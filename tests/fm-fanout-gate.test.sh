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

run_report() {
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_FANOUT_LEDGER="$1/units.jsonl" "$ROOT/bin/fm-fanout-check.sh" "$2" >"$1/rout" 2>"$1/rerr"
}

test_gate_router_prefixed_free_name_passes() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"zai/glm-5"},{"model":"nvidia/nemotron-3-ultra-550b-a55b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"huddle-mod","outcome":"check_passed","requested_model":"nvidia/nemotron-3-ultra-550b-a55b:free","served_model":"kilo/nvidia/nemotron-3-ultra-550b-a55b:free"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "router-prefixed free name passes"
  assert_no_grep "REFUSED" "$tmp/err" "no REFUSED in err"
  # report mode
  run_report "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "report mode exits 0"
  assert_grep "free_written=yes" "$tmp/rout" "report shows free_written=yes"
  assert_grep "paid_step_ups=0" "$tmp/rout" "report shows paid_step_ups=0"
}

test_gate_prefix_stripped_ranked_name_passes() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"zai/glm-5"},{"model":"nvidia/nemotron-3-ultra-550b-a55b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"auto","served_model":"openrouter/zai/glm-5"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "prefix-stripped ranked name passes"
}

test_gate_unprefixed_ranked_name_passes() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"zai/glm-5"},{"model":"nvidia/nemotron-3-ultra-550b-a55b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"auto","served_model":"zai/glm-5"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "unprefixed ranked name passes"
}

test_gate_direct_paid_name_refused() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"zai/glm-5"},{"model":"nvidia/nemotron-3-ultra-550b-a55b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"deepseek-chat","served_model":"deepseek-chat"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 1 $rc "direct paid name refused"
  assert_grep "REFUSED: fanout-gate" "$tmp/err" "REFUSED prefix"
  assert_grep "deepseek-chat" "$tmp/err" "deepseek-chat named"
}

test_gate_and_report_agree() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"zai/glm-5"},{"model":"nvidia/nemotron-3-ultra-550b-a55b"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"a","outcome":"check_passed","requested_model":"nvidia/nemotron-3-ultra-550b-a55b:free","served_model":"kilo/nvidia/nemotron-3-ultra-550b-a55b:free"}
{"run_id":"fr-20261005T010203Z-abc123","label":"b","outcome":"check_passed","requested_model":"deepseek-chat","served_model":"deepseek-chat"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 1 $rc "gate refuses when any unit is paid"
  assert_grep "REFUSED: fanout-gate" "$tmp/err" "REFUSED prefix"
  assert_grep "deepseek-chat" "$tmp/err" "deepseek-chat named"
  assert_no_grep "kilo/" "$tmp/err" "no kilo/ in err"
  # report mode
  run_report "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "report mode exits 0 and counts only the free unit"
  assert_grep "units=1" "$tmp/rout" "report shows units=1"
}

test_gate_requested_free_served_same_model_router_prefixed_passes() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"zai/glm-5"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"t-gate-retry-tests","outcome":"check_passed","requested_model":"nvidia/nemotron-3-ultra-550b-a55b:free","served_model":"requesty/nvidia/nemotron-3-ultra-550b-a55b"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "requested free served same model router prefixed passes"
  assert_no_grep "REFUSED" "$tmp/err" "no REFUSED in err"
  # report mode
  run_report "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "report mode exits 0"
  assert_grep "free_written=yes" "$tmp/rout" "report shows free_written=yes"
}

test_gate_requested_free_served_different_paid_model_refused() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"zai/glm-5"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"nvidia/nemotron-3-ultra-550b-a55b:free","served_model":"requesty/anthropic/claude-sonnet"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 1 $rc "requested free served different paid model refused"
  assert_grep "claude-sonnet" "$tmp/err" "served model named"
}

test_gate_split_resolves_exhausted_with_router_prefixed_requested_free() {
  local tmp
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  local models_file
  models_file="$tmp/models.json"
  FM_FANOUT_MODELS="$models_file"
  export FM_FANOUT_MODELS
  cat > "$models_file" <<'EOF'
{"models":[{"model":"zai/glm-5"}]}
EOF
  local state_file
  state_file="$tmp/state/t1.status"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$state_file"
  local ledger
  ledger="$tmp/units.jsonl"
  cat > "$ledger" <<EOF
{"run_id":"fr-20261005T010203Z-abc123","label":"p","outcome":"free_exhausted","requested_model":"auto","served_model":""}
{"run_id":"fr-20261005T010203Z-abc123","label":"p--a","outcome":"check_passed","requested_model":"nvidia/nemotron-3-ultra-550b-a55b:free","served_model":"requesty/nvidia/nemotron-3-ultra-550b-a55b"}
EOF
  local rc
  run_gate "$tmp" "t1"
  rc=$?
  expect_code 0 $rc "split resolves exhausted with router prefixed requested free"
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
test_gate_router_prefixed_free_name_passes
test_gate_prefix_stripped_ranked_name_passes
test_gate_unprefixed_ranked_name_passes
test_gate_direct_paid_name_refused
test_gate_and_report_agree
test_gate_requested_free_served_same_model_router_prefixed_passes
test_gate_requested_free_served_different_paid_model_refused
test_gate_split_resolves_exhausted_with_router_prefixed_requested_free