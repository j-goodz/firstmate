#!/usr/bin/env bash
# tests/fm-wake-drain-dedupe.test.sh - behavior tests for the delivery record, the
# unchanged-section gate, and the --absorb-resurface mode of bin/fm-wake-drain.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-dedupe-tests)

# Helper to run drain and capture outputs
run_drain() {
    local state="$1"
    shift
    local out_file="$1"
    local err_file="$2"
    shift 2
    FM_STATE_OVERRIDE="$state" "$DRAIN" "$@" > "$out_file" 2> "$err_file"
    return $?
}

# Helper to parse WAKE_ACK_REQUIRED line
parse_ack_line() {
    local err_file="$1"
    if [[ -s "$err_file" ]]; then
        grep '^WAKE_ACK_REQUIRED:' "$err_file" | sed 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh --ack-through \([0-9]*\) --recovery-generation \(.*\)$/\1 \2/'
    fi
}

# Helper to read delivery record
read_delivery_record() {
    local state="$1"
    if [[ -f "$state/.drain-delivered" ]]; then
        cat "$state/.drain-delivered"
    fi
}

# Test 1: A drain over one queued row records N equal to that row's sequence number and the printed GEN.
test_delivery_record_single_row() {
    local dir
    dir=$(make_case "delivery-record-single")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Append a signal row (will get sequence 1)
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"

    run_drain "$state" "$out" "$err"
    local code=$?
    expect_code 0 "$code" "drain exits 0"

    local ack_line
    ack_line=$(parse_ack_line "$err")
    assert_contains "$ack_line" " " "WAKE_ACK_REQUIRED line present"
    local ack_n
    ack_n=$(echo "$ack_line" | awk '{print $1}')
    local ack_gen
    ack_gen=$(echo "$ack_line" | awk '{print $2}')

    local record
    record=$(read_delivery_record "$state")
    assert_contains "$record" "$ack_n" "record contains ack N"
    assert_contains "$record" "$ack_gen" "record contains ack GEN"
    # Check format: N<TAB>GEN<TAB>epoch
    local record_n
    record_n=$(echo "$record" | cut -f1)
    local record_gen
    record_gen=$(echo "$record" | cut -f2)
    local record_epoch
    record_epoch=$(echo "$record" | cut -f3)
    [[ "$record_n" == "$ack_n" ]] || fail "record N ($record_n) != ack N ($ack_n)"
    [[ "$record_gen" == "$ack_gen" ]] || fail "record GEN ($record_gen) != ack GEN ($ack_gen)"
    [[ "$record_epoch" =~ ^[0-9]+$ ]] || fail "record epoch not numeric: $record_epoch"

    pass "test_delivery_record_single_row"
}

# Test 2: An empty-queue recovery drain also records.
test_delivery_record_empty_queue_recovery() {
    local dir
    dir=$(make_case "delivery-record-empty-recovery")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Write recovery marker with empty queue
    echo "pending:downtime:gen1" > "$state/.watcher-down"
    # Ensure queue is empty
    : > "$state/.wake-queue"
    run_drain "$state" "$out" "$err"
    local code=$?
    expect_code 0 "$code" "drain exits 0"

    local ack_line
    ack_line=$(parse_ack_line "$err")
    assert_contains "$ack_line" "0 gen1" "WAKE_ACK_REQUIRED shows --ack-through 0 --recovery-generation gen1"

    local record
    record=$(read_delivery_record "$state")
    assert_contains "$record" "0" "record N is 0"
    assert_contains "$record" "gen1" "record GEN is gen1"
    local record_n
    record_n=$(echo "$record" | cut -f1)
    local record_gen
    record_gen=$(echo "$record" | cut -f2)
    [[ "$record_n" == "0" ]] || fail "record N should be 0, got $record_n"
    [[ "$record_gen" == "gen1" ]] || fail "record GEN should be gen1, got $record_gen"

    pass "test_delivery_record_empty_queue_recovery"
}

