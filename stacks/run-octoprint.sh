#!/bin/bash
# ponytail: host-side OctoPrint stack hook — invoked by build-rootfs.sh STACKS loop.
# Required env: CHROOT, STAGING, WORKDIR
set -euo pipefail

: "${CHROOT:?CHROOT env var required}"
: "${STAGING:?STAGING env var required}"
: "${WORKDIR:?WORKDIR env var required}"

# --- USB serial modules (issue-005) ---
KERNEL_VER="6.12.1-msm8916"
USB_MOD_SRC="$WORKDIR/modules/octoprint-usb-serial/${KERNEL_VER}"
USB_REQUIRED_MODS="ch341.ko usbserial.ko cdc-acm.ko ftdi_sio.ko pl2303.ko"

_missing=""
for _mod in $USB_REQUIRED_MODS; do
    [ -f "$USB_MOD_SRC/$_mod" ] || _missing="$_missing $_mod"
done
if [ -n "$_missing" ]; then
    echo "ERROR: Missing required USB serial modules for OctoPrint:${_missing}"
    echo "       Expected in: $USB_MOD_SRC/"
    exit 1
fi

echo "[*] Installing USB serial modules (${KERNEL_VER})..."
USB_MOD_SERIAL="$CHROOT/lib/modules/${KERNEL_VER}/kernel/drivers/usb/serial"
USB_MOD_CLASS="$CHROOT/lib/modules/${KERNEL_VER}/kernel/drivers/usb/class"
mkdir -p "$USB_MOD_SERIAL" "$USB_MOD_CLASS"
for _mod in usbserial.ko ch341.ko ftdi_sio.ko pl2303.ko; do
    install -m0644 "$USB_MOD_SRC/$_mod" "$USB_MOD_SERIAL/"
done
[ -f "$USB_MOD_SRC/cdc-acm.ko" ] && install -m0644 "$USB_MOD_SRC/cdc-acm.ko" "$USB_MOD_CLASS/"

chroot "$CHROOT" depmod -a "${KERNEL_VER}"

# Force USB host mode and preload printer serial drivers at boot.
cat > "$CHROOT/etc/local.d/octoprint-usb.start" << 'EOF'
#!/bin/sh
ROLE=/sys/class/usb_role/ci_hdrc.0-role-switch/role
for _ in 1 2 3 4 5; do
    [ -w "$ROLE" ] && { echo host > "$ROLE"; break; }
    sleep 1
done
modprobe usbserial 2>/dev/null || true
modprobe ch341 2>/dev/null || true
modprobe ftdi_sio 2>/dev/null || true
modprobe pl2303 2>/dev/null || true
modprobe cdc_acm 2>/dev/null || true
EOF
chmod +x "$CHROOT/etc/local.d/octoprint-usb.start"

# --- Health logging (issue-007) ---
echo "[*] Installing print-health..."
install -Dm0755 "$WORKDIR/configs/health/print-health.sh"  "$CHROOT/usr/local/sbin/print-health"
mkdir -p "$CHROOT/etc/periodic/15min"
install -Dm0755 "$WORKDIR/configs/health/print-health-log" "$CHROOT/etc/periodic/15min/print-health-log"
chroot "$CHROOT" rc-update add crond default

# --- OctoPrint install ---
echo "[*] Preinstalling OctoPrint..."
RESOURCE_MONITOR_VERSION="0.4.0"
RESOURCE_MONITOR_ZIP_HOST="$STAGING/OctoPrint-Resource-Monitor-${RESOURCE_MONITOR_VERSION}.zip"
wget -q "https://github.com/Renaud11232/OctoPrint-Resource-Monitor/archive/refs/tags/${RESOURCE_MONITOR_VERSION}.zip" \
    -O "$RESOURCE_MONITOR_ZIP_HOST"

LED_STATUS_ZIP_HOST="$WORKDIR/plugins/octoprint-led-status/dist/OctoPrint-LedStatus-1.0.0.zip"
echo "[*] Building LED Status plugin zip from tracked source..."
make -C "$WORKDIR" plugins
install -Dm0644 "$LED_STATUS_ZIP_HOST"                                         "$CHROOT/tmp/$(basename "$LED_STATUS_ZIP_HOST")"
install -Dm0755 "$WORKDIR/plugins/octoprint-led-status/helper/led-helper"     "$CHROOT/tmp/led-helper"
install -Dm0640 "$WORKDIR/plugins/octoprint-led-status/sudoers/octoprint-led" "$CHROOT/tmp/octoprint-led-sudoers"

install -Dm0755 "$WORKDIR/stacks/install-octoprint.sh" "$CHROOT/tmp/install-octoprint.sh"
install -Dm0644 "$RESOURCE_MONITOR_ZIP_HOST" "$CHROOT/tmp/$(basename "$RESOURCE_MONITOR_ZIP_HOST")"
chroot "$CHROOT" env \
    RESOURCE_MONITOR_ZIP="/tmp/$(basename "$RESOURCE_MONITOR_ZIP_HOST")" \
    LED_STATUS_ZIP="/tmp/$(basename "$LED_STATUS_ZIP_HOST")" \
    LED_STATUS_HELPER="/tmp/led-helper" \
    LED_STATUS_SUDOERS="/tmp/octoprint-led-sudoers" \
    bash /tmp/install-octoprint.sh -y
chroot "$CHROOT" /opt/octoprint/venv/bin/pip show OctoPrint-Resource-Monitor >/dev/null
chroot "$CHROOT" /opt/octoprint/venv/bin/pip show OctoPrint-LedStatus >/dev/null
rm -rf "$CHROOT/tmp/install-octoprint.sh" \
       "$CHROOT/tmp/$(basename "$RESOURCE_MONITOR_ZIP_HOST")" \
       "$CHROOT/tmp/$(basename "$LED_STATUS_ZIP_HOST")" \
       "$CHROOT/tmp/led-helper" \
       "$CHROOT/tmp/octoprint-led-sudoers"
