#!/usr/bin/env bash
# Multi-OS EDL Flasher for Yiming UZ801 v3.0 (MSM8916)
# Supports: alpine, void, arch, dietpi, immortalwrt, ubuntu, chimera, pmos, kali, alma, goos
# Usage:
#   ./flash.sh [target]                      - Lite flash (boot & rootfs)
#   ./flash.sh -f [target]                   - Full flash (GPT + firmware + radio + boot + rootfs)
#   ./flash.sh -s "SSID" -p "PASS" [target]  - Suntikkan WiFi SSID & Password langsung saat flash!

set -euo pipefail

TOT_SECTORS=7634944
FULL_MODE=false
CUSTOM_WIFI_SSID=""
CUSTOM_WIFI_PASS=""

while getopts "flhs:p:" opt; do
    case $opt in
        f) FULL_MODE=true ;;
        l) FULL_MODE=false ;;
        s) CUSTOM_WIFI_SSID="$OPTARG" ;;
        p) CUSTOM_WIFI_PASS="$OPTARG" ;;
        *)
            echo "Usage: $0 [-f|-l] [-s <ssid> -p <password>] [target]"
            echo "  -l           Lite mode (default): Flash boot & rootfs"
            echo "  -f           Full mode: Flash GPT, bootloader firmware, radio EFS, boot, & rootfs"
            echo "  -s <ssid>    Suntikkan nama WiFi (SSID) langsung ke rootfs sebelum diflash"
            echo "  -p <pass>    Suntikkan password WiFi (WPA-PSK) langsung ke rootfs"
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
    echo "  [9] Kali Linux Rolling   (systemd + Pocket 4G Pentest Drop-Box)"
    echo "  [10] AlmaLinux 9.8       (systemd + glibc + dnf/rpm Enterprise)"
    echo "  [11] UZ801 GoOS v1.0     (Pure Go PID 1 Appliance Firmware)"
    read -rp "Pilihan [1-11] (Default: 1): " num
    case "${num:-1}" in
        1) OS_CHOICE="alpine" ;;
        2) OS_CHOICE="void" ;;
        3) OS_CHOICE="arch" ;;
        4) OS_CHOICE="dietpi" ;;
        5) OS_CHOICE="immortalwrt" ;;
        6) OS_CHOICE="ubuntu" ;;
        7) OS_CHOICE="chimera" ;;
        8) OS_CHOICE="pmos" ;;
        9) OS_CHOICE="kali" ;;
        10) OS_CHOICE="alma" ;;
        11) OS_CHOICE="goos" ;;
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
    kali)        ROOTFS_GZ="$FILES_DIR/kali-rootfs.img.gz" ;;
    alma|almalinux) ROOTFS_GZ="$FILES_DIR/alma-rootfs.img.gz" ;;
    goos)        ROOTFS_GZ="$FILES_DIR/goos-rootfs.img.gz" ;;
    boot)        ROOTFS_GZ="" ;;
    *)
        echo "[-] Unknown OS: $OS_CHOICE (choose: alpine, void, arch, dietpi, immortalwrt, ubuntu, chimera, pmos, kali, alma, goos, boot)"
        exit 1
        ;;
esac

BOOT_GZ="$FILES_DIR/boot.img.gz"

[[ -f "$BOOT_GZ" ]] || { echo "[-] Missing $BOOT_GZ"; exit 1; }
if [[ "$OS_CHOICE" != "boot" ]]; then
    [[ -f "$ROOTFS_GZ" ]] || { echo "[-] Missing $ROOTFS_GZ"; exit 1; }
fi

echo "=== Target Flash Configuration ==="
echo "[+] Target   : $OS_CHOICE"
echo "[+] Boot Img : $(basename "$BOOT_GZ")"
echo

raw_tmp="$(mktemp -d)"
trap 'rm -rf "$raw_tmp"' EXIT

echo "=== Decompressing image(s) ==="
gunzip -c "$BOOT_GZ" > "${raw_tmp}/boot.raw"
if [[ "$OS_CHOICE" != "boot" ]]; then
    gunzip -c "$ROOTFS_GZ" > "${raw_tmp}/rootfs.raw"
fi

