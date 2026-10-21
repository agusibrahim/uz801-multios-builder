> 🌐 **Bahasa / Language:** **[🇬🇧 English](UZ801_OS_PORTING_GUIDE_EN.md)** | **🇮🇩 Bahasa Indonesia**

# Panduan Lengkap Porting & Build OS Linux untuk Modem USB MSM8916 (Yiming UZ801 v3.0)

Dokumen ini merangkum seluruh arsitektur hardware, urutan booting, tabel partisi GPT, jebakan (*pitfalls*) bootloader/kernel/driver, hingga konfigurasi USB Gadget (NCM + ADB), WiFi (`WCN3620`), dan Modem 4G LTE (`QDSP6 MPSS`) pada dongle **Yiming UZ801 v3.0 (Qualcomm Snapdragon 410 / MSM8916)**.

Dokumen ini dirancang agar **manusia maupun AI Coding Agent** dapat melakukan *porting*, *build*, atau *debugging* distribusi Linux apa pun (Alpine Linux, Debian, Ubuntu, Arch Linux ARM, Void Linux, postmarketOS, OpenWrt) dari host **macOS (Apple Silicon)** maupun **Linux** secara deterministik dari nol sampai 100% berjalan.

---

## 1. Spesifikasi Hardware Target (Yiming UZ801 v3.0)

| Komponen | Spesifikasi Teknis | Catatan Penting untuk Porting OS |
| :--- | :--- | :--- |
| **SoC** | Qualcomm MSM8916 (Snapdragon 410), 4x Cortex-A53 @ 1.2 GHz (`aarch64`) | Menggunakan kernel mainline `arm64` (`linux-postmarketos-qcom-msm8916`) |
| **RAM** | **512 MB** LPDDR3 (`0x80000000`) | Sebagian RAM (~91 MB) di-reserve untuk modem DSP (`mpss@86800000` = 85 MB) & WiFi (`wcnss` = 6 MB). Sisa RAM efektif untuk Linux ~380 MB -> **Wajib gunakan `zram` swap!** |
| **Storage (eMMC)** | **4 GB** eMMC (`7634944` sektor @ 512 byte = `3.64 GiB` / `3728 MB`) | Controller `sdhc_1` (`mmc@7824900`) -> `/dev/mmcblk0` |
| **Device Tree (DTB)** | `msm8916-yiming-uz801v3.dtb` (`compatible = "yiming,uz801-v3", "qcom,msm8916"`) | Termasuk `msm8916-ufi.dtsi` |
| **GPIO Tombol & LED** | - **Tombol Reset**: `GPIO 23` (`GPIO_ACTIVE_LOW`, pull-up)<br>- **LED Merah (Power)**: `GPIO 7` (`GPIO_ACTIVE_HIGH`)<br>- **LED Hijau (WLAN/WAN)**: `GPIO 8` (`GPIO_ACTIVE_HIGH`)<br>- **LED Biru (WAN/WLAN)**: `GPIO 6` (`GPIO_ACTIVE_HIGH`) | **JANGAN gunakan profil `thwc,ufi001c` / `generic,uf02` di bootloader `lk2nd`!** Pada `uz801-v3`, `GPIO 37` bernilai *LOW* secara fisik. Di `ufi001c`, `GPIO 37` adalah tombol EDL! |
| **WiFi / BT** | Qualcomm WCN3620 (`wcnss` remoteproc `a204000.remoteproc`, driver `wcn36xx`) | Butuh `wcnss.mdt` + `wcnss.b00..b11` + `wlan/prima/WCNSS_qcom_wlan_nv.bin` |
| **Modem 4G LTE** | Qualcomm Hexagon QDSP6 (`mpss` remoteproc `4080000.remoteproc`, driver `qcom_q6v5_mss` + `bam_dmux`) | Butuh `mba.mbn` + `modem.mdt` + `modem.b00..b25` + `mcfg_sw.mbn` + layanan `rmtfs` (membaca partisi `modemst1`, `modemst2`, `fsg`, `fsc`) |
| **USB Controller** | ChipIdea High-Speed Dual-Role USB (`ci_hdrc_msm`, `usb@78d9000`, UDC `ci_hdrc.0`) | Hanya ada 1 port USB fisik (dipakai sekaligus untuk power 5V dan data USB Gadget NCM/RNDIS/ADB) |

