#!/usr/bin/env bash
# fm-suite-daily.sh - one full test run per repo per day, at a quiet hour.
#
# Lanes run only the tests their change affects, so a whole suite runs once a
# day per repo instead, in the quiet hours (03:00-05:00 ET), on one machine
# chosen by the placement rule, never stacked with lane work. Each run lands in
# a JSONL log and a failure is posted once to #issues. It is timer driven and
# makes one attempt per repo per day. docs/test-capacity-standard.md owns the
# standard and docs/configuration.md "Daily suite run" owns the config file.
#
# Usage:
#   fm-suite-daily.sh run KEY
#   fm-suite-daily.sh dispatch [--repo KEY]... [--dry-run]
#   fm-suite-daily.sh status [--json]
#   fm-suite-daily.sh install [--print] [--time HH:MM]
#   fm-suite-daily.sh --help | -h
#
# No subcommand, an unknown one, `run` without a KEY and an unknown option exit
# 2 with the reason on stderr.
#
# Config (FM_SUITE_DAILY_CONFIG, default ${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/suite-daily):
#   One repo per line: KEY|PATH|FORMAT|COMMAND. Blank lines and "#" lines are
#   ignored, a line with fewer than four fields is ignored, the first line for a
#   KEY wins. PATH is a git clone on this machine. FORMAT is pytest, fm-test or
#   none and says how failing test ids are read from the output. COMMAND runs
#   with `bash -c` in a detached checkout of the tested commit, with
#   FM_DAILY_SRC set to PATH so a command can borrow the clone's environment.
#
# run KEY (this machine only):
#   Exit 10 when KEY is not configured here (nothing logged). Otherwise the run
#   is SKIPPED (exit 11) with a reason when the machine cannot take it now:
#   heat-hold, heat-hot, memory-pressure (below FM_SUITE_MIN_AVAILABLE_MB,
#   default 600), load-busy (load per CPU at or above
#   FM_SUITE_DAILY_MAX_LOAD_PER_CORE, default 0.5, halved on a machine with no
#   suite slots, which runs the daily suite only when nearly idle), no-ref,
#   no-checkout, or no-slot (the machine's suite slot stayed taken for
#   FM_SUITE_DAILY_SLOT_WAIT_SECS, default 900). Otherwise the tested commit
#   (FM_SUITE_DAILY_REF, default origin/main, after a fetch unless
#   FM_SUITE_DAILY_FETCH=0) is checked out detached under the state directory,
#   the command runs there niced, bounded by FM_SUITE_DAILY_TIMEOUT_SECS
#   (default 7200) and, when the machine has suite slots, inside one slot. The
#   checkout is always removed. Exit 0 for a pass or a fail.
#   Every run appends one "daily-run" JSON line to FM_SUITE_DAILY_LOG (default
#   $HOME/.nexus/suite-daily.jsonl) with ts, host, key, sha, status
#   (pass|fail|skipped), reason, rc, failures, failed_ids (first 20) and
#   duration_s, and prints "RESULT <that json>" as the last line of stdout.
#
# dispatch (the machine that owns the timer):
#   Asks the placement command (FM_SUITE_DAILY_PLACE, default fm-place.sh
#   --class heavy --json) for the ranked machines and tries, for each repo,
#   machines with verdict ok, then busy, then light-only machines (reason
#   no-suite-slots, which decide on the machine whether they are idle enough).
#   A machine whose mate is "self" runs `run` directly, any other through
#   FM_SUITE_DAILY_SSH (default ssh). Exit 0 from `run` ends the search, 10, 11
#   or any other status tries the next machine. With no usable placement the
#   only candidate is this machine. One "dispatch" JSON line per repo is
#   appended to the log (machine, status, reason, sha, failures, tried,
#   alerted). A failure calls FM_SUITE_DAILY_ALERT (default the nexus
#   post-issue-alert.py when present) as `ALERT --tag "[suite-daily]" --sig
#   SIG MESSAGE`; SIG carries the repo, the commit and a hash of the failing
#   ids, so the same failure is not posted twice. --dry-run prints
#   "PLAN <KEY> -> <machines>" and runs nothing. Dispatch exits 0 even when a
#   suite failed, so the timer does not look failed because a suite did.
#
# status: the last result line per key from the log, newest first, as
#   "key=.. status=.. sha=.. ts=.. host=.. failures=.." or a JSON array.
#
# install: writes fm-suite-daily.service and fm-suite-daily.timer into
#   FM_SUITE_UNIT_DIR (default ~/.config/systemd/user), the timer firing at
#   03:30 America/Toronto (--time HH:MM changes it) with Persistent=false, then
#   daemon-reloads and enables it through FM_SUITE_SYSTEMCTL (default
#   systemctl) unless FM_SUITE_INSTALL_NO_ENABLE=1. --print writes nothing and
#   prints both units. Install from the live home, never a disposable worktree,
#   because ExecStart names this script's path.
#
# Other environment: FM_SUITE_STATE_DIR (scratch under daily/<KEY>/),
#   FM_SUITE_DAILY_LOADAVG (default /proc/loadavg), FM_SUITE_NPROC,
#   FM_SUITE_DAILY_MAX_LOAD_PER_CORE, plus everything fm-suite-slot.sh reads.
set -u

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${FM_SUITE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/suite}"
CONFIG_FILE="${FM_SUITE_DAILY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/suite-daily}"
LOG_FILE="${FM_SUITE_DAILY_LOG:-$HOME/.nexus/suite-daily.jsonl}"
SLOT="$SCRIPT_DIR/fm-suite-slot.sh"

