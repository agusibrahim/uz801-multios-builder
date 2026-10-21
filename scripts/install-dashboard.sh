#!/usr/bin/env bash
# Live Installer for UZ801 Modem Manager Web Dashboard + Cool/RAM-Unlocked Kernel DTB over ADB
# Works on all 11 supported operating systems without reflashing rootfs!

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH_BIN="$SCRIPT_DIR/configs/dashboard/uz801-dashboard"
GADGET_SH="$SCRIPT_DIR/configs/usb-gadget/usb-gadget.sh"
DTB_FILE="$SCRIPT_DIR/files/dtbs/msm8916-yiming-uz801v3.dtb"
SERIAL="${1:-2c2d59162055f8d2}"

echo "[*] Building static arm64 uz801-dashboard binary..."
(cd "$SCRIPT_DIR/configs/dashboard" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o uz801-dashboard .)

echo "[*] Waiting for UZ801 ADB device ($SERIAL)..."
adb -s "$SERIAL" wait-for-device

echo "[*] Stopping existing uz801-dashboard process..."
adb -s "$SERIAL" shell "killall -9 uz801-dashboard 2>/dev/null || pkill -9 -f uz801-dashboard 2>/dev/null || true"

echo "[*] Pushing uz801-dashboard and usb-gadget to device..."
adb -s "$SERIAL" push "$DASH_BIN" /tmp/uz801-dashboard.new
adb -s "$SERIAL" push "$GADGET_SH" /usr/sbin/usb-gadget

if [[ -f "$DTB_FILE" ]]; then
    echo "[*] Updating /boot Device Tree (54°C Thermal Cap + +22MB RAM Unlock + 533MHz/1.15GHz OPP)..."
    adb -s "$SERIAL" push "$DTB_FILE" /tmp/msm8916-yiming-uz801v3.dtb
    adb -s "$SERIAL" shell "
        mkdir -p /boot
        mount /dev/mmcblk0p13 /boot 2>/dev/null || mount -o remount,rw /boot 2>/dev/null || true
        if [ -d /boot/dtbs/qcom ]; then
            cp -f /tmp/msm8916-yiming-uz801v3.dtb /boot/dtbs/qcom/msm8916-yiming-uz801v3.dtb
            cat > /boot/extlinux/extlinux.conf << 'EOF'
TIMEOUT 1
DEFAULT alpine

LABEL alpine
    MENU LABEL UZ801 Mainline 6.12 (Cool & RAM-Unlocked)
    linux /vmlinuz
    fdt /dtbs/qcom/msm8916-yiming-uz801v3.dtb
    append earlycon root=/dev/mmcblk0p14 console=ttyMSM0,115200 no_framebuffer=true cma=2M rw rootwait
EOF
            sync
            mount -o remount,ro /boot 2>/dev/null || true
        fi
        rm -f /tmp/msm8916-yiming-uz801v3.dtb
    "
fi

echo "[*] Installing and starting uz801-dashboard service (2-Core 533MHz + 10dBm WiFi Cool Profile)..."
adb -s "$SERIAL" shell "mv -f /tmp/uz801-dashboard.new /usr/bin/uz801-dashboard && chmod 0755 /usr/bin/uz801-dashboard /usr/sbin/usb-gadget && (nohup /usr/bin/uz801-dashboard >/run/uz801-dashboard.log 2>&1 </dev/null &); sleep 1; cat /run/uz801-dashboard.log"

echo ""
echo "[+] UZ801 Modem Manager Dashboard + Thermal/RAM Kernel DTB installed!"
echo "    -> Reboot the stick ('adb shell reboot') once to activate the new +22MB RAM & 533MHz/1.15GHz DTB."
echo "    -> USB NCM : http://192.168.42.1"