---

## 2. Arsitektur Boot Chain & Tabel Partisi GPT (14 Partisi)

### 2.1. Alur Booting Mainline (64-bit)
```text
PBL (ROM) 
  └──> SBL1 (sbl1.mbn dari db410c, inisialisasi DDR 512MB internal)
         ├──> RPM (rpm.mbn, power/clock management)
         ├──> TZ  (tz.mbn, TrustZone 64-bit)
         └──> HYP (hyp.mbn = qhypstub, bypass hypervisor agar Linux boot di EL2)
                └──> ABOOT (aboot.mbn = lk1st-msm8916, membaca ext2 /boot/extlinux/extlinux.conf)
                       └──> Linux Kernel (/vmlinuz + /dtbs/qcom/msm8916-yiming-uz801v3.dtb)
                              └──> Rootfs (/dev/mmcblk0p14, ext4)
```

### 2.2. Layout Tabel Partisi GPT (`gpt_both0.bin`)
Total sektor eMMC: `7634944` (`0x748000`).

| No | Dev Node | Nama Partisi (`PARTLABEL`) | Start Sector | Size (Sectors) | Ukuran | Fungsi |
| :- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | `/dev/mmcblk0p1` | `fsc` | `4096` | `2` | 1 KB | Radio FS Cookie (Wajib di-backup/restore) |
| 2 | `/dev/mmcblk0p2` | `fsg` | `4098` | `3072` | 1.5 MB | Golden Radio EFS Backup (Wajib di-backup/restore) |
| 3 | `/dev/mmcblk0p3` | `modem` | `7170` | `131072` | 64 MB | Partisi FAT16 berisi firmware `image/modem.*`, `mba.mbn`, `wcnss.*` |
| 4 | `/dev/mmcblk0p4` | `modemst1` | `138242` | `3072` | 1.5 MB | Partisi NV/EFS Modem 1 / IMEI (Wajib di-backup/restore) |
| 5 | `/dev/mmcblk0p5` | `modemst2` | `141314` | `3072` | 1.5 MB | Partisi NV/EFS Modem 2 / IMEI (Wajib di-backup/restore) |
| 6 | `/dev/mmcblk0p6` | `persist` | `144386` | `65536` | 32 MB | Partisi ext4 berisi `WCNSS_qcom_wlan_nv.bin` |
| 7 | `/dev/mmcblk0p7` | `sec` | `209922` | `32` | 16 KB | Security fuse configuration |
| 8 | `/dev/mmcblk0p8` | `hyp` | `209954` | `1024` | 512 KB | `qhypstub` yang sudah di-sign dengan `qtestsign` |
| 9 | `/dev/mmcblk0p9` | `rpm` | `210978` | `1024` | 512 KB | `rpm.mbn` dari paket bootloader DB410c |
| 10 | `/dev/mmcblk0p10` | `sbl1` | `212002` | `1024` | 512 KB | `sbl1.mbn` dari paket bootloader DB410c |
| 11 | `/dev/mmcblk0p11` | `tz` | `213026` | `2048` | 1 MB | `tz.mbn` dari paket bootloader DB410c |
| 12 | `/dev/mmcblk0p12` | `aboot` | `215074` | `2048` | 1 MB | `lk1st-msm8916` (`emmc_appsboot.mbn` signed dengan `qtestsign`) |
| 13 | `/dev/mmcblk0p13` | `boot` | `217122` | `131072` | 64 MB | Partisi **`ext2`** berisi `/vmlinuz`, `/dtbs/`, `/extlinux/extlinux.conf` |
| 14 | `/dev/mmcblk0p14` | `rootfs` | `348194` | `7286717` | ~3.5 GB | Partisi **`ext4`** berisi sistem operasi utama (`/`) |

