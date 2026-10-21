> 🌐 **Bahasa / Language:** **[🇬🇧 English](README_EN.md)** | **🇮🇩 Bahasa Indonesia**

# OpenStick UZ801 v3.0 (MSM8916) — Multi-OS Linux Builder & EDL Flasher

Builder dan flasher mandiri untuk menjalankan **5 distribusi Linux Mainline 64-bit (`aarch64`, Kernel `6.12.1-msm8916`)** pada modem USB 4G LTE **Yiming UZ801 v3.0 (Qualcomm Snapdragon 410 / MSM8916)** langsung dari **macOS (Apple Silicon via Docker/OrbStack)** maupun Linux.

Seluruh image OS yang dihasilkan sudah terkonfigurasi otomatis (*out-of-the-box*) dengan:
- **ADB Over USB (`adbd` FunctionFS)** — langsung terdeteksi di `adb devices` dan bisa `adb shell` (akses `root` instan tanpa jaringan).
- **USB Gadget Networking (`CDC-NCM`)** — plug-and-play di macOS/Linux (`192.168.42.1/24` + DHCP server `dnsmasq`).
- **Modem 4G LTE (`QDSP6 MPSS` + `ModemManager` + `rmtfs`)** — firmware baseband & kalibrasi EFS tertanam langsung, otomatis konek ke internet seluler (`wwan0`) saat boot tanpa perlu menjalankan script perbaikan manual.
- **WiFi Client (`WCN3620` + `NetworkManager` + `wpa_supplicant`)** — otomatis terhubung ke WiFi yang dikonfigurasi di `variables.env`.
- **Auto-Expand Rootfs & ZRAM Swap** — otomatis memperbesar partisi `ext4` ke ukuran penuh eMMC (`3.4 GB`) saat first boot dan mengaktifkan `256 MB` compressed RAM swap (`lz4`).
- **Power-Cut Safe `/etc/fstab` & Time Sync** — tahan cabut-pasang langsung tanpa korupsi filesystem dan otomatis menyinkronkan waktu via HTTP/NTP (mengatasi ketiadaan baterai RTC pada dongle).

> 📖 **Ingin mem-porting OS lain atau mempelajari detail arsitektur & troubleshooting?**
> Baca dokumentasi teknis lengkap di **[`UZ801_OS_PORTING_GUIDE.md`](UZ801_OS_PORTING_GUIDE.md)** ([🇬🇧 English version](UZ801_OS_PORTING_GUIDE_EN.md)).

---

## 1. Distribusi OS yang Didukung

Keempat image OS berikut sudah di-build, diuji langsung di hardware UZ801 v3.0, dan siap di-flash kapan saja dari folder `files/`:

| No | Sistem Operasi | File Image (`files/`) | Init System | C Library | Package Manager | RAM Idle | Keunggulan Utama |
| :- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | **Alpine Linux v3.21** | `alpine-rootfs.img.gz` (`76 MB`) | `OpenRC` | `musl` | `apk` | **~45 MB** | Paling kecil, cepat, cocok untuk container/embedded |
| **2** | **Void Linux** | `void-rootfs.img.gz` (`134 MB`) | `runit` | `musl` | `xbps` | **~69 MB** | Init `runit` super cepat, rolling-release ringan |
| **3** | **Arch Linux ARM** | `arch-rootfs.img.gz` (`205 MB`) | `systemd` | `glibc` (+ `musl`) | `pacman` | **~88 MB** | Ekosistem Arch/`pacman` lengkap & paket selalu terbaru |
| **4** | **DietPi v10.7 (Bookworm)** | `dietpi-rootfs.img.gz` (`100 MB`) | `systemd` | `glibc` (+ `musl`) | `apt` + `dietpi-software` | **~81 MB** | Berbasis Debian 12 dengan menu `dietpi-config` & `dietpi-software` |
| **5** | **ImmortalWrt 24.10.6** | `immortalwrt-rootfs.img.gz` (`50 MB`) | `procd` | `musl` | `opkg` + `LuCI Web UI` | **~60 MB** | Router OS modern dengan dashboard web **LuCI Argon** (`http://192.168.42.1`) |

