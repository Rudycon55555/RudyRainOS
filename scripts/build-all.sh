#!/usr/bin/env bash
set -euo pipefail

ARCHES=(
  amd64
  arm64
  armhf
  ppc64el
  riscv64
  s390x
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

mkdir -p artifacts

build_arch() {
  local arch="$1"
  echo "[INFO] Starting build for ${arch}"
  "${SCRIPT_DIR}/build-one.sh" "${arch}"
  echo "[INFO] Finished build for ${arch}"
}

export -f build_arch
export SCRIPT_DIR

if command -v parallel >/dev/null 2>&1; then
  printf "%s\n" "${ARCHES[@]}" | parallel --jobs 3 build_arch {}
else
  for arch in "${ARCHES[@]}"; do
    build_arch "${arch}"
  done
fi

echo "[INFO] All ISOs built. See artifacts/ directory."
