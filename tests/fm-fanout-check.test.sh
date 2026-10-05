#!/usr/bin/env bash
# Test file for bin/fm-fanout-check.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_yes() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-yes-1"
  local run_id="fr-20261005T010203Z-abc123"
  echo "$run_id" > "$state_dir/${task_id}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed"}\n' "$run_id" > "$ledger_file"
  printf '{"run_id":"%s","label":"step2","outcome":"check_passed"}\n' "$run_id" >> "$ledger_file"
  printf '{"run_id":"%s","label":"step3","outcome":"free_exhausted"}\n' "$run_id" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?

  expect_code 0 $rc "exit code for yes case"
  assert_equals "fanout-check: $task_id free_written=yes verdict=yes units=2 paid_step_ups=1 runs=$run_id" "$out" "stdout for yes case"
  assert_equals "" "$(cat "$errfile")" "stderr should be empty"
  assert_present "$adoption_file" "adoption ledger should exist"
  local adoption_line
  adoption_line=$(cat "$adoption_file")
  local free_written
  free_written=$(echo "$adoption_line" | jq -r '.free_written')
  local verdict
  verdict=$(echo "$adoption_line" | jq -r '.verdict')
  local units
  units=$(echo "$adoption_line" | jq -r '.units')
  local paid_step_ups
  paid_step_ups=$(echo "$adoption_line" | jq -r '.paid_step_ups')
  local runs
  runs=$(echo "$adoption_line" | jq -r '.runs | join(",")')
  assert_equals "true" "$free_written" "adoption free_written"
  assert_equals "yes" "$verdict" "adoption verdict"
  assert_equals "2" "$units" "adoption units"
  assert_equals "1" "$paid_step_ups" "adoption paid_step_ups"
  assert_equals "$run_id" "$runs" "adoption runs"

  pass "fm-fanout-check.sh: yes case"
}

test_no() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-no-1"
  local run_id="fr-20261005T010203Z-abc123"
  local other_run_id="fr-20261005T010203Z-def456"
  echo "$run_id" > "$state_dir/${task_id}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"check_failed"}\n' "$run_id" > "$ledger_file"
  printf '{"run_id":"%s","label":"step2","outcome":"rerouted"}\n' "$run_id" >> "$ledger_file"
  printf '{"run_id":"%s","label":"step3","outcome":"check_passed"}\n' "$other_run_id" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?

  expect_code 0 $rc "exit code for no case"
  assert_equals "fanout-check: $task_id free_written=no verdict=no units=0 paid_step_ups=0 runs=$run_id" "$out" "stdout for no case"
  local stderr_content
  stderr_content=$(cat "$errfile")
  assert_contains "$stderr_content" "WARNING: fanout-check:" "stderr contains WARNING"
  local adoption_line
  adoption_line=$(cat "$adoption_file")
  local free_written
  free_written=$(echo "$adoption_line" | jq -r '.free_written')
  assert_equals "false" "$free_written" "adoption free_written false"

  pass "fm-fanout-check.sh: no case"
}

test_missing_ledger() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/nonexistent.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-missing-1"
  local run_id="fr-20261005T010203Z-abc123"
  echo "$run_id" > "$state_dir/${task_id}.status"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?

  expect_code 0 $rc "exit code for missing-ledger"
  assert_equals "fanout-check: $task_id free_written=no verdict=missing-ledger units=0 paid_step_ups=0 runs=$run_id" "$out" "stdout for missing-ledger"
  local stderr_content
  stderr_content=$(cat "$errfile")
  assert_contains "$stderr_content" "WARNING: fanout-check:" "stderr WARNING for missing-ledger"
  assert_present "$adoption_file" "adoption ledger exists"
  local adoption_line
  adoption_line=$(cat "$adoption_file")
  local verdict
  verdict=$(echo "$adoption_line" | jq -r '.verdict')
  assert_equals "missing-ledger" "$verdict" "adoption verdict missing-ledger"

  pass "fm-fanout-check.sh: missing-ledger case"
}

