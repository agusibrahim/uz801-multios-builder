#!/bin/bash
set -euo pipefail

OCTOPRINT_USER="octoprint"
INSTALL_DIR="/opt/octoprint"
VENV_DIR="$INSTALL_DIR/venv"
DATA_DIR="/var/lib/octoprint"
VERSION_FILE="$INSTALL_DIR/version"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCE_MONITOR_VERSION="0.4.0"
RESOURCE_MONITOR_ZIP="${RESOURCE_MONITOR_ZIP:-}"
LED_STATUS_VERSION="1.0.0"
LED_STATUS_ZIP="${LED_STATUS_ZIP:-}"
LED_STATUS_HELPER="${LED_STATUS_HELPER:-$SCRIPT_DIR/../plugins/octoprint-led-status/helper/led-helper}"
LED_STATUS_SUDOERS="${LED_STATUS_SUDOERS:-$SCRIPT_DIR/../plugins/octoprint-led-status/sudoers/octoprint-led}"
YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) YES=1 ;;
        *) echo "ERROR: unknown argument: $1"; exit 1 ;;
    esac
    shift
done

log() { echo "$@"; }
run_quiet() { "$@"; }

# Must run as root
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root"; exit 1; }

log "[*] Installing system dependencies..."
run_quiet apk add --no-cache --no-interactive python3 python3-dev py3-netifaces gcc musl-dev libffi-dev openssl-dev linux-headers ffmpeg

# Create dedicated non-root service user/group if not present
if ! getent group "$OCTOPRINT_USER" >/dev/null; then
    run_quiet addgroup -S "$OCTOPRINT_USER"
fi
if ! id "$OCTOPRINT_USER" &>/dev/null; then
    log "[*] Creating user '$OCTOPRINT_USER'..."
    run_quiet adduser -S -D -H -G "$OCTOPRINT_USER" -h "$DATA_DIR" -s /sbin/nologin "$OCTOPRINT_USER"
fi
# ponytail: addgroup is idempotent on Alpine (no-op if already a member)
if run_quiet addgroup "$OCTOPRINT_USER" dialout; then
    log "[*] '$OCTOPRINT_USER' is in the 'dialout' group (serial device access)."
else
    echo "[!] WARNING: could not add '$OCTOPRINT_USER' to 'dialout' group."
fi

