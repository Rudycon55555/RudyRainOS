#!/bin/bash
set -e

ROOT=/mnt/host/ISOs

mkdir -p \
  "$ROOT/cache/apt" \
  "$ROOT/artifacts/amd64" \
  "$ROOT/artifacts/arm64" \
  "$ROOT/artifacts/armhf" \
  "$ROOT/artifacts/ppc64el" \
  "$ROOT/artifacts/riscv64" \
  "$ROOT/artifacts/s390x"

cd "$(dirname "$0")"

# Requires: sudo apt install live-build parallel
parallel --jobs 4 ::: \
  "./build-amd64.sh" \
  "./build-arm64.sh" \
  "./build-armhf.sh" \
  "./build-ppc64el.sh" \
  "./build-riscv64.sh" \
  "./build-s390x.sh"
