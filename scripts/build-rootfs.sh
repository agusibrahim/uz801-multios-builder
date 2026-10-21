#!/bin/bash
set -euo pipefail

# ponytail: load order: default profile → selected profile → local overrides
[ -f ./profiles/default.env ] && source ./profiles/default.env

if [ -n "${PROFILE:-}" ]; then
    _PROFILE_FILE="./profiles/${PROFILE}.env"
    if [ ! -f "$_PROFILE_FILE" ]; then
        _AVAILABLE=$(ls ./profiles/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//' | grep -v '^default$' | tr '\n' ' ')
        echo "ERROR: Unknown profile '${PROFILE}'. Available: ${_AVAILABLE:-none}"
        exit 1
    fi
    source "$_PROFILE_FILE"
fi

[ -f ./variables.env ] && source ./variables.env

# Configuration
WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801a}"
RELEASE="${RELEASE:-v3.21}"
PMOS_RELEASE="${PMOS_RELEASE:-v25.06}"
MIRROR="${MIRROR:-http://dl-cdn.alpinelinux.org/alpine}"
PMOS_MIRROR="${PMOS_MIRROR:-http://mirror.postmarketos.org/postmarketos}"

USERNAME="${USERNAME:-user}"
DTB_FILE="${DTB_FILE:-msm8916-yiming-uz801v3.dtb}"
USB0_IP="${USB0_IP:-192.168.42.1/24}"
USB_GADGET_INSTALL="${USB_GADGET_INSTALL:-yes}"
USB_GADGET_OTG="${USB_GADGET_OTG:-no}"
USB_GADGET_ENABLED="${USB_GADGET_ENABLED:-yes}"
OCTOPRINT_PREINSTALL="${OCTOPRINT_PREINSTALL:-no}"
ZORAXY_PREINSTALL="${ZORAXY_PREINSTALL:-no}"
DOCKER_ENABLE="${DOCKER_ENABLE:-no}"
STACKS="${STACKS:-}"
# Profile-controlled additions (set in profiles/*.env, not here)
PROFILE_PACKAGES="${PROFILE_PACKAGES:-}"
PROFILE_SERVICES="${PROFILE_SERVICES:-}"

# Required: password must be set
[ -z "${PASSWORD:-}" ] && {
    echo "ERROR: PASSWORD not set. Copy variables.env.example to variables.env and set a password."
    exit 1
}

# Cleanup on exit
trap 'rm -rf "$STAGING"' EXIT INT TERM

# Validations
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"
HOST_ARCH="$(uname -m)"
IS_ARM64=false
[ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ] && IS_ARM64=true

if [ "$IS_ARM64" = "false" ]; then
    command -v qemu-aarch64-static >/dev/null || { echo "Falta qemu-aarch64-static"; exit 1; }
fi

echo "[*] Profile: ${PROFILE:-default}"
echo "[*] Output directory: $OUT_DIR"
echo "[*] Temporary staging: $STAGING"

# Create rootfs
mkdir -p "$CHROOT"

# Setup APK repositories
mkdir -p "$CHROOT/etc/apk"
cat << EOF > "$CHROOT/etc/apk/repositories"
${MIRROR}/${RELEASE}/main
${MIRROR}/${RELEASE}/community
${PMOS_MIRROR}/${PMOS_RELEASE}
EOF

# Copy DNS config
cp /etc/resolv.conf "$CHROOT/etc/"

# Copy QEMU static (only needed when cross-building)
mkdir -p "$CHROOT/usr/bin"
if [ "$IS_ARM64" = "false" ]; then
    cp $(which qemu-aarch64-static) "$CHROOT/usr/bin/"
fi

# Download and use apk.static
echo "[*] Downloading apk.static..."
if [ "$IS_ARM64" = "true" ]; then
    APK_STATIC_ARCH="aarch64"
else
    APK_STATIC_ARCH="x86_64"
fi
wget -q "https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.6/${APK_STATIC_ARCH}/apk.static" -O "$STAGING/apk.static"
chmod a+x "$STAGING/apk.static"

# Bootstrap Alpine
echo "[*] Bootstrapping Alpine Linux..."
"$STAGING/apk.static" add -p "$CHROOT" --initdb -U --arch aarch64 --allow-untrusted alpine-base

