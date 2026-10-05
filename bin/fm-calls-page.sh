#!/usr/bin/env bash
# fm-calls-page.sh - the captain's open-calls page, generated from the live
# captain-hold records so an answered call leaves the page by itself.
#
# Usage:
#   fm-calls-page.sh render [--if-present]
#   fm-calls-page.sh arm [--reopen]
#   fm-calls-page.sh apply <result-file>
#
# render   Collect every open captain call and write data/open-calls/calls.html
#          atomically. A call is open when its task is held for the captain
#          (hold kind captain, not Done) and its hold-until date is absent,
#          today, or past. A hold-until date still in the future makes the call
#          parked: it is listed only by title and date in a collapsed list.
#          Calls come from this home and from every second mate listed in
#          data/secondmates.md. A remote home is read over its registered route
#          (bin/fm-on.sh, explicit remote FM_HOME, read-only fetch of its
#          data/backlog.md); a local second mate's home is read directly. Every
#          backlog is parsed by bin/fm-fleet-snapshot.sh --contribution-input.
#          A call whose latest captain-hold record is already resolved never
#          renders, even while its backlog row is still held: in this home that
#          is bin/fm-captain-hold.sh diverged, and for a second mate it is the
#          newest `captain-hold-<task>-<n>` key in this home's
#          state/<secondmate>.status closing as resolved (a chat answer relayed
#          through bin/fm-send.sh --resolve-key). A home that cannot be read is
#          named on the page and on stderr; the page still renders.
#          Cards group by project (the task's repo); the default sort is newest
#          asked first across every project, with a Newest / By project switch
#          (By project keeps the groups in newest-call order). Each card shows
#          its ask date relatively to the build date ("today", "yesterday", or
#          "Sep 28") and a one-line why. An optional curated file
#          data/open-calls/calls.json refines grouping:
#            [{"project", "feature", "context",
#              "calls": [{"id", "home", "question",
#                         "options": [{"value", "label", "detail"}],
#                         "recommendation"}]}]
#          A curated call renders under its project and feature, the feature's
#          long context folds into a collapsed details (a one-line why stays on
#          the card), its question replaces the task title, and its
#          recommendation is a marked suggestion, never pre-selected. "home" is
#          "local" (or "main") for this home, else the second mate id. A curated
#          call that is not open never renders; an open call missing from the
#          file renders under its repo.
#          Without curated options, a task body may carry a call-options block:
#          a line `call-options:` followed by one `- <option>` line per option,
#          ending at the first line that does not start with `- `. Every card
#          also offers "Later, park one week", "Not needed, close it", and
#          "Let's talk about it first", and a text box for the captain's own
#          words; nothing is pre-selected. A curated call's "his_prior_words"
#          folds into a collapsed details above its options. The curated file
#          may also be an object whose "groups" array has that shape, and a
#          curated "home" naming a machine instead of a home id still matches
#          when the task id is open in exactly one home.
#          Each card has its own save, which queues one Lavish prompt carrying
#          data {schema: "open-call-answer.v1", call, home, kind, value,
#          answer, note, asked} (kind: option, text, later, not-needed, or
#          talk) and sends it at once, confirms what was saved on the card for
#          1.5 seconds, then collapses it without the next card jumping under
#          the reader's finger. The collapsed marker is keyed to the page build,
#          so the next re-render leaves every still-open card answerable again,
#          and a talk save (nothing recorded) writes no persistent marker at all.
#          --if-present makes render a silent no-op when the page does not exist
#          yet, which is how bin/fm-captain-hold.sh calls it after every
#          successful mutation (best effort: a failed re-render never fails the
#          mutation). Lavish live-reloads an artifact when its file changes, so
#          an open review page refreshes without any extra step.
#          Prints `rendered: <path> open=<n> parked=<n>`.
# arm      Render the page if it is missing, open or resume its Lavish session
#          (`lavish-axi <page>`; --reopen only when the captain asks to reopen a
#          session he ended), and arm it through bin/fm-procevent-lavish.sh arm.
#          Idempotent: resuming an open session changes nothing, and arming
#          again republishes the same registration for the same source.
# apply    Apply each open-call-answer.v1 item in a captured Lavish result (read
#          through bin/fm-procevent-lavish.sh read; the last save per call
#          wins) to the call's owning home through bin/fm-captain-hold.sh:
#            option          `answer <task> --decision-file <captain's words>`,
#                            with --release when the held task is a work item
#                            rather than a call-only task (kind captain);
#            later           `hold <task> --reason <parked note> --until <today+7>`;
#            not-needed      answer "Not needed" and close (never --release);
#            text or talk    typed words with no option picked are never a
#                            decision: with the captain's words, re-`hold` the
#                            call with those words in its reason so it stays open; with no
#                            words, record nothing. Either way it is printed as
#                            `talk:` for firstmate to raise in chat.
#          Every recorded answer and every talk prints one
#          `route: <home>/<task> <answer>` line so firstmate acts on it; an
#          option, text, Later, or Not needed answer for a call held in a second
#          mate home is also sent to `fm-<home>` through bin/fm-send.sh, so its
#          home files any follow-up work the decision authorizes (best effort).
#          A second mate's remote calls go through `fm-on.sh` to its own
#          fm-captain-hold.sh (`answers` keyed intake on stdin, or `hold`); the
#          keyed intake shortens each field to 512 characters. An item whose
#          call is no longer open is reported `skipped:` and records nothing, so
#          an answer already given in chat is never applied twice. A second-mate send
#          that failed is kept in state/calls-page-undelivered.tsv and retried at
#          the start of the next apply. The reserved
#          value `reconcile` is reported `refused:` and never applied. Then the
#          page is re-rendered best effort (a failed rebuild is a warning, never
#          a failed apply). Exit 1 only when a recording command failed.
#
# Every render and applied item appends one JSON line to state/calls-page.jsonl
# (capped to its newest 2000 lines).
#
# Environment: FM_CALLS_PAGE_TODAY (YYYY-MM-DD) and FM_CALLS_PAGE_NOW (UTC ISO
# time) pin the clock; FM_CALLS_PAGE_REMOTE_TIMEOUT bounds each remote read
# (default 30 seconds); FM_CALLS_PAGE_FM_ON, FM_CALLS_PAGE_FM_SEND and
# FM_CALLS_PAGE_CAPTAIN_HOLD replace the transport, the second-mate send, and
# the captain-hold command (test seams).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

