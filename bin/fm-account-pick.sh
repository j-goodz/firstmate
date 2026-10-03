#!/usr/bin/env bash
# Pick the Claude account (CLAUDE_CONFIG_DIR) one worker launch should run on.
#
# Usage: fm-account-pick.sh --config <file> [--log <jsonl>] [--task <id>] [--current <dir>]
#        fm-account-pick.sh --check --config <file>
#        fm-account-pick.sh --help
#
# bin/fm-spawn.sh calls this for every claude ship, scout, and secondmate launch
# and relaunch, with --config "$CONFIG/claude-accounts", --log
# "$DATA/account-picks.jsonl", and --current set to its own CLAUDE_CONFIG_DIR.
#
# Config (config/claude-accounts, LOCAL, gitignored; docs/configuration.md
# "Claude account routing" owns the operator-facing description):
#   # comment lines and blank lines are ignored
#   snapshot <absolute path to the usage snapshot JSON>      exactly once
#   account <label> <absolute store dir> [<absolute sign-in file>]   one or more
#   reserve <label> <HH:MM> <HH:MM>                          optional, repeatable
#   reserve-file <absolute path>                             optional, at most once
# <label> is [A-Za-z0-9._-]+, unique, and must match a key under the snapshot's
# "accounts" object. Paths may not contain whitespace. Any other line, a
# relative path, a duplicate label, a second snapshot line, or no account line
# is malformed. A reserve line must name a configured label and two distinct
# 24-hour times (00:00 to 23:59).
#
# Reserves keep an account out of every pick, fallback included:
#   reserve        Monday to Friday, from the first time until before the second,
#                  in America/Toronto local time. A window whose end is earlier
#                  than its start runs past midnight and belongs to the weekday
#                  it opens on. The intended use is 03:00 08:00, so the trading
#                  account starts the morning with a fresh 5-hour window.
#   reserve-file   each line "<account number or label> <until epoch>" reserves
#                  that account until the epoch; a bare number N means the label
#                  account-N. Blank and # lines are skipped, past epochs are
#                  ignored, and a missing file reserves nothing. An unusable line
#                  (wrong shape, non-numeric epoch, unknown account) is one
#                  stderr warning and reserves nothing. This is also how a spent
#                  account sits out until its limit resets: one line holding the
#                  reset epoch, after which routing returns to normal by itself.
# When several reserves cover one account, the one that ends last applies.
#
# Snapshot: a JSON object whose "accounts" maps each label to a reading with
# numeric five_hour_pct and weekly_pct, weekly_resets_at (ISO-8601 or epoch),
# fetched_at (ISO-8601 or epoch), and optional outcome ("ok" when present). This
# is the shape nexus writes to ~/.nexus/usage-snapshot.json; this script only
# reads it and never fetches usage itself.
#
# Selection, per account, in this order:
#   excluded-reserve  a reserve above covers the clock
#   excluded-signin   neither <store>/.credentials.json holds a refresh token (or
#                     access token) that has not expired, nor the optional
#                     sign-in file exists non-empty
#   unknown-missing   the snapshot is absent, unreadable, or has no reading for the label
#   unknown-failed    the reading's outcome is present and not "ok"
#   unknown-stale     fetched_at is missing or older than MAX_AGE_S (900s, the
#                     same freshness bound nexus usage_snapshot.is_usable uses)
#   unknown-incomplete  a percent or the weekly reset is missing or unparseable
#   excluded-5h       five_hour_pct above FIVE_HOUR_MAX (85)
#   excluded-weekly   weekly_pct at or above WEEKLY_MAX (98)
#   eligible          score = (100 - weekly_pct) / hours until weekly reset
#                     (hours floored at 0.1), so weekly allowance that expires
#                     sooner is spent first and an account with a far reset is kept
# The supervisor keeps its own account: the account whose store is --current
# (an empty --current means $HOME/.claude) ranks below every other eligible
# account, so a worker uses it only when it is the sole eligible one, and the
# reason says so either way. Among the rest the highest score wins; ties break
# on lower five_hour_pct, then config order. With no eligible account the pick
# falls back to --current and says so, unless --current is a reserved account's
# store: then it refuses with exit 3 and one stderr line naming the account and
# when its reserve ends, and prints no pick. With a reserve configured and jq
# missing, or a reserve file present but unreadable, it also refuses with exit 3
# because the reserve cannot be honored.
#
# Output on a pick (stdout, exit 0), three lines:
#   account=<label>      or "inherited" on fallback
#   config_dir=<dir>     the chosen store, or --current (possibly empty) on fallback
#   reason=<one line>
# An absent config prints nothing, logs nothing, and exits 0, so a home without
# the file launches exactly as before. A malformed config exits 2 with an error
# on stderr; --check validates the config the same way and never picks or logs.
# Without a configured reserve, missing jq or snapshot problems never refuse:
# they fall back to --current.
#
# Log: with --log, every pick (fallback included) appends one JSON line holding
# ts, epoch, task, chosen, config_dir, fallback, refused, reason, the
# thresholds, the snapshot path, the reserve file, and per account: label,
# config_dir, signin, supervisor, status, reserved, reserve_until (epoch or
# null), reserve_until_local (Toronto time or null), reserve_source ("window" or
# "file" or null), five_hour_pct, weekly_pct, weekly_resets_at,
# hours_to_weekly_reset, age_s, and score. A refusal is logged with chosen null. Credential contents are never read into output or the log; the
# sign-in test is a jq -e predicate. A failed log write is one stderr warning
# and never changes the pick.
#
# Environment: FM_ACCOUNT_PICK_NOW pins the clock (epoch seconds) for tests.
set -euo pipefail

