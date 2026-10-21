#!/bin/bash
set -euo pipefail

# Paths
WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
ROOTFS_TAR="$OUT_DIR/rootfs.tgz"
BOOT_RAW="$STAGING/boot.raw"
ROOT_RAW="$STAGING/rootfs.raw"

# Cleanup on exit
trap 'rm -rf "$STAGING"' EXIT INT TERM

# Sizes (adjustable)
BOOT_SIZE_MIB="${BOOT_SIZE_MIB:=64}"
ROOT_SIZE_MIB="${ROOT_SIZE_MIB:=512}"

# Requirements
[ -d "$OUT_DIR" ] || { echo "No existe directorio: $OUT_DIR"; exit 1; }
[ -f "$ROOTFS_TAR" ] || { echo "No existe $ROOTFS_TAR"; exit 1; }

echo "[*] Output directory: $OUT_DIR"
echo "[*] Temporary staging: $STAGING"
echo "[*] Rootfs source: $ROOTFS_TAR"

# Prep
mkdir -p "$STAGING/boot_dir" "$STAGING/root_dir"

# Create boot image (ext2)
echo "[*] Extracting boot files..."
# CRÍTICO: strip-components=2 para dejar archivos en raíz de boot partition
tar xf "$ROOTFS_TAR" -C "$STAGING/boot_dir" \
    ./boot \
    --exclude='./boot/linux.efi' \
    --strip-components=2 \
    2>/dev/null || true

echo "[*] Boot partition contents:"
ls -lhR "$STAGING/boot_dir/" | head -30 || true

echo "[*] Creating boot image ($BOOT_SIZE_MIB MiB)..."
truncate -s "$((BOOT_SIZE_MIB * 1024 * 1024))" "$BOOT_RAW"
mkfs.ext2 -F -d "$STAGING/boot_dir" "$BOOT_RAW" >/dev/null 2>&1

# Create rootfs image (ext4)
echo "[*] Extracting rootfs files..."
tar xpf "$ROOTFS_TAR" -C "$STAGING/root_dir" \
    --exclude='./boot/*' \
    --exclude='./root/*' \
    --exclude='./dev/*' 2>/dev/null || true

echo "[*] Creating rootfs image ($ROOT_SIZE_MIB MiB)..."
truncate -s "$((ROOT_SIZE_MIB * 1024 * 1024))" "$ROOT_RAW"
mkfs.ext4 -F -d "$STAGING/root_dir" "$ROOT_RAW" >/dev/null 2>&1

# Compress raw images with gzip
echo "[*] Compressing images..."
gzip -c "$BOOT_RAW" > "$OUT_DIR/boot.img.gz"
gzip -c "$ROOT_RAW" > "$OUT_DIR/rootfs.img.gz"

echo "[+] Images created successfully:"
echo "    - $OUT_DIR/boot.img.gz ($(du -h "$OUT_DIR/boot.img.gz" | cut -f1))"
echo "    - $OUT_DIR/rootfs.img.gz ($(du -h "$OUT_DIR/rootfs.img.gz" | cut -f1))"
