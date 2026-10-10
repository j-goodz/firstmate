#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-spawn-rate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-rate-helpers.sh"

sr_init fm-spawn-rate-marker

# Case 3: recovery marker reader
printf 'pending:downtime:abc123\n' > "$FM_STATE_OVERRIDE/.marker-good"
printf 'pending:downtime:abc123\npending:downtime:abc123\n' > "$FM_STATE_OVERRIDE/.marker-two"

sr_run "
  . \"\$1/bin/fm-wake-lib.sh\"
  : > \"\$FM_FORK_LOG\"
  if ! fm_recovery_marker_read \"\$FM_STATE_OVERRIDE/.marker-good\"; then
    echo \"First read should succeed\" >&2
    exit 1
  fi
  if [ \"\$FM_RECOVERY_MARKER_TOKEN\" != \"pending:downtime:abc123\" ]; then
    echo \"Token mismatch: \$FM_RECOVERY_MARKER_TOKEN\" >&2
    exit 1
  fi
  if fm_recovery_marker_read \"\$FM_STATE_OVERRIDE/.marker-two\"; then
    echo \"Second read should fail\" >&2
    exit 1
  fi
" "$SR_ROOT" || exit 1

sr_assert_budget "recovery marker read" "$(sr_count)" 0

printf '# fm-spawn-rate-marker: done\n'
