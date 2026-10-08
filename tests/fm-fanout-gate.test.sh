#!/usr/bin/env bash
# Tests for fm-fanout-gate
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

run_gate() {
  local tmp
  tmp=$1
  local id
  id=$2
  local rc
  FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_DATA_OVERRIDE="$tmp/data" FM_FANOUT_LEDGER="$tmp/units.jsonl" "$ROOT/bin/fm-fanout-check.sh" "$id" --gate >"$tmp/out" 2>"$tmp/err"
  rc=$?
  return $rc
}

test_gate_clean_lane_passes() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"dots-studio/dots-3-note-preview:free"},{"model":"openai/gpt-oss-120b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free"}
{"run_id":"fr-20261005T010203Z-abc123","label":"u2","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "clean lane passes"
  assert_no_grep "REFUSED" "$tmp/err" "no REFUSED in err"
  if [ -f "$tmp/data/fanout-adoption.jsonl" ]; then
    fail "fanout-adoption.jsonl should not exist"
  else
    pass "fanout-adoption.jsonl absent"
  fi
}

test_gate_refuses_no_run_ids() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"dots-studio/dots-3-note-preview:free"},{"model":"openai/gpt-oss-120b"}]}
EOF
  # no state file
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 1 $rc "refuses no run ids"
  assert_grep "REFUSED: fanout-gate" "$tmp/err" "REFUSED prefix"
  assert_grep "no fan-out run ids" "$tmp/err" "no run ids message"
}

test_gate_refuses_free_exhausted_last() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"dots-studio/dots-3-note-preview:free"},{"model":"openai/gpt-oss-120b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_failed","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free"}
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"free_exhausted","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 1 $rc "refuses free_exhausted last"
  assert_grep "fr-20261005T010203Z-abc123/u1" "$tmp/err" "run id and unit"
  assert_grep "free_exhausted" "$tmp/err" "free_exhausted message"
}

test_gate_free_exhausted_then_free_pass_is_clean() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"dots-studio/dots-3-note-preview:free"},{"model":"openai/gpt-oss-120b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"free_exhausted","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free"}
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "free_exhausted then pass is clean"
}

test_gate_split_units_resolve_exhausted_parent() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  FM_FANOUT_MODELS="$tmp/models.json"
  export FM_FANOUT_MODELS
  echo '{"models":[{"model":"dots-studio/dots-3-note-preview:free"}]}' > "$FM_FANOUT_MODELS"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$tmp/state/t1.status"
  local m="dots-studio/dots-3-note-preview:free"
  cat > "$tmp/units.jsonl" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"free_exhausted","requested_model":"$m","served_model":"$m"}
{"run_id":"fr-20261005T010203Z-abc123","label":"u1--a","outcome":"check_passed","requested_model":"$m","served_model":"$m"}
{"run_id":"fr-20261005T010203Z-abc123","label":"u1--b","outcome":"check_passed","requested_model":"$m","served_model":"$m"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "split units resolve exhausted parent"
}

test_gate_split_unit_exhausted_still_refused() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  FM_FANOUT_MODELS="$tmp/models.json"
  export FM_FANOUT_MODELS
  echo '{"models":[{"model":"dots-studio/dots-3-note-preview:free"}]}' > "$FM_FANOUT_MODELS"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$tmp/state/t1.status"
  local m="dots-studio/dots-3-note-preview:free"
  cat > "$tmp/units.jsonl" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"free_exhausted","requested_model":"$m","served_model":"$m"}
{"run_id":"fr-20261005T010203Z-abc123","label":"u1--a","outcome":"free_exhausted","requested_model":"$m","served_model":"$m"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 1 $rc "exhausted split unit refused"
  assert_grep "u1--a" "$tmp/err" "split unit named"
}

test_gate_refuses_paid_served() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"dots-studio/dots-3-note-preview:free"},{"model":"openai/gpt-oss-120b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"openai/gpt-oss-120b","served_model":"anthropic/claude-sonnet"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 1 $rc "refuses paid served"
  assert_grep "u1" "$tmp/err" "unit name"
  assert_grep "anthropic/claude-sonnet" "$tmp/err" "served model"
}

test_gate_refuses_missing_ledger() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"dots-studio/dots-3-note-preview:free"},{"model":"openai/gpt-oss-120b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  # no ledger file
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 1 $rc "refuses missing ledger"
  assert_grep "units ledger" "$tmp/err" "ledger missing message"
}

# Run tests
test_gate_clean_lane_passes
test_gate_refuses_no_run_ids
test_gate_refuses_free_exhausted_last
test_gate_free_exhausted_then_free_pass_is_clean
test_gate_split_units_resolve_exhausted_parent
test_gate_split_unit_exhausted_still_refused
test_gate_refuses_paid_served
test_gate_refuses_missing_ledger