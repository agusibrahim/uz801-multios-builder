> 🌐 **Language:** **🇬🇧 English** | **[🇮🇩 Bahasa Indonesia](UZ801_OS_PORTING_GUIDE.md)**

# Complete Linux OS Porting & Engineering Guide for MSM8916 USB Modems (Yiming UZ801 v3.0)

This document details the complete hardware architecture, boot chain, 14-partition GPT layout, critical bootloader/kernel/driver pitfalls, and configuration contracts for USB Gadget (`CDC-NCM` + `FunctionFS ADB`), WiFi (`WCN3620`), and the 4G LTE Modem (`QDSP6 MPSS`) on the **Yiming UZ801 v3.0 (Qualcomm Snapdragon 410 / MSM8916)** 4G LTE USB Stick.

It is written so that **any developer or AI Coding Agent** can deterministically port, build, debug, and flash any `aarch64` Linux distribution (Alpine Linux, Void Linux, Arch Linux ARM, DietPi, Debian, Ubuntu, postmarketOS, OpenWrt, etc.) from a **macOS (Apple Silicon)** or **Linux** host.

---

## 1. Target Hardware Specifications (Yiming UZ801 v3.0)

| Component | Technical Specification | Critical OS Porting Notes |
| :--- | :--- | :--- |
| **SoC** | Qualcomm MSM8916 (Snapdragon 410), 4x Cortex-A53 @ 1.2 GHz (`aarch64`) | Uses mainline `arm64` kernel (`linux-postmarketos-qcom-msm8916`) |
| **RAM** | **512 MB** LPDDR3 (`0x80000000`) | ~91 MB is reserved in Device Tree for the LTE modem DSP (`mpss@86800000` = 85 MB) and WiFi (`wcnss` = 6 MB). Effective Linux RAM is **~376 MB** -> **Always enable `zram` swap!** |
| **Storage (eMMC)** | **4 GB** eMMC (`7634944` sectors @ 512 bytes = `3.64 GiB` / `3728 MB`) | Controller `sdhc_1` (`mmc@7824900`) -> `/dev/mmcblk0` |
| **Device Tree (DTB)** | `msm8916-yiming-uz801v3.dtb` (`compatible = "yiming,uz801-v3", "qcom,msm8916"`) | Includes `msm8916-ufi.dtsi` |
| **Button & LED GPIOs** | - **Reset Button**: `GPIO 23` (`GPIO_ACTIVE_LOW`, pull-up)<br>- **Red LED (Power)**: `GPIO 7` (`GPIO_ACTIVE_HIGH`)<br>- **Green LED (WLAN/WAN)**: `GPIO 8` (`GPIO_ACTIVE_HIGH`)<br>- **Blue LED (WAN/WLAN)**: `GPIO 6` (`GPIO_ACTIVE_HIGH`) | **NEVER use `thwc,ufi001c` / `generic,uf02` in `lk2nd`!** On `uz801-v3`, `GPIO 37` is physically pulled *LOW*. On `ufi001c`, `GPIO 37` is the EDL button! |
| **WiFi / BT** | Qualcomm WCN3620 (`wcnss` remoteproc `a204000.remoteproc`, driver `wcn36xx`) | Requires `wcnss.mdt` + `wcnss.b00..b11` + `wlan/prima/WCNSS_qcom_wlan_nv.bin` |
| **4G LTE Modem** | Qualcomm Hexagon QDSP6 (`mpss` remoteproc `4080000.remoteproc`, drivers `qcom_q6v5_mss` + `bam_dmux`) | Requires `mba.mbn` + `modem.mdt` + `modem.b00..b25` + `mcfg_sw.mbn` + `rmtfs` daemon (serving `modemst1`, `modemst2`, `fsg`, `fsc` partitions) |
| **USB Controller** | ChipIdea High-Speed Dual-Role USB (`ci_hdrc_msm`, `usb@78d9000`, UDC `ci_hdrc.0`) | Single physical USB-A connector (carries both 5V power and USB Gadget NCM/RNDIS/ADB data) |

---

## 2. Boot Chain Architecture & 14-Partition GPT Layout

