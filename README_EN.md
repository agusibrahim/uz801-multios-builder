> 🌐 **Language:** **🇬🇧 English** | **[🇮🇩 Bahasa Indonesia](README.md)**

# OpenStick UZ801 v3.0 (MSM8916) — Multi-OS Linux Builder & EDL Flasher

A self-contained builder and EDL flasher for running **7 Mainline 64-bit Linux distributions (`aarch64`, Kernel `6.12.1-msm8916`)** on the **Yiming UZ801 v3.0 (Qualcomm Snapdragon 410 / MSM8916)** 4G LTE USB Modem Stick directly from **macOS (Apple Silicon via Docker/OrbStack)** or Linux.

Every OS image built by this project comes pre-configured **out-of-the-box** with:
- **ADB Over USB (`adbd` FunctionFS)** — immediately detected by `adb devices` with direct `root` access via `adb shell` (even without network/IP).
- **USB Gadget Networking (`CDC-NCM`)** — plug-and-play on macOS/Linux (`192.168.42.1/24` + `dnsmasq` DHCP server).
- **4G LTE Cellular Modem (`QDSP6 MPSS` + `ModemManager` + `rmtfs`)** — factory baseband firmware & EFS calibration integrated directly; automatically connects to cellular data (`wwan0`) on boot without needing post-install repair scripts.
- **WiFi Client (`WCN3620` + `NetworkManager` + `wpa_supplicant`)** — automatically connects to the WiFi network configured in `variables.env`.
- **Auto-Expand Rootfs & ZRAM Swap** — automatically resizes the `ext4` root partition to fill the entire eMMC (`3.4 GB`) on first boot and enables a `256 MB` `lz4`-compressed RAM swap.
- **Power-Cut Safe `/etc/fstab` & Automatic Time Sync** — resilient against sudden USB unplugging without filesystem corruption, with automatic HTTP/NTP clock synchronization (compensating for the lack of a battery-backed RTC on the dongle).

> 📖 **Want to port another Linux distro or dive into the hardware architecture & root-cause analysis?**
> Read the full technical porting guide in **[`UZ801_OS_PORTING_GUIDE_EN.md`](UZ801_OS_PORTING_GUIDE_EN.md)** ([🇮🇩 Indonesian version](UZ801_OS_PORTING_GUIDE.md)).

---

## 1. Supported Operating Systems