PAGE="$DATA/open-calls/calls.html"
CURATED="$DATA/open-calls/calls.json"
LOG="$STATE/calls-page.jsonl"
UNDELIVERED="$STATE/calls-page-undelivered.tsv"
HELPER="$SCRIPT_DIR/fm-calls-page.py"
CAPTAIN_HOLD="${FM_CALLS_PAGE_CAPTAIN_HOLD:-$SCRIPT_DIR/fm-captain-hold.sh}"
FM_ON="${FM_CALLS_PAGE_FM_ON:-$SCRIPT_DIR/fm-on.sh}"
FM_SEND="${FM_CALLS_PAGE_FM_SEND:-$SCRIPT_DIR/fm-send.sh}"
REMOTE_TIMEOUT=${FM_CALLS_PAGE_REMOTE_TIMEOUT:-30}
TODAY=${FM_CALLS_PAGE_TODAY:-$(date -u +%Y-%m-%d)}
NOW=${FM_CALLS_PAGE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
LOCK="$STATE/.calls-page.lock"
LOCK_HELD=0
WORK=

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-calls-page: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ "$LOCK_HELD" = 1 ]; then
    fm_lock_release "$LOCK" || true
    LOCK_HELD=0
  fi
  [ -z "$WORK" ] || rm -rf -- "$WORK"
}
trap cleanup EXIT

log_event() {  # <jq-args...> -- appends one structured line, best effort
  local line
  line=$(jq -cn --arg at "$NOW" "$@" '$ARGS.named') || return 0
  { printf '%s\n' "$line" >> "$LOG"; } 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2400 ]; then
    { tail -n 2000 "$LOG" > "$LOG.tmp" && mv -f -- "$LOG.tmp" "$LOG"; } 2>/dev/null || true
  fi
}

# One home's backlog, parsed by the canonical parser, into <out>.
snapshot_of() {  # <fm-home> <out>
  FM_HOME="$1" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$2"
}

