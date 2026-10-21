#!/bin/bash
# OctoPrint appliance verification.
# Automated checks run immediately.
# Manual device-side checks are printed as a numbered checklist.
set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

# Resolve repo root relative to this script so it can be called from anywhere.
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== OctoPrint Verification ==="
echo ""

# ---- 1. Syntax checks ----------------------------------------
echo "-- 1. Syntax checks --"

for script in stacks/install-octoprint.sh; do
    if bash -n "$REPO/$script" 2>&1; then
        ok "bash -n $script"
    else
        fail "bash -n $script"
    fi
done

# Extract and syntax-check the inline OpenRC init script embedded in the installer.
TMPINIT=$(mktemp)
awk '/^cat > \/etc\/init.d\/octoprint <<.EOF./{p=1;next} /^EOF$/{p=0} p' \
    "$REPO/stacks/install-octoprint.sh" > "$TMPINIT"
if bash -n "$TMPINIT" 2>/dev/null; then
    ok "OpenRC init script (embedded in installer) is valid sh syntax"
else
    fail "OpenRC init script (embedded in installer) has syntax errors"
fi
rm -f "$TMPINIT"

# ---- 2. USB gadget policy ------------------------------------
echo ""
echo "-- 2. USB gadget policy --"

if grep -q 'USB_GADGET_INSTALL="no"' "$REPO/profiles/octoprint.env"; then
    ok "OctoPrint profile disables USB gadget install (USB_GADGET_INSTALL=no)"
else
    fail "OctoPrint profile should set USB_GADGET_INSTALL=\"no\""
fi

if grep -q 'USB_GADGET_ENABLED="no"' "$REPO/profiles/octoprint.env"; then
    ok "OctoPrint profile disables USB gadget autostart (USB_GADGET_ENABLED=no)"
else
    fail "OctoPrint profile should set USB_GADGET_ENABLED=\"no\""
fi

if grep -q 'USB_GADGET_OTG="yes"' "$REPO/profiles/octoprint.env"; then
    ok "OctoPrint profile enables USB host (OTG) mode for printer (USB_GADGET_OTG=yes)"
else
    fail "OctoPrint profile should set USB_GADGET_OTG=\"yes\" to enable USB host path"
fi

if grep -q 'if \[ "$USB_GADGET_INSTALL" = "yes" \]' "$REPO/scripts/build-rootfs.sh"; then
    ok "Rootfs generator gates usb-gadget install on USB_GADGET_INSTALL"
else
    fail "Rootfs generator installs usb-gadget unconditionally"
fi

if grep -q 'if \[ "$USB_GADGET_ENABLED" = "yes" \]' "$REPO/scripts/build-rootfs.sh"; then
    ok "Rootfs generator gates usb-gadget autostart on USB_GADGET_ENABLED"
else
    fail "Rootfs generator starts usb-gadget unconditionally"
fi

# ---- 3. Idempotency guard ------------------------------------
echo ""
echo "-- 3. Idempotency guard --"

if grep -q 'skipping pip reinstall' "$REPO/stacks/install-octoprint.sh"; then
    ok "Installer skips pip reinstall when version already matches (NEEDS_INSTALL=0)"
else
    fail "Installer missing pip-skip idempotency guard"
fi

if grep -q 'rc-update add octoprint' "$REPO/stacks/install-octoprint.sh"; then
    ok "Installer always refreshes integration files (service, sudoers) outside pip gate"
else
    fail "Installer missing unconditional integration refresh (rc-update add octoprint)"
fi

if grep -q 'if \[ ! -f.*config.yaml' "$REPO/stacks/install-octoprint.sh"; then
    ok "Installer preserves existing config.yaml on rerun (no user-config wipe)"
else
    fail "Installer does not guard config.yaml write — may overwrite user config on rerun"
fi

if grep -q 'RESOURCE_MONITOR_ZIP=' "$REPO/stacks/install-octoprint.sh" \
   && grep -q 'OctoPrint-Resource-Monitor.*zip' "$REPO/stacks/run-octoprint.sh"; then
    ok "Appliance downloads Resource Monitor zip before chroot install"
else
    fail "Appliance install is missing bundled Resource Monitor zip integration"
