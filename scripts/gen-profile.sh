#!/usr/bin/env bash
# Render profile.yaml.tmpl for a given output kind.
#   Usage: OUTPUT_KIND=iso OUTPUT_FORMAT=raw scripts/gen-profile.sh > profile.iso.yaml
#          OUTPUT_KIND=installer OUTPUT_FORMAT="" scripts/gen-profile.sh > profile.installer.yaml
# Required env (from versions.env + the workflow): REGISTRY, ARCH, TALOS_VERSION,
#   EXT_INTEL_UCODE, EXT_ISCSI_TOOLS, EXT_UTIL_LINUX, EXT_THUNDERBOLT.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${OUTPUT_KIND:?set OUTPUT_KIND (iso|installer)}"
: "${OUTPUT_FORMAT:=}"          # iso wants "raw"; installer wants empty
: "${REGISTRY:?}" "${ARCH:?}" "${TALOS_VERSION:?}"

export OUTPUT_KIND OUTPUT_FORMAT REGISTRY ARCH TALOS_VERSION \
       EXT_INTEL_UCODE EXT_ISCSI_TOOLS EXT_UTIL_LINUX EXT_THUNDERBOLT

envsubst < "${here}/profile.yaml.tmpl"
