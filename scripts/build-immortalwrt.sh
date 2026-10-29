#!/bin/bash
set -euo pipefail

[ -f ./variables.env ] && source ./variables.env

WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="ImmortalWrt"
PASSWORD="${PASSWORD:-changeme}"
WIFI_SSID="${WIFI_SSID:-Kaylaa}"
WIFI_PASS="${WIFI_PASS:-agus00000}"

IWRT_URL="https://downloads.immortalwrt.org/releases/24.10.6/targets/armsr/armv8/immortalwrt-24.10.6-armsr-armv8-rootfs.tar.gz"
IWRT_TAR="$OUT_DIR/immortalwrt-24.10.6-armsr-armv8-rootfs.tar.gz"

trap 'rm -rf "$STAGING"' EXIT INT TERM

mkdir -p "$OUT_DIR" "$CHROOT"

if [ ! -f "$IWRT_TAR" ]; then
    echo "[*] Downloading ImmortalWrt 24.10.6 aarch64 rootfs..."
    wget -q --show-progress "$IWRT_URL" -O "$IWRT_TAR"
fi

echo "[*] Extracting ImmortalWrt base rootfs..."
tar -xzf "$IWRT_TAR" -C "$CHROOT"

mkdir -p "$CHROOT/var/lock" "$CHROOT/tmp"
rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# Remove kmods feed for 6.6 kernel since we use mainline 6.12.1-msm8916 kernel, and disable signature check
sed -i '/immortalwrt_kmods/d' "$CHROOT/etc/opkg/distfeeds.conf"
sed -i 's/^option check_signature/# option check_signature/' "$CHROOT/etc/opkg.conf" 2>/dev/null || true

echo "[*] Installing packages via opkg (ModemManager, LuCI Argon, L2TP VPN, WiFi, kmod, tools)..."
chroot "$CHROOT" /bin/sh -e -c "
opkg update
opkg install --force-depends \
    modemmanager \
    luci-proto-modemmanager \
    luci-proto-ppp \
    xl2tpd \
    ppp-mod-pppol2tp \
    resolveip \
    libqmi \
    wpad-basic-mbedtls \
    iw \
    iwinfo \
    wireless-regdb \
    wifi-scripts \
    resize2fs \
    blkid \
    kmod \
    bash \
    htop \
    nano \
    curl \
    ca-bundle \
    luci-theme-argon
