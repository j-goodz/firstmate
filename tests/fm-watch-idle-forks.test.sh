#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-watch-idle-forks)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

SHIM_BIN="$TMP_ROOT/shim-bin"
FORK_LOG="$TMP_ROOT/fork.log"
mkdir -p "$SHIM_BIN"

# Capture real tools before we shadow PATH
REAL_DATE=$(command -v date)
REAL_STAT=$(command -v stat)
REAL_SLEEP=$(command -v sleep)
REAL_KILL=$(command -v kill)
REAL_WAIT=$(command -v wait)

TOOLS=(sleep date mktemp chmod mv rm stat ps tr tail cat sort git head wc mkdir touch sed awk perl uname dirname basename od shasum sha256sum cp ln find grep id readlink rmdir cut jq timeout)
for tool in "${TOOLS[@]}"; do
  real=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$real" ] || continue
  cat > "$SHIM_BIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\${1-}" >> "\$FM_FORK_LOG"
exec "$real" "\$@"
SH
  chmod +x "$SHIM_BIN/$tool"
done

log_count() { [ -f "$FORK_LOG" ] && wc -l < "$FORK_LOG" || echo 0; }

assert_idle_budget() {
  local label=$1 seconds=$2 budget=$3
  local before after used
  before=$(log_count)
  "$REAL_SLEEP" "$seconds"
  after=$(log_count)
  used=$((after - before))
  if [ "$used" -gt "$budget" ]; then
    tail -n +"$((before + 1))" "$FORK_LOG" 2>/dev/null | sort | uniq -c | sort -rn >&2
    fail "$label spawned $used helper processes in ${seconds}s (budget $budget)"
  else
    printf '# %s: %d helper processes in %ds\n' "$label" "$used" "$seconds"
  fi
}

make_home() {
  local name=$1
  local home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/config"
  : > "$home/state/.last-check"
  : > "$home/state/.last-heartbeat"
  printf 0 > "$home/state/.heartbeat-streak"
  printf '{}' > "$home/state/home-summary.json"
  mkdir -p "$home/state/pending-replies"
  local i
  for i in $(seq 1 300); do
    local corr_id
    corr_id=$(printf '%016x' $((i + 0x1000000000000000)))
    cat > "$home/state/pending-replies/$corr_id" <<EOF
schema=fm-pending-reply.v1
corr_id=$corr_id
task_id=mate1
phase=resolved
delivered_epoch=1
resolved_epoch=2
resolved_via=status
escalated_epoch=
EOF
  done
  echo "$home"
}

WATCH_PID=""
WATCH_POLL=2
start_watcher() {
  local home=$1 outfile=$2
  shift 2
  local extra_env=("$@")
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL="$WATCH_POLL" FM_SIGNAL_GRACE=1 \
      FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" PATH="$SHIM_BIN:$PATH" FM_FORK_LOG="$FORK_LOG" \
      "${extra_env[@]}" "$ROOT/bin/fm-watch.sh" > "$outfile" 2>&1 &
  WATCH_PID=$!
}

stop_watcher() {
  if [ -n "$WATCH_PID" ]; then
    "$REAL_KILL" "$WATCH_PID" 2>/dev/null || true
    "$REAL_WAIT" "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
  fi
}

cleanup() {
  stop_watcher
  fm_test_cleanup
}
trap cleanup EXIT

# ---------- Test 1: idle watcher spawns about nothing ----------
home1=$(make_home idle1)
out1="$TMP_ROOT/out1.log"
WATCH_POLL=2
start_watcher "$home1" "$out1"

# wait for beacon
for _ in {1..100}; do
  [ -f "$home1/state/.last-watcher-beat" ] && break
  "$REAL_SLEEP" 0.2
done
[ -f "$home1/state/.last-watcher-beat" ] || fail "watcher did not create beacon"

"$REAL_SLEEP" 6  # let startup settle
assert_idle_budget "an idle watcher" 8 2

# watcher still running?
"$REAL_KILL" -0 "$WATCH_PID" || fail "idle watcher exited unexpectedly"

# the watcher's own beacon write must not wake it more often than the poll interval
beats=$(
  last=""; n=0
  for _ in $(seq 1 50); do
    m=$("$REAL_STAT" -c %y "$home1/state/.last-watcher-beat" 2>/dev/null || echo 0)
    [ "$m" = "$last" ] || { n=$((n + 1)); last=$m; }
    "$REAL_SLEEP" 0.2
  done
  echo "$n"
)
[ "$beats" -le $((10 / WATCH_POLL + 2)) ] || fail "idle watcher woke $beats times in 10s (poll ${WATCH_POLL}s)"

# beacon fresh (<=5s)
beacon_ts=$("$REAL_STAT" -c %Y "$home1/state/.last-watcher-beat" 2>/dev/null || echo 0)
now_ts=$("$REAL_DATE" +%s)
[ $((now_ts - beacon_ts)) -le 5 ] || fail "beacon older than 5s"

pass "an idle watcher stays inside its process-spawn budget"

# ---------- Test 2: status event wakes promptly ----------
stop_watcher
# a killed watcher leaves a recovery marker that makes its successor wake at once, so use a fresh home
home2=$(make_home idle2)
out2="$TMP_ROOT/out2.log"
WATCH_POLL=30
start_watcher "$home2" "$out2"

for _ in {1..100}; do
  [ -f "$home2/state/.last-watcher-beat" ] && break
  "$REAL_SLEEP" 0.2
done
"$REAL_SLEEP" 6

T0=$SECONDS
printf 'done [at=1700000000]: finished\n' >> "$home2/state/crew1.status"