test_no_runs() {
  # Subcase 1: status file exists but no run id
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-no-runs-1"
  echo "some text without run id" > "$state_dir/${task_id}.status"
  : > "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for no-runs with status file no id"
  assert_equals "fanout-check: $task_id free_written=no verdict=no-runs units=0 paid_step_ups=0 runs=-" "$out" "stdout no-runs status no id"
  local stderr_content
  stderr_content=$(cat "$errfile")
  assert_contains "$stderr_content" "WARNING: fanout-check:" "stderr WARNING no-runs"

  # Subcase 2: no status file at all
  local tmp_root2
  tmp_root2=$(fm_test_tmproot fm-fanout-check)
  local state_dir2="$tmp_root2/state"
  local data_dir2="$tmp_root2/data"
  local ledger_file2="$tmp_root2/units.jsonl"
  mkdir -p "$state_dir2" "$data_dir2"
  local task_id2="task-no-runs-2"
  : > "$ledger_file2"

  out=$(FM_HOME="$tmp_root2" FM_STATE_OVERRIDE="$state_dir2" FM_DATA_OVERRIDE="$data_dir2" FM_FANOUT_LEDGER="$ledger_file2" "$ROOT/bin/fm-fanout-check.sh" "$task_id2" 2>"$errfile")
  rc=$?
  expect_code 0 $rc "exit code for no-runs no status file"
  assert_equals "fanout-check: $task_id2 free_written=no verdict=no-runs units=0 paid_step_ups=0 runs=-" "$out" "stdout no-runs no status file"
  stderr_content=$(cat "$errfile")
  assert_contains "$stderr_content" "WARNING: fanout-check:" "stderr WARNING no-runs no status"

  pass "fm-fanout-check.sh: no-runs case"
}

test_body_file() {
  # Test 1: run id only via --body-file
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-body-1"
  local run_id="fr-20261005T010203Z-abc123"
  local body_file="$tmp_root/body.txt"
  echo "This is a PR description with run id ${run_id} inside." > "$body_file"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed"}\n' "$run_id" > "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" --body-file "$body_file" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for body-file"
  assert_equals "fanout-check: $task_id free_written=yes verdict=yes units=1 paid_step_ups=0 runs=$run_id" "$out" "stdout body-file"
  assert_equals "" "$(cat "$errfile")" "stderr empty body-file"

  # Test 2: run id in both status file and body file, counted once
  local tmp_root2
  tmp_root2=$(fm_test_tmproot fm-fanout-check)
  local state_dir2="$tmp_root2/state"
  local data_dir2="$tmp_root2/data"
  local ledger_file2="$tmp_root2/units.jsonl"
  mkdir -p "$state_dir2" "$data_dir2"
  local task_id2="task-body-2"
  local run_id2="fr-20261005T010203Z-def456"
  echo "$run_id2" > "$state_dir2/${task_id2}.status"
  local body_file2="$tmp_root2/body.txt"
  echo "Run id: $run_id2" > "$body_file2"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed"}\n' "$run_id2" > "$ledger_file2"

  out=$(FM_HOME="$tmp_root2" FM_STATE_OVERRIDE="$state_dir2" FM_DATA_OVERRIDE="$data_dir2" FM_FANOUT_LEDGER="$ledger_file2" "$ROOT/bin/fm-fanout-check.sh" "$task_id2" --body-file "$body_file2" 2>"$errfile")
  rc=$?
  expect_code 0 $rc "exit code for body-file duplicate"
  assert_equals "fanout-check: $task_id2 free_written=yes verdict=yes units=1 paid_step_ups=0 runs=$run_id2" "$out" "stdout body-file duplicate"

  pass "fm-fanout-check.sh: body-file case"
}

test_multiple_ids_on_one_line() {
  # Test 1: multiple run ids on one line in body file, with deduplication
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-multi-1"
  local run_id1="fr-20261005T010203Z-aaa111"
  local run_id2="fr-20261005T010203Z-bbb222"
  local body_file="$tmp_root/body.txt"
  echo "Fan-out runs: $run_id1, $run_id2 and $run_id1 again" > "$body_file"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed"}\n' "$run_id2" > "$ledger_file"
  printf '{"run_id":"%s","label":"step2","outcome":"free_exhausted"}\n' "$run_id1" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" --body-file "$body_file" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for multi-ids body-file"
  assert_equals "fanout-check: $task_id free_written=yes verdict=yes units=1 paid_step_ups=1 runs=$run_id1,$run_id2" "$out" "stdout multi-ids body-file"
  assert_equals "" "$(cat "$errfile")" "stderr empty multi-ids body-file"

  # Test 2: two run ids on one line in status file, each with check_passed
  local tmp_root2
  tmp_root2=$(fm_test_tmproot fm-fanout-check)
  local state_dir2="$tmp_root2/state"
  local data_dir2="$tmp_root2/data"
  local ledger_file2="$tmp_root2/units.jsonl"
  mkdir -p "$state_dir2" "$data_dir2"
  local task_id2="task-multi-2"
  local run_id3="fr-20261005T010203Z-ccc333"
  local run_id4="fr-20261005T010203Z-ddd444"
  echo "$run_id3 $run_id4" > "$state_dir2/${task_id2}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed"}\n' "$run_id3" > "$ledger_file2"
  printf '{"run_id":"%s","label":"step2","outcome":"check_passed"}\n' "$run_id4" >> "$ledger_file2"

  out=$(FM_HOME="$tmp_root2" FM_STATE_OVERRIDE="$state_dir2" FM_DATA_OVERRIDE="$data_dir2" FM_FANOUT_LEDGER="$ledger_file2" "$ROOT/bin/fm-fanout-check.sh" "$task_id2" 2>"$errfile")
  rc=$?
  expect_code 0 $rc "exit code for multi-ids status"
  assert_equals "fanout-check: $task_id2 free_written=yes verdict=yes units=2 paid_step_ups=0 runs=$run_id3,$run_id4" "$out" "stdout multi-ids status"
  assert_equals "" "$(cat "$errfile")" "stderr empty multi-ids status"

  pass "fm-fanout-check.sh: multiple ids on one line case"
}

