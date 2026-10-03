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
# <label> is [A-Za-z0-9._-]+, unique, and must match a key under the snapshot's
# "accounts" object. Paths may not contain whitespace. Any other line, a
# relative path, a duplicate label, a second snapshot line, or no account line
# is malformed.
#
# Snapshot: a JSON object whose "accounts" maps each label to a reading with
# numeric five_hour_pct and weekly_pct, weekly_resets_at (ISO-8601 or epoch),
# fetched_at (ISO-8601 or epoch), and optional outcome ("ok" when present). This
# is the shape nexus writes to ~/.nexus/usage-snapshot.json; this script only
# reads it and never fetches usage itself.
#
# Selection, per account, in this order:
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
# The highest score wins; ties break on lower five_hour_pct, then config order.
# With no eligible account the pick falls back to --current and says so.
#
# Output on a pick (stdout, exit 0), three lines:
#   account=<label>      or "inherited" on fallback
#   config_dir=<dir>     the chosen store, or --current (possibly empty) on fallback
#   reason=<one line>
# An absent config prints nothing, logs nothing, and exits 0, so a home without
# the file launches exactly as before. A malformed config exits 2 with an error
# on stderr; --check validates the config the same way and never picks or logs.
# Missing jq or snapshot problems never refuse: they fall back to --current.
#
# Log: with --log, every pick (fallback included) appends one JSON line holding
# ts, epoch, task, chosen, config_dir, fallback, reason, the thresholds, the
# snapshot path, and per account: label, config_dir, signin, status,
# five_hour_pct, weekly_pct, weekly_resets_at, hours_to_weekly_reset, age_s, and
# score. Credential contents are never read into output or the log; the
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
  echo "error: $CONFIG_FILE: $1 (expected '# comment', 'snapshot <absolute path>', or 'account <label> <absolute store dir> [<absolute sign-in file>]')" >&2
  exit 2
}

[ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] || malformed "not a readable regular file"

SNAPSHOT=
LABELS=()
DIRS=()
SIGNIN_FILES=()
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
  *) malformed "line $lineno: unknown keyword '${words[0]}'" ;;
  esac
done <"$CONFIG_FILE"
[ -n "$SNAPSHOT" ] || malformed "no snapshot line"
[ "${#LABELS[@]}" -gt 0 ] || malformed "no account line"

[ "$CHECK" -eq 0 ] || exit 0

NOW=${FM_ACCOUNT_PICK_NOW:-$(date +%s)}

emit() {  # <account> <config_dir> <reason>
  printf 'account=%s\nconfig_dir=%s\nreason=%s\n' "$1" "$2" "$3"
}

if ! command -v jq >/dev/null 2>&1; then
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

ACCOUNTS_JSON='[]'
for i in "${!LABELS[@]}"; do
  signin=false
  signed_in "${DIRS[$i]}" "${SIGNIN_FILES[$i]}" && signin=true
  ACCOUNTS_JSON=$(jq -c --arg label "${LABELS[$i]}" --arg dir "${DIRS[$i]}" --argjson signin "$signin" --argjson idx "$i" \
    '. + [{label: $label, config_dir: $dir, signin: $signin, idx: $idx}]' <<<"$ACCOUNTS_JSON")
done

SNAPSHOT_JSON=null
if [ -f "$SNAPSHOT" ] && [ -r "$SNAPSHOT" ]; then
  SNAPSHOT_JSON=$(jq -c 'if type == "object" then . else null end' "$SNAPSHOT" 2>/dev/null) || SNAPSHOT_JSON=null
  [ -n "$SNAPSHOT_JSON" ] || SNAPSHOT_JSON=null
fi

RESULT=$(jq -nc \
  --argjson accounts "$ACCOUNTS_JSON" \
  --argjson snap "$SNAPSHOT_JSON" \
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
      | (if $a.signin | not then "excluded-signin"
         elif $r == null then "unknown-missing"
         elif ($r.outcome != null) and ($r.outcome != "ok") then "unknown-failed"
         elif $age == null or $age > $max_age then "unknown-stale"
         elif $five == null or $weekly == null or $hours == null then "unknown-incomplete"
         elif $five > $five_max then "excluded-5h"
         elif $weekly >= $weekly_max then "excluded-weekly"
         else "eligible" end) as $status
      | {label: $a.label, config_dir: $a.config_dir, signin: $a.signin, idx: $a.idx, status: $status,
         five_hour_pct: $five, weekly_pct: $weekly,
         weekly_resets_at: (if $r == null then null else $r.weekly_resets_at end),
         hours_to_weekly_reset: (if $hours == null then null else ($hours | r2) end),
         age_s: $age,
         score: (if $status == "eligible"
                 then ((([100 - $weekly, 0] | max) / ([$hours, 0.1] | max)) * 1000000 | round / 1000000)
                 else null end)} ] as $rows
  | ([ $rows[] | select(.status == "eligible") ] | sort_by([-.score, .five_hour_pct, .idx])) as $ranked
  | ($ranked[0] // null) as $pick
  | def brief: "\(.label) \(.status)\(if .status == "eligible" then " \(.score | r2)%/h" else "" end)";
    (if $pick == null then
      {chosen: "inherited", config_dir: $current, fallback: true,
       reason: ("fallback: no eligible account (" + ([ $rows[] | brief ] | join(", ")) + "); kept the current account")}
    else
      {chosen: $pick.label, config_dir: $pick.config_dir, fallback: false,
       reason: ("\($pick.label): \(100 - $pick.weekly_pct | r2)% weekly left, resets in \($pick.hours_to_weekly_reset)h (\($pick.score | r2)%/h), 5h \($pick.five_hour_pct)%"
         + (if ($rows | length) > 1 then "; others: " + ([ $rows[] | select(.label != $pick.label) | brief ] | join(", ")) else "" end))}
    end) as $choice
  | $choice + {
      ts: ($now | todate), epoch: $now, task: $task,
      five_hour_max: $five_max, weekly_max: $weekly_max, max_age_s: $max_age, snapshot: $snapshot,
      accounts: [ $rows[] | del(.idx) ]}
')

CHOSEN=$(jq -r .chosen <<<"$RESULT")
CHOSEN_DIR=$(jq -r .config_dir <<<"$RESULT")
REASON=$(jq -r .reason <<<"$RESULT")

if [ -n "$LOG_FILE" ]; then
  if ! printf '%s\n' "$RESULT" >>"$LOG_FILE" 2>/dev/null; then
    echo "warning: fm-account-pick.sh: could not append the pick to $LOG_FILE" >&2
  fi
fi

emit "$CHOSEN" "$CHOSEN_DIR" "$REASON"
