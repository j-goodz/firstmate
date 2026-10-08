#!/usr/bin/env bash
# Tests for fm-backlog-overdue.sh arm subcommand: creates a private shim, registers it,
# is idempotent, refuses symlinks, and the shim runs wake correctly.
# To retire the shim, run bin/fm-check-unregister.sh backlog-overdue.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SCRIPT="$ROOT/bin/fm-backlog-overdue.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-overdue)
NOW=$(date -u -d 2026-10-08T12:00:00Z +%s)

unset FM_OVERDUE_NOW_EPOCH FM_OVERDUE_LIMIT FM_OVERDUE_QUEUED_HOURS FM_OVERDUE_LOG

test_arm_writes_a_registered_private_shim() {
  local home; home="$TMP_ROOT/arm-writes"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] a-inflight - In flight, fresh (repo: x) (kind: ship) (since 2026-10-08)
- [ ] a-inflight-late - In flight with a passed hold date (repo: x) (kind: ship) (since 2026-09-01) (hold: waiting on reset) (hold-until: 2026-10-07)

## Queued
- [ ] old-queued - Old queued item (repo: x) (kind: ship) (since 2026-09-24)
  an indented body line (since 2020-01-01) that must never count as a row
- [ ] fresh-queued - Queued 36 hours (repo: x) (kind: ship) (since 2026-10-07)
- [ ] hold-past - Hold date passed (repo: x) (kind: captain) (since 2026-09-30) (hold: ask) (hold-kind: captain) (hold-until: 2026-10-06)
- [ ] hold-future - Hold date ahead (repo: x) (kind: captain) (since 2026-09-01) (hold: ask) (hold-kind: captain) (hold-until: 2026-10-20)
- [ ] hold-today - Hold date is today (repo: x) (kind: captain) (since 2026-10-01) (hold: ask) (hold-kind: captain) (hold-until: 2026-10-08)
- [ ] held-undated - Captain hold without date (repo: x) (kind: captain) (since 2026-09-01) (hold: waiting for captain) (hold-kind: captain)
- [ ] pacing-undated - Pacing hold without reset (repo: x) (kind: ship) (since 2026-10-03) (hold: Pacing on until the weekly reset)
- [ ] pacing-dated - Pacing hold with reset (repo: x) (kind: ship) (since 2026-10-03) (hold: Pacing on) (hold-until: 2026-10-12)
- [ ] due-past - Due date passed (repo: x) (kind: ship) (since 2026-10-05) (due: 2026-10-06)
- [ ] blocked-one - Blocked (repo: x) (kind: ship) (since 2026-09-01) (blocked-by: old-queued)
- [ ] no-since - Queued with no since date (repo: x) (kind: ship)

## Done
- [x] done-old - Done row with a stale date (repo: x) (kind: ship) (since 2026-01-01) (hold-until: 2020-01-01)
EOF

  local out; out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" arm 2>&1)
  local status=$?
  assert_equals 0 "$status" "arm exits 0"
  assert_equals "" "$out" "arm prints nothing"

  local shim="$home/state/backlog-overdue.check.sh"
  local trust="$home/state/backlog-overdue.check-trust"

  local mode; mode=$(stat -c %a "$shim")
  assert_equals "700" "$mode" "shim mode 700"

  local firstline; firstline=$(head -1 "$shim")
  assert_contains "$firstline" "#!/usr/bin/env bash" "shim starts with shebang"

  local content; content=$(cat "$shim")
  assert_contains "$content" "export FM_HOME=" "shim exports FM_HOME"

  local lastline; lastline=$(tail -1 "$shim")
  assert_contains "$lastline" "fm-backlog-overdue.sh" "shim last line references script"
  assert_contains "$lastline" "wake" "shim last line runs wake"

  local trust_exists; trust_exists=$(test -f "$trust" && echo "yes" || echo "no")
  assert_equals "yes" "$trust_exists" "trust file exists"
}

test_arm_is_idempotent() {
  local home; home="$TMP_ROOT/arm-idempotent"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] old-queued - Old queued item (repo: x) (kind: ship) (since 2026-09-24)
EOF

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" arm >/dev/null
  local cksum1; cksum1=$(cksum "$home/state/backlog-overdue.check.sh")
  local trust1; trust1=$(cksum "$home/state/backlog-overdue.check-trust")

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" arm >/dev/null
  local cksum2; cksum2=$(cksum "$home/state/backlog-overdue.check.sh")
  local trust2; trust2=$(cksum "$home/state/backlog-overdue.check-trust")

  assert_equals "$cksum1" "$cksum2" "shim bytes identical after second arm"
  assert_equals "$trust1" "$trust2" "trust file bytes identical after second arm"
}

test_arm_refuses_a_symlink_destination() {
  local home; home="$TMP_ROOT/arm-symlink"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] old-queued - Old queued item (repo: x) (kind: ship) (since 2026-09-24)
EOF

  local target="$home/state/other.sh"
  printf '#!/usr/bin/env bash\n' > "$target"
  ln -s "$target" "$home/state/backlog-overdue.check.sh"

  local err; err=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" arm 2>&1 >/dev/null)
  local status=$?
  if [ "$status" -eq 0 ]; then fail "arm should exit non-zero for symlink"; fi
  assert_contains "$err" "symlink" "arm mentions symlink in stderr"
  assert_equals "#!/usr/bin/env bash" "$(cat "$target")" "symlink target unchanged"
}

test_armed_shim_runs_the_wake() {
  local home; home="$TMP_ROOT/arm-shim-wake"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] old-queued - Old queued item (repo: x) (kind: ship) (since 2026-09-24)
EOF

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" arm >/dev/null

  local shim="$home/state/backlog-overdue.check.sh"
  local out; out=$(FM_OVERDUE_NOW_EPOCH="$NOW" "$shim" 2>&1)
  local status=$?
  assert_equals 0 "$status" "shim exits 0"
  assert_contains "$out" "backlog-overdue: 1 item(s) overdue, woken" "shim prints woken line"

  local queue="$home/state/.wake-queue"
  assert_grep "old-queued" "$queue" "wake queue contains old-queued"

  local log="$home/state/backlog-overdue.jsonl"
  assert_grep "old-queued" "$log" "JSONL log contains old-queued"
  while IFS= read -r line; do
    jq -e . >/dev/null 2>&1 <<< "$line" || fail "JSONL line is invalid JSON"
  done < "$log"
}

test_arm_writes_a_registered_private_shim
test_arm_is_idempotent
test_arm_refuses_a_symlink_destination
test_armed_shim_runs_the_wake