test_malformed_ledger() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-malformed-1"
  local run_id="fr-20261005T010203Z-abc123"
  echo "$run_id" > "$state_dir/${task_id}.status"
  {
    printf '{"run_id":"%s","label":"step1","outcome":"check_passed"}\n' "$run_id"
    printf 'garbage line\n'
    printf '\n'
    printf '["array","not","object"]\n'
    printf '{"run_id":"%s","label":"step2","outcome":"check_passed"}\n' "$run_id"
  } > "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for malformed ledger"
  assert_equals "fanout-check: $task_id free_written=yes verdict=yes units=2 paid_step_ups=0 runs=$run_id" "$out" "stdout malformed ledger"
  assert_equals "" "$(cat "$errfile")" "stderr empty malformed ledger"

  pass "fm-fanout-check.sh: malformed ledger case"
}

test_adoption_accumulates() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id1="task-accum-1"
  local task_id2="task-accum-2"
  local run_id1="fr-20261005T010203Z-abc123"
  local run_id2="fr-20261005T010203Z-def456"
  echo "$run_id1" > "$state_dir/${task_id1}.status"
  echo "$run_id2" > "$state_dir/${task_id2}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed"}\n' "$run_id1" > "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id1" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "first invocation exit"
  assert_present "$adoption_file" "adoption file exists after first"

  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id2" 2>"$errfile")
  rc=$?
  expect_code 0 $rc "second invocation exit"

  local line_count
  line_count=$(wc -l < "$adoption_file")
  assert_equals 2 "$line_count" "adoption file has two lines"
  local valid=true
  while IFS= read -r line; do
    if ! echo "$line" | jq -e . > /dev/null 2>&1; then
      valid=false
      break
    fi
  done < "$adoption_file"
  if ! $valid; then
    fail "adoption file contains invalid JSON line"
  fi
  local task1
  task1=$(sed -n '1p' "$adoption_file" | jq -r '.task')
  local task2
  task2=$(sed -n '2p' "$adoption_file" | jq -r '.task')
  assert_equals "$task_id1" "$task1" "first adoption task"
  assert_equals "$task_id2" "$task2" "second adoption task"

  pass "fm-fanout-check.sh: adoption accumulates case"
}

test_bad_usage() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  mkdir -p "$state_dir" "$data_dir"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" 2>"$errfile")
  local rc=$?
  expect_code 2 $rc "exit code for no args"

  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" --foo 2>"$errfile")
  rc=$?
  expect_code 2 $rc "exit code for unknown option"

  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" --help 2>"$errfile")
  rc=$?
  expect_code 0 $rc "exit code for --help"
  assert_contains "$out" "fm-fanout-check" "help output contains script name"

  pass "fm-fanout-check.sh: bad usage case"
}

test_ledger_unchanged() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-unchanged-1"
  local run_id="fr-20261005T010203Z-abc123"
  echo "$run_id" > "$state_dir/${task_id}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed"}\n' "$run_id" > "$ledger_file"

  local cksum_before
  cksum_before=$(cksum "$ledger_file" | awk '{print $1}')

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for ledger unchanged"

  local cksum_after
  cksum_after=$(cksum "$ledger_file" | awk '{print $1}')
  assert_equals "$cksum_before" "$cksum_after" "ledger checksum unchanged"

  pass "fm-fanout-check.sh: ledger unchanged case"
}

test_yes
test_no
test_missing_ledger
test_no_runs
test_body_file
test_multiple_ids_on_one_line
test_malformed_ledger
test_adoption_accumulates
test_bad_usage
test_ledger_unchanged
