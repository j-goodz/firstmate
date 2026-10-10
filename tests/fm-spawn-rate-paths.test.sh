#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-spawn-rate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-rate-helpers.sh"

sr_init fm-spawn-rate-paths

# Case 3: marker path helpers
sr_reset
# shellcheck disable=SC2016
out=$(sr_run '
  . "$1/bin/fm-classify-lib.sh"
  : > "$FM_FORK_LOG"
  status_heartbeat_seen_marker_path /s "a:b/c.d"; printf "\n"
  status_daemon_seen_marker_path /s "a:b/c.d"; printf "\n"
  _fm_open_decisions_cursor_path /s/t.one.status; printf "\n"
' "$SR_ROOT") || fail "marker path helpers body failed"
count=$(sr_count)
expected=$'/s/.hb-surfaced-a_b_c_d\n/s/.subsuper-seen-status-a_b_c_d\n/s/.t.one.open-decisions-cursor'
[ "$out" = "$expected" ] || fail "marker path helpers printed: $out"
sr_assert_budget "marker path helpers" "$count" 0

printf '# fm-spawn-rate-paths: done\n'