# Task ids whose newest captain-hold-<task>-<n> key in <status-file> closed as
# resolved: a second mate's call answered through the parent channel.
parent_resolved_ids() {  # <status-file>
  local status=$1 filtered pairs id n
  [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ] || return 0
  filtered="$WORK/parent-$RANDOM.status"
  grep -F 'captain-hold-' "$status" > "$filtered" 2>/dev/null || return 0
  pairs=$(grep -o 'key=captain-hold-[A-Za-z0-9._-]*-[0-9][0-9]*\]' "$filtered" \
    | awk '{
        k = $0; sub(/^key=captain-hold-/, "", k); sub(/\]$/, "", k)
        n = k; sub(/.*-/, "", n); id = k; sub(/-[0-9]+$/, "", id)
        if (!(id in max) || n + 0 > max[id] + 0) max[id] = n
      } END { for (id in max) print id, max[id] }')
  while read -r id n; do
    [ -n "$id" ] || continue
    if [ "$(status_key_closing_verb "$filtered" "captain-hold-$id-$n")" = "$FM_CLASSIFY_RESOLVE_VERB_DEFAULT" ]; then
      printf '%s\n' "$id"
    fi
  done <<EOF
$pairs
EOF
}

ids_json() { jq -R -s 'split("\n") | map(select(length > 0))'; }

manifest_line() {  # <home> <label> <snapshot-or-empty> <resolved-json> <error-or-empty>
  jq -cn --arg home "$1" --arg label "$2" --arg snapshot "$3" --argjson resolved "$4" --arg error "$5" \
    '{home:$home,label:$label,snapshot:(if $snapshot == "" then null else $snapshot end),
      resolved:$resolved,error:(if $error == "" then null else $error end)}'
}

# Collect every home into $WORK/manifest.jsonl for the helper.
collect() {
  local manifest="$WORK/manifest.jsonl" reg="$DATA/secondmates.md" line id home snap staged err resolved
  : > "$manifest"
  snap="$WORK/local.json"
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$snap" 2>"$WORK/local.err"; then
    die "cannot read this home's backlog: $(tail -1 "$WORK/local.err")"
  fi
  resolved=$("$CAPTAIN_HOLD" diverged 2>/dev/null | cut -f1 | ids_json)
  manifest_line local "this home" "$snap" "$resolved" '' >> "$manifest"
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || continue
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    snap="$WORK/sm-$id.json"
    err=''
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
      staged="$WORK/sm-$id"
      mkdir -p "$staged/data" "$staged/state"
      if ! fm_run_timed "$REMOTE_TIMEOUT" "$FM_ON" "$id" fm-remote-file.sh get data/backlog.md 1048576 \
          > "$staged/data/backlog.md" 2>"$staged/err" </dev/null; then
        err="the read from $SECONDMATE_REGISTRY_HOST failed ($(tail -1 "$staged/err" | tr -d '\r'))"
      elif ! snapshot_of "$staged" "$snap" 2>"$staged/err"; then
        err="its backlog could not be parsed ($(tail -1 "$staged/err"))"
      fi
      resolved=$(parent_resolved_ids "$STATE/$id.status" | ids_json)
    else
      if ! snapshot_of "$home" "$snap" 2>"$WORK/sm-$id.err"; then
        err="its backlog could not be parsed ($(tail -1 "$WORK/sm-$id.err"))"
      fi
      resolved=$({ parent_resolved_ids "$STATE/$id.status"
        FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' "$CAPTAIN_HOLD" diverged 2>/dev/null | cut -f1
      } | ids_json)
    fi
    if [ -n "$err" ]; then
      printf 'warning: could not read the calls held by %s: %s\n' "$id" "$err" >&2
      manifest_line "$id" "$id" '' "$resolved" "$err" >> "$manifest"
    else
      manifest_line "$id" "$id" "$snap" "$resolved" '' >> "$manifest"
    fi
  done < "$reg"
}

do_render() {
  local out started errors
  started=$(date +%s)
  mkdir -p "$DATA/open-calls" || die "cannot create $DATA/open-calls"
  collect
  out=$(python3 "$HELPER" render "$WORK/manifest.jsonl" "$TODAY" "$NOW" "$PAGE" "$CURATED" 2>"$WORK/render.err") \
    || die "the calls page could not be written: $(tail -1 "$WORK/render.err")"
  errors=$(jq -s '[.[] | select(.error != null)] | length' "$WORK/manifest.jsonl")
  printf 'rendered: %s %s\n' "$PAGE" "$out"
  log_event --arg event render --arg counts "$out" --arg unreadable_homes "$errors" \
    --arg seconds "$(( $(date +%s) - started ))"
}