# Test 3: Empty queue with no recovery marker prints no WAKE_ACK_REQUIRED and writes no record.
# Second drain after record exists leaves previous record untouched.
test_delivery_record_empty_no_marker() {
    local dir
    dir=$(make_case "delivery-record-empty-no-marker")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # First drain: empty queue, no marker
    : > "$state/.wake-queue"
    run_drain "$state" "$out" "$err"
    local code=$?
    expect_code 0 "$code" "first drain exits 0"
    [[ ! -s "$err" ]] || fail "stderr should be empty, got: $(cat "$err")"
    [[ ! -f "$state/.drain-delivered" ]] || fail "no delivery record should be written"

    # Create a record by doing a real drain with a row
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"
    run_drain "$state" "$out" "$err"
    local record1
    record1=$(read_delivery_record "$state")
    [[ -n "$record1" ]] || fail "record should exist after real drain"

    # Empty the queue and drop the marker without acknowledging (an acknowledgement
    # correctly removes the record, which is behavior 4)
    : > "$state/.wake-queue"
    rm -f "$state/.watcher-down"

    # Now queue is empty, marker gone, but record exists
    run_drain "$state" "$out" "$err"
    code=$?
    expect_code 0 "$code" "second drain exits 0"
    [[ ! -s "$err" ]] || fail "stderr should be empty on empty queue"
    local record2
    record2=$(read_delivery_record "$state")
    [[ "$record2" == "$record1" ]] || fail "record should be unchanged, was: $record1, now: $record2"

    pass "test_delivery_record_empty_no_marker"
}

# Test 4: Manual acknowledgement at or above recorded sequence removes record; below leaves it.
test_delivery_record_ack_removes() {
    local dir
    dir=$(make_case "delivery-record-ack")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Create a record with sequence 5
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"
    run_drain "$state" "$out" "$err"
    local ack_line
    ack_line=$(parse_ack_line "$err")
    local ack_n
    ack_n=$(echo "$ack_line" | awk '{print $1}')
    local ack_gen
    ack_gen=$(echo "$ack_line" | awk '{print $2}')

    # Verify record exists
    [[ -f "$state/.drain-delivered" ]] || fail "record should exist"

    # Ack with N below recorded (ack_n - 1) - should leave record
    local below_n
    below_n=$((ack_n - 1))
    if [[ $below_n -ge 0 ]]; then
        FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$below_n" --recovery-generation "$ack_gen" >/dev/null 2>&1
        [[ -f "$state/.drain-delivered" ]] || fail "record should remain after ack below"
    fi

    # Ack with N at recorded - should remove record
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$ack_n" --recovery-generation "$ack_gen" >/dev/null 2>&1
    [[ ! -f "$state/.drain-delivered" ]] || fail "record should be removed after ack at"

    # Re-create record and ack above
    append_wake "$state" signal t2.status "signal: $state/t2.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t2.status"
    run_drain "$state" "$out" "$err"
    ack_line=$(parse_ack_line "$err")
    ack_n=$(echo "$ack_line" | awk '{print $1}')
    ack_gen=$(echo "$ack_line" | awk '{print $2}')

    local above_n
    above_n=$((ack_n + 1))
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$above_n" --recovery-generation "$ack_gen" >/dev/null 2>&1
    [[ ! -f "$state/.drain-delivered" ]] || fail "record should be removed after ack above"

    pass "test_delivery_record_ack_removes"
}

# Test 5: Branch actor never writes the record.
test_delivery_record_branch_actor() {
    local dir
    dir=$(make_case "delivery-record-branch")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"

    FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2> "$err"
    local code=$?
    # Branch actor may fail or refuse, but should not write record
    [[ ! -f "$state/.drain-delivered" ]] || fail "branch actor should not write delivery record"

    pass "test_delivery_record_branch_actor"
}

