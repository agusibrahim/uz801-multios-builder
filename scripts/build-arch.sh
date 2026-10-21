#!/bin/bash
set -euo pipefail

[ -f ./variables.env ] && source ./variables.env

WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801-arch}"
USERNAME="${USERNAME:-user}"
PASSWORD="${PASSWORD:-changeme}"
WIFI_SSID="${WIFI_SSID:-Kaylaa}"
WIFI_PASS="${WIFI_PASS:-agus00000}"

ARCH_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
ARCH_TAR="$OUT_DIR/ArchLinuxARM-aarch64-latest.tar.gz"

trap 'umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true; rm -rf "$STAGING"' EXIT INT TERM

mkdir -p "$OUT_DIR" "$CHROOT"

if [ ! -f "$ARCH_TAR" ]; then
    echo "[*] Downloading Arch Linux ARM aarch64 rootfs..."
    wget -q --show-progress "$ARCH_URL" -O "$ARCH_TAR"
fi

echo "[*] Extracting Arch Linux ARM base rootfs..."
tar xpf "$ARCH_TAR" -C "$CHROOT" 2>/dev/null || true

rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# Disable CheckSpace and enable ParallelDownloads in pacman.conf
sed -i 's/^CheckSpace/#CheckSpace/' "$CHROOT/etc/pacman.conf"
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' "$CHROOT/etc/pacman.conf"

echo "[*] Initializing pacman keys, removing default kernel/firmware, and installing packages..."
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"

chroot "$CHROOT" /bin/bash -e -c "
pacman -Rdd --noconfirm \$(pacman -Qq | grep -E '^linux-aarch64|^linux-firmware|^mkinitcpio|^firmware-') 2>/dev/null || true
rm -rf /boot/* /usr/lib/modules/* /usr/lib/firmware/*
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm --needed \
    networkmanager \
    modemmanager \
    libqmi \
    dnsmasq \
    wpa_supplicant \
    wireless-regdb \
    iw \
    chrony \
    sudo \
    htop \
    nano \
    fastfetch \
    psmisc \
    wireguard-tools
gpgconf --kill all 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/*
"

umount -l "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true

echo "[*] Copying kernel modules (6.12.1-msm8916), firmware, and isolated musl runtime for rmtfs/adbd..."
mkdir -p "$STAGING/alpine"
tar -xzf "$OUT_DIR/alpine-rootfs.tgz" -C "$STAGING/alpine" \
    ./lib \
    ./usr/lib \
    ./usr/sbin/rmtfs

mkdir -p "$CHROOT/usr/lib/modules" "$CHROOT/usr/lib/firmware" "$CHROOT/usr/lib/musl"
cp -a "$STAGING/alpine/lib/modules/"* "$CHROOT/usr/lib/modules/"
cp -a "$STAGING/alpine/lib/firmware/"* "$CHROOT/usr/lib/firmware/"

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
sed -i "/127.0.0.1/ s/$/ ${HOST_NAME}/" "$CHROOT/etc/hosts" 2>/dev/null || echo "127.0.0.1 localhost ${HOST_NAME}" >> "$CHROOT/etc/hosts"

chroot "$CHROOT" /bin/bash -e -c "
userdel -r alarm 2>/dev/null || true
echo 'root:${PASSWORD}' | chpasswd
useradd -m -G wheel,network -s /bin/bash ${USERNAME} 2>/dev/null || true
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

# Replace dbus-broker with standard dbus-daemon (compatible with 6.12.1-msm8916 kernel config)
rm -f "$CHROOT/etc/systemd/system/dbus.service" "$CHROOT/usr/lib/systemd/system/dbus.service"
cat > "$CHROOT/etc/systemd/system/dbus.service" << 'EOF'
[Unit]
Description=D-Bus System Message Bus
Documentation=man:dbus-daemon(1)
Requires=dbus.socket

[Service]
ExecStart=/usr/bin/dbus-daemon --system --address=systemd: --nofork --nopidfile --systemd-activation --syslog-only
ExecReload=/usr/bin/dbus-send --print-reply --system --type=method_call --dest=org.freedesktop.DBus / org.freedesktop.DBus.ReloadConfig
OOMScoreAdjust=-900
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
/usr/bin/usb-gadget start >/dev/null 2>&1 || true

# Background helper to ensure 4G LTE connects once ModemManager registers SIM
(
    for i in $(seq 1 30); do
        ip link set usb0 up 2>/dev/null || true
        if ip addr show wwan0 2>/dev/null | grep -q "inet "; then
            break
        fi
        if mmcli -m 0 >/dev/null 2>&1; then
            mmcli -m 0 --set-power-state-on >/dev/null 2>&1 || true
            mmcli -m 0 -e >/dev/null 2>&1 || true
            if nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -q "^wwan0qmi0:disconnected"; then
                nmcli connection up lte >/dev/null 2>&1 || true
            fi
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
systemctl disable systemd-networkd.service systemd-resolved.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
systemctl enable NetworkManager.service ModemManager.service wpa_supplicant.service sshd.service chronyd.service rmtfs.service uz801-init.service
"

# Trim docs/locales/manpages to fit comfortably in 640 MiB initial image
rm -rf "$CHROOT/usr/share/man/"* "$CHROOT/usr/share/doc/"* "$CHROOT/usr/share/gtk-doc/"* "$CHROOT/usr/share/locale/"* "$CHROOT/usr/share/vim" "$CHROOT/usr/share/i18n" "$CHROOT/usr/include/"* 2>/dev/null || true

echo "[*] Creating Arch Linux ARM ext4 rootfs image (640 MiB)..."
ROOT_RAW="$STAGING/arch-rootfs.raw"
truncate -s $((640 * 1024 * 1024)) "$ROOT_RAW"
mkfs.ext4 -F -d "$CHROOT" "$ROOT_RAW" >/dev/null 2>&1
gzip -c "$ROOT_RAW" > "$OUT_DIR/arch-rootfs.img.gz"

echo "[+] Arch Linux ARM rootfs image created:"
ls -lh "$OUT_DIR/arch-rootfs.img.gz"
