#!/bin/bash
set -euo pipefail

[ -f ./variables.env ] && source ./variables.env

WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801-pmos}"
USERNAME="${USERNAME:-user}"
PASSWORD="${PASSWORD:-changeme}"
WIFI_SSID="${WIFI_SSID:-Kaylaa}"
WIFI_PASS="${WIFI_PASS:-agus00000}"

trap 'umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true; rm -rf "$STAGING"' EXIT INT TERM

mkdir -p "$OUT_DIR" "$CHROOT"

echo "[*] Extracting base rootfs for postmarketOS v25.06..."
tar -xzf "$OUT_DIR/alpine-rootfs.tgz" -C "$CHROOT"

chmod 1777 "$CHROOT/tmp" 2>/dev/null || true
rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

echo "[*] Installing postmarketOS v25.06 packages (postmarketos-base, postmarketos-ui-console, fastfetch)..."
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"

chroot "$CHROOT" /bin/sh -e -c "
apk update
apk fix --reinstall postmarketos-base
apk add --no-cache \
    postmarketos-base-openrc \
    postmarketos-release-upgrade \
    !postmarketos-base-mesa \
    !postmarketos-base-nftables \
    fastfetch \
    htop \
    nano \
    curl \
    jq \
    tree
"

umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true

# Ensure msm-firmware-loader services stay disabled so direct /lib/firmware is used
rm -f "$CHROOT/etc/runlevels/sysinit/msm-firmware-loader" \
      "$CHROOT/etc/runlevels/boot/msm-firmware-loader-unpack" \
      "$CHROOT/etc/runlevels/default/dnsmasq" 2>/dev/null || true

# Restore UZ801 /etc/fstab (postmarketos-base overwrites /etc/fstab with template)
cat > "$CHROOT/etc/fstab" << 'EOF'
/dev/mmcblk0p13    /boot    ext2    ro,noatime          0 0
/dev/mmcblk0p14    /        ext4    rw,noatime,commit=1 0 0
EOF

echo "$HOST_NAME" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" << EOF
127.0.0.1 localhost ${HOST_NAME}
::1       localhost ip6-localhost ip6-loopback
EOF

chroot "$CHROOT" /bin/sh -e -c "
echo 'root:${PASSWORD}' | chpasswd
echo '${USERNAME}:${PASSWORD}' | chpasswd 2>/dev/null || true
"

echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" >> "$CHROOT/etc/sudoers"

# Ensure latest usb-gadget script is installed
install -Dm0755 configs/usb-gadget/usb-gadget.sh "$CHROOT/usr/sbin/usb-gadget"
ln -sf /usr/sbin/usb-gadget "$CHROOT/usr/bin/usb-gadget"

# Ensure NetworkManager WiFi & LTE profiles and DNS config
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

# Add 4G LTE autoconnect helper in /etc/local.d/uz801-lte.start
mkdir -p "$CHROOT/etc/local.d"
cat > "$CHROOT/etc/local.d/uz801-lte.start" << 'EOF'
#!/bin/sh
(
    for i in $(seq 1 30); do
        ip link set usb0 up 2>/dev/null || true
        if mmcli -m 0 >/dev/null 2>&1; then
            mmcli -m 0 --set-power-state-on >/dev/null 2>&1 || true
            mmcli -m 0 -e >/dev/null 2>&1 || true
            if nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -q "^wwan0qmi0:disconnected"; then
                nmcli connection up lte >/dev/null 2>&1 || true
            fi
        fi
        if ip addr show wwan0 2>/dev/null | grep -q "inet "; then
            break
        fi
        sleep 5
    done
) &
EOF
chmod 0755 "$CHROOT/etc/local.d/uz801-lte.start"
ln -sf /etc/init.d/local "$CHROOT/etc/runlevels/default/local" 2>/dev/null || true

echo "[*] Creating postmarketOS v25.06 ext4 rootfs image (512 MiB)..."
ROOT_RAW="$STAGING/pmos-rootfs.raw"
truncate -s $((512 * 1024 * 1024)) "$ROOT_RAW"
mkfs.ext4 -F -d "$CHROOT" "$ROOT_RAW" >/dev/null 2>&1
gzip -c "$ROOT_RAW" > "$OUT_DIR/pmos-rootfs.img.gz"

echo "[+] postmarketOS v25.06 rootfs image created:"
ls -lh "$OUT_DIR/pmos-rootfs.img.gz"