> **PERINGATAN KRITIS TENTANG PARTISI `cdt`:**
> - **JANGAN** membuat partisi `cdt` dan mem-flash `sbc_1.0_8016.bin` jika menggunakan skema `lk1st-msm8916` + `gpt_both0.bin` 14-partisi ini!
> - `sbc_1.0_8016.bin` memiliki konfigurasi DDR **1 GB** (milik DragonBoard 410c) dan `board_id = 0x18` (`HW_PLATFORM_SBC`). Jika partisi `cdt` ada di GPT, `sbl1.mbn` akan meload konfigurasi DDR 1 GB pada chip RAM 512 MB UZ801 dan gagal booting. Tanpa partisi `cdt`, `sbl1.mbn` otomatis menggunakan tabel DDR default internalnya (512 MB, `board_id = 0x08` `HW_PLATFORM_MTP`) yang cocok 100% dengan `lk1st-msm8916`.

---

## 3. Delapan Jebakan Kritis (*Root Causes*) & Solusinya

Berikut adalah temuan masalah paling krusial saat mem-porting OS ke UZ801 v3.0 beserta solusinya:

### Jebakan 1: Dongle Selalu Balik ke Mode EDL (`9008` / `QHSUSB__BULK`) Saat Boot
- **Gejala:** Setelah flash `firmware.zip`, setiap kali dicolok dongle langsung masuk ke mode EDL `9008`.
- **Penyebab:** `lk1st-msm8916` (`aboot.mbn`) dikompilasi dengan `LK2ND_COMPATIBLE="generic,uf02"` (alias dari `thwc,ufi001c`). Pada board `ufi001c`, `GPIO 37` adalah tombol EDL (`GPIO_ACTIVE_LOW`). Sedangkan pada board **`uz801-v3`**, jalur `GPIO 37` secara hardware tertarik *LOW* (dan tombol fisik sebenarnya ada di `GPIO 23`). Akibatnya, `lk2nd` mengira tombol EDL sedang ditekan terus dan memanggil `reboot into dload mode`.
- **Solusi:** Saat meng-compile `lk2nd` (`scripts/build-firmware.sh`), **WAJIB** gunakan:
  ```bash
  make \
    LK2ND_BUNDLE_DTB="msm8916-512mb-mtp.dtb" \
    LK2ND_COMPATIBLE="yiming,uz801-v3" \
    TOOLCHAIN_PREFIX=arm-none-eabi- \
    lk1st-msm8916
  ```

### Jebakan 2: Dongle Berhenti di LED Merah Solid (Gagal Mount eMMC `/dev/mmcblk0p14`)
- **Gejala:** Bootloader lewat (`lk2nd` jalan, kernel mulai boot dan menyalakan LED merah `led_r`), tetapi tidak ada aktivitas USB maupun WiFi.
- **Penyebab:** Script pembuat DTB (`scripts/build-dtb.sh`) meng-clone `https://github.com/torvalds/linux.git` tanpa menentukan tag versi (mengambil branch `HEAD` Linux `6.13+`/`6.19`). Di Linux `6.13+`, node eMMC `mmc@7824900` di `msm8916.dtsi` menambahkan properti `resets = <&gcc GCC_SDCC1_BCR>;` (`<0x13 0x24>`). Padahal kernel yang dipakai adalah **Linux `6.12.1-msm8916`**, yang driver `gcc-msm8916`-nya belum mengenali reset index tersebut! Akibatnya probe `mmc0` gagal dengan `-EINVAL` dan kernel hang di `Waiting for root device /dev/mmcblk0p14...`.
- **Solusi:** **WAJIB** mengunci branch/tag repo DTS sesuai versi kernel (`--branch v6.12` untuk kernel `6.12.x`), atau gunakan langsung file `.dtb` bawaan paket kernel `linux-postmarketos-qcom-msm8916`.

### Jebakan 3: Rusaknya Partisi `/boot` (`ext2`) Saat Dongle Dicabut Tanpa Shutdown
- **Gejala:** Boot pertama setelah flash berhasil, tetapi setelah dongle dicabut (misal untuk pasang SIM card) dan dicolok lagi, dongle gagal masuk ke runlevel `default`.
- **Penyebab:**
  1. USB dongle tidak punya tombol power/baterai dan selalu dimatikan dengan cara langsung dicabut dari port USB.
  2. Partisi `/boot` (`/dev/mmcblk0p13`) menggunakan filesystem **`ext2` (tidak punya journal)** karena `lk2nd` hanya bisa membaca `ext2`.
  3. Jika `/etc/fstab` me-mount `/boot` sebagai `rw` (`defaults 0 2`), maka begitu dongle dicabut, superblock `/boot` berstatus *dirty* (`s_state = 0`). Saat dicolok kembali, layanan `fsck` mendeteksi `/boot` tidak bersih dan menghentikan proses boot (`rc-abort` / reboot loop).
  4. Selain itu, jangan pernah menjalankan `e2fsck -fy` pada partisi `/` yang sedang ter-mount `rw` di dalam script `expand-rootfs.sh`, dan wajib panggil `sync` setelah `resize2fs`.