say() { printf 'fm-suite-daily: %s\n' "$*" >&2; }
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

is_key() {
  case "${1:-}" in
    [A-Za-z0-9]*) case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac; return 0 ;;
  esac
  return 1
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_line() {  # <json>
  { mkdir -p "$(dirname "$LOG_FILE")" && printf '%s\n' "$1" >> "$LOG_FILE"; } 2> /dev/null || true
}

# config_entry <key>: the first valid config line for key.
config_entry() {
  local line k
  [ -f "$CONFIG_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'* | ' '*'#'*) continue ;; esac
    [ "$(printf '%s' "$line" | tr -cd '|' | wc -c)" -ge 3 ] || continue
    k="${line%%|*}"
    is_key "$k" || continue
    if [ "$k" = "$1" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$CONFIG_FILE"
  return 1
}

config_keys() {
  local line seen=' ' k
  [ -f "$CONFIG_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    [ "$(printf '%s' "$line" | tr -cd '|' | wc -c)" -ge 3 ] || continue
    k="${line%%|*}"
    is_key "$k" || continue
    case "$seen" in *" $k "*) continue ;; esac
    seen="$seen$k "
    printf '%s\n' "$k"
  done < "$CONFIG_FILE"
}

# extract_ids <format> <file>: failing test ids, sorted and unique.
extract_ids() {
  case "$1" in
    pytest)
      awk '/^(FAILED|ERROR) / {
             s = $0; sub(/^[A-Z]+ /, "", s); out = s; depth = 0
             for (i = 1; i <= length(s); i++) {
               c = substr(s, i, 1)
               if (c == "[") depth++
               else if (c == "]" && depth > 0) depth--
               else if (depth == 0 && substr(s, i, 3) == " - ") { out = substr(s, 1, i - 1); break }
             }
             sub(/[ \t]+$/, "", out); print out
           }' "$2" | LC_ALL=C sort -u
      ;;
    fm-test)
      awk '$1 == "FM_TEST_END" { for (i = 1; i <= NF; i++) if ($i ~ /^exit=/ && substr($i, 6) != "0") print $3 }' "$2" | LC_ALL=C sort -u
      ;;
    *) : ;;
  esac
}

# result_json <key> <sha> <status> <reason> <rc> <duration_s> [ids-file]
result_json() {
  local ids='[]'
  [ -z "${7:-}" ] || ids=$(jq -R . < "$7" | jq -sc '.')
  jq -cn --arg ts "$(now_iso)" --arg host "$(hostname -s)" --arg key "$1" --arg sha "$2" --arg status "$3" \
    --arg reason "$4" --arg rc "$5" --argjson dur "$6" --argjson ids "$ids" \
    '{ts: $ts, event: "daily-run", host: $host, key: $key, sha: $sha, status: $status, reason: $reason,
      rc: (if $rc == "" then null else ($rc | tonumber) end), failures: ($ids | length),
      failed_ids: $ids[0:20], duration_s: $dur}'
}

