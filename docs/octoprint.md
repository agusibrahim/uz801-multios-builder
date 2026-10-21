# OctoPrint on MSM8916 Alpine

OctoPrint core for a Creality Ender-3 V3 SE (or similar USB-serial printer) running on an MSM8916
dongle with constrained memory (~384 MB usable). Read this before installing.

## What this is (and isn't)

| | This setup |
|---|---|
| OctoPrint core | ✓ |
| OctoPi image | ✗ — this is Alpine Linux, not OctoPi |
| Docker | ✗ — intentionally avoided; too heavy for ~384 MB RAM |
| Webcam / live monitoring | Optional — install a lightweight plugin; no timelapse by default |
| Pre-installed plugins | Resource Monitor 0.4.0, LED Status 1.0.0 |
| LTE modem | ✗ — disabled in the OctoPrint DTB profile to reclaim ~86 MB RAM |

OctoPrint runs as a native OpenRC service under a dedicated `octoprint` user, pre-installed via the `octoprint` profile build into `/opt/octoprint/venv`. No post-boot installer script is left on the device.

## Memory layout

The dongle has 512 MB total RAM. With the generic DTB, modem firmware and video decode reserves
consume roughly 91 MB. The OctoPrint DTB profile (`msm8916-yiming-uz801v3-octoprint.dtb`) disables
those regions and leaves ~384 MB usable for the OS and OctoPrint.

On top of that, the image configures a **256 MB zram swap** device using lz4 compression
(`/etc/local.d/zram.start`). zram compresses idle pages in RAM; it is not a substitute for real
RAM but it gives OctoPrint headroom when the kernel needs to reclaim pages. No external swap
device is required.

**Keep plugins light.** Each installed OctoPrint plugin consumes RAM at startup. Avoid heavy
plugins (OctoPrint-Dashboard, timelapse, etc.) on this device.

## Interesting plugins

