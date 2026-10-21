#!/bin/bash
set -euo pipefail

[ -f ./variables.env ] && source ./variables.env

WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801-void}"
USERNAME="${USERNAME:-user}"
PASSWORD="${PASSWORD:-changeme}"
WIFI_SSID="${WIFI_SSID:-Kaylaa}"
WIFI_PASS="${WIFI_PASS:-agus00000}"

VOID_URL="https://repo-default.voidlinux.org/live/current/void-aarch64-musl-ROOTFS-20250202.tar.xz"
VOID_TAR="$OUT_DIR/void-aarch64-musl-base.tar.xz"

trap 'rm -rf "$STAGING"' EXIT INT TERM

mkdir -p "$OUT_DIR" "$CHROOT"

if [ ! -f "$VOID_TAR" ]; then
    echo "[*] Downloading Void Linux aarch64-musl rootfs..."
    wget -q --show-progress "$VOID_URL" -O "$VOID_TAR"
fi

echo "[*] Extracting Void Linux base rootfs..."
tar xJf "$VOID_TAR" -C "$CHROOT"

cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

echo "[*] Updating xbps and installing packages in Void Linux chroot..."
chroot "$CHROOT" /bin/sh -e -c "
xbps-install -Syu xbps
xbps-install -Sy \
    NetworkManager \
    ModemManager \
    libqmi \
    dnsmasq \
    dbus \
    chrony \
    htop \
    nano \
    iw \
    wireless-regdb \
    wireguard-tools \
    kmod \
    psmisc \
    fastfetch || xbps-install -Sy \
    NetworkManager \
    ModemManager \
    libqmi \
    dnsmasq \
    dbus \
    chrony \
    htop \
    nano \
    iw \
    wireless-regdb \
    wireguard-tools \
    kmod \
    psmisc
xbps-remove -ROo
rm -rf /var/cache/xbps/*
"

echo "[*] Copying kernel modules (6.12.1-msm8916), firmware, and rmtfs from Alpine rootfs..."
mkdir -p "$STAGING/alpine"
tar -xzf "$OUT_DIR/alpine-rootfs.tgz" -C "$STAGING/alpine" \
    ./lib/modules \
    ./lib/firmware \
    ./usr/sbin/rmtfs \
    ./usr/lib/libqrtr.so.1 \
    ./usr/lib/libqrtr.so.1.1

mkdir -p "$CHROOT/usr/lib/modules" "$CHROOT/usr/lib/firmware"
cp -a "$STAGING/alpine/lib/modules/"* "$CHROOT/usr/lib/modules/"
cp -a "$STAGING/alpine/lib/firmware/"* "$CHROOT/usr/lib/firmware/"
install -Dm0755 "$STAGING/alpine/usr/sbin/rmtfs" "$CHROOT/usr/bin/rmtfs"
cp -a "$STAGING/alpine/usr/lib/libqrtr.so.1"* "$CHROOT/usr/lib/"

echo "[*] Installing adbd and USB Gadget..."
install -Dm0755 configs/adb/adbd "$CHROOT/usr/bin/adbd"
install -Dm0755 configs/adb/libcrypto.so.1.1 "$CHROOT/usr/lib/libcrypto.so.1.1"
install -Dm0644 configs/adb/adb_profile "$CHROOT/etc/adb_profile"
mkdir -p "$CHROOT/system/bin"
cat > "$CHROOT/system/bin/sh" <<'SHWRAP'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=${TERM:-xterm-256color}
exec /bin/bash "$@"
SHWRAP
chmod 0755 "$CHROOT/system/bin/sh"

install -Dm0755 configs/usb-gadget/usb-gadget.sh "$CHROOT/usr/bin/usb-gadget"
cat > "$CHROOT/etc/usb-gadget.conf" << 'EOF'
USE_NCM=1
ENABLE_OTG=0
EOF

echo "[*] Configuring users, SSH, hostname, and fstab..."
echo "$HOST_NAME" > "$CHROOT/etc/hostname"
sed -i "/127.0.0.1/ s/$/ ${HOST_NAME}/" "$CHROOT/etc/hosts"

chroot "$CHROOT" /bin/sh -e -c "
echo 'root:${PASSWORD}' | chpasswd -c SHA512
useradd -m -G wheel,network,audio,video -s /bin/bash ${USERNAME} 2>/dev/null || true
echo '${USERNAME}:${PASSWORD}' | chpasswd -c SHA512
"

mkdir -p "$CHROOT/etc/sudoers.d"
echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "$CHROOT/etc/sudoers.d/${USERNAME}"
chmod 0440 "$CHROOT/etc/sudoers.d/${USERNAME}"

sed -i 's/^#*\s*PermitRootLogin.*/PermitRootLogin yes/' "$CHROOT/etc/ssh/sshd_config"
sed -i 's/^#*\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$CHROOT/etc/ssh/sshd_config"

cat > "$CHROOT/etc/fstab" << 'EOF'
/dev/mmcblk0p13    /boot    ext2    ro,noatime          0 0
/dev/mmcblk0p14    /        ext4    rw,noatime,commit=1 0 0
EOF