start_work() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-calls-page.XXXXXX") || die "cannot create a work directory"
  fm_lock_acquire_wait_bounded "$LOCK" 120 || die "another calls-page run still holds $LOCK"
  LOCK_HELD=1
}

cmd_render() {
  local if_present=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --if-present) if_present=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  if [ "$if_present" = 1 ] && [ ! -f "$PAGE" ]; then
    return 0
  fi
  start_work
  do_render
}

cmd_arm() {
  local reopen=0 opened link
  local -a open_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reopen) reopen=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  if [ ! -f "$PAGE" ]; then
    start_work
    do_render
  fi
  open_args=("$PAGE")
  [ "$reopen" = 0 ] || open_args+=(--reopen)
  opened=$(lavish-axi "${open_args[@]}" 2>&1) \
    || die "Lavish did not open the page: $(printf '%s\n' "$opened" | head -3 | tr '\n' ' ')"
  link=$(printf '%s\n' "$opened" | grep -o 'http[s]*://[^" ]*/session/[A-Za-z0-9_-]*' | head -1)
  if [ -n "$link" ] && command -v lavish-sys >/dev/null 2>&1; then
    link=$(lavish-sys url "$link" 2>/dev/null || printf '%s' "$link")
  fi
  [ -z "$link" ] || printf 'link: %s\n' "$link"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$PAGE"
}

# The owning home of a call: "local", a local second mate, or a remote one.
HOME_KIND=
HOME_PATH=
resolve_home() {  # <home-id>
  local reg="$DATA/secondmates.md"
  HOME_KIND=
  HOME_PATH=
  if [ "$1" = local ]; then
    HOME_KIND=local
    return 0
  fi
  [ -f "$reg" ] || return 1
  secondmate_registry_line_for_id "$reg" "$1" || return 1
  if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
    HOME_KIND=remote
  else
    HOME_KIND=mate
    HOME_PATH=$SECONDMATE_REGISTRY_HOME
  fi
}

# Run one fm-captain-hold.sh mutation in the call's owning home.
hold_in_home() {  # <home-id> <args...>
  local home=$1
  shift
  case "$HOME_KIND" in
    local) FM_CALLS_PAGE_RERENDER=0 "$CAPTAIN_HOLD" "$@" ;;
    mate)
      FM_HOME="$HOME_PATH" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_CALLS_PAGE_RERENDER=0 "$CAPTAIN_HOLD" "$@"
      ;;
    remote) fm_run_timed "$REMOTE_TIMEOUT" "$FM_ON" "$home" fm-captain-hold.sh "$@" </dev/null ;;
  esac
}

# Record one answer in the call's owning home.
answer_in_home() {  # <home-id> <task> <answer> <words> <release-0-or-1>
  local home=$1 id=$2 answer=$3 words=$4 release=$5 file mode='done' text
  if [ "$HOME_KIND" = remote ]; then
    [ "$release" = 0 ] || mode=release
    text=$answer
    [ -z "$words" ] || text="$answer - $words"
    printf '%s\t%s\t\t%s\n' "$id" "$(printf '%s' "$text" | tr '\n\r\t' '   ')" "$mode" \
      | fm_run_timed "$REMOTE_TIMEOUT" "$FM_ON" --stdin "$home" fm-captain-hold.sh answers --source "the calls page"
    return
  fi
  file="$WORK/decision-$home-$id.txt"
  {
    printf 'Captain answered this call on the calls page.\n'
    printf 'Task: %s\n' "$id"
    printf 'Answer: %s\n' "$answer"
    [ -z "$words" ] || printf "Captain's words: %s\n" "$words"
  } > "$file"
  if [ "$release" = 1 ]; then
    hold_in_home "$home" answer "$id" --decision-file "$file" --release
  else
    hold_in_home "$home" answer "$id" --decision-file "$file"
  fi
}

plus_week() {  # <YYYY-MM-DD>
  python3 -c 'import datetime, sys; print(datetime.date.fromisoformat(sys.argv[1]) + datetime.timedelta(days=7))' "$1"
}

# Fold a hold reason to the one-line, parenthesis-free form the hold contract
# requires, so the captain's own words can be recorded without failing the hold.
sanitize_reason() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '()'
}