- **Solusi:** Di `/etc/fstab`, mount `/boot` secara **Read-Only (`ro`)** dan `/` dengan `commit=1`:
  ```fstab
  /dev/mmcblk0p13    /boot    ext2    ro,noatime          0 0
  /dev/mmcblk0p14    /        ext4    rw,noatime,commit=1 0 0
  ```

### Jebakan 4: Korupsi Loop Mount (`mount -o loop`) di Dalam Docker Container (macOS OrbStack/Docker Desktop)
- **Gejala:** Saat membuat `boot.raw` dan `rootfs.raw` di dalam container Docker pada direktori `/tmp` (yang berada di atas *OverlayFS*), `mount -o loop` sering gagal menulis balik (*flush*) page-cache ke file `.raw` sebelum `umount`, menghasilkan `boot.img.gz` kosong (`64 KB`).
- **Solusi:** Gunakan fitur native `-d <rootdir>` milik `e2fsprogs` (`mkfs.ext2` & `mkfs.ext4` versi 1.46+) yang mengisi filesystem langsung di *userspace* tanpa memerlukan `mount -o loop` sama sekali:
  ```bash
  truncate -s $((64 * 1024 * 1024)) boot.raw
  mkfs.ext2 -F -d /path/ke/boot_dir boot.raw

  truncate -s $((512 * 1024 * 1024)) rootfs.raw
  mkfs.ext4 -F -d /path/ke/root_dir rootfs.raw
  ```
  *(Catatan: Ukuran image awal `rootfs.raw` cukup `512 MiB` agar proses flash via EDL 3x lebih cepat (~80 detik); saat first boot `resize2fs /dev/mmcblk0p14` otomatis memperbesarnya ke 3.4 GB).*

### Jebakan 5: USB Gadget NCM (`usb0`) Berstatus `inactive` di macOS & Bentrok dengan `adbd`
- **Gejala:** Perangkat USB terdeteksi sebagai `USB Network` (`en13`) di macOS, tetapi berstatus `inactive` (tidak dapat IP), atau saat `ffs.adb` ditambahkan USB sama sekali tidak muncul.
- **Penyebab:**
  1. Driver kernel Linux `f_ncm` (`usb_f_ncm`) **baru mengirim sinyal *Link Connected* (`USB_CDC_NOTIFY_NETWORK_CONNECTION = 1`) ke host macOS apabila interface `usb0` di sisi dongle sudah dinaikkan (`ip link set usb0 up`)**. Jika menunggu NetworkManager yang justru menunggu *carrier* aktif lebih dulu, terjadi *deadlock* (`status: inactive`).
  2. Untuk **ADB (`ffs.adb` / FunctionFS)**: Daemon `/usr/bin/adbd -D` **wajib** sudah me-mount `/dev/usb-ffs/adb` (`-t functionfs`) dan `/dev/pts` (`-t devpts`), serta menulis descriptor ke `/dev/usb-ffs/adb/ep0` (sehingga file `ep1` dan `ep2` muncul) **SEBELUM** nama controller (`ci_hdrc.0`) ditulis ke file `UDC`.
  3. Jika `adbd` dijalankan sebagai *background job* biasa (`adbd &`) dari script udev/OpenRC, proses `adbd` akan terkena `SIGHUP`/dibunuh ketika script selesai. Begitu `adbd` mati dan menutup `ep0`, kernel `f_fs` otomatis memutus seluruh koneksi USB Gadget (`UDC` menjadi kosong)!
- **Solusi:**
  - Gunakan `start-stop-daemon --start --background --exec /usr/bin/adbd -- -D` (atau `nohup ... </dev/null &`).
  - Sediakan *fallback* otomatis saat menulis ke `UDC`: jika `echo "$UDC" > UDC` gagal, lepas symlink `configs/c.1/ffs.adb` lalu tulis ulang `echo "$UDC" > UDC` agar jaringan USB NCM tetap dijamin menyala.
  - Begitu `UDC` aktif, langsung jalankan `ip link set usb0 up`, pasang IP `192.168.42.1/24`, dan jalankan `dnsmasq` untuk melayani DHCP ke host macOS.

