#!/bin/bash

GADGET_PATH="/sys/kernel/config/usb_gadget/msm8916"
CONFIG_FILE="/etc/usb-gadget.conf"

# Load configuration from file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    fi
    
    # Set defaults if not configured
    : ${USE_NCM:=1}
    : ${ENABLE_OTG:=0}
}

# Update a single configuration value
update_config() {
    local key="$1"
    local value="$2"
    
    # Create config file if doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
# MSM8916 USB Gadget Configuration
# Generated automatically - modify with enable_*/disable_* commands

USE_NCM=1           # 1 = NCM (Linux/Mac), 0 = RNDIS (Windows)
ENABLE_OTG=0        # 1 = OTG Host mode, 0 = Gadget mode
EOF
    fi
    
    # Update or add the key
    if grep -q "^${key}=" "$CONFIG_FILE"; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$CONFIG_FILE"
    else
        echo "${key}=${value}" >> "$CONFIG_FILE"
    fi
    
    log "Configuration updated: ${key}=${value}"
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $@"
    logger -t usb-gadget "$@" 2>/dev/null || true
}

get_serial_number() {
    echo "2c2d59162055f8d2"
}

generate_mac_address() {
    local prefix="$1"
    local serial="$(get_serial_number)"
    local hash="$(echo "${serial}${prefix}" | md5sum | cut -c1-12)"
    
    local b1="${hash:0:2}"
    local b2="${hash:2:2}"
    local b3="${hash:4:2}"
    local b4="${hash:6:2}"
    local b5="${hash:8:2}"
    local b6="${hash:10:2}"
    
    # Set locally administered, unicast
    b1="$(printf '%02x' $((0x${b1} & 0xfe | 0x02)))"
    
    echo "${b1}:${b2}:${b3}:${b4}:${b5}:${b6}"
}