# Tell firstmate about a recorded answer: one route line, and for a second
# mate also a send into its own home so it files any follow-up work.
route_line() {  # <home> <task> <text>
  local text
  text=$(printf '%s' "$3" | tr '\n\r\t' '   ')
  [ -n "$text" ] || text='(no words)'
  printf 'route: %s/%s %s\n' "$1" "$2" "$text"
}

# Send one recorded answer to a second mate. FM_HOME is passed explicitly
# because it is only a local default here, so a process-event run without it in
# the environment would otherwise leave fm-send refusing. A failed send is kept
# in UNDELIVERED and retried by the next apply.
try_send() {  # <home> <task> <text>
  FM_HOME="$FM_HOME" fm_run_timed "$REMOTE_TIMEOUT" "$FM_SEND" "fm-$1" "Call $2: $3" >/dev/null 2>"$WORK/send.err"
}

send_to_mate() {  # <home> <task> <text>
  local home=$1 task=$2 text=$3
  [ "$home" != local ] || return 0
  try_send "$home" "$task" "$text" || {
    printf '%s\t%s\t%s\n' "$home" "$task" "$text" >> "$UNDELIVERED"
    printf 'warning: the answer for %s/%s is recorded, but it was not sent to %s (kept for the next apply): %s\n' \
      "$home" "$task" "$home" "$(tail -1 "$WORK/send.err")" >&2
  }
  return 0
}

# Retry every answer recorded earlier whose send failed.
retry_undelivered() {
  local pending="$WORK/undelivered.pending" home task text
  [ -s "$UNDELIVERED" ] || return 0
  mv "$UNDELIVERED" "$pending"
  while IFS=$'\t' read -r home task text; do
    [ -n "$home" ] || continue
    if try_send "$home" "$task" "$text"; then
      printf 'delivered: %s/%s (answer recorded earlier)\n' "$home" "$task"
    else
      printf '%s\t%s\t%s\n' "$home" "$task" "$text" >> "$UNDELIVERED"
    fi
  done < "$pending"
}

# Answer text carried to firstmate for each recorded kind.
route_text() {  # <kind> <answer> <note>
  case "$1" in
    option) printf '%s' "$2" ;;
    not-needed) printf 'Not needed' ;;
    later) printf 'Later, park one week' ;;
    *) if [ -n "$3" ]; then printf '%s' "$3"; else printf '%s' "$2"; fi ;;
  esac
}

# Rebuild the page best effort: a failed rebuild is a warning, never a failed
# apply. bin/fm-captain-hold.sh's mutation hook is the same policy.
render_after_apply() {
  if ( do_render 2>"$WORK/apply-render.err" ); then
    [ -s "$WORK/apply-render.err" ] && cat "$WORK/apply-render.err" >&2
  else
    [ -s "$WORK/apply-render.err" ] && cat "$WORK/apply-render.err" >&2
    printf 'warning: the answers are recorded, but the calls page was not rebuilt\n' >&2
  fi
  return 0
}

