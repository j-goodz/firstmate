#!/usr/bin/env bash
# Behavior tests for fm-sleep-pretool-check.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-sleep-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-sleep-pretool-tests)
LOG="$TMP_ROOT/denials.jsonl"
OUT="$TMP_ROOT/out.json"
ERR="$TMP_ROOT/err.json"

run_cmd() {
    local cmd="$1"
    shift
    local payload
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    printf '%s' "$payload" | env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --claude "$@" >"$OUT" 2>"$ERR"
    return $?
}

run_raw() {
    local payload="$1"
    shift
    printf '%s' "$payload" | env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --claude "$@" >"$OUT" 2>"$ERR"
    return $?
}

expect_allow() {
    local label="$1"
    local cmd="$2"
    local rc=0
    run_cmd "$cmd" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$label: expected exit 0, got $rc"
    fi
    if [ -s "$OUT" ]; then
        fail "$label: expected empty stdout, got $(cat "$OUT")"
    fi
    if [ -s "$ERR" ]; then
        fail "$label: expected empty stderr, got $(cat "$ERR")"
    fi
}

expect_deny() {
    local label="$1"
    local cmd="$2"
    local code="$3"
    local rc=0
    run_cmd "$cmd" || rc=$?
    if [ "$rc" -ne 2 ]; then
        fail "$label: expected exit 2, got $rc"
    fi
    if [ -s "$OUT" ]; then
        fail "$label: expected empty stdout (--claude), got $(cat "$OUT")"
    fi
    if [ ! -s "$ERR" ]; then
        fail "$label: expected stderr with denial JSON"
    fi
    jq -e '(.hookSpecificOutput.hookEventName == "PreToolUse")' "$ERR" >/dev/null || fail "$label: hookEventName not PreToolUse"
    jq -e '(.hookSpecificOutput.permissionDecision == "deny")' "$ERR" >/dev/null || fail "$label: permissionDecision not deny"
    jq -e --arg code "$code" '(.systemMessage | startswith("[sleep-poll]")) and (.systemMessage | contains("run_in_background")) and (.systemMessage | contains("end your turn")) and (.systemMessage | contains($code))' "$ERR" >/dev/null || fail "$label: systemMessage missing required parts for code $code"
}

test_sleep_too_long_denials() {
    expect_deny "sleep-580" "sleep 580" "sleep-too-long"
    expect_deny "sleep-5m" "sleep 5m" "sleep-too-long"
    expect_deny "sleep-40-semicolon" "sleep 40; tail x" "sleep-too-long"
    expect_deny "sleep-60-in-chain" "cd /tmp && make && sleep 60 && tail log" "sleep-too-long"
    expect_deny "sleep-1m30s" "sleep 1m 30s" "sleep-too-long"
    expect_deny "sleep-infinity" "sleep infinity" "sleep-too-long"
    expect_deny "sleep-31" "sleep 31" "sleep-too-long"
    expect_deny "sleep-multiline" $'a\nsleep 45' "sleep-too-long"
    expect_deny "sleep-pipe" "foo | sleep 100" "sleep-too-long"
    pass "sleep-too-long denials"
}

# shellcheck disable=SC2016 # the literal $ is the command text under test
test_sleep_allowed() {
    expect_allow "sleep-20" "sleep 20"
    expect_allow "sleep-30" "sleep 30"
    expect_allow "sleep-30s" "sleep 30s"
    expect_allow "sleep-0.5" "sleep 0.5"
    expect_allow "sleep-20-and-tail" "sleep 20 && tail x"
    expect_allow "for-sleep-10" "for i in 1 2 3; do sleep 10; done"
    expect_allow "sleep-dollar-N" 'sleep $N'
    expect_allow "sleep-quoted-DELAY" 'sleep "$DELAY"'
    expect_allow "echo-sleep" "echo sleep 580"
    expect_allow "git-grep-sleep" "git log --grep sleep"
    expect_allow "ls-la" "ls -la"
    expect_allow "tail-f" "tail -f x.log"
    expect_allow "grep-sleep-in-docs" 'grep -rn "sleep 580" docs'
    pass "allowed sleeps"
}

# shellcheck disable=SC2016 # the literal $ is the command text under test
test_sleep_poll_loop_denials() {
    expect_deny "until-sleep" "until test -f /tmp/x; do sleep 2; done" "sleep-poll-loop"
    expect_deny "while-true-sleep" "while true; do sleep 1; done" "sleep-poll-loop"
    expect_deny "while-curl-sleep" "while ! curl -s localhost; do sleep 5; done" "sleep-poll-loop"
    expect_allow "while-read-no-sleep" 'while read l; do echo "$l"; done < f'
    pass "sleep-poll-loop denials and allow"
}

test_non_bash_tools_untouched() {
    local rc=0
    run_raw '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "non-bash Read: expected exit 0, got $rc"
    fi
    if [ -s "$OUT" ] || [ -s "$ERR" ]; then
        fail "non-bash Read: expected no output"
    fi

    rc=0
    run_raw '{"tool_name":"Write","tool_input":{"command":"sleep 580"}}' || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "non-bash Write: expected exit 0, got $rc"
    fi
    if [ -s "$OUT" ] || [ -s "$ERR" ]; then
        fail "non-bash Write: expected no output"
    fi
    pass "non-Bash tools untouched"
}

