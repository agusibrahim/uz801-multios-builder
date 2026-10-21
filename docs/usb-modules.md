# USB Serial Modules — Build & Deploy Decision

## What is built

`scripts/build-modules.sh` (via `make kernel-modules`) compiles these in-tree modules against the
prepared msm8916 kernel build environment (see `scripts/setup-kernel-build.sh`):

| Module | Driver |
|---|---|
| `usbserial.ko` | USB serial core (dependency) |
| `ch341.ko` | CH340/CH341 (Creality, most cheap USB-serial dongles) |
| `ftdi_sio.ko` | FTDI FT232 |
| `pl2303.ko` | Prolific PL2303 |
| `cdc-acm.ko` | CDC ACM (if `CONFIG_USB_ACM=m` in `.config`) |

Artifacts land in `kernel-build/artifacts/6.12.1-msm8916/modules/` (gitignored).

## Vermagic decision

After building, the script calls `modinfo -F vermagic` on every `.ko` and
checks that it starts with **`6.12.1-msm8916`**.

| Outcome | Meaning | Action |
|---|---|---|
| ✅ Prefix matches | Kernel ABI is compatible | Copy `.ko` files to device + run `depmod -a`. **No full kernel install needed.** |
| ❌ Prefix mismatch | Config divergence (extra `LOCALVERSION`, different build flags) | Re-run setup with `device.config.gz` from `/proc/config.gz` on the device, rebuild, recheck. If still mismatched, full kernel install required. |

## How to use the built modules on the device

```sh
# On the build host — copy artifacts to device
scp kernel-build/artifacts/6.12.1-msm8916/modules/*.ko root@<device-ip>:/lib/modules/6.12.1-msm8916/kernel/drivers/usb/serial/
scp kernel-build/artifacts/6.12.1-msm8916/modules/cdc-acm.ko root@<device-ip>:/lib/modules/6.12.1-msm8916/kernel/drivers/usb/class/

# On the device
depmod -a
modprobe ch341
```

> Integration into the rootfs image is tracked in issue 005.

## Quick start

```sh
# 1. Prepare kernel build env (Linux/VM only)
make kernel-env          # runs setup-kernel-build.sh

# 2. Build USB modules
make kernel-modules      # runs build-modules.sh

# 3. Validate environment (works on macOS too, skips compile checks)
make kernel-env-check
```
