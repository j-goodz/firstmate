#!/usr/bin/env bash
# fm-suite-slot.sh - machine-wide gate for whole-suite test runs.
#
# At most N whole-suite runs execute at once on one machine, where N is sized
# from the machine's logical CPU count and CPU temperature, and a new run is
# admitted only while the machine has memory to spare. Every home and worktree
# on the machine shares the same slots, so suites queue instead of stacking.
# The standard that makes this the rule is docs/test-capacity-standard.md, and
# docs/configuration.md "Suite slots" owns the machine file.
#
# Usage:
#   fm-suite-slot.sh capacity
#   fm-suite-slot.sh status [--json]
#   fm-suite-slot.sh run [--key NAME] [--wait-secs N] [--poll-secs N] -- CMD [ARGS...]
#   fm-suite-slot.sh --help | -h
#
# No subcommand or an unknown one exits 2 with usage on stderr, as does `run`
# without `--` and a command, or a non-numeric --wait-secs. --wait-secs is whole
# seconds (default 10800, 0 means never wait). --poll-secs may be decimal
# (default 2). --key labels the holder (default "default").
#
# Environment:
#   FM_SUITE_STATE_DIR        lock files, holder info and the event log
#                             (default ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/suite)
#   FM_SUITE_CONFIG           machine file (default ${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/suite-slots)
#                             key=value lines, "#" comments, last valid value wins.
#                             Keys: slots, hot_c, hold_c, min_available_mb. A value that
#                             is not a non-negative integer is ignored.
#   FM_SUITE_SLOTS            non-negative integer overriding the base slot count
#   FM_SUITE_NPROC            positive integer overriding the detected logical CPUs
#   FM_SUITE_MIN_AVAILABLE_MB available-memory floor in MB (default 600, the floor
#                             nexus's gate admission uses); the config key
#                             min_available_mb is the file form
#   FM_SUITE_MEMINFO          meminfo file to read (default /proc/meminfo), a test seam
#   FM_THERMAL_SYSFS          passed through to the sibling fm-host-temp.sh
#   FM_HOME                   when set, hot_c and hold_c fall back to
#                             $FM_HOME/config/thermal-gate
#   FM_TASK_ID                recorded in holder info and log events
#   FM_SUITE_SLOT_HELD        "1" makes `run` exec the command directly with no
#                             slot and no log, so a suite already inside a slot can
#                             start nested suites. `run` exports it as 1 to the
#                             command, with FM_SUITE_SLOT_INDEX=<slot number>.
#
# Capacity:
#   Base B is FM_SUITE_SLOTS, else the config "slots", else floor(CPUs / 6), so
#   12 CPUs give 2, 8 give 1, 4 give 0 and 24 give 4. Temperature T comes from
#   fm-host-temp.sh (unknown when unreadable). The tier is "hold" when T is at or
#   above hold_c, "hot" when at or above hot_c, "cool" when T is known and under
#   both, else "unknown". Capacity C is 0 at hold, min(B, 1) at hot, else B.
#   Memory pressure (available memory known and under the floor) leaves C alone
#   and only stops NEW slots from being granted while it lasts.
#
# capacity prints C. status prints, on its first line,
#   capacity=<C> base=<B> temp=<T|unknown> tier=<tier> held=<H> free=<F> avail_mb=<MB|unknown>
# then one "slot=<i> free" or "slot=<i> held pid= key= task= since= cmd=" line per
# base slot; a held slot is one whose lock some live process holds, so a stale
# info file never counts. status --json prints the same facts as one JSON object.
#
# run takes a slot and runs CMD while holding it, passing stdin, stdout and
# stderr through and exiting with CMD's status. It exits 75 at once when B is 0,
# and after --wait-secs when no slot was granted (heat, a full house or memory
# pressure all wait the same way). The lock descriptor is closed in CMD, so a
# leaked background process cannot keep the slot held; killing `run` with
# SIGKILL frees the slot. SIGTERM and SIGINT are forwarded to CMD.
#
# flock is required to hold a slot. On a host where it is missing (stock macOS,
# which this repo supports) there is no machine-wide gate: `run` prints a
# one-line warning and executes CMD ungated with CMD's own status, and `status`
# never reports a slot held. capacity and status still print.
#
# Event log: one JSON object per line appended to events.jsonl in the state
# directory (best effort, rotated to events.jsonl.1 past 5 MiB). Events are
# wait, acquire, release, refuse and timeout, with ts, key, task, slot,
# capacity, waited_ms, duration_ms, exit, cmd and host.
set -u

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${FM_SUITE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/suite}"
CONFIG_FILE="${FM_SUITE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/suite-slots}"