### Jebakan 6: Binary `adbd` di Alpine Linux (`musl` `aarch64`)
- **Masalah:** Paket `android-tools` di Alpine Linux hanya berisi `adb` (client) dan `fastboot`, tidak menyertakan daemon `adbd` untuk gadget.
- **Solusi:** Gunakan binary `/usr/bin/adbd` + `/usr/lib/libcrypto.so.1.1` dari OpenWrt/HandsomeMod (`aarch64_cortex-a53_musl`) yang menggunakan interpreter `/lib/ld-musl-aarch64.so.1` yang sama persis dengan Alpine Linux!
  - Karena binary `adbd` mengeksekusi `/system/bin/sh` saat `adb shell` dipanggil, buat wrapper `/system/bin/sh`:
    ```bash
    #!/bin/bash
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root
    export TERM=${TERM:-xterm-256color}
    exec /bin/bash "$@"
    ```

### Jebakan 7: WiFi (`wlan0`) Tidak Mau Konek di Alpine Linux
- **Penyebab:**
  1. Script `/etc/init.d/wpa_supplicant` bawaan Alpine memiliki bug logika: ia mencari interface wireless dan menjalankan `wpa_supplicant -iwlan0` **tanpa flag `-u` (D-Bus)**. Akibatnya `NetworkManager` tidak bisa berkomunikasi dengan `wpa_supplicant` via D-Bus.
  2. Paket `wireless-regdb` dan `iw` belum terinstall.
  3. Layanan `msm-firmware-loader` menimpa `/sys/module/firmware_class/parameters/path` ke `/run/msm-firmware-loader/target`.
- **Solusi:**
  - Salin seluruh file firmware WiFi (`wcnss.mdt`, `wcnss.b00..b11`, `WCNSS_qcom_wlan_nv.bin`, `wlan/prima/WCNSS_qcom_wlan_nv.bin`) langsung ke `/lib/firmware` di rootfs dan nonaktifkan `msm-firmware-loader` dari runlevel `sysinit`.
  - Ganti `/etc/init.d/wpa_supplicant` agar menjalankan `/sbin/wpa_supplicant -u` (mode D-Bus murni untuk NetworkManager):
    ```sh
    #!/sbin/openrc-run
    supervisor=supervise-daemon
    name="WPA Supplicant"
    command=/sbin/wpa_supplicant
    command_args="-u"
    depend() {
        need localmount dbus
        after bootmisc modules udev-settle
        before networkmanager net
        keyword -shutdown
    }
    ```

### Jebakan 8: Modem 4G LTE (`wwan0`) Tidak Konek / Putus Setelah Restart
- **Penyebab:**
  1. Modem MSM8916 membutuhkan file firmware asli dari perangkat (`mba.mbn`, `modem.mdt`, `modem.b00..b25`, dan profil operator `mcfg_sw.mbn` Generic 3GPP ROW) di `/lib/firmware/`, serta partisi kalibrasi `fsc`, `fsg`, `modemst1`, `modemst2` yang valid untuk layanan `rmtfs`.
  2. Di profil NetworkManager (`lte.nmconnection`), setting `[ipv6] method=auto` membuat NetworkManager gagal/timeout saat menunggu konfigurasi IPv6 dari jaringan seluler Indonesia (Telkomsel/by.U/XL/Indosat), sehingga koneksi `wwan0` diputus kembali.
- **Solusi:**
  - Set `[ipv6] method=ignore` (IPv4 only) dan `apn=byu` (atau `internet`) dengan `autoconnect=true` & `autoconnect-retries=0` di `/etc/NetworkManager/system-connections/lte.nmconnection`.
  - Tambahkan script `/etc/local.d/lte-autoconnect.start` untuk memastikan modem di-*enable* (`mmcli -m 0 -e`) dan koneksi `lte` diaktifkan (`nmcli connection up lte`) saat boot.

---

## 4. Langkah Build & Flash Lengkap di macOS (OrbStack / Docker)

