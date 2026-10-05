#!/usr/bin/env bash
# tests/fm-suite-daily.test.sh - `run`, `status` and `install` of
# bin/fm-suite-daily.sh (`dispatch` has tests/fm-suite-daily-dispatch.test.sh).
#
# Every case builds a throwaway git clone with a tiny suite script, points the
# script at it through its config file, and pins load, memory, heat and slot
# inputs to fixtures so nothing depends on the machine running the test. The
# failure extractors are also fed output from real producers (pytest and
# bin/fm-test-run.sh) kept under tests/fixtures/suite-capacity/.
# The suite bodies are single-quoted on purpose: they expand inside the suite.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_SUITE_SLOT_HELD FM_SUITE_SLOTS FM_SUITE_NPROC FM_HOME FM_THERMAL_SYSFS FM_TASK_ID FM_SUITE_MIN_AVAILABLE_MB

DAILY="$ROOT/bin/fm-suite-daily.sh"
SLOT="$ROOT/bin/fm-suite-slot.sh"
ASSETS="$ROOT/tests/fixtures/suite-capacity"
TMP_ROOT=$(fm_test_tmproot fm-suite-daily)
HOLDERS=()
kill_holders() {
    local p
    for p in "${HOLDERS[@]+"${HOLDERS[@]}"}"; do
        kill -9 "$p" 2> /dev/null
    done
}
trap kill_holders EXIT

# new_case <name> <format> <suite body>: a clone with suite.sh, a config line,
# and every machine input pinned. Sets CASE, SRC, SHA and exports the env.
new_case() {
    CASE="$TMP_ROOT/$1"
    SRC="$CASE/src"
    mkdir -p "$CASE/sysfs"
    fm_git_init_commit "$SRC"
    printf '%s\n' "$3" > "$SRC/suite.sh"
    git -C "$SRC" add suite.sh
    git -C "$SRC" -c user.name=t -c user.email=t@example.invalid commit -qm suite
    SHA=$(git -C "$SRC" rev-parse main)
    printf 'proj|%s|%s|bash suite.sh\n' "$SRC" "$2" > "$CASE/config"
    printf '0.10 0.10 0.10 1/100 1\n' > "$CASE/loadavg"
    printf 'MemAvailable:    4194304 kB\n' > "$CASE/meminfo"
    export FM_SUITE_DAILY_CONFIG="$CASE/config" FM_SUITE_STATE_DIR="$CASE/state" FM_SUITE_DAILY_LOG="$CASE/log.jsonl"
    export FM_SUITE_CONFIG="$CASE/no-machine-file" FM_SUITE_DAILY_FETCH=0 FM_SUITE_DAILY_REF=main
    export FM_SUITE_SLOTS=1 FM_SUITE_NPROC=4 FM_SUITE_DAILY_LOADAVG="$CASE/loadavg"
    export FM_SUITE_MEMINFO="$CASE/meminfo" FM_THERMAL_SYSFS="$CASE/sysfs"
    unset FM_SUITE_DAILY_TIMEOUT_SECS FM_SUITE_DAILY_SLOT_WAIT_SECS FM_SUITE_MIN_AVAILABLE_MB
}