say() { printf 'fm-suite-slot: %s\n' "$*" >&2; }
bad_usage() {
  say "$*"
  usage >&2
  exit 2
}

is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# cfg_get <file> <key>: the last valid non-negative integer for key, else nothing.
cfg_get() {
  local file=$1 key=$2 line k v out=''
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    k="${k//[[:space:]]/}"
    v="${v//[[:space:]]/}"
    if [ "$k" = "$key" ] && is_uint "$v"; then out=$v; fi
  done < "$file"
  [ -z "$out" ] || printf '%s' "$out"
}

cpu_count() {
  local n
  if is_uint "${FM_SUITE_NPROC:-}" && [ "$FM_SUITE_NPROC" -ge 1 ]; then
    printf '%s' "$FM_SUITE_NPROC"
    return
  fi
  n=$(nproc 2> /dev/null || getconf _NPROCESSORS_ONLN 2> /dev/null || echo 1)
  is_uint "$n" || n=1
  printf '%s' "$n"
}

# compute: sets BASE TEMP TIER CAP AVAIL FLOOR PRESSURE from the machine now.
compute() {
  local v n t home_gate
  BASE=''
  v="${FM_SUITE_SLOTS:-}"
  if is_uint "$v"; then
    BASE=$v
  else
    v=$(cfg_get "$CONFIG_FILE" slots)
    if [ -n "$v" ]; then
      BASE=$v
    else
      n=$(cpu_count)
      BASE=$((n / 6))
    fi
  fi

  home_gate=''
  [ -z "${FM_HOME:-}" ] || home_gate="$FM_HOME/config/thermal-gate"
  HOT_C=$(cfg_get "$CONFIG_FILE" hot_c)
  [ -n "$HOT_C" ] || [ -z "$home_gate" ] || HOT_C=$(cfg_get "$home_gate" hot_c)
  HOLD_C=$(cfg_get "$CONFIG_FILE" hold_c)
  [ -n "$HOLD_C" ] || [ -z "$home_gate" ] || HOLD_C=$(cfg_get "$home_gate" hold_c)

  TEMP=''
  if t=$("$SCRIPT_DIR/fm-host-temp.sh" 2> /dev/null) && is_uint "$t"; then TEMP=$t; fi
  if [ -z "$TEMP" ]; then
    TIER=unknown
  elif [ -n "$HOLD_C" ] && [ "$TEMP" -ge "$HOLD_C" ]; then
    TIER=hold
  elif [ -n "$HOT_C" ] && [ "$TEMP" -ge "$HOT_C" ]; then
    TIER=hot
  else
    TIER=cool
  fi
  case "$TIER" in
    hold) CAP=0 ;;
    hot) CAP=$((BASE < 1 ? BASE : 1)) ;;
    *) CAP=$BASE ;;
  esac

  FLOOR="${FM_SUITE_MIN_AVAILABLE_MB:-}"
  is_uint "$FLOOR" || FLOOR=$(cfg_get "$CONFIG_FILE" min_available_mb)
  [ -n "$FLOOR" ] || FLOOR=600
  AVAIL=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' "${FM_SUITE_MEMINFO:-/proc/meminfo}" 2> /dev/null)
  is_uint "$AVAIL" || AVAIL=''
  PRESSURE=0
  if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$FLOOR" ]; then PRESSURE=1; fi
}

have_flock() { command -v flock > /dev/null 2>&1; }

# slot_held <i>: success when a live process holds the slot lock.
slot_held() {
  local f="$STATE_DIR/slot.$1.lock" fd
  [ -e "$f" ] || return 1
  have_flock || return 1
  exec {fd}< "$f" || return 1
  if flock -n "$fd"; then
    exec {fd}<&-
    return 1
  fi
  exec {fd}<&-
  return 0
}

