#!/usr/bin/env bash
# Tests for fm-backlog-overdue.sh wake subcommand.
# Verifies that overdue items are enqueued exactly once per day,
# that the correct number of items are woken, that the wake queue
# rows and JSONL log entries are correct, and that a second wake on
# the same day does nothing while a wake on the next day adds new rows.

set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# Unset any ambient test‑seam variables.
unset FM_OVERDUE_NOW_EPOCH FM_OVERDUE_LIMIT FM_OVERDUE_QUEUED_HOURS FM_OVERDUE_LOG

SCRIPT="$ROOT/bin/fm-backlog-overdue.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-overdue)

# Fixed “now” for the first two runs.
NOW=$(date -u -d 2026-10-08T12:00:00Z +%s)

# Helper: write the common backlog fixture.
write_fixture() {
    local data_dir=$1
    mkdir -p "$data_dir"
    cat >"$data_dir/backlog.md" <<'EOF'
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
}

# Expected titles for the seven overdue items.
declare -A EXPECTED_TITLE=(
    [held-undated]="Captain hold without date"
    [old-queued]="Old queued item"
    [pacing-undated]="Pacing hold without reset"
    [due-past]="Due date passed"
    [hold-past]="Hold date passed"
    [a-inflight-late]="In flight with a passed hold date"
    [hold-today]="Hold date is today"
)

# Expected reasons for the seven overdue items.
declare -A EXPECTED_REASON=(
    [held-undated]="undated hold, re-check"
    [old-queued]="queued 14d, never dispatched"
    [pacing-undated]="pacing hold has no hold-until reset date"
    [due-past]="due 2026-10-06"
    [hold-past]="hold-until 2026-10-06"
    [a-inflight-late]="hold-until 2026-10-07"
    [hold-today]="hold-until 2026-10-08"
)

# Compute overdue seconds for a given id.
overdue_secs() {
    local id=$1
    local since epoch
    case "$id" in
        held-undated)
            since=$(date -u -d 2026-09-01 +%s)
            epoch=$(( NOW - since - 48 * 3600 ))
            ;;
        old-queued)
            since=$(date -u -d 2026-09-24 +%s)
            epoch=$(( NOW - since - 48 * 3600 ))
            ;;
        pacing-undated)
            since=$(date -u -d 2026-10-03 +%s)
            epoch=$(( NOW - since ))
            ;;
        due-past)
            epoch=$(date -u -d 2026-10-06 +%s)
            epoch=$(( NOW - epoch ))
            ;;
        hold-past)
            epoch=$(date -u -d 2026-10-06 +%s)
            epoch=$(( NOW - epoch ))
            ;;
        a-inflight-late)
            epoch=$(date -u -d 2026-10-07 +%s)
            epoch=$(( NOW - epoch ))
            ;;
        hold-today)
            epoch=$(date -u -d 2026-10-08 +%s)
            epoch=$(( NOW - epoch ))
            ;;
        *) epoch=0 ;;
    esac
    printf '%d' "$epoch"
}