cmd_apply() {
  local result=${1:-} items index item home call kind answer note task_kind release words until rc failed=0 lowered rtext talk_text
  [ "$#" -eq 1 ] && [ -n "$result" ] || { usage >&2; exit 2; }
  [ -f "$result" ] || die "result file does not exist: $result"
  start_work
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent-lavish.sh" read "$result" > "$WORK/read.txt" \
    || die "cannot read the captured result: $result"
  items=$(python3 "$HELPER" parse-result < "$WORK/read.txt") || die "cannot parse the captured result"
  retry_undelivered
  collect
  index=$(python3 "$HELPER" index "$WORK/manifest.jsonl" "$TODAY") || die "cannot list the open calls"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    home=$(jq -r .home <<<"$item")
    call=$(jq -r .call <<<"$item")
    kind=$(jq -r .kind <<<"$item")
    answer=$(jq -r .answer <<<"$item")
    note=$(jq -r .note <<<"$item")
    lowered=$(printf '%s|%s' "$answer" "$note" | tr '[:upper:]' '[:lower:]')
    if [ "$lowered" = "reconcile|" ] || [ "$lowered" = "|reconcile" ]; then
      printf 'refused: %s/%s (reconcile is reserved for re-checking a call, never an answer)\n' "$home" "$call"
      log_event --arg event apply --arg home "$home" --arg call "$call" --arg outcome refused-reconcile
      continue
    fi
    task_kind=$(jq -r --arg h "$home" --arg c "$call" 'select(.home == $h and .id == $c) | .kind' <<<"$index" | head -1)
    if [ -z "$task_kind" ]; then
      printf 'skipped: %s/%s (no longer open, nothing recorded)\n' "$home" "$call"
      log_event --arg event apply --arg home "$home" --arg call "$call" --arg outcome skipped-not-open
      continue
    fi
    if ! resolve_home "$home"; then
      printf 'skipped: %s/%s (no registered home by that name)\n' "$home" "$call"
      log_event --arg event apply --arg home "$home" --arg call "$call" --arg outcome skipped-unknown-home
      continue
    fi
    # Typed words with no option picked are a reply to raise, never a decision.
    if [ "$kind" = text ]; then
      [ -n "$note" ] || note=$answer
      if [ -z "$note" ]; then
        printf 'skipped: %s/%s (the save carried no answer)\n' "$home" "$call"
        continue
      fi
      kind=talk
    fi
    if [ "$kind" = talk ]; then
      if [ -n "$note" ]; then
        reason=$(jq -r --arg h "$home" --arg c "$call" 'select(.home == $h and .id == $c) | .reason' <<<"$index" | head -1)
        talk_reason=$(sanitize_reason "${reason:+$reason - }Captain asked to talk first on $TODAY: $note")
        rc=0
        hold_in_home "$home" hold "$call" --reason "$talk_reason" >"$WORK/out" 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
          printf 'applied: %s/%s talk\n' "$home" "$call"
          log_event --arg event apply --arg home "$home" --arg call "$call" --arg kind talk --arg outcome raised
        else
          failed=1
          printf 'failed: %s/%s talk (%s)\n' "$home" "$call" "$(tail -1 "$WORK/out")"
          log_event --arg event apply --arg home "$home" --arg call "$call" --arg kind talk --arg outcome failed \
            --arg error "$(tail -1 "$WORK/out")"
        fi
      else
        printf 'talk: %s/%s (raise it in chat; nothing recorded)\n' "$home" "$call"
        log_event --arg event apply --arg home "$home" --arg call "$call" --arg kind talk --arg outcome raised
      fi
      talk_text=$note
      [ -n "$talk_text" ] || talk_text="Let's talk about it first"
      route_line "$home" "$call" "$talk_text"
      continue
    fi
    release=0
    [ "$task_kind" = captain ] || release=1
    rc=0
    case "$kind" in
      later)
        until=$(plus_week "$TODAY")
        hold_in_home "$home" hold "$call" \
          --reason "Parked: captain chose Later on the calls page $TODAY. Do not ask again before $until." \
          --until "$until" >"$WORK/out" 2>&1 || rc=$?
        ;;
      not-needed)
        answer_in_home "$home" "$call" "Not needed" "$note" 0 >"$WORK/out" 2>&1 || rc=$?
        ;;
      option)
        answer_in_home "$home" "$call" "$answer" "$note" "$release" >"$WORK/out" 2>&1 || rc=$?
        ;;
      *)
        words=$note
        [ -n "$words" ] || words=$answer
        if [ -z "$words" ]; then
          printf 'skipped: %s/%s (the save carried no answer)\n' "$home" "$call"
          continue
        fi
        answer_in_home "$home" "$call" "$words" '' "$release" >"$WORK/out" 2>&1 || rc=$?
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      printf 'applied: %s/%s %s\n' "$home" "$call" "$kind"
      log_event --arg event apply --arg home "$home" --arg call "$call" --arg kind "$kind" --arg outcome applied
      rtext=$(route_text "$kind" "$answer" "$note")
      route_line "$home" "$call" "$rtext"
      send_to_mate "$home" "$call" "$rtext"
    else
      failed=1
      printf 'failed: %s/%s %s (%s)\n' "$home" "$call" "$kind" "$(tail -1 "$WORK/out")"
      log_event --arg event apply --arg home "$home" --arg call "$call" --arg kind "$kind" --arg outcome failed \
        --arg error "$(tail -1 "$WORK/out")"
    fi
  done <<EOF
$items
EOF
  render_after_apply
  [ "$failed" = 0 ]
}

case "${1:-}" in
  render) shift; cmd_render "$@" ;;
  arm) shift; cmd_arm "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