echo "[*] Installing packages..."
chroot "$CHROOT" ash -l -c "
apk add --no-cache --no-interactive --allow-untrusted postmarketos-keys
apk add --no-cache --no-interactive \
    openrc \
    eudev udev-init-scripts udev-init-scripts-openrc \
    shadow sudo \
    e2fsprogs e2fsprogs-extra \
    linux-postmarketos-qcom-msm8916 \
    msm-firmware-loader \
    rmtfs \
    modemmanager \
    dbus \
    networkmanager networkmanager-cli networkmanager-wifi networkmanager-wwan networkmanager-dnsmasq \
    wpa_supplicant wireless-regdb iw \
    iptables \
    dropbear \
    networkmanager-tui \
    nano \
    bash bash-completion \
    ca-certificates
"

# Install profile-specific packages (profile contract — separate from base and user packages)
if [ -n "${PROFILE_PACKAGES:-}" ]; then
    _PPKG_LIST="$(echo "$PROFILE_PACKAGES" | tr '\n' ' ' | tr -s ' ')"
    echo "[*] Installing profile packages (${PROFILE:-default}): ${_PPKG_LIST}"
    chroot "$CHROOT" ash -l -c "apk add --no-cache --no-interactive ${_PPKG_LIST}"
fi

# Install extra packages from variables.env (user/local overrides)
if [ -n "${PACKAGES:-}" ]; then
    _PKG_LIST="$(echo "$PACKAGES" | tr '\n' ' ' | tr -s ' ')"
    echo "[*] Installing user packages..."
    chroot "$CHROOT" ash -l -c "apk add --no-cache --no-interactive ${_PKG_LIST}"
fi

# Setup Alpine
echo "[*] Setting up Alpine..."
chroot "$CHROOT" ash -l -c "
# Create user
echo ${USERNAME}:${PASSWORD}::::/home/${USERNAME}:/bin/bash | newusers

# Set up bash for the user
printf 'PS1=\"\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]$ \"\n' > /home/${USERNAME}/.bash_profile
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile

# Enable system services
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit
rc-update add udev-postmount default
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

# Enable essential application services
rc-update del sshd default 2>/dev/null || true
rc-update del zram-init default 2>/dev/null || true
rc-update del swapfile default 2>/dev/null || true
rc-update add dbus default
rc-update add wpa_supplicant default
rc-update add dropbear default
rc-update add modemmanager default
rc-update add networkmanager default
rc-update add rmtfs default
rc-update add local default

# Enable profile-specific services (profile contract — separate from base and user services)
$(for svc in ${PROFILE_SERVICES:-}; do echo "rc-update add $svc default"; done)

# Enable extra services from variables.env (user/local overrides)
$(for svc in ${SERVICES_AUTOSTART:-}; do echo "rc-update add $svc default"; done)
"

# Sudo config
install -d -m0750 "$CHROOT/etc/sudoers.d"
echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "$CHROOT/etc/sudoers.d/${USERNAME}"
chmod 0440 "$CHROOT/etc/sudoers.d/${USERNAME}"

# Docker install + configuration (profile-driven)
if [ "$DOCKER_ENABLE" = "yes" ]; then
    echo "[*] Installing Docker..."
    chroot "$CHROOT" ash -l -c "apk add --no-cache --no-interactive docker"
    chroot "$CHROOT" ash -l -c "addgroup ${USERNAME} docker; rc-update add docker default"
    echo "[*] Configuring Docker..."
    mkdir -p "$CHROOT/etc/docker"
    cat > "$CHROOT/etc/docker/daemon.json" <<'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "iptables": true
}
DOCKEREOF
fi

# Chrony configuration
echo "[*] Configuring Chrony..."
cat > "$CHROOT/etc/chrony/chrony.conf" <<'CHRONYEOF'
# NTP servers
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server 3.pool.ntp.org iburst

# Sync system clock to hardware clock
rtcsync

# Drift file
driftfile /var/lib/chrony/chrony.drift

# Make chrony quickly sync on startup
makestep 1.0 3
CHRONYEOF