---

## 2. Struktur Direktori Project

```text
openstick/
├── README.md                      # Dokumentasi utama project ini
├── UZ801_OS_PORTING_GUIDE.md      # Panduan teknis porting OS & root-cause analysis
├── Makefile                       # Perintah satu baris untuk build & flash tiap OS
├── flash.sh                       # Script EDL flasher interaktif / CLI (Lite & Full mode)
├── variables.env                  # Konfigurasi kredensial user, WiFi, APN, dan DTB
├── variables.env.example          # Contoh file konfigurasi
├── configs/
│   ├── adb/                       # Binary adbd (aarch64-musl), libcrypto.so.1.1, adb_profile
│   ├── usb-gadget/                # Script & init service USB Gadget (CDC-NCM + FunctionFS ADB)
│   ├── expand-rootfs/             # Script online resize2fs saat first boot
│   └── network-manager/           # Template koneksi WiFi (wlan.nmconnection) & 4G LTE (lte.nmconnection)
├── scripts/
│   ├── build-rootfs.sh            # Builder Alpine Linux v3.21
│   ├── build-void.sh              # Builder Void Linux (aarch64-musl + runit)
│   ├── build-arch.sh              # Builder Arch Linux ARM (aarch64 + systemd)
│   ├── build-dietpi.sh            # Builder DietPi v10.7 (Debian 12 Bookworm ARMv8)
│   ├── build-dtb.sh               # Compiler Device Tree (.dts -> .dtb, dikunci ke Linux v6.12)
│   ├── build-firmware.sh          # Compiler bootloader lk1st-msm8916 (yiming,uz801-v3) & qhypstub
│   ├── build-images.sh            # Generator image partisi boot.img.gz (ext2) & rootfs.img.gz (ext4)
│   └── build-gpt.sh               # Generator tabel partisi GPT 14-partisi (gpt_both0.bin)
├── files/                         # Direktori output image siap flash & cache base tarball
│   ├── boot.img.gz                # Image partisi boot (Kernel 6.12.1-msm8916 + DTB + extlinux.conf)
│   ├── alpine-rootfs.img.gz       # Image rootfs Alpine Linux v3.21
│   ├── void-rootfs.img.gz         # Image rootfs Void Linux
│   ├── arch-rootfs.img.gz         # Image rootfs Arch Linux ARM
│   ├── dietpi-rootfs.img.gz       # Image rootfs DietPi v10.7
│   ├── firmware.zip               # Paket bootloader (aboot.mbn, hyp.mbn, sbl1.mbn, rpm.mbn, tz.mbn)
│   ├── gpt_both0.bin              # Tabel partisi GPT (14 partisi)
│   └── dtbs/                      # File .dtb hasil kompilasi
├── saved/                         # Partisi radio & kalibrasi modem untuk restore otomatis saat Full Flash
└── backup_original/               # Backup mentah seluruh partisi awal perangkat
```

---

## 3. Cara Flash / Ganti OS ke Dongle (Via EDL `9008`)

### Prasyarat di macOS
Pastikan `edl` (`bkerler/edl`) sudah terinstall:
```bash
brew install libusb
uv tool install --python /opt/homebrew/bin/python3.11 git+https://github.com/bkerler/edl.git
```

### Langkah Masuk ke Mode EDL (`9008`)
1. Cabut dongle dari port USB.
2. Tekan dan tahan **tombol kecil (Reset/EDL)** pada dongle.
3. Sambil tetap menahan tombol, colokkan dongle ke port USB, tahan 2–3 detik lalu lepaskan.
4. Cek apakah sudah terdeteksi oleh `edl`:
   ```bash
   edl printgpt
   ```

### Menjalankan Flash (`./flash.sh`)

