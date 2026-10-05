#!/usr/bin/env bash
# fm-idle-session-reap.sh - close agent sessions that are idle AND finished or
# ownerless, across every Firstmate home and Herdr session on this machine.
#
# Usage: fm-idle-session-reap.sh [--apply] [--idle-minutes N]
#        fm-idle-session-reap.sh install-timer
#        fm-idle-session-reap.sh uninstall-timer
#        fm-idle-session-reap.sh --help
#
#   (no flag)        dry run: decide and log every pane, change nothing.
#   --apply          act on the decisions: one attempt per pane, no retry.
#   --idle-minutes N idle window (default 30).
#   install-timer    write and enable an hourly systemd user timer that runs
#                    this exact script with --apply (Linux with systemd only).
#                    The unit records the homes discovered now in
#                    FM_IDLE_REAP_HOMES so the hourly run does not rely on
#                    rediscovery under its own $HOME.
#   uninstall-timer  disable and remove that timer.
#
# Why this exists. Firstmate closes a lane's terminal only at cleanup, and a
# lane parked as paused, deferred behind a cleanup collision, or left after a
# lost record never reaches cleanup. Its agent keeps running idle for hours and
# burns CPU, which a heat- or memory-gated machine pays for in working lanes.
# This pass is the hourly backstop. It never removes a worktree, a branch, a
# record, or uncommitted work: an owned lane's agent is stopped through the
# owning home's own control plane (bin/fm-control.sh exit, which preserves the
# endpoint and every change), and only a pane no record claims is closed.
#
# Scope. Every running Herdr session except fm-lab-* test labs. Homes are the
# directories directly under $HOME holding bin/fm-spawn.sh, state/ and
# AGENTS.md (FM_IDLE_REAP_HOMES, colon-separated, overrides discovery). A
# pane is a candidate only when Herdr reports an agent in it and its tab label
# is a Firstmate lane label (fm-<task>); every other pane is left alone.
#
# Decision, in order, per pane. The first rule that matches is logged.
#   no-agent                 Herdr reports no agent in the pane.
#   working                  Herdr reports the agent working.
#   supervisor-pane          the workspace is a supervisor's ("firstmate" or
#                            "2ndmate-<id>"), or the lane id is a secondmate:
#                            a kind=secondmate record in any local home or a
#                            home's .fm-secondmate-home marker.
#   not-a-firstmate-lane     the tab label is not fm-<task>.
#   agent-stopped            the pane provably holds only an idle shell (Herdr
#                            keeps the last agent label after an agent exits).
#   ambiguous-owner          more than one local record claims the pane.
#   Owned (exactly one record claims session+pane):
#     remote-record          the record lives on another machine.
#     recent-activity        the newest of the task's turn-ended, progress,
#                            busy-state, status and meta files is younger than
#                            the idle window.
#     in-flight:<state>      the owning home's bin/fm-crew-state.sh reports a
#                            state other than done or failed; paused counts as
#                            finished only when no validation run owns it
#                            (in-flight:paused-validation otherwise).
#     focused-with-viewer    the pane is focused and a viewer is attached or
#                            cannot be ruled out.
#     scout-no-report        a scout without data/<task>/report.md.
#     uncommitted-work, unlanded-commits, worktree-missing,
#     worktree-unreadable    the recorded worktree is dirty, has commits no
#                            remote-tracking ref contains, or cannot be read.
#     finished-idle          acted on: exited through the owning home's
#                            fm-control.sh, and a note: line naming this pass
#                            is appended to the task's status log.
#   Ownerless (no record claims the pane):
#     no-owner-home          no Firstmate home was discovered at all, so the
#                            pane's owner cannot be judged: never closed.
#     first-sight-idle, activity-seen
#                            observed: the screen fingerprint is new or
#                            changed, so the idle clock (re)starts now. The
#                            clock lives in FM_IDLE_REAP_SEEN, so an ownerless
#                            pane closes at the first run at least the idle
#                            window after it stopped changing.
#     recent-activity        unchanged for less than the idle window.
#     focused-with-viewer, uncommitted-work, unlanded-commits
#                            as above, for the git tree the pane sits in.
#     composer-<verdict>     the agent's input box is not proven empty.
#     ownerless-idle         acted on: the exact pane is closed.
#
# Output. One JSON line per pane decision and one run summary line, appended
# to FM_IDLE_REAP_LOG (default ~/.nexus/session-reaper.jsonl). Actions are
# observed, skipped, exited, closed, failed, and would-exit / would-close in a
# dry run. Runs are serialized by FM_IDLE_REAP_LOCK; an overlapping run logs
# result=overlap and exits 0.
#
# Environment: FM_IDLE_REAP_HOMES, FM_IDLE_REAP_LOG, FM_IDLE_REAP_SEEN,
# FM_IDLE_REAP_LOCK, FM_IDLE_REAP_NOW (epoch, for tests),
# FM_IDLE_REAP_SYSTEMD_DIR (unit directory for install-timer).
# FM_IDLE_REAP_SOURCE_ONLY=1 defines the functions without running.
set -u

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR=${SCRIPT_PATH%/*}
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# The libraries resolve a home for their own defaults; this pass names every
# home it touches explicitly and never acts on this default.
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_IDLE_REAP_UNIT=fm-idle-session-reap

fm_idle_reap_usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$SCRIPT_PATH"
}

# --- seams: the only Herdr reads and the only pane mutation -----------------

fm_idle_reap_herdr_sessions() {
  herdr session list --json 2>/dev/null | jq -r '.sessions[]? | select(.running == true) | .name'
}

fm_idle_reap_snapshot() {  # <session>
  fm_backend_herdr_cli "$1" api snapshot 2>/dev/null
}

fm_idle_reap_fingerprint() {  # <session> <pane>
  local cap
  cap=$(fm_backend_herdr_capture "$1:$2" 60 2>/dev/null) || return 1
  [ -n "$cap" ] || return 1
  printf '%s' "$cap" | fm_idle_reap_screen_digest
}

# Digest of a screen on stdin with spinner glyphs (Braille patterns and the
# quarter-circle set) removed: a tool left in a running state animates a
# spinner forever, and that frame change is not activity.
fm_idle_reap_screen_digest() {
  perl -CSD -pe 's/[\x{2800}-\x{28FF}\x{25D0}-\x{25D3}]//g' | cksum | awk '{print $1 "-" $2}'
}

fm_idle_reap_composer_state() {  # <session> <pane>
  fm_backend_herdr_composer_state "$1:$2"
}

# Herdr keeps a pane's last agent label after the agent exits, so the label
# alone cannot say an agent still runs; the backend's idle-shell proof can.
fm_idle_reap_agent_stopped() {  # <session> <pane>
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=3 fm_backend_herdr_pane_idle_shell_pid "$1" "$2" >/dev/null 2>&1
}

fm_idle_reap_viewer_present() {  # <session>; unknown counts as present
  local rc=0
  fm_backend_herdr_foreground_client_present "$1" || rc=$?
  [ "$rc" != 1 ]
}

fm_idle_reap_close_pane() {  # <session> <pane>
  fm_backend_herdr_kill "$1:$2" >/dev/null 2>&1 || true
  fm_backend_herdr_endpoint_confirmed_gone "$1:$2"
}

# --- inventory ---------------------------------------------------------------

fm_idle_reap_homes() {
  local d real seen=$'\n'
  if [ -n "${FM_IDLE_REAP_HOMES:-}" ]; then
    printf '%s\n' "$FM_IDLE_REAP_HOMES" | tr ':' '\n' | awk 'NF'
    return 0
  fi
  for d in "$HOME"/*/; do
    d=${d%/}
    [ -f "$d/bin/fm-spawn.sh" ] && [ -d "$d/state" ] && [ -f "$d/AGENTS.md" ] || continue
    real=$(cd "$d" 2>/dev/null && pwd -P) || continue
    case "$seen" in *$'\n'"$real"$'\n'*) continue ;; esac
    seen="$seen$real"$'\n'
    printf '%s\n' "$real"
  done
}

