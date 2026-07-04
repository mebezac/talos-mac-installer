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
  PKGS_PIN="$pin"                 # v1.13.0-36-g6b315f7 (stock, non-dirty tag)
  PKGS_REF="${pin##*-g}"          # -> 6b315f7 (git ref to check out pkgs at)
  export PKGS_PIN PKGS_REF
  echo "pkgs pin: $PKGS_PIN -> ref $PKGS_REF"
}

# cdn.kernel.org 404s the kernel tarball from GitHub Actions egress (kernel.org blocks
# the shared CI IP ranges) — that was the "digest mismatch": buildkit hashed a 404 page.
# Source the exact stable tag from GitHub's kernel mirror instead (same source tree as
# the official tarball, so talos' patches + config apply unchanged). GitHub archive
# gzip bytes differ from the official .tar.xz, so recompute the checksums — this mirrors
# talos' own "kspp from github archive, pinned by sha" pattern.
KMIRROR="https://github.com/gregkh/linux/archive/refs/tags"
repoint_kernel_source() {
  cd "$WORK/pkgs"
  local ver url s256 s512
  ver="$(grep -E '^[[:space:]]*linux_version:' Pkgfile | awk '{print $2}')"
  url="${KMIRROR}/v${ver}.tar.gz"
  log "kernel source -> $url (cdn.kernel.org unreachable from CI)"
  curl -fSL --retry 4 --retry-delay 5 -o /tmp/linux.src.tar.gz "$url"
  s256="$(sha256sum /tmp/linux.src.tar.gz | awk '{print $1}')"
  s512="$(sha512sum /tmp/linux.src.tar.gz | awk '{print $1}')"
  rm -f /tmp/linux.src.tar.gz
  sed -i -E "s|^([[:space:]]*linux_sha256:).*|\1 ${s256}|" Pkgfile
  sed -i -E "s|^([[:space:]]*linux_sha512:).*|\1 ${s512}|" Pkgfile
  # Repoint the download URL (keep the {{ .linux_version }} template) and make the
  # untar codec-agnostic — GNU/busybox tar auto-detect gzip-vs-xz from the magic bytes.
  # NB: the url line embeds a {{ regexReplaceAll "..." }} with double-quotes, so match
  # greedily to the trailing .tar.xz rather than a quote-excluding class.
  sed -i -E "s|https://cdn\.kernel\.org.*\.tar\.xz|${KMIRROR}/v{{ .linux_version }}.tar.gz|" kernel/prepare/pkg.yaml
  sed -i 's/tar -xJf linux.tar.xz/tar -xf linux.tar.xz/' kernel/prepare/pkg.yaml
  echo "kernel $ver sha256=$s256"
  grep -nE 'gregkh|tar -xf linux' kernel/prepare/pkg.yaml || true
  cd - >/dev/null
}

# 1) Custom kernel: remove LLVM so it links with GCC/GNU-ld.
build_pkgs_kernel() {
  log "pkgs: kernel (LLVM removed) @ $PKGS_REF"
  clone https://github.com/siderolabs/pkgs.git "$PKGS_REF" pkgs
  repoint_kernel_source
  cd "$WORK/pkgs"
  sed -i '/^\s*LLVM:\s*1/d' kernel/build/pkg.yaml
  # tag the produced image with the dirty describe so downstream can reference it
  PKGS_TAG="$(git describe --tags --always --dirty --match 'v[0-9]*')"
  export PKGS_TAG
  # The kernel compile is ~2h. If this exact image is already in the registry (from a
  # prior run of the same commit), reuse it so downstream-only fixes iterate in minutes.
  if [ "${FORCE_KERNEL:-0}" != "1" ] && crane manifest "$REGISTRY/pkgs/kernel:$PKGS_TAG" >/dev/null 2>&1; then
    log "kernel $REGISTRY/pkgs/kernel:$PKGS_TAG already built — skipping compile (FORCE_KERNEL=1 to rebuild)"
    cd - >/dev/null; return
  fi
  make kernel-olddefconfig PLATFORM="$PLATFORM"
  make kernel REGISTRY="$REGISTRY" USERNAME=pkgs PUSH=true PLATFORM="$PLATFORM"
  echo "PKGS_TAG=$PKGS_TAG"          # -> $REGISTRY/pkgs/kernel:$PKGS_TAG
  cd - >/dev/null
}

# i915 pulls BOTH kernel and linux-firmware from a single PKGS_PREFIX. kernel is our
# custom build; linux-firmware is stock (GPU blobs, kernel-independent). Mirror the
# stock firmware into our prefix under the dirty tag so the one shared prefix resolves.
mirror_pkg_deps() {
  local dst="$REGISTRY/pkgs/linux-firmware:$PKGS_TAG"
  if crane manifest "$dst" >/dev/null 2>&1; then
    log "linux-firmware already mirrored ($dst)"; return
  fi
  log "mirror stock linux-firmware -> $dst"
  crane copy "ghcr.io/siderolabs/linux-firmware:$PKGS_PIN" "$dst"
}