fi

# ---- 4. OctoPrint no-LTE DTB profile -------------------------
echo ""
echo "-- 4. OctoPrint no-LTE DTB profile --"
DTS="$REPO/dts/msm8916-yiming-uz801v3-octoprint.dts"

if [ -f "$DTS" ]; then
    ok "OctoPrint DTB profile exists: dts/msm8916-yiming-uz801v3-octoprint.dts"

    # Each node block is &foo {\n\tstatus = "disabled";\n}; — grep -A2 is sufficient.
    for node in mpss mpss_mem mba_mem bam_dmux bam_dmux_dma venus venus_mem; do
        if grep -A2 "^&${node} {" "$DTS" | grep -q 'status = "disabled"'; then
            ok "  &${node} is disabled"
        else
            fail "  &${node} is NOT disabled in OctoPrint profile"
        fi
    done

    # WiFi (wcnss) must NOT be overridden/disabled — it inherits enabled from base DTS.
    if grep -A2 '&wcnss' "$DTS" | grep -q 'disabled'; then
        fail "  WiFi (&wcnss) is disabled — it must stay enabled"
    else
        ok "  WiFi (&wcnss) not overridden — stays enabled from base DTS"
    fi
else
    fail "OctoPrint DTB profile not found: dts/msm8916-yiming-uz801v3-octoprint.dts"
fi

# ---- 5. USB serial module artifacts (issue-005) --------------
echo ""
echo "-- 5. USB serial module artifacts --"
_KERNEL_VER="6.12.1-msm8916"
_ARTIFACT_DIR="$REPO/modules/octoprint-usb-serial/${_KERNEL_VER}"
for _mod in ch341.ko usbserial.ko cdc-acm.ko ftdi_sio.ko pl2303.ko; do
    if [ -f "$_ARTIFACT_DIR/$_mod" ]; then
        ok "USB module artifact present: ${_mod}"
    else
        fail "USB module artifact missing: ${_mod} in modules/octoprint-usb-serial/${_KERNEL_VER}"
    fi
done
unset _KERNEL_VER _ARTIFACT_DIR _mod

if grep -q 'octoprint-usb.start' "$REPO/stacks/run-octoprint.sh" \
    && grep -q 'echo host > "$ROLE"' "$REPO/stacks/run-octoprint.sh" \
    && grep -q 'modprobe ch341' "$REPO/stacks/run-octoprint.sh" \
    && grep -q 'modprobe cdc_acm' "$REPO/stacks/run-octoprint.sh"; then
    ok "OctoPrint image forces USB host mode and preloads serial modules at boot"
else
    fail "OctoPrint image missing USB host/module boot setup"
fi

# ---- 6. LED status plugin (issue-005) -----------------------
echo ""
echo "-- 6. LED status plugin --"

_LS_SETUP="$REPO/plugins/octoprint-led-status/setup.py"
_LS_PLUGIN="$REPO/plugins/octoprint-led-status/octoprint_led_status/__init__.py"
_LS_HELPER="$REPO/plugins/octoprint-led-status/helper/led-helper"
_LS_SUDOERS="$REPO/plugins/octoprint-led-status/sudoers/octoprint-led"

if [ -f "$_LS_SETUP" ] && [ -f "$_LS_PLUGIN" ]; then
    ok "LED Status plugin source is present under plugins/octoprint-led-status/"
else
    fail "LED Status plugin source missing under plugins/octoprint-led-status/"
fi

if grep -q 'make -C "\$WORKDIR" plugins' "$REPO/stacks/run-octoprint.sh" \
   && grep -q 'LED_STATUS_ZIP_HOST=' "$REPO/stacks/run-octoprint.sh"; then
    ok "OctoPrint stack rebuilds the LED Status plugin zip during image build"
else
    fail "OctoPrint stack does not rebuild the LED Status plugin zip during image build"
fi

if [ ! -e "$REPO/plugins/octoprint-network-settings" ]; then
    ok "Unused OctoPrint network-settings artifact is absent"
else
    fail "Unused OctoPrint network-settings artifact should not remain in the repo"
fi

