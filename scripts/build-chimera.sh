#!/bin/bash
set -euo pipefail

[ -f ./variables.env ] && source ./variables.env

WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801-chimera}"
USERNAME="${USERNAME:-user}"
PASSWORD="${PASSWORD:-changeme}"
WIFI_SSID="${WIFI_SSID:-Kaylaa}"
WIFI_PASS="${WIFI_PASS:-agus00000}"

CHIMERA_URL="https://repo.chimera-linux.org/live/latest/chimera-linux-aarch64-ROOTFS-20251220-bootstrap.tar.gz"
CHIMERA_TAR="$OUT_DIR/chimera-bootstrap.tar.gz"

trap 'umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true; rm -rf "$STAGING"' EXIT INT TERM

mkdir -p "$OUT_DIR" "$CHROOT"

if [ ! -f "$CHIMERA_TAR" ]; then
    echo "[*] Downloading Chimera Linux aarch64 bootstrap rootfs..."
    wget -q --show-progress "$CHIMERA_URL" -O "$CHIMERA_TAR"
fi

echo "[*] Extracting Chimera Linux rootfs..."
tar -xzf "$CHIMERA_TAR" -C "$CHROOT"

chmod 1777 "$CHROOT/tmp" 2>/dev/null || true
rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

echo "[*] Installing Chimera Linux packages (dinit, FreeBSD userland, NetworkManager, ModemManager, SSH)..."
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"

chroot "$CHROOT" /bin/sh -e -c "
apk update
apk add --no-interactive !base-man !base-locale \
    dinit \
    dinit-chimera \
    udev \
    kmod \
    dbus \
    polkit \
    networkmanager \
    modemmanager \
    libqmi \
    wpa_supplicant \
    wireless-regdb \
    iw \
    openssh \
    dnsmasq \
    bash \
    fastfetch \
    htop \
    nano \
    curl \
    iproute2 \
    iputils \
    e2fsprogs \
    shadow \
    procps \
    psmisc \
    util-linux-mount \
    util-linux-mkfs
rm -rf /var/cache/apk/*
"

umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true

echo "[*] Copying kernel modules (6.12.1-msm8916), firmware, rmtfs, and adbd..."
mkdir -p "$STAGING/alpine"
tar -xzf "$OUT_DIR/alpine-rootfs.tgz" -C "$STAGING/alpine" \
    ./lib \
    ./usr/lib \
    ./usr/sbin/rmtfs

mkdir -p "$CHROOT/usr/lib/modules" "$CHROOT/usr/lib/firmware"
rm -f "$CHROOT/usr/lib/firmware/regulatory.db"*
cp -af "$STAGING/alpine/lib/modules/"* "$CHROOT/usr/lib/modules/"
cp -af "$STAGING/alpine/lib/firmware/"* "$CHROOT/usr/lib/firmware/"

# Chimera uses musl natively; copy libqrtr.so.1, libgcc_s.so.1, and libcrypto.so.1.1 for rmtfs & adbd
cp -a "$STAGING/alpine/usr/lib/libqrtr.so.1"* "$CHROOT/usr/lib/"
cp -a "$STAGING/alpine/usr/lib/libgcc_s.so.1" "$CHROOT/usr/lib/"
cp -a configs/adb/libcrypto.so.1.1 "$CHROOT/usr/lib/libcrypto.so.1.1"
install -Dm0755 "$STAGING/alpine/usr/sbin/rmtfs" "$CHROOT/usr/bin/rmtfs"
install -Dm0755 configs/adb/adbd "$CHROOT/usr/bin/adbd"
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

install -Dm0755 configs/usb-gadget/usb-gadget.sh "$CHROOT/usr/sbin/usb-gadget"
cat > "$CHROOT/etc/usb-gadget.conf" << 'EOF'
USE_NCM=1
ENABLE_OTG=0
EOF

echo "[*] Configuring users, SSH, hostname, and fstab..."
echo "$HOST_NAME" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" << EOF
127.0.0.1 localhost ${HOST_NAME}
::1       localhost ip6-localhost ip6-loopback
EOF

chroot "$CHROOT" /bin/sh -e -c "
echo 'root:${PASSWORD}' | chpasswd -c SHA512
useradd -m -G wheel -s /bin/bash ${USERNAME} 2>/dev/null || true
echo '${USERNAME}:${PASSWORD}' | chpasswd -c SHA512
chsh -s /bin/bash root 2>/dev/null || true
"

mkdir -p "$CHROOT/etc/ssh/sshd_config.d"
cat > "$CHROOT/etc/ssh/sshd_config.d/99-uz801.conf" << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
if [ -f "$CHROOT/etc/ssh/sshd_config" ]; then
    sed -i 's/^#*\s*PermitRootLogin.*/PermitRootLogin yes/' "$CHROOT/etc/ssh/sshd_config"
    sed -i 's/^#*\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$CHROOT/etc/ssh/sshd_config"