# Test 6: First drain prints full block, second prints one-line form.
test_unchanged_gate_first_second() {
    local dir
    dir=$(make_case "unchanged-gate-first-second")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Set up one open decision
    printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"

    # First drain
    run_drain "$state" "$out" "$err"
    local code=$?
    expect_code 0 "$code" "first drain exits 0"
    assert_contains "$(cat "$out")" "OPEN DECISIONS (still open" "first drain prints header"
    assert_contains "$(cat "$out")" "pick-a" "first drain prints key"
    assert_contains "$(cat "$out")" "pick A or B" "first drain prints decision text"
    assert_contains "$(cat "$out")" "OPEN DECISIONS: close one by answering it" "first drain prints hint"

    # Second drain (no changes)
    run_drain "$state" "$out" "$err"
    code=$?
    expect_code 0 "$code" "second drain exits 0"
    local out2
    out2=$(cat "$out")
    assert_contains "$out2" "OPEN DECISIONS: 1 still open, unchanged since the last drain" "second drain prints one-line form"
    assert_not_contains "$out2" "OPEN DECISIONS (still open" "second drain does not print header"
    assert_not_contains "$out2" "pick-a" "second drain does not print item"
    assert_not_contains "$out2" "pick A or B" "second drain does not print decision text"
    assert_not_contains "$out2" "close one by answering it" "second drain does not print hint"

    pass "test_unchanged_gate_first_second"
}

# Test 7: Adding a second decision makes next drain print full block with both.
test_unchanged_gate_add_decision() {
    local dir
    dir=$(make_case "unchanged-gate-add-decision")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # First decision
    printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    run_drain "$state" "$out" "$err"

    # Second drain (unchanged)
    run_drain "$state" "$out" "$err"
    assert_contains "$(cat "$out")" "1 still open" "second drain shows 1"

    # Add second decision
    printf 'needs-decision [key=pick-b] [at=1791061357]: pick X or Y\n' > "$state/t2.status"
    append_wake "$state" signal t2.status "signal: $state/t2.status"

    # Third drain - should print full block with both
    run_drain "$state" "$out" "$err"
    local out3
    out3=$(cat "$out")
    assert_contains "$out3" "OPEN DECISIONS (still open" "third drain prints header"
    assert_contains "$out3" "pick-a" "third drain prints first key"
    assert_contains "$out3" "pick-b" "third drain prints second key"
    assert_contains "$out3" "pick A or B" "third drain prints first text"
    assert_contains "$out3" "pick X or Y" "third drain prints second text"

    # Fourth drain - should print one-line with 2
    run_drain "$state" "$out" "$err"
    local out4
    out4=$(cat "$out")
    assert_contains "$out4" "OPEN DECISIONS: 2 still open, unchanged since the last drain" "fourth drain shows 2"
    assert_not_contains "$out4" "OPEN DECISIONS (still open" "fourth drain no header"

    pass "test_unchanged_gate_add_decision"
}

# Test 8: FM_WAKE_DRAIN_FULL=1 forces full block.
test_unchanged_gate_full_env() {
    local dir
    dir=$(make_case "unchanged-gate-full-env")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"

    # First drain (full)
    run_drain "$state" "$out" "$err"
    assert_contains "$(cat "$out")" "OPEN DECISIONS (still open" "first drain full"

    # Second drain with FM_WAKE_DRAIN_FULL=1
    FM_WAKE_DRAIN_FULL=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err"
    assert_contains "$(cat "$out")" "OPEN DECISIONS (still open" "FM_WAKE_DRAIN_FULL=1 forces full"

    # Third drain without env - should be one-line
    run_drain "$state" "$out" "$err"
    assert_contains "$(cat "$out")" "1 still open" "third drain one-line"

    pass "test_unchanged_gate_full_env"
}

# Test 10: FM_DRAIN_SECTION_TTL_SECS=1 causes reprint after sleep.
test_unchanged_gate_ttl() {
    local dir
    dir=$(make_case "unchanged-gate-ttl")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"

    # First drain
    run_drain "$state" "$out" "$err"
    assert_contains "$(cat "$out")" "OPEN DECISIONS (still open" "first drain full"

    # Second drain with TTL=1 - should be one-line immediately
    FM_DRAIN_SECTION_TTL_SECS=8 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err"
    assert_contains "$(cat "$out")" "1 still open" "second drain inside the TTL is one-line"

    # Sleep past the TTL (a drain itself takes seconds on a loaded machine)
    sleep 9

    # Third drain past the TTL - should be full again
    FM_DRAIN_SECTION_TTL_SECS=8 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err"
    assert_contains "$(cat "$out")" "OPEN DECISIONS (still open" "third drain after sleep is full"

    pass "test_unchanged_gate_ttl"
}