### 4.1. Build Image menggunakan Docker (OrbStack)
Jalankan perintah berikut dari root repositori `msm8916-alpine`:

```bash
docker run --rm --privileged \
  -v "$PWD:/host" \
  -v "/Users/macbook/Downloads/UZ801-USB-MODEM-main/backup_kayla_extracted:/kayla:ro" \
  -v msm8916-kernel-dts:/app/.kernel-dts \
  ubuntu:22.04 bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    mkdir -p /app
    tar -C /host --exclude="./files" --exclude="./.kernel-dts" --exclude="./.git" --exclude="./backup_original" --exclude="./saved" -cf - . | tar -C /app -xf -
    cd /app
    ./scripts/build-deps.sh
    mkdir -p files
    ./scripts/build-dtb.sh ./files
    ./scripts/build-rootfs.sh ./files

    # Inject firmware WiFi & LTE Modem asli ke /lib/firmware
    mkdir -p files/rootfs/lib/firmware/wlan/prima
    for f in /kayla/modem_extracted/IMAGE/MODEM.* /kayla/modem_extracted/IMAGE/MBA.* /kayla/modem_extracted/IMAGE/WCNSS.*; do
        [ -f "$f" ] && cp "$f" "files/rootfs/lib/firmware/$(basename "$f" | tr "[:upper:]" "[:lower:]")"
    done
    cp "/kayla/modem_extracted/IMAGE/MODEM_PR/MCFG/CONFIGS/MCFG_SW/GENERIC/COMMON/ROW/GEN_3GPP/MCFG_SW.MBN" "files/rootfs/lib/firmware/mcfg_sw.mbn"
    ln -sf mcfg_sw.mbn "files/rootfs/lib/firmware/MCFG_SW.MBN"
    for f in files/rootfs/lib/firmware/*.mdt; do
        [ -e "$f" ] && ln -sf "$(basename "$f")" "${f%.mdt}.mbn"
    done
    mkdir -p /mnt/persist && mount -o loop,ro /kayla/persist.img /mnt/persist
    cp /mnt/persist/WCNSS_qcom_wlan_nv.bin files/rootfs/lib/firmware/WCNSS_qcom_wlan_nv.bin
    cp /mnt/persist/WCNSS_qcom_wlan_nv.bin files/rootfs/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin
    umount /mnt/persist

    rm -f files/rootfs/etc/runlevels/sysinit/msm-firmware-loader
    rm -f files/rootfs/etc/runlevels/boot/msm-firmware-loader-unpack

    tar cpzf files/rootfs.tgz -C files/rootfs .
    ./scripts/build-images.sh ./files
    ./scripts/build-firmware.sh files/firmware.zip
    ./scripts/build-gpt.sh files/gpt_both0.bin
    mkdir -p /host/files
    cd /app/files && tar cf - *.img.gz *.tgz *.zip *.bin dtbs/ | tar xf - -C /host/files/
  '
```

### 4.2. Flash ke Perangkat via EDL (`9008`)
1. Pastikan tool `edl` sudah terinstall di macOS:
   ```bash
   brew install libusb
   uv tool install --python /opt/homebrew/bin/python3.11 git+https://github.com/bkerler/edl.git
   ```
2. Masukkan dongle ke mode EDL (tahan tombol reset saat mencolokkan USB), lalu verifikasi dengan `edl printgpt`.
3. Jalankan flash lengkap:
   ```bash
   ./flash.sh
   ```

---

## 5. Checklist untuk Porting OS Lain (Debian, Arch, Void, OpenWrt, dll.)

Jika kamu atau AI Agent ingin mem-porting distro Linux lain ke dongle ini, cukup pertahankan lapisan bawah dan ikuti kontrak berikut:

1. **Jangan Ubah Partisi 1–12 (`gpt_both0.bin` & `firmware.zip`)**:
   - Biarkan `hyp`, `rpm`, `sbl1`, `tz`, `aboot` (`lk1st-msm8916` dengan `LK2ND_COMPATIBLE="yiming,uz801-v3"`), serta partisi radio (`fsc`, `fsg`, `modem`, `modemst1`, `modemst2`, `persist`, `sec`) tetap seperti sekarang.
