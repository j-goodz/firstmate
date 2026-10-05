#!/usr/bin/env bash
# Test file for bin/fm-fanout-check.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Ranked free-model fixture: the check reads this to tell free-written units from paid
# ones, so these tests never touch the operator's real ~/.nexus/free-coding-models.json.
FM_FANOUT_MODELS_FIXTURE_ROOT=$(fm_test_tmproot fm-fanout-check-models)
cat > "$FM_FANOUT_MODELS_FIXTURE_ROOT/free-coding-models.json" <<'JSON'
{"models":[
  {"model":"dots-studio/dots-3-note-preview:free"},
  {"model":"openai/gpt-oss-120b"},
  {"model":"kilo/cohere/north-mini-code:free"},
  {"model":"codestral-2508"}
]}
JSON
export FM_FANOUT_MODELS="$FM_FANOUT_MODELS_FIXTURE_ROOT/free-coding-models.json"

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
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free"}\n' "$run_id" > "$ledger_file"
  printf '{"run_id":"%s","label":"step2","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$run_id" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?

  expect_code 0 $rc "exit code for yes case"
  assert_equals "fanout-check: $task_id free_written=yes verdict=yes units=2 paid_step_ups=0 runs=$run_id" "$out" "stdout for yes case"
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
  assert_equals "0" "$paid_step_ups" "adoption paid_step_ups"
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

test_multiple_ids_on_one_line() {
  # Test 1: multiple run ids on one line in the status file, with deduplication
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
  echo "Fan-out runs: $run_id1, $run_id2 and $run_id1 again" > "$state_dir/${task_id}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$run_id2" > "$ledger_file"
  printf '{"run_id":"%s","label":"step2","outcome":"free_exhausted"}\n' "$run_id1" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for multi-ids status file"
  assert_equals "fanout-check: $task_id free_written=no verdict=mixed units=1 paid_step_ups=1 runs=$run_id1,$run_id2" "$out" "stdout multi-ids status file"
  assert_contains "$(cat "$errfile")" "WARNING: fanout-check:" "stderr WARNING multi-ids status file"

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
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$run_id3" > "$ledger_file2"
  printf '{"run_id":"%s","label":"step2","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free"}\n' "$run_id4" >> "$ledger_file2"

  out=$(FM_HOME="$tmp_root2" FM_STATE_OVERRIDE="$state_dir2" FM_DATA_OVERRIDE="$data_dir2" FM_FANOUT_LEDGER="$ledger_file2" "$ROOT/bin/fm-fanout-check.sh" "$task_id2" 2>"$errfile")
  rc=$?
  expect_code 0 $rc "exit code for multi-ids status"
  assert_equals "fanout-check: $task_id2 free_written=yes verdict=yes units=2 paid_step_ups=0 runs=$run_id3,$run_id4" "$out" "stdout multi-ids status"
  assert_equals "" "$(cat "$errfile")" "stderr empty multi-ids status"

  pass "fm-fanout-check.sh: multiple ids on one line case"
}

test_paid_step_up() {
  # A unit free could not write (free_exhausted under the free run) that a paid model
  # later passed (check_passed under the paid run) is a paid step-up, never free-written.
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-step-up-1"
  local free_run="fr-20261005T010203Z-aaa111"
  local paid_run="fr-20261005T010204Z-bbb222"
  echo "$free_run $paid_run" > "$state_dir/${task_id}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"free_exhausted"}\n' "$free_run" > "$ledger_file"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"paid-model-xyz"}\n' "$paid_run" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for paid step-up"
  assert_equals "fanout-check: $task_id free_written=no verdict=no units=0 paid_step_ups=1 runs=$free_run,$paid_run" "$out" "stdout paid step-up"
  local stderr_content
  stderr_content=$(cat "$errfile")
  assert_contains "$stderr_content" "WARNING: fanout-check:" "stderr WARNING paid step-up"
  local adoption_line
  adoption_line=$(cat "$adoption_file")
  assert_equals "false" "$(echo "$adoption_line" | jq -r '.free_written')" "adoption free_written false for paid step-up"
  assert_equals "no" "$(echo "$adoption_line" | jq -r '.verdict')" "adoption verdict no for paid step-up"
  assert_equals "0" "$(echo "$adoption_line" | jq -r '.units')" "adoption units zero for paid step-up"
  assert_equals "1" "$(echo "$adoption_line" | jq -r '.paid_step_ups')" "adoption paid_step_ups one for paid step-up"

  pass "fm-fanout-check.sh: paid step-up case"
}