### 2.1. Mainline 64-bit Boot Flow
```text
PBL (ROM) 
  └──> SBL1 (sbl1.mbn from db410c, uses internal 512MB MTP DDR table)
         ├──> RPM (rpm.mbn, power/clock management)
         ├──> TZ  (tz.mbn, 64-bit TrustZone)
         └──> HYP (hyp.mbn = qhypstub, hypervisor stub allowing Linux to boot in EL2)
                └──> ABOOT (aboot.mbn = lk1st-msm8916, mounts ext2 /boot/extlinux/extlinux.conf)
                       └──> Linux Kernel (/vmlinuz + /dtbs/qcom/msm8916-yiming-uz801v3.dtb)
                              └──> Rootfs (/dev/mmcblk0p14, ext4)
```

### 2.2. GPT Partition Table (`gpt_both0.bin`)
Total eMMC sectors: `7634944` (`0x748000`).

| # | Device Node | Partition Name (`PARTLABEL`) | Start Sector | Size (Sectors) | Size | Purpose |
| :- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | `/dev/mmcblk0p1` | `fsc` | `4096` | `2` | 1 KB | Radio FS Cookie (Must backup/restore) |
| 2 | `/dev/mmcblk0p2` | `fsg` | `4098` | `3072` | 1.5 MB | Golden Radio EFS Backup (Must backup/restore) |
| 3 | `/dev/mmcblk0p3` | `modem` | `7170` | `131072` | 64 MB | FAT16 partition with factory `image/modem.*`, `mba.mbn`, `wcnss.*` |
| 4 | `/dev/mmcblk0p4` | `modemst1` | `138242` | `3072` | 1.5 MB | Modem NV/EFS Partition 1 / IMEI (Must backup/restore) |
| 5 | `/dev/mmcblk0p5` | `modemst2` | `141314` | `3072` | 1.5 MB | Modem NV/EFS Partition 2 / IMEI (Must backup/restore) |
| 6 | `/dev/mmcblk0p6` | `persist` | `144386` | `65536` | 32 MB | ext4 partition with `WCNSS_qcom_wlan_nv.bin` |
| 7 | `/dev/mmcblk0p7` | `sec` | `209922` | `32` | 16 KB | Security fuse configuration |
| 8 | `/dev/mmcblk0p8` | `hyp` | `209954` | `1024` | 512 KB | `qhypstub` signed with `qtestsign` |
| 9 | `/dev/mmcblk0p9` | `rpm` | `210978` | `1024` | 512 KB | `rpm.mbn` from DB410c bootloader package |
| 10 | `/dev/mmcblk0p10` | `sbl1` | `212002` | `1024` | 512 KB | `sbl1.mbn` from DB410c bootloader package |
| 11 | `/dev/mmcblk0p11` | `tz` | `213026` | `2048` | 1 MB | `tz.mbn` from DB410c bootloader package |
| 12 | `/dev/mmcblk0p12` | `aboot` | `215074` | `2048` | 1 MB | `lk1st-msm8916` (`emmc_appsboot.mbn` signed with `qtestsign`) |
| 13 | `/dev/mmcblk0p13` | `boot` | `217122` | `131072` | 64 MB | **`ext2`** partition containing `/vmlinuz`, `/dtbs/`, `/extlinux/extlinux.conf` |
| 14 | `/dev/mmcblk0p14` | `rootfs` | `348194` | `7286717` | ~3.5 GB | **`ext4`** partition containing the main OS root filesystem (`/`) |

> **CRITICAL WARNING REGARDING THE `cdt` PARTITION:**
> - **DO NOT** create a `cdt` partition or flash `sbc_1.0_8016.bin` when using this 14-partition `lk1st-msm8916` + `gpt_both0.bin` scheme!
> - `sbc_1.0_8016.bin` contains a **1 GB** DDR configuration (for DragonBoard 410c) and `board_id = 0x18` (`HW_PLATFORM_SBC`). If a `cdt` partition exists in GPT, `sbl1.mbn` loads the 1 GB DDR table onto the UZ801's 512 MB RAM chip and fails DDR training on boot. When no `cdt` partition exists in GPT, `sbl1.mbn` falls back to its built-in default 512 MB DDR table (`board_id = 0x08` `HW_PLATFORM_MTP`), which matches `lk1st-msm8916` (`msm8916-512mb-mtp.dtb`) 100%.

---

## 3. Eight Critical Pitfalls (Root Causes) & Their Solutions