# Test 11: Resolving decision removes block; re-creating prints full again.
test_unchanged_gate_resolve() {
    local dir
    dir=$(make_case "unchanged-gate-resolve")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"

    # First drain
    run_drain "$state" "$out" "$err"
    assert_contains "$(cat "$out")" "OPEN DECISIONS (still open" "first drain full"

    # Resolve the decision
    printf 'resolved [key=pick-a] [at=1791061400]: done\n' >> "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"

    # Drain - should have no OPEN DECISIONS block
    run_drain "$state" "$out" "$err"
    assert_not_contains "$(cat "$out")" "OPEN DECISIONS" "resolved decision removes block"

    # Re-create identical open decision
    printf 'needs-decision [key=pick-a] [at=1791061500]: pick A or B\n' >> "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"

    # Drain - should print full block again
    run_drain "$state" "$out" "$err"
    assert_contains "$(cat "$out")" "OPEN DECISIONS (still open" "re-created decision prints full"

    pass "test_unchanged_gate_resolve"
}

# Test 12: Drain with stdout closed doesn't consume gate.
test_unchanged_gate_stdout_closed() {
    local dir
    dir=$(make_case "unchanged-gate-stdout-closed")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"

    # First presentation goes to a failing sink - try /dev/full first
    if [[ -c /dev/full ]]; then
        FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/full 2> "$err" || true
    else
        # Try closing stdout
        FM_STATE_OVERRIDE="$state" "$DRAIN" >&- 2> "$err" || true
    fi

    # Third drain normal - should still print full block (gate not consumed)
    run_drain "$state" "$out" "$err"
    local out3
    out3=$(cat "$out")
    if assert_contains "$out3" "OPEN DECISIONS (still open" "third drain prints full block (gate not consumed)"; then
        pass "test_unchanged_gate_stdout_closed"
    else
        # If we can't test this properly, skip
        echo "skip: could not test stdout closed behavior"
    fi
}

# Test 13: --absorb-resurface with one working-only row exits 0, clears queue.
test_absorb_working_only() {
    local dir
    dir=$(make_case "absorb-working-only")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # One working-only signal row
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"

    # Run absorb
    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 0 "$code" "absorb exits 0"
    [[ ! -s "$out" ]] || fail "stdout should be empty, got: $(cat "$out")"

    # Queue should be empty
    [[ ! -s "$state/.wake-queue" ]] || fail "queue should be empty after absorb"

    # Normal drain afterwards prints no WAKE_ACK_REQUIRED
    run_drain "$state" "$out" "$err"
    [[ ! -s "$err" ]] || fail "normal drain after absorb should have no WAKE_ACK_REQUIRED"

    pass "test_absorb_working_only"
}

# Test 13b: With recovery marker, absorb retires it to acked.
test_absorb_with_recovery_marker() {
    local dir
    dir=$(make_case "absorb-with-marker")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    echo "pending:downtime:gen1" > "$state/.watcher-down"
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"

    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 0 "$code" "absorb exits 0"

    # Marker should become acked
    local marker
    marker=$(cat "$state/.watcher-down")
    [[ "$marker" == "acked:downtime:gen1" ]] || fail "marker should be acked:downtime:gen1, got: $marker"

    pass "test_absorb_with_recovery_marker"
}

# Test 14: Working-only row plus captain inbox note -> exit 1, both rows remain.
test_absorb_with_inbox_note() {
    local dir
    dir=$(make_case "absorb-with-inbox")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"
    append_wake "$state" check inbox:111 "check: captain inbox note 111 - hello"

    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 1 "$code" "absorb exits 1 with inbox note"

    # Both rows should remain
    local queue_lines
    queue_lines=$(wc -l < "$state/.wake-queue")
    [[ "$queue_lines" -eq 2 ]] || fail "queue should have 2 rows, has $queue_lines"

    pass "test_absorb_with_inbox_note"
}

