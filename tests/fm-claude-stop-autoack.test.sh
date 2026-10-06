#!/usr/bin/env bash
# tests/fm-claude-stop-autoack.test.sh - behavior tests for the Stop hook's turn-end
# acknowledgement and record-only absorb (bin/fm-claude-stop-autoarm.sh).
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoack)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin"
  for f in fm-claude-stop-autoarm.sh fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
    fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh fm-lock.sh \
    fm-wake-drain.sh fm-wake-absorb-lib.sh fm-classify-lib.sh fm-line-cap-lib.sh fm-timeout-lib.sh \
    fm-lease-lib.sh fm-wake-grant.sh fm-guard.sh fm-captain-hold.sh fm-inactive-reconcile.sh; do
    [ -f "$ROOT/bin/$f" ] && cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir"/bin/*.sh
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness that holds the fixture home's session lock.
# $1 = fixture dir, $2 = Stop payload JSON (default: no transcript_path).
WATCHER_PIDS=
# A healthy attached watcher is what makes a non-actionable arm close benign (the hook
# verifies a live identity-matched watcher with a fresh beacon), so every run gets one.
ensure_live_watcher() {  # <dir>
  local dir=$1 pid identity
  [ -e "$dir/state/.watch.lock/pid" ] && return 0
  sleep 120 &
  pid=$!
  WATCHER_PIDS="$WATCHER_PIDS $pid"
  identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not identify the fixture watcher"
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$(cd "$dir/bin" && pwd)/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  touch "$dir/state/.last-watcher-beat"
}

run_autoarm() {
  local dir=$1 payload=${2:-'{"session_id":"sess-autoack","stop_hook_active":false}'} rc=0
  ensure_live_watcher "$dir"
  printf '%s\n' "$payload" \
    | FM_HOME="$dir" FM_GUARD_GRACE=300 "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

append_row() {  # <dir> <kind> <key> <payload>
  FM_STATE_OVERRIDE="$1/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append "$2" "$3" "$4"' _ "$1" "$2" "$3" "$4"
}

# ============================================================
# Test 1: Fresh drain record, healthy transcript
# ============================================================
test_turn_end_ack_healthy() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t1")
  : > "$dir/state/task.meta"

  # Queue two rows: captain inbox and signal for done task
  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  # Run the drain to create .drain-delivered
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  # Create a healthy transcript (no interruption)
  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"

  # Arm fixture: clean attach
  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  # Queue should be empty
  assert_not_contains "$(cat "$dir/state/.wake-queue" 2>/dev/null || true)" "." "queue is empty"
  # .drain-delivered should be gone
  [ ! -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should be removed"
  # No banner on stderr (hook stdout/stderr captured in run_autoarm output)
  # Arm ran exactly once
  local arm_count
  arm_count=$(wc -l < "$dir/state/arm-ran" 2>/dev/null || echo 0)
  expect_code 1 "$arm_count" "arm ran once"
  pass "test_turn_end_ack_healthy"
}

# ============================================================
# Test 2: Interrupted turn
# ============================================================
test_turn_end_ack_interrupted() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t2")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"
  # Append interruption marker with current UTC time
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}],"timestamp":"%s","sessionId":"s"}\n' "$now" >> "$transcript"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  # Both queue rows remain
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 2 "$qlines" "two rows remain queued"
  # .drain-delivered gone (dropped, not retried)
  [ ! -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should be removed"
  # wake-absorb.jsonl has autoack-skipped
  assert_contains "$(cat "$dir/state/wake-absorb.jsonl" 2>/dev/null || true)" 'autoack-skipped' "autoack-skipped logged"
  pass "test_turn_end_ack_interrupted"
}

