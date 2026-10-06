#!/usr/bin/env bash
# tests/fm-wake-absorb-report.test.sh - behavior tests for bin/fm-wake-absorb-report.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-wake-absorb-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-absorb-report-tests)

test_mixed_log_fresh() {
	local state_dir="$TMP_ROOT/test1"
	mkdir -p "$state_dir"
	local now
	now=$(date +%s)
	# Build log lines
	# 2 absorbed events with rows "2" and "3"
	# 3 autoack
	# 1 autoack-failed
	# skipped: 2 interrupted, 1 stale-record
	cat > "$state_dir/wake-absorb.jsonl" <<EOF
{"ts":$now,"event":"absorbed","rows":"2"}
{"ts":$now,"event":"absorbed","rows":"3"}
{"ts":$now,"event":"autoack"}
{"ts":$now,"event":"autoack"}
{"ts":$now,"event":"autoack"}
{"ts":$now,"event":"autoack-failed"}
{"ts":$now,"event":"autoack-skipped","reason":"interrupted"}
{"ts":$now,"event":"autoack-skipped","reason":"interrupted"}
{"ts":$now,"event":"autoack-skipped","reason":"stale-record"}
EOF
	local out
	out=$("$REPORT" --state "$state_dir")
	expect_code 0 $? "exit code 0"
	assert_contains "$out" "window_hours: 24" "window_hours 24"
	assert_contains "$out" "absorbed_events: 2" "absorbed_events 2"
	assert_contains "$out" "absorbed_rows: 5" "absorbed_rows 5"
	assert_contains "$out" "autoack: 3" "autoack 3"
	assert_contains "$out" "autoack_failed: 1" "autoack_failed 1"
	assert_contains "$out" "autoack_skipped: 3" "autoack_skipped 3"
	assert_contains "$out" "  interrupted: 2" "interrupted 2"
	assert_contains "$out" "  stale-record: 1" "stale-record 1"
	assert_contains "$out" "  no-transcript: 0" "no-transcript 0"
	assert_contains "$out" "  bad-record: 0" "bad-record 0"
	pass "test_mixed_log_fresh"
}

test_old_lines_excluded_by_default_included_with_since_hours() {
	local state_dir="$TMP_ROOT/test2"
	mkdir -p "$state_dir"
	local now
	now=$(date +%s)
	local old_ts=$((now - 200000))  # ~55 hours ago
	# One old absorbed, one fresh absorbed
	cat > "$state_dir/wake-absorb.jsonl" <<EOF
{"ts":$old_ts,"event":"absorbed","rows":"10"}
{"ts":$now,"event":"absorbed","rows":"5"}
EOF
	# Default (24h) should only count fresh
	local out
	out=$("$REPORT" --state "$state_dir")
	expect_code 0 $? "exit code 0"
	assert_contains "$out" "absorbed_events: 1" "only fresh absorbed_events"
	assert_contains "$out" "absorbed_rows: 5" "only fresh absorbed_rows"
	# With --since-hours 100 (100 hours = 360000 seconds) both should be counted
	out=$("$REPORT" --state "$state_dir" --since-hours 100)
	expect_code 0 $? "exit code 0 with --since-hours 100"
	assert_contains "$out" "absorbed_events: 2" "both absorbed_events"
	assert_contains "$out" "absorbed_rows: 15" "both absorbed_rows"
	pass "test_old_lines_excluded_by_default_included_with_since_hours"
}

test_json_output() {
	local state_dir="$TMP_ROOT/test3"
	mkdir -p "$state_dir"
	local now
	now=$(date +%s)
	cat > "$state_dir/wake-absorb.jsonl" <<EOF
{"ts":$now,"event":"absorbed","rows":"2"}
{"ts":$now,"event":"absorbed","rows":"3"}
{"ts":$now,"event":"autoack"}
{"ts":$now,"event":"autoack"}
{"ts":$now,"event":"autoack"}
{"ts":$now,"event":"autoack-failed"}
{"ts":$now,"event":"autoack-skipped","reason":"interrupted"}
{"ts":$now,"event":"autoack-skipped","reason":"interrupted"}
{"ts":$now,"event":"autoack-skipped","reason":"stale-record"}
EOF
	local out
	out=$("$REPORT" --state "$state_dir" --json)
	expect_code 0 $? "exit code 0 for --json"
	# Parse with python
	python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["window_hours"] == 24
assert data["absorbed_events"] == 2
assert data["absorbed_rows"] == 5
assert data["autoack"] == 3
assert data["autoack_failed"] == 1
assert data["autoack_skipped"] == 3
assert data["skipped_by_reason"]["interrupted"] == 2
assert data["skipped_by_reason"]["stale-record"] == 1
assert data["skipped_by_reason"]["no-transcript"] == 0
assert data["skipped_by_reason"]["bad-record"] == 0
' <<< "$out" || fail "json output mismatch"
	pass "test_json_output"
}

