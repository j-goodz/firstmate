#!/usr/bin/env bash
# tests/fm-suite-slot-run.test.sh - the `run` subcommand of bin/fm-suite-slot.sh.
#
# Covers pass-through of output, input and exit codes, mutual exclusion and
# queueing, wait timeouts, the zero-slot refusal, the nested-run bypass, a
# SIGKILLed holder freeing its slot, SIGTERM forwarding, heat and memory
# waits, and the lock descriptor not leaking into the command. Every case
# drives the real script with its own state directory and a fixture meminfo.
# The wait_for expressions are evaluated later on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_SUITE_SLOT_HELD FM_SUITE_SLOTS FM_SUITE_NPROC FM_HOME FM_THERMAL_SYSFS FM_HWMON_SYSFS FM_TASK_ID FM_SUITE_MIN_AVAILABLE_MB

SLOT="$ROOT/bin/fm-suite-slot.sh"
TMP_ROOT=$(fm_test_tmproot fm-suite-slot-run)
printf 'MemAvailable:    8388608 kB\n' > "$TMP_ROOT/meminfo"
export FM_SUITE_MEMINFO="$TMP_ROOT/meminfo"
export FM_SUITE_CONFIG="$TMP_ROOT/no-such-config"
HOLDERS=()

cleanup_holders() {
    local pid
    for pid in "${HOLDERS[@]+"${HOLDERS[@]}"}"; do
        kill -9 "$pid" 2> /dev/null || true
    done
}
trap 'cleanup_holders' EXIT

# new_case <name> <slots>: a fresh state dir and slot count for one case.
new_case() {
    FM_SUITE_STATE_DIR="$TMP_ROOT/$1/state"
    FM_SUITE_SLOTS=$2
    export FM_SUITE_STATE_DIR FM_SUITE_SLOTS
    mkdir -p "$TMP_ROOT/$1"
    CASE="$TMP_ROOT/$1"
}

wait_for() {  # <shell expression>: poll up to about 15 seconds
    local n=0
    while ! eval "$1"; do
        n=$((n + 1))
        [ "$n" -lt 150 ] || fail "timed out waiting for: $1"
        sleep 0.1
    done
}

held_count() {
    "$SLOT" status | sed -n '1s/.* held=\([0-9]*\) .*/\1/p'
}

# hold_slot <seconds>: a background run holding one slot; sets HOLDER_PID.
hold_slot() {
    "$SLOT" run --key holder -- sleep "$1" > /dev/null 2>&1 &
    HOLDER_PID=$!
    HOLDERS+=("$HOLDER_PID")
}

test_run_passes_output_input_and_exit_code_through() {
    local rc out
    new_case basic 1
    "$SLOT" run -- sh -c 'exit 7' 2> /dev/null
    rc=$?
    expect_code 7 "$rc" "a failing command's status must come back"
    "$SLOT" run -- true
    expect_code 0 "$?" "a passing command's status must come back"
    out=$("$SLOT" run -- echo hello)
    assert_equals hello "$out" "stdout must pass through"
    out=$(printf 'line in\n' | "$SLOT" run -- cat)
    assert_equals "line in" "$out" "stdin must pass through"
    out=$("$SLOT" run -- sh -c 'echo "$FM_SUITE_SLOT_HELD $FM_SUITE_SLOT_INDEX"')
    assert_equals "1 0" "$out" "the command must see the held marker and its slot index"
    "$SLOT" run -- /no/such/command 2> /dev/null
    expect_code 127 "$?" "a missing command must exit 127"
    pass "run passes output, input and exit codes through"
}

test_second_run_waits_for_the_first() {
    new_case mutual 1
    local marker="$CASE/marker"
    "$SLOT" run --key A -- sh -c "echo A-start >> '$marker'; sleep 2; echo A-end >> '$marker'" &
    local a=$!
    HOLDERS+=("$a")
    wait_for "grep -q A-start '$marker' 2> /dev/null"
    "$SLOT" run --key B --poll-secs 0.2 -- sh -c "echo B-start >> '$marker'" 2> /dev/null &
    local b=$!
    wait "$a"
    expect_code 0 "$?" "run A"
    wait "$b"
    expect_code 0 "$?" "run B"
    assert_equals $'A-start\nA-end\nB-start' "$(cat "$marker")" "B must start only after A ended"
    pass "a second run waits until the first has finished"
}

