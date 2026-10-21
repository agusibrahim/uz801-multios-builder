#!/bin/bash
set -euo pipefail

[ -f ./variables.env ] && source ./variables.env

WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801-goos}"
USERNAME="${USERNAME:-user}"
PASSWORD="${PASSWORD:-changeme}"
WIFI_SSID="${WIFI_SSID:-Kaylaa}"
WIFI_PASS="${WIFI_PASS:-agus00000}"

trap 'umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true; rm -rf "$STAGING"' EXIT INT TERM

mkdir -p "$OUT_DIR" "$CHROOT"

echo "[*] Extracting minimal hardware runtime for UZ801 GoOS v1.0..."
tar -xzf "$OUT_DIR/alpine-rootfs.tgz" -C "$CHROOT"

chmod 1777 "$CHROOT/tmp" 2>/dev/null || true
rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

echo "[*] Installing nftables & fastfetch for UZ801 GoOS..."
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"

chroot "$CHROOT" /bin/sh -e -c "
apk update
apk add --no-interactive --no-cache nftables !postmarketos-base-nftables fastfetch curl jq htop
"

umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true

# Remove OpenRC init scripts/runlevels — PID 1 is 100% Pure Go (goos-init)!
rm -rf "$CHROOT/etc/runlevels" "$CHROOT/etc/init.d" "$CHROOT/etc/inittab" 2>/dev/null || true

echo "[*] Installing Pure Go PID 1 (/sbin/init) & UZ801 Modem Manager Dashboard..."
install -Dm0755 configs/goos/goos-init "$CHROOT/sbin/init"
ln -sf /sbin/init "$CHROOT/sbin/reboot"
ln -sf /sbin/init "$CHROOT/sbin/poweroff"
ln -sf /sbin/init "$CHROOT/sbin/halt"
ln -sf /sbin/init "$CHROOT/usr/sbin/reboot"
ln -sf /sbin/init "$CHROOT/usr/bin/reboot"

install -Dm0755 configs/dashboard/uz801-dashboard "$CHROOT/usr/bin/uz801-dashboard"
install -Dm0755 configs/usb-gadget/usb-gadget.sh "$CHROOT/usr/sbin/usb-gadget"
ln -sf /usr/sbin/usb-gadget "$CHROOT/usr/bin/usb-gadget"
install -Dm0755 configs/adb/adbd "$CHROOT/usr/bin/adbd"

cat > "$CHROOT/etc/os-release" << 'EOF'
PRETTY_NAME="UZ801 GoOS v1.0 (Pure Go PID 1)"
NAME="UZ801 GoOS"
VERSION_ID="1.0"
VERSION="1.0 (Mainline 6.12)"
ID="goos"
HOME_URL="https://github.com/agusibrahim/uz801-multios-builder"
EOF
cp "$CHROOT/etc/os-release" "$CHROOT/usr/lib/os-release" 2>/dev/null || true

cat > "$CHROOT/etc/motd" << 'EOF'
   _   _ ______ ___   ___  _    ____        ___  ____  
  | | | |__  ( _ ) / _ \/ |  / ___| ___  / _ \/ ___| 
  | | | | / // _ \| | | | | | |  _ / _ \| | | \___ \ 
  | |_| |/ /| (_) | |_| | | | |_| | (_) | |_| |___) |
   \___//____\___/ \___/|_|  \____|\___/ \___/|____/ 
  Pure Go PID 1 Firmware Appliance (Kernel 6.12.1-msm8916)
  Web Dashboard & Captive Portal: http://192.168.42.1
EOF

echo "$HOST_NAME" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" << EOF
127.0.0.1 localhost ${HOST_NAME}
::1       localhost ip6-localhost ip6-loopback
EOF

cat > "$CHROOT/etc/fstab" << 'EOF'
/dev/mmcblk0p13    /boot    ext2    ro,noatime          0 0
/dev/mmcblk0p14    /        ext4    rw,noatime,commit=1 0 0
EOF

mkdir -p "$CHROOT/etc/NetworkManager/conf.d" "$CHROOT/etc/NetworkManager/system-connections"
cat > "$CHROOT/etc/NetworkManager/conf.d/10-uz801.conf" << 'EOF'
[main]
dns=default
rc-manager=file

[keyfile]
unmanaged-devices=interface-name:usb0
EOF

cp configs/network-manager/wlan.nmconnection "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
sed -i "s/__SSID__/${WIFI_SSID}/g" "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
sed -i "s/__PASS__/${WIFI_PASS}/g" "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
cp configs/network-manager/lte.nmconnection "$CHROOT/etc/NetworkManager/system-connections/lte.nmconnection"
chmod 0600 "$CHROOT/etc/NetworkManager/system-connections/"*.nmconnection

cat > "$CHROOT/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

echo "[*] Creating UZ801 GoOS v1.0 ext4 rootfs image (512 MiB)..."
ROOT_RAW="$STAGING/goos-rootfs.raw"
truncate -s $((512 * 1024 * 1024)) "$ROOT_RAW"
mkfs.ext4 -F -d "$CHROOT" "$ROOT_RAW" >/dev/null 2>&1
gzip -c "$ROOT_RAW" > "$OUT_DIR/goos-rootfs.img.gz"

echo "[+] UZ801 GoOS v1.0 rootfs image created:"
ls -lh "$OUT_DIR/goos-rootfs.img.gz"
