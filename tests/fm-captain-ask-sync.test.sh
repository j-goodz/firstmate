#!/bin/bash
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v tasks-axi >/dev/null 2>&1; then
    echo "skip: tasks-axi not found"
    exit 0
fi

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

TMP=$(fm_test_tmproot "fm-captain-ask-sync")
WRAPPER="$ROOT/bin/fm-tasks-axi.sh"

make_case() {
    local name="$1"
    local dir="$TMP/$name"
    mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
    cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
    cat > "$dir/home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
    ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
}

make_bridge() {
    local dir="$1"
    cat > "$dir/bridge.py" <<'EOF'
import os, sys, time
log_path = os.environ.get('BRIDGE_LOG')
if log_path:
    with open(log_path, 'a') as f:
        f.write(' '.join(sys.argv[1:]) + '\n')
sleep_sec = os.environ.get('BRIDGE_SLEEP')
if sleep_sec:
    time.sleep(float(sleep_sec))
exit_code = os.environ.get('BRIDGE_EXIT')
if exit_code:
    sys.exit(int(exit_code))
sys.exit(0)
EOF
    chmod +x "$dir/bridge.py"
}

test1() {
    local case_dir="$TMP/test1"
    make_case test1
    make_bridge "$case_dir"
    export FM_CAPTAIN_ASK_BRIDGE="$case_dir/bridge.py"
    export BRIDGE_LOG="$case_dir/bridge.log"

    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" add "test-id" "Test item" >/dev/null 2>&1)
    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" start "test-id" >/dev/null 2>&1)
    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" "done" "test-id" >/dev/null 2>&1)

    assert_grep "sync --backlog-id test-id" "$BRIDGE_LOG" "Bridge was called with correct arguments"
    pass "wrapper done calls bridge with sync --backlog-id"
    unset FM_CAPTAIN_ASK_BRIDGE BRIDGE_LOG
}

test2() {
    local case_dir="$TMP/test2"
    make_case test2
    make_bridge "$case_dir"
    export FM_CAPTAIN_ASK_BRIDGE="$case_dir/bridge.py"
    export BRIDGE_LOG="$case_dir/bridge.log"

    (
        # shellcheck disable=SC1091
        source "$ROOT/bin/fm-tasks-axi-lib.sh"
        # shellcheck disable=SC1091
        source "$ROOT/bin/fm-backlog-transition-lib.sh"
        tasks-axi add "test-id" "Test item" --file "$case_dir/home/data/backlog.md" >/dev/null 2>&1
        tasks-axi start "test-id" --file "$case_dir/home/data/backlog.md" >/dev/null 2>&1
        FM_HOME="$case_dir/home" fm_backlog_done "$case_dir/home/data" "test-id"
    )

    assert_grep "sync --backlog-id test-id" "$BRIDGE_LOG" "Bridge was called via fm_backlog_done"
    pass "fm_backlog_done calls bridge with sync --backlog-id"
    unset FM_CAPTAIN_ASK_BRIDGE BRIDGE_LOG
}

test3() {
    local case_dir="$TMP/test3"
    make_case test3
    export FM_CAPTAIN_ASK_BRIDGE="$case_dir/nonexistent.py"

    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" add "test-id" "Test item" >/dev/null 2>&1)
    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" start "test-id" >/dev/null 2>&1)

    local output
    output=$(cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" "done" "test-id" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        fail "done command failed with exit code $exit_code"
    fi

    if echo "$output" | grep -qE "warning|captain-ask"; then
        fail "Output contained 'warning' or 'captain-ask'"
    else
        pass "missing bridge path: done succeeds silently"
    fi
    unset FM_CAPTAIN_ASK_BRIDGE
}

test4() {
    local case_dir="$TMP/test4"
    make_case test4
    make_bridge "$case_dir"
    export FM_CAPTAIN_ASK_BRIDGE="$case_dir/bridge.py"
    export BRIDGE_LOG="$case_dir/bridge.log"
    export BRIDGE_EXIT=3

    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" add "test-id" "Test item" >/dev/null 2>&1)
    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" start "test-id" >/dev/null 2>&1)

    local output
    output=$(cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" "done" "test-id" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        fail "done command failed with exit code $exit_code"
    fi

    assert_grep "sync --backlog-id test-id" "$BRIDGE_LOG" "Bridge was called"
    if echo "$output" | grep -q "captain-ask sync"; then
        pass "BRIDGE_EXIT=3: done succeeds and output contains captain-ask sync"
    else
        fail "Output did not contain 'captain-ask sync'"
    fi

    unset FM_CAPTAIN_ASK_BRIDGE BRIDGE_LOG BRIDGE_EXIT
}

test5() {
    local case_dir="$TMP/test5"
    make_case test5
    make_bridge "$case_dir"
    export FM_CAPTAIN_ASK_BRIDGE="$case_dir/bridge.py"
    export BRIDGE_LOG="$case_dir/bridge.log"
    export BRIDGE_SLEEP=30
    export FM_CAPTAIN_ASK_SYNC_TIMEOUT=1

    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" add "test-id" "Test item" >/dev/null 2>&1)
    (cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" start "test-id" >/dev/null 2>&1)

    local start_time end_time elapsed output exit_code
    start_time=$(date +%s)
    output=$(cd "$case_dir/code" && FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code" "$WRAPPER" "done" "test-id" 2>&1)
    exit_code=$?
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    if [ $exit_code -ne 0 ]; then
        fail "done command failed with exit code $exit_code"
    fi

    if [ $elapsed -gt 5 ]; then
        fail "done did not return promptly (took ${elapsed}s)"
    fi

    assert_grep "sync --backlog-id test-id" "$BRIDGE_LOG" "Bridge was called"
    pass "BRIDGE_SLEEP=30 with timeout=1: done succeeds and returns promptly"

    unset FM_CAPTAIN_ASK_BRIDGE BRIDGE_LOG BRIDGE_SLEEP FM_CAPTAIN_ASK_SYNC_TIMEOUT
}

test1
test2
test3
test4
test5

exit 0