cmd_run() {
  local key=${1:-} entry src format command sha status_line base tier avail cores load1 lpc limit floor
  local daily rundir wt logfile idsfile rcfile secs slot_wait t0 rc outer reason json run_inner
  [ -n "$key" ] || bad_usage "run needs a KEY"
  is_key "$key" || bad_usage "invalid repo key: $key"
  entry=$(config_entry "$key") || { say "$key is not configured on this machine ($CONFIG_FILE)"; exit 10; }
  IFS='|' read -r _ src format command <<< "$entry"
  git -C "$src" rev-parse --is-inside-work-tree > /dev/null 2>&1 || { say "$key: $src is not a git work tree"; exit 10; }
  t0=$SECONDS

  skip() {  # <reason> [sha]
    json=$(result_json "$key" "${2:-}" skipped "$1" "" "$((SECONDS - t0))")
    log_line "$json"
    printf 'RESULT %s\n' "$json"
    exit 11
  }

  status_line=$("$SLOT" status 2> /dev/null | head -n1)
  field() { printf '%s\n' "$status_line" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
  base=$(field base)
  tier=$(field tier)
  avail=$(field avail_mb)
  is_uint "$base" || base=0
  if is_uint "${FM_SUITE_NPROC:-}" && [ "$FM_SUITE_NPROC" -ge 1 ]; then cores=$FM_SUITE_NPROC; else cores=$(nproc 2> /dev/null || echo 1); fi
  load1=$(cut -d' ' -f1 "${FM_SUITE_DAILY_LOADAVG:-/proc/loadavg}" 2> /dev/null)
  lpc=$(awk -v l="${load1:-0}" -v c="$cores" 'BEGIN { if (c > 0) printf "%.4f", l / c; else print 0 }')
  limit="${FM_SUITE_DAILY_MAX_LOAD_PER_CORE:-0.5}"
  [ "$base" -gt 0 ] || limit=$(awk -v m="$limit" 'BEGIN { print m / 2 }')
  floor="${FM_SUITE_MIN_AVAILABLE_MB:-600}"
  case "$tier" in
    hold) skip heat-hold ;;
    hot) skip heat-hot ;;
  esac
  if is_uint "$avail" && [ "$avail" -lt "$floor" ]; then skip memory-pressure; fi
  if awk -v a="$lpc" -v b="$limit" 'BEGIN { exit !(a + 0 >= b + 0) }'; then skip load-busy; fi

  [ "${FM_SUITE_DAILY_FETCH:-1}" = 0 ] || git -C "$src" fetch --quiet origin 2> /dev/null || say "warning: fetch failed in $src, testing what is already there"
  sha=$(git -C "$src" rev-parse --verify --quiet "${FM_SUITE_DAILY_REF:-origin/main}^{commit}") || skip no-ref

  daily="$STATE_DIR/daily/$key"
  mkdir -p "$daily"
  rundir=$(mktemp -d "$daily/wt.XXXXXX") || skip no-checkout "$sha"
  wt="$rundir/wt"
  logfile="$rundir/run.log"
  idsfile="$rundir/ids"
  rcfile="$rundir/rc"
  # shellcheck disable=SC2329 # Registered by the EXIT trap below.
  drop_run() {
    git -C "$src" worktree remove --force "$wt" > /dev/null 2>&1
    rm -rf "$rundir"
    git -C "$src" worktree prune > /dev/null 2>&1
  }
  trap 'drop_run' EXIT
  trap 'exit 143' INT TERM
  git -C "$src" worktree add --detach --quiet "$wt" "$sha" > /dev/null 2>&1 || skip no-checkout "$sha"

  secs="${FM_SUITE_DAILY_TIMEOUT_SECS:-7200}"
  slot_wait="${FM_SUITE_DAILY_SLOT_WAIT_SECS:-900}"
  rm -f "$rcfile"
  # shellcheck disable=SC2016  # the runner is a bash -c program, expanded there
  run_inner='cd "$1" || exit 126; export FM_DAILY_SRC="$2" FM_SUITE_SLOT_HELD=1; nice -n 19 timeout -k 5 "$4" bash -c "$5"; echo $? > "$3"'
  if [ "$base" -gt 0 ]; then
    "$SLOT" run --key "daily-$key" --wait-secs "$slot_wait" --poll-secs 5 -- \
      bash -c "$run_inner" _ "$wt" "$src" "$rcfile" "$secs" "$command" 2>&1 | tee "$logfile" >&2
  else
    bash -c "$run_inner" _ "$wt" "$src" "$rcfile" "$secs" "$command" 2>&1 | tee "$logfile" >&2
  fi
  outer=${PIPESTATUS[0]}
  if [ ! -f "$rcfile" ]; then
    [ "$outer" -ne 75 ] || skip no-slot "$sha"
    rc=$outer
    reason=runner-error
  else
    rc=$(cat "$rcfile")
    reason=suite-failed
    [ "$rc" -ne 124 ] || reason=timeout
  fi

  extract_ids "$format" "$logfile" > "$idsfile"
  cat "$logfile" > "$daily/.last-run.log.$$" 2> /dev/null && mv -f "$daily/.last-run.log.$$" "$daily/last-run.log" 2> /dev/null
  if [ "$rc" -eq 0 ]; then
    json=$(result_json "$key" "$sha" pass "" "$rc" "$((SECONDS - t0))" "$idsfile")
  else
    json=$(result_json "$key" "$sha" fail "$reason" "$rc" "$((SECONDS - t0))" "$idsfile")
  fi
  log_line "$json"
  printf 'RESULT %s\n' "$json"
  exit 0
}

