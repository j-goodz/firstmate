#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-spawn-rate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-rate-helpers.sh"

sr_init fm-spawn-rate-hooks

payload='{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"/tmp","hook_event_name":"PreToolUse"}'

# fm-subagent-pretool-check.sh --claude
sr_reset
printf '%s' "$payload" | env PATH="$SR_SHIM_BIN:$PATH" bash "$SR_ROOT/bin/fm-subagent-pretool-check.sh" --claude >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
status=$?
if (( status != 0 )); then
    fail "fm-subagent-pretool-check.sh exited with status $status"
fi
if [[ -s "$TMP_ROOT/out" ]]; then
    fail "fm-subagent-pretool-check.sh produced unexpected output"
fi
if [[ -s "$TMP_ROOT/err" ]]; then
    fail "fm-subagent-pretool-check.sh produced unexpected error output"
fi
sr_assert_budget "fm-subagent-pretool-check per tool call" "$(sr_count)" 1

# fm-sleep-pretool-check.sh --claude --task t1
sr_reset
printf '%s' "$payload" | env PATH="$SR_SHIM_BIN:$PATH" bash "$SR_ROOT/bin/fm-sleep-pretool-check.sh" --claude --task t1 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
status=$?
if (( status != 0 )); then
    fail "fm-sleep-pretool-check.sh exited with status $status"
fi
if [[ -s "$TMP_ROOT/out" ]]; then
    fail "fm-sleep-pretool-check.sh produced unexpected output"
fi
if [[ -s "$TMP_ROOT/err" ]]; then
    fail "fm-sleep-pretool-check.sh produced unexpected error output"
fi
sr_assert_budget "fm-sleep-pretool-check per tool call" "$(sr_count)" 1

# fm-arm-pretool-check.sh --claude
sr_reset
printf '%s' "$payload" | env PATH="$SR_SHIM_BIN:$PATH" bash "$SR_ROOT/bin/fm-arm-pretool-check.sh" --claude >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
status=$?
if (( status != 0 )); then
    fail "fm-arm-pretool-check.sh exited with status $status"
fi
if [[ -s "$TMP_ROOT/out" ]]; then
    fail "fm-arm-pretool-check.sh produced unexpected output"
fi
if [[ -s "$TMP_ROOT/err" ]]; then
    fail "fm-arm-pretool-check.sh produced unexpected error output"
fi
sr_assert_budget "fm-arm-pretool-check per tool call" "$(sr_count)" 1

# fm-cd-pretool-check.sh --claude
sr_reset
printf '%s' "$payload" | env PATH="$SR_SHIM_BIN:$PATH" bash "$SR_ROOT/bin/fm-cd-pretool-check.sh" --claude >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
status=$?
if (( status != 0 )); then
    fail "fm-cd-pretool-check.sh exited with status $status"
fi
if [[ -s "$TMP_ROOT/out" ]]; then
    fail "fm-cd-pretool-check.sh produced unexpected output"
fi
if [[ -s "$TMP_ROOT/err" ]]; then
    fail "fm-cd-pretool-check.sh produced unexpected error output"
fi
sr_assert_budget "fm-cd-pretool-check per tool call" "$(sr_count)" 1

printf '# fm-spawn-rate-hooks: done\n'