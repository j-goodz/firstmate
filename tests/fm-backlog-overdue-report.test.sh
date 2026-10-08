#!/usr/bin/env bash
# Test suite: proves fm-backlog-overdue.sh report subcommand outputs correct overdue list,
# respects limits, handles empty/missing backlog, and reacts to re-hold changes.
# Also verifies wake queue and JSONL log are not touched by report (report only prints).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SCRIPT="$ROOT/bin/fm-backlog-overdue.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-overdue)
NOW=$(date -u -d 2026-10-08T12:00:00Z +%s)

# Unset ambient FM_OVERDUE_* variables
unset FM_OVERDUE_NOW_EPOCH || true
unset FM_OVERDUE_LIMIT || true
unset FM_OVERDUE_QUEUED_HOURS || true
unset FM_OVERDUE_LOG || true

test_report_lists_overdue_oldest_first() {
  local home; home="$TMP_ROOT/report-lists-overdue-oldest-first"
  mkdir -p "$home/data" "$home/state"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] a-inflight - In flight, fresh (repo: x) (kind: ship) (since 2026-10-08)
- [ ] a-inflight-late - In flight with a passed hold date (repo: x) (kind: ship) (since 2026-09-01) (hold: waiting on reset) (hold-until: 2026-10-07)

## Queued
- [ ] old-queued - Old queued item (repo: x) (kind: ship) (since 2026-09-24)
  an indented body line (since 2020-01-01) that must never count as a row
- [ ] fresh-queued - Queued 36 hours (repo: x) (kind: ship) (since 2026-10-07)
- [ ] hold-past - Hold date passed (repo: x) (kind: captain) (since 2026-09-30) (hold: ask) (hold-kind: captain) (hold-until: 2026-10-06)
- [ ] hold-future - Hold date ahead (repo: x) (kind: captain) (since 2026-09-01) (hold: ask) (hold-kind: captain) (hold-until: 2026-10-20)
- [ ] hold-today - Hold date is today (repo: x) (kind: captain) (since 2026-10-01) (hold: ask) (hold-kind: captain) (hold-until: 2026-10-08)
- [ ] held-undated - Captain hold without date (repo: x) (kind: captain) (since 2026-09-01) (hold: waiting for captain) (hold-kind: captain)
- [ ] pacing-undated - Pacing hold without reset (repo: x) (kind: ship) (since 2026-10-03) (hold: Pacing on until the weekly reset)
- [ ] pacing-dated - Pacing hold with reset (repo: x) (kind: ship) (since 2026-10-03) (hold: Pacing on) (hold-until: 2026-10-12)
- [ ] due-past - Due date passed (repo: x) (kind: ship) (since 2026-10-05) (due: 2026-10-06)
- [ ] blocked-one - Blocked (repo: x) (kind: ship) (since 2026-09-01) (blocked-by: old-queued)
- [ ] no-since - Queued with no since date (repo: x) (kind: ship)

