#!/usr/bin/env bash
# Build a Talos installer + ISO with a GCC-linked kernel so 2018 T2 Intel Macs
# cold-boot. The fix: drop `LLVM: 1` from the kernel pkg so the EFI stub is linked
# by GNU ld instead of LLD (siderolabs/talos#13579 / #13231).
#
# Runs on a Linux/amd64 host with Docker. Designed for GitHub Actions ubuntu-latest
# but runnable locally. NOT runnable on macOS (needs privileged linux/amd64 buildkit).
#
# Env (see versions.env). REGISTRY must be a pushable repo base you're logged into,
# e.g. ghcr.io/<owner>/talos-mac. Everything is pushed under $REGISTRY/<username>/...
set -euo pipefail

: "${REGISTRY:?set REGISTRY, e.g. ghcr.io/<owner>/talos-mac}"
: "${TALOS_VERSION:?}"
# Extensions tag every patch release, so default to the Talos version. pkgs does NOT
# tag per-patch — its ref is derived from the talos Makefile's PKGS pin (see build_talos_src).
: "${EXTENSIONS_REF:=$TALOS_VERSION}"
: "${PLATFORM:=linux/amd64}" "${ARCH:=amd64}"
WORK="${WORK:-$(pwd)/_src}"
OUT="${OUT:-$(pwd)/_out}"
mkdir -p "$WORK" "$OUT"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# buildx builder with the insecure entitlement Talos builds require.
setup_buildx() {
  log "buildx builder (insecure entitlement)"
  docker buildx inspect talos-mac >/dev/null 2>&1 || \
    docker buildx create --name talos-mac --driver docker-container \
      --buildkitd-flags '--allow-insecure-entitlement security.insecure' >/dev/null
  docker buildx use talos-mac
  docker buildx inspect --bootstrap >/dev/null
}

clone() { # repo ref dir
  local repo="$1" ref="$2" dir="$3"
  if [ ! -d "$WORK/$dir/.git" ]; then
    git clone --filter=blob:none "$repo" "$WORK/$dir"
  fi
  git -C "$WORK/$dir" fetch --tags --force origin
  git -C "$WORK/$dir" checkout --force "$ref"
}

# Clone talos first and read the exact pkgs commit it pins (PKGS ?= v1.13.0-N-gSHA).
# The moving release-1.13 branch drifts ahead and its kernel checksum stops matching
# the tarball on cdn.kernel.org — that was the "digest mismatch" failure.
resolve_pkgs_ref() {
  log "talos: resolve pkgs pin @ $TALOS_VERSION"
  clone https://github.com/siderolabs/talos.git "$TALOS_VERSION" talos
  local pin
  pin="$(grep -E '^PKGS[[:space:]]*\?=' "$WORK/talos/Makefile" | head -1 | awk '{print $3}')"
  [ -n "$pin" ] || { echo "could not read PKGS pin from talos Makefile" >&2; exit 1; }
  PKGS_REF="${pin##*-g}"          # v1.13.0-36-g6b315f7 -> 6b315f7
  export PKGS_REF
  echo "pkgs pin: $pin -> ref $PKGS_REF"
}

# 1) Custom kernel: remove LLVM so it links with GCC/GNU-ld.
build_pkgs_kernel() {
  log "pkgs: kernel (LLVM removed) @ $PKGS_REF"
  clone https://github.com/siderolabs/pkgs.git "$PKGS_REF" pkgs
  cd "$WORK/pkgs"
  sed -i '/^\s*LLVM:\s*1/d' kernel/build/pkg.yaml
  # tag the produced image with the dirty describe so downstream can reference it
  PKGS_TAG="$(git describe --tags --always --dirty --match 'v[0-9]*')"
  export PKGS_TAG
  make kernel-olddefconfig PLATFORM="$PLATFORM"
  make kernel REGISTRY="$REGISTRY" USERNAME=pkgs PUSH=true PLATFORM="$PLATFORM"
  echo "PKGS_TAG=$PKGS_TAG"          # -> $REGISTRY/pkgs/kernel:$PKGS_TAG
  cd - >/dev/null
}

