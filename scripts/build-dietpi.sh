#!/bin/bash
set -euo pipefail

[ -f ./variables.env ] && source ./variables.env

WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801-dietpi}"
USERNAME="${USERNAME:-user}"
PASSWORD="${PASSWORD:-changeme}"
WIFI_SSID="${WIFI_SSID:-Kaylaa}"
WIFI_PASS="${WIFI_PASS:-agus00000}"

DIETPI_XZ="$OUT_DIR/DietPi_Container-ARMv8-Bookworm_network.img.xz"
DIETPI_IMG="$OUT_DIR/dietpi-base.img"

trap 'umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" "$STAGING/mnt" 2>/dev/null || true; rm -rf "$STAGING"' EXIT INT TERM

mkdir -p "$OUT_DIR" "$CHROOT" "$STAGING/mnt"

if [ ! -f "$DIETPI_IMG" ]; then
    echo "[*] Extracting DietPi base disk image..."
    xz -dc "$DIETPI_XZ" > "$DIETPI_IMG"
fi

echo "[*] Copying DietPi rootfs from partition 1..."
mount -o loop,ro,offset=$((2048 * 512)) "$DIETPI_IMG" "$STAGING/mnt"
cp -a "$STAGING/mnt/." "$CHROOT/"
umount "$STAGING/mnt"
rm -rf "$CHROOT/lost+found"

rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
chmod 1777 "$CHROOT/tmp" "$CHROOT/var/tmp" 2>/dev/null || true

echo "[*] Installing hardware support packages (udev, kmod, NetworkManager, ModemManager)..."
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"

chroot "$CHROOT" /bin/bash -e -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    udev \
    kmod \
    dbus \
    systemd-timesyncd \
    network-manager \
    modemmanager \
    libqmi-utils \
    dnsmasq \
    wpasupplicant \
    wireless-regdb \
    iw \
    sudo \
    htop \
    nano \
    psmisc \
    iproute2 \
    iputils-ping \
    ca-certificates
apt-get clean
rm -rf /var/lib/apt/lists/*
"

umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true

echo "[*] Copying kernel modules (6.12.1-msm8916), firmware, and isolated musl runtime for rmtfs/adbd..."
mkdir -p "$STAGING/alpine"
tar -xzf "$OUT_DIR/alpine-rootfs.tgz" -C "$STAGING/alpine" \
    ./lib \
    ./usr/lib \
    ./usr/sbin/rmtfs

mkdir -p "$CHROOT/usr/lib/modules" "$CHROOT/usr/lib/firmware" "$CHROOT/usr/lib/musl"
rm -f "$CHROOT/usr/lib/firmware/regulatory.db"*
cp -af "$STAGING/alpine/lib/modules/"* "$CHROOT/usr/lib/modules/"
cp -af "$STAGING/alpine/lib/firmware/"* "$CHROOT/usr/lib/firmware/"

# Isolated musl runtime (/lib/ld-musl-aarch64.so.1 + /usr/lib/musl) for adbd & rmtfs
cp -a "$STAGING/alpine/lib/ld-musl-aarch64.so.1" "$CHROOT/usr/lib/ld-musl-aarch64.so.1"
cp -a "$STAGING/alpine/lib/ld-musl-aarch64.so.1" "$CHROOT/usr/lib/musl/libc.musl-aarch64.so.1"
cp -a "$STAGING/alpine/lib/ld-musl-aarch64.so.1" "$CHROOT/usr/lib/musl/libc.so"
cp -a "$STAGING/alpine/lib/libz.so.1"* "$CHROOT/usr/lib/musl/" 2>/dev/null || cp -a "$STAGING/alpine/usr/lib/libz.so.1"* "$CHROOT/usr/lib/musl/"
cp -a "$STAGING/alpine/usr/lib/libgcc_s.so.1" "$CHROOT/usr/lib/musl/"
cp -a "$STAGING/alpine/lib/libudev.so.1"* "$CHROOT/usr/lib/musl/" 2>/dev/null || cp -a "$STAGING/alpine/usr/lib/libudev.so.1"* "$CHROOT/usr/lib/musl/"
cp -a "$STAGING/alpine/usr/lib/libqrtr.so.1"* "$CHROOT/usr/lib/musl/"
cp -a configs/adb/libcrypto.so.1.1 "$CHROOT/usr/lib/musl/libcrypto.so.1.1"
echo "/usr/lib/musl" > "$CHROOT/etc/ld-musl-aarch64.path"

install -Dm0755 "$STAGING/alpine/usr/sbin/rmtfs" "$CHROOT/usr/bin/rmtfs"
install -Dm0755 configs/adb/adbd "$CHROOT/usr/bin/adbd"
[ -f configs/dashboard/uz801-dashboard ] && install -Dm0755 configs/dashboard/uz801-dashboard "$CHROOT/usr/bin/uz801-dashboard"
install -Dm0644 configs/adb/adb_profile "$CHROOT/etc/adb_profile"

mkdir -p "$CHROOT/system/bin"
cat > "$CHROOT/system/bin/sh" <<'SHWRAP'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/boot/dietpi
export HOME=/root
export TERM=${TERM:-xterm-256color}
exec /bin/bash "$@"
SHWRAP
chmod 0755 "$CHROOT/system/bin/sh"

install -Dm0755 configs/usb-gadget/usb-gadget.sh "$CHROOT/usr/sbin/usb-gadget"
ln -sf /usr/sbin/usb-gadget "$CHROOT/usr/bin/usb-gadget"
cat > "$CHROOT/etc/usb-gadget.conf" << 'EOF'
USE_NCM=1
ENABLE_OTG=0
EOF

echo "[*] Configuring DietPi stage, hardware model, users, SSH, hostname, and fstab..."
echo "2" > "$CHROOT/boot/dietpi/.install_stage"
echo "21" > "$CHROOT/etc/.dietpi_hw_model_identifier"
sed -i "s/^CONFIG_NTP_MODE=.*/CONFIG_NTP_MODE=2/" "$CHROOT/boot/dietpi.txt" 2>/dev/null || true
rm -f "$CHROOT/etc/systemd/system/multi-user.target.wants/dietpi-firstboot.service"
rm -f "$CHROOT/etc/systemd/system/multi-user.target.wants/networking.service"

