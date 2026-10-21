#!/usr/bin/env bash
# Multi-OS EDL Flasher for Yiming UZ801 v3.0 (MSM8916)
# Supports: alpine, void, arch, dietpi
# Usage:
#   ./flash.sh [alpine|void|arch|dietpi]        - Lite flash (rootfs + boot only, fast)
#   ./flash.sh -f [alpine|void|arch|dietpi]     - Full flash (GPT + firmware + radio + boot + rootfs)

set -euo pipefail

TOT_SECTORS=7634944
FULL_MODE=false

while getopts "flh" opt; do
    case $opt in
        f) FULL_MODE=true ;;
        l) FULL_MODE=false ;;
        *)
            echo "Usage: $0 [-f|-l] [alpine|void|arch|dietpi]"
            echo "  -l    Lite mode (default): Only flash boot & rootfs"
            echo "  -f    Full mode: Flash GPT, bootloader firmware, radio EFS, boot, and rootfs"
            exit 0
            ;;
    esac
done
shift $((OPTIND - 1))

OS_CHOICE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
SAVED_DIR="$SCRIPT_DIR/saved"

if [[ -z "$OS_CHOICE" ]]; then
    echo "=== UZ801 v3.0 Multi-OS EDL Flasher ==="
    echo "Pilih OS yang ingin di-flash:"
    echo "  [1] Alpine Linux v3.21   (OpenRC + musl)"
    echo "  [2] Void Linux           (runit  + musl)"
    echo "  [3] Arch Linux ARM       (systemd + glibc)"
    echo "  [4] DietPi v10.7         (Debian 12 Bookworm ARMv8)"
    echo "  [5] ImmortalWrt 24.10.6  (procd + LuCI Web UI)"
    echo "  [6] Ubuntu 24.04.5 LTS   (systemd + glibc)"
    echo "  [7] Chimera Linux        (dinit + FreeBSD Userland + LLVM)"
    echo "  [8] postmarketOS v25.06  (OpenRC + musl Mobile Linux)"
    read -rp "Pilihan [1-8] (Default: 1): " num
    case "${num:-1}" in
        1) OS_CHOICE="alpine" ;;
        2) OS_CHOICE="void" ;;
        3) OS_CHOICE="arch" ;;
        4) OS_CHOICE="dietpi" ;;
        5) OS_CHOICE="immortalwrt" ;;
        6) OS_CHOICE="ubuntu" ;;
        7) OS_CHOICE="chimera" ;;
        8) OS_CHOICE="pmos" ;;
        *) echo "[-] Pilihan tidak valid"; exit 1 ;;
    esac
fi

case "$OS_CHOICE" in
    alpine)      ROOTFS_GZ="$FILES_DIR/alpine-rootfs.img.gz" ;;
    void)        ROOTFS_GZ="$FILES_DIR/void-rootfs.img.gz" ;;
    arch)        ROOTFS_GZ="$FILES_DIR/arch-rootfs.img.gz" ;;
    dietpi)      ROOTFS_GZ="$FILES_DIR/dietpi-rootfs.img.gz" ;;
    immortalwrt) ROOTFS_GZ="$FILES_DIR/immortalwrt-rootfs.img.gz" ;;
    ubuntu)      ROOTFS_GZ="$FILES_DIR/ubuntu-rootfs.img.gz" ;;
    chimera)     ROOTFS_GZ="$FILES_DIR/chimera-rootfs.img.gz" ;;
    pmos|postmarketos) ROOTFS_GZ="$FILES_DIR/pmos-rootfs.img.gz" ;;
    *)
        echo "[-] Unknown OS: $OS_CHOICE (choose: alpine, void, arch, dietpi, immortalwrt, ubuntu, chimera, pmos)"
        exit 1
        ;;
esac

BOOT_GZ="$FILES_DIR/boot.img.gz"

[[ -f "$BOOT_GZ" ]]   || { echo "[-] Missing $BOOT_GZ"; exit 1; }
[[ -f "$ROOTFS_GZ" ]] || { echo "[-] Missing $ROOTFS_GZ"; exit 1; }

echo "=== Target Flash Configuration ==="
echo "[+] OS Image : $OS_CHOICE ($(basename "$ROOTFS_GZ"))"
echo "[+] Boot Img : $(basename "$BOOT_GZ")"
echo "[+] Mode     : $([[ "$FULL_MODE" == true ]] && echo "FULL (GPT + Firmware + Radio + Boot + Rootfs)" || echo "LITE (Boot + Rootfs only)")"
echo

raw_tmp="$(mktemp -d)"
trap 'rm -rf "$raw_tmp"' EXIT

if [[ "$FULL_MODE" == true ]]; then
    GPT_BIN="$FILES_DIR/gpt_both0.bin"
    FW_ZIP="$FILES_DIR/firmware.zip"
    [[ -f "$GPT_BIN" ]] || { echo "[-] Missing $GPT_BIN"; exit 1; }
    [[ -f "$FW_ZIP" ]]  || { echo "[-] Missing $FW_ZIP"; exit 1; }

    echo "=== 1. Flashing GPT (14 Partitions) ==="
    dd if="$GPT_BIN" bs=512 count=34         of="${raw_tmp}/primary.bin"        2>/dev/null
    dd if="$GPT_BIN" bs=512 skip=34 count=32 of="${raw_tmp}/backup_entries.bin" 2>/dev/null
    dd if="$GPT_BIN" bs=512 skip=66 count=1  of="${raw_tmp}/backup_header.bin"  2>/dev/null
    edl ws 0                       "${raw_tmp}/primary.bin"
    edl ws $((TOT_SECTORS - 33))  "${raw_tmp}/backup_entries.bin"
    edl ws $((TOT_SECTORS - 1))   "${raw_tmp}/backup_header.bin"

    echo "=== 2. Flashing Bootloader Firmware ==="
    unzip -q -j -d "$raw_tmp" "$FW_ZIP" "*.mbn"
    edl w aboot "${raw_tmp}/aboot.mbn"
    edl w hyp   "${raw_tmp}/hyp.mbn"
    edl w rpm   "${raw_tmp}/rpm.mbn"
    edl w sbl1  "${raw_tmp}/sbl1.mbn"
    edl w tz    "${raw_tmp}/tz.mbn"

    echo "=== 3. Restoring Radio & Calibration Partitions ==="
    for n in fsc fsg modem modemst1 modemst2 persist sec; do
        if [[ -f "$SAVED_DIR/${n}.bin" ]]; then
            echo "[*] Flashing $n..."
            edl w "$n" "$SAVED_DIR/${n}.bin"
        fi
    done
fi

echo "=== Decompressing boot & $OS_CHOICE rootfs ==="
gunzip -c "$BOOT_GZ"   > "${raw_tmp}/boot.raw"
gunzip -c "$ROOTFS_GZ" > "${raw_tmp}/rootfs.raw"

echo "=== Flashing boot ==="
edl w boot "${raw_tmp}/boot.raw"

echo "=== Flashing $OS_CHOICE rootfs ==="
edl w rootfs "${raw_tmp}/rootfs.raw"

echo "=== Rebooting device ==="
edl reset || true
echo "[+] Done! Wait ~35 seconds for $OS_CHOICE to boot."
