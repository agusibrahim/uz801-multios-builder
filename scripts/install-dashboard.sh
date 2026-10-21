#!/usr/bin/env bash
# Live Installer for UZ801 Modem Manager Web Dashboard over ADB
# Works on all 10 supported Linux distributions without reflashing!

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH_BIN="$SCRIPT_DIR/configs/dashboard/uz801-dashboard"
GADGET_SH="$SCRIPT_DIR/configs/usb-gadget/usb-gadget.sh"
SERIAL="${1:-2c2d59162055f8d2}"

if [[ ! -f "$DASH_BIN" ]] || [[ "$SCRIPT_DIR/configs/dashboard/main.go" -nt "$DASH_BIN" ]] || [[ "$SCRIPT_DIR/configs/dashboard/static/index.html" -nt "$DASH_BIN" ]]; then
    echo "[*] Building static arm64 uz801-dashboard binary..."
    (cd "$SCRIPT_DIR/configs/dashboard" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o uz801-dashboard .)
fi

echo "[*] Waiting for UZ801 ADB device ($SERIAL)..."
adb -s "$SERIAL" wait-for-device

echo "[*] Pushing uz801-dashboard and usb-gadget to device..."
adb -s "$SERIAL" push "$DASH_BIN" /usr/bin/uz801-dashboard
adb -s "$SERIAL" push "$GADGET_SH" /usr/sbin/usb-gadget

echo "[*] Starting uz801-dashboard service..."
adb -s "$SERIAL" shell "chmod 0755 /usr/bin/uz801-dashboard /usr/sbin/usb-gadget && killall uz801-dashboard 2>/dev/null || true; (nohup /usr/bin/uz801-dashboard >/run/uz801-dashboard.log 2>&1 </dev/null &); sleep 1; cat /run/uz801-dashboard.log"

echo ""
echo "[+] UZ801 Modem Manager Dashboard is live!"
echo "    -> USB NCM : http://192.168.42.1 (or http://192.168.42.1:8080 on ImmortalWrt)"
echo "    -> WiFi LAN: http://192.168.1.138 (or :8080)"
