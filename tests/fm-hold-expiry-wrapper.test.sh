#!/usr/bin/env bash
# Test: fm-hold-expiry-wrapper.test.sh
# Tests the hold wrapper behavior for pacing holds with expiry dates.

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

test_undated_pacing_hold_refused() {
  local home
  home=$(make_home "test1")
  
  # Add a row to hold
  (cd "$home" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" add p-1 "Pacing test row")
  
  # Capture backlog checksum before
  local cksum_before
  cksum_before=$(cksum "$home/data/backlog.md")
  
  # Run hold without --until, capture stderr and exit code
  local stderr_file
  stderr_file=$(mktemp)
  local exit_code
  exit_code=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" hold p-1 --reason "pacing test" >/dev/null 2>"$stderr_file" || exit_code=$?
  
  # Check exit code is 2
  assert_equals 2 "$exit_code" "expected exit 2 for undated pacing hold"
  
  # Check stderr contains pacing hold needs --until
  assert_contains "$(cat "$stderr_file")" "pacing hold needs --until" "stderr message"
  
  # Check backlog unchanged
  local cksum_after
  cksum_after=$(cksum "$home/data/backlog.md")
  assert_equals "$cksum_before" "$cksum_after" "backlog unchanged"
  
  rm -f "$stderr_file"
}

test_dated_pacing_hold_accepted() {
  local home
  home=$(make_home "test2")
  
  # Add a row to hold
  (cd "$home" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" add p-1 "Pacing test row")
  
  # Run hold with --until
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" hold p-1 --reason "pacing test" --until 2026-10-12
  local exit_code=$?
  
  # Check exit code is 0
  assert_equals 0 "$exit_code" "dated pacing hold accepted"
  
  # Check backlog contains hold-until
  assert_grep "(hold-until: 2026-10-12)" "$home/data/backlog.md" "backlog has hold-until"
}

test_ordinary_hold_accepted() {
  local home
  home=$(make_home "test3")
  
  # Add a row to hold
  (cd "$home" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" add p-1 "Ordinary test row")
  
  # Run hold without --until, without pacing word
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" hold p-1 --reason "ordinary test"
  local exit_code=$?
  
  # Check exit code is 0
  assert_equals 0 "$exit_code" "ordinary hold accepted"
  
  # Check backlog has no hold-until
  local hold_count
  hold_count=$(grep -c "(hold-until:" "$home/data/backlog.md" || true)
  assert_equals 0 "$hold_count" "no hold-until in backlog"
}

test_uppercase_pacing_treated_as_pacing() {
  local home
  home=$(make_home "test4")
  
  # Add a row to hold
  (cd "$home" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" add p-1 "PACING test row")
  
  # Capture backlog checksum before
  local cksum_before
  cksum_before=$(cksum "$home/data/backlog.md")
  
  # Run hold with upper-case PACING, no --until
  local stderr_file
  stderr_file=$(mktemp)
  local exit_code
  exit_code=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" hold p-1 --reason "PACING test" >/dev/null 2>"$stderr_file" || exit_code=$?
  
  # Check exit code is 2 (refused)
  assert_equals 2 "$exit_code" "expected exit 2 for undated PACING hold"
  
  # Check stderr contains pacing hold needs --until
  assert_contains "$(cat "$stderr_file")" "pacing hold needs --until" "stderr message"
  
  # Check backlog unchanged
  local cksum_after
  cksum_after=$(cksum "$home/data/backlog.md")
  assert_equals "$cksum_before" "$cksum_after" "backlog unchanged"
  
  rm -f "$stderr_file"
}

test_undated_pacing_hold_refused
test_dated_pacing_hold_accepted
test_ordinary_hold_accepted
test_uppercase_pacing_treated_as_pacing
