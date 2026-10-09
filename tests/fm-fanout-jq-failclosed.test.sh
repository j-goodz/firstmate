#!/usr/bin/env bash
# Regression: fm-fanout-check.sh --gate must fail closed (REFUSED, exit 1) when jq itself fails.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_gate_refuses_when_jq_fails() {
  local tmp rc
  tmp=$(fm_test_tmproot)
  mkdir -p "$tmp/state" "$tmp/data" "$tmp/fakebin"
  cat > "$tmp/models.json" <<'JSON'
{"models":[{"model":"dots-studio/dots-3-note-preview:free"}]}
JSON
  export FM_FANOUT_MODELS="$tmp/models.json"
  echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$tmp/state/t1.status"
  cat > "$tmp/units.jsonl" <<'JSON'
{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"check_passed","requested_model":"dots-studio/dots-3-note-preview:free","served_model":"dots-studio/dots-3-note-preview:free","at":"2026-10-05T01:00:00Z"}
JSON
  cat > "$tmp/fakebin/jq" <<'STUB'
#!/usr/bin/env bash
echo "jq: error: stub failure" >&2
exit 3
STUB
  chmod +x "$tmp/fakebin/jq"
  PATH="$tmp/fakebin:$PATH" FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_DATA_OVERRIDE="$tmp/data" FM_FANOUT_LEDGER="$tmp/units.jsonl" "$ROOT/bin/fm-fanout-check.sh" t1 --gate >"$tmp/out" 2>"$tmp/err"
  rc=$?
  expect_code 1 "$rc" "gate exits 1 when jq fails"
  assert_grep 'REFUSED: fanout-gate: jq failed' "$tmp/err" "refusal names the jq failure"
  pass "gate fails closed when jq fails"
}

test_gate_refuses_when_jq_fails