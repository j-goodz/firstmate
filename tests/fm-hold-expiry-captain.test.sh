#!/usr/bin/env bash
# Test: fm-captain-hold.sh pacing hold expiry behavior

set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

TMP_ROOT=$(fm_test_tmproot fm-hold-expiry)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

test_captain_refuses_undated_pacing_hold() {
  local home cksum_before stderr_file run_status cksum_after

  home=$(make_home test1)

  cksum_before=$(cksum "$home/data/backlog.md")

  stderr_file=$(mktemp)

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold p-2 --title "Pacing call" --reason "Pacing on until reset" 2>"$stderr_file"
  run_status=$?

  if [ "$run_status" -eq 0 ]; then
    fail "expected non-zero exit for undated pacing hold"
  fi

  assert_grep "pacing hold needs --until" "$stderr_file" "stderr mentions pacing hold needs --until"

  cksum_after=$(cksum "$home/data/backlog.md")
  assert_equals "$cksum_before" "$cksum_after" "backlog unchanged byte for byte"

  rm -f "$stderr_file"

  pass "captain-hold refuses undated pacing hold"
}

test_captain_accepts_dated_pacing_hold() {
  local home run_status

  home=$(make_home test2)

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold p-2 --title "Pacing call" --reason "Pacing on until reset" --until 2026-10-12
  run_status=$?

  assert_equals 0 "$run_status" "exit zero for dated pacing hold"
  assert_grep "hold-until: 2026-10-12" "$home/data/backlog.md" "backlog row contains hold-until"

  pass "captain-hold accepts dated pacing hold"
}

test_captain_refuses_undated_pacing_hold
test_captain_accepts_dated_pacing_hold