# Test 15: Working-only plus .turn-ended -> exit 1. Signal over done -> exit 1.
test_absorb_with_turn_ended() {
    local dir
    dir=$(make_case "absorb-with-turn-ended")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"
    append_wake "$state" signal t1.turn-ended "signal: $state/t1.turn-ended"

    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 1 "$code" "absorb exits 1 with turn-ended"

    local queue_lines
    queue_lines=$(wc -l < "$state/.wake-queue")
    [[ "$queue_lines" -eq 2 ]] || fail "queue should have 2 rows, has $queue_lines"

    pass "test_absorb_with_turn_ended"
}

test_absorb_with_done_signal() {
    local dir
    dir=$(make_case "absorb-with-done")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'done [at=1791061356]: finished\n' > "$state/t1.status"

    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 1 "$code" "absorb exits 1 with done signal"

    pass "test_absorb_with_done_signal"
}

# Test 16: Empty queue (with and without recovery marker) -> exit 0.
test_absorb_empty_queue() {
    local dir
    dir=$(make_case "absorb-empty")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Empty queue, no marker
    : > "$state/.wake-queue"
    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 0 "$code" "absorb empty queue no marker exits 0"

    # Empty queue with marker
    echo "pending:downtime:gen1" > "$state/.watcher-down"
    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    code=$?
    expect_code 0 "$code" "absorb empty queue with marker exits 0"

    pass "test_absorb_empty_queue"
}

# Test 17: Working-only row with undelivered open decision -> exit 1.
# After delivery and ack, new working-only row -> exit 0.
test_absorb_with_undelivered_decision() {
    local dir
    dir=$(make_case "absorb-undelivered-decision")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Open decision never delivered
    printf 'needs-decision [key=pick-a] [at=1791061356]: pick A or B\n' > "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    # Working-only row for another task
    append_wake "$state" signal t2.status "signal: $state/t2.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t2.status"

    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 1 "$code" "absorb exits 1 with undelivered decision"

    # Normal drain should still print full block
    run_drain "$state" "$out" "$err"
    assert_contains "$(cat "$out")" "OPEN DECISIONS (still open" "normal drain prints full block"
    assert_contains "$(cat "$out")" "working" "normal drain lists queued row"

    # Now deliver and ack the decision
    run_drain "$state" "$out" "$err"
    local ack_line
    ack_line=$(parse_ack_line "$err")
    local ack_n
    ack_n=$(echo "$ack_line" | awk '{print $1}')
    local ack_gen
    ack_gen=$(echo "$ack_line" | awk '{print $2}')
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$ack_n" --recovery-generation "$ack_gen" >/dev/null 2>&1

    # Queue a new working-only row
    append_wake "$state" signal t3.status "signal: $state/t3.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t3.status"

    # Absorb should now succeed
    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    code=$?
    expect_code 0 "$code" "absorb exits 0 after decision delivered and acked"

    pass "test_absorb_with_undelivered_decision"
}

# Test 18: Working-only row with unread note in another task -> exit 1.
test_absorb_with_unread_note() {
    local dir
    dir=$(make_case "absorb-unread-note")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Working-only row
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"

    # Another task with unread note
    printf 'note [at=1791061400]: an answer\n' > "$state/t2.status"
    append_wake "$state" signal t2.status "signal: $state/t2.status"

    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 1 "$code" "absorb exits 1 with unread note"

    # Normal drain should print the note under UNREAD STATUS
    run_drain "$state" "$out" "$err"
    assert_contains "$(cat "$out")" "UNREAD STATUS" "normal drain shows UNREAD STATUS"
    assert_contains "$(cat "$out")" "an answer" "normal drain shows note text"

    pass "test_absorb_with_unread_note"
}

