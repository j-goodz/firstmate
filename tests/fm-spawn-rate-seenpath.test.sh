#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-spawn-rate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-rate-helpers.sh"

sr_init fm-spawn-rate-seenpath

# Case 2: seen-marker path helper
sr_reset

# shellcheck disable=SC2016
output=$(sr_run '
    . "$1/bin/fm-wake-lib.sh"
    : > "$FM_FORK_LOG"
    printf "%s\n" "$(fm_wake_signal_seen_path "$FM_STATE_OVERRIDE" "$FM_STATE_OVERRIDE/foo.bar.status")"
    printf "%s\n" "$(fm_wake_signal_seen_path "$FM_STATE_OVERRIDE" "$FM_STATE_OVERRIDE/x.turn-ended")"
' "$SR_ROOT")

mapfile -t lines <<< "$output"
line1="${lines[0]}"
line2="${lines[1]}"

expected1="$FM_STATE_OVERRIDE/.seen-foo_bar_status"
expected2="$FM_STATE_OVERRIDE/.seen-x_turn-ended"

if [[ "$line1" != "$expected1" ]]; then
    fail "line 1 mismatch: expected '$expected1', got '$line1'"
else
    pass "line 1 ok"
fi

if [[ "$line2" != "$expected2" ]]; then
    fail "line 2 mismatch: expected '$expected2', got '$line2'"
else
    pass "line 2 ok"
fi

sr_assert_budget "seen-marker path helper" "$(sr_count)" 0

printf '# fm-spawn-rate-seenpath: done\n'
