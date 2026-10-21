#!/bin/sh
# Expand rootfs filesystem on first boot
set -e

ROOT_DEV=$(awk '$2 == "/" {print $1}' /proc/mounts | head -1)
[ -b "$ROOT_DEV" ] || ROOT_DEV="/dev/mmcblk0p14"
echo "[*] Expanding filesystem on $ROOT_DEV..."

# Resize filesystem online to fill partition (do NOT run e2fsck -fy on a live rw mounted rootfs!)
if resize2fs "$ROOT_DEV"; then
    echo "[+] Filesystem expanded successfully!"
    df -h /
    touch /var/lib/expand-rootfs.done
    sync
else
    echo "ERROR: Failed to resize filesystem"
    exit 1
fi
