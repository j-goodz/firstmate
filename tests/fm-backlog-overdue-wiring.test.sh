# tests/fm-backlog-overdue-wiring.test.sh
# Tests that the overdue scanner is wired into the watcher's check sweep and the wake drain.
# Runs real executables from the outside with a tiny backlog fixture.
# shellcheck shell=bash

set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create a temp root for this test suite (used by make_case)
export TMP_ROOT
TMP_ROOT="$(fm_test_tmproot fm-backlog-overdue-wiring)"

# Helper to write the fixture backlog with a stale item (overdue since 2020)
write_stale_backlog() {
    local dir="$1"
    mkdir -p "$dir/data"
    cat >"$dir/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] stale-one - A queued item nobody dispatched (repo: x) (kind: ship) (since 2020-01-01)

## Done
EOF
}

# Helper to write a fresh backlog (no overdue items)
write_fresh_backlog() {
    local dir="$1"
    local today
    today="$(date -u +%F)"
    mkdir -p "$dir/data"
    cat >"$dir/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] fresh-one - Fresh (repo: x) (kind: ship) (since $today)

## Done
EOF
}

# Test 1: drain prints overdue on heartbeat
drain_prints_overdue_on_heartbeat() {
    local case_dir state dir out
    case_dir="$(make_case drain-heartbeat)"
    state="$case_dir/state"
    dir="$case_dir"
    write_stale_backlog "$dir"

    append_wake "$state" heartbeat heartbeat heartbeat

    out="$("$ROOT/bin/fm-wake-drain.sh" \
        FM_STATE_OVERRIDE="$state" \
        FM_DATA_OVERRIDE="$dir/data" \
        2>/dev/null)" || return 1

    assert_contains "$out" "OVERDUE (1 item(s)" "heartbeat drain shows OVERDUE header"
    assert_contains "$out" "stale-one - A queued item nobody dispatched" "heartbeat drain shows stale item"
    pass "drain_prints_overdue_on_heartbeat"
}

# Test 2: drain prints overdue for overdue check wake
drain_prints_overdue_for_overdue_check_wake() {
    local case_dir state dir out
    case_dir="$(make_case drain-check-wake)"
    state="$case_dir/state"
    dir="$case_dir"
    write_stale_backlog "$dir"

    append_wake "$state" check "backlog-overdue:stale-one" \
        "backlog-overdue: stale-one - A queued item nobody dispatched: 9999d overdue (queued 9999d, never dispatched); dispatch it, re-hold it with a new date, or close it with a reason"

    out="$("$ROOT/bin/fm-wake-drain.sh" \
        FM_STATE_OVERRIDE="$state" \
        FM_DATA_OVERRIDE="$dir/data" \
        2>/dev/null)" || return 1

    assert_contains "$out" "OVERDUE (" "check wake drain shows OVERDUE header"
    pass "drain_prints_overdue_for_overdue_check_wake"
}

# Test 3: drain stays quiet for other wakes (signal)
drain_stays_quiet_for_other_wakes() {
    local case_dir state dir out
    case_dir="$(make_case drain-signal)"
    state="$case_dir/state"
    dir="$case_dir"
    write_stale_backlog "$dir"

    append_wake "$state" signal t1 "signal: t1 done"

    out="$("$ROOT/bin/fm-wake-drain.sh" \
        FM_STATE_OVERRIDE="$state" \
        FM_DATA_OVERRIDE="$dir/data" \
        2>/dev/null)" || return 1

    assert_not_contains "$out" "OVERDUE (" "signal wake does not trigger OVERDUE"
    pass "drain_stays_quiet_for_other_wakes"
}

# Test 4: drain stays quiet with no overdue items
drain_stays_quiet_with_no_overdue() {
    local case_dir state dir out
    case_dir="$(make_case drain-fresh)"
    state="$case_dir/state"
    dir="$case_dir"
    write_fresh_backlog "$dir"

    append_wake "$state" heartbeat heartbeat heartbeat

    out="$("$ROOT/bin/fm-wake-drain.sh" \
        FM_STATE_OVERRIDE="$state" \
        FM_DATA_OVERRIDE="$dir/data" \
        2>/dev/null)" || return 1

    assert_not_contains "$out" "OVERDUE (" "fresh backlog does not trigger OVERDUE"
    pass "drain_stays_quiet_with_no_overdue"
}

# Test 5: watcher raises check wake for overdue item
watcher_raises_check_wake_for_overdue_item() {
    local home state_dir data_dir out err status wake_queue jsonl
    home="$(make_case watcher-overdue)"
    state_dir="$home/state"
    data_dir="$home/data"
    mkdir -p "$state_dir" "$data_dir"
    write_stale_backlog "$home"

    # Arm the check first
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-backlog-overdue.sh" arm >/dev/null 2>&1 || return 1

    # First run: should raise check wake
    out=""
    err=""
    status=0
    env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 \
        "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 10 >"$home/out1" 2>"$home/err1" || status=$?
    out="$(cat "$home/out1")"
    err="$(cat "$home/err1")"

    if [[ $status -ne 0 ]]; then
        fail "watcher_raises_check_wake_for_overdue_item: first run exit code $status, err: $err"
    fi

    assert_contains "$out" "check:" "first run output contains check:"
    assert_contains "$out" "backlog-overdue" "first run output contains backlog-overdue"

    wake_queue="$state_dir/.wake-queue"
    if [[ ! -f "$wake_queue" ]]; then
        fail "watcher_raises_check_wake_for_overdue_item: wake queue not created"
    fi
    assert_contains "$(cat "$wake_queue")" "backlog-overdue:stale-one" "wake queue contains backlog-overdue:stale-one"

    jsonl="$state_dir/backlog-overdue.jsonl"
    if [[ ! -f "$jsonl" ]]; then
        fail "watcher_raises_check_wake_for_overdue_item: backlog-overdue.jsonl not created"
    fi
    # Check JSONL has a line with .id == "stale-one"
    if ! jq -e 'select(.id == "stale-one")' "$jsonl" >/dev/null 2>&1; then
        fail "watcher_raises_check_wake_for_overdue_item: jsonl missing stale-one entry"
    fi

    # Second run immediately: should NOT raise another wake (once per day)
    out=""
    err=""
    status=0
    env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 \
        "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 10 >"$home/out2" 2>"$home/err2" || status=$?
    out="$(cat "$home/out2")"
    err="$(cat "$home/err2")"

    if [[ $status -ne 0 ]]; then
        fail "watcher_raises_check_wake_for_overdue_item: second run exit code $status, err: $err"
    fi

    assert_not_contains "$out" "backlog-overdue" "second run does not contain backlog-overdue (one wake per day)"

    pass "watcher_raises_check_wake_for_overdue_item"
}

# Run all tests
drain_prints_overdue_on_heartbeat
drain_prints_overdue_for_overdue_check_wake
drain_stays_quiet_for_other_wakes
drain_stays_quiet_with_no_overdue
watcher_raises_check_wake_for_overdue_item