All 4 OS images have been built, tested live on UZ801 v3.0 hardware, and are available in the **[GitHub Releases](https://github.com/agusibrahim/uz801-multios-builder/releases)** page (or in `./files/` after building):

| # | Operating System | Image File (`files/`) | Init System | C Library | Package Manager | Idle RAM | Key Highlights |
| :- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | **Alpine Linux v3.21** | `alpine-rootfs.img.gz` (`76 MB`) | `OpenRC` | `musl` | `apk` | **~45 MB** | Smallest footprint, ultra-fast boot, ideal for containers/appliances |
| **2** | **Void Linux** | `void-rootfs.img.gz` (`134 MB`) | `runit` | `musl` | `xbps` | **~69 MB** | Blazing-fast `runit` supervision, lightweight rolling-release |
| **3** | **Arch Linux ARM** | `arch-rootfs.img.gz` (`205 MB`) | `systemd` | `glibc` (+ `musl`) | `pacman` | **~88 MB** | Full Arch/`pacman` rolling-release ecosystem with latest packages |
| **4** | **DietPi v10.7 (Bookworm)** | `dietpi-rootfs.img.gz` (`100 MB`) | `systemd` | `glibc` (+ `musl`) | `apt` + `dietpi-software` | **~81 MB** | Debian 12 Bookworm base with `dietpi-config` & `dietpi-software` wizards |
| **5** | **ImmortalWrt 24.10.6** | `immortalwrt-rootfs.img.gz` (`50 MB`) | `procd` | `musl` | `opkg` + `LuCI Web UI` | **~60 MB** | Modern OpenWrt/ImmortalWrt router OS with **LuCI Argon Web UI** (`http://192.168.42.1`) |
| **6** | **Ubuntu 24.04.5 LTS** | `ubuntu-rootfs.img.gz` (`106 MB`) | `systemd` | `glibc` (+ `musl`) | `apt` (`Ubuntu Ports`) | **~77 MB** | Official Ubuntu Noble Numbat 24.04.5 LTS built from `ubuntu-base` (zero bloat) |
| **7** | **Chimera Linux** | `chimera-rootfs.img.gz` (`81 MB`) | `dinit` | `musl` (FreeBSD + LLVM) | `apk` (v3) | **~86 MB** | Modern non-GNU distro with **FreeBSD userland**, **LLVM/Clang** toolchain, and **`dinit`** init |

---

## 2. Project Directory Structure

```text
openstick/
├── README.md                         # Main documentation (Bahasa Indonesia)
├── README_EN.md                      # Main documentation (English)
├── UZ801_OS_PORTING_GUIDE.md         # Deep-dive OS porting guide (Bahasa Indonesia)
├── UZ801_OS_PORTING_GUIDE_EN.md      # Deep-dive OS porting guide (English)
├── Makefile                          # One-line targets to build & flash each OS
├── flash.sh                          # Interactive / CLI EDL flasher (Lite & Full modes)
├── variables.env.example             # Example configuration file (copy to variables.env)
├── configs/
│   ├── adb/                          # adbd binary (aarch64-musl), libcrypto.so.1.1, adb_profile
│   ├── usb-gadget/                   # USB Gadget script & init service (CDC-NCM + FunctionFS ADB)
│   ├── expand-rootfs/                # Online first-boot resize2fs script
│   └── network-manager/              # WiFi (wlan.nmconnection) & 4G LTE (lte.nmconnection) profiles
├── scripts/
│   ├── build-rootfs.sh               # Alpine Linux v3.21 builder
│   ├── build-void.sh                 # Void Linux (aarch64-musl + runit) builder
│   ├── build-arch.sh                 # Arch Linux ARM (aarch64 + systemd) builder
│   ├── build-dietpi.sh               # DietPi v10.7 (Debian 12 Bookworm ARMv8) builder
│   ├── build-dtb.sh                  # Device Tree compiler (.dts -> .dtb, pinned to Linux v6.12)
│   ├── build-firmware.sh             # Bootloader compiler: lk1st-msm8916 (yiming,uz801-v3) & qhypstub
│   ├── build-images.sh               # Userspace ext2/ext4 image generator (mkfs -d, no loop mount)
│   └── build-gpt.sh                  # 14-partition GPT generator (gpt_both0.bin)
└── files/                            # Output directory for flashable images & compiled DTBs
    ├── boot.img.gz                   # Boot partition image (Kernel 6.12.1-msm8916 + DTB + extlinux.conf)
    ├── alpine-rootfs.img.gz          # Alpine Linux v3.21 rootfs image
    ├── void-rootfs.img.gz            # Void Linux rootfs image
    ├── arch-rootfs.img.gz            # Arch Linux ARM rootfs image
    ├── dietpi-rootfs.img.gz          # DietPi v10.7 rootfs image
    ├── firmware.zip                  # Bootloader bundle (aboot.mbn, hyp.mbn, sbl1.mbn, rpm.mbn, tz.mbn)
    ├── gpt_both0.bin                 # 14-partition GPT table
    └── dtbs/                         # Compiled .dtb files
```

---

## 3. Flashing / Switching OS on the Dongle (Via EDL `9008`)

### Host Prerequisites (macOS / Linux)
Install `edl` (`bkerler/edl`) and `libusb`:
```bash
brew install libusb
uv tool install --python /opt/homebrew/bin/python3.11 git+https://github.com/bkerler/edl.git
```

Download the pre-built release artifacts from **[GitHub Releases](https://github.com/agusibrahim/uz801-multios-builder/releases/tag/v1.0.0)** into the `./files/` folder (or build them locally).

### Entering EDL Mode (`9008`)
1. Unplug the dongle from the USB port.
2. Press and hold the **small Reset/EDL button** on the dongle.
3. While holding the button, plug the dongle into the USB port, hold for 2–3 seconds, then release.
4. Verify detection:
   ```bash
   edl printgpt
   ```

### Running the Flasher (`./flash.sh`)

#### A. Lite Mode (Default — Flashes `boot` + `rootfs` Only, ~80 Seconds)
Use this mode if the dongle is already partitioned with this project's GPT layout and you just want to **switch operating systems**:

```bash
# Interactive menu (pick 1-4):
./flash.sh

# Or pass the OS name directly:
./flash.sh alpine        # Flash Alpine Linux
./flash.sh void          # Flash Void Linux
./flash.sh arch          # Flash Arch Linux ARM
./flash.sh dietpi        # Flash DietPi v10.7
./flash.sh immortalwrt   # Flash ImmortalWrt 24.10.6
./flash.sh ubuntu        # Flash Ubuntu 24.04.5 LTS
./flash.sh chimera       # Flash Chimera Linux
```

#### B. Full Mode (Flashes GPT + Bootloader + Radio EFS Backup/Restore + `boot` + `rootfs`)
Use the `-f` flag when flashing a dongle for the first time:

```bash
./flash.sh -f dietpi
# or via Makefile:
make flash-full OS=dietpi
```

Once flashing finishes, the script automatically executes `edl reset`. Wait **~35 seconds** for the dongle to boot.

---

## 4. Accessing the Dongle After Boot

All 4 operating systems share uniform credentials and network addresses:

### 1. Via ADB Shell (Easiest — Direct `root` Shell Without Password)
```bash
adb devices -l
# Output: 2c2d59162055f8d2 device product:occam model:Nexus_4 device:mako

adb -s 2c2d59162055f8d2 shell
```

### 2. Via SSH Over USB (`usb0` / `enX` on Mac)
```bash
ssh user@192.168.42.1
# or:
ssh root@192.168.42.1
```
- **Password:** `changeme` (on DietPi, user `dietpi` also uses `changeme`)

### 3. Via SSH Over WiFi (`wlan0`)
```bash
ssh user@<dongle-wifi-ip>
```

---

## 5. Useful Commands Inside the Dongle

### Check 4G LTE Modem & Signal Status
```bash
mmcli -m 0
ip -br addr show wwan0
ping -I wwan0 -c 3 1.1.1.1
```

### Manage WiFi & Cellular Connections (`NetworkManager`)
```bash
nmcli device status
nmcli connection show
nmtui    # Interactive TUI to configure WiFi or cellular APN
```

### Change SIM Card APN
Edit `/etc/NetworkManager/system-connections/lte.nmconnection` (default: `apn=byu`), or run:
```bash
nmcli connection modify lte gsm.apn "internet"
nmcli connection up lte
```

### Switch USB Gadget Mode (`NCM` vs `RNDIS` vs `OTG Host`)
```bash
usb-gadget status
usb-gadget enable_ncm     # NCM mode for macOS / Linux (Default)
usb-gadget disable_ncm    # RNDIS mode for Windows
usb-gadget enable_otg     # USB OTG Host mode (for 3D printers / USB peripherals)
```

---

## 6. Rebuilding OS Images on macOS (OrbStack / Docker)

To customize WiFi credentials, passwords, or pre-installed packages:

```bash
# 1. Copy and edit configuration
cp variables.env.example variables.env
nano variables.env

# 2. Build any of the 4 OS images using Docker/OrbStack:
make build-alpine        # Outputs files/alpine-rootfs.img.gz
make build-void          # Outputs files/void-rootfs.img.gz
make build-arch          # Outputs files/arch-rootfs.img.gz
make build-dietpi        # Outputs files/dietpi-rootfs.img.gz
make build-immortalwrt   # Outputs files/immortalwrt-rootfs.img.gz
make build-ubuntu        # Outputs files/ubuntu-rootfs.img.gz
make build-chimera       # Outputs files/chimera-rootfs.img.gz
```