### Pitfall 1: Dongle Reboots Straight into EDL Mode (`9008` / `QHSUSB__BULK`) on Every Boot
- **Symptom:** After flashing `firmware.zip`, plugging in the dongle immediately drops it into EDL `9008` mode.
- **Root Cause:** `lk1st-msm8916` (`aboot.mbn`) was compiled with `LK2ND_COMPATIBLE="generic,uf02"` (an alias for `thwc,ufi001c`). On `ufi001c`, `GPIO 37` is the active-low EDL button. On **`uz801-v3`**, `GPIO 37` is physically pulled *LOW* on the PCB (while the actual physical button is on `GPIO 23`). Consequently, `lk2nd` thinks the EDL button is being held down at boot and calls `reboot into dload mode`.
- **Solution:** Always compile `lk2nd` (`scripts/build-firmware.sh`) with:
  ```bash
  make \
    LK2ND_BUNDLE_DTB="msm8916-512mb-mtp.dtb" \
    LK2ND_COMPATIBLE="yiming,uz801-v3" \
    TOOLCHAIN_PREFIX=arm-none-eabi- \
    lk1st-msm8916
  ```

### Pitfall 2: Dongle Freezes at a Solid Red LED (Fails to Mount eMMC `/dev/mmcblk0p14`)
- **Symptom:** The bootloader succeeds (`lk2nd` loads the kernel, which probes `gpio-leds` and turns on the solid red power LED `led_r`), but neither USB nor WiFi ever comes up.
- **Root Cause:** `scripts/build-dtb.sh` cloned `https://github.com/torvalds/linux.git` without specifying a tag (pulling Linux `6.13+`/`6.19` `HEAD`). In Linux `6.13+`, the eMMC controller node `mmc@7824900` in `msm8916.dtsi` added `resets = <&gcc GCC_SDCC1_BCR>;` (`<0x13 0x24>`). However, the kernel in use is **Linux `6.12.1-msm8916`**, whose `gcc-msm8916` driver does not support that reset index! As a result, probing `mmc0` fails with `-EINVAL` and the kernel hangs forever at `Waiting for root device /dev/mmcblk0p14...`.
- **Solution:** Pin the kernel DTS repository to `--branch v6.12` (matching kernel `6.12.1-msm8916`).

### Pitfall 3: `/boot` (`ext2`) Corruption After Unplugging the Dongle Without Shutdown
- **Symptom:** First boot after flashing works, but after unplugging the dongle (e.g., to insert a SIM card) and plugging it back in, it fails to boot.
- **Root Cause:**
  1. A USB modem stick has no battery or power button; it is always powered off by unplugging it from USB.
  2. The `/boot` partition (`/dev/mmcblk0p13`) must be **`ext2` (journal-less)** because `lk2nd` only supports `ext2`.
  3. Mounting `/boot` as read-write (`defaults 0 2`) in `/etc/fstab` marks the `ext2` superblock *dirty* (`s_state = 0`) as soon as it is mounted. When power is yanked, the next boot's `fsck` sees a dirty non-journaled `ext2` filesystem and aborts the boot (`rc-abort` / `emergency_shell`).
  4. Additionally, never run `e2fsck -fy` on a live `rw`-mounted rootfs inside `expand-rootfs.sh`, and always call `sync` immediately after `resize2fs`.
- **Solution:** Mount `/boot` as **Read-Only (`ro`)** (or omit `/boot` from `/etc/fstab` on distros like DietPi) and mount `/` with `commit=1`:
  ```fstab
  /dev/mmcblk0p13    /boot    ext2    ro,noatime          0 0
  /dev/mmcblk0p14    /        ext4    rw,noatime,commit=1 0 0
  ```

### Pitfall 4: Loop Mount (`mount -o loop`) Page-Cache Corruption Inside Docker (macOS OrbStack/Docker Desktop)
- **Symptom:** Creating `boot.raw` and `rootfs.raw` inside `/tmp` in a Docker container using `mount -o loop` + `tar` + `umount` can fail to flush page-cache writes back to the underlying OverlayFS file, producing an empty `64 KB` `boot.img.gz`.
- **Solution:** Use `e2fsprogs` 1.46+ native `-d <rootdir>` directory population (`mkfs.ext2 -F -d` and `mkfs.ext4 -F -d`), which writes the filesystem directly in userspace without `mount -o loop`:
  ```bash
  truncate -s $((64 * 1024 * 1024)) boot.raw
  mkfs.ext2 -F -d /path/to/boot_dir boot.raw

  truncate -s $((512 * 1024 * 1024)) rootfs.raw
  mkfs.ext4 -F -d /path/to/root_dir rootfs.raw
  ```