2. **Kontrak Partisi `boot` (`/dev/mmcblk0p13`)**:
   - Format **wajib `ext2`** (ukuran 64 MiB).
   - Berisi `/vmlinuz` (kernel `arm64` compressed/uncompressed), `/dtbs/qcom/msm8916-yiming-uz801v3.dtb` (dari sumber kernel yang **sama versinya** dengan `/vmlinuz`), dan `/extlinux/extlinux.conf`:
     ```text
     TIMEOUT 10
     DEFAULT linux

     LABEL linux
         MENU LABEL Linux MSM8916
         linux /vmlinuz
         fdt /dtbs/qcom/msm8916-yiming-uz801v3.dtb
         append earlycon root=/dev/mmcblk0p14 console=ttyMSM0,115200 no_framebuffer=true rw rootwait
     ```
3. **Kontrak Partisi `rootfs` (`/dev/mmcblk0p14`)**:
   - Format **`ext4`**.
   - `/etc/fstab` wajib me-mount `/boot` secara **`ro`** (`read-only`).
   - Menyertakan modul kernel `/lib/modules/<versi>-msm8916/` dan seluruh blob firmware di `/lib/firmware/` (`wcnss.*`, `modem.*`, `mba.mbn`, `mcfg_sw.mbn`, `wlan/prima/WCNSS_qcom_wlan_nv.bin`).
   - Menjalankan daemon **`rmtfs -P -r -s`** (wajib agar prosesor modem Hexagon tidak crash saat mengakses EFS).
   - Menjalankan script `usb-gadget` untuk mengaktifkan `ncm.usb0` + `ffs.adb` (`adbd`) dan menaikkan `ip link set usb0 up`.

---

## 6. Studi Kasus: Porting Void Linux (`aarch64-musl` + `runit`) — `scripts/build-void.sh`

Implementasi nyata kontrak di atas untuk mem-porting **Void Linux (`aarch64-musl`)** telah tersedia di [`scripts/build-void.sh`](../scripts/build-void.sh) dan menghasilkan `files/void-rootfs.img.gz`.

### Detail Khusus `runit` di Void Linux pada UZ801:
1. **Binary Compatibility (`musl`)**:
   - Karena `void-aarch64-musl` menggunakan dynamic linker `/lib/ld-musl-aarch64.so.1`, binary `/usr/sbin/rmtfs` + `libqrtr.so.1` dan `/usr/bin/adbd` + `libcrypto.so.1.1` berjalan 100% native tanpa kompilasi ulang.
2. **Stage 1 `/etc/runit/core-services/03-filesystems.sh`**:
   - Secara default, `03-filesystems.sh` di Void mencoba menjalankan `mount -o remount,ro / || emergency_shell` sebelum `fsck`. Pada embedded boot dengan `root=/dev/mmcblk0p14 rw`, sederhanakan `03-filesystems.sh` agar langsung `mount -o remount,rw /` dan `mount -a` sehingga tidak pernah terjebak di `emergency_shell`.
3. **Inisialisasi di `/etc/rc.local` (Stage 2 sebelum `runsvdir`)**:
   - Jalankan `resize2fs /dev/mmcblk0p14 && sync`, aktivasi swap `zram0` (256 MB), `/usr/sbin/usb-gadget start`, dan *background loop* auto-connect LTE di `/etc/rc.local` (bukan via udev rule di Stage 1 agar daemon `adbd` & `dnsmasq` tidak dihentikan oleh `udevadm control --exit` saat transisi Stage 1 -> Stage 2).
4. **Layanan `runit` (`/etc/runit/runsvdir/default/`)**:
   - `udevd`, `dbus`, `rmtfs` (`exec /usr/bin/rmtfs -P -r -s`), `wpa_supplicant` (`sv check dbus && exec /usr/bin/wpa_supplicant -u`), `NetworkManager`, `ModemManager` (`sv check dbus && exec /usr/bin/ModemManager`), `sshd`, `chronyd`, dan `agetty-ttyMSM0`.

---

## 7. Studi Kasus: Porting Arch Linux ARM (`aarch64` + `systemd` + `glibc`) — `scripts/build-arch.sh`

Implementasi nyata untuk mem-porting **Arch Linux ARM (`aarch64`)** telah tersedia di [`scripts/build-arch.sh`](../scripts/build-arch.sh) dan menghasilkan `files/arch-rootfs.img.gz`.

