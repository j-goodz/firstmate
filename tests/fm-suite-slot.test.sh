#!/usr/bin/env bash
# tests/fm-suite-slot.test.sh - capacity, status and error paths of
# bin/fm-suite-slot.sh (the `run` subcommand has tests/fm-suite-slot-run.test.sh).
#
# The assertions drive the real script with fixture config files, a fake sysfs
# thermal tree and fixture meminfo files, so nothing depends on the machine the
# test happens to run on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_SUITE_SLOT_HELD FM_SUITE_SLOTS FM_SUITE_NPROC FM_HOME FM_THERMAL_SYSFS FM_TASK_ID FM_SUITE_MIN_AVAILABLE_MB

SLOT="$ROOT/bin/fm-suite-slot.sh"
TMP_ROOT=$(fm_test_tmproot fm-suite-slot)
HOLDERS=()
kill_holders() {
    local p
    for p in "${HOLDERS[@]+"${HOLDERS[@]}"}"; do
        kill -9 "$p" 2> /dev/null
    done
}
trap kill_holders EXIT

# new_case <name>: fresh state dir, missing config, roomy meminfo, no sensor.
new_case() {
    CASE="$TMP_ROOT/$1"
    mkdir -p "$CASE/sysfs"
    printf 'MemAvailable:    3145728 kB\n' > "$CASE/meminfo"
    export FM_SUITE_STATE_DIR="$CASE/state" FM_SUITE_CONFIG="$CASE/config" FM_SUITE_MEMINFO="$CASE/meminfo" FM_THERMAL_SYSFS="$CASE/sysfs"
    unset FM_SUITE_SLOTS FM_SUITE_NPROC FM_HOME
}

set_temp() {  # <millidegrees>
    mkdir -p "$CASE/sysfs/thermal_zone0"
    printf 'x86_pkg_temp\n' > "$CASE/sysfs/thermal_zone0/type"
    printf '%s\n' "$1" > "$CASE/sysfs/thermal_zone0/temp"
}

cap() { "$SLOT" capacity; }
tier() { "$SLOT" status | sed -n '1s/.* tier=\([a-z]*\) .*/\1/p'; }

test_capacity_env_beats_config_and_bad_values_are_ignored() {
    new_case capacity
    assert_equals 3 "$(FM_SUITE_SLOTS=3 cap)" "FM_SUITE_SLOTS"
    printf 'slots=2\n' > "$FM_SUITE_CONFIG"
    assert_equals 2 "$(cap)" "config slots"
    assert_equals 3 "$(FM_SUITE_SLOTS=3 cap)" "env beats config"
    assert_equals 2 "$(FM_SUITE_SLOTS=abc cap)" "a non-numeric env value is ignored"
    assert_equals 2 "$(FM_SUITE_SLOTS=-1 cap)" "a negative env value is ignored"
    printf 'slots=nope\n' > "$FM_SUITE_CONFIG"
    assert_equals 2 "$(FM_SUITE_NPROC=12 cap)" "an invalid config value falls to the CPU rule"
    printf '# comment\n\n slots = 4 \nslots=oops\n' > "$FM_SUITE_CONFIG"
    assert_equals 4 "$(cap)" "spaces, comments and a later invalid line"
    pass "env beats config, and invalid values are ignored"
}

test_capacity_from_cpu_count() {
    new_case cpus
    assert_equals 2 "$(FM_SUITE_NPROC=12 cap)" "12 CPUs"
    assert_equals 1 "$(FM_SUITE_NPROC=8 cap)" "8 CPUs"
    assert_equals 0 "$(FM_SUITE_NPROC=5 cap)" "5 CPUs"
    assert_equals 0 "$(FM_SUITE_NPROC=4 cap)" "4 CPUs"
    assert_equals 4 "$(FM_SUITE_NPROC=24 cap)" "24 CPUs"
    pass "one slot per six logical CPUs, rounded down"
}

test_heat_lowers_capacity() {
    new_case heat
    printf 'slots=3\nhot_c=70\nhold_c=80\n' > "$FM_SUITE_CONFIG"
    set_temp 60000
    assert_equals 3 "$(cap)" "cool capacity"
    assert_equals cool "$(tier)" "cool tier"
    set_temp 75000
    assert_equals 1 "$(cap)" "hot capacity"
    assert_equals hot "$(tier)" "hot tier"
    set_temp 85000
    assert_equals 0 "$(cap)" "hold capacity"
    assert_equals hold "$(tier)" "hold tier"
    rm -f "$CASE/sysfs/thermal_zone0/temp"
    assert_equals 3 "$(cap)" "no readable sensor leaves the capacity alone"
    assert_equals unknown "$(tier)" "no sensor tier"
    pass "heat lowers capacity at hot_c and hold_c"
}

test_heat_limits_fall_back_to_the_home_thermal_gate() {
    new_case gate
    printf 'slots=3\n' > "$FM_SUITE_CONFIG"
    mkdir -p "$CASE/home/config"
    printf 'hot_c=70\nhold_c=80\n' > "$CASE/home/config/thermal-gate"
    set_temp 75000
    assert_equals hot "$(FM_HOME="$CASE/home" tier)" "limits read from the home's thermal-gate"
    assert_equals cool "$(tier)" "no FM_HOME, no limits"
    printf 'slots=3\nhot_c=60\nhold_c=75\n' > "$FM_SUITE_CONFIG"
    assert_equals hold "$(FM_HOME="$CASE/home" tier)" "the machine config wins over the thermal-gate"
    pass "hot_c and hold_c fall back to the home thermal-gate, the machine file wins"
}