if [ -f "$_LS_HELPER" ]; then
    ok "LED Status helper present: plugins/octoprint-led-status/helper/led-helper"
else
    fail "LED Status helper missing: $_LS_HELPER"
fi

if grep -q 'install.*led-helper' "$REPO/stacks/install-octoprint.sh"; then
    ok "Installer deploys helper to /usr/local/sbin/led-helper (root:root 0755)"
else
    fail "Installer does not deploy led-helper"
fi

if [ -f "$_LS_SUDOERS" ]; then
    ok "LED Status sudoers file present: plugins/octoprint-led-status/sudoers/octoprint-led"
    # Narrow scope: lines must end with an explicit state, not bare '/usr/local/sbin/led-helper'
    if grep -qE 'NOPASSWD:.*led-helper$' "$_LS_SUDOERS"; then
        fail "Sudoers rule has wildcard (unrestricted args) — must list explicit states"
    else
        ok "Sudoers rule is narrowly scoped (explicit states, no wildcard)"
    fi
else
    fail "LED Status sudoers file missing: $_LS_SUDOERS"
fi

# Contract: only green:wan and blue:wlan are managed; red:power must not appear
if grep -q 'GREEN=/sys/class/leds/green:wan' "$_LS_HELPER" \
   && grep -q 'BLUE=/sys/class/leds/blue:wlan' "$_LS_HELPER" \
   && grep -q 'RED=/sys/class/leds/red:power' "$_LS_HELPER"; then
    ok "Helper contract: manages green:wan, blue:wlan, and red:power"
else
    fail "Helper does not define expected green:wan / blue:wlan / red:power sysfs paths"
fi

if grep -q 'RED=/sys/class/leds/red:power' "$_LS_HELPER"; then
    ok "Helper manages red:power as appliance power indicator (on=active, off=shutdown)"
else
    fail "Helper missing red:power management"
fi

unset _LS_SETUP _LS_PLUGIN _LS_HELPER _LS_SUDOERS

# ---- Summary --------------------------------------------------
echo ""
echo "=== Automated: $PASS passed, $FAIL failed ==="
echo ""

# ---- Manual device-side checklist ----------------------------
cat <<'MANUAL'
=== Manual checks (run on the device) ===

1. OpenRC service lifecycle:
     rc-service octoprint start   && rc-service octoprint status   # expect: started
     rc-service octoprint restart && rc-service octoprint status   # expect: started
     rc-service octoprint stop    && rc-service octoprint status   # expect: stopped
     rc-service octoprint start

2. Profile build left a ready appliance (no post-boot installer script):
     command -v octoprint                     # expect: /opt/octoprint/venv/bin/octoprint
     ls -ld /opt/octoprint/venv /var/lib/octoprint
     ls ~/install-octoprint.sh                # expect: No such file or directory

3. Memory — compare free RAM before and after the OctoPrint DTB:
     # Boot with generic DTB (msm8916-yiming-uz801v3.dtb) and note:
     free -m
     # Reboot with OctoPrint DTB (msm8916-yiming-uz801v3-octoprint.dtb) and compare:
     free -m
     # Expect: ~30–60 MB more free RAM (modem + Venus firmware memory reclaimed)

4. WiFi still works after switching to the OctoPrint DTB:
     ip link show wlan0             # interface must be present
     ping -c 3 8.8.8.8              # or any reachable LAN host

5. LTE modem absent in OctoPrint profile:
     ls /sys/bus/platform/devices/ | grep -E 'mpss|venus|bam_dmux'
     # expect: no output (modem remoteproc not registered)
     ip link | grep -E 'wwan|rmnet'
     # expect: no output

6. Printer serial device detection (USB OTG cable + printer connected):
     ls /dev/ttyUSB* /dev/ttyACM*   # expect at least one device
     groups octoprint | grep -w dialout   # expect: dialout present

7. OctoPrint reachability on port 5000 (from another LAN host):
     curl -sf http://<device-ip>:5000/   # expect HTTP 200 with OctoPrint HTML
     # Or open in a browser: http://<device-ip>:5000/

MANUAL

[ "$FAIL" -eq 0 ] || { echo "Some automated checks failed — review above."; exit 1; }
exit 0
