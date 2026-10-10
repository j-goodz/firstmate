#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-spawn-rate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-rate-helpers.sh"

sr_init fm-spawn-rate-meta

printf 'kind=ship\nwindow=a:b=c\nwindow=x:y\n' > "$FM_STATE_OVERRIDE/m.meta"

sr_reset
# shellcheck disable=SC2016
actual="$(sr_run '
  . "$1/bin/fm-classify-lib.sh"
  : > "$FM_FORK_LOG"
  _fm_meta_value "$FM_STATE_OVERRIDE/m.meta" window v1
  _fm_meta_value "$FM_STATE_OVERRIDE/m.meta" nokey v2
  _fm_meta_value /nonexistent kind v3
  printf "%s\n%s\n%s\n" "$v1" "$v2" "$v3"
' "$SR_ROOT")"

expected="$(printf 'x:y\n\n\n')"
if [ "$actual" = "$expected" ]; then
  echo "metadata reader: OK"
else
  echo "metadata reader: FAIL"
  echo "expected:"
  printf '%s' "$expected"
  echo "---"
  echo "got:"
  printf '%s' "$actual"
  echo "---"
  exit 1
fi

sr_assert_budget "metadata reader" "$(sr_count)" 0

printf '# fm-spawn-rate-meta: done\n'
