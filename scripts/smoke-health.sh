#!/bin/sh
# Smoke check: verify print-health produces all expected category headers.
# Runs on host (macOS/Linux); missing hardware is expected, missing headers are failures.
set -e

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/configs/health/print-health.sh"

if [ ! -x "$SCRIPT" ]; then
    echo "ERROR: $SCRIPT not found or not executable" >&2
    exit 1
fi

echo "[*] Running print-health..."
OUT=$("$SCRIPT" 2>&1)
echo "$OUT"
echo ""
echo "[*] Checking categories..."

_ok=0; _fail=0
for _cat in "uptime/load" "memory" "disk" "thermal" "kernel-errors" "networking" "usb-serial" "octoprint-service"; do
    if echo "$OUT" | grep -q "^--- ${_cat} ---"; then
        echo "  OK: $_cat"
        _ok=$((_ok + 1))
    else
        echo "FAIL: $_cat"
        _fail=$((_fail + 1))
    fi
done

echo ""
echo "Result: $_ok categories OK, $_fail missing"
[ "$_fail" -eq 0 ]
