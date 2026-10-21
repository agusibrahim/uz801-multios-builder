#!/bin/bash
# ponytail: profile contract smoke check — runs on host, no VM needed
set -euo pipefail

PROFILES_DIR="$(cd "$(dirname "$0")/../profiles" && pwd)"
FAIL=0

# Source default + optional named profile, then assert key=expected pairs
check_profile() {
    local name="$1"; shift
    # Reset all contract vars so stale state doesn't mask missing keys
    unset USB_GADGET_INSTALL USB_GADGET_ENABLED USB_GADGET_OTG \
          OCTOPRINT_PREINSTALL ZORAXY_PREINSTALL DOCKER_ENABLE \
          PROFILE_PACKAGES PROFILE_SERVICES STACKS 2>/dev/null || true
    # Load order: base defaults → named profile
    # shellcheck source=/dev/null
    source "$PROFILES_DIR/default.env"
    if [ "$name" != "default" ]; then
        # shellcheck source=/dev/null
        source "$PROFILES_DIR/${name}.env"
    fi

    local ok=1
    for kv in "$@"; do
        local key="${kv%%=*}" expected="${kv#*=}"
        local actual
        actual="$(eval echo "\${${key}:-}")"
        if [ "$actual" != "$expected" ]; then
            echo "  FAIL [$name] $key: expected '$expected', got '$actual'"
            ok=0; FAIL=1
        fi
    done
    [ "$ok" = 1 ] && echo "  OK   [$name]"
}

echo "[*] Checking profile contract..."

check_profile default \
    USB_GADGET_INSTALL=yes \
    USB_GADGET_ENABLED=yes \
    USB_GADGET_OTG=no \
    OCTOPRINT_PREINSTALL=no \
    ZORAXY_PREINSTALL=no \
    DOCKER_ENABLE=no \
    STACKS="" \
    PROFILE_PACKAGES="" \
    PROFILE_SERVICES=""

check_profile octoprint \
    OCTOPRINT_PREINSTALL=yes \
    USB_GADGET_INSTALL=no \
    USB_GADGET_ENABLED=no \
    USB_GADGET_OTG=yes \
    DOCKER_ENABLE=no \
    ZORAXY_PREINSTALL=no \
    STACKS=octoprint

check_profile docker \
    DOCKER_ENABLE=yes \
    OCTOPRINT_PREINSTALL=no \
    ZORAXY_PREINSTALL=no \
    STACKS=""

check_profile zoraxy \
    ZORAXY_PREINSTALL=yes \
    OCTOPRINT_PREINSTALL=no \
    DOCKER_ENABLE=no \
    STACKS=zoraxy

# --- Stack module wiring checks ---
echo "[*] Checking stack module wiring..."
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WIRE_OK=1
BUILD_ROOTFS="$ROOT_DIR/scripts/build-rootfs.sh"

# build-rootfs.sh must use the generic STACKS loop, not hardcoded preinstall blocks
if grep -q 'for _stack in.*STACKS' "$BUILD_ROOTFS"; then
    echo "  OK   build-rootfs.sh uses generic STACKS loop"
else
    echo "  FAIL build-rootfs.sh missing generic STACKS loop"
    WIRE_OK=0; FAIL=1
fi
if grep -q 'OCTOPRINT_PREINSTALL.*yes.*then' "$BUILD_ROOTFS" || \
   grep -q 'ZORAXY_PREINSTALL.*yes.*then' "$BUILD_ROOTFS"; then
    echo "  FAIL build-rootfs.sh still has hardcoded preinstall blocks"
    WIRE_OK=0; FAIL=1
fi

# stacks/run-octoprint.sh must exist, be executable, and reference USB serial modules
if [ -x "$ROOT_DIR/stacks/run-octoprint.sh" ]; then
    echo "  OK   stacks/run-octoprint.sh exists and is executable"
else
    echo "  FAIL stacks/run-octoprint.sh missing or not executable"
    WIRE_OK=0; FAIL=1
fi
if [ -x "$ROOT_DIR/stacks/install-octoprint.sh" ]; then
    echo "  OK   stacks/install-octoprint.sh exists and is executable"
else
    echo "  FAIL stacks/install-octoprint.sh missing or not executable"
    WIRE_OK=0; FAIL=1
fi
RUN_OCTOPRINT="$ROOT_DIR/stacks/run-octoprint.sh"
for _mod in cdc-acm ch341 ftdi_sio pl2303 usbserial; do
    if grep -q "${_mod}" "$RUN_OCTOPRINT"; then
        echo "  OK   ${_mod} referenced in run-octoprint.sh"
    else
        echo "  FAIL ${_mod} not referenced in run-octoprint.sh"
        WIRE_OK=0; FAIL=1
    fi
done

# stacks/run-zoraxy.sh and stacks/install-zoraxy.sh must exist and be executable
if [ -x "$ROOT_DIR/stacks/run-zoraxy.sh" ]; then
    echo "  OK   stacks/run-zoraxy.sh exists and is executable"
else
    echo "  FAIL stacks/run-zoraxy.sh missing or not executable"
    WIRE_OK=0; FAIL=1
fi
if [ -f "$ROOT_DIR/stacks/install-zoraxy.sh" ]; then
    echo "  OK   stacks/install-zoraxy.sh exists"
else
    echo "  FAIL stacks/install-zoraxy.sh missing"
    WIRE_OK=0; FAIL=1
fi

# stacks/install-homer.sh must exist
if [ -f "$ROOT_DIR/stacks/install-homer.sh" ]; then
    echo "  OK   stacks/install-homer.sh exists"
else
    echo "  FAIL stacks/install-homer.sh missing"
    WIRE_OK=0; FAIL=1
fi

[ "$WIRE_OK" = 1 ] && echo "  OK   [stack-module-wiring]"

if [ "$FAIL" = 0 ]; then
    echo "[+] All profile checks passed"
else
    echo "[!] Profile check failed"
    exit 1
fi
