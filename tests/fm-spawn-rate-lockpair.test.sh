#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-spawn-rate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-rate-helpers.sh"

sr_init fm-spawn-rate-lockpair

# Case 1: lock acquire/release pair
sr_reset
# shellcheck disable=SC2016
if ! sr_run '
    . "$1/bin/fm-wake-lib.sh" || exit 1
    : > "$FM_FORK_LOG" || exit 1
    for _ in 1 2 3 4 5; do
        fm_lock_try_acquire "$FM_STATE_OVERRIDE/.rate.lock" || exit 1
        [ -L "$FM_STATE_OVERRIDE/.rate.lock" ] || exit 1
        fm_lock_release "$FM_STATE_OVERRIDE/.rate.lock" || exit 1
    done
' "$SR_ROOT"; then
    echo "FAIL: sr_run did not succeed" >&2
    exit 1
fi
for leftover in "$FM_STATE_OVERRIDE"/.rate.lock "$FM_STATE_OVERRIDE"/.rate.lock.owner.*; do if [ -e "$leftover" ] || [ -L "$leftover" ]; then echo "FAIL: lock files remain in $FM_STATE_OVERRIDE" >&2; exit 1; fi; done
sr_assert_budget "5 lock acquire/release pairs" "$(sr_count)" 45

printf '# fm-spawn-rate-lockpair: done\n'