#### A. Mode Lite (Default — Hanya Flash `boot` + `rootfs`, ~80 Detik)
Gunakan mode ini jika dongle sudah pernah di-flash dengan skema partisi project ini dan kamu hanya ingin **berganti OS**:

```bash
# Menu interaktif (tinggal pilih angka 1-4):
./flash.sh

# Atau langsung sebutkan nama OS di argumen:
./flash.sh alpine        # Flash Alpine Linux
./flash.sh void          # Flash Void Linux
./flash.sh arch          # Flash Arch Linux ARM
./flash.sh dietpi        # Flash DietPi v10.7
./flash.sh immortalwrt   # Flash ImmortalWrt 24.10.6
```

#### B. Mode Full (Flash GPT + Bootloader + Radio EFS + `boot` + `rootfs`)
Gunakan flag `-f` jika mem-flash dongle baru dari awal (misal dari firmware Android bawaan atau OpenWrt):

```bash
./flash.sh -f dietpi
# atau lewat Makefile:
make flash-full OS=dietpi
```

Setelah flash selesai, script akan otomatis menjalankan `edl reset`. Tunggu sekitar **35 detik** hingga dongle selesai booting.

---

## 4. Cara Mengakses Dongle Setelah Boot

Semua 4 OS menggunakan kredensial dan alamat jaringan yang seragam:

### 1. Via ADB Shell (Paling Mudah — Langsung `root` Tanpa Password)
```bash
adb devices -l
# Output: 2c2d59162055f8d2 device product:occam model:Nexus_4 device:mako

adb -s 2c2d59162055f8d2 shell
```

### 2. Via SSH Lewat USB (`usb0` / `en13` di Mac)
```bash
ssh user@192.168.42.1
# atau:
ssh root@192.168.42.1
```
- **Password:** `changeme` (pada DietPi user `dietpi` juga menggunakan password `changeme`)

### 3. Via SSH Lewat WiFi (`wlan0`)
```bash
ssh user@192.168.1.138    # Sesuaikan dengan IP DHCP dari router WiFi kamu
```

---

## 5. Perintah Berguna di Dalam Dongle

### Cek Status Modem 4G LTE & Sinyal
```bash
mmcli -m 0
ip -br addr show wwan0
ping -I wwan0 -c 3 1.1.1.1
```

### Cek & Kelola Koneksi WiFi / Seluler (`NetworkManager`)
```bash
nmcli device status
nmcli connection show
nmtui    # Antarmuka TUI interaktif untuk mengatur WiFi / APN
```

### Mengganti APN Kartu SIM
Edit file `/etc/NetworkManager/system-connections/lte.nmconnection` (default: `apn=byu`), atau jalankan:
```bash
nmcli connection modify lte gsm.apn "internet"
nmcli connection up lte
```

### Mengatur Mode USB Gadget (`NCM` vs `RNDIS` vs `OTG Host`)
```bash
usb-gadget status
usb-gadget enable_ncm     # Mode NCM untuk macOS / Linux (Default)
usb-gadget disable_ncm    # Mode RNDIS untuk Windows
usb-gadget enable_otg     # Mode USB Host OTG (untuk colok printer 3D / flashdisk)
```

---

## 6. Cara Rebuild Image OS di macOS (OrbStack / Docker)

Jika kamu mengubah konfigurasi di `variables.env` (seperti `WIFI_SSID`, `WIFI_PASS`, `PASSWORD`, atau daftar paket tambahan) dan ingin mem-build ulang image OS:

```bash
# 1. Edit konfigurasi
nano variables.env

# 2. Rebuild OS yang diinginkan menggunakan Docker/OrbStack:
make build-alpine        # Menghasilkan files/alpine-rootfs.img.gz
make build-void          # Menghasilkan files/void-rootfs.img.gz
make build-arch          # Menghasilkan files/arch-rootfs.img.gz
make build-dietpi        # Menghasilkan files/dietpi-rootfs.img.gz
make build-immortalwrt   # Menghasilkan files/immortalwrt-rootfs.img.gz
```
