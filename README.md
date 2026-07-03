# talos-mac-installer

Builds a **GCC-linked** Talos installer image + USB ISO so 2018 T2 Intel Mac minis
(`Macmini8,1`) cold-boot Talos **v1.13+**. Publishes to GHCR via GitHub Actions.

## Why this exists

Talos v1.13's kernel is linked with **Clang + LLD/ThinLTO**. Apple's Intel EFI
firmware validates PE binaries and refuses to hand off to an LLD-linked EFI stub, so
the node hangs at the TALOS splash on a cold boot. This is not Talos-specific — any
distro with an LLD-linked kernel hits it (siderolabs/talos#13579, #13231). Kernel 6.11
disabled LTO in `libstub` for exactly this class of EFI issues; the LLVM link is what
remains.

**The fix is one line:** drop `LLVM: 1` from the kernel package so the kernel (and its
EFI stub) links with **GCC + GNU ld**, which the Mac firmware accepts. Everything else
in the build is just rebuilding what depends on that custom kernel.

Because the *stub* is the problem, a GCC kernel boots fine under **UKI/systemd-boot** —
so this **retires the GRUB v1.9.6 → ladder dance entirely**. Point a node at this
installer and `talosctl upgrade` like any other node.

## What the build does

1. **pkgs** — clone `siderolabs/pkgs`, `sed` out `LLVM: 1`, `make kernel` → GHCR
   (`.../pkgs/kernel:<version>-dirty`).
2. **extensions** — recompile **i915** against the custom kernel (out-of-tree `.ko`
   modules must match the new build), retag to `.../extensions/i915:<version>`.
   Other schematic extensions (intel-ucode, iscsi-tools, util-linux-tools, thunderbolt)
   are firmware/userspace only → pulled stock, no rebuild.
3. **talos** — `make imager installer-base` with `PKG_KERNEL=<custom>` → GHCR.
4. **imager** — render `profile.yaml.tmpl` twice:
   - `kind: iso` → `metal-amd64.iso`, attached to a GitHub Release.
   - `kind: installer` → `ghcr.io/<owner>/talos-mac/installer:<version>`.

## Usage

1. Push this repo to GitHub. Enable GHCR packages.
2. Set `TALOS_VERSION` in `versions.env`.
3. Run the **build-installer** workflow (auto-runs on push, or dispatch with a version
   override).
4. Consume the outputs in `home-cluster` (below).

Local run (Linux/amd64 + Docker only — not macOS):
```bash
set -a; . versions.env; set +a
export REGISTRY=ghcr.io/<owner>/talos-mac
scripts/build.sh
```

## Wiring into home-cluster

Point the talmac nodes at the custom installer instead of the factory schematic. In
`kubernetes/bootstrap/talos/talconfig.yaml`, for each talmac node:

```yaml
  - hostname: "talmac-02"
    talosImageURL: ghcr.io/<owner>/talos-mac/installer   # talhelper appends :<talosVersion>
```

Then the normal flow works — no GRUB ladder, no per-node version pin:
```bash
# fresh install: write metal-amd64.iso (release asset) to USB, boot it, apply-config
# in-place upgrade:
talosctl -n 10.25.30.43 upgrade \
  --image ghcr.io/<owner>/talos-mac/installer:v1.13.5 --preserve
```

Delete the `patches/talmac-*/machine-install.yaml` version pins once nodes track
`talosVersion: v1.13.5` globally.

## First-run caveats (things most likely to need a tweak)

- **Disk space** on `ubuntu-latest` is tight even after the cleanup step. If the kernel
  build fails on `ENOSPC`, switch to a larger runner.
- **pkgs image tag** is `git describe --dirty`. On a branch head not sitting exactly on
  a tag it may be `v1.13.0-N-gsha-dirty`; the script captures it dynamically, so it's
  fine, but the string in GHCR won't be pretty.
- **i915 auto-tag capture** — extensions tag images with a build datestamp. The script
  greps the build log for the pushed ref then `crane copy`s it to a clean
  `:<version>` tag. If the grep misses (upstream log format change), fix the pattern in
  `scripts/build.sh:build_extensions`.
- **installer tarball** — `make_installer` assumes imager writes `installer-*.tar` into
  `_out`. If the imager output name/format differs on your Talos version, adjust the
  `crane push` line (may need `skopeo copy oci-archive:...`).
- **thunderbolt** — pulled stock. If your USB enclosure / smarthome adapter regresses
  after upgrade, rebuild `thunderbolt` like i915 and reference the custom image in
  `versions.env`.
- **EXT_* digests** — pin to `@sha256:...` before trusting in-cluster.

## Layout

```
versions.env                     one build's inputs (Renovate-tracked)
profile.yaml.tmpl                imager profile (envsubst)
scripts/build.sh                 the whole pipeline
scripts/gen-profile.sh           render profile for iso|installer
.github/workflows/build-installer.yaml
renovate.json
```