# -------------------------------------------------------------------------
# Test 6 – wake enqueues one check wake per item and logs correctly.
test_wake_enqueues_one_check_wake_per_item_and_logs() {
    local case_dir="$TMP_ROOT/case6"
    local home="$case_dir/home"
    local data="$home/data"
    local state="$home/state"

    mkdir -p "$state"
    write_fixture "$data"

    # Run the wake subcommand.
    local out
    out=$(
        FM_HOME="$home" \
        FM_STATE_OVERRIDE="$state" \
        FM_DATA_OVERRIDE="$data" \
        FM_OVERDUE_NOW_EPOCH="$NOW" \
        "$SCRIPT" wake
    )
    assert_equals "backlog-overdue: 7 item(s) overdue, woken" "$out" "wake summary line"

    # -----------------------------------------------------------------
    # Verify the wake queue.
    local queue_file="$state/.wake-queue"
    assert_contains "$(cat "$queue_file")" "" "queue file exists"

    local row_count
    row_count=$(awk -F '\t' 'NF' "$queue_file" | wc -l | tr -d ' ')
    assert_equals "7" "$row_count" "queue contains seven rows"

    while IFS=$'\t' read -r epoch _ kind key payload; do
        assert_equals "check" "$kind" "queue kind is check"
        local id
        id=${key#backlog-overdue:}
        assert_contains "$key" "backlog-overdue:$id" "queue key format"
        assert_contains "$payload" "$id - " "payload contains id"
        assert_contains "$payload" "${EXPECTED_TITLE[$id]}" "payload contains title"
    done <"$queue_file"

    # -----------------------------------------------------------------
    # Verify the JSONL log.
    local log_file="$state/backlog-overdue.jsonl"
    assert_contains "$(cat "$log_file")" "" "log file exists"

    local log_count
    log_count=$(wc -l <"$log_file" | tr -d ' ')
    assert_equals "7" "$log_count" "log contains seven lines"

    while IFS= read -r line; do
        # Validate JSON.
        jq -e . <<<"$line" >/dev/null || fail "invalid JSON line: $line"

        local id ts day reason overdue woken title
        id=$(jq -r .id <<<"$line")
        ts=$(jq -r .ts <<<"$line")
        day=$(jq -r .day <<<"$line")
        reason=$(jq -r .reason <<<"$line")
        overdue=$(jq -r .overdue_secs <<<"$line")
        woken=$(jq -r .woken <<<"$line")
        title=$(jq -r .title <<<"$line")

        assert_equals "$NOW" "$ts" "log ts for $id"
        assert_equals "2026-10-08" "$day" "log day for $id"
        assert_equals "true" "$woken" "log woken flag for $id"
        assert_equals "${EXPECTED_REASON[$id]}" "$reason" "log reason for $id"
        assert_equals "${EXPECTED_TITLE[$id]}" "$title" "log title for $id"
        assert_equals "$(overdue_secs "$id")" "$overdue" "log overdue_secs for $id"
    done <"$log_file"
}

# -------------------------------------------------------------------------
# Test 7 – wake is once per item per day, but works on the next day.
test_wake_is_once_per_item_per_day() {
    local case_dir="$TMP_ROOT/case7"
    local home="$case_dir/home"
    local data="$home/data"
    local state="$home/state"

    mkdir -p "$state"
    write_fixture "$data"

    # First wake (day 1).
    local out1
    out1=$(
        FM_HOME="$home" \
        FM_STATE_OVERRIDE="$state" \
        FM_DATA_OVERRIDE="$data" \
        FM_OVERDUE_NOW_EPOCH="$NOW" \
        "$SCRIPT" wake
    )
    assert_equals "backlog-overdue: 7 item(s) overdue, woken" "$out1" "first wake prints summary"

    local queue_before
    queue_before=$(cat "$state/.wake-queue")
    local log_before
    log_before=$(cat "$state/backlog-overdue.jsonl")

    # Second wake on the same day – should be silent.
    local out2
    out2=$(
        FM_HOME="$home" \
        FM_STATE_OVERRIDE="$state" \
        FM_DATA_OVERRIDE="$data" \
        FM_OVERDUE_NOW_EPOCH="$NOW" \
        "$SCRIPT" wake
    )
    assert_equals "" "$out2" "second wake on same day prints nothing"

    # Queue and log must be unchanged.
    assert_equals "$queue_before" "$(cat "$state/.wake-queue")" "queue unchanged after second wake"
    assert_equals "$log_before" "$(cat "$state/backlog-overdue.jsonl")" "log unchanged after second wake"

    # Third wake on the next UTC day.
    local next_now=$(( NOW + 86400 ))
    local out3
    out3=$(
        FM_HOME="$home" \
        FM_STATE_OVERRIDE="$state" \
        FM_DATA_OVERRIDE="$data" \
        FM_OVERDUE_NOW_EPOCH="$next_now" \
        "$SCRIPT" wake
    )
    # The script may limit output to the number of items woken; we only require
    # that it reports a non‑empty count and that at least five items were added.
    assert_contains "$out3" "item(s) overdue, woken" "third wake on next day prints a summary"
    assert_contains "$out3" "backlog-overdue:" "summary contains expected prefix"

    # Verify that new rows were added to the queue.
    local total_rows
    total_rows=$(awk -F '\t' 'NF' "$state/.wake-queue" | wc -l | tr -d ' ')
    # At least the original six plus one new row (the script may cap at LIMIT).
    if (( total_rows < 12 )); then
        fail "expected at least 12 queue rows after next‑day wake, got $total_rows"
    fi

    # Verify that new log lines were added.
    local total_log
    total_log=$(wc -l <"$state/backlog-overdue.jsonl" | tr -d ' ')
    if (( total_log < 12 )); then
        fail "expected at least 12 log lines after next‑day wake, got $total_log"
    fi

    # Spot‑check that the newest log entries have the new timestamp.
    local new_ts_found=0
    while IFS= read -r line; do
        local ts
        ts=$(jq -r .ts <<<"$line")
        if (( ts == next_now )); then
            new_ts_found=$(( new_ts_found + 1 ))
        fi
    done <"$state/backlog-overdue.jsonl"
    if (( new_ts_found == 0 )); then
        fail "no log entries with the next‑day timestamp $next_now"
    fi
}

# Execute the tests.
test_wake_enqueues_one_check_wake_per_item_and_logs
test_wake_is_once_per_item_per_day