### Detail Khusus `systemd` & `glibc` di Arch Linux ARM pada UZ801:
1. **Koeksistensi `glibc` + Isolated `musl` Runtime**:
   - Sistem utama Arch Linux berjalan di atas `glibc` (`/lib/ld-linux-aarch64.so.1`).
   - Untuk menjalankan `/usr/bin/adbd` dan `/usr/bin/rmtfs` (yang dikompilasi terhadap `musl`) tanpa mengotori `/usr/lib` milik `glibc`, pasang `/usr/lib/ld-musl-aarch64.so.1`, letakkan library musl (`libqrtr.so.1`, `libudev.so.1`, `libcrypto.so.1.1`, `libz.so.1`, `libgcc_s.so.1`) di dalam `/usr/lib/musl/`, dan tulis `/usr/lib/musl` ke `/etc/ld-musl-aarch64.path`.
2. **Mengganti `dbus-broker` dengan `dbus-daemon`**:
   - Arch Linux modern menggunakan `dbus-broker.service` secara default, yang gagal (`fatal error: -107`) pada kernel embedded tanpa fitur audit/memfd tertentu. Ganti `/etc/systemd/system/dbus.service` agar mengeksekusi `/usr/bin/dbus-daemon --system --address=systemd: --nofork --nopidfile --systemd-activation --syslog-only`.
3. **`KillMode=none` pada Service Inisialisasi USB Gadget (`uz801-init.service`)**:
   - Pada `systemd`, unit `Type=oneshot` secara default memiliki `KillMode=control-group` yang akan membunuh proses background (`adbd` dan `dnsmasq`) begitu script `ExecStart` selesai. Wajib tambahkan `KillMode=none` pada `[Service]` di `uz801-init.service`.
4. **Serial Number USB Gadget Konsisten**:
   - Karena `systemd` men-generate `/etc/machine-id` secara dinamis, gunakan serial number statis di `usb-gadget` (`2c2d59162055f8d2`) agar MAC address NCM dan interface `enX` di macOS tidak berubah-ubah antar distro maupun antar reboot.

---

## 8. Studi Kasus: Porting DietPi v10.7 (`ARMv8 64-bit` / Debian 12 Bookworm) — `scripts/build-dietpi.sh`

Implementasi untuk mem-porting **DietPi (`ARMv8 64-bit`)** telah tersedia di [`scripts/build-dietpi.sh`](../scripts/build-dietpi.sh) dan menghasilkan `files/dietpi-rootfs.img.gz`.

### Detail Khusus DietPi pada UZ801:
1. **Menjaga Direktori `/boot/dietpi` Tetap Utuh**:
   - Seluruh core script DietPi (`dietpi-launcher`, `dietpi-software`, `dietpi-config`, `dietpi-banner`, `.version`, `.install_stage`) disimpan di dalam `/boot/dietpi` pada rootfs.
   - Karena itu, di `/etc/fstab` **jangan** me-mount partisi `/dev/mmcblk0p13` ke `/boot` agar tidak menutupi direktori `/boot/dietpi` pada `/dev/mmcblk0p14`.
2. **Bypass Interactive First-Boot & Hardware Model**:
   - Tulis `2` ke `/boot/dietpi/.install_stage` dan hapus symlink `dietpi-firstboot.service` agar tidak berhenti di wizard setup interaktif saat boot pertama.
   - Tulis `21` (`Native PC (aarch64)`) ke `/etc/.dietpi_hw_model_identifier` agar `dietpi-cpuinfo` dan manajemen frekuensi CPU (`schedutil` 200 MHz – 998 MHz) serta sensor suhu berjalan penuh.
3. **Sinkronisasi Jam Tanpa RTC (`systemd-timesyncd` + HTTP Date Header)**:
   - Karena UZ801 tidak memiliki baterai RTC, jam sistem saat cold-boot mundur sehingga sertifikat HTTPS (`curl` di `dietpi-banner` dan `apt update` ke `https://deb.debian.org`) ditolak dengan `certificate is not yet valid`.
   - Solusi: install `systemd-timesyncd` dan tambahkan sinkronisasi waktu awal via HTTP `Date:` header (`curl -sI http://1.1.1.1`) di `uz801-init.sh`.



