#!/bin/bash
# ponytail: smoke check — artifact pipeline wiring only, no actual builds.
# Verifies scripts exist/executable and Makefile targets are defined.
# Safe to run on host (no VM, no root, no build tools required).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$ROOT_DIR/Makefile"
FAIL=0

pass() { echo "  OK   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }

echo "[*] Checking artifact scripts..."

# Each entry: "script-path  makefile-target  description"
check_script() {
    local script="$ROOT_DIR/$1" target="$2" desc="$3"
    if [ -x "$script" ]; then
        pass "$desc script exists and is executable ($1)"
    else
        fail "$desc script missing or not executable ($1)"
    fi
    if grep -q "^${target}:" "$MAKEFILE"; then
        pass "$desc Makefile target '${target}' defined"
    else
        fail "$desc Makefile target '${target}' missing"
    fi
}

check_script scripts/build-dtb.sh      dts         "DTS/DTB generation"
check_script scripts/build-firmware.sh build-all   "Firmware packaging"
check_script scripts/build-gpt.sh      build-all   "GPT generation"
check_script scripts/build-rootfs.sh   build       "Rootfs generation"
check_script scripts/build-images.sh   build       "Boot image generation"

echo "[*] Checking USB serial module build support..."
# build-usb-modules.sh is invoked via build-modules.sh → 'modules' / 'kernel-modules' targets
if [ -x "$ROOT_DIR/scripts/build-usb-modules.sh" ]; then
    pass "build-usb-modules.sh exists and is executable"
else
    fail "build-usb-modules.sh missing or not executable"
fi
if grep -q 'build-usb-modules' "$ROOT_DIR/scripts/build-modules.sh"; then
    pass "build-modules.sh delegates to build-usb-modules.sh"
else
    fail "build-modules.sh does not call build-usb-modules.sh"
fi
if grep -q '^modules:' "$MAKEFILE" && grep -q '^kernel-modules' "$MAKEFILE"; then
    pass "Makefile targets 'modules' and 'kernel-modules' defined"
else
    fail "Makefile missing 'modules' or 'kernel-modules' target"
fi

echo "[*] Checking build-all wires firmware + GPT after build..."
# build-all must depend on build and call both firmware and gpt scripts
if awk '/^build-all:/{found=1} found && /build-firmware\.sh/{print; exit}' "$MAKEFILE" | grep -q 'build-firmware'; then
    pass "build-all calls build-firmware.sh"
else
    fail "build-all does not call build-firmware.sh"
fi
if awk '/^build-all:/{found=1} found && /build-gpt\.sh/{print; exit}' "$MAKEFILE" | grep -q 'build-gpt'; then
    pass "build-all calls build-gpt.sh"
else
    fail "build-all does not call build-gpt.sh"
fi

echo "[*] Checking profile aliases wire through build-all..."
for profile in octoprint docker zoraxy; do
    if grep -q "^${profile}:" "$MAKEFILE" && \
       awk "/^${profile}:/{found=1} found && /build-all/{print; exit}" "$MAKEFILE" | grep -q 'build-all'; then
        pass "profile alias '${profile}' routes through build-all"
    else
        fail "profile alias '${profile}' missing or not routed through build-all"
    fi
done

if [ "$FAIL" = 0 ]; then
    echo "[+] All artifact wiring checks passed"
else
    echo "[!] Artifact wiring check FAILED"
    exit 1
fi