echo "$HOST_NAME" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" << EOF
127.0.0.1 localhost ${HOST_NAME}
::1       localhost ip6-localhost ip6-loopback
EOF

chroot "$CHROOT" /bin/bash -e -c "
echo 'root:${PASSWORD}' | chpasswd
echo 'dietpi:${PASSWORD}' | chpasswd 2>/dev/null || true
useradd -m -G sudo,netdev -s /bin/bash ${USERNAME} 2>/dev/null || true
echo '${USERNAME}:${PASSWORD}' | chpasswd
"

mkdir -p "$CHROOT/etc/sudoers.d"
echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "$CHROOT/etc/sudoers.d/${USERNAME}"
chmod 0440 "$CHROOT/etc/sudoers.d/${USERNAME}"

# Keep /boot on rootfs so /boot/dietpi is preserved and accessible
cat > "$CHROOT/etc/fstab" << 'EOF'
/dev/mmcblk0p14    /           ext4     rw,noatime,commit=1                     0 0
tmpfs              /tmp        tmpfs    noatime,lazytime,nodev,nosuid,mode=1777 0 0
tmpfs              /var/log    tmpfs    size=50M,noatime,lazytime,nodev,nosuid  0 0
EOF

echo "[*] Configuring NetworkManager (WiFi & 4G LTE)..."
mkdir -p "$CHROOT/etc/NetworkManager/system-connections"
cp configs/network-manager/wlan.nmconnection "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
sed -i "s/__SSID__/${WIFI_SSID}/g" "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
sed -i "s/__PASS__/${WIFI_PASS}/g" "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
cp configs/network-manager/lte.nmconnection "$CHROOT/etc/NetworkManager/system-connections/lte.nmconnection"
chmod 0600 "$CHROOT/etc/NetworkManager/system-connections/"*.nmconnection

echo "[*] Configuring systemd services for UZ801..."
cat > "$CHROOT/etc/systemd/system/rmtfs.service" << 'EOF'
[Unit]
Description=Qualcomm Remote Filesystem Service
Before=ModemManager.service

[Service]
ExecStart=/usr/bin/rmtfs -P -r -s
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$CHROOT/usr/local/sbin"
cat > "$CHROOT/usr/local/sbin/uz801-init.sh" << 'EOF'
#!/bin/bash
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
                date -u -s "$HTTP_DATE" >/dev/null 2>&1 && TIME_SYNCED=1
                systemctl restart systemd-timesyncd.service 2>/dev/null || true
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
EOF
chmod 0755 "$CHROOT/usr/local/sbin/uz801-init.sh"

cat > "$CHROOT/etc/systemd/system/uz801-init.service" << 'EOF'
[Unit]
Description=UZ801 USB Gadget, ZRAM, and LTE Autoconnect Init
After=systemd-udevd.service local-fs.target
Before=NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
KillMode=none
ExecStart=/usr/local/sbin/uz801-init.sh

[Install]
WantedBy=multi-user.target
EOF

chroot "$CHROOT" /bin/bash -e -c "
systemctl disable dnsmasq.service networking.service 2>/dev/null || true
systemctl enable systemd-timesyncd.service NetworkManager.service ModemManager.service wpa_supplicant.service dropbear.service rmtfs.service uz801-init.service
"

rm -rf "$CHROOT/usr/share/man/"* "$CHROOT/usr/share/doc/"* "$CHROOT/usr/share/locale/"* 2>/dev/null || true

echo "[*] Creating DietPi ext4 rootfs image (512 MiB)..."
ROOT_RAW="$STAGING/dietpi-rootfs.raw"
truncate -s $((512 * 1024 * 1024)) "$ROOT_RAW"
mkfs.ext4 -F -d "$CHROOT" "$ROOT_RAW" >/dev/null 2>&1
gzip -c "$ROOT_RAW" > "$OUT_DIR/dietpi-rootfs.img.gz"

echo "[+] DietPi rootfs image created:"
ls -lh "$OUT_DIR/dietpi-rootfs.img.gz"