test_wait_secs_bounds_the_wait() {
    local out rc
    new_case timeout 1
    hold_slot 20
    wait_for '[ "$(held_count)" = 1 ]'
    out=$("$SLOT" run --wait-secs 1 --poll-secs 0.2 -- true 2>&1)
    rc=$?
    expect_code 75 "$rc" "--wait-secs 1 on a full house"
    assert_contains "$out" "timed out waiting for a suite slot" "timeout message"
    assert_contains "$out" "waiting for a suite slot (key=default" "the first failed attempt announces the wait"
    out=$("$SLOT" run --wait-secs 0 -- true 2>&1)
    rc=$?
    expect_code 75 "$rc" "--wait-secs 0 on a full house"
    assert_contains "$out" "timed out waiting for a suite slot" "immediate timeout message"
    pass "--wait-secs bounds the wait and exits 75"
}

test_two_slots_allow_two_holders_and_no_third() {
    local out rc
    new_case two 2
    hold_slot 20
    hold_slot 20
    wait_for '[ "$(held_count)" = 2 ]'
    out=$("$SLOT" run --wait-secs 0 -- true 2>&1)
    rc=$?
    expect_code 75 "$rc" "a third run on two slots"
    assert_contains "$out" "timed out waiting" "third run message"
    pass "two slots allow two holders and no third"
}

test_zero_slots_refuse_at_once() {
    local out err rc
    new_case zero 0
    out=$("$SLOT" run -- sh -c 'echo ran' 2> "$CASE/err")
    rc=$?
    err=$(cat "$CASE/err")
    expect_code 75 "$rc" "zero slots"
    assert_contains "$err" "no full-suite slot on this machine" "refusal message"
    assert_equals "" "$out" "the command must not run"
    pass "a machine with zero slots refuses at once"
}

test_nested_run_bypasses_the_gate() {
    local out rc
    new_case bypass 1
    hold_slot 20
    wait_for '[ "$(held_count)" = 1 ]'
    : > "$FM_SUITE_STATE_DIR/events.jsonl"
    out=$(FM_SUITE_SLOT_HELD=1 "$SLOT" run -- echo nested)
    rc=$?
    expect_code 0 "$rc" "nested run"
    assert_equals nested "$out" "nested command output"
    out=$(FM_SUITE_SLOT_HELD=1 FM_SUITE_SLOTS=0 "$SLOT" run -- echo nested0)
    assert_equals nested0 "$out" "nested run ignores the slot count"
    assert_equals "0" "$(wc -l < "$FM_SUITE_STATE_DIR/events.jsonl" | tr -d ' ')" "a nested run logs nothing"
    pass "a nested run (FM_SUITE_SLOT_HELD=1) bypasses the gate and the log"
}

test_sigkilled_run_frees_its_slot() {
    new_case sigkill 1
    "$SLOT" run -- sleep 30 > /dev/null 2>&1 &
    local run_pid=$!
    wait_for '[ "$(held_count)" = 1 ]'
    kill -9 "$run_pid" 2> /dev/null
    wait "$run_pid" 2> /dev/null
    wait_for '[ "$(held_count)" = 0 ]'
    "$SLOT" run --wait-secs 3 -- true
    expect_code 0 "$?" "a new run after the holder was killed"
    pkill -f 'sleep 30' -P 1 2> /dev/null || true
    pass "a SIGKILLed run frees its slot"
}

test_sigterm_reaches_the_command() {
    new_case sigterm 1
    local ready="$CASE/ready" mark="$CASE/mark"
    "$SLOT" run -- bash -c "trap 'echo got-term > \"$mark\"; exit 0' TERM; echo up > \"$ready\"; while :; do sleep 0.1; done" &
    local run_pid=$!
    HOLDERS+=("$run_pid")
    wait_for "[ -f '$ready' ]"
    kill -TERM "$run_pid"
    wait_for "! kill -0 $run_pid 2> /dev/null"
    assert_equals got-term "$(cat "$mark" 2> /dev/null)" "SIGTERM must reach the command"
    pass "SIGTERM sent to run is forwarded to the command"
}

