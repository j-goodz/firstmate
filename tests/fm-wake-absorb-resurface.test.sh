#!/usr/bin/env bash
# tests/fm-wake-absorb-resurface.test.sh - behavior tests for --absorb-resurface of bin/fm-wake-drain.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-absorb-resurface-tests)

test_empty_queue_with_marker() {
  local dir state
  dir=$(make_case "empty-queue-with-marker")
  state="$dir/state"
  printf 'pending:downtime:gen1\n' > "$state/.watcher-down"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$dir/out" 2> "$dir/err"
  local code=$?
  expect_code 0 "$code" "exit code"

  assert_not_contains "$(cat "$dir/out")" "." "stdout empty"
  assert_contains "$(cat "$state/.watcher-down")" "acked:downtime:gen1" "marker updated to acked"
  assert_contains "$(cat "$state/wake-absorb.jsonl")" '"event":"absorbed"' "absorbed event logged"

  pass "empty queue with marker"
}

test_empty_queue_no_marker() {
  local dir state
  dir=$(make_case "empty-queue-no-marker")
  state="$dir/state"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$dir/out" 2> "$dir/err"
  local code=$?
  expect_code 0 "$code" "exit code"

  assert_not_contains "$(cat "$dir/out")" "." "stdout empty"
  # no marker file should be created
  if [[ -f "$state/.watcher-down" ]]; then
    fail "marker file should not exist"
  fi

  pass "empty queue no marker"
}

test_empty_queue_marker_with_undelivered_decision() {
  local dir state
  dir=$(make_case "empty-queue-marker-undelivered-decision")
  state="$dir/state"
  printf 'pending:downtime:gen1\n' > "$state/.watcher-down"
  # create an open decision that has never been delivered
  printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$dir/out" 2> "$dir/err"
  local code=$?
  expect_code 1 "$code" "exit code"

  assert_contains "$(cat "$state/.watcher-down")" "pending:downtime:gen1" "marker still pending"
  # normal drain should print the full block
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out2" 2> "$dir/err2"
  assert_contains "$(cat "$dir/out2")" "OPEN DECISIONS (still open" "normal drain shows open decision"

  pass "empty queue marker with undelivered decision"
}

test_empty_queue_marker_decision_delivered_then_resurface() {
  local dir state
  dir=$(make_case "empty-queue-marker-decision-delivered-then-resurface")
  state="$dir/state"
  printf 'pending:downtime:gen1\n' > "$state/.watcher-down"
  printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"

  # first normal drain delivers the block
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out1" 2> "$dir/err1"
  # set marker back to pending
  printf 'pending:downtime:gen1\n' > "$state/.watcher-down"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$dir/out2" 2> "$dir/err2"
  local code=$?
  expect_code 0 "$code" "exit code"

  assert_contains "$(cat "$state/.watcher-down")" "acked:downtime:gen1" "marker updated to acked"
  # later normal drain with FULL=1 should still list the decision as open
  FM_WAKE_DRAIN_FULL=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out3" 2> "$dir/err3"
  assert_contains "$(cat "$dir/out3")" "OPEN DECISIONS (still open" "decision still open in full drain"

  pass "empty queue marker decision delivered then resurface"
}

test_queue_working_only_signal_row() {
  local dir state
  dir=$(make_case "queue-working-only-signal")
  state="$dir/state"
  printf 'pending:downtime:gen1\n' > "$state/.watcher-down"
  # status file with working line
  printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"
  # queue row for that signal
  append_wake "$state" signal t1.status "signal: $state/t1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$dir/out" 2> "$dir/err"
  local code=$?
  expect_code 0 "$code" "exit code"

  assert_not_contains "$(cat "$dir/out")" "." "stdout empty"
  # queue should be empty (zero bytes)
  if [[ -s "$state/.wake-queue" ]]; then
    fail "queue should be empty"
  fi
  assert_contains "$(cat "$state/.watcher-down")" "acked:downtime:gen1" "marker updated to acked"

  pass "queue working only signal row"
}

test_queue_captain_inbox_row() {
  local dir state
  dir=$(make_case "queue-captain-inbox")
  state="$dir/state"
  printf 'pending:downtime:gen1\n' > "$state/.watcher-down"
  append_wake "$state" check inbox:111 "check: captain inbox note 111 - hello"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$dir/out" 2> "$dir/err"
  local code=$?
  expect_code 1 "$code" "exit code"

  assert_not_contains "$(cat "$dir/out")" "." "stdout empty"
  # queue should still have one line
  local lines
  lines=$(wc -l < "$state/.wake-queue")
  if [[ "$lines" -ne 1 ]]; then
    fail "queue should still have one row, got $lines"
  fi

  pass "queue captain inbox row"
}

test_queue_signal_row_done_status() {
  local dir state
  dir=$(make_case "queue-signal-done-status")
  state="$dir/state"
  printf 'pending:downtime:gen1\n' > "$state/.watcher-down"
  printf 'done [at=1791061356]: finished\n' > "$state/t1.status"
  append_wake "$state" signal t1.status "signal: $state/t1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$dir/out" 2> "$dir/err"
  local code=$?
  expect_code 1 "$code" "exit code"

  assert_not_contains "$(cat "$dir/out")" "." "stdout empty"
  local lines
  lines=$(wc -l < "$state/.wake-queue")
  if [[ "$lines" -ne 1 ]]; then
    fail "queue should still have one row, got $lines"
  fi

  pass "queue signal row done status"
}

test_resurface_then_new_inbox() {
  local dir state
  dir=$(make_case "resurface-then-new-inbox")
  state="$dir/state"
  printf 'pending:downtime:gen1\n' > "$state/.watcher-down"

  # first absorb-resurface on empty queue
  FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$dir/out1" 2> "$dir/err1"
  local code=$?
  expect_code 0 "$code" "first absorb-resurface exit code"

  # now append a new inbox row
  append_wake "$state" check inbox:111 "check: captain inbox note 111 - hello"

  # normal drain
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out2" 2> "$dir/err2"
  assert_contains "$(cat "$dir/out2")" "inbox:111" "output contains inbox row"
  assert_contains "$(cat "$dir/err2")" "WAKE_ACK_REQUIRED" "stderr contains WAKE_ACK_REQUIRED"

  pass "resurface then new inbox"
}

# Run all tests
test_empty_queue_with_marker
test_empty_queue_no_marker
test_empty_queue_marker_with_undelivered_decision
test_empty_queue_marker_decision_delivered_then_resurface
test_queue_working_only_signal_row
test_queue_captain_inbox_row
test_queue_signal_row_done_status
test_resurface_then_new_inbox

echo "ok: fm-wake-absorb-resurface tests"