# Profile Reference — MSM8916 Alpine

Profiles are declared in `profiles/*.env` and selected at build time. They control packages, services, USB mode, and which stacks are pre-installed. The build order is:

```
profiles/default.env  →  profiles/<PROFILE>.env  →  variables.env (local overrides)
```

## Selecting a profile

Pass `PROFILE=<name>` to any build target, or use the named shorthand:

```bash
# Named shortcuts (inside the builder VM or CI)
make octoprint     # OctoPrint appliance
make docker        # Docker-enabled base
make zoraxy        # Zoraxy reverse proxy appliance

# Generic — no profile applied (default.env only)
make build-all

# Explicit profile on any target
make build-all PROFILE=octoprint
```

## Available profiles

### `default`

Baseline used by all builds. Installs USB gadget tooling, NetworkManager, Dropbear SSH, and zram swap. No appliance stack pre-installed.

| Key | Value |
|-----|-------|
| `USB_GADGET_INSTALL` | `yes` |
| `USB_GADGET_OTG` | `no` (gadget/NCM mode) |
| `DOCKER_ENABLE` | `no` |
| `OCTOPRINT_PREINSTALL` | `no` |
| `ZORAXY_PREINSTALL` | `no` |
| `STACKS` | _(empty)_ |

### `octoprint`

3D printer appliance. OctoPrint runs natively (no Docker). The single USB port is dedicated to the printer in OTG host mode — USB gadget networking is **not** available; use WiFi for remote access.

| Key | Value |
|-----|-------|
| `USB_GADGET_INSTALL` | `no` — gadget tooling omitted |
| `USB_GADGET_OTG` | `yes` — USB port boots as host for the printer |
| `USB_GADGET_ENABLED` | `no` |
| `OCTOPRINT_PREINSTALL` | `yes` |
| `STACKS` | `octoprint` |

The `octoprint` stack hook (`stacks/run-octoprint.sh`) runs inside the chroot during the build. It installs the USB serial kernel modules (`ch341`, `cdc-acm`, `ftdi_sio`, `pl2303`), sets up the OTG host boot script, installs OctoPrint into `/opt/octoprint/venv`, and pre-installs the Resource Monitor and LED Status plugins. No installer script is left on the device.

DTB: use `msm8916-yiming-uz801v3-octoprint.dtb` to reclaim ~91 MB from unused LTE modem and video decode firmware reserves.

### `docker`

Docker-enabled base image. USB gadget networking active. No appliance stack pre-installed.

| Key | Value |
|-----|-------|
| `USB_GADGET_INSTALL` | `yes` |
| `USB_GADGET_OTG` | `no` |
| `DOCKER_ENABLE` | `yes` |
| `STACKS` | _(empty)_ |

Use this profile as a base for Docker Compose stacks (`stacks/*.docker-compose.yml`).

### `zoraxy`

Zoraxy native reverse proxy appliance. No Docker required.

| Key | Value |
|-----|-------|
| `USB_GADGET_INSTALL` | `yes` |
| `USB_GADGET_OTG` | `no` |
| `ZORAXY_PREINSTALL` | `yes` |
| `STACKS` | `zoraxy` |

Admin panel: `http://<device-ip>:8000`

## Per-profile package and service additions

To add packages or services specific to a profile, set `PROFILE_PACKAGES` and `PROFILE_SERVICES` in the profile's `.env`. These are additive on top of the default base set:

```bash
# profiles/myprofile.env
PROFILE_PACKAGES="htop tmux"
PROFILE_SERVICES="my-daemon"
```

Extra packages for any build (regardless of profile) can be added in `variables.env`:

```bash
# variables.env (gitignored)
PACKAGES="chrony wireguard-tools"
SERVICES_AUTOSTART="chronyd"
```

## USB mode summary

| Profile | USB port | Gadget (NCM/RNDIS) | OTG host |
|---------|----------|--------------------|----------|
| default | networking | ✓ | optional |
| docker  | networking | ✓ | optional |
| zoraxy  | networking | ✓ | optional |
| octoprint | **printer** | ✗ | ✓ (forced) |

## Profile validation

After flashing and first boot:

```bash
# Check which profile is active
cat /etc/octoprint-profile 2>/dev/null || echo "(no profile tag on device)"

# OctoPrint profile
rc-service octoprint status          # started
ls /var/lib/octoprint/               # data dir exists

# Docker profile
rc-service docker status             # started

# Zoraxy profile
rc-service zoraxy status             # started

# Confirm no stray unused installer scripts
ls ~/install-*.sh 2>/dev/null || echo "clean"
```

Automated pre-flash check (inside builder VM):

```bash
make verify-octoprint     # checks OctoPrint profile artifacts
make check-profiles       # checks all profiles pass basic contract
```
