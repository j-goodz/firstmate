#!/usr/bin/env bash
# tests/fm-test-run-suite-slot.test.sh - bin/fm-test-run.sh --all takes a suite
# slot through bin/fm-suite-slot.sh, and every other selection leaves the gate
# alone. The assertions run a copied runner against a one-script fixture repo.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Unset ambient state so nothing leaks into the tests.
unset FM_SUITE_SLOT_HELD FM_SUITE_SLOTS FM_SUITE_NPROC FM_HOME FM_THERMAL_SYSFS FM_HWMON_SYSFS FM_TASK_ID

# --- helpers ---------------------------------------------------------------

create_default_probe() {
    local probe_dir="$1"
    local probe_file="$probe_dir/probe.test.sh"
    cat > "$probe_file" <<'PROBE_EOF'
#!/usr/bin/env bash
echo "${FM_SUITE_SLOT_HELD:-unset}" >> "$PROBE_LOG"
echo "ok - probe"
exit 0
PROBE_EOF
    chmod +x "$probe_file"
}

create_concurrent_probe() {
    local probe_dir="$1"
    local probe_file="$probe_dir/probe.test.sh"
    cat > "$probe_file" <<'PROBE_EOF'
#!/usr/bin/env bash
echo "start" >> "$PROBE_LOG"
sleep 1
echo "end" >> "$PROBE_LOG"
echo "ok - probe"
exit 0
PROBE_EOF
    chmod +x "$probe_file"
}

# Sets up a fixture repo with the real scripts copied in.
# Arguments: repo_dir [omit_slot=0]
setup_repo() {
    local repo="$1"
    local omit_slot="${2:-0}"
    mkdir -p "$repo/bin" "$repo/tests"
    cp "$ROOT/bin/fm-test-run.sh" "$repo/bin/"
    cp "$ROOT/bin/fm-host-temp.sh" "$repo/bin/"
    cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/"
    if [ "$omit_slot" -eq 0 ]; then
        cp "$ROOT/bin/fm-suite-slot.sh" "$repo/bin/"
    fi
    cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
    chmod +x "$repo/bin/"*.sh "$repo/tests/"*.sh
    # The runner may need a git repo; create one if possible.
    fm_git_init_commit "$repo" >/dev/null 2>&1 || true
}

# --- tests -----------------------------------------------------------------

test_all_with_slot_1() {
    local tmp_root
    tmp_root=$(fm_test_tmproot "slot1")
    local repo="$tmp_root/repo"
    local state_dir="$tmp_root/state"
    local config_file="$tmp_root/config"
    local probe_log="$tmp_root/probe.log"
    touch "$config_file"

    setup_repo "$repo"
    create_default_probe "$repo/tests"

    PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=1 "$repo/bin/fm-test-run.sh" --all
    local exit_code=$?

    expect_code 0 "$exit_code" "exit 0 with slots=1"
    assert_equals "1" "$(head -n1 "$probe_log")" "probe saw FM_SUITE_SLOT_HELD=1"
    assert_grep "acquire" "$state_dir/events.jsonl" "acquire event present"
    assert_grep "firstmate" "$state_dir/events.jsonl" "key firstmate in event"
    pass "test_all_with_slot_1"
}

test_all_with_slot_0() {
    local tmp_root
    tmp_root=$(fm_test_tmproot "slot0")
    local repo="$tmp_root/repo"
    local state_dir="$tmp_root/state"
    local config_file="$tmp_root/config"
    local probe_log="$tmp_root/probe.log"
    touch "$config_file"

    setup_repo "$repo"
    create_default_probe "$repo/tests"

    PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=0 "$repo/bin/fm-test-run.sh" --all
    local exit_code=$?

    expect_code 75 "$exit_code" "exit 75 with slots=0"
    if [ -f "$probe_log" ] && [ -s "$probe_log" ]; then
        fail "probe ran when it should not have"
    else
        pass "probe did not run"
    fi
    pass "test_all_with_slot_0"
}

test_all_with_slot_0_and_CI() {
    local tmp_root
    tmp_root=$(fm_test_tmproot "slot0_ci")
    local repo="$tmp_root/repo"
    local state_dir="$tmp_root/state"
    local config_file="$tmp_root/config"
    local probe_log="$tmp_root/probe.log"
    touch "$config_file"

    setup_repo "$repo"
    create_default_probe "$repo/tests"

    PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=0 CI=true "$repo/bin/fm-test-run.sh" --all
    local exit_code=$?

    expect_code 0 "$exit_code" "exit 0 with CI=true"
    assert_equals "unset" "$(head -n1 "$probe_log")" "probe saw FM_SUITE_SLOT_HELD=unset"
    pass "test_all_with_slot_0_and_CI"
}

test_all_with_slot_held_and_slot_0() {
    local tmp_root
    tmp_root=$(fm_test_tmproot "slot_held")
    local repo="$tmp_root/repo"
    local state_dir="$tmp_root/state"
    local config_file="$tmp_root/config"
    local probe_log="$tmp_root/probe.log"
    touch "$config_file"

    setup_repo "$repo"
    create_default_probe "$repo/tests"

    PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=0 FM_SUITE_SLOT_HELD=1 "$repo/bin/fm-test-run.sh" --all
    local exit_code=$?

    expect_code 0 "$exit_code" "exit 0 with slot held"
    assert_equals "1" "$(head -n1 "$probe_log")" "probe saw FM_SUITE_SLOT_HELD=1"
    pass "test_all_with_slot_held_and_slot_0"
}

