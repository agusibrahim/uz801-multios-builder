#!/bin/bash
set -euo pipefail

[ -f ./variables.env ] && source ./variables.env

WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801-ubuntu}"
USERNAME="${USERNAME:-user}"
PASSWORD="${PASSWORD:-changeme}"
WIFI_SSID="${WIFI_SSID:-Kaylaa}"
WIFI_PASS="${WIFI_PASS:-agus00000}"

UBUNTU_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz"
UBUNTU_TAR="$OUT_DIR/ubuntu-base-24.04.5-base-arm64.tar.gz"

trap 'umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true; rm -rf "$STAGING"' EXIT INT TERM

mkdir -p "$OUT_DIR" "$CHROOT"

if [ ! -f "$UBUNTU_TAR" ]; then
    echo "[*] Downloading Ubuntu Base 24.04.5 LTS arm64 rootfs..."
    wget -q --show-progress "$UBUNTU_URL" -O "$UBUNTU_TAR"
fi

echo "[*] Extracting Ubuntu Base 24.04.5 LTS rootfs..."
tar -xzf "$UBUNTU_TAR" -C "$CHROOT"

chmod 1777 "$CHROOT/tmp" "$CHROOT/var/tmp" 2>/dev/null || true
rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

echo "[*] Installing minimal Ubuntu 24.04 LTS packages (systemd, NetworkManager, ModemManager, SSH)..."
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"

chroot "$CHROOT" /bin/bash -e -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    systemd \
    systemd-sysv \
    systemd-timesyncd \
    udev \
    kmod \
    dbus \
    network-manager \
    modemmanager \
    libqmi-utils \
    dnsmasq-base \
    wpasupplicant \
    wireless-regdb \
    iw \
    openssh-server \
    sudo \
    htop \
    nano \
    neofetch \
    psmisc \
    iproute2 \
    iputils-ping \
    curl \
    ca-certificates \
    e2fsprogs \
    passwd
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
ln -sf /usr/sbin/usb-gadget "$CHROOT/usr/bin/usb-gadget"
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

chroot "$CHROOT" /bin/bash -e -c "
echo 'root:${PASSWORD}' | chpasswd
useradd -m -G sudo,adm -s /bin/bash ${USERNAME} 2>/dev/null || true
echo '${USERNAME}:${PASSWORD}' | chpasswd
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

# Allow NetworkManager to manage all ethernet/wifi/gsm devices on Ubuntu and write /etc/resolv.conf directly
mkdir -p "$CHROOT/etc/NetworkManager/conf.d"
cat > "$CHROOT/etc/NetworkManager/conf.d/10-globally-managed-devices.conf" << 'EOF'
[main]
dns=default
rc-manager=file

[keyfile]
unmanaged-devices=interface-name:usb0
EOF

cat > "$CHROOT/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

mkdir -p "$CHROOT/etc/apt/apt.conf.d"
cat > "$CHROOT/etc/apt/apt.conf.d/99-uz801-fast" << 'EOF'
Acquire::ForceIPv4 "true";
Acquire::Languages "none";
Acquire::GzipIndexes "true";
APT::Install-Recommends "false";
EOF

echo "[*] Configuring NetworkManager (WiFi & 4G LTE)..."
mkdir -p "$CHROOT/etc/NetworkManager/system-connections"
cp configs/network-manager/wlan.nmconnection "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
sed -i "s/__SSID__/${WIFI_SSID}/g" "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
sed -i "s/__PASS__/${WIFI_PASS}/g" "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
cp configs/network-manager/lte.nmconnection "$CHROOT/etc/NetworkManager/system-connections/lte.nmconnection"
chmod 0600 "$CHROOT/etc/NetworkManager/system-connections/"*.nmconnection

echo "[*] Configuring systemd services & volatile journald..."
mkdir -p "$CHROOT/etc/systemd/journald.conf.d"
cat > "$CHROOT/etc/systemd/journald.conf.d/volatile.conf" << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=8M
EOF

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
systemctl disable systemd-networkd.service systemd-resolved.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
systemctl enable systemd-timesyncd.service NetworkManager.service ModemManager.service wpa_supplicant.service ssh.service rmtfs.service uz801-init.service
"

# Trim docs/locales/manpages
rm -rf "$CHROOT/usr/share/man/"* "$CHROOT/usr/share/doc/"* "$CHROOT/usr/share/locale/"* 2>/dev/null || true

echo "[*] Creating Ubuntu 24.04.5 LTS ext4 rootfs image (512 MiB)..."
ROOT_RAW="$STAGING/ubuntu-rootfs.raw"
truncate -s $((512 * 1024 * 1024)) "$ROOT_RAW"
mkfs.ext4 -F -d "$CHROOT" "$ROOT_RAW" >/dev/null 2>&1
gzip -c "$ROOT_RAW" > "$OUT_DIR/ubuntu-rootfs.img.gz"

echo "[+] Ubuntu 24.04.5 LTS rootfs image created:"
ls -lh "$OUT_DIR/ubuntu-rootfs.img.gz"