test_fail_open() {
    local rc=0
    printf '' | env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --claude >"$OUT" 2>"$ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "fail-open empty stdin: expected exit 0, got $rc"
    fi
    if [ -s "$OUT" ] || [ -s "$ERR" ]; then
        fail "fail-open empty stdin: expected no output"
    fi

    rc=0
    printf 'not json' | env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --claude >"$OUT" 2>"$ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "fail-open malformed json: expected exit 0, got $rc"
    fi
    if [ -s "$OUT" ] || [ -s "$ERR" ]; then
        fail "fail-open malformed json: expected no output"
    fi

    rc=0
    printf '{"tool_name":"Bash"}' | env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --claude >"$OUT" 2>"$ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "fail-open no command: expected exit 0, got $rc"
    fi
    if [ -s "$OUT" ] || [ -s "$ERR" ]; then
        fail "fail-open no command: expected no output"
    fi

    rc=0
    printf '{"tool_name":"Bash","tool_input":{"command":""}}' | env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --claude >"$OUT" 2>"$ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "fail-open empty command: expected exit 0, got $rc"
    fi
    if [ -s "$OUT" ] || [ -s "$ERR" ]; then
        fail "fail-open empty command: expected no output"
    fi
    pass "fail-open cases"
}

test_without_claude_flag() {
    local rc=0
    local payload
    payload=$(jq -nc --arg c "sleep 580" '{tool_name:"Bash",tool_input:{command:$c}}')
    printf '%s' "$payload" | env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" >"$OUT" 2>"$ERR" || rc=$?
    if [ "$rc" -ne 2 ]; then
        fail "without-claude: expected exit 2, got $rc"
    fi
    if [ ! -s "$OUT" ]; then
        fail "without-claude: expected stdout with denial JSON"
    fi
    jq -e '(.decision == "deny")' "$OUT" >/dev/null || fail "without-claude: decision not deny"
    jq -e '(.reason | startswith("[sleep-poll]"))' "$OUT" >/dev/null || fail "without-claude: reason missing [sleep-poll]"
    if [ ! -s "$ERR" ]; then
        fail "without-claude: expected stderr with denial JSON"
    fi
    jq -e '(.hookSpecificOutput.hookEventName == "PreToolUse")' "$ERR" >/dev/null || fail "without-claude: hookEventName not PreToolUse"
    jq -e '(.hookSpecificOutput.permissionDecision == "deny")' "$ERR" >/dev/null || fail "without-claude: permissionDecision not deny"
    pass "without --claude flag"
}

test_denial_log() {
    rm -f "$LOG"
    local count
    count=$(env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --count 2>/dev/null)
    if [ "$count" -ne 0 ]; then
        fail "log-count-initial: expected 0, got $count"
    fi

    run_cmd "sleep 580" >/dev/null 2>&1 || true
    run_cmd "sleep 5m" >/dev/null 2>&1 || true
    run_cmd "while true; do sleep 1; done" --task demo-task >/dev/null 2>&1 || true

    count=$(env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --count 2>/dev/null)
    if [ "$count" -ne 3 ]; then
        fail "log-count-after-three: expected 3, got $count"
    fi

    jq -e . "$LOG" >/dev/null || fail "log-lines-valid-json: some line invalid"

    jq -se '(.[2].task == "demo-task")' "$LOG" >/dev/null || fail "log-last-task: expected demo-task"
    jq -se '(.[2].code == "sleep-poll-loop")' "$LOG" >/dev/null || fail "log-last-code: expected sleep-poll-loop"
    jq -se '(.[2].ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' "$LOG" >/dev/null || fail "log-last-ts: invalid timestamp format"

    jq -se '(.[0].code == "sleep-too-long") and (.[0].seconds == 580)' "$LOG" >/dev/null || fail "log-first: expected sleep-too-long with seconds 580"
    jq -se '(.[1].code == "sleep-too-long") and (.[1].seconds == 300)' "$LOG" >/dev/null || fail "log-second: expected sleep-too-long with seconds 300"

    run_cmd "sleep 20" >/dev/null 2>&1 || true
    count=$(env FM_SLEEP_GUARD_LOG="$LOG" "$CHECK" --count 2>/dev/null)
    if [ "$count" -ne 3 ]; then
        fail "log-count-after-allow: expected 3, got $count"
    fi

    local long_cmd="sleep 580; echo "
    long_cmd+=$(printf 'x%.0s' {1..300})
    run_cmd "$long_cmd" >/dev/null 2>&1 || true
    jq -se '(.[3].command | length <= 200)' "$LOG" >/dev/null || fail "log-truncation: command not truncated to 200 chars"
    pass "denial log"
}

test_unwritable_log() {
    local rc=0
    FM_SLEEP_GUARD_LOG=/proc/nonexistent/denials.jsonl run_cmd "sleep 580" || rc=$?
    if [ "$rc" -ne 2 ]; then
        fail "unwritable-log: expected exit 2, got $rc"
    fi
    pass "unwritable log does not change verdict"
}

test_help_and_unknown_arg() {
    local rc=0
    "$CHECK" --help >"$OUT" 2>"$ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "help: expected exit 0, got $rc"
    fi
    if ! grep -q "run_in_background" "$OUT"; then
        fail "help: output missing run_in_background"
    fi

    rc=0
    "$CHECK" --unknown-flag >"$OUT" 2>"$ERR" || rc=$?
    if [ "$rc" -ne 2 ]; then
        fail "unknown-arg: expected exit 2, got $rc"
    fi
    if [ ! -s "$ERR" ]; then
        fail "unknown-arg: expected error on stderr"
    fi
    pass "help and unknown argument"
}

test_script_is_shellcheck_clean() {
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck "$CHECK"
    else
        pass "shellcheck not installed, skipping"
    fi
}

test_sleep_too_long_denials
test_sleep_allowed
test_sleep_poll_loop_denials
test_non_bash_tools_untouched
test_fail_open
test_without_claude_flag
test_denial_log
test_unwritable_log
test_help_and_unknown_arg
test_script_is_shellcheck_clean