# Writes CLAIMS (session|pane<TAB>home<TAB>task) and SECONDMATES (one id per
# line) for every local home.
fm_idle_reap_index() {  # <claims-file> <secondmates-file>
  local claims=$1 mates=$2 home meta id kind session pane window marker
  : > "$claims"
  : > "$mates"
  HOMES_FOUND=0
  while IFS= read -r home; do
    [ -d "$home/state" ] || continue
    HOMES_FOUND=$((HOMES_FOUND + 1))
    marker="$home/$FM_BACKEND_HERDR_SECONDMATE_MARKER"
    if [ -f "$marker" ]; then
      id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
      [ -z "$id" ] || printf '%s\n' "$id" >> "$mates"
    fi
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}
      id=${id%.meta}
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || printf '%s\n' "$id" >> "$mates"
      session=$(fm_meta_get "$meta" herdr_session)
      pane=$(fm_meta_get "$meta" herdr_pane_id)
      if [ -z "$session" ] || [ -z "$pane" ]; then
        window=$(fm_meta_get "$meta" window)
        session=${window%%:*}
        pane=${window#*:}
        case "$pane" in w*:p*) ;; *) continue ;; esac
      fi
      printf '%s|%s\t%s\t%s\n' "$session" "$pane" "$home" "$id" >> "$claims"
    done
  done < <(fm_idle_reap_homes)
}

