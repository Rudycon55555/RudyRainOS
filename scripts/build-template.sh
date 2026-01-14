#!/bin/bash
set -e

ARCH="$1"
DIST="bookworm"

REPO=/mnt/host/RudyRainOS
ROOT=/mnt/host/ISOs
WORKDIR="$ROOT/build-$ARCH"
CACHE="$ROOT/cache/apt"
OUT="$ROOT/artifacts/$ARCH"

mkdir -p "$WORKDIR" "$CACHE" "$OUT"
rm -rf "$WORKDIR"/*
cd "$WORKDIR"

mkdir -p \
  "$WORKDIR/config/includes.chroot" \
  "$WORKDIR/config/includes.binary" \
  "$WORKDIR/config/hooks" \
  "$WORKDIR/config/package-lists"

########################################
# 1) Overlay your RudyRainOS filesystem
########################################

if [ -d "$REPO/Meta-Packages/rudyraindesktop/files" ]; then
  cp -a "$REPO/Meta-Packages/rudyraindesktop/files/"* \
        "$WORKDIR/config/includes.chroot/"
fi

# Copy debian/ source for meta-package into chroot
mkdir -p "$WORKDIR/config/includes.chroot/usr/src/rudyraindesktop-debian"
cp -a "$REPO/Meta-Packages/debian/"* \
      "$WORKDIR/config/includes.chroot/usr/src/rudyraindesktop-debian/"

########################################
# 2) Hook: build + install meta-package
########################################

cat > "$WORKDIR/config/hooks/00-build-rudyraindesktop.chroot" << 'EOF'
#!/bin/sh
set -e

cd /usr/src/rudyraindesktop-debian

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y build-essential debhelper devscripts

dpkg-buildpackage -us -uc

cd ..
# Install the built .deb (assumes package name starts with 'rudyraindesktop')
PKG="$(ls rudyraindesktop_*.deb | head -n 1 || true)"
if [ -n "$PKG" ]; then
    apt-get install -y "./$PKG" || {
        dpkg -i "./$PKG" || true
        apt-get -f install -y
    }
fi
EOF
chmod +x "$WORKDIR/config/hooks/00-build-rudyraindesktop.chroot"

########################################
# 3) Hooks: schemas + caches
########################################

cat > "$WORKDIR/config/hooks/01-compile-schemas.chroot" << 'EOF'
#!/bin/sh
set -e
if command -v glib-compile-schemas >/dev/null 2>&1 && [ -d /usr/share/glib-2.0/schemas ]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas/ || true
fi
EOF
chmod +x "$WORKDIR/config/hooks/01-compile-schemas.chroot"

cat > "$WORKDIR/config/hooks/02-update-caches.chroot" << 'EOF'
#!/bin/sh
set -e
if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f -v || true
fi
if command -v update-icon-caches >/dev/null 2>&1; then
    update-icon-caches /usr/share/icons/* 2>/dev/null || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database /usr/share/mime || true
fi
EOF
chmod +x "$WORKDIR/config/hooks/02-update-caches.chroot"

########################################
# 4) Package list: kernel + GNOME + base
########################################

# Choose kernel meta-package per arch
case "$ARCH" in
  amd64)   KERNEL_PKG="linux-image-amd64" ;;
  arm64)   KERNEL_PKG="linux-image-arm64" ;;
  armhf)   KERNEL_PKG="linux-image-armmp" ;;
  ppc64el) KERNEL_PKG="linux-image-ppc64el" ;;
  riscv64) KERNEL_PKG="linux-image-riscv64" ;;
  s390x)   KERNEL_PKG="linux-image-s390x" ;;
  *)       KERNEL_PKG="linux-image-$ARCH" ;;
esac

cat > "$WORKDIR/config/package-lists/base-desktop.list.chroot" << EOF
$KERNEL_PKG

# Display stack
xorg
xserver-xorg-video-all
xserver-xorg-input-all

# GNOME core (your meta-package will add lots more)
gnome-shell
gnome-session
gdm3
gnome-control-center
nautilus
gnome-terminal
gnome-system-monitor

# Network
network-manager
network-manager-gnome

# Audio
pulseaudio
pavucontrol

# Firmware & drivers (where available)
firmware-linux-free
firmware-linux-nonfree

# Base system tools
sudo
vim
curl
wget
EOF

########################################
# 5) Configure live-build
########################################

lb config \
  --architectures "$ARCH" \
  --distribution "$DIST" \
  --binary-images iso-hybrid \
  --debian-installer false \
  --archive-areas "main contrib non-free non-free-firmware" \
  --mirror-bootstrap http://deb.debian.org/debian/ \
  --mirror-chroot http://deb.debian.org/debian/ \
  --bootappend-live "boot=live components quiet splash"
  --bootloader grub-pc

########################################
# 6) Build and move ISO
########################################

sudo lb build

mv ./*.iso "$OUT/"
echo "Built RudyRainOS desktop ISO for $ARCH -> $OUT"