# alert_for <key> <machine> <result json>: posts once per commit and failing set.
alert_for() {
  local key=$1 machine=$2 result=$3 alert sha ids n sig msg first more
  alert="${FM_SUITE_DAILY_ALERT-}"
  if [ -z "${FM_SUITE_DAILY_ALERT+x}" ] && [ -f "$HOME/nexus/scripts/post-issue-alert.py" ]; then
    alert="python3 $HOME/nexus/scripts/post-issue-alert.py"
  fi
  [ -n "$alert" ] || return 1
  sha=$(jq -r '.sha' <<< "$result")
  ids=$(jq -r '(.failed_ids // []) | sort | .[]' <<< "$result")
  n=$(jq -r '.failures // 0' <<< "$result")
  sig="suite-daily:$key:$sha:$(printf '%s\n' "$ids" | md5sum | cut -c1-12)"
  first=$(printf '%s\n' "$ids" | head -n3 | paste -sd, - | sed 's/,/, /g')
  more=''
  [ "$n" -le 3 ] || more=", +$((n - 3)) more"
  msg="Daily full test run failed for $key at ${sha:0:7} on $machine: $n failing ($first$more). Results: $machine:~/.nexus/suite-daily.jsonl"
  local -a alert_argv
  read -ra alert_argv <<< "$alert"
  "${alert_argv[@]}" --tag "[suite-daily]" --sig "$sig" "$msg" > /dev/null 2>&1
}

cmd_dispatch() {
  local -a repos=()
  local dry=0 place_cmd place_json candidates ssh_cmd repo machine mate root out rc result tried status reason sha failures alerted line remote_cmd
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || bad_usage "--repo needs a KEY"; is_key "$2" || bad_usage "invalid repo key: $2"; repos+=("$2"); shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) bad_usage "unknown dispatch option: $1" ;;
    esac
  done
  if [ "${#repos[@]}" -eq 0 ]; then
    mapfile -t repos < <(config_keys)
  fi
  [ "${#repos[@]}" -gt 0 ] || bad_usage "no repos: pass --repo KEY or fill $CONFIG_FILE"

  place_cmd="${FM_SUITE_DAILY_PLACE:-$SCRIPT_DIR/fm-place.sh}"
  ssh_cmd="${FM_SUITE_DAILY_SSH:-ssh}"
  place_json=$("$place_cmd" --class heavy --json 2> /dev/null)
  if printf '%s\n' "$place_json" | jq -e '.machines | type == "array"' > /dev/null 2>&1; then
    candidates=$(printf '%s\n' "$place_json" | jq -r '
      ([.machines[] | select(.verdict == "ok")] + [.machines[] | select(.verdict == "busy")]
       + [.machines[] | select(.verdict == "no" and .reason == "no-suite-slots")])
      | .[] | [.machine, .mate, .root] | @tsv')
  else
    candidates=$(printf '%s\tself\t%s\n' "$(hostname -s)" "$(dirname "$SCRIPT_DIR")")
  fi

  for repo in "${repos[@]}"; do
    if [ "$dry" -eq 1 ]; then
      out=$(printf '%s\n' "$candidates" | awk -F'\t' 'NF { print $1 }' | paste -sd, -)
      printf 'PLAN %s -> %s\n' "$repo" "${out:-none}"
      continue
    fi
    tried=()
    result=''
    machine=''
    while IFS=$'\t' read -r cand mate root; do
      [ -n "$cand" ] || continue
      tried+=("$cand")
      if [ "$mate" = self ]; then
        out=$("$SCRIPT_DIR/fm-suite-daily.sh" run "$repo" 2> /dev/null < /dev/null)
        rc=$?
      else
        printf -v remote_cmd '%q/bin/fm-suite-daily.sh run %q' "$root" "$repo"
        out=$("$ssh_cmd" -o BatchMode=yes -o ConnectTimeout=5 "$cand" "$remote_cmd" 2> /dev/null < /dev/null)
        rc=$?
      fi
      line=$(printf '%s\n' "$out" | grep '^RESULT ' | tail -n1)
      if [ "$rc" -eq 0 ] && printf '%s\n' "${line#RESULT }" | jq -e . > /dev/null 2>&1; then
        result=${line#RESULT }
        machine=$cand
        break
      fi
    done <<< "$candidates"

    alerted=false
    if [ -n "$result" ]; then
      status=$(jq -r '.status' <<< "$result")
      reason=$(jq -r '.reason // ""' <<< "$result")
      sha=$(jq -r '.sha // ""' <<< "$result")
      failures=$(jq -r '.failures // 0' <<< "$result")
      if [ "$status" = fail ] && alert_for "$repo" "$machine" "$result"; then alerted=true; fi
    else
      status=skipped reason=no-machine-ran sha='' failures=0
    fi
    log_line "$(jq -cn --arg ts "$(now_iso)" --arg host "$(hostname -s)" --arg key "$repo" --arg machine "$machine" \
      --arg status "$status" --arg reason "$reason" --arg sha "$sha" --argjson failures "$failures" \
      --argjson tried "$(printf '%s\n' "${tried[@]+"${tried[@]}"}" | jq -R . | jq -sc 'map(select(length > 0))')" --argjson alerted "$alerted" \
      '{ts: $ts, event: "dispatch", host: $host, key: $key, machine: $machine, status: $status, reason: $reason,
        sha: $sha, failures: $failures, tried: $tried, alerted: $alerted}')"
  done
  exit 0
}