echo "[*] Configuring NetworkManager (WiFi & 4G LTE)..."
mkdir -p "$CHROOT/etc/NetworkManager/system-connections"
cp configs/network-manager/wlan.nmconnection "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
sed -i "s/__SSID__/${WIFI_SSID}/g" "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
sed -i "s/__PASS__/${WIFI_PASS}/g" "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
cp configs/network-manager/lte.nmconnection "$CHROOT/etc/NetworkManager/system-connections/lte.nmconnection"
chmod 0600 "$CHROOT/etc/NetworkManager/system-connections/"*.nmconnection

echo "[*] Configuring runit services..."
mkdir -p "$CHROOT/etc/sv/rmtfs"
cat > "$CHROOT/etc/sv/rmtfs/run" << 'EOF'
#!/bin/sh
exec /usr/bin/rmtfs -P -r -s
EOF
chmod 0755 "$CHROOT/etc/sv/rmtfs/run"

mkdir -p "$CHROOT/etc/sv/ModemManager"
cat > "$CHROOT/etc/sv/ModemManager/run" << 'EOF'
#!/bin/sh
sv check dbus >/dev/null || exit 1
exec /usr/bin/ModemManager
EOF
chmod 0755 "$CHROOT/etc/sv/ModemManager/run"

cat > "$CHROOT/etc/sv/wpa_supplicant/run" << 'EOF'
#!/bin/sh
sv check dbus >/dev/null || exit 1
exec /usr/bin/wpa_supplicant -u
EOF
chmod 0755 "$CHROOT/etc/sv/wpa_supplicant/run"

# Simplify 03-filesystems.sh for embedded root=/dev/mmcblk0p14 rw boot (never drop to emergency_shell)
cat > "$CHROOT/etc/runit/core-services/03-filesystems.sh" << 'EOF'
msg "Mounting rootfs read-write..."
mount -o remount,rw / 2>/dev/null || true
msg "Mounting all non-network filesystems..."
mount -a -t "nosysfs,nonfs,nonfs4,nosmbfs,nocifs" -O no_netdev 2>/dev/null || true
EOF

# Clean default runit services and enable required ones
rm -f "$CHROOT/etc/runit/runsvdir/default/"*
for svc in udevd dbus rmtfs wpa_supplicant NetworkManager ModemManager sshd chronyd agetty-console; do
    if [ -d "$CHROOT/etc/sv/$svc" ]; then
        ln -sf "/etc/sv/$svc" "$CHROOT/etc/runit/runsvdir/default/$svc"
    fi
done

# Configure serial console agetty on ttyMSM0
mkdir -p "$CHROOT/etc/sv/agetty-ttyMSM0"
cat > "$CHROOT/etc/sv/agetty-ttyMSM0/run" << 'EOF'
#!/bin/sh
exec agetty -a root -L 115200 ttyMSM0 vt100
EOF
chmod 0755 "$CHROOT/etc/sv/agetty-ttyMSM0/run"
ln -sf "/etc/sv/agetty-ttyMSM0" "$CHROOT/etc/runit/runsvdir/default/agetty-ttyMSM0"

# Configure /etc/rc.local (runs in stage 2 right before runsvdir)
cat > "$CHROOT/etc/rc.local" << 'EOF'
#!/bin/sh
# Expand rootfs on first boot
if [ ! -f /var/lib/expand-rootfs.done ]; then
    resize2fs /dev/mmcblk0p14 >/dev/null 2>&1 || true
    mkdir -p /var/lib
    touch /var/lib/expand-rootfs.done
    sync
fi

# Configure 256MB zram swap
if [ -b /dev/zram0 ] || modprobe zram 2>/dev/null; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo 256M > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1 && swapon /dev/zram0 2>/dev/null || true
fi

# Start USB Gadget (NCM 192.168.42.1/24 + ADB)
/usr/sbin/usb-gadget start >/dev/null 2>&1 || true

# Background helper to ensure 4G LTE connects once ModemManager registers SIM
(
    for i in $(seq 1 30); do
        if mmcli -m 0 >/dev/null 2>&1; then
            mmcli -m 0 --set-power-state-on >/dev/null 2>&1 || true
            mmcli -m 0 -e >/dev/null 2>&1 || true
            if ! ip addr show wwan0 2>/dev/null | grep -q "inet "; then
                nmcli connection up lte >/dev/null 2>&1 || true
            else
                break
            fi
        fi
        sleep 3
    done
) &
EOF
chmod 0755 "$CHROOT/etc/rc.local"

echo "[*] Creating Void Linux ext4 rootfs image (512 MiB)..."
ROOT_RAW="$STAGING/void-rootfs.raw"
truncate -s $((512 * 1024 * 1024)) "$ROOT_RAW"
mkfs.ext4 -F -d "$CHROOT" "$ROOT_RAW" >/dev/null 2>&1
gzip -c "$ROOT_RAW" > "$OUT_DIR/void-rootfs.img.gz"

echo "[+] Void Linux rootfs image created:"
ls -lh "$OUT_DIR/void-rootfs.img.gz"
