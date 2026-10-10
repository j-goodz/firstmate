#!/usr/bin/env bash
# fm-idle-capacity.sh
# Purpose: Deterministic idle‑capacity poll for a firstmate home.
# Usage:   fm-idle-capacity.sh [check|arm|disarm|--help|-h]
# Env:     FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_IDLE_CAPACITY_NOW,
#          FM_IDLE_CAPACITY_THRESHOLD_SECS, FM_IDLE_CAPACITY_COOLDOWN_SECS,
#          FM_IDLE_CAPACITY_DEFAULT_CAP, FM_IDLE_CAPACITY_HUB_TIMEOUT,
#          FM_IDLE_CAPACITY_READY_TIMEOUT, FM_IDLE_CAPACITY_HUB_PROBE,
#          FM_IDLE_CAPACITY_HUB_HOST, FM_IDLE_CAPACITY_READY_CMD, etc.
# Never surveys or modifies anything except its own small state file.
# The `check` action prints ONE line only when the home should be woken;
# that line becomes a `check:` wake for the watcher.

set -u
export LC_ALL=C

# -------------------------------------------------------------------------
# Paths and constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/.idle-capacity"
CHECK_ID=idle-capacity
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-idle-capacity-v1

# -------------------------------------------------------------------------
# Library sources
# shellcheck source=bin/fm-timeout-lib.sh
source "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
source "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
source "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-thermal-lib.sh
source "$SCRIPT_DIR/fm-thermal-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
source "$SCRIPT_DIR/fm-busy-lib.sh"

# -------------------------------------------------------------------------
# Helper: usage
usage() {
  cat <<'EOF'
fm-idle-capacity.sh – idle‑capacity poll for a firstmate home.

Usage:
  fm-idle-capacity.sh [check]    # default; prints nothing or one line, exit 0
  fm-idle-capacity.sh arm        # write + register state/idle-capacity.check.sh
  fm-idle-capacity.sh disarm     # remove shim, trust file and state file
  fm-idle-capacity.sh --help|-h  # this help, exit 0

Environment (all optional):
  FM_HOME                     Home directory (default: repo root)
  FM_STATE_OVERRIDE           Override state directory
  FM_CONFIG_OVERRIDE          Override config directory
  FM_IDLE_CAPACITY_NOW        Epoch seconds override for “now”
  FM_IDLE_CAPACITY_THRESHOLD_SECS  Seconds condition must hold (default 600)
  FM_IDLE_CAPACITY_COOLDOWN_SECS   Minimum seconds between wakes (default 3600)
  FM_IDLE_CAPACITY_DEFAULT_CAP    Worker cap when thermal gate yields none (default 3)
  FM_IDLE_CAPACITY_HUB_TIMEOUT    Probe timeout, 1‑20 s (default 4)
  FM_IDLE_CAPACITY_READY_TIMEOUT  Ready‑command timeout, 1‑25 s (default 15)
  FM_IDLE_CAPACITY_HUB_PROBE      Command string for custom hub probe
  FM_IDLE_CAPACITY_HUB_HOST       Host for built‑in probe (default “cloud-server”)
  FM_IDLE_CAPACITY_READY_CMD      Command string for ready query
EOF
}