log "[*] Fetching latest OctoPrint release..."
LATEST=$(wget -qO- https://pypi.org/pypi/OctoPrint/json \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['version'])")
log "[*] Latest version: $LATEST"

# Check current installed version (idempotency guard)
CURRENT=""
[ -f "$VERSION_FILE" ] && CURRENT=$(cat "$VERSION_FILE")

# ponytail: only skip pip; always refresh service/sudoers/config below
NEEDS_INSTALL=1
if [ "$CURRENT" = "$LATEST" ] && [ -x "$VENV_DIR/bin/octoprint" ]; then
    log "[+] OctoPrint $LATEST already installed — skipping pip reinstall."
    NEEDS_INSTALL=0
fi

# Create install dir; preserve DATA_DIR if it already exists (user config/uploads)
mkdir -p "$INSTALL_DIR"
mkdir -p "$DATA_DIR"

if [ "$NEEDS_INSTALL" -eq 1 ]; then
    [ -n "$CURRENT" ] && log "[*] Updating $CURRENT -> $LATEST..." || log "[*] Installing OctoPrint $LATEST..."

    log "[*] Setting up Python virtual environment..."
    run_quiet python3 -m venv --system-site-packages "$VENV_DIR"

    log "[*] Installing OctoPrint into venv (may take several minutes on this device)..."
    run_quiet "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    run_quiet "$VENV_DIR/bin/pip" install --quiet "OctoPrint==$LATEST"

    echo "$LATEST" > "$VERSION_FILE"
fi

# Install Resource Monitor plugin (pinned release zip prepared by the image build)
RM_INSTALLED=$("$VENV_DIR/bin/pip" show OctoPrint-Resource-Monitor 2>/dev/null | awk '/^Version:/{print $2}' || true)
# ponytail: idempotent - skip if exact pinned version already present
if [ "$RM_INSTALLED" = "$RESOURCE_MONITOR_VERSION" ]; then
    log "[+] Resource Monitor $RESOURCE_MONITOR_VERSION already installed — skipping."
elif [ -n "$RESOURCE_MONITOR_ZIP" ] && [ -f "$RESOURCE_MONITOR_ZIP" ]; then
    log "[*] Installing Resource Monitor plugin $RESOURCE_MONITOR_VERSION from $RESOURCE_MONITOR_ZIP..."
    run_quiet "$VENV_DIR/bin/pip" install "$RESOURCE_MONITOR_ZIP" \
        || { echo "ERROR: Failed to install Resource Monitor $RESOURCE_MONITOR_VERSION."; exit 1; }
    log "[+] Resource Monitor $RESOURCE_MONITOR_VERSION installed."
else
    echo "ERROR: Resource Monitor zip not bundled: ${RESOURCE_MONITOR_ZIP:-unset}"
    exit 1
fi

# Install LED Status plugin (pinned release zip prepared by the image build)
LS_INSTALLED=$("$VENV_DIR/bin/pip" show OctoPrint-LedStatus 2>/dev/null | awk '/^Version:/{print $2}' || true)
# ponytail: idempotent - skip if exact pinned version already present
if [ "$LS_INSTALLED" = "$LED_STATUS_VERSION" ]; then
    log "[+] LED Status $LED_STATUS_VERSION already installed — skipping."
elif [ -n "$LED_STATUS_ZIP" ] && [ -f "$LED_STATUS_ZIP" ]; then
    log "[*] Installing LED Status plugin $LED_STATUS_VERSION from $LED_STATUS_ZIP..."
    run_quiet "$VENV_DIR/bin/pip" install "$LED_STATUS_ZIP" \
        || { echo "ERROR: Failed to install LED Status $LED_STATUS_VERSION."; exit 1; }
    log "[+] LED Status $LED_STATUS_VERSION installed."
else
    echo "ERROR: LED Status zip not bundled: ${LED_STATUS_ZIP:-unset}"
    exit 1
fi

log "[*] Installing LED Status helper..."
# ponytail: always overwrite — helper is root-owned; idempotent by content
mkdir -p /usr/local/sbin /etc/sudoers.d
install -o root -g root -m 0755 "$LED_STATUS_HELPER" /usr/local/sbin/led-helper
log "[+] Helper installed: /usr/local/sbin/led-helper (root:root 0755)"

log "[*] Installing LED Status sudoers rule..."
if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$LED_STATUS_SUDOERS" \
        || { echo "ERROR: sudoers syntax invalid: $LED_STATUS_SUDOERS"; exit 1; }
fi
install -o root -g root -m 0440 "$LED_STATUS_SUDOERS" /etc/sudoers.d/octoprint-led
log "[+] Sudoers rule installed: /etc/sudoers.d/octoprint-led (0440)"
if command -v visudo >/dev/null 2>&1; then
    visudo -c >/dev/null || { echo "ERROR: sudoers validation failed post-install"; exit 1; }
fi

if [ ! -f "$DATA_DIR/config.yaml" ]; then
    log "[*] Installing default OctoPrint config..."
    cat > "$DATA_DIR/config.yaml" <<'YAML'
server:
  commands:
    serverRestartCommand: sudo /sbin/rc-service octoprint restart
    systemRestartCommand: sudo /sbin/reboot
    systemShutdownCommand: sudo /sbin/poweroff

appearance:
  components:
    disabled:
      tab:
        - timelapse
      settings:
        - webcam
YAML
fi

chown -R "$OCTOPRINT_USER:$OCTOPRINT_USER" "$INSTALL_DIR" "$DATA_DIR"


log "[*] Allowing OctoPrint UI power controls via sudo..."
cat > /etc/sudoers.d/octoprint <<'SUDOERS'
octoprint ALL=(root) NOPASSWD: /sbin/rc-service octoprint restart, /sbin/reboot, /sbin/poweroff, /sbin/halt
SUDOERS
chmod 0440 /etc/sudoers.d/octoprint
if command -v visudo >/dev/null 2>&1; then
    visudo -c >/dev/null || { echo "ERROR: sudoers validation failed post-install"; exit 1; }
fi

log "[*] Installing OpenRC service..."
cat > /etc/init.d/octoprint <<'EOF'
#!/sbin/openrc-run
# OpenRC service for OctoPrint

name="octoprint"
description="OctoPrint 3D printer web interface"

OCTOPRINT_USER="octoprint"
VENV_DIR="/opt/octoprint/venv"
DATA_DIR="/var/lib/octoprint"

command="$VENV_DIR/bin/octoprint"
command_args="serve --host 0.0.0.0 --port 5000 --basedir $DATA_DIR"
command_user="$OCTOPRINT_USER"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/octoprint/octoprint.log"
error_log="/var/log/octoprint/octoprint.log"

depend() {
    need net
    after localmount
}

start_pre() {
    if [ ! -x "$command" ]; then
        eerror "OctoPrint not found at $command — run install-octoprint.sh first"
        return 1
    fi
    mkdir -p /var/log/octoprint
    chown "$OCTOPRINT_USER" /var/log/octoprint
}
EOF
chmod 755 /etc/init.d/octoprint
run_quiet rc-update add octoprint default

# ponytail: minimal sanity check - binary must be callable
"$VENV_DIR/bin/octoprint" --version >/dev/null \
    || { echo "[!] WARNING: octoprint binary check failed."; exit 1; }
log "[+] Installation verified."

log "[+] Done! OctoPrint $LATEST installed."
log "    Install : $INSTALL_DIR"
log "    Venv    : $VENV_DIR"
log "    Data    : $DATA_DIR"
log "    Binary  : $VENV_DIR/bin/octoprint"
log ""
log "    Service : /etc/init.d/octoprint (enabled in default runlevel)"
log ""
log "[*] Start now with: rc-service octoprint start"
log "    Web UI  : http://<device-ip>:5000"
log "    UI cmds : sudo /sbin/rc-service octoprint restart | sudo /sbin/reboot | sudo /sbin/poweroff"
log "    Webcam  : disabled by default (no stream/snapshot; ffmpeg installed for later RTSP/timelapse)"