# 2) Kernel-module extensions rebuilt against the custom kernel. These ship signed
# .ko files; our kernel enforces module signatures with OUR build's key, so a stock
# image (signed with siderolabs' key) would be rejected — they must be rebuilt here.
# Firmware/userspace extensions (intel-ucode, iscsi-tools, util-linux-tools) have no
# modules and are pulled stock in the imager profile.
MODULE_EXTS=(i915 thunderbolt)
build_extensions() {
  mirror_pkg_deps   # linux-firmware, needed by i915
  clone https://github.com/siderolabs/extensions.git "$EXTENSIONS_REF" extensions
  cd "$WORK/extensions"
  local ext built
  for ext in "${MODULE_EXTS[@]}"; do
    if [ "${FORCE_EXT:-0}" != "1" ] && crane manifest "$REGISTRY/extensions/$ext:$TALOS_VERSION" >/dev/null 2>&1; then
      log "extension $ext:$TALOS_VERSION already built — skipping (FORCE_EXT=1 to rebuild)"; continue
    fi
    log "extensions: $ext (against custom kernel) @ $EXTENSIONS_REF"
    make "$ext" TAG="$TALOS_VERSION" REGISTRY="$REGISTRY" USERNAME=extensions PUSH=true \
      PLATFORM="$PLATFORM" PKGS="$PKGS_TAG" PKGS_PREFIX="$REGISTRY/pkgs" \
      2>&1 | tee "$OUT/$ext-build.log"
    # extensions self-tag (datestamp-version); capture the pushed ref and pin to :VERSION
    built="$(grep -oE "$REGISTRY/extensions/$ext:[A-Za-z0-9._-]+" "$OUT/$ext-build.log" | tail -1)"
    [ -n "$built" ] || { echo "could not capture $ext image ref from build log" >&2; exit 1; }
    log "retag $ext $built -> :$TALOS_VERSION"
    crane copy "$built" "$REGISTRY/extensions/$ext:$TALOS_VERSION"
  done
  cd - >/dev/null
}

# 3) Talos boot artifacts (kernel/initramfs/installer-base/imager) with the custom kernel.
build_talos() {
  # make_iso/make_installer only RUN the imager image, so if it's already published we
  # can skip rebuilding the talos artifacts and iterate the imager steps in minutes.
  if [ "${FORCE_TALOS:-0}" != "1" ] && crane manifest "$REGISTRY/imager/imager:$TALOS_VERSION" >/dev/null 2>&1; then
    log "imager $REGISTRY/imager/imager:$TALOS_VERSION already built — skipping talos build (FORCE_TALOS=1 to rebuild)"; return
  fi
  log "talos: imager + installer-base @ $TALOS_VERSION"
  clone https://github.com/siderolabs/talos.git "$TALOS_VERSION" talos
  cd "$WORK/talos"
  # Pull every pkg (containerd, grub, iptables, ...) from STOCK siderolabs at the pin;
  # override ONLY the kernel to our custom GCC-linked build. Non-kernel pkgs are
  # userspace and kernel-independent, so stock + custom kernel is correct.
  make kernel initramfs imager installer-base \
    REGISTRY="$REGISTRY" USERNAME=imager PUSH=true TAG="$TALOS_VERSION" \
    PKG_KERNEL="$REGISTRY/pkgs/kernel:$PKGS_TAG" \
    PLATFORM="$PLATFORM" INSTALLER_ARCH="$ARCH" \
    PKGS="$PKGS_PIN" PKGS_PREFIX="ghcr.io/siderolabs"
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
    EXT_UTIL_LINUX="$EXT_UTIL_LINUX" \
    scripts/gen-profile.sh | imager
  ls -lh "$OUT"/*.iso
}

# 4b) Installer image for `talosctl upgrade --image` and talconfig talosImageURL.
make_installer() {
  log "imager: installer image -> $REGISTRY/installer:$TALOS_VERSION"
  OUTPUT_KIND=installer OUTPUT_FORMAT="" REGISTRY="$REGISTRY" ARCH="$ARCH" \
    TALOS_VERSION="$TALOS_VERSION" \
    EXT_INTEL_UCODE="$EXT_INTEL_UCODE" EXT_ISCSI_TOOLS="$EXT_ISCSI_TOOLS" \
    EXT_UTIL_LINUX="$EXT_UTIL_LINUX" \
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