# daily_run <key>: RC and RESULT (the JSON after the last "RESULT " line); stdout and
# stderr are kept in $CASE/out and $CASE/err.
daily_run() {
    "$DAILY" run "$1" > "$CASE/out" 2> "$CASE/err"
    RC=$?
    RESULT=$(grep '^RESULT ' "$CASE/out" | tail -n1)
    RESULT=${RESULT#RESULT }
}

assert_json() {  # <json> <jq expression> <message>
    printf '%s\n' "$1" | jq -e "$2" > /dev/null || fail "$3: $1"
}

test_a_passing_suite_is_logged_and_the_checkout_removed() {
    new_case pass fm-test 'echo "FM_TEST_END 2026-10-05T00:00:00Z tests/a.test.sh exit=0 duration_ms=1 gate_skip=false"'
    daily_run proj
    expect_code 0 "$RC" "a passing suite"
    assert_json "$RESULT" ".status == \"pass\" and .key == \"proj\" and .failures == 0 and .sha == \"$SHA\"" "RESULT line"
    assert_equals 1 "$(wc -l < "$FM_SUITE_DAILY_LOG" | tr -d ' ')" "one log line"
    assert_json "$(cat "$FM_SUITE_DAILY_LOG")" '.event == "daily-run" and .status == "pass" and (.host | length) > 0' "log line"
    local -a leftover=("$FM_SUITE_STATE_DIR"/daily/proj/wt.*)
    assert_equals "$FM_SUITE_STATE_DIR/daily/proj/wt.*" "${leftover[0]}" "the checkout must be removed"
    assert_equals 1 "$(git -C "$SRC" worktree list | wc -l | tr -d ' ')" "no worktree left in the clone"
    pass "a passing suite is logged and its checkout removed"
}

test_a_failing_suite_names_its_failing_ids() {
    new_case fail fm-test 'echo "FM_TEST_END 2026-10-05T00:00:00Z tests/a.test.sh exit=0 duration_ms=1 gate_skip=false"
echo "FM_TEST_END 2026-10-05T00:00:00Z tests/b.test.sh exit=1 duration_ms=1 gate_skip=false"
exit 1'
    daily_run proj
    expect_code 0 "$RC" "a failing suite still counts as a run"
    assert_json "$RESULT" '.status == "fail" and .reason == "suite-failed" and .rc == 1 and .failures == 1 and .failed_ids == ["tests/b.test.sh"]' "RESULT line"
    pass "a failing suite is recorded with its failing ids"
}

test_extractors_read_real_producer_output() {
    new_case realpytest pytest "cat '$ASSETS/pytest-real.out'; exit 1"
    daily_run proj
    assert_json "$RESULT" '.status == "fail" and .failed_ids == ["tests/test_alpha.py::TestKlass::test_method","tests/test_alpha.py::test_bad","tests/test_alpha.py::test_dash_param[a - b]","tests/test_alpha.py::test_param[1-2]","tests/test_broken_import.py"]' "real pytest output"
    new_case realfm fm-test "cat '$ASSETS/fm-test-run-real.out'; exit 1"
    daily_run proj
    assert_json "$RESULT" '.status == "fail" and .failed_ids == ["tests/b.test.sh"]' "real fm-test-run output"
    new_case nonefmt none 'echo "FM_TEST_END 2026-10-05T00:00:00Z tests/b.test.sh exit=1 duration_ms=1 gate_skip=false"; exit 1'
    daily_run proj
    assert_json "$RESULT" '.status == "fail" and .failures == 0' "format none names no ids"
    pass "failure ids come out of real pytest and fm-test-run output, and format none names none"
}

test_unconfigured_key_exits_10_and_logs_nothing() {
    new_case unconfigured fm-test 'true'
    "$DAILY" run nosuchkey > /dev/null 2>&1
    expect_code 10 "$?" "unknown key"
    FM_SUITE_DAILY_CONFIG="$CASE/missing-config" "$DAILY" run proj > /dev/null 2>&1
    expect_code 10 "$?" "missing config file"
    assert_absent "$FM_SUITE_DAILY_LOG" "nothing may be logged"
    pass "an unconfigured key exits 10 and logs nothing"
}

test_guards_skip_a_busy_hot_or_short_machine() {
    new_case guards fm-test 'echo ran > "$FM_DAILY_SRC/../ran-marker"'
    printf '4.00 4.00 4.00 1/100 1\n' > "$CASE/loadavg"
    daily_run proj
    expect_code 11 "$RC" "load per CPU 1.0"
    assert_json "$RESULT" '.status == "skipped" and .reason == "load-busy"' "busy machine"
    printf '0.10 0.10 0.10 1/100 1\n' > "$CASE/loadavg"
    printf 'slots=1\nhot_c=60\nhold_c=70\n' > "$CASE/machine"
    mkdir -p "$CASE/sysfs/thermal_zone0"
    printf 'x86_pkg_temp\n' > "$CASE/sysfs/thermal_zone0/type"
    printf '75000\n' > "$CASE/sysfs/thermal_zone0/temp"
    export FM_SUITE_CONFIG="$CASE/machine"
    daily_run proj
    expect_code 11 "$RC" "heat hold"
    assert_json "$RESULT" '.status == "skipped" and .reason == "heat-hold"' "held machine"
    printf '65000\n' > "$CASE/sysfs/thermal_zone0/temp"
    daily_run proj
    assert_json "$RESULT" '.status == "skipped" and .reason == "heat-hot"' "hot machine"
    printf '30000\n' > "$CASE/sysfs/thermal_zone0/temp"
    printf 'MemAvailable:    102400 kB\n' > "$CASE/meminfo"
    daily_run proj
    assert_json "$RESULT" '.status == "skipped" and .reason == "memory-pressure"' "short of memory"
    assert_absent "$CASE/ran-marker" "a skipped run must not start the suite"
    pass "load, heat and memory guards skip the run with exit 11"
}

test_a_machine_without_suite_slots_runs_only_when_nearly_idle() {
    new_case noslots fm-test 'echo "FM_TEST_END 2026-10-05T00:00:00Z tests/a.test.sh exit=0 duration_ms=1 gate_skip=false"'
    export FM_SUITE_SLOTS=0
    printf '0.20 0.20 0.20 1/100 1\n' > "$CASE/loadavg"
    daily_run proj
    expect_code 0 "$RC" "nearly idle, no slots"
    assert_json "$RESULT" '.status == "pass"' "ran directly"
    printf '1.20 1.20 1.20 1/100 1\n' > "$CASE/loadavg"
    daily_run proj
    expect_code 11 "$RC" "load per CPU 0.3 against a halved limit"
    assert_json "$RESULT" '.status == "skipped" and .reason == "load-busy"' "halved limit"
    pass "a machine with no suite slots runs only when nearly idle"
}

test_the_suite_is_time_bounded() {
    new_case timeout fm-test 'sleep 30'
    export FM_SUITE_DAILY_TIMEOUT_SECS=1
    daily_run proj
    assert_json "$RESULT" '.status == "fail" and .reason == "timeout" and .rc == 124' "timeout"
    pass "a suite that outruns the timeout is a failure with reason timeout"
}

test_a_busy_slot_skips_the_run() {
    local n=0
    new_case slotbusy fm-test 'echo ran > "$FM_DAILY_SRC/../ran-marker"'
    "$SLOT" run --key holder -- sleep 20 > /dev/null 2>&1 &
    HOLDERS+=("$!")
    until "$SLOT" status | grep -q ' held=1 '; do
        n=$((n + 1))
        [ "$n" -lt 100 ] || fail "the holder never took the slot"
        sleep 0.1
    done
    export FM_SUITE_DAILY_SLOT_WAIT_SECS=1
    daily_run proj
    expect_code 11 "$RC" "slot taken"
    assert_json "$RESULT" '.status == "skipped" and .reason == "no-slot"' "no slot"
    assert_absent "$CASE/ran-marker" "the suite must not start"
    pass "a run that cannot get a slot in time is skipped with reason no-slot"
}

test_the_suite_runs_in_a_detached_checkout() {
    new_case where fm-test 'pwd > "$FM_DAILY_SRC/../where"; echo "$FM_DAILY_SRC" > "$FM_DAILY_SRC/../src-seen"'
    daily_run proj
    case "$(cat "$CASE/where")" in
        */daily/proj/wt.*) ;;
        *) fail "the suite ran in $(cat "$CASE/where"), expected a daily/proj/wt.* checkout" ;;
    esac
    assert_not_equals "$SRC" "$(cat "$CASE/where")" "the suite must not run in the clone itself"
    assert_equals "$SRC" "$(cat "$CASE/src-seen")" "FM_DAILY_SRC must name the clone"
    pass "the suite runs in a detached checkout, with FM_DAILY_SRC naming the clone"
}