info_get() {  # <i> <name>
  local f="$STATE_DIR/slot.$1.info"
  [ -f "$f" ] || return 0
  sed -n "s/^$2=//p" "$f" | tail -n1
}

log_event() {  # <event> <key> <slot> <waited_ms> <duration_ms> <exit> <cmd>
  local file="$STATE_DIR/events.jsonl" size
  {
    mkdir -p "$STATE_DIR"
    size=$(stat -c %s "$file" 2> /dev/null || echo 0)
    if [ "$size" -gt 5242880 ]; then mv -f "$file" "$file.1"; fi
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$1" --arg key "$2" \
      --arg task "${FM_TASK_ID:-}" --arg slot "$3" --argjson capacity "${CAP:-0}" \
      --argjson waited "${4:-0}" --argjson duration "${5:-0}" --arg exit "$6" \
      --arg cmd "${7:0:200}" --arg host "$(hostname -s)" \
      '{ts: $ts, event: $event, key: $key, task: $task,
        slot: (if $slot == "" then null else ($slot | tonumber) end),
        capacity: $capacity, waited_ms: $waited, duration_ms: $duration,
        exit: (if $exit == "" then null else ($exit | tonumber) end), cmd: $cmd, host: $host}' >> "$file"
  } 2> /dev/null || true
}

now_ms() {
  local t="${EPOCHREALTIME/[.,]/}"
  printf '%s' $((t / 1000))
}