setup_gadget() {
    load_config
    
    # If already active and bound to UDC, just ensure usb0, dnsmasq, and dropbear are up
    if [ -d "${GADGET_PATH}" ] && [ -s "${GADGET_PATH}/UDC" ]; then
        if ip link show usb0 >/dev/null 2>&1; then
            ip link set usb0 up 2>/dev/null || true
            ip addr replace 192.168.42.1/24 dev usb0 2>/dev/null || true
        if [ ! -f /run/dnsmasq-usb0.pid ] || ! kill -0 $(cat /run/dnsmasq-usb0.pid 2>/dev/null) 2>/dev/null; then
            /usr/sbin/dnsmasq --user=root --interface=usb0 --bind-interfaces --except-interface=lo \
                --dhcp-range=192.168.42.10,192.168.42.250,255.255.255.0,12h \
                --dhcp-option=3 --dhcp-leasefile=/run/dnsmasq-usb0.leases \
                --pid-file=/run/dnsmasq-usb0.pid 2>/dev/null || true
        fi
        fi
        return 0
    fi

    # Wait up to 10s for UDC to appear
    for _i in $(seq 1 20); do
        [ -n "$(ls /sys/class/udc/ 2>/dev/null)" ] && break
        sleep 0.5
    done

    # Check if OTG host mode requested
    if [ "$ENABLE_OTG" = "1" ]; then
        log "OTG Host mode enabled - skipping gadget setup"
        echo "host" > /sys/class/udc/ci_hdrc.0/device/role 2>/dev/null || true
        return 0
    fi
    echo "device" > /sys/class/udc/ci_hdrc.0/device/role 2>/dev/null || true
    
    log "Setting up USB gadget"
    
    # Generate MAC addresses
    MAC_HOST=$(generate_mac_address "host")
    MAC_DEV=$(generate_mac_address "dev")
    
    modprobe libcomposite 2>/dev/null || true
    modprobe usb_f_ncm 2>/dev/null || true
    modprobe usb_f_fs 2>/dev/null || true
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>/dev/null || true
    
    mkdir -p "${GADGET_PATH}"
    cd "${GADGET_PATH}"
    
    # Device descriptors
    echo "0x0200" > bcdUSB
    echo "0x1d6b" > idVendor
    echo "0x0104" > idProduct
    echo "0x0100" > bcdDevice
    echo "0x40"   > bMaxPacketSize0
    echo "0xEF" > bDeviceClass
    echo "0x02" > bDeviceSubClass
    echo "0x01" > bDeviceProtocol
    
    # Strings
    mkdir -p strings/0x409
    echo "$(get_serial_number)" > strings/0x409/serialnumber
    echo "MSM8916" > strings/0x409/manufacturer
    echo "USB Network" > strings/0x409/product
    
    # Configuration
    mkdir -p configs/c.1/strings/0x409
    echo "250" > configs/c.1/MaxPower
    
    # Network function
    if [ "$USE_NCM" = "1" ]; then
        log "Configuring NCM (Linux/Mac) - MAC: $MAC_HOST / $MAC_DEV"
        mkdir -p functions/ncm.usb0
        echo "$MAC_HOST" > functions/ncm.usb0/host_addr
        echo "$MAC_DEV" > functions/ncm.usb0/dev_addr
        ln -sf "${GADGET_PATH}/functions/ncm.usb0" configs/c.1/ncm.usb0
        echo "NCM" > configs/c.1/strings/0x409/configuration
        echo "0x80" > configs/c.1/bmAttributes
    else
        log "Configuring RNDIS (Windows) - MAC: $MAC_HOST / $MAC_DEV"
        mkdir -p functions/rndis.usb0
        echo "$MAC_HOST" > functions/rndis.usb0/host_addr
        echo "$MAC_DEV" > functions/rndis.usb0/dev_addr
        ln -sf "${GADGET_PATH}/functions/rndis.usb0" configs/c.1/rndis.usb0
        echo "RNDIS" > configs/c.1/strings/0x409/configuration
        echo "0xe0" > configs/c.1/bmAttributes
        
        # Windows compatibility
        echo 1 > os_desc/use
        echo 0xcd > os_desc/b_vendor_code
        echo MSFT100 > os_desc/qw_sign
        echo RNDIS > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
        echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
        ln -sf "${GADGET_PATH}/configs/c.1" os_desc/c.1
    fi
    
    # ADB function (FunctionFS)
    if [ -x /usr/bin/adbd ]; then
        log "Configuring ADB (FunctionFS)"
        mkdir -p /dev/pts /dev/usb-ffs/adb
        mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts 2>/dev/null || true
        mkdir -p functions/ffs.adb
        ln -sf "${GADGET_PATH}/functions/ffs.adb" configs/c.1/ffs.adb
        mountpoint -q /dev/usb-ffs/adb || mount -t functionfs adb /dev/usb-ffs/adb 2>/dev/null || true
        if ! pgrep -x adbd >/dev/null 2>&1; then
            start-stop-daemon --start --background --exec /usr/bin/adbd -- -D 2>/dev/null || \
                setsid /usr/bin/adbd -D >/run/adbd.log 2>&1 </dev/null &
        fi
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            [ -e /dev/usb-ffs/adb/ep1 ] && break
            sleep 0.3
        done
    fi

    # Enable gadget (with automatic fallback to pure NCM if ffs.adb fails UDC bind)
    UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
    if [ -n "$UDC" ]; then
        echo "$UDC" > UDC 2>/dev/null || true
        if [ ! -s "${GADGET_PATH}/UDC" ]; then
            log "UDC bind with ffs.adb failed, falling back to NCM"
            rm -f configs/c.1/ffs.adb 2>/dev/null || true
            echo "$UDC" > UDC 2>/dev/null || true
        fi
    fi
    
    # Bring usb0 up immediately so host sees link active (carrier=1), DHCP works, and SSH is reachable
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        ip link show usb0 >/dev/null 2>&1 && break
        sleep 0.2
    done
    if ip link show usb0 >/dev/null 2>&1; then
        ip link set usb0 up 2>/dev/null || true
        ip addr replace 192.168.42.1/24 dev usb0 2>/dev/null || true
        kill $(cat /run/dnsmasq-usb0.pid 2>/dev/null) 2>/dev/null || true
        /usr/sbin/dnsmasq --user=root --interface=usb0 --bind-interfaces --except-interface=lo \
            --dhcp-range=192.168.42.10,192.168.42.250,255.255.255.0,12h \
            --dhcp-option=3 --dhcp-leasefile=/run/dnsmasq-usb0.leases \
            --pid-file=/run/dnsmasq-usb0.pid 2>/dev/null || true
    fi

    log "USB gadget enabled on $UDC"
    log "Interface usb0 ready (192.168.42.1/24) + ADB active"
}

