#!/bin/bash
# ponytail: host-side Zoraxy stack hook — invoked by build-rootfs.sh STACKS loop.
# Required env: CHROOT, WORKDIR
set -euo pipefail

: "${CHROOT:?CHROOT env var required}"
: "${WORKDIR:?WORKDIR env var required}"

echo "[*] Preinstalling Zoraxy..."
install -Dm0755 "$WORKDIR/stacks/install-zoraxy.sh" "$CHROOT/tmp/install-zoraxy.sh"
chroot "$CHROOT" bash /tmp/install-zoraxy.sh
rm -f "$CHROOT/tmp/install-zoraxy.sh"