# Suntikkan WiFi kustom langsung ke dalam ext4 rootfs jika parameter -s / -p diberikan
if [[ -n "$CUSTOM_WIFI_SSID" ]] && [[ "$OS_CHOICE" != "boot" ]]; then
    echo "[*] Menyuntikkan WiFi SSID '$CUSTOM_WIFI_SSID' ke dalam rootfs..."
    wifi_tmp="${raw_tmp}/wlan.nmconnection"
    cat > "$wifi_tmp" << EOF
[connection]
id=${CUSTOM_WIFI_SSID}
uuid=f9ab6583-91df-496f-90a8-639bd3253a28
type=wifi
autoconnect=true
interface-name=wlan0

[wifi]
mode=infrastructure
ssid=${CUSTOM_WIFI_SSID}
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk=${CUSTOM_WIFI_PASS}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto

[proxy]
EOF
    chmod 0600 "$wifi_tmp"

    if command -v e2cp >/dev/null 2>&1; then
        e2cp -G 0 -O 0 -P 600 "$wifi_tmp" "${raw_tmp}/rootfs.raw:/etc/NetworkManager/system-connections/wlan.nmconnection" 2>/dev/null || true
        # Juga suntikkan ke wpa_supplicant jika ada
        wpa_tmp="${raw_tmp}/wpa_supplicant.conf"
        cat > "$wpa_tmp" << EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="${CUSTOM_WIFI_SSID}"
    psk="${CUSTOM_WIFI_PASS}"
}
EOF
        chmod 0600 "$wpa_tmp"
        e2cp -G 0 -O 0 -P 600 "$wpa_tmp" "${raw_tmp}/rootfs.raw:/etc/wpa_supplicant/wpa_supplicant.conf" 2>/dev/null || true

        # Khusus OpenWrt / ImmortalWrt: Suntikkan juga ke sistem UCI (/etc/config/wireless)
        openwrt_wireless="${raw_tmp}/wireless.uci"
        enc_type="psk2"
        [[ -z "$CUSTOM_WIFI_PASS" ]] && enc_type="none"
        cat > "$openwrt_wireless" << EOF
config wifi-device 'radio0'
	option type 'mac80211'
	option path 'platform/soc@0/a204000.remoteproc/remoteproc/remoteproc0/remoteproc0:smd-edge/remoteproc0:smd-edge.WCNSS_CTRL.-1.-1/a204000.remoteproc:smd-edge:wcnss:wifi'
	option band '2g'
	option channel '1'
	option htmode 'HT20'
	option country 'ID'
	option disabled '0'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'wwan'
	option mode 'sta'
	option ssid '${CUSTOM_WIFI_SSID}'
	option encryption '${enc_type}'
	option key '${CUSTOM_WIFI_PASS}'
EOF
        chmod 0644 "$openwrt_wireless"
        e2cp -G 0 -O 0 -P 644 "$openwrt_wireless" "${raw_tmp}/rootfs.raw:/etc/config/wireless" 2>/dev/null || true

        echo "[+] Berhasil menyuntikkan WiFi '$CUSTOM_WIFI_SSID' via e2tools (NetworkManager, wpa_supplicant & OpenWrt UCI)!"
    else
        echo "[!] Tool e2cp tidak ditemukan, instal via 'brew install e2tools' untuk fitur penyuntikan WiFi langsung."
    fi
fi

if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -q "2c2d59162055f8d2"; then
    echo "=== Rebooting device from ADB to Fastboot (lk2nd) ==="
    adb -s 2c2d59162055f8d2 reboot bootloader || true
    for _i in {1..16}; do
        if command -v fastboot >/dev/null 2>&1 && fastboot devices 2>/dev/null | grep -q "fastboot"; then
            break
        fi
        sleep 0.5
    done
fi
if command -v fastboot >/dev/null 2>&1 && fastboot devices 2>/dev/null | grep -q "fastboot"; then
    echo "=== Switching lk2nd Fastboot to Qualcomm EDL 9008 ==="
    fastboot oem edl 2>/dev/null || fastboot reboot-emergency 2>/dev/null || true
    sleep 2
fi

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

echo "=== Flashing boot ==="
edl w boot "${raw_tmp}/boot.raw"

if [[ "$OS_CHOICE" != "boot" ]]; then
    echo "=== Flashing $OS_CHOICE rootfs ==="
    edl w rootfs "${raw_tmp}/rootfs.raw"
fi

echo "=== Rebooting device ==="
edl reset || true
echo "[+] Done! Wait ~35 seconds for $OS_CHOICE to boot."