cmd_status() {
  local json=0
  case "${1:-}" in
    '') ;;
    --json) json=1 ;;
    *) bad_usage "unknown status option: $1" ;;
  esac
  [ -f "$LOG_FILE" ] || return 0
  local pick='[.[] | select(.event == "daily-run" or .event == "dispatch")] | group_by(.key) | map(last) | sort_by(.ts) | reverse'
  if [ "$json" -eq 1 ]; then
    jq -s "$pick" "$LOG_FILE"
  else
    jq -sr "$pick | .[] | \"key=\\(.key) status=\\(.status) sha=\\((.sha // \"\")[0:7]) ts=\\(.ts) host=\\(.host) failures=\\(.failures // 0)\"" "$LOG_FILE"
  fi
}

cmd_install() {
  local print=0 when=03:30 dir exe service timer
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --print) print=1; shift ;;
      --time) [ "$#" -ge 2 ] || bad_usage "--time needs HH:MM"; when=$2; shift 2 ;;
      *) bad_usage "unknown install option: $1" ;;
    esac
  done
  case "$when" in
    [0-2][0-9]:[0-5][0-9]) ;;
    *) bad_usage "--time must look like 03:30" ;;
  esac
  exe="$SCRIPT_DIR/fm-suite-daily.sh"
  service="[Unit]
Description=Daily full test run per repo

[Service]
Type=oneshot
ExecStart=$exe dispatch
Nice=10
Environment=PATH=%h/bin:%h/.local/bin:/usr/local/bin:/usr/bin:/bin
"
  timer="[Unit]
Description=Daily full test run per repo

[Timer]
OnCalendar=*-*-* $when:00 America/Toronto
RandomizedDelaySec=900
Persistent=false

[Install]
WantedBy=timers.target
"
  if [ "$print" -eq 1 ]; then
    printf '# fm-suite-daily.service\n%s\n# fm-suite-daily.timer\n%s' "$service" "$timer"
    return 0
  fi
  case "$exe" in */.treehouse/*) say "warning: installing from a disposable worktree path ($exe); install from the live home" ;; esac
  dir="${FM_SUITE_UNIT_DIR:-$HOME/.config/systemd/user}"
  mkdir -p "$dir" || { say "cannot create $dir"; exit 1; }
  printf '%s' "$service" > "$dir/fm-suite-daily.service"
  printf '%s' "$timer" > "$dir/fm-suite-daily.timer"
  if [ "${FM_SUITE_INSTALL_NO_ENABLE:-}" != 1 ]; then
    "${FM_SUITE_SYSTEMCTL:-systemctl}" --user daemon-reload || { say "daemon-reload failed"; exit 1; }
    "${FM_SUITE_SYSTEMCTL:-systemctl}" --user enable --now fm-suite-daily.timer || { say "enabling the timer failed"; exit 1; }
  fi
  printf 'installed fm-suite-daily.timer (%s America/Toronto)\n' "$when"
}

case "${1:-}" in
  --help | -h) usage; exit 0 ;;
  run) shift; cmd_run "$@" ;;
  dispatch) shift; cmd_dispatch "$@" ;;
  status) shift; cmd_status "$@" ;;
  install) shift; cmd_install "$@" ;;
  '') bad_usage "missing subcommand" ;;
  *) bad_usage "unknown subcommand: $1" ;;
esac