rm -rf /tmp/opkg-lists/* /var/opkg-lists/*
"

# Fix relative path in /lib/netifd/proto/l2tp.sh so netifd & LuCI register L2TP protocol properly
sed -i 's|\.\./netifd-proto\.sh|/lib/netifd/netifd-proto.sh|g' "$CHROOT/lib/netifd/proto/l2tp.sh" 2>/dev/null || true

# Restore OpenWrt resolv.conf symlink
ln -sf /tmp/resolv.conf "$CHROOT/etc/resolv.conf"

echo "[*] Copying kernel modules (6.12.1-msm8916), firmware, and rmtfs from Alpine rootfs..."
mkdir -p "$STAGING/alpine"
tar -xzf "$OUT_DIR/alpine-rootfs.tgz" -C "$STAGING/alpine" \
    ./lib \
    ./usr/lib \
    ./usr/sbin/rmtfs

rm -rf "$CHROOT/lib/modules/"*
mkdir -p "$CHROOT/lib/modules" "$CHROOT/lib/firmware"
cp -af "$STAGING/alpine/lib/modules/"* "$CHROOT/lib/modules/"
rm -f "$CHROOT/lib/firmware/regulatory.db"*
cp -af "$STAGING/alpine/lib/firmware/"* "$CHROOT/lib/firmware/"

# Also create flat .ko symlinks in /lib/modules/6.12.1-msm8916/ for OpenWrt kmodloader compatibility
find "$CHROOT/lib/modules/6.12.1-msm8916/kernel" -name "*.ko" -exec ln -sf {} "$CHROOT/lib/modules/6.12.1-msm8916/" \;

# Copy rmtfs and its required libraries (libqrtr.so.1, libudev.so.1)
install -Dm0755 "$STAGING/alpine/usr/sbin/rmtfs" "$CHROOT/usr/sbin/rmtfs"
cp -a "$STAGING/alpine/usr/lib/libqrtr.so.1"* "$CHROOT/usr/lib/"
cp -a "$STAGING/alpine/lib/libudev.so.1"* "$CHROOT/usr/lib/" 2>/dev/null || cp -a "$STAGING/alpine/usr/lib/libudev.so.1"* "$CHROOT/usr/lib/"

echo "[*] Installing adbd and USB Gadget..."
install -Dm0755 configs/adb/adbd "$CHROOT/usr/bin/adbd"
[ -f configs/dashboard/uz801-dashboard ] && install -Dm0755 configs/dashboard/uz801-dashboard "$CHROOT/usr/bin/uz801-dashboard"
install -Dm0755 configs/adb/libcrypto.so.1.1 "$CHROOT/usr/lib/libcrypto.so.1.1"
install -Dm0644 configs/adb/adb_profile "$CHROOT/etc/adb_profile"

mkdir -p "$CHROOT/system/bin"
cat > "$CHROOT/system/bin/sh" <<'SHWRAP'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=${TERM:-xterm-256color}
exec /bin/bash "$@"
SHWRAP
chmod 0755 "$CHROOT/system/bin/sh"

install -Dm0755 configs/usb-gadget/usb-gadget.sh "$CHROOT/usr/sbin/usb-gadget"
cat > "$CHROOT/etc/usb-gadget.conf" << 'EOF'
USE_NCM=1
ENABLE_OTG=0
EOF

# Remove Chinese-specific uci-defaults so timezone (Asia/Jakarta), English LuCI, and official ImmortalWrt mirror are preserved
rm -f "$CHROOT/etc/uci-defaults/99-default-settings-chinese" "$CHROOT/etc/uci-defaults/"*zh-cn*
sed -i "s/eth0/usb0/g" "$CHROOT/etc/board.d/99-default_network" 2>/dev/null || true

echo "[*] Configuring root password, network, wireless, firewall, and UZ801 init service..."
# Set root password to $PASSWORD
chroot "$CHROOT" /bin/sh -e -c "
PASS_HASH=\$(openssl passwd -6 '${PASSWORD}' 2>/dev/null || echo '')
if [ -n \"\$PASS_HASH\" ]; then
    sed -i \"s|^root:[^:]*:|root:\${PASS_HASH}:|\" /etc/shadow
fi
"

cat > "$CHROOT/etc/config/system" << EOF
config system
	option hostname '${HOST_NAME}'
	option timezone 'WIB-7'
	option zonename 'Asia/Jakarta'
	option ttylogin '0'
	option log_size '64'
	option urandom_seed '0'

config timeserver 'ntp'
	option enabled '1'
	option enable_server '0'
	list server '0.openwrt.pool.ntp.org'
	list server '1.openwrt.pool.ntp.org'
	list server 'time.cloudflare.com'
EOF

cat > "$CHROOT/etc/config/dropbear" << 'EOF'
config dropbear
	option PasswordAuth 'on'
	option RootPasswordAuth 'on'
	option Port '22'
EOF

cat > "$CHROOT/etc/config/network" << 'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fd42:8916:uz80::/48'

config interface 'lan'
	option device 'usb0'
	option proto 'static'
	option ipaddr '192.168.42.1'
	option netmask '255.255.255.0'
	option ip6assign '60'

config interface 'wwan'
	option proto 'dhcp'
	option peerdns '1'
	option metric '20'
EOF

rm -f "$CHROOT/etc/config/wireless"

# Allow incoming SSH/HTTP on wan zone & add wwan/wwan0 to wan zone
sed -i "s/list network 'wan6'/list network 'wan6'\n\tlist network 'wwan'\n\tlist device 'wwan0'/" "$CHROOT/etc/config/firewall"
sed -i "s/option input\t\tREJECT/option input\t\tACCEPT/" "$CHROOT/etc/config/firewall"

# Configure serial console on ttyMSM0 in /etc/inittab
grep -q "ttyMSM0" "$CHROOT/etc/inittab" || echo "ttyMSM0::askfirst:/usr/libexec/login.sh" >> "$CHROOT/etc/inittab"

# Create UZ801 hardware & LTE init script
cat > "$CHROOT/etc/init.d/uz801-init" << 'EOF'
#!/bin/sh /etc/rc.common

START=12
USE_PROCD=1

start_service() {
    # 1. Create /dev/disk/by-partlabel symlinks required by rmtfs
    mkdir -p /dev/disk/by-partlabel
    for p in /sys/block/mmcblk0/mmcblk0p*; do
        [ -e "$p/uevent" ] || continue
        devname=$(sed -n 's/^DEVNAME=//p' "$p/uevent")
        partname=$(sed -n 's/^PARTNAME=//p' "$p/uevent")
        [ -n "$devname" ] && [ -n "$partname" ] && ln -sf "/dev/$devname" "/dev/disk/by-partlabel/$partname"
    done

    # 2. Expand rootfs on first boot
    if [ ! -f /etc/expand-rootfs.done ]; then
        resize2fs /dev/mmcblk0p14 >/dev/null 2>&1 || true
        touch /etc/expand-rootfs.done
        sync
    fi

    # 3. Load MSM8916 kernel modules (USB gadget, WiFi WCN3620, 4G LTE QDSP6, ZRAM)
    for mod in zram libcomposite u_ether usb_f_ncm usb_f_rndis usb_f_fs \
               mdt_loader qcom_common qcom_pil_info qcom_wcnss_pil wcnss_ctrl wcn36xx \
               qcom_q6v5 qcom_q6v5_mss qcom_bam_dmux rpmsg_wwan_ctrl rmnet; do
        modprobe "$mod" 2>/dev/null || true
    done

    # 4. Configure 256MB zram swap
    if [ -b /dev/zram0 ]; then
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        echo 256M > /sys/block/zram0/disksize 2>/dev/null || true
        mkswap /dev/zram0 >/dev/null 2>&1 && swapon /dev/zram0 2>/dev/null || true
    fi

    # 5. Start USB Gadget (CDC-NCM 192.168.42.1/24 + FunctionFS ADB)
    /usr/sbin/usb-gadget start >/dev/null 2>&1 || true

    # 6. Run rmtfs under procd supervision
    procd_open_instance "rmtfs"
    procd_set_param command /usr/sbin/rmtfs -P -r -s
    procd_set_param respawn
    procd_close_instance

    # 7. Background helper for WiFi auto-detect and 4G LTE ModemManager connection
    (
        sleep 4
        if [ -d /sys/class/ieee80211/phy0 ] && [ ! -s /etc/config/wireless ]; then
            wifi config >/dev/null 2>&1 || true
            uci set wireless.radio0.disabled='0' 2>/dev/null || true
            uci set wireless.default_radio0.mode='sta' 2>/dev/null || true
            uci set wireless.default_radio0.network='wwan' 2>/dev/null || true
            uci set wireless.default_radio0.ssid='Kaylaa' 2>/dev/null || true
            uci set wireless.default_radio0.encryption='psk2' 2>/dev/null || true
            uci set wireless.default_radio0.key='agus00000' 2>/dev/null || true
            uci commit wireless 2>/dev/null || true
            wifi up >/dev/null 2>&1 || true
        fi
        for i in $(seq 1 35); do
            ip link set usb0 up 2>/dev/null || true
            ip addr replace 192.168.42.1/24 dev usb0 2>/dev/null || true

            # Report wwan/net/rpmsg kernel events to OpenWrt ModemManager (built without udev)
            for d in /sys/class/wwan/*; do
                [ -e "$d" ] && mmcli --report-kernel-event="action=add,name=$(basename "$d"),subsystem=wwan" >/dev/null 2>&1 || true
            done
            for d in /sys/class/net/wwan*; do
                [ -e "$d" ] && mmcli --report-kernel-event="action=add,name=$(basename "$d"),subsystem=net" >/dev/null 2>&1 || true
            done
            for d in /sys/class/rpmsg/*; do
                [ -e "$d" ] && mmcli --report-kernel-event="action=add,name=$(basename "$d"),subsystem=rpmsg" >/dev/null 2>&1 || true
            done

            if mmcli -m 0 >/dev/null 2>&1; then
                mmcli -m 0 --set-power-state-on >/dev/null 2>&1 || true
                mmcli -m 0 -e >/dev/null 2>&1 || true
                if ! ip addr show wwan0 2>/dev/null | grep -q "inet "; then
                    OP_CODE=$(mmcli -i 0 -K 2>/dev/null | awk -F': ' '/sim\.properties\.operator-code/{print $2}')
                    APN_VAL="internet"
                    case "$OP_CODE" in
                        51089) APN_VAL="3gprs" ;;
                        51010) APN_VAL="byu" ;;
                        51001|51021) APN_VAL="indosatgprs" ;;
                        51011|51008) APN_VAL="axis" ;;
                    esac
                    mmcli -m 0 --simple-connect="apn=${APN_VAL},ip-type=ipv4" >/dev/null 2>&1 || true
                    for b_idx in 1 2 3 4 5; do
                        BEARER=$(mmcli -m 0 -K 2>/dev/null | awk -F': ' "/modem\.generic\.bearers\.value\[${b_idx}\]/{print \$2}")
                        [ -n "$BEARER" ] || continue
                        BINFO=$(mmcli -b "$BEARER" -K 2>/dev/null)
                        BIP=$(echo "$BINFO" | awk -F': ' '/bearer\.ipv4-config\.address/{print $2}')
                        BPFX=$(echo "$BINFO" | awk -F': ' '/bearer\.ipv4-config\.prefix/{print $2}')
                        BGW=$(echo "$BINFO" | awk -F': ' '/bearer\.ipv4-config\.gateway/{print $2}')
                        if [ -n "$BIP" ] && [ "$BIP" != "--" ]; then
                            ip link set wwan0 up 2>/dev/null || true
                            ip addr replace "${BIP}/${BPFX:-30}" dev wwan0 2>/dev/null || true
                            [ -n "$BGW" ] && [ "$BGW" != "--" ] && ip route replace default via "$BGW" dev wwan0 metric 10 2>/dev/null || true
                            break
                        fi
                    done
                else
                    break
                fi
            fi
            sleep 4
        done
    ) &
}
EOF
# Disable default OpenWrt dnsmasq & firewall4 nftables rules that conflict with usb-gadget dnsmasq & LuCI on wwan
rm -f "$CHROOT/etc/rc.d/S19dnsmasq" "$CHROOT/etc/rc.d/S19firewall"
ln -sf ../init.d/dropbear "$CHROOT/etc/rc.d/S19dropbear" 2>/dev/null || true
ln -sf ../init.d/uhttpd "$CHROOT/etc/rc.d/S50uhttpd" 2>/dev/null || true
chmod 0755 "$CHROOT/etc/init.d/uz801-init"
ln -sf ../init.d/uz801-init "$CHROOT/etc/rc.d/S12uz801-init"

echo "[*] Creating ImmortalWrt 24.10.6 ext4 rootfs image (512 MiB)..."
ROOT_RAW="$STAGING/immortalwrt-rootfs.raw"
truncate -s $((512 * 1024 * 1024)) "$ROOT_RAW"
mkfs.ext4 -F -d "$CHROOT" "$ROOT_RAW" >/dev/null 2>&1
gzip -c "$ROOT_RAW" > "$OUT_DIR/immortalwrt-rootfs.img.gz"

echo "[+] ImmortalWrt 24.10.6 rootfs image created:"
ls -lh "$OUT_DIR/immortalwrt-rootfs.img.gz"