# 2) i915 recompiled against the custom kernel, retagged to a deterministic ref.
build_extensions() {
  log "extensions: i915 (against custom kernel) @ $EXTENSIONS_REF"
  clone https://github.com/siderolabs/extensions.git "$EXTENSIONS_REF" extensions
  cd "$WORK/extensions"
  make i915 TAG="$TALOS_VERSION" REGISTRY="$REGISTRY" USERNAME=extensions PUSH=true \
    PLATFORM="$PLATFORM" PKGS="$PKGS_TAG" PKGS_PREFIX="$REGISTRY/pkgs" \
    2>&1 | tee "$OUT/i915-build.log"
  # extensions auto-tag with a datestamp (e.g. 20260410-v1.13.0); capture and pin it
  local built
  built="$(grep -oE "$REGISTRY/extensions/i915:[A-Za-z0-9._-]+" "$OUT/i915-build.log" | tail -1)"
  [ -n "$built" ] || { echo "could not capture i915 image ref from build log" >&2; exit 1; }
  log "retag i915 $built -> :$TALOS_VERSION"
  crane copy "$built" "$REGISTRY/extensions/i915:$TALOS_VERSION"
  cd - >/dev/null
}

# 3) Talos boot artifacts (kernel/initramfs/installer-base/imager) with the custom kernel.
build_talos() {
  log "talos: imager + installer-base @ $TALOS_VERSION"
  clone https://github.com/siderolabs/talos.git "$TALOS_VERSION" talos
  cd "$WORK/talos"
  make kernel initramfs imager installer-base \
    REGISTRY="$REGISTRY" USERNAME=imager PUSH=true TAG="$TALOS_VERSION" \
    PKG_KERNEL="$REGISTRY/pkgs/kernel:$PKGS_TAG" \
    PLATFORM="$PLATFORM" INSTALLER_ARCH="$ARCH" \
    PKGS="$PKGS_TAG" PKGS_PREFIX="$REGISTRY/pkgs"
  cd - >/dev/null
}

imager() { # runs the imager container against a rendered profile on stdin
  docker run --rm -i --privileged --network=host -v "$OUT:/out" \
    "$REGISTRY/imager/imager:$TALOS_VERSION" -
}

# 4a) ISO for USB fresh installs.
make_iso() {
  log "imager: metal ISO"
  OUTPUT_KIND=iso OUTPUT_FORMAT=raw REGISTRY="$REGISTRY" ARCH="$ARCH" \
    TALOS_VERSION="$TALOS_VERSION" \
    EXT_INTEL_UCODE="$EXT_INTEL_UCODE" EXT_ISCSI_TOOLS="$EXT_ISCSI_TOOLS" \
    EXT_UTIL_LINUX="$EXT_UTIL_LINUX" EXT_THUNDERBOLT="$EXT_THUNDERBOLT" \
    scripts/gen-profile.sh | imager
  ls -lh "$OUT"/*.iso
}

# 4b) Installer image for `talosctl upgrade --image` and talconfig talosImageURL.
make_installer() {
  log "imager: installer image -> $REGISTRY/installer:$TALOS_VERSION"
  OUTPUT_KIND=installer OUTPUT_FORMAT="" REGISTRY="$REGISTRY" ARCH="$ARCH" \
    TALOS_VERSION="$TALOS_VERSION" \
    EXT_INTEL_UCODE="$EXT_INTEL_UCODE" EXT_ISCSI_TOOLS="$EXT_ISCSI_TOOLS" \
    EXT_UTIL_LINUX="$EXT_UTIL_LINUX" EXT_THUNDERBOLT="$EXT_THUNDERBOLT" \
    scripts/gen-profile.sh | imager
  # imager writes an OCI/docker tarball into /out; push it under a clean name.
  local tar
  tar="$(ls "$OUT"/installer-*.tar 2>/dev/null | head -1)"
  [ -n "$tar" ] || { echo "no installer tarball in $OUT" >&2; ls -la "$OUT" >&2; exit 1; }
  crane push "$tar" "$REGISTRY/installer:$TALOS_VERSION"
  log "installer ready: $REGISTRY/installer:$TALOS_VERSION"
}

main() {
  setup_buildx
  resolve_pkgs_ref
  build_pkgs_kernel
  build_extensions
  build_talos
  make_iso
  make_installer
  log "done. ISO in $OUT, installer at $REGISTRY/installer:$TALOS_VERSION"
}
main "$@"