# ============================================================
# Test 3: Interruption marker a day BEFORE drain epoch
# ============================================================
test_turn_end_ack_old_interruption() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t3")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  # Read the drain record to get its epoch
  local drain_epoch
  drain_epoch=$(cut -f3 "$dir/state/.drain-delivered")
  # A day before in seconds
  local old_epoch=$((drain_epoch - 86400))
  local old_ts
  old_ts=$(date -u -d "@$old_epoch" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$old_epoch" +%Y-%m-%dT%H:%M:%S.000Z)

  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}],"timestamp":"%s","sessionId":"s"}\n' "$old_ts" >> "$transcript"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  # Queue should be empty (acknowledged despite old interruption)
  assert_not_contains "$(cat "$dir/state/.wake-queue" 2>/dev/null || true)" "." "queue is empty"
  [ ! -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should be removed"
  pass "test_turn_end_ack_old_interruption"
}

# ============================================================
# Test 4: No transcript_path in payload
# ============================================================
test_turn_end_ack_no_transcript_path() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t4")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  # Payload without transcript_path
  run_autoarm "$dir" '{"session_id":"sess-autoack","stop_hook_active":false}'
  expect_code 0 $? "hook exits 0"

  # Rows remain
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 2 "$qlines" "rows remain"
  # Record dropped
  [ ! -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should be removed"
  pass "test_turn_end_ack_no_transcript_path"
}

# ============================================================
# Test 5: Transcript path does not exist
# ============================================================
test_turn_end_ack_missing_transcript() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t5")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s/nonexistent.jsonl"}' "$dir")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 2 "$qlines" "rows remain"
  [ ! -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should be removed"
  pass "test_turn_end_ack_missing_transcript"
}

# ============================================================
# Test 6: Record older than 6 hours
# ============================================================
test_turn_end_ack_stale_record() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t6")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  # Manually write a stale .drain-delivered (epoch 25000 seconds ago)
  local stale_epoch
  stale_epoch=$(( $(date +%s) - 25000 ))
  printf '1\t1\t%s\n' "$stale_epoch" > "$dir/state/.drain-delivered"

  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  # Rows remain (not acknowledged)
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 2 "$qlines" "rows remain"
  # Record dropped
  [ ! -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should be removed"
  pass "test_turn_end_ack_stale_record"
}

# ============================================================
# Test 7: No record at all
# ============================================================
test_turn_end_ack_no_record() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t7")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  # No drain run, so no .drain-delivered

  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  # Queue untouched
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 2 "$qlines" "queue untouched"
  # Arm ran once
  local arm_count
  arm_count=$(wc -l < "$dir/state/arm-ran" 2>/dev/null || echo 0)
  expect_code 1 "$arm_count" "arm ran once"
  pass "test_turn_end_ack_no_record"
}

# ============================================================
# Test 8: Rows that arrived after the drain are kept
# ============================================================
test_turn_end_ack_post_drain_rows_kept() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t8")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  # Append a third row AFTER the drain
  append_row "$dir" signal t2.status "signal: $dir/state/t2.status"

  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  # Only the third row remains
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 1 "$qlines" "one row remains"
  # Verify it's the post-drain row
  assert_contains "$(cat "$dir/state/.wake-queue")" "t2.status" "remaining row is post-drain"
  [ ! -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should be removed"
  pass "test_turn_end_ack_post_drain_rows_kept"
}

# ============================================================
# Test 9: .afk exists - no acknowledgement
# ============================================================
test_turn_end_ack_afk() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t9")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  # Rows and record untouched
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 2 "$qlines" "rows untouched"
  [ -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should remain"
  pass "test_turn_end_ack_afk"
}

# ============================================================
# Test 10: Record claimed atomically (concurrent hooks)
# ============================================================
test_turn_end_ack_concurrent() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t10")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")

  # Run two hooks concurrently
  run_autoarm "$dir" "$payload" &
  local pid1=$!
  run_autoarm "$dir" "$payload" &
  local pid2=$!
  wait "$pid1"
  local rc1=$?
  wait "$pid2"
  local rc2=$?

  expect_code 0 "$rc1" "first hook exits 0"
  expect_code 0 "$rc2" "second hook exits 0"

  # Queue ends empty
  assert_not_contains "$(cat "$dir/state/.wake-queue" 2>/dev/null || true)" "." "queue is empty"
  [ ! -f "$dir/state/.drain-delivered" ] || fail ".drain-delivered should be removed"
  pass "test_turn_end_ack_concurrent"
}

