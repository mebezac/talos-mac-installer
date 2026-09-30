# talos-mac-installer

> [!IMPORTANT]
> **This repository is archived and no longer needed.** Talos **v1.14.2** and later
> boot on 2018 T2 Intel Mac minis (`Macmini8,1`) out of the box. Use the stock Image
> Factory images instead.

## What to do instead

1. Create an [Image Factory](https://factory.talos.dev) schematic for **v1.14.2 or
   later** with the extensions you need. The stock extensions work now, including
   `i915` and `thunderbolt`, so nothing has to be rebuilt. Typical set: `i915`,
   `thunderbolt`, `intel-ucode`, `iscsi-tools`, `util-linux-tools`.
2. **Fresh install:** download the factory `metal-amd64.iso`, `dd` it to a USB stick,
   hold ⌥ at power-on, then choose **EFI Boot**.
3. **Nodes already running this repo's installer:** upgrade straight to the factory
   installer:
   ```bash
   talosctl -n <node-ip> upgrade \
     --image factory.talos.dev/installer/<schematic-id>:v1.14.2 --preserve
   ```
   With talhelper, change `talosImageURL` back to
   `factory.talos.dev/installer/<schematic-id>`.

Talos v1.13.x and v1.14.0–v1.14.1 do **not** include the fix. These Macs still hang
at boot on those versions.

## The real fix

This repo assumed Apple's EFI firmware rejected an LLD-linked kernel EFI stub. That
assumption was wrong. The actual cause was a kernel bug, fixed by
[siderolabs/pkgs@6c312e4](https://github.com/siderolabs/pkgs/commit/6c312e4)
(patch `0018-efistub-x86-Fix-the-size-type-of-the-Apple-propertie.patch`, by
Nicolas Brainez, also
[submitted upstream](https://lore.kernel.org/linux-efi/20260928072832.25399-1-nicolas@brainez.net/)
with `Cc: stable`):

- The x86 EFI stub declares the size argument of the Apple device properties
  protocol (`get_all()` and friends) as `u32`. The firmware actually uses a 64-bit
  `UINTN`.
- `retrieve_apple_device_properties()` passes a pointer to a 4-byte `u32` on the
  stack. 64-bit Apple firmware writes 8 bytes through it and overwrites the stack
  slot next to it.
- With **clang** and `CONFIG_EFI_MIXED=n`, that slot holds the protocol pointer `p`.
  The second `get_all()` call jumps through the corrupted pointer, and the Mac hangs
  or powers off before printing anything.
- **GCC** happens to leave padding in that slot, so the overwrite does no damage.
  That is the only reason this repo's GCC-linked kernel booted. The problem was never
  GNU ld compared to LLD.

The patch declares the size as `unsigned long`. It shipped in Talos v1.14.2, which
pins that pkgs commit. Tracking issues:
[siderolabs/talos#13231](https://github.com/siderolabs/talos/issues/13231),
[siderolabs/talos#13579](https://github.com/siderolabs/talos/issues/13579).

---

## Historical documentation

Everything below describes the workaround as it was built, kept for reference. The
workaround rebuilt Talos with a **GCC-linked** kernel (by dropping `LLVM: 1` from the
kernel package in `siderolabs/pkgs`). It also rebuilt every extension that ships
signed kernel modules against that kernel, then published an installer image and a
USB ISO to GHCR.

### What the build does

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

### Usage

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

### Using the output

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
Never point a T2 Mac at `factory.talos.dev` for v1.13.x–v1.14.1 — those stock kernels hang. (v1.14.2+ is fixed; see above.)

### How it works

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

### Layout

```
versions.env                     one build's inputs (Renovate-tracked)
profile.yaml.tmpl                imager profile (envsubst)
scripts/build.sh                 the whole pipeline
scripts/gen-profile.sh           render profile for iso|installer
.github/workflows/build-installer.yaml
renovate.json
```