test_two_overlapping_runs_of_one_key_do_not_collide() {
    local p1 p2 rc1 rc2 d1 d2
    new_case overlap fm-test 'd=$(pwd); printf "%s\n" "$d" > "$FM_DAILY_SRC/../checkout-$$"; : > "$d/marker"; sleep 1; [ "$(pwd)" = "$d" ] && [ -f "$d/marker" ] || { echo marker-lost >&2; exit 1; }; echo "FM_TEST_END 2026-10-05T00:00:00Z tests/a.test.sh exit=0 duration_ms=1 gate_skip=false"'
    export FM_SUITE_SLOTS=0
    "$DAILY" run proj > "$CASE/out1" 2> "$CASE/err1" &
    p1=$!
    "$DAILY" run proj > "$CASE/out2" 2> "$CASE/err2" &
    p2=$!
    wait "$p1"
    rc1=$?
    wait "$p2"
    rc2=$?
    expect_code 0 "$rc1" "the first overlapping run"
    expect_code 0 "$rc2" "the second overlapping run"
    assert_json "$(grep '^RESULT ' "$CASE/out1" | tail -n1 | sed 's/^RESULT //')" '.status == "pass"' "the first result"
    assert_json "$(grep '^RESULT ' "$CASE/out2" | tail -n1 | sed 's/^RESULT //')" '.status == "pass"' "the second result"
    d1=$(cat "$CASE"/checkout-* | LC_ALL=C sort | sed -n 1p)
    d2=$(cat "$CASE"/checkout-* | LC_ALL=C sort | sed -n 2p)
    assert_not_equals "$d1" "$d2" "each run must see its own checkout"
    case "$d1" in */daily/proj/wt.*) ;; *) fail "the first checkout ran in $d1, expected a daily/proj/wt.* checkout" ;; esac
    assert_equals 1 "$(git -C "$SRC" worktree list | wc -l | tr -d ' ')" "no worktree left in the clone"
    pass "two overlapping runs of one key both pass with their own checkouts"
}