FIVE_HOUR_MAX=85
WEEKLY_MAX=98
MAX_AGE_S=900

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

CHECK=0
CONFIG_FILE=
LOG_FILE=
TASK=
CURRENT=
while [ $# -gt 0 ]; do
  case "$1" in
  --check) CHECK=1 ;;
  --config) CONFIG_FILE=${2-} && shift ;;
  --log) LOG_FILE=${2-} && shift ;;
  --task) TASK=${2-} && shift ;;
  --current) CURRENT=${2-} && shift ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "error: fm-account-pick.sh: unknown argument '$1'; see --help" >&2
    exit 2
    ;;
  esac
  shift
done
[ -n "$CONFIG_FILE" ] || {
  echo "error: fm-account-pick.sh: --config <file> is required" >&2
  exit 2
}

# Absent config: today's behavior, byte for byte.
if [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
  exit 0
fi

malformed() {
  echo "error: $CONFIG_FILE: $1 (expected '# comment', 'snapshot <absolute path>', 'account <label> <absolute store dir> [<absolute sign-in file>]', 'reserve <label> <HH:MM> <HH:MM>', or 'reserve-file <absolute path>')" >&2
  exit 2
}

hhmm_minutes() {  # <HH:MM> -> minutes since midnight, or fail
  case "$1" in
  [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9]) echo $((10#${1%%:*} * 60 + 10#${1##*:})) ;;
  *) return 1 ;;
  esac
}

[ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] || malformed "not a readable regular file"

SNAPSHOT=
LABELS=()
DIRS=()
SIGNIN_FILES=()
RESERVE_FILE=
RESERVE_FILE_SET=0
WINDOW_LABELS=()
WINDOW_STARTS=()
WINDOW_ENDS=()
WINDOW_LINES=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  read -r -a words <<<"$line" || true
  [ "${#words[@]}" -gt 0 ] || continue
  case "${words[0]}" in
  \#*) continue ;;
  snapshot)
    [ "${#words[@]}" -eq 2 ] || malformed "line $lineno: snapshot takes exactly one path"
    [ -z "$SNAPSHOT" ] || malformed "line $lineno: snapshot given twice"
    case "${words[1]}" in /*) ;; *) malformed "line $lineno: snapshot path must be absolute" ;; esac
    SNAPSHOT=${words[1]}
    ;;
  account)
    [ "${#words[@]}" -eq 3 ] || [ "${#words[@]}" -eq 4 ] ||
      malformed "line $lineno: account takes a label, a store dir, and an optional sign-in file"
    case "${words[1]}" in
    *[!A-Za-z0-9._-]*) malformed "line $lineno: label '${words[1]}' may only use letters, digits, dot, underscore, and dash" ;;
    esac
    for existing in ${LABELS[@]+"${LABELS[@]}"}; do
      [ "$existing" != "${words[1]}" ] || malformed "line $lineno: duplicate label '${words[1]}'"
    done
    case "${words[2]}" in /*) ;; *) malformed "line $lineno: store dir must be absolute" ;; esac
    if [ "${#words[@]}" -eq 4 ]; then
      case "${words[3]}" in /*) ;; *) malformed "line $lineno: sign-in file must be absolute" ;; esac
    fi
    LABELS+=("${words[1]}")
    DIRS+=("${words[2]}")
    SIGNIN_FILES+=("${words[3]-}")
    ;;
  reserve)
    [ "${#words[@]}" -eq 4 ] || malformed "line $lineno: reserve takes a label, a start time, and an end time"
    start_min=$(hhmm_minutes "${words[2]}") || malformed "line $lineno: reserve start '${words[2]}' is not HH:MM"
    end_min=$(hhmm_minutes "${words[3]}") || malformed "line $lineno: reserve end '${words[3]}' is not HH:MM"
    [ "$start_min" -ne "$end_min" ] || malformed "line $lineno: reserve start and end are the same time"
    WINDOW_LABELS+=("${words[1]}")
    WINDOW_STARTS+=("$start_min")
    WINDOW_ENDS+=("$end_min")
    WINDOW_LINES+=("$lineno")
    ;;
  reserve-file)
    [ "${#words[@]}" -eq 2 ] || malformed "line $lineno: reserve-file takes exactly one path"
    [ "$RESERVE_FILE_SET" -eq 0 ] || malformed "line $lineno: reserve-file given twice"
    case "${words[1]}" in /*) ;; *) malformed "line $lineno: reserve-file path must be absolute" ;; esac
    RESERVE_FILE=${words[1]}
    RESERVE_FILE_SET=1
    ;;
  *) malformed "line $lineno: unknown keyword '${words[0]}'" ;;
  esac
done <"$CONFIG_FILE"
[ -n "$SNAPSHOT" ] || malformed "no snapshot line"
[ "${#LABELS[@]}" -gt 0 ] || malformed "no account line"

label_index() {  # <label> -> its config index, or fail
  local i
  for i in "${!LABELS[@]}"; do
    [ "${LABELS[$i]}" != "$1" ] || {
      echo "$i"
      return 0
    }
  done
  return 1
}
for i in "${!WINDOW_LABELS[@]}"; do
  label_index "${WINDOW_LABELS[$i]}" >/dev/null ||
    malformed "line ${WINDOW_LINES[$i]}: reserve names '${WINDOW_LABELS[$i]}', which no account line defines"
done
RESERVE_CONFIGURED=0
[ "${#WINDOW_LABELS[@]}" -eq 0 ] && [ "$RESERVE_FILE_SET" -eq 0 ] || RESERVE_CONFIGURED=1

[ "$CHECK" -eq 0 ] || exit 0

NOW=${FM_ACCOUNT_PICK_NOW:-$(date +%s)}

emit() {  # <account> <config_dir> <reason>
  printf 'account=%s\nconfig_dir=%s\nreason=%s\n' "$1" "$2" "$3"
}

refuse() {  # <one line>
  echo "error: fm-account-pick.sh: $1" >&2
  exit 3
}

if ! command -v jq >/dev/null 2>&1; then
  [ "$RESERVE_CONFIGURED" -eq 0 ] ||
    refuse "jq is not installed, so the configured account reserve cannot be honored; refusing rather than risk launching on a reserved account"
  echo "warning: fm-account-pick.sh: jq is not installed, so usage cannot be read; keeping the current account" >&2
  emit inherited "$CURRENT" "fallback: jq is not installed; kept the current account"
  exit 0
fi

# Sign-in per account: a jq -e predicate over the credential store, so no
# credential value is ever printed.
signed_in() {  # <store dir> <sign-in file or empty>
  local creds="$1/.credentials.json"
  if [ -n "$2" ] && [ -s "$2" ]; then
    return 0
  fi
  [ -f "$creds" ] && [ -r "$creds" ] || return 1
  jq -e --argjson now "$NOW" '
    def secs: if . > 100000000000 then . / 1000 else . end;
    def live($exp): ($exp == null) or (($exp | type) == "number" and ($exp | secs) > $now);
    (.claudeAiOauth // {}) as $o
    | ((($o.refreshToken // "") | type == "string" and length > 0) and live($o.refreshTokenExpiresAt))
      or ((($o.accessToken // "") | type == "string" and length > 0) and ($o.expiresAt != null) and live($o.expiresAt))
  ' "$creds" >/dev/null 2>&1
}

# Reserves: windows resolve against America/Toronto wall time inside jq (TZ
# applies to that one call), and the file's lines are parsed here.
WINDOWS_JSON='[]'
for i in "${!WINDOW_LABELS[@]}"; do
  WINDOWS_JSON=$(jq -c --arg label "${WINDOW_LABELS[$i]}" --argjson s "${WINDOW_STARTS[$i]}" --argjson e "${WINDOW_ENDS[$i]}" \
    '. + [{label: $label, start: $s, end: $e}]' <<<"$WINDOWS_JSON")
done
FILE_RESERVES_JSON='[]'
if [ "$RESERVE_FILE_SET" -eq 1 ] && { [ -e "$RESERVE_FILE" ] || [ -L "$RESERVE_FILE" ]; }; then
  [ -f "$RESERVE_FILE" ] && [ -r "$RESERVE_FILE" ] ||
    refuse "reserve file $RESERVE_FILE exists but is not a readable file, so its reserves cannot be honored; refusing rather than risk launching on a reserved account"
  rlineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    rlineno=$((rlineno + 1))
    read -r -a words <<<"$line" || true
    [ "${#words[@]}" -gt 0 ] || continue
    case "${words[0]}" in \#*) continue ;; esac
    rlabel=${words[0]}
    case "$rlabel" in *[!0-9]*) ;; *) rlabel="account-$rlabel" ;; esac
    if [ "${#words[@]}" -ne 2 ] || [ -z "${words[1]##*[!0-9]*}" ] || ! label_index "$rlabel" >/dev/null; then
      echo "warning: fm-account-pick.sh: $RESERVE_FILE line $rlineno is not '<account number or label> <until epoch>' for a configured account; it reserves nothing" >&2
      continue
    fi
    FILE_RESERVES_JSON=$(jq -c --arg label "$rlabel" --argjson until "$((10#${words[1]}))" \
      '. + [{label: $label, until: $until}]' <<<"$FILE_RESERVES_JSON")
  done <"$RESERVE_FILE"
fi
RESERVES_JSON=$(TZ=America/Toronto jq -nc --argjson windows "$WINDOWS_JSON" --argjson file "$FILE_RESERVES_JSON" --argjson now "$NOW" '
  # Wall-clock offset at an instant, and the instant a wall-clock time (given as
  # seconds since the epoch read as UTC) names; two passes settle a DST change.
  def off: (localtime | mktime) - .;
  def local_epoch: . as $wall | ($wall - ($wall | off)) as $e0 | $wall - ($e0 | off);
  (($now + ($now | off)) | floor) as $wall_now
  | ($wall_now - ($wall_now % 86400)) as $today
  | [ $windows[] as $w
      | ($today - 86400, $today) as $day
      | select(($day | gmtime | .[6]) as $wd | $wd >= 1 and $wd <= 5)
      | ($day + $w.start * 60 | local_epoch) as $start
      | ((if $w.end > $w.start then $day else $day + 86400 end) + $w.end * 60 | local_epoch) as $end
      | select($start <= $now and $now < $end)
      | {label: $w.label, until: $end, source: "window"} ]
    + [ $file[] | select(.until > $now) | . + {source: "file"} ]
  | group_by(.label)
  | map(max_by(.until) | . + {until_local: (.until | strflocaltime("%Y-%m-%d %H:%M %Z"))})
  | map({key: .label, value: .}) | from_entries
')

# Store paths compare after resolving symlinks and trailing slashes.
canon_dir() {
  local d=$1
  [ -n "$d" ] || d="$HOME/.claude"
  if [ -d "$d" ] && (CDPATH='' cd -P -- "$d" 2>/dev/null && pwd -P); then
    return 0
  fi
  while [ "${#d}" -gt 1 ] && [ "${d%/}" != "$d" ]; do d=${d%/}; done
  printf '%s\n' "$d"
}
CURRENT_CANON=$(canon_dir "$CURRENT")

ACCOUNTS_JSON='[]'
for i in "${!LABELS[@]}"; do
  signin=false
  signed_in "${DIRS[$i]}" "${SIGNIN_FILES[$i]}" && signin=true
  supervisor=false
  [ "$(canon_dir "${DIRS[$i]}")" != "$CURRENT_CANON" ] || supervisor=true
  ACCOUNTS_JSON=$(jq -c --arg label "${LABELS[$i]}" --arg dir "${DIRS[$i]}" --argjson signin "$signin" --argjson idx "$i" \
    --argjson supervisor "$supervisor" \
    '. + [{label: $label, config_dir: $dir, signin: $signin, supervisor: $supervisor, idx: $idx}]' <<<"$ACCOUNTS_JSON")
done

SNAPSHOT_JSON=null
if [ -f "$SNAPSHOT" ] && [ -r "$SNAPSHOT" ]; then
  SNAPSHOT_JSON=$(jq -c 'if type == "object" then . else null end' "$SNAPSHOT" 2>/dev/null) || SNAPSHOT_JSON=null
  [ -n "$SNAPSHOT_JSON" ] || SNAPSHOT_JSON=null
fi

RESULT=$(jq -nc \
  --argjson accounts "$ACCOUNTS_JSON" \
  --argjson snap "$SNAPSHOT_JSON" \
  --argjson reserves "$RESERVES_JSON" \
  --arg reserve_file "$RESERVE_FILE" \
  --argjson now "$NOW" \
  --argjson five_max "$FIVE_HOUR_MAX" \
  --argjson weekly_max "$WEEKLY_MAX" \
  --argjson max_age "$MAX_AGE_S" \
  --arg current "$CURRENT" \
  --arg task "$TASK" \
  --arg snapshot "$SNAPSHOT" '
  # ISO-8601 (optional fractional seconds, Z or +-HH:MM offset) or epoch -> epoch.
  def epoch:
    if type == "number" then .
    elif type == "string" then
      (try (capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
        | (.b + "Z" | fromdateiso8601) as $base
        | (if (.z // "Z") == "Z" then 0
           else (.z | sub(":"; "")) as $z
             | ((if $z[0:1] == "-" then -1 else 1 end) * (($z[1:3] | tonumber) * 3600 + ($z[3:5] | tonumber) * 60))
           end) as $off
        | $base - $off) catch null)
    else null end;
  def r2: . * 100 | round / 100;
  def num: if type == "number" then . else null end;
  ($snap | if type == "object" then (.accounts // {}) else {} end) as $readings
  | [ $accounts[] as $a
      | ($readings[$a.label] // null) as $r
      | ($r | if type == "object" then . else null end) as $r
      | (if $r == null then null else ($r.fetched_at // $snap.generated_at // null | epoch) end) as $fetched
      | (if $fetched == null then null else ($now - $fetched | floor) end) as $age
      | (if $r == null then null else ($r.five_hour_pct | num) end) as $five
      | (if $r == null then null else ($r.weekly_pct | num) end) as $weekly
      | (if $r == null then null else ($r.weekly_resets_at | epoch) end) as $reset
      | (if $reset == null then null else (($reset - $now) / 3600) end) as $hours
      | ($reserves[$a.label] // null) as $res
      | (if $res != null then "excluded-reserve"
         elif $a.signin | not then "excluded-signin"
         elif $r == null then "unknown-missing"
         elif ($r.outcome != null) and ($r.outcome != "ok") then "unknown-failed"
         elif $age == null or $age > $max_age then "unknown-stale"
         elif $five == null or $weekly == null or $hours == null then "unknown-incomplete"
         elif $five > $five_max then "excluded-5h"
         elif $weekly >= $weekly_max then "excluded-weekly"
         else "eligible" end) as $status
      | {label: $a.label, config_dir: $a.config_dir, signin: $a.signin, supervisor: $a.supervisor, idx: $a.idx,
         status: $status, reserved: ($res != null),
         reserve_until: ($res | if . == null then null else .until end),
         reserve_until_local: ($res | if . == null then null else .until_local end),
         reserve_source: ($res | if . == null then null else .source end),
         five_hour_pct: $five, weekly_pct: $weekly,
         weekly_resets_at: (if $r == null then null else $r.weekly_resets_at end),
         hours_to_weekly_reset: (if $hours == null then null else ($hours | r2) end),
         age_s: $age,
         score: (if $status == "eligible"
                 then ((([100 - $weekly, 0] | max) / ([$hours, 0.1] | max)) * 1000000 | round / 1000000)
                 else null end)} ] as $rows
  | ([ $rows[] | select(.status == "eligible") ] | sort_by([(if .supervisor then 1 else 0 end), -.score, .five_hour_pct, .idx])) as $ranked
  | ($ranked[0] // null) as $pick
  | ([ $rows[] | select(.supervisor and .reserved) ][0] // null) as $reserved_current
  | def brief: "\(.label) \(.status)\(if .status == "eligible" then " \(.score | r2)%/h" elif .reserved then " until \(.reserve_until_local)" else "" end)";
    (if $pick == null and $reserved_current != null then
      {chosen: null, config_dir: null, fallback: true, refused: true,
       reason: ("refusing: no eligible account (" + ([ $rows[] | brief ] | join(", ")) + ") and the fallback, the supervisor'"'"'s account \($reserved_current.label), is reserved until \($reserved_current.reserve_until_local) by its \($reserved_current.reserve_source) reserve")}
    elif $pick == null then
      {chosen: "inherited", config_dir: $current, fallback: true, refused: false,
       reason: ("fallback: no eligible account (" + ([ $rows[] | brief ] | join(", ")) + "); kept the current account")}
    else
      {chosen: $pick.label, config_dir: $pick.config_dir, fallback: false, refused: false,
       reason: ((if $pick.supervisor then "only eligible account is the supervisor'"'"'s own; " else "" end)
         + "\($pick.label): \(100 - $pick.weekly_pct | r2)% weekly left, resets in \($pick.hours_to_weekly_reset)h (\($pick.score | r2)%/h), 5h \($pick.five_hour_pct)%"
         + ([ $ranked[] | select(.supervisor and .label != $pick.label) | "; kept the supervisor'"'"'s account \(.label) free" ] | join(""))
         + (if ($rows | length) > 1 then "; others: " + ([ $rows[] | select(.label != $pick.label) | brief ] | join(", ")) else "" end))}
    end) as $choice
  | $choice + {
      ts: ($now | todate), epoch: $now, task: $task,
      five_hour_max: $five_max, weekly_max: $weekly_max, max_age_s: $max_age, snapshot: $snapshot,
      reserve_file: (if $reserve_file == "" then null else $reserve_file end),
      accounts: [ $rows[] | del(.idx) ]}
')

CHOSEN=$(jq -r .chosen <<<"$RESULT")
CHOSEN_DIR=$(jq -r .config_dir <<<"$RESULT")
REASON=$(jq -r .reason <<<"$RESULT")
REFUSED=$(jq -r .refused <<<"$RESULT")

if [ -n "$LOG_FILE" ]; then
  if ! printf '%s\n' "$RESULT" >>"$LOG_FILE" 2>/dev/null; then
    [ "$REFUSED" = true ] || echo "warning: fm-account-pick.sh: could not append the pick to $LOG_FILE" >&2
  fi
fi

[ "$REFUSED" != true ] || refuse "$REASON"

emit "$CHOSEN" "$CHOSEN_DIR" "$REASON"
