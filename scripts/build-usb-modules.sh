#!/bin/bash
# Build in-tree USB serial modules against the prepared msm8916 kernel build env.
# Requires: scripts/setup-kernel-build.sh has been run first (modules_prepare done).
# Run inside the builder VM (make builder) or any arm64/amd64 Linux box.
#
# Usage: sudo bash scripts/build-usb-modules.sh
#
# Outputs .ko files to: modules/octoprint-usb-serial/6.12.1-msm8916/
# Then checks vermagic prefix matches "6.12.1-msm8916".
#
# Decision: if vermagic matches, copying .ko files + running depmod on the device
# is sufficient — no full kernel install needed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/kernel-build"
KSRC="$BUILD_DIR/linux-6.12.1-msm8916"
EXPECTED_VERMAGIC="6.12.1-msm8916"
ARTIFACT_DIR="$REPO_ROOT/modules/octoprint-usb-serial/$EXPECTED_VERMAGIC"

# Detect cross-compile prefix (same logic as setup-kernel-build.sh)
if [ "$(uname -m)" = "aarch64" ]; then
    CROSS_COMPILE=""
else
    CROSS_COMPILE="aarch64-linux-gnu-"
fi

# --- Preflight ---
if [ ! -f "$KSRC/scripts/mod/modpost" ]; then
    echo "[FAIL] modules_prepare not done. Run: sudo bash scripts/setup-kernel-build.sh" >&2
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"

echo "[msm8916-kern] Building USB serial modules ..."
echo "  KSRC    : $KSRC"
echo "  ARTIFACTS: $ARTIFACT_DIR"
echo "  CROSS   : ${CROSS_COMPILE:-<native arm64>}"
echo ""

# --- 1. Build USB serial drivers (usbserial.ko + ch341.ko + ftdi_sio.ko + pl2303.ko) ---
# ponytail: directory target is a no-op here; ask kbuild for exact .ko files.
for target in \
    drivers/usb/serial/usbserial.ko \
    drivers/usb/serial/ch341.ko \
    drivers/usb/serial/ftdi_sio.ko \
    drivers/usb/serial/pl2303.ko
 do
    make -C "$KSRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" KBUILD_MODPOST_WARN=1 "$target"
done

# --- 2. Build CDC ACM if enabled as module ---
if grep -q '^CONFIG_USB_ACM=m' "$KSRC/.config"; then
    echo "[+] CONFIG_USB_ACM=m found — building cdc-acm.ko ..."
    make -C "$KSRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" KBUILD_MODPOST_WARN=1 drivers/usb/class/cdc-acm.ko
else
    echo "[=] CONFIG_USB_ACM not =m in .config, skipping cdc-acm.ko"
fi

echo ""
echo "[+] Copying .ko files to artifacts ..."

# --- 3. Copy target modules ---
SERIAL_KOS="usbserial.ko ch341.ko ftdi_sio.ko pl2303.ko"
for mod in $SERIAL_KOS; do
    src="$KSRC/drivers/usb/serial/$mod"
    if [ -f "$src" ]; then
        cp "$src" "$ARTIFACT_DIR/"
        echo "  [+] $mod"
    else
        echo "  [WARN] $mod not found (check .config — may not be =m)"
    fi
done

if [ -f "$KSRC/drivers/usb/class/cdc-acm.ko" ]; then
    cp "$KSRC/drivers/usb/class/cdc-acm.ko" "$ARTIFACT_DIR/"
    echo "  [+] cdc-acm.ko"
fi

# --- 4. Verify vermagic ---
echo ""
echo "[+] Checking vermagic (expected prefix: $EXPECTED_VERMAGIC) ..."
ERRORS=0
shopt -s nullglob
KOS=("$ARTIFACT_DIR"/*.ko)
if [ ${#KOS[@]} -eq 0 ]; then
    echo "[FAIL] No .ko files found in $ARTIFACT_DIR" >&2
    exit 1
fi

for ko in "${KOS[@]}"; do
    vm=$(modinfo -F vermagic "$ko" 2>/dev/null || echo "UNKNOWN")
    if echo "$vm" | grep -q "^${EXPECTED_VERMAGIC}"; then
        echo "  [ OK ] $(basename "$ko"): $vm"
    else
        echo "  [FAIL] $(basename "$ko"): vermagic='$vm' (expected prefix '$EXPECTED_VERMAGIC')"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "[ OK ] All modules vermagic match. Copying + depmod on device is sufficient."
    echo "       No full kernel install needed."
    echo ""
    echo "  Artifacts: $ARTIFACT_DIR"
    ls -lh "$ARTIFACT_DIR/"
    exit 0
else
    echo "[FAIL] $ERRORS vermagic mismatch(es)."
    echo "       Check whether device.config.gz was used (exact match) vs pmaports config."
    echo "       If mismatch persists, a full kernel install may be needed."
    exit 1
fi