test_overlapping_runs_of_one_key_keep_their_own_status() {
    local p1 p2 rc1 rc2 r1 r2
    new_case overlapstatus fm-test 'if [ "${FM_TEST_EXPECT:-pass}" = fail ]; then echo "FM_TEST_END 2026-10-05T00:00:00Z tests/b.test.sh exit=1 duration_ms=1 gate_skip=false"; exit 1; fi; sleep 1; echo "FM_TEST_END 2026-10-05T00:00:00Z tests/a.test.sh exit=0 duration_ms=1 gate_skip=false"'
    export FM_SUITE_SLOTS=0
    FM_TEST_EXPECT=fail "$DAILY" run proj > "$CASE/out1" 2> "$CASE/err1" &
    p1=$!
    FM_TEST_EXPECT=pass "$DAILY" run proj > "$CASE/out2" 2> "$CASE/err2" &
    p2=$!
    wait "$p1"
    rc1=$?
    wait "$p2"
    rc2=$?
    expect_code 0 "$rc1" "the failing overlapping run still exits 0"
    expect_code 0 "$rc2" "the passing overlapping run still exits 0"
    r1=$(grep '^RESULT ' "$CASE/out1" | tail -n1 | sed 's/^RESULT //')
    r2=$(grep '^RESULT ' "$CASE/out2" | tail -n1 | sed 's/^RESULT //')
    assert_json "$r1" '.status == "fail" and .reason == "suite-failed" and .rc == 1 and .failed_ids == ["tests/b.test.sh"]' "the failing run keeps its own status"
    assert_json "$r2" '.status == "pass" and .rc == 0 and .failures == 0' "the passing run keeps its own status"
    pass "overlapping runs of one key each keep their own status"
}

test_run_refuses_an_invalid_repo_key() {
    new_case badkey fm-test 'true'
    "$DAILY" run 'a;touch x' > /dev/null 2>&1
    expect_code 2 "$?" "a semicolon in a run key"
    "$DAILY" run 'a b' > /dev/null 2>&1
    expect_code 2 "$?" "a space in a run key"
    "$DAILY" run '-a' > /dev/null 2>&1
    expect_code 2 "$?" "a leading dash in a run key"
    assert_absent "$FM_SUITE_DAILY_LOG" "nothing may be logged for an invalid key"
    pass "run refuses a key that is not a plain repo name"
}

test_a_config_line_with_an_invalid_key_is_ignored() {
    new_case badconfig fm-test 'echo "FM_TEST_END 2026-10-05T00:00:00Z tests/a.test.sh exit=0 duration_ms=1 gate_skip=false"'
    printf 'a;touch x|%s|fm-test|bash suite.sh\nproj|%s|fm-test|bash suite.sh\n' "$SRC" "$SRC" > "$CASE/config"
    daily_run proj
    expect_code 0 "$RC" "the valid line still runs"
    assert_json "$RESULT" '.status == "pass"' "the valid repo passed"
    assert_equals 1 "$(wc -l < "$FM_SUITE_DAILY_LOG" | tr -d ' ')" "only the valid key is logged"
    pass "a config line whose key is not a plain repo name is ignored"
}