# Fix wpa_supplicant OpenRC script for NetworkManager (run in D-Bus mode -u without binding single interface)
cat > "$CHROOT/etc/init.d/wpa_supplicant" <<'WPAEOF'
#!/sbin/openrc-run
supervisor=supervise-daemon
name="WPA Supplicant"
command=/sbin/wpa_supplicant
command_args="-u"
depend() {
	need localmount dbus
	after bootmisc modules udev-settle
	before networkmanager net
	keyword -shutdown
}
WPAEOF
chmod 0755 "$CHROOT/etc/init.d/wpa_supplicant"

# Install adbd for USB ADB shell support
if [ -f configs/adb/adbd ]; then
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
fi

# Udev rule to trigger USB gadget on UDC probe
cat << 'EOF' > "$CHROOT/etc/udev/rules.d/10-udc.rules"
ACTION=="add", SUBSYSTEM=="udc", RUN+="/usr/sbin/usb-gadget start"
EOF

# Enable autologin on console
sed -i '/^tty/ s/^/#/' "$CHROOT/etc/inittab"
echo 'ttyMSM0::respawn:/bin/bash' >> "$CHROOT/etc/inittab"

# Hostname
echo "$HOST_NAME" > "$CHROOT/etc/hostname"
sed -i "/localhost/ s/$/ ${HOST_NAME}/" "$CHROOT/etc/hosts"