## Done
- [x] done-old - Done row with a stale date (repo: x) (kind: ship) (since 2026-01-01) (hold-until: 2020-01-01)
EOF

  local stdout_file; stdout_file="$home/state/stdout.txt"
  local exitcode; exitcode=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" report > "$stdout_file" 2>&1 || exitcode=$?

  assert_equals 0 "$exitcode" "report exits 0"

  local expected_header="OVERDUE (6 item(s) past a hold date, due date or the 48h queue limit, oldest first):"
  assert_contains "$(cat "$stdout_file")" "$expected_header" "header line present"

  local expected_lines=(
    "old-queued - Old queued item: 12d overdue (queued 14d, never dispatched)"
    "pacing-undated - Pacing hold without reset: 5d overdue (pacing hold has no hold-until reset date)"
    "due-past - Due date passed: 2d overdue (due 2026-10-06)"
    "hold-past - Hold date passed: 2d overdue (hold-until 2026-10-06)"
    "a-inflight-late - In flight with a passed hold date: 1d overdue (hold-until 2026-10-07)"
    "hold-today - Hold date is today: <1d overdue (hold-until 2026-10-08)"
  )

  local line
  for line in "${expected_lines[@]}"; do
    assert_contains "$(cat "$stdout_file")" "$line" "contains expected line: $line"
  done

  local expected_final="OVERDUE: act on each one: dispatch it, re-hold it with a new date (fm-captain-hold.sh hold <id> --reason <why> --until YYYY-MM-DD, or fm-tasks-axi.sh hold <id> --reason <why> --until YYYY-MM-DD), or close it with a reason."
  assert_contains "$(cat "$stdout_file")" "$expected_final" "final act line present"

  local non_overdue=("a-inflight" "fresh-queued" "hold-future" "held-undated" "pacing-dated" "blocked-one" "no-since" "done-old")
  local id
  for id in "${non_overdue[@]}"; do
    assert_not_contains "$id" "$(cat "$stdout_file")" "non-overdue id $id not in output"
  done

  local wake_queue; wake_queue="$home/state/.wake-queue"
  local jsonl; jsonl="$home/state/backlog-overdue.jsonl"
  assert_equals "" "$(cat "$wake_queue" 2>/dev/null || true)" "wake queue empty"
  assert_equals "" "$(cat "$jsonl" 2>/dev/null || true)" "jsonl log empty"

  pass "report_lists_overdue_oldest_first"
}

test_report_is_silent_when_nothing_is_overdue() {
  local home; home="$TMP_ROOT/report-is-silent-when-nothing-is-overdue"
  mkdir -p "$home/data" "$home/state"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] fresh-inflight - Fresh in flight (repo: x) (kind: ship) (since 2026-10-08)

## Queued
- [ ] fresh-queued - Fresh queued (repo: x) (kind: ship) (since 2026-10-07)
EOF

  local stdout_file; stdout_file="$home/state/stdout.txt"
  local exitcode; exitcode=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" report > "$stdout_file" 2>&1 || exitcode=$?

  assert_equals 0 "$exitcode" "report exits 0 with fresh rows"
  assert_equals "" "$(cat "$stdout_file")" "stdout empty with fresh rows"

  # Missing backlog file
  rm -f "$home/data/backlog.md"
  exitcode=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" report > "$stdout_file" 2>&1 || exitcode=$?
  assert_equals 0 "$exitcode" "report exits 0 with missing backlog"
  assert_equals "" "$(cat "$stdout_file")" "stdout empty with missing backlog"

  # Empty file
  touch "$home/data/backlog.md"
  exitcode=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" report > "$stdout_file" 2>&1 || exitcode=$?
  assert_equals 0 "$exitcode" "report exits 0 with empty backlog"
  assert_equals "" "$(cat "$stdout_file")" "stdout empty with empty backlog"

  pass "report_is_silent_when_nothing_is_overdue"
}

test_report_caps_at_ten_with_more_line() {
  local home; home="$TMP_ROOT/report-caps-at-ten-with-more-line"
  mkdir -p "$home/data" "$home/state"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] q01 - Queued item 1 (repo: x) (kind: ship) (since 2026-09-01)