else
    cat > "$CHROOT/etc/ssh/sshd_config" << 'EOF'
Include /etc/ssh/sshd_config.d/*.conf
PermitRootLogin yes
PasswordAuthentication yes
Subsystem sftp /usr/lib/ssh/sftp-server
EOF
fi

cat > "$CHROOT/etc/fstab" << 'EOF'
/dev/mmcblk0p13    /boot    ext2    ro,noatime          0 0
/dev/mmcblk0p14    /        ext4    rw,noatime,commit=1 0 0
EOF

echo "[*] Configuring NetworkManager (WiFi & 4G LTE)..."
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

rm -f "$CHROOT/etc/resolv.conf"
cat > "$CHROOT/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

echo "[*] Configuring dinit services & /etc/rc.local..."
cat > "$CHROOT/etc/dinit.d/rmtfs" << 'EOF'
type = process
command = /usr/bin/rmtfs -P -r -s
smooth-recovery = true
before: modemmanager
depends-on: local.target
EOF

mkdir -p "$CHROOT/etc/dinit.d/boot.d"
ln -sf /usr/lib/dinit.d/udevd "$CHROOT/etc/dinit.d/boot.d/udevd"
ln -sf /usr/lib/dinit.d/dbus "$CHROOT/etc/dinit.d/boot.d/dbus"
ln -sf /usr/lib/dinit.d/polkitd "$CHROOT/etc/dinit.d/boot.d/polkitd"
ln -sf /etc/dinit.d/rmtfs "$CHROOT/etc/dinit.d/boot.d/rmtfs"
ln -sf /usr/lib/dinit.d/modemmanager "$CHROOT/etc/dinit.d/boot.d/modemmanager"
ln -sf /usr/lib/dinit.d/networkmanager "$CHROOT/etc/dinit.d/boot.d/networkmanager"
ln -sf /usr/lib/dinit.d/sshd "$CHROOT/etc/dinit.d/boot.d/sshd"

cat > "$CHROOT/etc/rc.local" << 'EOF'
#!/bin/sh
if [ ! -f /var/lib/expand-rootfs.done ]; then
    resize2fs /dev/mmcblk0p14 >/dev/null 2>&1 || true
    mkdir -p /var/lib
    touch /var/lib/expand-rootfs.done
    sync
fi

if [ -b /dev/zram0 ] || modprobe zram 2>/dev/null; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo 256M > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1 && swapon /dev/zram0 2>/dev/null || true
fi

/usr/sbin/usb-gadget start >/dev/null 2>&1 || true

(
    TIME_SYNCED=0
    for i in $(seq 1 30); do
        ip link set usb0 up 2>/dev/null || true
        if [ "$TIME_SYNCED" = 0 ]; then
            HTTP_DATE=$(curl -sI --max-time 3 http://1.1.1.1 2>/dev/null | sed -n "s/^[Dd]ate: //p" | tr -d "\r")
            if [ -n "$HTTP_DATE" ]; then
                (date -u -s "$HTTP_DATE" || date -u -f "%a, %d %b %Y %H:%M:%S GMT" "$HTTP_DATE") >/dev/null 2>&1 && TIME_SYNCED=1
            fi
        fi
        if mmcli -m 0 >/dev/null 2>&1; then
            mmcli -m 0 --set-power-state-on >/dev/null 2>&1 || true
            mmcli -m 0 -e >/dev/null 2>&1 || true
            if nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -q "^wwan0qmi0:disconnected"; then
                nmcli connection up lte >/dev/null 2>&1 || true
            fi
        fi
        if [ "$TIME_SYNCED" = 1 ] && ip addr show wwan0 2>/dev/null | grep -q "inet "; then
            break
        fi
        sleep 5
    done
) &
exit 0
EOF
chmod 0755 "$CHROOT/etc/rc.local"

echo "[*] Creating Chimera Linux ext4 rootfs image (512 MiB)..."
ROOT_RAW="$STAGING/chimera-rootfs.raw"
truncate -s $((512 * 1024 * 1024)) "$ROOT_RAW"
mkfs.ext4 -F -d "$CHROOT" "$ROOT_RAW" >/dev/null 2>&1
gzip -c "$ROOT_RAW" > "$OUT_DIR/chimera-rootfs.img.gz"

echo "[+] Chimera Linux rootfs image created:"
ls -lh "$OUT_DIR/chimera-rootfs.img.gz"