test_heat_hold_waits_then_clears() {
    local out rc
    new_case heat 1
    mkdir -p "$CASE/sysfs/thermal_zone0"
    printf 'x86_pkg_temp\n' > "$CASE/sysfs/thermal_zone0/type"
    printf '85000\n' > "$CASE/sysfs/thermal_zone0/temp"
    printf 'slots=1\nhot_c=70\nhold_c=80\n' > "$CASE/config"
    export FM_THERMAL_SYSFS="$CASE/sysfs" FM_HWMON_SYSFS="$CASE/hwmon"
    out=$(FM_SUITE_CONFIG="$CASE/config" "$SLOT" run --wait-secs 1 --poll-secs 0.2 -- true 2>&1)
    rc=$?
    expect_code 75 "$rc" "run while the machine is at its heat hold"
    assert_contains "$out" "tier=hold" "the wait names the heat tier"
    printf '40000\n' > "$CASE/sysfs/thermal_zone0/temp"
    FM_SUITE_CONFIG="$CASE/config" "$SLOT" run --wait-secs 3 -- true
    expect_code 0 "$?" "run after the machine cooled"
    unset FM_THERMAL_SYSFS FM_HWMON_SYSFS
    pass "a heat hold waits like a full house and clears when cool"
}

test_memory_pressure_waits_then_clears() {
    local out rc
    new_case mem 1
    printf 'MemAvailable:    102400 kB\n' > "$CASE/meminfo"
    out=$(FM_SUITE_MEMINFO="$CASE/meminfo" "$SLOT" run --wait-secs 1 --poll-secs 0.2 -- true 2>&1)
    rc=$?
    expect_code 75 "$rc" "run under memory pressure"
    assert_contains "$out" "memory pressure" "the wait names memory pressure"
    FM_SUITE_MEMINFO="$CASE/meminfo" FM_SUITE_MIN_AVAILABLE_MB=50 "$SLOT" run --wait-secs 3 -- true
    expect_code 0 "$?" "run with a lower memory floor"
    pass "memory pressure waits and clears with a lower floor"
}

test_leaked_child_does_not_keep_the_slot() {
    new_case leak 1
    "$SLOT" run -- bash -c '(sleep 7 &); true'
    expect_code 0 "$?" "the run itself"
    assert_equals 0 "$(held_count)" "a leaked background child must not hold the slot"
    pass "the lock descriptor is not inherited by the command"
}

test_host_without_flock_runs_ungated_and_status_prints() {
    local sans rc first
    new_case noflock 1
    sans=$(fm_test_base_path_sans "$PATH" flock)
    mkdir -p "$FM_SUITE_STATE_DIR"
    : > "$FM_SUITE_STATE_DIR/slot.0.lock"
    PATH="$sans" "$SLOT" run --wait-secs 1 --poll-secs 0.2 -- sh -c 'exit 3' > "$CASE/out" 2> "$CASE/err"
    rc=$?
    expect_code 3 "$rc" "a host without flock must run the command and return its status"
    assert_equals "" "$(cat "$CASE/out")" "the command output still passes through"
    assert_contains "$(cat "$CASE/err")" "running ungated" "the no-flock warning"
    first=$(PATH="$sans" "$SLOT" status | sed -n '1p')
    assert_contains "$first" "capacity=1" "status still prints its first line"
    assert_contains "$first" "held=0" "a lock file is not counted held when flock is missing"
    pass "a host without flock runs ungated and status still prints"
}

test_run_passes_output_input_and_exit_code_through
test_second_run_waits_for_the_first
test_wait_secs_bounds_the_wait
test_two_slots_allow_two_holders_and_no_third
test_zero_slots_refuse_at_once
test_nested_run_bypasses_the_gate
test_sigkilled_run_frees_its_slot
test_sigterm_reaches_the_command
test_heat_hold_waits_then_clears
test_memory_pressure_waits_then_clears
test_leaked_child_does_not_keep_the_slot
test_host_without_flock_runs_ungated_and_status_prints