### Pitfall 5: USB Gadget NCM (`usb0`) Stuck at `status: inactive` on macOS & `ffs.adb` Unbinding
- **Symptom:** macOS detects `USB Network` (`enX`), but its status remains `inactive`, or adding `ffs.adb` prevents USB from enumerating at all.
- **Root Cause:**
  1. The Linux kernel `f_ncm` driver only sends `USB_CDC_NOTIFY_NETWORK_CONNECTION = 1` (Link Connected) to the macOS host **after `ip link set usb0 up` is executed on the dongle**. Waiting for NetworkManager (which waits for carrier first) causes a deadlock.
  2. For **ADB (`ffs.adb` / FunctionFS)**: `/dev/pts` (`devpts`) and `/dev/usb-ffs/adb` (`functionfs`) must be mounted and `/usr/bin/adbd -D` must write descriptors to `/dev/usb-ffs/adb/ep0` (creating `ep1` and `ep2`) **before** writing `ci_hdrc.0` to `UDC`.
  3. If `adbd` is spawned in the background without detaching (`setsid` / `start-stop-daemon --background` / `KillMode=none`), when the init script exits, `adbd` receives `SIGHUP` and closes `ep0` — causing the kernel's `f_fs` driver to immediately unbind the entire USB gadget!
- **Solution:**
  - Start `adbd` detached (`setsid /usr/bin/adbd -D >/run/adbd.log 2>&1 </dev/null &`) and set `KillMode=none` in systemd units.
  - Provide an automatic fallback when binding `UDC`: if `echo "$UDC" > UDC` fails, remove `configs/c.1/ffs.adb` and retry `echo "$UDC" > UDC` so NCM networking is 100% guaranteed.
  - Immediately run `ip link set usb0 up`, assign `192.168.42.1/24`, and start `dnsmasq` (`--dhcp-leasefile=/run/dnsmasq-usb0.leases`) inside `usb-gadget.sh`.

### Pitfall 6: Running `adbd` & `rmtfs` Across Both `musl` and `glibc` Distros
- **Problem:** `adbd` (from OpenWrt/HandsomeMod `aarch64-musl`) and `rmtfs` (from postmarketOS `aarch64-musl`) are linked against `/lib/ld-musl-aarch64.so.1`. How do we run them on `glibc` distros like **Arch Linux ARM** and **DietPi (Debian)** without library conflicts?
- **Solution:**
  - `glibc` uses `/lib/ld-linux-aarch64.so.1`, while `musl` uses `/lib/ld-musl-aarch64.so.1` — their dynamic linkers never collide!
  - Place `/usr/lib/ld-musl-aarch64.so.1` in `/usr/lib`, put all required `musl` shared libraries (`libc.so`, `libz.so.1`, `libgcc_s.so.1`, `libudev.so.1`, `libqrtr.so.1`, `libcrypto.so.1.1`) in an isolated directory **`/usr/lib/musl/`**, and write `/usr/lib/musl` into **`/etc/ld-musl-aarch64.path`**.
  - Because `adbd` executes `/system/bin/sh` when `adb shell` is invoked, create an executable script at `/system/bin/sh` that exports a full `PATH` and `TERM=xterm-256color` before `exec /bin/bash "$@"`.

### Pitfall 7: WiFi (`wlan0`) Fails to Connect under `NetworkManager`
- **Root Cause:**
  1. Alpine's default `/etc/init.d/wpa_supplicant` launches `wpa_supplicant -iwlan0` without the `-u` (D-Bus) flag, preventing `NetworkManager` from controlling `wpa_supplicant`.
  2. `msm-firmware-loader` overwrites `/sys/module/firmware_class/parameters/path` with `/run/msm-firmware-loader/target`.
- **Solution:**
  - Inject all factory firmware blobs (`wcnss.*`, `modem.*`, `mba.mbn`, `mcfg_sw.mbn`, `WCNSS_qcom_wlan_nv.bin`, `wlan/prima/WCNSS_qcom_wlan_nv.bin`) directly into `/lib/firmware` on the rootfs and disable `msm-firmware-loader`.
  - Ensure `wpa_supplicant` runs with `-u` (D-Bus enabled).