# Copy configs (usb0 is managed directly by usb-gadget.sh)
echo "[*] Copying configs..."
mkdir -p "$CHROOT/etc/NetworkManager/system-connections"
cp configs/network-manager/*.nmconnection "$CHROOT/etc/NetworkManager/system-connections/" 2>/dev/null || true
rm -f "$CHROOT/etc/NetworkManager/system-connections/usb0.nmconnection"
chmod 0600 "$CHROOT/etc/NetworkManager/system-connections/"* 2>/dev/null || true

# Substitute WiFi placeholders if WiFi is enabled and credentials are provided
if [ "${WIFI_ENABLED:-yes}" = "yes" ] && [ -n "${WIFI_SSID:-}" ]; then
    echo "[*] Configuring WiFi connection (SSID: ${WIFI_SSID})"
    WLAN_CONN="$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
    sed -i "s/__SSID__/${WIFI_SSID}/g" "$WLAN_CONN"
    sed -i "s/__PASS__/${WIFI_PASS:-}/g" "$WLAN_CONN"
    if [ -n "${WIFI_IP:-}" ]; then
        echo "[*] WiFi: static ${WIFI_IP}"
        sed -i '/^\[ipv4\]/,/^\[ipv6\]/ s|method=auto|method=manual|' "$WLAN_CONN"
        if [ -n "${WIFI_GW:-}" ]; then
            sed -i "/\[ipv4\]/a address1=${WIFI_IP},${WIFI_GW}" "$WLAN_CONN"
        else
            sed -i "/\[ipv4\]/a address1=${WIFI_IP}" "$WLAN_CONN"
        fi
        if [ -n "${WIFI_DNS:-}" ]; then
            _WIFI_DNS="$(printf '%s' "$WIFI_DNS" | tr ',' ';')"
            case "$_WIFI_DNS" in *';') ;; *) _WIFI_DNS="${_WIFI_DNS};" ;; esac
            sed -i "/\[ipv4\]/a dns=${_WIFI_DNS}" "$WLAN_CONN"
        fi
    fi
else
    echo "[*] WiFi disabled or no SSID provided — removing wlan config"
    rm -f "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
fi

# DTBs: compiled (files/dtbs/) take priority, then precompiled (dtbs/)
mkdir -p "$CHROOT/boot/dtbs/qcom"
cp "$OUT_DIR/dtbs/"*.dtb "$CHROOT/boot/dtbs/qcom/" 2>/dev/null || true
cp dtbs/*.dtb "$CHROOT/boot/dtbs/qcom/" 2>/dev/null || true

mkdir -p "$CHROOT/boot/extlinux"
cat > "$CHROOT/boot/extlinux/extlinux.conf" <<EOF
TIMEOUT 10
DEFAULT alpine

LABEL alpine
    MENU LABEL Alpine Linux
    linux /vmlinuz
    fdt /dtbs/qcom/${DTB_FILE}
    append earlycon root=/dev/mmcblk0p14 console=ttyMSM0,115200 no_framebuffer=true rw rootwait
EOF

cat > "$CHROOT/etc/fstab" <<EOF
/dev/mmcblk0p13    /boot    ext2    ro,noatime          0 0
/dev/mmcblk0p14    /        ext4    rw,noatime,commit=1 0 0
EOF

# USB gadget
if [ "$USB_GADGET_INSTALL" = "yes" ]; then
    install -Dm0755 configs/usb-gadget/usb-gadget.sh "$CHROOT/usr/sbin/usb-gadget"
    install -Dm0755 configs/usb-gadget/usb-gadget.init "$CHROOT/etc/init.d/usb-gadget"
    cat > "$CHROOT/etc/usb-gadget.conf" << EOF
# MSM8916 USB Gadget Configuration

USE_NCM=1           # 1 = NCM (Linux/Mac), 0 = RNDIS (Windows)
ENABLE_OTG=$([ "$USB_GADGET_OTG" = "yes" ] && echo 1 || echo 0)        # 1 = OTG Host mode, 0 = Gadget mode
EOF

    # Enable USB gadget service (controlled by USB_GADGET_ENABLED profile setting)
    if [ "$USB_GADGET_ENABLED" = "yes" ]; then
        chroot "$CHROOT" ash -l -c "rc-update add usb-gadget default" || true
    fi
fi

# Expand rootfs on first boot
install -Dm0755 configs/expand-rootfs/expand-rootfs.sh "$CHROOT/usr/sbin/expand-rootfs.sh"
install -Dm0755 configs/expand-rootfs/expand-rootfs.init "$CHROOT/etc/init.d/expand-rootfs"
chroot "$CHROOT" ash -l -c "rc-update add expand-rootfs boot" || true

# zram swap (compressed in-RAM swap, ~256MB effective headroom)
echo "[*] Configuring zram swap..."
mkdir -p "$CHROOT/etc/local.d"
cat > "$CHROOT/etc/local.d/zram.start" << 'EOF'
#!/bin/sh
modprobe zram
echo 1 > /sys/block/zram0/reset
echo lz4 > /sys/block/zram0/comp_algorithm
echo 256M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0
EOF
chmod +x "$CHROOT/etc/local.d/zram.start"

cat > "$CHROOT/etc/local.d/lte-autoconnect.start" << 'EOF'
#!/bin/sh
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
chmod +x "$CHROOT/etc/local.d/lte-autoconnect.start"

# Stack hooks — profile-driven via STACKS (see profiles/*.env and stacks/run-*.sh)
for _stack in ${STACKS:-}; do
    echo "[*] Running stack: $_stack"
    CHROOT="$CHROOT" STAGING="$STAGING" WORKDIR="$WORKDIR" \
        bash "$WORKDIR/stacks/run-${_stack}.sh"
done

# Create tarball
echo "[*] Creating tarball..."
tar cpzf "$STAGING/alpine_rootfs.tgz" \
    --exclude="root/*" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -C "$CHROOT" .

# Copy to output directory
echo "[*] Copying rootfs to $OUT_DIR..."
rm -rf "$OUT_DIR/rootfs"
mkdir -p "$OUT_DIR/rootfs"
tar -C "$CHROOT" \
    --exclude="root/*" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -cf - . | tar -C "$OUT_DIR/rootfs" -xf -

cp "$STAGING/alpine_rootfs.tgz" "$OUT_DIR/rootfs.tgz"

echo "[+] OK: Alpine rootfs ready in $OUT_DIR (profile: ${PROFILE:-default})"
echo "    - Kernel: linux-postmarketos-qcom-msm8916 from ${PMOS_RELEASE}"
echo "    - Docker: ${DOCKER_ENABLE}"
echo "    - Stacks: ${STACKS:-none}"
echo "    - Chrony: enabled with NTP servers"
echo "    - DTB: ${DTB_FILE}"
echo "    - $OUT_DIR/rootfs/ (directory)"
echo "    - $OUT_DIR/rootfs.tgz (tarball)"
ls -lh "$OUT_DIR/rootfs.tgz"