test_paid_only_run() {
  # review-3 forward: a run handed wholesale to a paid model (no prior free run) must not
  # be recorded as free adoption, even though every unit emits check_passed.
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-paid-only-1"
  local paid_run="fr-20261005T010203Z-aaa111"
  echo "$paid_run" > "$state_dir/${task_id}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"paid-model-xyz"}\n' "$paid_run" > "$ledger_file"
  printf '{"run_id":"%s","label":"step2","outcome":"check_passed","requested_model":"paid-model-xyz"}\n' "$paid_run" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for paid-only run"
  assert_equals "fanout-check: $task_id free_written=no verdict=no units=0 paid_step_ups=0 runs=$paid_run" "$out" "stdout paid-only run"
  local stderr_content
  stderr_content=$(cat "$errfile")
  assert_contains "$stderr_content" "WARNING: fanout-check:" "stderr WARNING paid-only run"
  local adoption_line
  adoption_line=$(cat "$adoption_file")
  assert_equals "false" "$(echo "$adoption_line" | jq -r '.free_written')" "adoption free_written false for paid-only run"
  assert_equals "0" "$(echo "$adoption_line" | jq -r '.units')" "adoption units zero for paid-only run"

  pass "fm-fanout-check.sh: paid-only run is not free adoption"
}

test_label_reuse_across_runs() {
  # review-3 reverse: a genuine free check_passed for a label that some other collected
  # run reports free_exhausted must still count as free-written.
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-label-reuse-1"
  local free_run_a="fr-20261005T010203Z-aaa111"
  local free_run_b="fr-20261005T010204Z-bbb222"
  echo "$free_run_a $free_run_b" > "$state_dir/${task_id}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"free_exhausted"}\n' "$free_run_a" > "$ledger_file"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$free_run_b" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for label reuse"
  assert_equals "fanout-check: $task_id free_written=no verdict=mixed units=1 paid_step_ups=1 runs=$free_run_a,$free_run_b" "$out" "stdout label reuse"
  assert_contains "$(cat "$errfile")" "WARNING: fanout-check:" "stderr WARNING label reuse"

  pass "fm-fanout-check.sh: free pass survives a free_exhausted on another run's label"
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
    printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$run_id"
    printf 'garbage line\n'
    printf '\n'
    printf '["array","not","object"]\n'
    printf '{"run_id":"%s","label":"step2","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free"}\n' "$run_id"
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
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" 2>"$errfile")
  local rc=$?
  expect_code 2 $rc "exit code for no args"

  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" --foo 2>"$errfile")
  rc=$?
  expect_code 2 $rc "exit code for unknown option"

  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" -h 2>"$errfile")
  rc=$?
  expect_code 2 $rc "exit code for unknown short option"
  assert_absent "$adoption_file" "a rejected option appends no adoption row"

  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" --help 2>"$errfile")
  rc=$?
  expect_code 0 $rc "exit code for --help"
  assert_contains "$out" "fm-fanout-check" "help output contains script name"

  pass "fm-fanout-check.sh: bad usage case"
}

test_unwritable_data_dir() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local ledger_file="$tmp_root/units.jsonl"
  local blocker="$tmp_root/not-a-directory"
  local data_dir="$blocker/sub"
  local task_id="task-unwritable-1"
  mkdir -p "$state_dir"
  : > "$blocker"
  : > "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code when the data dir cannot be created"
  assert_equals "fanout-check: $task_id free_written=no verdict=no-runs units=0 paid_step_ups=0 runs=-" "$out" "stdout when the data dir cannot be created"
  local stderr_content
  stderr_content=$(cat "$errfile")
  assert_contains "$stderr_content" "WARNING: fanout-check:" "stderr reports the adoption-ledger failure"

  pass "fm-fanout-check.sh: unwritable data dir case"
}

test_pr_url() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local fakebin
  fakebin=$(fm_fakebin "$tmp_root")
  local task_id="task-pr-url-1"
  local run_id="fr-20261005T010203Z-abc123"
  mkdir -p "$state_dir" "$data_dir"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$run_id" > "$ledger_file"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'Fan-out runs: fr-20261005T010203Z-abc123\n'