# One record per pane, fields joined by the ASCII unit separator (a tab would
# collapse an empty agent field under read): pane agent status focused cwd tab
# workspace.
fm_idle_reap_panes() {  # <session>
  fm_idle_reap_snapshot "$1" | jq -r '
    .result.snapshot as $s
    | (($s.tabs // []) | map({(.tab_id): (.label // "")}) | add // {}) as $t
    | (($s.workspaces // []) | map({(.workspace_id): (.label // "")}) | add // {}) as $w
    | ($s.panes // [])[]
    | [.pane_id, (.agent // ""), (.agent_status // ""), (if .focused then "1" else "0" end),
       (.foreground_cwd // .cwd // ""), ($t[.tab_id] // ""), ($w[.workspace_id] // "")]
    | map(tostring | gsub("[\u001f\n]"; " "))
    | join("\u001f")'
}

# --- evidence ----------------------------------------------------------------

# Prints nothing when <dir> holds no unlanded work, else the reason.
fm_idle_reap_work_state() {  # <git-dir>
  local dir=$1 dirty head contained
  [ -d "$dir" ] || { printf 'worktree-missing'; return 0; }
  dirty=$(git -C "$dir" status --porcelain 2>/dev/null) || { printf 'worktree-unreadable'; return 0; }
  [ -z "$dirty" ] || { printf 'uncommitted-work'; return 0; }
  head=$(git -C "$dir" rev-parse --verify -q HEAD 2>/dev/null) || { printf 'worktree-unreadable'; return 0; }
  contained=$(git -C "$dir" for-each-ref --contains "$head" --count=1 --format='%(refname)' refs/remotes 2>/dev/null)
  [ -n "$contained" ] || printf 'unlanded-commits'
}

fm_idle_reap_last_activity() {  # <home> <task>
  local f m newest=0
  for f in "$1/state/$2".turn-ended "$1/state/$2".progress "$1/state/$2".busy-state \
           "$1/state/$2".status "$1/state/$2".meta; do
    [ -e "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
    [ "$m" -le "$newest" ] || newest=$m
  done
  printf '%s' "$newest"
}

# --- log ---------------------------------------------------------------------

fm_idle_reap_log_pane() {  # <action> <reason> [idle_s] [detail]
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson epoch "$NOW" --arg host "$HOST" \
    --arg mode "$MODE" --arg session "$P_SESSION" --arg pane "$P_PANE" --arg tab "$P_TAB" \
    --arg agent "$P_AGENT" --arg agent_status "$P_STATUS" --arg home "${P_HOME:-}" \
    --arg task "${P_TASK:-}" --arg action "$1" --arg reason "$2" --arg idle "${3:-}" \
    --arg detail "${4:-}" '
    {ts:$ts, epoch:$epoch, host:$host, event:"pane", mode:$mode, session:$session,
     pane:$pane, tab:$tab, agent:$agent, agent_status:$agent_status, home:$home,
     task:$task, action:$action, reason:$reason,
     idle_s:(if $idle == "" then null else ($idle | tonumber) end), detail:$detail}' \
    >> "$LOG" 2>/dev/null || true
  case "$1" in
    exited|closed|would-exit|would-close) ACTED=$((ACTED + 1)) ;;
    failed) FAILED=$((FAILED + 1)) ;;
    *) KEPT=$((KEPT + 1)) ;;
  esac
  printf '%s %s:%s %s %s %s\n' "$1" "$P_SESSION" "$P_PANE" "$P_TAB" "$2" "${4:-}"
}

fm_idle_reap_log_run() {  # <result>
  local end_ms
  end_ms=$(fm_idle_reap_ms)
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson epoch "$NOW" --arg host "$HOST" \
    --arg mode "$MODE" --arg result "$1" --argjson panes "$PANES" --argjson acted "$ACTED" \
    --argjson kept "$KEPT" --argjson failed "$FAILED" --argjson window "$WINDOW" \
    --argjson duration "$((end_ms - START_MS))" '
    {ts:$ts, epoch:$epoch, host:$host, event:"run", mode:$mode, result:$result,
     panes:$panes, acted:$acted, kept:$kept, failed:$failed, idle_window_s:$window,
     duration_ms:$duration}' >> "$LOG" 2>/dev/null || true
}

fm_idle_reap_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null)
  case "$ms" in *N|'') printf '%s000' "$(date +%s)" ;; *) printf '%s' "$ms" ;; esac
}

# --- decisions ---------------------------------------------------------------

fm_idle_reap_owned() {  # <home> <task>
  local home=$1 id=$2 meta last idle crew state source kind wt why out rc
  meta="$home/state/$id.meta"
  P_HOME=$home
  P_TASK=$id
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    fm_idle_reap_log_pane skipped remote-record
    return 0
  fi
  last=$(fm_idle_reap_last_activity "$home" "$id")
  idle=$((NOW - last))
  if [ "$idle" -lt "$WINDOW" ]; then
    fm_idle_reap_log_pane skipped recent-activity "$idle"
    return 0
  fi
  crew=$(cd "$home" && FM_HOME="$home" FM_CREW_STATE_NO_FORGE=1 \
    fm_run_timed 90 "$home/bin/fm-crew-state.sh" "$id" 2>/dev/null | head -n 1)
  state=${crew#state: }
  state=${state%% *}
  source=${crew#*source: }
  source=${source%% *}
  [ -n "$crew" ] && [ "$state" != "$crew" ] || state=unknown
  case "$state" in
    done|failed) ;;
    paused)
      if [ "$source" = run-step ]; then
        fm_idle_reap_log_pane skipped in-flight:paused-validation "$idle" "$crew"
        return 0
      fi
      ;;
    *)
      fm_idle_reap_log_pane skipped "in-flight:$state" "$idle" "$crew"
      return 0
      ;;
  esac
  if [ "$P_FOCUSED" = 1 ] && fm_idle_reap_viewer_present "$P_SESSION"; then
    fm_idle_reap_log_pane skipped focused-with-viewer "$idle"
    return 0
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" = scout ]; then
    if [ ! -f "$home/data/$id/report.md" ]; then
      fm_idle_reap_log_pane skipped scout-no-report "$idle"
      return 0
    fi
  else
    wt=$(fm_meta_get "$meta" worktree)
    why=$(fm_idle_reap_work_state "$wt")
    if [ -n "$why" ]; then
      fm_idle_reap_log_pane skipped "$why" "$idle" "$wt"
      return 0
    fi
  fi
  if [ "$MODE" != apply ]; then
    fm_idle_reap_log_pane would-exit finished-idle "$idle" "$crew"
    return 0
  fi
  rc=0
  out=$(cd "$home" && FM_HOME="$home" fm_run_timed 180 "$home/bin/fm-control.sh" "$id" exit 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    fm_idle_reap_log_pane failed control-exit-failed "$idle" "rc=$rc $(printf '%s' "$out" | tail -n 1)"
    return 0
  fi
  printf 'note [at=%s]: idle-session-reaper stopped this idle finished agent after %sm with no turn (%s); the local copy and branch are untouched; relaunch it with fm-control.sh %s relaunch if more work is needed\n' \
    "$NOW" "$((idle / 60))" "$state" "$id" >> "$home/state/$id.status" 2>/dev/null || true
  fm_idle_reap_log_pane exited finished-idle "$idle" "$crew"
}

fm_idle_reap_ownerless() {
  local key fp prev first prev_fp idle top why verdict
  if [ "${HOMES_FOUND:-0}" -eq 0 ]; then
    fm_idle_reap_log_pane skipped no-owner-home
    return 0
  fi
  key="$P_SESSION|$P_PANE"
  if ! fp=$(fm_idle_reap_fingerprint "$P_SESSION" "$P_PANE") || [ -z "$fp" ]; then
    fm_idle_reap_log_pane skipped screen-unreadable
    return 0
  fi
  fp="$P_STATUS:$fp"
  prev=$(awk -F'\t' -v k="$key" '$1 == k { print $2 "\t" $3; exit }' "$SEEN" 2>/dev/null)
  first=${prev%%$'\t'*}
  prev_fp=${prev#*$'\t'}
  if [ -z "$prev" ] || [ "$prev_fp" != "$fp" ]; then
    printf '%s\t%s\t%s\n' "$key" "$NOW" "$fp" >> "$SEEN_NEXT"
    if [ -z "$prev" ]; then
      fm_idle_reap_log_pane observed first-sight-idle 0
    else
      fm_idle_reap_log_pane observed activity-seen 0
    fi
    return 0
  fi
  idle=$((NOW - first))
  if [ "$idle" -lt "$WINDOW" ]; then
    printf '%s\t%s\t%s\n' "$key" "$first" "$fp" >> "$SEEN_NEXT"
    fm_idle_reap_log_pane skipped recent-activity "$idle"
    return 0
  fi
  # Every later refusal keeps the idle clock so a cleared guard acts next run.
  printf '%s\t%s\t%s\n' "$key" "$first" "$fp" >> "$SEEN_NEXT"
  if [ "$P_FOCUSED" = 1 ] && fm_idle_reap_viewer_present "$P_SESSION"; then
    fm_idle_reap_log_pane skipped focused-with-viewer "$idle"
    return 0
  fi
  if [ -n "$P_CWD" ] && top=$(git -C "$P_CWD" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ]; then
    why=$(fm_idle_reap_work_state "$top")
    if [ -n "$why" ]; then
      fm_idle_reap_log_pane skipped "$why" "$idle" "$top"
      return 0
    fi
  fi
  verdict=$(fm_idle_reap_composer_state "$P_SESSION" "$P_PANE" 2>/dev/null)
  if [ "$verdict" != empty ]; then
    fm_idle_reap_log_pane skipped "composer-${verdict:-unknown}" "$idle"
    return 0
  fi
  if [ "$MODE" != apply ]; then
    fm_idle_reap_log_pane would-close ownerless-idle "$idle"
    return 0
  fi
  if fm_idle_reap_close_pane "$P_SESSION" "$P_PANE"; then
    fm_idle_reap_log_pane closed ownerless-idle "$idle"
  else
    fm_idle_reap_log_pane failed close-unconfirmed "$idle"
  fi
}

fm_idle_reap_pane() {
  local lane claims count home id
  P_HOME=
  P_TASK=
  if [ -z "$P_AGENT" ]; then
    fm_idle_reap_log_pane skipped no-agent
    return 0
  fi
  if [ "$P_STATUS" = working ]; then
    fm_idle_reap_log_pane skipped working
    return 0
  fi
  case "$P_WS" in
    firstmate|2ndmate-*)
      fm_idle_reap_log_pane skipped supervisor-pane
      return 0
      ;;
  esac
  case "$P_TAB" in
    fm-?*) lane=${P_TAB#fm-} ;;
    *)
      fm_idle_reap_log_pane skipped not-a-firstmate-lane
      return 0
      ;;
  esac
  if grep -Fxq -- "$lane" "$MATES" 2>/dev/null; then
    fm_idle_reap_log_pane skipped supervisor-pane
    return 0
  fi
  if fm_idle_reap_agent_stopped "$P_SESSION" "$P_PANE"; then
    fm_idle_reap_log_pane skipped agent-stopped
    return 0
  fi
  claims=$(awk -F'\t' -v k="$P_SESSION|$P_PANE" '$1 == k { print $2 "\t" $3 }' "$CLAIMS")
  count=$(printf '%s' "$claims" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$count" -gt 1 ]; then
    fm_idle_reap_log_pane skipped ambiguous-owner "" "$(printf '%s' "$claims" | tr '\t\n' ': ')"
    return 0
  fi
  if [ "$count" = 1 ]; then
    home=${claims%%$'\t'*}
    id=${claims#*$'\t'}
    fm_idle_reap_owned "$home" "$id"
    return 0
  fi
  fm_idle_reap_ownerless
}

# --- entry points ------------------------------------------------------------

fm_idle_reap_main() {
  local arg minutes=30 session work rc
  MODE=dry-run
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --apply) MODE=apply ;;
      --idle-minutes)
        minutes=${1:-}
        shift || true
        case "$minutes" in ''|*[!0-9]*|0) echo "error: --idle-minutes needs a positive integer" >&2; return 2 ;; esac
        ;;
      -h|--help) fm_idle_reap_usage; return 0 ;;
      *) echo "error: unknown argument '$arg' (see --help)" >&2; return 2 ;;
    esac
  done
  NOW=${FM_IDLE_REAP_NOW:-$(date +%s)}
  WINDOW=$((minutes * 60))
  HOST=$(hostname -s 2>/dev/null || hostname)
  LOG=${FM_IDLE_REAP_LOG:-$HOME/.nexus/session-reaper.jsonl}
  SEEN=${FM_IDLE_REAP_SEEN:-$HOME/.nexus/session-reaper-seen.tsv}
  LOCK=${FM_IDLE_REAP_LOCK:-$HOME/.nexus/session-reaper.lock}
  START_MS=$(fm_idle_reap_ms)
  PANES=0 ACTED=0 KEPT=0 FAILED=0
  mkdir -p "${LOG%/*}" "${SEEN%/*}" "${LOCK%/*}" 2>/dev/null || true

  if ! fm_lock_try_acquire "$LOCK"; then
    echo "another reaper run holds $LOCK; skipping"
    fm_idle_reap_log_run overlap
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    fm_lock_release "$LOCK"
    echo "error: jq is required" >&2
    return 1
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-idle-reap.XXXXXX") || { fm_lock_release "$LOCK"; return 1; }
  CLAIMS="$work/claims"
  MATES="$work/mates"
  SEEN_NEXT="$work/seen"
  : > "$SEEN_NEXT"
  fm_idle_reap_index "$CLAIMS" "$MATES"

  rc=0
  while IFS= read -r session; do
    case "$session" in ''|fm-lab-*) continue ;; esac
    while IFS=$'\x1f' read -r P_PANE P_AGENT P_STATUS P_FOCUSED P_CWD P_TAB P_WS; do
      [ -n "$P_PANE" ] || continue
      P_SESSION=$session
      PANES=$((PANES + 1))
      fm_idle_reap_pane
    done < <(fm_idle_reap_panes "$session")
  done < <(fm_idle_reap_herdr_sessions)

  mv -f "$SEEN_NEXT" "$SEEN" 2>/dev/null || rc=1
  fm_idle_reap_log_run ok
  rm -rf "$work"
  fm_lock_release "$LOCK"
  printf 'summary: mode=%s panes=%s acted=%s kept=%s failed=%s log=%s\n' \
    "$MODE" "$PANES" "$ACTED" "$KEPT" "$FAILED" "$LOG"
  return "$rc"
}