test_status_first_line_and_slot_lines() {
    local out
    new_case status
    printf 'slots=2\n' > "$FM_SUITE_CONFIG"
    out=$("$SLOT" status)
    assert_equals "capacity=2 base=2 temp=unknown tier=unknown held=0 free=2 avail_mb=3072" "$(printf '%s\n' "$out" | sed -n 1p)" "first line"
    assert_equals "slot=0 free" "$(printf '%s\n' "$out" | sed -n 2p)" "slot 0"
    assert_equals "slot=1 free" "$(printf '%s\n' "$out" | sed -n 3p)" "slot 1"
    rm -f "$FM_SUITE_MEMINFO"
    assert_contains "$("$SLOT" status)" "avail_mb=unknown" "missing meminfo"
    printf 'MemTotal: 1 kB\n' > "$FM_SUITE_MEMINFO"
    assert_contains "$("$SLOT" status)" "avail_mb=unknown" "meminfo without MemAvailable"
    pass "status prints the documented first line and one line per slot"
}

test_status_json_shape() {
    local json
    new_case json
    printf 'slots=2\n' > "$FM_SUITE_CONFIG"
    json=$("$SLOT" status --json) || fail "status --json failed"
    printf '%s\n' "$json" | jq -e '.capacity == 2 and .base == 2 and .temp == null and .tier == "unknown" and .held == 0 and .free == 2 and .avail_mb == 3072 and (.slots | length) == 2' > /dev/null \
        || fail "status --json has the wrong shape: $json"
    pass "status --json carries capacity, base, temp, tier, held, free, avail_mb and slots"
}

test_status_shows_a_holder_and_ignores_a_stale_info_file() {
    local out json n
    new_case holder
    export FM_SUITE_SLOTS=1
    "$SLOT" run --key holder -- sleep 30 > /dev/null 2>&1 &
    local run_pid=$!
    HOLDERS+=("$run_pid")
    n=0
    until "$SLOT" status | grep -q ' held=1 '; do
        n=$((n + 1))
        [ "$n" -lt 100 ] || fail "the holder never showed up in status"
        sleep 0.1
    done
    out=$("$SLOT" status)
    assert_contains "$out" "slot=0 held" "held slot line"
    assert_contains "$out" "key=holder" "holder key"
    json=$("$SLOT" status --json)
    printf '%s\n' "$json" | jq -e '.slots[0].held == true and .slots[0].key == "holder"' > /dev/null || fail "JSON holder: $json"
    kill -9 "$run_pid" 2> /dev/null
    wait "$run_pid" 2> /dev/null
    n=0
    until "$SLOT" status | grep -q ' held=0 '; do
        n=$((n + 1))
        [ "$n" -lt 100 ] || fail "the killed holder never left status"
        sleep 0.1
    done
    printf 'pid=1\nkey=stale\n' > "$FM_SUITE_STATE_DIR/slot.0.info"
    assert_contains "$("$SLOT" status)" "slot=0 free" "a stale info file must not count as held"
    unset FM_SUITE_SLOTS
    pass "status shows a live holder and ignores a stale info file"
}

test_usage_errors_and_help() {
    new_case usage
    assert_contains "$("$SLOT" --help)" "fm-suite-slot.sh" "--help"
    assert_contains "$("$SLOT" -h)" "fm-suite-slot.sh" "-h"
    "$SLOT" > /dev/null 2>&1
    expect_code 2 "$?" "no subcommand"
    "$SLOT" bogus > /dev/null 2>&1
    expect_code 2 "$?" "unknown subcommand"
    "$SLOT" run true > /dev/null 2>&1
    expect_code 2 "$?" "run without --"
    "$SLOT" run --wait-secs soon -- true > /dev/null 2>&1
    expect_code 2 "$?" "a non-numeric --wait-secs"
    pass "help prints usage and malformed calls exit 2"
}

test_run_writes_json_events() {
    new_case events
    export FM_SUITE_SLOTS=1
    "$SLOT" run --key testkey -- true || fail "run failed"
    jq -s -e 'any(.[]; .event == "acquire" and .key == "testkey") and any(.[]; .event == "release" and .exit == 0 and .key == "testkey") and all(.[]; .host != "")' \
        "$FM_SUITE_STATE_DIR/events.jsonl" > /dev/null || fail "acquire/release events missing: $(cat "$FM_SUITE_STATE_DIR/events.jsonl")"
    FM_SUITE_SLOTS=0 "$SLOT" run -- true 2> /dev/null
    jq -s -e 'any(.[]; .event == "refuse")' "$FM_SUITE_STATE_DIR/events.jsonl" > /dev/null || fail "refuse event missing"
    unset FM_SUITE_SLOTS
    pass "run appends JSON acquire, release and refuse events"
}

test_capacity_env_beats_config_and_bad_values_are_ignored
test_capacity_from_cpu_count
test_heat_lowers_capacity
test_heat_limits_fall_back_to_the_home_thermal_gate
test_status_first_line_and_slot_lines
test_status_json_shape
test_status_shows_a_holder_and_ignores_a_stale_info_file
test_usage_errors_and_help
test_run_writes_json_events