test_missing_and_empty_log() {
	local state_dir="$TMP_ROOT/test4"
	mkdir -p "$state_dir"
	# Missing log file
	local out
	out=$("$REPORT" --state "$state_dir")
	expect_code 0 $? "exit code 0 for missing log"
	assert_contains "$out" "absorbed_events: 0" "zero absorbed_events"
	assert_contains "$out" "absorbed_rows: 0" "zero absorbed_rows"
	assert_contains "$out" "autoack: 0" "zero autoack"
	assert_contains "$out" "autoack_failed: 0" "zero autoack_failed"
	assert_contains "$out" "autoack_skipped: 0" "zero autoack_skipped"
	# Empty log file
	: > "$state_dir/wake-absorb.jsonl"
	out=$("$REPORT" --state "$state_dir")
	expect_code 0 $? "exit code 0 for empty log"
	assert_contains "$out" "absorbed_events: 0" "zero absorbed_events empty"
	pass "test_missing_and_empty_log"
}

test_invalid_lines_ignored() {
	local state_dir="$TMP_ROOT/test5"
	mkdir -p "$state_dir"
	local now
	now=$(date +%s)
	cat > "$state_dir/wake-absorb.jsonl" <<EOF
garbage text
{"event":"absorbed","rows":"1"}
{"ts":"not-a-number","event":"absorbed","rows":"2"}
{"ts":$now,"event":"absorbed","rows":"3"}
{"ts":$now,"event":"autoack"}
EOF
	local out
	out=$("$REPORT" --state "$state_dir")
	expect_code 0 $? "exit code 0 with invalid lines"
	# Only the valid line with numeric ts and event absorbed/autoack should count
	assert_contains "$out" "absorbed_events: 1" "one valid absorbed"
	assert_contains "$out" "absorbed_rows: 3" "rows from valid absorbed"
	assert_contains "$out" "autoack: 1" "one valid autoack"
	pass "test_invalid_lines_ignored"
}

test_invalid_options_and_help() {
	# --since-hours abc
	local out
	out=$("$REPORT" --since-hours abc 2>&1)
	expect_code 2 $? "exit 2 for non-numeric since-hours"
	assert_contains "$out" "usage" "usage printed for non-numeric"
	# --since-hours 0
	out=$("$REPORT" --since-hours 0 2>&1)
	expect_code 2 $? "exit 2 for zero since-hours"
	assert_contains "$out" "usage" "usage printed for zero"
	# --bogus
	out=$("$REPORT" --bogus 2>&1)
	expect_code 2 $? "exit 2 for unknown option"
	assert_contains "$out" "usage" "usage printed for unknown"
	# --help
	out=$("$REPORT" --help 2>&1)
	expect_code 0 $? "exit 0 for help"
	assert_contains "$out" "--state" "help mentions --state"
	assert_contains "$out" "--since-hours" "help mentions --since-hours"
	assert_contains "$out" "--json" "help mentions --json"
	pass "test_invalid_options_and_help"
}

test_state_option_overrides_env() {
	local state_dir1="$TMP_ROOT/test7a"
	local state_dir2="$TMP_ROOT/test7b"
	mkdir -p "$state_dir1" "$state_dir2"
	local now
	now=$(date +%s)
	# Log in state_dir1 has one absorbed
	echo "{\"ts\":$now,\"event\":\"absorbed\",\"rows\":\"1\"}" > "$state_dir1/wake-absorb.jsonl"
	# Log in state_dir2 has two absorbed
	echo "{\"ts\":$now,\"event\":\"absorbed\",\"rows\":\"2\"}" > "$state_dir2/wake-absorb.jsonl"
	# Set FM_STATE_OVERRIDE to state_dir1, but pass --state state_dir2
	local out
	out=$(FM_STATE_OVERRIDE="$state_dir1" "$REPORT" --state "$state_dir2")
	expect_code 0 $? "exit code 0"
	assert_contains "$out" "absorbed_events: 1" "count from --state dir"
	assert_contains "$out" "absorbed_rows: 2" "rows from --state dir"
	pass "test_state_option_overrides_env"
}

# Run tests
test_mixed_log_fresh
test_old_lines_excluded_by_default_included_with_since_hours
test_json_output
test_missing_and_empty_log
test_invalid_lines_ignored
test_invalid_options_and_help
test_state_option_overrides_env

echo "ok: fm-wake-absorb-report tests"