cmd_status() {
  local json=0 i held=0 pid key task since cmd lines='' slots_json='[]'
  case "${1:-}" in
    '') ;;
    --json) json=1 ;;
    *) bad_usage "unknown status option: $1" ;;
  esac
  compute
  for ((i = 0; i < BASE; i++)); do
    if slot_held "$i"; then
      held=$((held + 1))
      pid=$(info_get "$i" pid)
      key=$(info_get "$i" key)
      task=$(info_get "$i" task)
      since=$(info_get "$i" since)
      cmd=$(info_get "$i" cmd)
      cmd="${cmd//$'\n'/ }"
      lines+="slot=$i held pid=${pid:--} key=${key:--} task=${task:--} since=${since:--} cmd=${cmd:0:120}"$'\n'
      slots_json=$(jq -c --argjson i "$i" --arg pid "$pid" --arg key "$key" --arg task "$task" --arg since "$since" --arg cmd "${cmd:0:120}" \
        '. + [{slot: $i, held: true, pid: (if $pid == "" then null else ($pid | tonumber? // null) end), key: $key, task: $task,
               since: (if $since == "" then null else ($since | tonumber? // null) end), cmd: $cmd}]' <<< "$slots_json")
    else
      lines+="slot=$i free"$'\n'
      slots_json=$(jq -c --argjson i "$i" '. + [{slot: $i, held: false}]' <<< "$slots_json")
    fi
  done
  local free=$((CAP - held))
  [ "$free" -ge 0 ] || free=0
  if [ "$json" -eq 1 ]; then
    jq -n --argjson capacity "$CAP" --argjson base "$BASE" --arg temp "$TEMP" --arg tier "$TIER" \
      --argjson held "$held" --argjson free "$free" --arg avail "$AVAIL" --argjson slots "$slots_json" \
      '{capacity: $capacity, base: $base, temp: (if $temp == "" then null else ($temp | tonumber) end), tier: $tier,
        held: $held, free: $free, avail_mb: (if $avail == "" then null else ($avail | tonumber) end), slots: $slots}'
  else
    printf 'capacity=%s base=%s temp=%s tier=%s held=%s free=%s avail_mb=%s\n' \
      "$CAP" "$BASE" "${TEMP:-unknown}" "$TIER" "$held" "$free" "${AVAIL:-unknown}"
    printf '%s' "$lines"
  fi
}

cmd_run() {
  local key=default wait_secs=10800 poll_secs=2 i got lockfd='' savedin child rc
  local t0 waited_ms start_ms last_note=0 noted=0 why elapsed info
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key) [ "$#" -ge 2 ] || bad_usage "--key needs a value"; key=$2; shift 2 ;;
      --wait-secs) [ "$#" -ge 2 ] || bad_usage "--wait-secs needs a value"; wait_secs=$2; shift 2 ;;
      --poll-secs) [ "$#" -ge 2 ] || bad_usage "--poll-secs needs a value"; poll_secs=$2; shift 2 ;;
      --) shift; break ;;
      *) bad_usage "unknown run option: $1" ;;
    esac
  done
  [ "$#" -gt 0 ] || bad_usage "run needs -- and a command"
  is_uint "$wait_secs" || bad_usage "--wait-secs must be whole seconds"
  case "$poll_secs" in '' | *[!0-9.]*) bad_usage "--poll-secs must be a number" ;; esac

  if [ "${FM_SUITE_SLOT_HELD:-}" = 1 ]; then exec "$@"; fi
  if ! have_flock; then
    say "no slot gate on this host (flock not found); running ungated"
    exec "$@"
  fi

  mkdir -p "$STATE_DIR" || { say "cannot create $STATE_DIR"; exit 75; }
  compute
  if [ "$BASE" -eq 0 ]; then
    say "no full-suite slot on this machine (base capacity 0); place the work on another machine with bin/fm-place.sh"
    log_event refuse "$key" "" 0 0 "" "$*"
    exit 75
  fi

  t0=$SECONDS
  start_ms=$(now_ms)
  got=''
  while :; do
    compute
    if [ "$PRESSURE" -eq 0 ]; then
      for ((i = 0; i < CAP; i++)); do
        exec {lockfd}>> "$STATE_DIR/slot.$i.lock" || continue
        if flock -n "$lockfd"; then got=$i; break; fi
        exec {lockfd}>&-
        lockfd=''
      done
    fi
    [ -z "$got" ] || break
    elapsed=$((SECONDS - t0))
    why="key=$key, capacity=$CAP, tier=$TIER"
    [ "$PRESSURE" -eq 0 ] || why="$why, memory pressure: ${AVAIL}MB available < ${FLOOR}MB"
    if [ "$elapsed" -ge "$wait_secs" ]; then
      say "timed out waiting for a suite slot ($why)"
      log_event timeout "$key" "" "$(($(now_ms) - start_ms))" 0 "" "$*"
      exit 75
    fi
    if [ "$noted" -eq 0 ]; then
      say "waiting for a suite slot ($why)"
      log_event wait "$key" "" 0 0 "" "$*"
      noted=1
      last_note=$elapsed
    elif [ $((elapsed - last_note)) -ge 60 ]; then
      say "still waiting for a suite slot ($why)"
      last_note=$elapsed
    fi
    sleep "$poll_secs"
  done

  waited_ms=$(($(now_ms) - start_ms))
  info="$STATE_DIR/slot.$got.info"
  {
    printf 'pid=%s\nkey=%s\ntask=%s\nsince=%s\ncmd=%s\n' "$$" "$key" "${FM_TASK_ID:-}" "$(date +%s)" "${*//$'\n'/ }" > "$info.$$" \
      && mv -f "$info.$$" "$info"
  } 2> /dev/null || true
  log_event acquire "$key" "$got" "$waited_ms" 0 "" "$*"

  exec {savedin}<&0
  FM_SUITE_SLOT_HELD=1 FM_SUITE_SLOT_INDEX=$got "$@" 0<&"$savedin" {lockfd}>&- {savedin}<&- &
  child=$!
  exec {savedin}<&-
  trap 'kill -TERM "$child" 2> /dev/null' TERM
  trap 'kill -INT "$child" 2> /dev/null' INT
  wait "$child"
  rc=$?
  while kill -0 "$child" 2> /dev/null; do
    wait "$child"
    rc=$?
  done
  trap - TERM INT
  rm -f "$info"
  log_event release "$key" "$got" "$waited_ms" "$(($(now_ms) - start_ms - waited_ms))" "$rc" "$*"
  exit "$rc"
}

case "${1:-}" in
  --help | -h) usage; exit 0 ;;
  capacity) compute; printf '%s\n' "$CAP" ;;
  status) shift; cmd_status "$@" ;;
  run) shift; cmd_run "$@" ;;
  '') bad_usage "missing subcommand" ;;
  *) bad_usage "unknown subcommand: $1" ;;
esac
