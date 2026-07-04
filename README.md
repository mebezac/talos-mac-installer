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
in the build just rebuilds what depends on that custom kernel.

Because the *stub* is the problem, a GCC kernel boots fine under **UKI/systemd-boot** —
there's no need for GRUB or a version ladder. Point a node at this installer and
`talosctl upgrade` it like any other node.

## What the build does

1. **kernel** — clone `siderolabs/pkgs` at the exact commit the target Talos release
   pins, `sed` out `LLVM: 1`, `make kernel` → GHCR (`.../pkgs/kernel:<pkgs>-dirty`).
   The kernel source is pulled from `github.com/gregkh/linux` (see [notes](#how-it-works)).
2. **module extensions** — rebuild **i915** and **thunderbolt** against the custom
   kernel and retag to `.../extensions/<name>:<talos-version>`. Both ship signed `.ko`
   modules; the kernel enforces module signatures with the build's own key, so stock
   images (signed with Sidero's key) would be rejected. Firmware/userspace extensions
   (`intel-ucode`, `iscsi-tools`, `util-linux-tools`) have no modules and are pulled
   stock at the Image Factory's blessed tags.
3. **talos** — `make imager installer-base`, pulling every stock pkg from
   `ghcr.io/siderolabs` and overriding only `PKG_KERNEL` with the custom build → GHCR.
4. **imager** — render `profile.yaml.tmpl` twice:
   - `kind: iso` → `metal-amd64.iso`, attached to a GitHub Release.
   - `kind: installer` → `ghcr.io/<owner>/talos-mac/installer:<talos-version>`.

## Usage

1. Fork/clone to GitHub. GHCR publishing uses the built-in `GITHUB_TOKEN`.
2. Set `TALOS_VERSION` in `versions.env` (and the stock extension tags — the values the
   Image Factory resolves for that release; see the comments in that file).
3. **Tag the repo with the Talos version to trigger a build:**
   ```bash
   git tag v1.13.5 && git push --tags
   ```
   Builds run on tag push only. Use the **build-installer** workflow's
   `workflow_dispatch` (optionally with a `talos_version` input) to test without tagging.

The kernel compile is ~2h on a stock runner; the kernel / extension / talos steps each
skip if their image already exists (`FORCE_KERNEL`/`FORCE_EXT`/`FORCE_TALOS=1` to
rebuild), so re-runs of the same version finish in minutes.

Local run (Linux/amd64 + Docker, logged in to your GHCR namespace — not macOS):
```bash
set -a; . versions.env; set +a
export REGISTRY=ghcr.io/<owner>/talos-mac
scripts/build.sh
```

## Using the output

Fresh install: download `metal-amd64.iso` from the matching Release, `dd` it to a USB
stick, boot the Mac holding ⌥ → **EFI Boot** → Talos maintenance mode, then apply your
machine config.

In-place (once a node is already on the custom image):
```bash
talosctl -n <node-ip> upgrade \
  --image ghcr.io/<owner>/talos-mac/installer:v1.13.5 --preserve
```

With talhelper, set the node's `talosImageURL` to `ghcr.io/<owner>/talos-mac/installer`
(talhelper appends `:${talosVersion}`) so it tracks the version like any other node.
Never point a T2 Mac at `factory.talos.dev` for v1.13+ — that's the hanging stock kernel.

## How it works

A few non-obvious things the pipeline handles:

- **pkgs ref.** `siderolabs/pkgs` isn't tagged per patch release; the build reads the
  exact pinned commit from the target Talos release's `Makefile` (`PKGS ?= …`), so the
  kernel config/patches always match.
- **Kernel source.** `cdn.kernel.org` 404s the tarball from GitHub Actions egress (the
  shared CI IP ranges are blocked), which surfaced as a buildkit "digest mismatch". The
  build sources the exact stable tag from `github.com/gregkh/linux` (the stable tree's
  GitHub mirror — same source tree as the official tarball, so patches/config apply) and
  recomputes the checksums, mirroring Talos' own "kspp from GitHub archive" pattern.
- **Extension deps.** i915 pulls both `kernel` (custom) and `linux-firmware` (stock) from
  one shared `PKGS_PREFIX`; the build mirrors stock `linux-firmware` into the custom
  prefix so the single prefix resolves both.
- **Installer output.** `kind: installer` requires `outFormat: raw` (passthrough); an
  empty value decodes to `unknown` and the imager errors.

## Layout

```
versions.env                     one build's inputs (Renovate-tracked)
profile.yaml.tmpl                imager profile (envsubst)
scripts/build.sh                 the whole pipeline
scripts/gen-profile.sh           render profile for iso|installer
.github/workflows/build-installer.yaml
renovate.json
```