teardown_gadget() {
    log "Tearing down USB gadget"
    
    [ ! -d "${GADGET_PATH}" ] && return 0
    
    cd "${GADGET_PATH}"
    
    # Disable gadget
    echo "" > UDC 2>/dev/null || true
    killall adbd 2>/dev/null || true
    umount /dev/usb-ffs/adb 2>/dev/null || true
    kill $(cat /run/dnsmasq-usb0.pid 2>/dev/null) 2>/dev/null || true
    
    # Remove config
    rm -f configs/c.1/ncm.usb0 2>/dev/null || true
    rm -f configs/c.1/rndis.usb0 2>/dev/null || true
    rm -f configs/c.1/ffs.adb 2>/dev/null || true
    rm -f os_desc/c.1 2>/dev/null || true
    rmdir configs/c.1/strings/0x409 2>/dev/null || true
    rmdir configs/c.1 2>/dev/null || true
    
    # Remove functions
    rmdir functions/ncm.usb0 2>/dev/null || true
    rmdir functions/rndis.usb0 2>/dev/null || true
    rmdir functions/ffs.adb 2>/dev/null || true
    
    # Remove strings and gadget
    rmdir strings/0x409 2>/dev/null || true
    cd ..
    rmdir msm8916 2>/dev/null || true
}

status() {
    load_config
    
    echo "Configuration:"
    echo "  NCM Mode: $([ "$USE_NCM" = "1" ] && echo "Enabled (Linux/Mac)" || echo "Disabled (RNDIS/Windows)")"
    echo "  OTG Host: $([ "$ENABLE_OTG" = "1" ] && echo "Enabled" || echo "Disabled")"
    echo ""
    
    if [ "$ENABLE_OTG" = "1" ]; then
        echo "USB Mode: OTG Host"
        return 0
    fi
    
    if [ -d "${GADGET_PATH}" ] && [ -s "${GADGET_PATH}/UDC" ]; then
        echo "USB Gadget: Active"
        echo "Mode: $([ "$USE_NCM" = "1" ] && echo "NCM (Linux/Mac)" || echo "RNDIS (Windows)")"
        echo "UDC: $(cat ${GADGET_PATH}/UDC)"
        if ip link show usb0 >/dev/null 2>&1; then
            echo "Interface: usb0 (managed by NetworkManager)"
            if ip addr show usb0 | grep -q 'inet '; then
                echo "IP: $(ip addr show usb0 | grep 'inet ' | awk '{print $2}')"
            fi
        fi
        return 0
    else
        echo "USB Gadget: Inactive"
        return 1
    fi
}

enable_ncm() {
    update_config "USE_NCM" "1"
    echo "NCM mode enabled (Linux/Mac compatible)"
    echo "Run 'rc-service usb-gadget restart' to apply changes"
}

disable_ncm() {
    update_config "USE_NCM" "0"
    echo "NCM mode disabled - RNDIS enabled (Windows compatible)"
    echo "Run 'rc-service usb-gadget restart' to apply changes"
}

enable_otg() {
    update_config "ENABLE_OTG" "1"
    echo "OTG Host mode enabled"
    echo "Run 'rc-service usb-gadget restart' to apply changes"
    echo "WARNING: This disables USB gadget functionality!"
}

disable_otg() {
    update_config "ENABLE_OTG" "0"
    echo "OTG Host mode disabled - Gadget mode enabled"
    echo "Run 'rc-service usb-gadget restart' to apply changes"
}

show_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "Current configuration ($CONFIG_FILE):"
        cat "$CONFIG_FILE"
    else
        echo "No configuration file found at $CONFIG_FILE"
        echo "Defaults will be used: USE_NCM=1, ENABLE_OTG=0"
    fi
}

case "$1" in
    start)
        setup_gadget
        ;;
    stop)
        teardown_gadget
        ;;
    restart)
        teardown_gadget
        setup_gadget
        ;;
    status)
        status
        ;;
    enable_ncm)
        enable_ncm
        ;;
    disable_ncm)
        disable_ncm
        ;;
    enable_otg)
        enable_otg
        ;;
    disable_otg)
        disable_otg
        ;;
    show_config|config)
        show_config
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|enable_ncm|disable_ncm|enable_otg|disable_otg|show_config}"
        exit 1
        ;;
esac
