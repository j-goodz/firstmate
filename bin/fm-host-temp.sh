#!/usr/bin/env bash
# fm-host-temp.sh - the single owner of reading the host CPU temperature for the
# optional per-home thermal gate (config/thermal-gate, documented in
# docs/configuration.md).
#
# Usage:
#   fm-host-temp.sh [--help]
#
# Prints the host CPU temperature as an integer Celsius: the x86_pkg_temp zone
# when present and readable, otherwise the hottest readable
# /sys/class/thermal/thermal_zone*/temp. It prints nothing and exits 3 when no
# zone is readable, so a caller can tell "no sensor on this host" apart from
# "0 C". A zone is readable only when its temp is a plain optional-signed
# integer, so a disabled or otherwise non-numeric sensor is skipped.
#
# FM_THERMAL_SYSFS overrides the sysfs thermal class directory (default
# /sys/class/thermal); it exists so tests can drive fixture trees, and is not a
# supported production setting.
set -u

usage() {
  cat <<'EOF'
Usage: fm-host-temp.sh [--help]

Print the host CPU temperature as an integer Celsius: the x86_pkg_temp zone
when present and readable, otherwise the hottest readable
/sys/class/thermal/thermal_zone*/temp. Prints nothing and exits 3 when no
thermal zone is readable.

FM_THERMAL_SYSFS overrides the sysfs thermal class directory (default
/sys/class/thermal); it exists for tests against fixture trees.
EOF
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  '') ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

SYSFS=${FM_THERMAL_SYSFS:-/sys/class/thermal}

preferred=
best_max=
have_max=0
for zone in "$SYSFS"/thermal_zone*; do
  [ -d "$zone" ] || continue
  [ -r "$zone/temp" ] || continue
  raw=$(tr -d '[:space:]' < "$zone/temp" 2>/dev/null) || raw=
  # sysfs reports millidegrees as a plain integer; anything else is not a
  # readable sensor and must not be treated as 0 C.
  [[ $raw =~ ^-?[0-9]+$ ]] || continue
  type=$(tr -d '[:space:]' < "$zone/type" 2>/dev/null) || type=
  if [ "$type" = x86_pkg_temp ] && [ -z "$preferred" ]; then
    preferred=$raw
  fi
  if [ "$have_max" -eq 0 ] || [ "$raw" -gt "$best_max" ]; then
    best_max=$raw
    have_max=1
  fi
done

if [ -n "$preferred" ]; then
  printf '%s\n' "$((preferred / 1000))"
  exit 0
fi
if [ "$have_max" -eq 1 ]; then
  printf '%s\n' "$((best_max / 1000))"
  exit 0
fi
exit 3