test_status_reads_the_last_line_per_key() {
    local out
    new_case status fm-test 'true'
    "$DAILY" status > "$CASE/none" 2>&1
    expect_code 0 "$?" "status without a log"
    assert_equals "" "$(cat "$CASE/none")" "status without a log prints nothing"
    printf 'proj|%s|fm-test|bash suite.sh\nother|%s|fm-test|bash suite.sh\n' "$SRC" "$SRC" > "$CASE/config"
    daily_run proj
    daily_run other
    out=$("$DAILY" status)
    assert_equals 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line per key"
    assert_contains "$out" "key=proj status=pass sha=${SHA:0:7}" "proj line"
    assert_contains "$out" "key=other status=pass" "other line"
    "$DAILY" status --json | jq -e 'type == "array" and length == 2 and all(.[]; has("key") and has("status"))' > /dev/null || fail "status --json shape"
    pass "status prints the last result per key as text and JSON"
}

test_install_writes_idempotent_units() {
    local out units="$TMP_ROOT/units" calls="$TMP_ROOT/systemctl-calls"
    out=$("$DAILY" install --print)
    assert_contains "$out" "# fm-suite-daily.service" "service marker"
    assert_contains "$out" "# fm-suite-daily.timer" "timer marker"
    assert_contains "$out" "OnCalendar=*-*-* 03:30:00 America/Toronto" "default time"
    assert_contains "$out" "Persistent=false" "no catch-up run"
    assert_contains "$out" "Type=oneshot" "oneshot service"
    assert_contains "$out" "fm-suite-daily.sh dispatch" "dispatch command"
    assert_contains "$("$DAILY" install --print --time 04:15)" "OnCalendar=*-*-* 04:15:00 America/Toronto" "custom time"
    "$DAILY" install --time 4pm > /dev/null 2>&1
    expect_code 2 "$?" "a malformed --time"
    assert_absent "$units" "--print must write nothing"

    FM_SUITE_UNIT_DIR="$units" FM_SUITE_INSTALL_NO_ENABLE=1 "$DAILY" install > /dev/null || fail "install without enabling"
    cat "$units/fm-suite-daily.service" "$units/fm-suite-daily.timer" > "$TMP_ROOT/first"
    FM_SUITE_UNIT_DIR="$units" FM_SUITE_INSTALL_NO_ENABLE=1 "$DAILY" install > /dev/null || fail "second install"
    cat "$units/fm-suite-daily.service" "$units/fm-suite-daily.timer" > "$TMP_ROOT/second"
    assert_equals "$(cat "$TMP_ROOT/first")" "$(cat "$TMP_ROOT/second")" "installing twice must leave the same units"

    printf '#!/bin/sh\necho "$@" >> "%s"\n' "$calls" > "$TMP_ROOT/fake-systemctl"
    chmod +x "$TMP_ROOT/fake-systemctl"
    FM_SUITE_UNIT_DIR="$units" FM_SUITE_SYSTEMCTL="$TMP_ROOT/fake-systemctl" "$DAILY" install > /dev/null || fail "install with systemctl"
    assert_contains "$(cat "$calls")" "--user daemon-reload" "daemon-reload call"
    assert_contains "$(cat "$calls")" "--user enable --now fm-suite-daily.timer" "enable call"
    pass "install writes the service and timer, idempotently, and enables the timer"
}

test_help_and_missing_subcommand() {
    new_case help fm-test 'true'
    assert_contains "$("$DAILY" --help)" "fm-suite-daily.sh" "--help"
    assert_contains "$("$DAILY" -h)" "fm-suite-daily.sh" "-h"
    "$DAILY" > /dev/null 2>&1
    expect_code 2 "$?" "no subcommand"
    "$DAILY" run > /dev/null 2>&1
    expect_code 2 "$?" "run without a key"
    pass "help prints usage and malformed calls exit 2"
}

test_a_passing_suite_is_logged_and_the_checkout_removed
test_a_failing_suite_names_its_failing_ids
test_extractors_read_real_producer_output
test_unconfigured_key_exits_10_and_logs_nothing
test_guards_skip_a_busy_hot_or_short_machine
test_a_machine_without_suite_slots_runs_only_when_nearly_idle
test_the_suite_is_time_bounded
test_a_busy_slot_skips_the_run
test_the_suite_runs_in_a_detached_checkout
test_two_overlapping_runs_of_one_key_do_not_collide
test_overlapping_runs_of_one_key_keep_their_own_status
test_run_refuses_an_invalid_repo_key
test_a_config_line_with_an_invalid_key_is_ignored
test_status_reads_the_last_line_per_key
test_install_writes_idempotent_units
test_help_and_missing_subcommand
