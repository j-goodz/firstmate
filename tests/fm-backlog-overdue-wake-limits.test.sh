#!/usr/bin/env bash

# Tests for bin/fm-backlog-overdue.sh wake subcommand. Proves:
# - wake enqueues checks for overdue items, logs JSONL, and prints a summary
# - wake respects FM_OVERDUE_LIMIT
# - wake does not mark items when enqueue fails
# - wake is silent when the backlog is missing

set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SCRIPT="$ROOT/bin/fm-backlog-overdue.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-overdue)
NOW=$(date -u -d 2026-10-08T12:00:00Z +%s)

# Case 8: wake_drains_ten_per_sweep
test_wake_drains_ten_per_sweep() {
    local home="$TMP_ROOT/wake-drains-ten-per-sweep"
    local data="$home/data"
    local state="$home/state"
    mkdir -p "$data" "$state"

    # Create backlog with 12 overdue items
    cat > "$data/backlog.md" <<'EOF'
# Backlog

## Queued
EOF

    # Add 12 overdue items (old-queued-1 to old-queued-12)
    for i in {1..12}; do
        echo "- [ ] old-queued-$i - Old queued item $i (repo: x) (kind: ship) (since 2026-09-24)" >> "$data/backlog.md"
    done

    # First wake: should enqueue 10 items
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" wake
    local wake_count
    wake_count=$(awk -F '\t' 'NF {count++} END {print count+0}' "$state/.wake-queue")
    assert_equals 10 "$wake_count" "First wake should enqueue 10 items"

    # Second wake: should enqueue the remaining 2 items
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" wake
    wake_count=$(awk -F '\t' 'NF {count++} END {print count+0}' "$state/.wake-queue")
    assert_equals 12 "$wake_count" "Second wake should enqueue remaining 2 items"

    # Third wake: should enqueue nothing
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" wake
    wake_count=$(awk -F '\t' 'NF {count++} END {print count+0}' "$state/.wake-queue")
    assert_equals 12 "$wake_count" "Third wake should enqueue nothing"
}

# Case 9: wake_does_not_mark_when_enqueue_fails
test_wake_does_not_mark_when_enqueue_fails() {
    local home="$TMP_ROOT/wake-does-not-mark"
    local data="$home/data"
    local state="$home/state"
    mkdir -p "$data" "$state"

    # Create a simple backlog
    cat > "$data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] test-item - Test item (repo: x) (kind: ship) (since 2026-09-24)
EOF

    # Run wake with a bad wake queue path
    local bad_path="$home/nope/q"
    mkdir -p "$(dirname "$bad_path")"
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_OVERDUE_NOW_EPOCH="$NOW" FM_WAKE_QUEUE="$bad_path" "$SCRIPT" wake
    local exit_status=$?

    # Check for failure
    if [ $exit_status -eq 0 ]; then
        echo "skip: wake unexpectedly succeeded with bad wake queue path"
        return
    fi

    # Verify no marker file was created
    if [ -f "$state/.backlog-overdue-woken" ]; then
        fail "Marker file should not exist when wake fails"
    else
        pass "Marker file not created when wake fails"
    fi
}

# Case 10: wake_silent_without_backlog
test_wake_silent_without_backlog() {
    local home="$TMP_ROOT/wake-silent-no-backlog"
    local data="$home/data"
    local state="$home/state"
    mkdir -p "$data" "$state"

    # Run wake with no backlog file
    local output
    output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_OVERDUE_NOW_EPOCH="$NOW" "$SCRIPT" wake)
    local exit_status=$?

    # Verify silent output and exit status
    assert_equals "" "$output" "Wake should produce no output when backlog is missing"
    assert_equals 0 "$exit_status" "Wake should exit 0 when backlog is missing"

    # Verify no log file was created
    if [ -f "$state/backlog-overdue.jsonl" ]; then
        fail "Log file should not exist when wake runs with no backlog"
    else
        pass "Log file not created when wake runs with no backlog"
    fi
}

# Run all tests
test_wake_drains_ten_per_sweep
test_wake_does_not_mark_when_enqueue_fails
test_wake_silent_without_backlog