# ============================================================
# Test 11: Successful acknowledgement logged
# ============================================================
test_turn_end_ack_logged() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t11")
  : > "$dir/state/task.meta"

  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"
  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1

  local transcript="$dir/state/transcript.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-05T17:05:37.214Z"}\n' > "$transcript"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  local payload
  payload=$(printf '{"session_id":"sess-autoack","stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  run_autoarm "$dir" "$payload"
  expect_code 0 $? "hook exits 0"

  # wake-absorb.jsonl has autoack event
  assert_contains "$(cat "$dir/state/wake-absorb.jsonl" 2>/dev/null || true)" 'autoack' "autoack logged"
  pass "test_turn_end_ack_logged"
}

# ============================================================
# Test 12: Absorb working-only row, no rewake
# ============================================================
test_absorb_working_only() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t12")
  : > "$dir/state/task.meta"

  # Working-only status
  printf 'working [at=1791061356]: relaunched\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  # Arm fixture: first run actionable (signal), later runs clean
  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
run_count=0
run_count=$(wc -l < "$FM_HOME/state/arm-ran")
if [ "$run_count" -eq 1 ]; then
  printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
  printf 'signal: %s/state/t1.status\n' "$FM_HOME"
else
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
fi
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  run_autoarm "$dir"
  expect_code 0 $? "hook exits 0 (no rewake)"

  # Arm ran twice (re-armed after absorbing)
  local arm_count
  arm_count=$(wc -l < "$dir/state/arm-ran" 2>/dev/null || echo 0)
  expect_code 2 "$arm_count" "arm ran twice"

  # Queue empty
  assert_not_contains "$(cat "$dir/state/.wake-queue" 2>/dev/null || true)" "." "queue is empty"

  # wake-absorb.jsonl has absorbed event
  assert_contains "$(cat "$dir/state/wake-absorb.jsonl" 2>/dev/null || true)" 'absorbed' "absorbed logged"
  pass "test_absorb_working_only"
}

# ============================================================
# Test 13: Working-only row + captain inbox row -> rewake
# ============================================================
test_absorb_working_only_with_captain() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t13")
  : > "$dir/state/task.meta"

  printf 'working [at=1791061356]: relaunched\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"
  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
run_count=0
run_count=$(wc -l < "$FM_HOME/state/arm-ran")
if [ "$run_count" -eq 1 ]; then
  printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
  printf 'signal: %s/state/t1.status\n' "$FM_HOME"
else
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
fi
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  run_autoarm "$dir"
  expect_code 2 $? "hook exits 2 (rewake)"

  # Banner starts with "firstmate watcher wake"
  # (captured in run_autoarm stderr output)
  # Arm ran once
  local arm_count
  arm_count=$(wc -l < "$dir/state/arm-ran" 2>/dev/null || echo 0)
  expect_code 1 "$arm_count" "arm ran once"

  # Both rows remain
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 2 "$qlines" "both rows remain"
  pass "test_absorb_working_only_with_captain"
}

# ============================================================
# Test 14: Status file holds 'done' line -> rewake
# ============================================================
test_absorb_done_status() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t14")
  : > "$dir/state/task.meta"

  printf 'done [at=1791061356]: finished\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
run_count=0
run_count=$(wc -l < "$FM_HOME/state/arm-ran")
if [ "$run_count" -eq 1 ]; then
  printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
  printf 'signal: %s/state/t1.status\n' "$FM_HOME"
else
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
fi
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  run_autoarm "$dir"
  expect_code 2 $? "hook exits 2 (rewake)"

  # Row remains
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 1 "$qlines" "row remains"
  pass "test_absorb_done_status"
}

# ============================================================
# Test 15: Absorb cap (FM_WAKE_ABSORB_MAX=3)
# ============================================================
test_absorb_cap() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t15")
  : > "$dir/state/task.meta"

  printf 'working [at=1791061356]: relaunched\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  # Arm fixture: ALWAYS prints actionable reason and re-queues a fresh working-only row
  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