- [ ] q02 - Queued item 2 (repo: x) (kind: ship) (since 2026-09-02)
- [ ] q03 - Queued item 3 (repo: x) (kind: ship) (since 2026-09-03)
- [ ] q04 - Queued item 4 (repo: x) (kind: ship) (since 2026-09-04)
- [ ] q05 - Queued item 5 (repo: x) (kind: ship) (since 2026-09-05)
- [ ] q06 - Queued item 6 (repo: x) (kind: ship) (since 2026-09-06)
- [ ] q07 - Queued item 7 (repo: x) (kind: ship) (since 2026-09-07)
- [ ] q08 - Queued item 8 (repo: x) (kind: ship) (since 2026-09-08)
- [ ] q09 - Queued item 9 (repo: x) (kind: ship) (since 2026-09-09)
- [ ] q10 - Queued item 10 (repo: x) (kind: ship) (since 2026-09-10)
- [ ] q11 - Queued item 11 (repo: x) (kind: ship) (since 2026-09-11)
- [ ] q12 - Queued item 12 (repo: x) (kind: ship) (since 2026-09-12)
EOF

  local stdout_file; stdout_file="$home/state/stdout.txt"
  local exitcode; exitcode=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" report > "$stdout_file" 2>&1 || exitcode=$?

  assert_equals 0 "$exitcode" "report exits 0 with 12 items"

  local header="OVERDUE (12 item(s) past a hold date, due date or the 48h queue limit, oldest first):"
  assert_contains "$(cat "$stdout_file")" "$header" "header says 12 item(s)"

  local item_count
  item_count=$(grep -cE '^[a-z0-9-]+ - .+: [0-9]+d overdue ' "$stdout_file" || true)
  assert_equals 10 "$item_count" "exactly 10 item lines"

  assert_contains "$(cat "$stdout_file")" "OVERDUE: +2 more" "shows +2 more"

  pass "report_caps_at_ten_with_more_line"
}

test_report_limit_env_overrides() {
  local home; home="$TMP_ROOT/report-limit-env-overrides"
  mkdir -p "$home/data" "$home/state"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] old-queued - Old queued item (repo: x) (kind: ship) (since 2026-09-24)
- [ ] pacing-undated - Pacing hold without reset (repo: x) (kind: ship) (since 2026-10-03) (hold: Pacing on until the weekly reset)
- [ ] due-past - Due date passed (repo: x) (kind: ship) (since 2026-10-05) (due: 2026-10-06)
- [ ] hold-past - Hold date passed (repo: x) (kind: captain) (since 2026-09-30) (hold: ask) (hold-kind: captain) (hold-until: 2026-10-06)
- [ ] a-inflight-late - In flight with a passed hold date (repo: x) (kind: ship) (since 2026-09-01) (hold: waiting on reset) (hold-until: 2026-10-07)
- [ ] hold-today - Hold date is today (repo: x) (kind: captain) (since 2026-10-01) (hold: ask) (hold-kind: captain) (hold-until: 2026-10-08)
EOF

  local stdout_file; stdout_file="$home/state/stdout.txt"
  local exitcode; exitcode=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_OVERDUE_NOW_EPOCH="$NOW" FM_OVERDUE_LIMIT=3 "$SCRIPT" report > "$stdout_file" 2>&1 || exitcode=$?

  assert_equals 0 "$exitcode" "report exits 0 with limit 3"

  local item_count
  item_count=$(grep -cE '^[a-z0-9-]+ - .+: [0-9]+d overdue ' "$stdout_file" || true)
  assert_equals 3 "$item_count" "exactly 3 item lines"

  assert_contains "$(cat "$stdout_file")" "OVERDUE: +3 more" "shows +3 more"

  pass "report_limit_env_overrides"
}

test_rehold_removes_overdue() {
  local home; home="$TMP_ROOT/rehold-removes-overdue"
  mkdir -p "$home/data" "$home/state"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] old-queued - Old queued item (repo: x) (kind: ship) (since 2026-09-24)
- [ ] fresh-queued - Queued 36 hours (repo: x) (kind: ship) (since 2026-10-07)
EOF

  sed -i 's/(since 2026-09-24)/(since 2026-09-24) (hold: re-held) (hold-until: 2026-10-20)/' "$home/data/backlog.md"

  local stdout_file; stdout_file="$home/state/stdout.txt"
  local exitcode; exitcode=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" report > "$stdout_file" 2>&1 || exitcode=$?

  assert_equals 0 "$exitcode" "report exits 0 after rehold"

  assert_not_contains "$(cat "$stdout_file")" "old-queued" "old-queued not listed after rehold"

  pass "rehold_removes_overdue"
}

test_report_lists_overdue_oldest_first
test_report_is_silent_when_nothing_is_overdue
test_report_caps_at_ten_with_more_line
test_report_limit_env_overrides
test_rehold_removes_overdue