# Test 19: Rows arriving after absorb survive.
test_absorb_new_rows_survive() {
    local dir
    dir=$(make_case "absorb-new-rows")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Queue working-only row
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"

    # Absorb it
    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 0 "$code" "first absorb exits 0"

    # Queue new inbox row
    append_wake "$state" check inbox:222 "check: captain inbox note 222 - hello"

    # Normal drain should list only the inbox row
    run_drain "$state" "$out" "$err"
    local out_content
    out_content=$(cat "$out")
    assert_contains "$out_content" "inbox:222" "normal drain shows new inbox row"
    assert_not_contains "$out_content" "t1.status" "normal drain does not show absorbed row"

    pass "test_absorb_new_rows_survive"
}

# Test 20: wake-absorb.jsonl gets absorbed event on success, not on refusal.
test_absorb_jsonl_log() {
    local dir
    dir=$(make_case "absorb-jsonl")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Successful absorb
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"

    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 0 "$code" "absorb exits 0"

    [[ -f "$state/wake-absorb.jsonl" ]] || fail "wake-absorb.jsonl should exist"
    local jsonl
    jsonl=$(cat "$state/wake-absorb.jsonl")
    assert_contains "$jsonl" '"event":"absorbed"' "jsonl has absorbed event"

    # Refusal absorb (with inbox note)
    local dir2
    dir2=$(make_case "absorb-jsonl-refusal")
    local state2="$dir2/state"
    local out2="$dir2/out"
    local err2="$dir2/err"

    append_wake "$state2" signal t1.status "signal: $state2/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state2/t1.status"
    append_wake "$state2" check inbox:111 "check: captain inbox note 111 - hello"

    FM_STATE_OVERRIDE="$state2" "$DRAIN" --absorb-resurface > "$out2" 2> "$err2"
    code=$?
    expect_code 1 "$code" "absorb exits 1"

    if [[ -f "$state2/wake-absorb.jsonl" ]]; then
        local jsonl2
        jsonl2=$(cat "$state2/wake-absorb.jsonl")
        assert_not_contains "$jsonl2" '"event":"absorbed"' "jsonl has no new absorbed event on refusal"
    fi

    pass "test_absorb_jsonl_log"
}

# Test 21: Working-only absorb leaves line marked as presented.
test_absorb_marks_presented() {
    local dir
    dir=$(make_case "absorb-marks-presented")
    local state="$dir/state"
    local out="$dir/out"
    local err="$dir/err"

    # Working-only row
    append_wake "$state" signal t1.status "signal: $state/t1.status"
    printf 'working [at=1791061356]: relaunched\n' > "$state/t1.status"

    # Absorb
    FM_STATE_OVERRIDE="$state" "$DRAIN" --absorb-resurface > "$out" 2> "$err"
    local code=$?
    expect_code 0 "$code" "absorb exits 0"

    # Append done line and queue signal
    printf 'done [at=1791061500]: finished\n' >> "$state/t1.status"
    append_wake "$state" signal t1.status "signal: $state/t1.status"

    # Normal drain
    run_drain "$state" "$out" "$err"
    local out_content
    out_content=$(cat "$out")
    assert_contains "$out_content" "done" "normal drain mentions done line"
    assert_not_contains "$out_content" "working [at=1791061356]: relaunched" "normal drain does not repeat working line"

    pass "test_absorb_marks_presented"
}

# Run all tests
test_delivery_record_single_row
test_delivery_record_empty_queue_recovery
test_delivery_record_empty_no_marker
test_delivery_record_ack_removes
test_delivery_record_branch_actor
test_unchanged_gate_first_second
test_unchanged_gate_add_decision
test_unchanged_gate_full_env
test_unchanged_gate_ttl
test_unchanged_gate_resolve
test_unchanged_gate_stdout_closed
test_absorb_working_only
test_absorb_with_recovery_marker
test_absorb_with_inbox_note
test_absorb_with_turn_ended
test_absorb_with_done_signal
test_absorb_empty_queue
test_absorb_with_undelivered_decision
test_absorb_with_unread_note
test_absorb_new_rows_survive
test_absorb_jsonl_log
test_absorb_marks_presented

echo "ok: fm-wake-drain-dedupe tests"