printf 'signal: %s/state/t1.status\n' "$FM_HOME"
# Re-queue a fresh working-only row using production library, with a new unread line behind it
printf 'working [at=%s]: tick\n' "$(date +%s%N)" >> "$FM_HOME/state/t1.status"
FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '. "$FM_HOME/bin/fm-wake-lib.sh"; fm_wake_append signal t1.status "signal: $FM_HOME/state/t1.status"' >/dev/null 2>&1
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  FM_WAKE_ABSORB_MAX=3 run_autoarm "$dir"
  expect_code 2 $? "hook exits 2 after cap (wakes model)"

  # Arm ran 4 times (3 absorbs + 1 final wake)
  local arm_count
  arm_count=$(wc -l < "$dir/state/arm-ran" 2>/dev/null || echo 0)
  expect_code 4 "$arm_count" "arm ran 4 times"
  pass "test_absorb_cap"
}

# ============================================================
# Test 16: No fm-wake-drain.sh -> behaves as before (rewake)
# ============================================================
test_absorb_no_drain_script() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t16")
  : > "$dir/state/task.meta"

  # Remove fm-wake-drain.sh after install
  rm -f "$dir/bin/fm-wake-drain.sh"

  printf 'working [at=1791061356]: relaunched\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
run_count=0
run_count=$(wc -l < "$FM_HOME/state/arm-ran")
if [ "$run_count" -eq 1 ]; then
  printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
  printf 'signal: %s/state/t1.status\n' "$FM_HOME"
else
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
fi
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  run_autoarm "$dir"
  expect_code 2 $? "hook exits 2 (rewake, no absorb without drain)"

  # Row remains
  local qlines
  qlines=$(wc -l < "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  expect_code 1 "$qlines" "row remains"
  pass "test_absorb_no_drain_script"
}

# ============================================================
# Test 17: Banner no longer instructs manual acknowledgement
# ============================================================
test_banner_no_manual_ack() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/t17")
  : > "$dir/state/task.meta"

  printf 'working [at=1791061356]: relaunched\n' > "$dir/state/t1.status"
  append_row "$dir" signal t1.status "signal: $dir/state/t1.status"
  append_row "$dir" check inbox:111 "check: captain inbox note 111 - hello"

  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.last-watcher-beat"
run_count=0
run_count=$(wc -l < "$FM_HOME/state/arm-ran")
if [ "$run_count" -eq 1 ]; then
  printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
  printf 'signal: %s/state/t1.status\n' "$FM_HOME"
else
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
fi
exit 0
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"

  # Capture stderr to check banner
  local output
  output=$(run_autoarm "$dir" 2>&1)
  local rc=$?
  expect_code 2 "$rc" "hook exits 2"

  # Banner mentions Stop hook acknowledges on turn end
  assert_contains "$output" "Stop hook acknowledges" "banner mentions auto-acknowledgement"
  # Banner does NOT contain the old manual instruction
  assert_not_contains "$output" "WAKE_ACK_REQUIRED" "banner does not contain WAKE_ACK_REQUIRED"
  assert_not_contains "$output" "run its exact" "banner does not contain 'run its exact'"
  pass "test_banner_no_manual_ack"
}

# ============================================================
# Run all tests
# ============================================================
test_turn_end_ack_healthy
test_turn_end_ack_interrupted
test_turn_end_ack_old_interruption
test_turn_end_ack_no_transcript_path
test_turn_end_ack_missing_transcript
test_turn_end_ack_stale_record
test_turn_end_ack_no_record
test_turn_end_ack_post_drain_rows_kept
test_turn_end_ack_afk
test_turn_end_ack_concurrent
test_turn_end_ack_logged
test_absorb_working_only
test_absorb_working_only_with_captain
test_absorb_done_status
test_absorb_cap
test_absorb_no_drain_script
test_banner_no_manual_ack

# shellcheck disable=SC2086
kill $WATCHER_PIDS 2>/dev/null || true
echo "ok: fm-claude-stop-autoack tests"
