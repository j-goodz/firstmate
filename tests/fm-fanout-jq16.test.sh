#!/usr/bin/env bash
# Regression: fm-fanout-check.sh must evaluate units on jq 1.6, where {run_id, label} shorthand is a syntax error.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_gate_units_evaluated_on_host_jq() {
  local tmp rc
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data"
  cat > "$tmp/models.json" <<'JSON'
{"models":[{"model":"dots-studio/dots-3-note-preview:free"},{"model":"openai/gpt-oss-120b"}]}
JSON
  export FM_FANOUT_MODELS="$tmp/models.json"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$tmp/state/t1.status"
  cat > "$tmp/units.jsonl" <<'JSON'
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free","at":"2026-10-05T01:00:00Z"}
{"run_id":"fr-20261005T010203Z-abc123","label":"u2","outcome":"free_exhausted","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free","at":"2026-10-05T01:01:00Z"}
{"run_id":"fr-20261005T010203Z-abc123","label":"u2--a","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free","at":"2026-10-05T01:02:00Z"}
JSON
  FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_DATA_OVERRIDE="$tmp/data" FM_FANOUT_LEDGER="$tmp/units.jsonl" "$ROOT/bin/fm-fanout-check.sh" t1 --gate >"$tmp/out" 2>"$tmp/err"
  rc=$?
  if grep -qiE 'jq: error|syntax error' "$tmp/err"; then
    fail "jq printed an error: $(head -3 "$tmp/err")"
  fi
  expect_code 0 "$rc" "gate passes: u2 exhausted but cleared by split u2--a"
  assert_grep 'units=2 ' "$tmp/out" "units evaluated (greater than 0)"
  assert_grep 'verdict=yes' "$tmp/out" "verdict yes: the exhausted unit is cleared by its split"
  assert_grep 'paid_step_ups=0' "$tmp/out" "no paid step-ups remain"
  assert_no_grep 'REFUSED' "$tmp/err" "no refusal"
  pass "gate evaluates units on host jq"
}

test_gate_units_evaluated_on_host_jq