fm_idle_reap_install_timer() {
  local dir=${FM_IDLE_REAP_SYSTEMD_DIR:-$HOME/.config/systemd/user}
  local home homes='' env_homes=''
  command -v systemctl >/dev/null 2>&1 || {
    echo "error: install-timer needs systemd (systemctl not found); schedule '$SCRIPT_PATH --apply' hourly another way" >&2
    return 1
  }
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    homes=${homes:+$homes:}$home
  done < <(fm_idle_reap_homes)
  [ -z "$homes" ] || env_homes="Environment=\"FM_IDLE_REAP_HOMES=$homes\""
  mkdir -p "$dir" || return 1
  cat > "$dir/$FM_IDLE_REAP_UNIT.service" <<EOF
[Unit]
Description=Firstmate idle session reaper: stop idle finished agent sessions (one pass)

[Service]
Type=oneshot
Environment="PATH=$PATH"
$env_homes
ExecStart=$SCRIPT_PATH --apply
Nice=10
TimeoutStartSec=20min
EOF
  cat > "$dir/$FM_IDLE_REAP_UNIT.timer" <<EOF
[Unit]
Description=Run the Firstmate idle session reaper every hour

[Timer]
OnCalendar=hourly
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload || return 1
  systemctl --user enable --now "$FM_IDLE_REAP_UNIT.timer" || return 1
  echo "installed $dir/$FM_IDLE_REAP_UNIT.timer (hourly) running $SCRIPT_PATH --apply"
}

fm_idle_reap_uninstall_timer() {
  local dir=${FM_IDLE_REAP_SYSTEMD_DIR:-$HOME/.config/systemd/user}
  systemctl --user disable --now "$FM_IDLE_REAP_UNIT.timer" 2>/dev/null || true
  rm -f "$dir/$FM_IDLE_REAP_UNIT.timer" "$dir/$FM_IDLE_REAP_UNIT.service"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "removed $FM_IDLE_REAP_UNIT timer and service from $dir"
}

if [ "${FM_IDLE_REAP_SOURCE_ONLY:-}" != 1 ]; then
  case "${1:-}" in
    install-timer) fm_idle_reap_install_timer ;;
    uninstall-timer) fm_idle_reap_uninstall_timer ;;
    *) fm_idle_reap_main "$@" ;;
  esac
  exit $?
fi
