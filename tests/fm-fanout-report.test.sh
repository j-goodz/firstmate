#!/usr/bin/env bash
# Test REPORT mode of bin/fm-fanout-check.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

expected_line() {
    printf "fanout-check: t1 free_written=%s verdict=%s units=%s paid_step_ups=%s runs=fr-20261009T070041Z-dda3ea,fr-20261009T070527Z-00d889,fr-20261009T071321Z-ce56e6,fr-20261009T071129Z-42c945,fr-20261009T140531Z-cff58f,fr-20261009T145221Z-b4b3bf,fr-20261009T155906Z-db0ead,fr-20261009T161229Z-8df752,fr-20261009T161646Z-09d88e,fr-20261009T161839Z-93d7bc" "$1" "$2" "$3" "$4"
}

setup_lane() {
    mkdir -p "$1/state" "$1/data"
    echo "working [at=1]: fan-out runs fr-20261009T070041Z-dda3ea fr-20261009T070527Z-00d889 fr-20261009T071321Z-ce56e6 fr-20261009T071129Z-42c945 fr-20261009T140531Z-cff58f fr-20261009T145221Z-b4b3bf fr-20261009T155906Z-db0ead fr-20261009T161229Z-8df752 fr-20261009T161646Z-09d88e fr-20261009T161839Z-93d7bc" > "$1/state/t1.status"
    cat > "$1/models.json" <<EOF
{"models":[{"model":"codestral-latest"},{"model":"codestral-2508"},{"model":"openai/gpt-oss-120b"},{"model":"openai/gpt-oss-20b"}]}
EOF
    export FM_FANOUT_MODELS="$1/models.json"
}

run_report() {
    FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_FANOUT_LEDGER="$1/units.jsonl" "$ROOT/bin/fm-fanout-check.sh" t1 >"$1/rout" 2>"$1/rerr"
    return $?
}

run_gate() {
    FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_FANOUT_LEDGER="$1/units.jsonl" "$ROOT/bin/fm-fanout-check.sh" --gate t1 >"$1/gout" 2>"$1/gerr"
    return $?
}

test_report_pr803_lane_is_yes() {
    tmp=$(fm_test_tmproot)
    setup_lane "$tmp"
    cp "$ROOT/tests/fixtures/fanout/pr803-units.jsonl" "$tmp/units.jsonl"
    run_report "$tmp"
    assert_equals 0 $? "report exits 0"
    assert_equals "$(expected_line yes yes 22 0)" "$(cat "$tmp/rout")" "stdout matches expected"
    assert_equals "" "$(cat "$tmp/rerr")" "stderr is empty"
    assert_equals "true" "$(jq -r '.free_written' "$tmp/data/fanout-adoption.jsonl")" "free_written is true"
    assert_equals "yes" "$(jq -r '.verdict' "$tmp/data/fanout-adoption.jsonl")" "verdict is yes"
    assert_equals "22" "$(jq -r '.units' "$tmp/data/fanout-adoption.jsonl")" "units is 22"
    assert_equals "0" "$(jq -r '.paid_step_ups' "$tmp/data/fanout-adoption.jsonl")" "paid_step_ups is 0"
    pass "test_report_pr803_lane_is_yes"
}

test_report_agrees_with_gate_on_pr803() {
    tmp=$(fm_test_tmproot)
    setup_lane "$tmp"
    cp "$ROOT/tests/fixtures/fanout/pr803-units.jsonl" "$tmp/units.jsonl"
    run_gate "$tmp"
    gate_rc=$?
    run_report "$tmp"
    assert_equals 0 $gate_rc "gate exits 0"
    assert_equals 0 $? "report exits 0"
    assert_equals "$(expected_line yes yes 22 0)" "$(cat "$tmp/rout")" "stdout matches expected"
    pass "test_report_agrees_with_gate_on_pr803"
}

test_report_counts_only_uncleared_exhausted() {
    tmp=$(fm_test_tmproot)
    setup_lane "$tmp"
    grep -v '"label":"f-dedup--a"' "$ROOT/tests/fixtures/fanout/pr803-units.jsonl" > "$tmp/units.jsonl"
    run_report "$tmp"
    assert_equals 0 $? "report exits 0"
    assert_equals "$(expected_line no mixed 21 1)" "$(cat "$tmp/rout")" "stdout matches expected"
    assert_grep "WARNING: fanout-check:" "$tmp/rerr" "stderr contains warning"
    run_gate "$tmp"
    assert_equals 1 $? "gate exits 1"
    pass "test_report_counts_only_uncleared_exhausted"
}

test_report_paid_written_unit_is_mixed() {
    tmp=$(fm_test_tmproot)
    setup_lane "$tmp"
    cp "$ROOT/tests/fixtures/fanout/pr803-units.jsonl" "$tmp/units.jsonl"
    echo '{"run_id":"fr-20261009T161839Z-93d7bc","label":"z-paid","outcome":"check_passed","requested_model":"deepseek-chat","served_model":"deepseek-chat","at":"2026-10-09T16:19:00Z"}' >> "$tmp/units.jsonl"
    run_report "$tmp"
    assert_equals "$(expected_line no mixed 22 0)" "$(cat "$tmp/rout")" "stdout matches expected"
    assert_grep "WARNING: fanout-check:" "$tmp/rerr" "stderr contains warning"
    run_gate "$tmp"
    assert_equals 1 $? "gate exits 1"
    pass "test_report_paid_written_unit_is_mixed"
}

test_report_requested_free_served_paid_is_not_free() {
    tmp=$(fm_test_tmproot)
    setup_lane "$tmp"
    echo '{"run_id":"fr-20261009T161839Z-93d7bc","label":"only","outcome":"check_passed","requested_model":"openai/gpt-oss-120b","served_model":"deepseek-chat","at":"2026-10-09T16:19:00Z"}' > "$tmp/units.jsonl"
    run_report "$tmp"
    assert_equals "$(expected_line no no 0 0)" "$(cat "$tmp/rout")" "stdout matches expected"
    pass "test_report_requested_free_served_paid_is_not_free"
}

test_report_provider_swapped_same_model_is_free() {
    tmp=$(fm_test_tmproot)
    setup_lane "$tmp"
    echo '{"run_id":"fr-20261009T161839Z-93d7bc","label":"only","outcome":"check_passed","requested_model":"openai/gpt-oss-20b","served_model":"ovh/gpt-oss-20b","at":"2026-10-09T16:19:00Z"}' > "$tmp/units.jsonl"
    run_report "$tmp"
    assert_equals "$(expected_line yes yes 1 0)" "$(cat "$tmp/rout")" "stdout matches expected"
    pass "test_report_provider_swapped_same_model_is_free"
}

test_report_pr803_lane_is_yes
test_report_agrees_with_gate_on_pr803
test_report_counts_only_uncleared_exhausted
test_report_paid_written_unit_is_mixed
test_report_requested_free_served_paid_is_not_free
test_report_provider_swapped_same_model_is_free