test_list_with_all_and_slot_0() {
    local tmp_root
    tmp_root=$(fm_test_tmproot "list_all")
    local repo="$tmp_root/repo"
    local state_dir="$tmp_root/state"
    local config_file="$tmp_root/config"
    local probe_log="$tmp_root/probe.log"
    touch "$config_file"

    setup_repo "$repo"
    create_default_probe "$repo/tests"

    local output
    output=$(PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=0 "$repo/bin/fm-test-run.sh" --list --all 2>&1)
    local exit_code=$?

    expect_code 0 "$exit_code" "exit 0 with --list --all"
    assert_contains "$output" "probe.test.sh" "output contains probe script path"
    assert_absent "$state_dir/events.jsonl" "no events.jsonl for --list"
    pass "test_list_with_all_and_slot_0"
}

test_copy_without_sibling() {
    local tmp_root
    tmp_root=$(fm_test_tmproot "no_sibling")
    local repo="$tmp_root/repo"
    local state_dir="$tmp_root/state"
    local config_file="$tmp_root/config"
    local probe_log="$tmp_root/probe.log"
    touch "$config_file"

    setup_repo "$repo" 1   # omit_slot=1
    create_default_probe "$repo/tests"

    PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=0 "$repo/bin/fm-test-run.sh" --all
    local exit_code=$?

    expect_code 0 "$exit_code" "exit 0 without sibling"
    assert_equals "unset" "$(head -n1 "$probe_log")" "probe saw FM_SUITE_SLOT_HELD=unset"
    pass "test_copy_without_sibling"
}

test_naming_test_script() {
    local tmp_root
    tmp_root=$(fm_test_tmproot "naming")
    local repo="$tmp_root/repo"
    local state_dir="$tmp_root/state"
    local config_file="$tmp_root/config"
    local probe_log="$tmp_root/probe.log"
    touch "$config_file"

    setup_repo "$repo"
    create_default_probe "$repo/tests"

    local exit_code=0
    (cd "$repo" && PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=0 ./bin/fm-test-run.sh tests/probe.test.sh) || exit_code=$?

    expect_code 0 "$exit_code" "exit 0 with explicit test script"
    assert_equals "unset" "$(head -n1 "$probe_log")" "probe saw FM_SUITE_SLOT_HELD=unset"
    pass "test_naming_test_script"
}

test_concurrent_runs() {
    local tmp_root
    tmp_root=$(fm_test_tmproot "concurrent")
    local repo="$tmp_root/repo"
    local state_dir="$tmp_root/state"
    local config_file="$tmp_root/config"
    local probe_log="$tmp_root/concurrent.log"
    touch "$config_file"

    setup_repo "$repo"
    create_concurrent_probe "$repo/tests"

    # Launch two concurrent --all runs; the slot gate must serialise them.
    local pid1 pid2
    PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=1 "$repo/bin/fm-test-run.sh" --all &
    pid1=$!
    PROBE_LOG="$probe_log" FM_SUITE_STATE_DIR="$state_dir" FM_SUITE_CONFIG="$config_file" FM_SUITE_SLOTS=1 "$repo/bin/fm-test-run.sh" --all &
    pid2=$!

    wait "$pid1"
    local exit1=$?
    wait "$pid2"
    local exit2=$?

    expect_code 0 "$exit1" "first concurrent exit 0"
    expect_code 0 "$exit2" "second concurrent exit 0"

    # The log must show non-overlapping runs: start, end, start, end.
    local expected=$'start\nend\nstart\nend'
    local actual
    actual=$(cat "$probe_log")
    assert_equals "$expected" "$actual" "log shows non-overlapping runs"

    pass "test_concurrent_runs"
}

test_host_without_flock_runs_ungated() {
    local tmp_root repo farm f
    tmp_root=$(fm_test_tmproot "noflock")
    repo="$tmp_root/repo"
    farm="$tmp_root/path"
    mkdir -p "$farm"
    for f in /usr/bin/*; do
        [ "${f##*/}" = flock ] || ln -s "$f" "$farm/${f##*/}"
    done
    touch "$tmp_root/config"
    setup_repo "$repo"
    create_default_probe "$repo/tests"

    PATH="$farm" PROBE_LOG="$tmp_root/probe.log" FM_SUITE_STATE_DIR="$tmp_root/state" FM_SUITE_CONFIG="$tmp_root/config" \
        FM_SUITE_SLOTS=0 /usr/bin/bash "$repo/bin/fm-test-run.sh" --all > /dev/null 2>&1
    expect_code 0 "$?" "a host without flock must not be gated"
    assert_equals "unset" "$(head -n1 "$tmp_root/probe.log")" "probe saw FM_SUITE_SLOT_HELD=unset"
    pass "test_host_without_flock_runs_ungated"
}

# --- run all tests ---------------------------------------------------------

test_all_with_slot_1
test_all_with_slot_0
test_all_with_slot_0_and_CI
test_all_with_slot_held_and_slot_0
test_list_with_all_and_slot_0
test_copy_without_sibling
test_naming_test_script
test_concurrent_runs
test_host_without_flock_runs_ungated
