#!/bin/sh
# print-health: compact health snapshot for long-print diagnosis.
# ponytail: every section is best-effort; missing hardware/services never cause failure.
echo "=== print-health $(date -Iseconds) ==="

printf '\n--- uptime/load ---\n'
uptime 2>/dev/null || echo "unavailable"

printf '\n--- memory ---\n'
free -m 2>/dev/null || cat /proc/meminfo 2>/dev/null || echo "unavailable"

printf '\n--- disk ---\n'
df -h / /var/log 2>/dev/null || echo "unavailable"

printf '\n--- thermal ---\n'
_any=0
for _f in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$_f" ] || continue
    _any=1
    _zone=$(dirname "$_f" | xargs basename)
    _type=$(cat "$(dirname "$_f")/type" 2>/dev/null || echo "unknown")
    _mc=$(cat "$_f" 2>/dev/null) && \
        printf '%s (%s): %d°C\n' "$_zone" "$_type" "$((_mc / 1000))" || true
done
[ "$_any" -eq 0 ] && echo "unavailable"

printf '\n--- kernel-errors ---\n'
_out=$(dmesg -T --level=err,crit,alert,emerg 2>/dev/null | tail -20)
[ -z "$_out" ] && _out=$(dmesg 2>/dev/null | grep -iE 'error|oops|panic|crit' | tail -20)
[ -n "$_out" ] && printf '%s\n' "$_out" || echo "unavailable"

printf '\n--- networking ---\n'
ip -brief addr 2>/dev/null || echo "unavailable"
_rt=$(ip route show default 2>/dev/null) \
    && printf '%s\n' "${_rt:-no default route}" \
    || echo "no default route"

printf '\n--- usb-serial ---\n'
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "none"

printf '\n--- octoprint-service ---\n'
rc-service octoprint status 2>/dev/null || echo "unavailable"