noticed=0
for _ in {1..60}; do
  if grep -q 'signal:' "$out2" 2>/dev/null; then
    noticed=1
    break
  fi
  "$REAL_SLEEP" 0.2
done
[ "$noticed" -eq 1 ] || fail "a status write was not noticed within 12s with a 30s poll"

elapsed=$((SECONDS - T0))
[ "$elapsed" -le 10 ] || fail "wake took ${elapsed}s (>10s)"

grep -q 'crew1.status' "$out2" || fail "output missing crew1.status reference"

# watcher exits after wake
"$REAL_WAIT" "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

pass "a status write wakes an idle watcher without waiting for the poll"

# ---------- Test 3: python3 inotify fallback ----------
if command -v python3 >/dev/null 2>&1; then
  # Test 3a: idle budget
  home3a=$(make_home idle3a)
  out3a="$TMP_ROOT/out3a.log"
  WATCH_POLL=2
  start_watcher "$home3a" "$out3a" FM_WATCH_EVENTS_NO_INOTIFYWAIT=1

  for _ in {1..100}; do
    [ -f "$home3a/state/.last-watcher-beat" ] && break
    "$REAL_SLEEP" 0.2
  done
  "$REAL_SLEEP" 6
  assert_idle_budget "an idle watcher on python inotify" 8 2
  "$REAL_KILL" -0 "$WATCH_PID" || fail "python inotify watcher exited"
  stop_watcher

  # Test 3b: prompt wake
  home3b=$(make_home idle3b)
  out3b="$TMP_ROOT/out3b.log"
  WATCH_POLL=30
  start_watcher "$home3b" "$out3b" FM_WATCH_EVENTS_NO_INOTIFYWAIT=1

  for _ in {1..100}; do
    [ -f "$home3b/state/.last-watcher-beat" ] && break
    "$REAL_SLEEP" 0.2
  done
  "$REAL_SLEEP" 6

  T0=$SECONDS
  printf 'done [at=1700000000]: finished\n' >> "$home3b/state/crew1.status"

  noticed=0
  for _ in {1..60}; do
    if grep -q 'signal:' "$out3b" 2>/dev/null; then
      noticed=1
      break
    fi
    "$REAL_SLEEP" 0.2
  done
  [ "$noticed" -eq 1 ] || fail "python inotify: status write not noticed within 12s"
  elapsed=$((SECONDS - T0))
  [ "$elapsed" -le 10 ] || fail "python inotify wake took ${elapsed}s (>10s)"
  grep -q 'crew1.status' "$out3b" || fail "python inotify output missing crew1.status"
  "$REAL_WAIT" "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=""

  pass "python inotify gives the same idle budget"
  pass "python inotify wakes on a status write"
else
  printf '# skipped: python3 unavailable\n'
fi

# ---------- Test 4: no inotify at all degrades to poll ----------
home4=$(make_home idle4)
out4="$TMP_ROOT/out4.log"
WATCH_POLL=2
start_watcher "$home4" "$out4" FM_WATCH_EVENTS_NO_INOTIFY=1

for _ in {1..100}; do
  [ -f "$home4/state/.last-watcher-beat" ] && break
  "$REAL_SLEEP" 0.2
done
"$REAL_SLEEP" 6

T0=$SECONDS
printf 'done [at=1700000000]: finished\n' >> "$home4/state/crew1.status"

noticed=0
for _ in {1..75}; do
  if grep -q 'signal:' "$out4" 2>/dev/null; then
    noticed=1
    break
  fi
  "$REAL_SLEEP" 0.2
done
[ "$noticed" -eq 1 ] || fail "without inotify watcher did not wake within 15s"

[ -s "$home4/state/.watch-events.fallback" ] || fail "fallback log missing or empty"

"$REAL_WAIT" "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

pass "without inotify the watcher still wakes on the poll and logs the fallback"

# ---------- Test 5: resolved pending-reply records cost nothing ----------
stop_watcher
# Use the idle1 fixture (300 resolved records)
home5="$TMP_ROOT/idle1/home"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_FORK_LOG="$FORK_LOG"
ORIG_PATH=$PATH
PATH="$SHIM_BIN:$PATH"
before=$(log_count)
fm_pending_reply_tick "$home5/state"
after=$(log_count)
PATH=$ORIG_PATH
used=$((after - before))
[ "$used" -le 3 ] || fail "a tick over resolved pending-reply records spawned $used helpers (budget 3)"

pass "a tick over resolved pending-reply records spawns nothing"

# ---------- Test 6: the event descriptor survives libraries that use fixed descriptors ----------
# fm-pr-lib.sh and others open and close descriptor 9 in the watcher's own shell; the event
# FIFO must never be one of the small fixed descriptors they use.
home6="$TMP_ROOT/idle6/state"
mkdir -p "$home6"
# shellcheck source=bin/fm-watch-events-lib.sh
. "$ROOT/bin/fm-watch-events-lib.sh"
fm_wev_init "$home6"
fm_wev_start || fail "the event monitor did not start for the descriptor check"
[ "${FM_WEV_FD:-0}" -ge 10 ] || fail "the event descriptor is $FM_WEV_FD, inside the range other libraries use"
exec 9< /dev/null
exec 9<&-
"$REAL_SLEEP" 1  # the monitor needs a moment to establish its watches
printf 'x\n' >> "$home6/t1.status"
fm_wev_wait 5 || fail "a status write was not seen after another library closed descriptor 9"
[ "$FM_WEV_SIG" = 1 ] || fail "the status write was not classified as a signal"
fm_wev_stop
pass "the event descriptor does not collide with fixed descriptors"

# cleanup trap will run