### Pitfall 8: 4G LTE (`wwan0`) Disconnects or Fails to Reconnect After Reboot
- **Root Cause:** Having `[ipv6] method=auto` in `/etc/NetworkManager/system-connections/lte.nmconnection` causes NetworkManager to time out waiting for IPv6 SLAAC on cellular carriers (such as Telkomsel/by.U) and tear down the bearer.
- **Solution:**
  - Set `[ipv6] method=ignore` (IPv4-only), `autoconnect=true`, and `autoconnect-retries=0` in `lte.nmconnection`.
  - Include a background boot loop that enables the modem (`mmcli -m 0 -e`) and activates `lte` (`nmcli connection up lte`) if `wwan0qmi0` is in `disconnected` state.

---

## 4. Distro-Specific Notes (Alpine, Void, Arch, DietPi)

### 1. Alpine Linux v3.21 (`OpenRC` + `musl`) — `scripts/build-rootfs.sh`
- Remove `sshd` (from `postmarketos-base-ssh`), `zram-init`, and `swapfile` from OpenRC `default` runlevel so `dropbear` and `/etc/local.d/zram.start` run without conflicts.

### 2. Void Linux (`runit` + `musl`) — `scripts/build-void.sh`
- Simplify `/etc/runit/core-services/03-filesystems.sh` so it does not attempt `mount -o remount,ro / || emergency_shell` on the already `rw`-mounted `/dev/mmcblk0p14`.
- Run `resize2fs`, `zram`, `usb-gadget start`, and the LTE autoconnect loop from `/etc/rc.local` (Stage 2 before `runsvdir`).

### 3. Arch Linux ARM (`systemd` + `glibc`) — `scripts/build-arch.sh`
- Replace `dbus-broker.service` with standard `/usr/bin/dbus-daemon --system --address=systemd: --nofork --nopidfile --systemd-activation --syslog-only` in `/etc/systemd/system/dbus.service` (as `dbus-broker` fails with `-107` on embedded kernels without audit/memfd seals).
- Add `KillMode=none` to `uz801-init.service`.

### 4. DietPi v10.7 (`systemd` + `glibc`, Debian 12 Bookworm) — `scripts/build-dietpi.sh`
- Do **not** mount `/dev/mmcblk0p13` onto `/boot` in `/etc/fstab` so `/boot/dietpi` on the rootfs stays intact.
- Write `2` to `/boot/dietpi/.install_stage` and `21` (`Native PC (aarch64)`) to `/etc/.dietpi_hw_model_identifier`.
- Install `systemd-timesyncd` and perform an initial HTTP `Date:` header clock sync (`curl -sI http://1.1.1.1`) in `uz801-init.sh` so HTTPS repositories (`deb.debian.org` and `dietpi.com`) never fail SSL certificate validation on cold boot.

### 5. ImmortalWrt 24.10.6 Mainline (`procd` + `LuCI Argon Web UI`) — `scripts/build-immortalwrt.sh`
- **Creating `/dev/disk/by-partlabel/*` for `rmtfs`**: Because OpenWrt's `procd` does not run `eudev`, `/dev/disk/by-partlabel/` is not created automatically. `/etc/init.d/uz801-init` parses `DEVNAME` and `PARTNAME` from `/sys/block/mmcblk0/mmcblk0p*/uevent` to populate `/dev/disk/by-partlabel/*` before starting `rmtfs -P -r -s`.
- **Reporting Kernel Events to `ModemManager` (`--without-udev`)**: OpenWrt compiles `ModemManager` without `libgudev` and relies on `mmcli --report-kernel-event`. `uz801-init` reports all `/sys/class/wwan/*`, `/sys/class/net/wwan*`, and `/sys/class/rpmsg/*` devices to `ModemManager`, connects the bearer (`mmcli -m 0 --simple-connect="apn=byu,ip-type=ipv4"`), and applies the bearer IPv4 address and route to `wwan0`.
- **WiFi `mac80211` Auto-Detection (`wifi config`)**: Runs `wifi config` once `wcn36xx` creates `phy0` so OpenWrt auto-detects the exact `remoteproc` sysfs path before configuring `default_radio0` as a `sta` client.
- **`dnsmasq --user=root` on `usb0`**: Passes `--user=root` to `dnsmasq` in `usb-gadget.sh` so DHCP leases in `/run/dnsmasq-usb0.leases` work seamlessly across all 5 distributions.

