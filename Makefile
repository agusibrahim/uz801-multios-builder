.PHONY: help build-alpine build-void build-arch build-dietpi build-immortalwrt \
        flash-alpine flash-void flash-arch flash-dietpi flash-immortalwrt flash-full

help:
	@echo "=== UZ801 v3.0 (MSM8916) Multi-OS Builder & Flasher (macOS Docker/OrbStack) ==="
	@echo ""
	@echo "Build Targets (via Docker/OrbStack):"
	@echo "  make build-alpine      - Build Alpine Linux v3.21 (OpenRC + musl)"
	@echo "  make build-void        - Build Void Linux (runit + musl)"
	@echo "  make build-arch        - Build Arch Linux ARM (systemd + glibc)"
	@echo "  make build-dietpi      - Build DietPi v10.7 (Debian 12 Bookworm ARMv8)"
	@echo "  make build-immortalwrt - Build ImmortalWrt 24.10.6 (procd + LuCI Web UI)"
	@echo ""
	@echo "Flash Targets (via EDL 9008):"
	@echo "  make flash-alpine      - Flash Alpine Linux rootfs + boot"
	@echo "  make flash-void        - Flash Void Linux rootfs + boot"
	@echo "  make flash-arch        - Flash Arch Linux ARM rootfs + boot"
	@echo "  make flash-dietpi      - Flash DietPi rootfs + boot"
	@echo "  make flash-immortalwrt - Flash ImmortalWrt 24.10.6 rootfs + boot"
	@echo "  make flash-full OS=alpine|void|arch|dietpi|immortalwrt - Full flash"

build-alpine:
	docker run --rm --privileged --platform linux/arm64 \
	  -v "$$PWD:/host" \
	  -v "/Users/macbook/Downloads/UZ801-USB-MODEM-main/backup_kayla_extracted:/kayla:ro" \
	  -v msm8916-kernel-dts:/app/.kernel-dts \
	  ubuntu:22.04 bash -ec '\
	    export DEBIAN_FRONTEND=noninteractive && \
	    mkdir -p /app && \
	    tar -C /host --exclude="./files" --exclude="./.kernel-dts" --exclude="./backup_original" --exclude="./saved" -cf - . | tar -C /app -xf - && \
	    cd /app && \
	    ./scripts/build-deps.sh && \
	    mkdir -p files && \
	    ./scripts/build-dtb.sh ./files && \
	    ./scripts/build-rootfs.sh ./files && \
	    mkdir -p files/rootfs/lib/firmware/wlan/prima && \
	    for f in /kayla/modem_extracted/IMAGE/MODEM.* /kayla/modem_extracted/IMAGE/MBA.* /kayla/modem_extracted/IMAGE/WCNSS.*; do \
	      [ -f "$$f" ] && cp "$$f" "files/rootfs/lib/firmware/$$(basename "$$f" | tr "[:upper:]" "[:lower:]")"; \
	    done && \
	    cp "/kayla/modem_extracted/IMAGE/MODEM_PR/MCFG/CONFIGS/MCFG_SW/GENERIC/COMMON/ROW/GEN_3GPP/MCFG_SW.MBN" "files/rootfs/lib/firmware/mcfg_sw.mbn" && \
	    ln -sf mcfg_sw.mbn "files/rootfs/lib/firmware/MCFG_SW.MBN" && \
	    for f in files/rootfs/lib/firmware/*.mdt; do [ -e "$$f" ] && ln -sf "$$(basename "$$f")" "$${f%.mdt}.mbn"; done && \
	    mkdir -p /mnt/persist && mount -o loop,ro /kayla/persist.img /mnt/persist && \
	    cp /mnt/persist/WCNSS_qcom_wlan_nv.bin files/rootfs/lib/firmware/WCNSS_qcom_wlan_nv.bin && \
	    cp /mnt/persist/WCNSS_qcom_wlan_nv.bin files/rootfs/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin && \
	    umount /mnt/persist && \
	    rm -f files/rootfs/etc/runlevels/sysinit/msm-firmware-loader files/rootfs/etc/runlevels/boot/msm-firmware-loader-unpack && \
	    tar cpzf files/alpine-rootfs.tgz -C files/rootfs . && \
	    cp files/alpine-rootfs.tgz files/rootfs.tgz && \
	    ./scripts/build-images.sh ./files && \
	    cp files/boot.img.gz /host/files/boot.img.gz && \
	    cp files/boot.img.gz /host/files/alpine-boot.img.gz && \
	    cp files/rootfs.img.gz /host/files/alpine-rootfs.img.gz && \
	    cp files/alpine-rootfs.tgz /host/files/alpine-rootfs.tgz \
	  '

build-void:
	docker run --rm --privileged --platform linux/arm64 \
	  -v "$$PWD:/host" \
	  ubuntu:22.04 bash -ec '\
	    export DEBIAN_FRONTEND=noninteractive && \
	    apt-get update -qq && apt-get install -y -qq wget xz-utils e2fsprogs ca-certificates >/dev/null && \
	    cd /host && ./scripts/build-void.sh ./files \
	  '

build-arch:
	docker run --rm --privileged --platform linux/arm64 \
	  -v "$$PWD:/host" \
	  ubuntu:22.04 bash -ec '\
	    export DEBIAN_FRONTEND=noninteractive && \
	    apt-get update -qq && apt-get install -y -qq wget xz-utils e2fsprogs ca-certificates >/dev/null && \
	    cd /host && ./scripts/build-arch.sh ./files \
	  '

build-dietpi:
	docker run --rm --privileged --platform linux/arm64 \
	  -v "$$PWD:/host" \
	  ubuntu:22.04 bash -ec '\
	    export DEBIAN_FRONTEND=noninteractive && \
	    apt-get update -qq && apt-get install -y -qq wget xz-utils e2fsprogs ca-certificates >/dev/null && \
	    cd /host && ./scripts/build-dietpi.sh ./files \
	  '

build-immortalwrt:
	docker run --rm --privileged --platform linux/arm64 \
	  -v "$$PWD:/host" \
	  ubuntu:22.04 bash -ec '\
	    export DEBIAN_FRONTEND=noninteractive && \
	    apt-get update -qq && apt-get install -y -qq wget e2fsprogs ca-certificates >/dev/null && \
	    cd /host && ./scripts/build-immortalwrt.sh ./files \
	  '

flash-alpine:
	./flash.sh alpine

flash-void:
	./flash.sh void

flash-arch:
	./flash.sh arch

flash-dietpi:
	./flash.sh dietpi

flash-immortalwrt:
	./flash.sh immortalwrt

flash-full:
	./flash.sh -f $(OS)