- **Resource Monitor** — preinstalled (v0.4.0). Watches RAM, CPU, disk, and network. On this box you only get ~384 MB usable RAM, so this is the fast way to catch memory pressure before OctoPrint or a plugin gets OOM-killed.
- **LED Status** — preinstalled (v1.0.0). Drives the dongle's green and blue LEDs to show printer state at a glance. See [docs/led-status.md](led-status.md).
- **OctoPrint-RTSP** — for camera monitoring via RTSP (install manually from OctoPrint's Plugin Manager):
  ```text
  https://github.com/soopahfly/OctoPrint-RTSP/archive/v1.0.3.zip
  ```

Keep camera use to live monitoring first. Avoid timelapse unless idle RAM/CPU during real prints still looks safe.

## Plugin source vs artifacts policy

The repository keeps **plugin source** for the appliance-owned LED Status plugin under
`plugins/octoprint-led-status/`.

Generated plugin ZIPs under `plugins/*/dist/` are **not source-controlled release inputs**.
They are treated as build outputs: the OctoPrint image build runs `make plugins` and installs the
freshly built LED Status ZIP into the chroot. The tracked source, helper, and sudoers files are the
authoritative inputs.

The stray `plugins/octoprint-network-settings/` ZIP was reviewed and is not used by the appliance
build, so it is not kept as a repository input.

## USB and WiFi — read this first

The OctoPrint appliance uses its **single USB port** for the printer in **USB OTG host mode**.
That port is **not** a USB networking fallback in this profile: `usb0` gadget mode is not part of
the appliance, so remote access is expected to happen over **WiFi only**.

> **Make sure WiFi works before depending on the box remotely.** If you save a bad wireless config,
> there is no second USB-network path to fall back to and you can lock yourself out until you get
> local access again.

The OctoPrint profile boots in OTG host mode already. Plug in the printer with a USB-A to USB-C/B
cable (or USB OTG adapter). The printer should enumerate within a few seconds.

## Expected serial devices

When a Creality Ender-3 V3 SE (or similar) is connected via USB, the kernel registers a serial
device. Look for:

| Device | Driver | Typical printer |
|---|---|---|
| `/dev/ttyUSB0` | USB serial (CH340, CP2102) | Creality boards with CH340 chip |
| `/dev/ttyACM0` | CDC-ACM | Printers with STM32 or similar |

```bash
# Check what appeared after connecting the printer
dmesg | tail -20
ls /dev/tty{USB,ACM}* 2>/dev/null
```

The `octoprint` service user is added to the `dialout` group during the build so it can open serial ports without root.

## Kernel drivers for USB serial

> **The `linux-postmarketos-qcom-msm8916` kernel (6.12.1-msm8916) does not ship
> `cdc_acm` or `ch341` as precompiled modules. There is no `apk add` that installs
> them.** Confirmed via `apk search ch341`, `apk search cdc-acm`, and the running
> kernel config (`CONFIG_USB_ACM=not set`, `CONFIG_USB_SERIAL_CH341=not set`).

What *is* already present on the device:
- `usbserial.ko` — generic USB serial core (dependency for all USB serial drivers)
- `cp210x.ko` — SiLabs CP2102/CP2104 adapters already work

### Decision: out-of-tree module build, exact kernel version

We build only the missing `.ko` files against the exact kernel source for
`6.12.1-msm8916`. This approach:

- Keeps `uname -r` unchanged on the device (no full kernel rebuild or reflash).
- Avoids touching the bootloader or extlinux chain.
- Produces two small `.ko` files that are `insmod`/`modprobe`-able and can be
  added to the image under `/lib/modules/6.12.1-msm8916/kernel/drivers/usb/`.

A full kernel rebuild is **not chosen** because it would require reflashing,
risks boot regressions, and is unnecessary when `usbserial.ko` (the dependency)
is already loaded.

### Minimal driver list

| CONFIG symbol | Module file | `/dev` node | Needed for |
|---|---|---|---|
| `USB_ACM` | `cdc-acm.ko` | `/dev/ttyACM0` | STM32-based boards (e.g. newer Creality, BLTouch) |
| `USB_SERIAL_CH341` | `ch341.ko` | `/dev/ttyUSB0` | Creality boards with CH340/CH341 chip |
| `USB_SERIAL_FTDI_SIO` | `ftdi_sio.ko` | `/dev/ttyUSB0` | FTDI-based adapters (optional) |
| `USB_SERIAL_PL2303` | `pl2303.ko` | `/dev/ttyUSB0` | Prolific PL2303 adapters (optional) |

`cp210x.ko` is already present and covers SiLabs CP210x — no action needed.

Build order for issues 002–005: set up cross-compile environment → clone
postmarketos kernel source at tag `6.12.1-msm8916` → enable the four symbols
above in `.config` → build only `M=drivers/usb/serial drivers/usb/class` →
copy resulting `.ko` files into the image.

## DTB profile selection

Set `DTB_FILE` in `variables.env` before building, or update `extlinux.conf` on the device after
first boot:

```bash
# For OctoPrint (LTE + video decode disabled, WiFi kept)
DTB_FILE="msm8916-yiming-uz801v3-octoprint.dtb"

# Generic (LTE enabled)
DTB_FILE="msm8916-yiming-uz801v3.dtb"
```

To switch on a running device:

```bash
# Edit extlinux.conf and reboot
sudo vi /boot/extlinux/extlinux.conf   # change the FDT line
sudo reboot
```

Confirm after reboot:

```bash
# LTE modem devices should be absent in the OctoPrint profile
ls /dev/cdc-wdm* 2>/dev/null || echo "modem absent (expected)"
free -m   # should show ~384 MB total
```

## Install

OctoPrint is pre-installed when you build with `make octoprint`. The `stacks/run-octoprint.sh` hook runs inside the chroot during the image build and:

1. Installs Alpine system dependencies (`python3`, build headers)
2. Creates the `octoprint` service user in the `dialout` group
3. Installs OctoPrint into `/opt/octoprint/venv`
4. Downloads the Resource Monitor plugin (v0.4.0, pinned)
5. Builds the LED Status plugin ZIP from `plugins/octoprint-led-status/` and installs it with its helper + sudoers rule
6. Enables the OpenRC service in the default runlevel
7. Installs USB serial modules and the OTG host boot script

No installer script is copied to the device. Flash the image and boot — OctoPrint starts automatically.

## Access

OctoPrint binds to all interfaces on **port 5000**.

```bash
# From your laptop — use the dongle's WiFi IP
http://192.168.1.XXX:5000

# Find the WiFi IP on the appliance itself
ip addr show wlan0
nmcli device show wlan0
```

First launch triggers the OctoPrint setup wizard in the browser.

## Service management

```bash
# Start / stop / restart
rc-service octoprint start
rc-service octoprint stop
rc-service octoprint restart

# Status
rc-service octoprint status

# Logs
tail -f /var/log/octoprint/octoprint.log
```

## Long-print health logging

`print-health` is a diagnostic snapshot command installed at `/usr/local/sbin/print-health`. It writes one timestamped block to `/var/log/print-health.log` every 15 minutes via `/etc/periodic/15min/`. The log is capped at 2000 lines (~200 KB) by tail-rotation; it never triggers a reboot, watchdog, or any self-healing action — it is read-only observability.

### Categories captured

| Section | What is logged |
|---|---|
| `uptime/load` | `uptime` output — system age and 1/5/15-min load averages |
| `memory` | `free -m` — RAM and zram swap usage |
| `disk` | `df -h / /var/log` — root and log filesystem fill |
| `thermal` | All `thermal_zone*/temp` entries — zone name, type, °C |
| `kernel-errors` | Last 20 `dmesg` lines at err/crit/alert/emerg level |
| `networking` | `ip -brief addr` + default route |
| `usb-serial` | `/dev/ttyUSB*` and `/dev/ttyACM*` presence |
| `octoprint-service` | `rc-service octoprint status` exit state |

Every section is best-effort: a missing device or service prints `unavailable` and the script continues.

### Inspect the log

```bash
# Tail the live log
tail -f /var/log/print-health.log

# Show the last snapshot
awk '/^=== print-health/{buf=""} {buf=buf $0 "\n"} END{printf "%s",buf}' /var/log/print-health.log

# Count snapshots collected
grep -c '^=== print-health' /var/log/print-health.log

# Show only thermal readings across all snapshots
grep -A5 '--- thermal ---' /var/log/print-health.log

# Show kernel errors across all snapshots
grep -A20 '--- kernel-errors ---' /var/log/print-health.log | grep -v '^--$'

# Run a snapshot manually right now
/usr/local/sbin/print-health
```

## OctoPrint UI system commands

Configure these in OctoPrint → Settings → Server → Commands:

```bash
# Restart OctoPrint
sudo rc-service octoprint restart

# Restart the device
sudo reboot

# Power off the device
sudo poweroff
```

The OctoPrint installer grants passwordless sudo only for these three commands.

## Disable / uninstall

```bash
# Disable autostart (keeps data intact)
rc-update del octoprint default
rc-service octoprint stop

# Full removal (destroys config and uploaded files)
rc-service octoprint stop
rc-update del octoprint default
rm -rf /opt/octoprint /var/lib/octoprint /var/log/octoprint /etc/init.d/octoprint
deluser octoprint
```

## Manual verification status

Resource Monitor is preinstalled. Confirm it is listed in Plugin Manager and its tab renders on the appliance.

## Troubleshooting

| Symptom | Check |
|---|---|
| No `/dev/ttyUSB0` or `/dev/ttyACM0` | `dmesg | tail -20` — cable, OTG mode, printer power. If dmesg shows `unknown USB device` with no driver, the kernel module is missing (see **Kernel drivers for USB serial** above) |
| OctoPrint unreachable on port 5000 | `rc-service octoprint status`, check logs |
| OOM / service killed | `free -m`, `dmesg | grep -i oom` — disable heavy plugins, confirm OctoPrint DTB profile |
| Modem still present | Wrong DTB loaded — check `extlinux.conf` FDT line |
| LEDs not changing state | Check `/sys/class/leds/green:wan` and `/sys/class/leds/blue:wlan` exist; see [docs/led-status.md — Troubleshooting](led-status.md#troubleshooting) |
| OctoPrint missing after flash | Rebuild with `make octoprint` — confirm the build log shows `[*] Preinstalling OctoPrint...` |
