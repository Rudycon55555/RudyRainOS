#!/usr/bin/env bash
set -euo pipefail

ARCH="$1"
DIST="bookworm"

ROOT="$(pwd)"
WORKDIR="${ROOT}/build-${ARCH}"
ARTIFACTS="${ROOT}/artifacts"

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}" "${ARTIFACTS}"

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

mkdir -p config/archives
echo "deb [trusted=yes] file:${RUDYRAIN_LOCAL_REPO} ./" > config/archives/local.list.chroot

lb build

ISO="$(ls -1 *.iso | head -n1)"
mv "${ISO}" "${ARTIFACTS}/RudyRainOS-${DIST}-${ARCH}.iso"
