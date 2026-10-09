#!/usr/bin/env bash
# tests/fm-wake-drain-hook-ack.test.sh - Tests the new behaviour of fm-wake-drain.sh
# when FM_STOP_HOOK_ACKS=1, where the Stop hook acknowledges through <N> instead
# of requiring manual --ack-through. Also verifies the old behaviour when unset.
# The test covers main drain, branch drain, and failure cases.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-hook-ack)

test_hook_ack_line_replaces_manual_instruction() {
  local dir state out err
  dir=$(make_case hook-ack-replaces)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" check inbox:1 "check: captain inbox note 1 - hi"

  FM_STATE_OVERRIDE="$state" FM_STOP_HOOK_ACKS=1 "$DRAIN" > "$out" 2> "$err"
  [ $? -eq 0 ] || fail "$(cat "$err")"

  grep -Fq 'WAKE_ACK: the Stop hook acknowledges through ' "$err" || fail "Expected WAKE_ACK line in stderr"
  grep -Fq 'Do not run --ack-through.' "$err" || fail "Expected 'Do not run --ack-through.' in stderr"
  ! grep -q '^WAKE_ACK_REQUIRED:' "$err" || fail "Unexpected WAKE_ACK_REQUIRED line in stderr"

  local sequence=$(sed -n 's/^WAKE_ACK: the Stop hook acknowledges through \([0-9][0-9]*\).*/\1/p' "$err")
  local delivered=$(cut -f1 "$state/.drain-delivered")
  [ "$sequence" = "$delivered" ] || fail "Sequence $sequence does not match delivered $delivered"

  [ -s "$state/.wake-queue" ] || fail "Queue file should not be empty after drain"
  pass "Hook ack line replaces manual instruction and queue is preserved"
}

test_manual_instruction_kept_when_the_hook_does_not_acknowledge() {
  local dir state out err
  dir=$(make_case manual-instruction-kept)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" check inbox:1 "check: captain inbox note 1 - hi"

  FM_STATE_OVERRIDE="$state" FM_STOP_HOOK_ACKS=0 "$DRAIN" > "$out" 2> "$err"
  [ $? -eq 0 ] || fail "$(cat "$err")"

  grep -Fq 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through ' "$err" || fail "Expected WAKE_ACK_REQUIRED line in stderr"
  ! grep -q '^WAKE_ACK:' "$err" || fail "Unexpected WAKE_ACK line in stderr"

  pass "Manual instruction is kept when hook does not acknowledge"
}

test_printed_manual_command_still_acknowledges() {
  local dir state out err
  dir=$(make_case manual-command-ack)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" check inbox:1 "check: captain inbox note 1 - hi"

  FM_STATE_OVERRIDE="$state" FM_STOP_HOOK_ACKS=0 "$DRAIN" > "$out" 2> "$err"
  [ $? -eq 0 ] || fail "$(cat "$err")"

  local sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  local generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" > "$out" 2> "$err"
  [ $? -eq 0 ] || fail "$(cat "$err")"

  [ ! -s "$state/.wake-queue" ] || fail "Queue file should be empty after manual ack"
  pass "Printed manual command still acknowledges the queue"
}

test_failed_delivery_record_write_keeps_the_manual_instruction() {
  local dir state out err
  dir=$(make_case failed-record-write)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" check inbox:1 "check: captain inbox note 1 - hi"
  # A fake mv refuses to move anything onto .drain-delivered, so the delivery
  # record cannot be written while every other mv behaves normally.
  local fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for last in "$@"; do :; done
case "$last" in
  */.drain-delivered) exit 1 ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$fakebin/mv"

  FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" FM_STOP_HOOK_ACKS=1 "$DRAIN" > "$out" 2> "$err"
  [ $? -eq 0 ] || fail "$(cat "$err")"

  grep -Fq 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through ' "$err" || fail "Expected WAKE_ACK_REQUIRED line in stderr"
  ! grep -q '^WAKE_ACK:' "$err" || fail "Unexpected WAKE_ACK line in stderr"

  pass "Failed delivery record write keeps the manual instruction"
}

test_branch_actor_keeps_the_manual_instruction() {
  local dir state out err
  dir=$(make_case branch-actor)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" signal task-a.status "signal: task-a"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$$" hook-ack
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish hook-ack 1

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch FM_STOP_HOOK_ACKS=1 "$DRAIN" > "$out" 2> "$err"
  [ $? -eq 0 ] || fail "$(cat "$err")"

  grep -Fq 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through ' "$err" || fail "Expected WAKE_ACK_REQUIRED line in stderr"
  ! grep -q '^WAKE_ACK:' "$err" || fail "Unexpected WAKE_ACK line in stderr"
  [ ! -f "$state/.drain-delivered" ] || fail "No .drain-delivered file should exist for branch actor"

  pass "Branch actor keeps the manual instruction"
}

test_harness_detection_decides_when_the_override_is_unset() {
  local dir state out err
  dir=$(make_case harness-detection)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" check inbox:1 "check: captain inbox note 1 - hi"

  local fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-detect")
  fm_fake_blind_ancestry "$fakebin"

  env -u FM_STOP_HOOK_ACKS FM_STATE_OVERRIDE="$state" CLAUDECODE=1 PATH="$fakebin:$PATH" "$DRAIN" > "$out" 2> "$err"
  [ $? -eq 0 ] || fail "$(cat "$err")"

  grep -Fq 'WAKE_ACK: the Stop hook acknowledges through ' "$err" || fail "Expected WAKE_ACK line in stderr"
  ! grep -q '^WAKE_ACK_REQUIRED:' "$err" || fail "Unexpected WAKE_ACK_REQUIRED line in stderr"

  dir=$(make_case harness-detection-no-override)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" check inbox:1 "check: captain inbox note 1 - hi"

  env -u CLAUDECODE -u FM_STOP_HOOK_ACKS FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" "$DRAIN" > "$out" 2> "$err"
  [ $? -eq 0 ] || fail "$(cat "$err")"

  grep -Fq 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through ' "$err" || fail "Expected WAKE_ACK_REQUIRED line in stderr"
  ! grep -q '^WAKE_ACK:' "$err" || fail "Unexpected WAKE_ACK line in stderr"

  pass "Harness detection decides when the override is unset"
}

test_hook_ack_line_replaces_manual_instruction
test_manual_instruction_kept_when_the_hook_does_not_acknowledge
test_printed_manual_command_still_acknowledges
test_failed_delivery_record_write_keeps_the_manual_instruction
test_branch_actor_keeps_the_manual_instruction
test_harness_detection_decides_when_the_override_is_unset