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

DIST="bookworm"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS="${ROOT}/artifacts"
mkdir -p "${ARTIFACTS}"

for ARCH in "${ARCHES[@]}"; do
  echo "[INFO] === Building ${ARCH} ==="

  WORKDIR="${ROOT}/build-${ARCH}"
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"

  lb clean --purge || true

  lb config \
    --architectures "${ARCH}" \
    --distribution "${DIST}" \
    --binary-images iso-hybrid \
    --debian-installer none \
    --archive-areas "main contrib non-free non-free-firmware" \
    --mirror-bootstrap http://deb.debian.org/debian/ \
    --mirror-chroot http://deb.debian.org/debian/ \
    --bootappend-live "boot=live components quiet splash" \
    --apt-recommends true

  mkdir -p config/package-lists
  echo "rudyraindesktop" > config/package-lists/rudyraindesktop.list.chroot

  mkdir -p config/archives/local-repo

  cp "${RUDYRAIN_LOCAL_REPO}/Packages" config/archives/local-repo/ || true
  cp "${RUDYRAIN_LOCAL_REPO}/Packages.gz" config/archives/local-repo/ || true
  cp "${RUDYRAIN_LOCAL_REPO}"/*.deb config/archives/local-repo/ || true

  echo "deb [trusted=yes] file:/config/archives/local-repo ./" \
    > config/archives/local.list.chroot

  echo "[INFO] Running lb build for ${ARCH}"
  if ! lb build; then
    echo "[ERROR] lb build failed for ${ARCH}"
    cd "${ROOT}"
    continue
  fi

  ISO="$(ls -1 *.iso | head -n1 || true)"

  if [[ -n "${ISO}" ]]; then
    mv "${ISO}" "${ARTIFACTS}/RudyRainOS-${DIST}-${ARCH}.iso"
    echo "[INFO] ISO created for ${ARCH}"
  else
    echo "[WARN] No ISO produced for ${ARCH}"
  fi

  cd "${ROOT}"
done

echo "[INFO] All builds complete. ISOs in artifacts/"