die_usage() {
  printf 'fm-idle-capacity: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# -------------------------------------------------------------------------
# Validate numeric environment variables
validate_whole() {
  local var_name=$1 var_val=$2 min=$3 max=$4
  if ! [[ $var_val =~ ^[0-9]+$ ]]; then
    printf 'fm-idle-capacity: %s must be a whole number\n' "$var_name" >&2
    exit 2
  fi
  if (( var_val < min )); then
    printf 'fm-idle-capacity: %s must be >= %s\n' "$var_name" "$min" >&2
    exit 2
  fi
  if (( max >= 0 && var_val > max )); then
    printf 'fm-idle-capacity: %s must be <= %s\n' "$var_name" "$max" >&2
    exit 2
  fi
}

# defaults
THRESHOLD_SECS=${FM_IDLE_CAPACITY_THRESHOLD_SECS:-600}
COOLDOWN_SECS=${FM_IDLE_CAPACITY_COOLDOWN_SECS:-3600}
DEFAULT_CAP=${FM_IDLE_CAPACITY_DEFAULT_CAP:-3}
HUB_TIMEOUT=${FM_IDLE_CAPACITY_HUB_TIMEOUT:-4}
READY_TIMEOUT=${FM_IDLE_CAPACITY_READY_TIMEOUT:-15}
NOW=${FM_IDLE_CAPACITY_NOW:-$(date +%s)}

validate_whole "FM_IDLE_CAPACITY_THRESHOLD_SECS" "$THRESHOLD_SECS" 0 -1
validate_whole "FM_IDLE_CAPACITY_COOLDOWN_SECS" "$COOLDOWN_SECS" 0 -1
validate_whole "FM_IDLE_CAPACITY_DEFAULT_CAP" "$DEFAULT_CAP" 1 -1
validate_whole "FM_IDLE_CAPACITY_HUB_TIMEOUT" "$HUB_TIMEOUT" 1 20
validate_whole "FM_IDLE_CAPACITY_READY_TIMEOUT" "$READY_TIMEOUT" 1 25
validate_whole "FM_IDLE_CAPACITY_NOW" "$NOW" 0 -1

# -------------------------------------------------------------------------
# Hub reachability test
hub_reachable() {
  if [ -n "${FM_IDLE_CAPACITY_HUB_PROBE-}" ]; then
    fm_run_timed "$HUB_TIMEOUT" bash -c "$FM_IDLE_CAPACITY_HUB_PROBE" >/dev/null 2>&1
    return $?
  fi

  local host=${FM_IDLE_CAPACITY_HUB_HOST:-cloud-server}
  local hn port info
  info=$(ssh -G "$host" 2>/dev/null | awk '
    $1=="hostname"{h=$2}
    $1=="port"{p=$2}
    END{if(h) printf "%s %s", h, p}
  ')
  if [ -n "$info" ]; then
    read -r hn port <<<"$info"
  else
    hn=$host
    port=22
  fi

  # shellcheck disable=SC2016  # deliberate: $1/$2 expand in the child shell
  fm_run_timed "$HUB_TIMEOUT" bash -c '
    exec 3<>/dev/tcp/$1/$2
    IFS= read -r -t 3 -u 3 line
    [[ $line == SSH-* ]]
  ' _ "$hn" "$port"
}

# -------------------------------------------------------------------------
# Ready count parser
ready_count() {
  local cmd=${FM_IDLE_CAPACITY_READY_CMD:-"$SCRIPT_DIR/fm-tasks-axi.sh ready"}
  local out rc
  out=$(fm_run_timed "$READY_TIMEOUT" bash -c "$cmd" 2>/dev/null) || return 1
  rc=$(awk -F',' '
    $0 ~ /^ready\[[0-9]+\]\{/ {found=1; next}
    found && $0 ~ /^  / && $0 !~ /^  -/ {
      kind=$3
      gsub(/^ +| +$/,"",kind)
      if (kind=="ship" || kind=="scout" || kind=="chore") c++
    }
    found && $0 !~ /^  / {exit}
    END {print c+0}
  ' <<<"$out")
  printf '%s' "$rc"
}

# -------------------------------------------------------------------------
# Record handling
record_read() {
  REC_SINCE=
  REC_WOKEN=
  if [ -f "$RECORD" ]; then
    IFS= read -r first < "$RECORD" || return
    if [ "$first" = "$RECORD_SCHEMA" ]; then
      while IFS='=' read -r key val; do
        case $key in
          since) REC_SINCE=$val ;;
          woken) REC_WOKEN=$val ;;
        esac
      done < <(tail -n +2 "$RECORD")
    fi
  fi
}

record_write() {
  local since=$1 woken=$2
  if [ -z "$since" ] && [ -z "$woken" ]; then
    rm -f -- "$RECORD"
    return 0
  fi
  mkdir -p "$STATE" || return 1
  local tmp
  tmp=$(umask 077; mktemp "$RECORD.XXXXXX") || return 1
  {
    printf '%s\n' "$RECORD_SCHEMA"
    if [ -n "$since" ]; then printf 'since=%s\n' "$since"; fi
    if [ -n "$woken" ]; then printf 'woken=%s\n' "$woken"; fi
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; return 1; }
  return 0
}

# -------------------------------------------------------------------------
# Action: check
action_check() {
  # 1. hub probe
  if ! hub_reachable; then
    record_read
    record_write "" "$REC_WOKEN"
    return 0
  fi

  # 2. thermal gate
  local live cap slots
  live=$(fm_thermal_gate_busy_count "$STATE") || live=0
  fm_thermal_gate_limit "$CONFIG/thermal-gate" "$SCRIPT_DIR/fm-host-temp.sh"
  if [ -n "${FM_THERMAL_LIMIT-}" ]; then
    cap=$FM_THERMAL_LIMIT
  else
    cap=$DEFAULT_CAP
  fi
  (( slots = cap - live ))
  (( slots < 0 )) && slots=0

  # 3. ready count
  local ready
  if ! ready=$(ready_count); then
    return 0
  fi

  # 4. state handling
  record_read
  local now=$NOW

  if (( slots > 0 && ready > 0 )); then
    # condition holds
    if [ -z "$REC_SINCE" ]; then
      REC_SINCE=$now
      record_write "$REC_SINCE" "$REC_WOKEN"
    fi
    local since=$REC_SINCE woken=$REC_WOKEN
    if (( now - since >= THRESHOLD_SECS )) && \
       { [ -z "$woken" ] || (( now - woken >= COOLDOWN_SECS )); }; then
      printf 'idle capacity: %s slots, %s ready\n' "$slots" "$ready"
      record_write "$since" "$now"
    fi
  else
    # condition not met – clear since
    record_write "" "$REC_WOKEN"
  fi
  return 0
}

# -------------------------------------------------------------------------
# Shim handling (arm / disarm)
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-idle-capacity.sh - idle capacity poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-idle-capacity.sh") check"
}

SHIM_WRITE_TMP=
ARM_BACKUP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1

  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] && \
     [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi

  tmp=$(umask 077; mktemp "$STATE/.fm-idle-capacity.XXXXXX") || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" ||
     ! chmod 0700 "$tmp" ||
     ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi

  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" ||
     ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-idle-capacity.XXXXXX") || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null ||
     ! chmod 0700 "$tmp" ||
     ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329
arm_interrupted() {
  arm_rollback
  printf 'fm-idle-capacity: arming was interrupted, so %s is not armed\n' "$CHECK_SHIM" >&2
  exit 1
}

action_arm() {
  local idle_bin="$SCRIPT_DIR/fm-idle-capacity.sh"
  if [ ! -x "$idle_bin" ]; then
    printf 'fm-idle-capacity: the script %s is not executable, cannot arm\n' "$idle_bin" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1

  local home want
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-idle-capacity: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac

  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-idle-capacity: could not save existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi

  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-idle-capacity: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi

  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-idle-capacity: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM

  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

# -------------------------------------------------------------------------
# Dispatcher
case "${1:-check}" in
  check)   action_check ;;
  arm)     action_arm ;;
  disarm)  action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
