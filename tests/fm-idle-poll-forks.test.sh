#!/usr/bin/env bash
# Idle process-spawn budget for Firstmate's long-lived polling loops.
#
# An idle remote-job worker, an idle process-event owner watchdog and an idle
# remote reply long-poll must wait on events and spawn essentially nothing: at
# most one helper process in a multi-second idle window. The loops once polled
# every 0.05-0.2 seconds, forking a pipeline of helpers each time, and held a
# 2018 laptop at 30% CPU doing nothing.
#
# Every external helper the loops can call goes through a logging shim on PATH,
# so the count is deterministic and does not depend on what else the machine is
# doing. FM_IDLE_FORKS_SRC_BIN points the fixture at another copy of bin/ (for
# example an older checkout) to prove this test fails against the old loops.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SRC_BIN=${FM_IDLE_FORKS_SRC_BIN:-$ROOT/bin}
TMP_ROOT=$(fm_test_tmproot fm-idle-forks)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

MAX_IDLE_HELPERS=1
SETTLE_SECONDS=5
OBSERVE_SECONDS=6

SHIM_BIN="$TMP_ROOT/shim-bin"
FORK_LOG="$TMP_ROOT/fork.log"
mkdir -p "$SHIM_BIN"
: > "$FORK_LOG"
for tool in sleep date mktemp chmod mv rm stat ps tr tail cat sort git head wc mkdir touch \
  sed awk perl uname dirname basename od shasum sha256sum cp ln find grep id; do
  real=$(command -v "$tool" 2>/dev/null) || continue
  case "$real" in /*) ;; *) continue ;; esac
  cat > "$SHIM_BIN/$tool" <<SH
#!/bin/bash
printf '%s %s\\n' "$tool" "\${1-}" >> "\$FM_FORK_LOG"
exec "$real" "\$@"
SH
  chmod +x "$SHIM_BIN/$tool"
done

log_count() { wc -l < "$FORK_LOG" | tr -d ' '; }

# <label> <seconds>: fail when the log grew by more than the budget in the window.
assert_idle_budget() {
  local label=$1 seconds=$2 before after used
  before=$(log_count)
  sleep "$seconds"
  after=$(log_count)
  used=$((after - before))
  [ "$used" -le "$MAX_IDLE_HELPERS" ] || tail -n "+$((before + 1))" "$FORK_LOG" | sort | uniq -c | sort -rn | head -6 >&2
  [ "$used" -le "$MAX_IDLE_HELPERS" ] \
    || fail "$label spawned $used helper processes in ${seconds}s (budget $MAX_IDLE_HELPERS)"
  printf '# %s: %s helper processes in %ss\n' "$label" "$used" "$seconds"
}

# --- remote job worker -------------------------------------------------------
REMOTE_ROOT="$TMP_ROOT/remote-root"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT_HOME"
cp "$SRC_BIN/fm-remote-job-lib.sh" "$SRC_BIN/fm-remote-job-worker.sh" \
  "$SRC_BIN/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"

WORKER_PID=
cleanup_idle_forks() {
  [ -z "$WORKER_PID" ] || kill "$WORKER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_idle_forks EXIT

HOME="$ACCOUNT_HOME" PATH="$SHIM_BIN:$PATH" FM_FORK_LOG="$FORK_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
WORKER_PID=$!
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
[ -f "$STATE_ROOT/worker.ready" ] || fail "the idle worker fixture never published its heartbeat"
sleep "$SETTLE_SECONDS"
assert_idle_budget "an idle remote job worker" "$OBSERVE_SECONDS"
kill -0 "$WORKER_PID" 2>/dev/null || fail "the idle worker exited during the observation window"
pass "an idle remote job worker stays inside its process-spawn budget"

# The readiness probe reads only the heartbeat's mtime, so a backdated heartbeat
# must be refreshed within the probe's freshness window.
touch -t 200001010000 "$STATE_ROOT/worker.ready"
for _ in $(seq 1 60); do
  [ -n "$(find "$STATE_ROOT/worker.ready" -mmin -1 2>/dev/null)" ] && break
  sleep 0.1
done
[ -n "$(find "$STATE_ROOT/worker.ready" -mmin -1 2>/dev/null)" ] \
  || fail "the idle worker stopped refreshing its heartbeat"
[ "$(cat "$STATE_ROOT/worker.ready")" = "$(cat "$STATE_ROOT/worker.pid")" ] \
  || fail "the heartbeat no longer names the worker pid"
pass "the quiet worker still refreshes its readiness heartbeat"

# Each section below measures its own loop, so the worker is stopped first.
kill "$WORKER_PID" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true
WORKER_PID=

# --- reply long-poll ---------------------------------------------------------
REPLY_HOME="$TMP_ROOT/reply-home"
mkdir -p "$REPLY_HOME/state"
: > "$REPLY_HOME/state/parent-replies.status"
if command -v shasum >/dev/null 2>&1; then
  EMPTY_SHA=$(: | shasum -a 256 | awk '{print $1}')
else
  EMPTY_SHA=$(: | sha256sum | awk '{print $1}')
fi
FM_HOME="$REPLY_HOME" PATH="$SHIM_BIN:$PATH" FM_FORK_LOG="$FORK_LOG" \
  "$REMOTE_ROOT/bin/fm-remote-delta-read.sh" state/parent-replies.status 0 "$EMPTY_SHA" 14 \
  < /dev/null > /dev/null 2>&1 &
POLL_PID=$!
sleep 3
assert_idle_budget "an idle reply long-poll" 8
wait "$POLL_PID" 2>/dev/null
[ "$?" -eq 75 ] || fail "the idle reply long-poll did not end with its empty-window exit"
pass "an idle reply long-poll stays inside its process-spawn budget"

# A line appended while the poll is asleep must still be delivered promptly.
FM_HOME="$REPLY_HOME" "$REMOTE_ROOT/bin/fm-remote-delta-read.sh" \
  state/parent-replies.status 0 "$EMPTY_SHA" 8 < /dev/null > "$TMP_ROOT/delta.out" 2>&1 &
DELTA_PID=$!
sleep 2.5
DELTA_APPENDED=$SECONDS
printf 'first line\n' >> "$REPLY_HOME/state/parent-replies.status"
wait "$DELTA_PID" || fail "the delta read did not return the appended line"
[ $((SECONDS - DELTA_APPENDED)) -le 3 ] || fail "an appended reply line took more than 3s to be delivered"
grep -q 'status=delta' "$TMP_ROOT/delta.out" || fail "the delta read reported no delta for the appended line"
pass "an appended reply line is still delivered while the poll idles"

# Without inotifywait (swift and zentop) python3's inotify is the event source:
# one watch process, no spawned helpers while idle, and prompt delivery.
FM_REMOTE_DELTA_NO_INOTIFYWAIT=1 FM_REMOTE_DELTA_FALLBACK_LOG="$TMP_ROOT/python-fallback.log" \
  FM_HOME="$REPLY_HOME" PATH="$SHIM_BIN:$PATH" FM_FORK_LOG="$FORK_LOG" \
  "$REMOTE_ROOT/bin/fm-remote-delta-read.sh" state/parent-replies.status 11 \
  "$(head -c 11 "$REPLY_HOME/state/parent-replies.status" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}')" 12 \
  < /dev/null > "$TMP_ROOT/python.out" 2>&1 &
PYTHON_POLL_PID=$!
sleep 3
assert_idle_budget "an idle reply long-poll on python inotify" 6
printf 'python line\n' >> "$REPLY_HOME/state/parent-replies.status"
wait "$PYTHON_POLL_PID" || fail "the python-inotify delta read did not return the appended line"
grep -q 'status=delta' "$TMP_ROOT/python.out" || fail "the python-inotify delta read reported no delta"
[ ! -s "$TMP_ROOT/python-fallback.log" ] || fail "python inotify was available but the reader logged a polling fallback"
pass "python inotify gives an event-driven reply wait with nothing spawned"
# the fallback section below appends to the same log, so restore its line count
: > "$REPLY_HOME/state/parent-replies.status"
printf 'first line\n' >> "$REPLY_HOME/state/parent-replies.status"

# Without inotifywait or python the wait degrades to a builtin once-per-second mtime check:
# still no helper processes, still prompt delivery, and the fallback is logged.
FALLBACK_LOG="$TMP_ROOT/fallback.log"
FM_REMOTE_DELTA_NO_INOTIFY=1 FM_REMOTE_DELTA_FALLBACK_LOG="$FALLBACK_LOG" \
  FM_HOME="$REPLY_HOME" PATH="$SHIM_BIN:$PATH" FM_FORK_LOG="$FORK_LOG" \
  "$REMOTE_ROOT/bin/fm-remote-delta-read.sh" state/parent-replies.status 11 \
  "$(head -c 11 "$REPLY_HOME/state/parent-replies.status" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}')" 12 \
  < /dev/null > "$TMP_ROOT/fallback.out" 2>&1 &
FALLBACK_PID=$!
sleep 3
assert_idle_budget "an idle reply long-poll without inotifywait" 6
printf 'second line\n' >> "$REPLY_HOME/state/parent-replies.status"
wait "$FALLBACK_PID" || fail "the fallback delta read did not return the appended line"
grep -q 'status=delta' "$TMP_ROOT/fallback.out" || fail "the fallback delta read reported no delta"
grep -q 'no inotifywait' "$FALLBACK_LOG" || fail "the polling fallback was not logged"
pass "the polling fallback spawns nothing, delivers promptly and is logged"

# --- process-event owner watchdog -------------------------------------------
HOME_DIR="$TMP_ROOT/pe-home"
mkdir -p "$HOME_DIR/state"
fm_test_track_procevent_home "$HOME_DIR"
STUB="$TMP_ROOT/idle-source.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
exec /bin/sleep 600
SH
chmod +x "$STUB"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" register lavish idle-src -- "$STUB" > /dev/null \
  || fail "the watchdog fixture source did not register"
# A six-second check interval wakes the guard every three seconds, so the window
# proves the wakes themselves spawn nothing; its one full check (process table,
# state root, lease) happens inside the settle time and the next is a lease away.
FM_PROCEVENT_OWNER_CHECK_SECONDS=6 FM_HOME="$HOME_DIR" PATH="$SHIM_BIN:$PATH" FM_FORK_LOG="$FORK_LOG" \
  "$ROOT/bin/fm-procevent.sh" reconcile > /dev/null 2>&1 || true
sleep "$SETTLE_SECONDS"
[ "$(pgrep -f "_owner-watchdog idle-src" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] \
  || fail "the fixture source started no owner watchdog"
assert_idle_budget "an idle owner watchdog" "$OBSERVE_SECONDS"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" retire idle-src > /dev/null 2>&1 || true
pass "an idle owner watchdog stays inside its process-spawn budget"