SH
  chmod +x "$fakebin/gh"

  local out errfile="$tmp_root/stderr.txt"
  out=$(PATH="$fakebin:$PATH" FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" --pr-url "https://forge.example/pr/1" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for --pr-url via the shared bounded runner"
  assert_equals "fanout-check: $task_id free_written=yes verdict=yes units=1 paid_step_ups=0 runs=$run_id" "$out" "stdout for --pr-url via the shared bounded runner"
  assert_equals "" "$(cat "$errfile")" "stderr empty for --pr-url"

  pass "fm-fanout-check.sh: --pr-url case"
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

test_mixed() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local adoption_file="$data_dir/fanout-adoption.jsonl"
  mkdir -p "$state_dir" "$data_dir"
  local task_id="task-mixed-1"
  local run_id="fr-20261005T010203Z-abc123"
  echo "$run_id" > "$state_dir/${task_id}.status"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$run_id" > "$ledger_file"
  printf '{"run_id":"%s","label":"step2","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$run_id" >> "$ledger_file"
  printf '{"run_id":"%s","label":"step3","outcome":"free_exhausted"}\n' "$run_id" >> "$ledger_file"

  local out errfile="$tmp_root/stderr.txt"
  out=$(FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" 2>"$errfile")
  local rc=$?

  expect_code 0 $rc "exit code for mixed case"
  assert_equals "fanout-check: $task_id free_written=no verdict=mixed units=2 paid_step_ups=1 runs=$run_id" "$out" "stdout for mixed case"
  local stderr_content
  stderr_content=$(cat "$errfile")
  assert_contains "$stderr_content" "WARNING: fanout-check:" "stderr contains WARNING for mixed"
  assert_present "$adoption_file" "adoption ledger should exist for mixed"
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
  assert_equals "false" "$free_written" "adoption free_written for mixed"
  assert_equals "mixed" "$verdict" "adoption verdict for mixed"
  assert_equals "2" "$units" "adoption units for mixed"
  assert_equals "1" "$paid_step_ups" "adoption paid_step_ups for mixed"
  assert_equals "$run_id" "$runs" "adoption runs for mixed"

  pass "fm-fanout-check.sh: mixed case"
}

test_pr_body_runs_line_only() {
  local tmp_root
  tmp_root=$(fm_test_tmproot fm-fanout-check)
  local state_dir="$tmp_root/state"
  local data_dir="$tmp_root/data"
  local ledger_file="$tmp_root/units.jsonl"
  local fakebin
  fakebin=$(fm_fakebin "$tmp_root")
  local task_id="task-pr-body-1"
  local run_id="fr-20261005T010203Z-abc123"
  mkdir -p "$state_dir" "$data_dir"
  printf '{"run_id":"%s","label":"step1","outcome":"check_passed","requested_model":"openai/gpt-oss-120b"}\n' "$run_id" > "$ledger_file"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'Fan-out runs: fr-20261005T010203Z-abc123\nSome pasted output fr-20261005T010203Z-def456\nMore text fr-20261005T010203Z-fff000\n'
SH
  chmod +x "$fakebin/gh"

  local out errfile="$tmp_root/stderr.txt"
  out=$(PATH="$fakebin:$PATH" FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_HOME="$tmp_root" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" FM_FANOUT_LEDGER="$ledger_file" "$ROOT/bin/fm-fanout-check.sh" "$task_id" --pr-url "https://forge.example/pr/1" 2>"$errfile")
  local rc=$?
  expect_code 0 $rc "exit code for pr-body runs-line-only"
  assert_equals "fanout-check: $task_id free_written=yes verdict=yes units=1 paid_step_ups=0 runs=$run_id" "$out" "stdout for pr-body runs-line-only"
  assert_equals "" "$(cat "$errfile")" "stderr empty for pr-body runs-line-only"

  pass "fm-fanout-check.sh: pr-body runs line only case"
}

test_yes
test_no
test_missing_ledger
test_no_runs
test_multiple_ids_on_one_line
test_paid_step_up
test_paid_only_run
test_label_reuse_across_runs
test_malformed_ledger
test_adoption_accumulates
test_bad_usage
test_unwritable_data_dir
test_pr_url
test_ledger_unchanged
test_mixed
test_pr_body_runs_line_only
