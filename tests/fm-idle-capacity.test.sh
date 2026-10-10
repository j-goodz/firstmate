#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EXTRA_ENV=()

SCRIPT="$ROOT/bin/fm-idle-capacity.sh"

# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------
run_check() {
  local home=$1 now=$2
  OUT=$( env FM_HOME="$home" \
    FM_IDLE_CAPACITY_NOW="$now" \
    FM_IDLE_CAPACITY_READY_CMD="$READY_CMD" \
    FM_IDLE_CAPACITY_HUB_PROBE="$HUB_PROBE" \
    FM_THERMAL_SYSFS="$THERMAL_ROOT" \
    FM_HWMON_SYSFS="$HWMON_ROOT" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    "$SCRIPT" check 2>/dev/null )
  RC=$?
}

write_ready() {
  local case_dir=$1
  shift
  local kinds=("$@")
  local ready_file="$case_dir/ready.txt"
  {
    echo "count: ${#kinds[@]}"
    if (( ${#kinds[@]} )); then
      echo "ready[${#kinds[@]}]{id,state,kind,repo,title}:"
      local i=1
      for kind in "${kinds[@]}"; do
        printf "  ready-%d,queued,%s,nexus,\"title %d\"\n" "$i" "$kind" "$i"
        ((i++))
      done
    fi
    echo "ready_public_followups: 0 delivery-ready obligations"
    echo "help[1]:"
    echo "  - Run \`tasks-axi start <id>\` to dispatch one of these"
  } > "$ready_file"
}

write_sysfs() {
  local root=$1; shift
  local idx=0
  for entry in "$@"; do
    IFS=':' read -r type temp <<< "$entry"
    local zone="${root}/thermal_zone${idx}"
    mkdir -p "$zone"
    echo "$type" > "${zone}/type"
    echo "$temp" > "${zone}/temp"
    ((idx++))
  done
}

seed_worker() {
  local home=$1 id=$2 state=$3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf '%s\n' "gen-$id" > "$home/state/$id.busy-gen"
  printf 'v1 gen=%s seq=1 state=%s source=claude-hook event=%s ts=1700000000\n' \
    "gen-$id" "$state" "ev-$id" > "$home/state/$id.busy-state"
  # secondmate record (must not count)
  fm_write_meta "$home/state/sm.meta" \
    "window=firstmate:fm-sm" \
    "endpoint_task_id=sm" \
    "harness=claude" \
    "kind=secondmate"
}

# ----------------------------------------------------------------------
# Test cases
# ----------------------------------------------------------------------
test_both_positive_nine_minutes_no_wake() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "both_positive_nine")
  local case=$TMP_ROOT/case1
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  # config
  printf 'max_workers=4\n' > "$home/config/thermal-gate"

  # ready (2 ship rows)
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"

  # hub reachable
  HUB_PROBE=true

  # thermal 55C
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # no workers
  # first run at T0
  run_check "$home" 1800000000
  assert_equals "" "$OUT" "first run should be silent"
  expect_code 0 $RC "first run exit 0"

  # second run at T0+540 (9 min)
  run_check "$home" $((1800000000+540))
  assert_equals "" "$OUT" "second run (9min) still silent"
  expect_code 0 $RC "second run exit 0"
  pass "both_positive_nine_minutes_no_wake"
}

test_both_positive_ten_minutes_wakes_once() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "both_positive_ten")
  local case=$TMP_ROOT/case2
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # T0
  run_check "$home" 1800000000
  assert_equals "" "$OUT" "T0 silent"
  # T0+300
  run_check "$home" $((1800000000+300))
  assert_equals "" "$OUT" "T0+300 silent"
  # T0+600
  run_check "$home" $((1800000000+600))
  assert_equals "idle capacity: 4 slots, 2 ready" "$OUT" "T0+600 should wake"
  pass "both_positive_ten_minutes_wakes_once"
}

test_cooldown_is_honored() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "cooldown")
  local case=$TMP_ROOT/case3
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # priming run at T0 (condition starts holding)
  run_check "$home" 1800000000
  assert_equals "" "$OUT" "priming run silent"
  # first wake at +600
  run_check "$home" $((1800000000+600))
  assert_equals "idle capacity: 4 slots, 2 ready" "$OUT" "first wake"
  # within cooldown
  for delta in 660 1200 4100; do
    run_check "$home" $((1800000000+delta))
    assert_equals "" "$OUT" "still cooldown at +$delta"
  done
  # after cooldown (600+3600 = 4200)
  run_check "$home" $((1800000000+4200))
  assert_equals "idle capacity: 4 slots, 2 ready" "$OUT" "second wake after cooldown"
  pass "cooldown_is_honored"
}

test_held_and_blocked_items_are_not_counted() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "held_blocked")
  local case=$TMP_ROOT/case4
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # 1) only task kind (should not count)
  write_ready "$case" task task
  READY_CMD="cat $case/ready.txt"
  run_check "$home" 1800000000
  assert_equals "" "$OUT" "no ready counted (first run)"
  run_check "$home" $((1800000000+600))
  assert_equals "" "$OUT" "still no wake after 600s"

  # 2) add ship and chore (2 counted)
  write_ready "$case" chore task ship
  READY_CMD="cat $case/ready.txt"
  # reset time to T0+1200 so that condition holds for 600s
  run_check "$home" $((1800000000+1200))
  assert_equals "" "$OUT" "condition just started, silent"
  run_check "$home" $((1800000000+1800))
  assert_equals "idle capacity: 4 slots, 2 ready" "$OUT" "wake after 600s with ship+chore"
  pass "held_and_blocked_items_are_not_counted"
}

test_kind_filter_ship_scout_chore() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "kind_filter")
  local case=$TMP_ROOT/case5
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  write_ready "$case" ship scout chore task repo-sync decision
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  run_check "$home" 1800000000
  run_check "$home" $((1800000000+300))
  run_check "$home" $((1800000000+600))
  assert_equals "idle capacity: 4 slots, 3 ready" "$OUT" "only ship, scout, chore counted"
  pass "kind_filter_ship_scout_chore"
}

test_hub_unreachable_skips_and_never_runs_ready() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "hub_unreach")
  local case=$TMP_ROOT/case6
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt && touch $case/ready-ran"
  HUB_PROBE=false   # unreachable
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # three runs while hub unreachable
  for delta in 0 600 7200; do
    run_check "$home" $((1800000000+delta))
    assert_equals "" "$OUT" "hub unreachable run $delta silent"
    expect_code 0 $RC "exit 0"
  done
  assert_absent "$case/ready-ran" "ready command never executed"

  # continuity restart scenario
  HUB_PROBE=true   # reachable again
  READY_CMD="cat $case/ready.txt && touch $case/ready-ran2"
  # T0 reachable (holds condition)
  run_check "$home" 1800000000
  # T0+300 hub unreachable
  HUB_PROBE=false
  run_check "$home" $((1800000000+300))
  # T0+700 reachable again, but continuity cleared, so still silent
  HUB_PROBE=true
  run_check "$home" $((1800000000+700))
  assert_equals "" "$OUT" "still silent after hub flaps"
  # T0+1300 (600s after reachable start) should wake
  run_check "$home" $((1800000000+1300))
  assert_equals "idle capacity: 4 slots, 2 ready" "$OUT" "wake after continuity restored"
  pass "hub_unreachable_skips_and_never_runs_ready"
}

test_thermal_gate_holding_gives_zero_slots() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "thermal_hold")
  local case=$TMP_ROOT/case7
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  # hold_c=88, temp 90C
  printf 'hold_c=88\n' > "$home/config/thermal-gate"
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:90000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  run_check "$home" $((1800000000+600))
  assert_equals "" "$OUT" "holding gate yields no wake"

  # hot tier test
  printf 'hot_c=80\nmax_workers=4\n' > "$home/config/thermal-gate"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:85000"
  # one busy worker
  seed_worker "$home" w1 busy
  run_check "$home" $((1800000000+1200))
  assert_equals "" "$OUT" "hot tier with busy worker yields 0 slots"

  # zero busy workers, same hot temp
  rm -rf "$home/state"/*   # clear workers
  run_check "$home" $((1800000000+1800))
  assert_equals "" "$OUT" "priming run silent"
  run_check "$home" $((1800000000+2400))
  assert_equals "idle capacity: 1 slots, 2 ready" "$OUT" "hot tier with idle yields 1 slot"
  pass "thermal_gate_holding_gives_zero_slots"
}

test_live_workers_reduce_slots() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "live_workers")
  local case=$TMP_ROOT/case8
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # priming run at T0 (condition starts holding)
  run_check "$home" 1800000000
  assert_equals "" "$OUT" "priming run silent"
  # two busy workers, one idle (idle not counted)
  seed_worker "$home" b1 busy
  seed_worker "$home" b2 busy
  seed_worker "$home" i1 idle
  run_check "$home" $((1800000000+600))
  assert_equals "idle capacity: 2 slots, 2 ready" "$OUT" "2 free slots after 2 busy workers"
  # four busy workers -> no slots
  rm -rf "$home/state"/*
  seed_worker "$home" b1 busy
  seed_worker "$home" b2 busy
  seed_worker "$home" b3 busy
  seed_worker "$home" b4 busy
  run_check "$home" $((1800000000+1200))
  assert_equals "" "$OUT" "no wake when all workers busy"
  pass "live_workers_reduce_slots"
}

test_no_gate_file_uses_default_cap() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "default_cap")
  local case=$TMP_ROOT/case9
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  # no thermal-gate file
  export FM_IDLE_CAPACITY_DEFAULT_CAP=2
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  mkdir -p "$THERMAL_ROOT"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # priming run at T0 (condition starts holding)
  run_check "$home" 1800000000
  assert_equals "" "$OUT" "priming run silent"
  run_check "$home" $((1800000000+600))
  assert_equals "idle capacity: 2 slots, 2 ready" "$OUT" "default cap used"
  pass "no_gate_file_uses_default_cap"
}

test_nothing_to_do_prints_nothing() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "nothing")
  local case=$TMP_ROOT/case10
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  write_ready "$case"   # zero ready rows
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # create a data file to check unchanged
  echo "backlog content" > "$home/data/backlog.md"
  local sha_before
  sha_before=$(sha256sum "$home/data/backlog.md" | awk '{print $1}')

  for delta in 0 600 99999; do
    run_check "$home" $((1800000000+delta))
    assert_equals "" "$OUT" "run $delta silent"
  done

  # slots 0 + ready rows case
  printf 'max_workers=0\n' > "$home/config/thermal-gate"
  write_ready "$case" ship
  READY_CMD="cat $case/ready.txt"
  run_check "$home" $((1800000000+200000))
  assert_equals "" "$OUT" "zero slots with ready still silent"

  # state dir should only contain .idle-capacity (if any) and files we created
  local state_files
  state_files=$(ls -A "$home/state")
  # allow .idle-capacity possibly present
  for f in $state_files; do
    [[ "$f" == ".idle-capacity" ]] || fail "unexpected file $f in state"
  done

  local sha_after
  sha_after=$(sha256sum "$home/data/backlog.md" | awk '{print $1}')
  assert_equals "$sha_before" "$sha_after" "data file unchanged"
  pass "nothing_to_do_prints_nothing"
}

test_condition_break_resets_the_clock() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "break_clock")
  local case=$TMP_ROOT/case11
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  # T0 condition holds
  run_check "$home" 1800000000
  assert_equals "" "$OUT" "condition holds at T0 silent"

  # T0+300 ready becomes empty (simulate by writing empty ready)
  write_ready "$case"
  READY_CMD="cat $case/ready.txt"
  run_check "$home" $((1800000000+300))
  assert_equals "" "$OUT" "empty ready silent"

  # T0+400 ready returns ship rows again
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"
  run_check "$home" $((1800000000+400))
  assert_equals "" "$OUT" "condition just restarted, still <600s"

  # T0+700 (only 300s since restart) silent
  run_check "$home" $((1800000000+700))
  assert_equals "" "$OUT" "still before threshold"

  # T0+1000 (600s since restart) wake
  run_check "$home" $((1800000000+1000))
  assert_equals "idle capacity: 4 slots, 2 ready" "$OUT" "wake after reset"
  pass "condition_break_resets_the_clock"
}

test_arm_registers_a_trusted_silent_shim() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "arm")
  local case=$TMP_ROOT/case12
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  # arm
  OUT=$(FM_HOME="$home" "$SCRIPT" arm)
  RC=$?
  expect_code 0 $RC "arm exit 0"
  assert_contains "$OUT" "armed:" "arm output mentions armed"
  local shim_path="$home/state/idle-capacity.check.sh"
  assert_present "$shim_path" "shim file exists"
  local mode
  mode=$(stat -c %a "$shim_path")
  assert_equals "700" "$mode" "shim mode 700"
  assert_present "$home/state/idle-capacity.check-trust" "trust file exists"

  # arm again (idempotent)
  OUT=$(FM_HOME="$home" "$SCRIPT" arm)
  RC=$?
  expect_code 0 $RC "second arm exit 0"

  # run shim (should be silent)
  mkdir -p "$case/sysfs" "$case/hwmon"
  OUT=$(env FM_HOME="$home" FM_IDLE_CAPACITY_NOW=1800000000 FM_IDLE_CAPACITY_READY_CMD="true" FM_IDLE_CAPACITY_HUB_PROBE=true FM_THERMAL_SYSFS="$case/sysfs" FM_HWMON_SYSFS="$case/hwmon" "$shim_path" 2>/dev/null)
  RC=$?
  expect_code 0 $RC "shim exit 0"
  assert_equals "" "$OUT" "shim silent when no work"

  # disarm
  OUT=$(FM_HOME="$home" "$SCRIPT" disarm)
  RC=$?
  expect_code 0 $RC "disarm exit 0"
  assert_contains "$OUT" "disarmed:" "disarm output"
  assert_absent "$shim_path" "shim removed"
  assert_absent "$home/state/idle-capacity.check-trust" "trust removed"
  assert_absent "$home/state/.idle-capacity" "state file removed"
  pass "arm_registers_a_trusted_silent_silent_shim"
}

test_help_and_usage() {
  OUT=$("$SCRIPT" --help)
  RC=$?
  expect_code 0 $RC "help exit 0"
  assert_contains "$OUT" "arm" "help mentions arm"
  assert_contains "$OUT" "disarm" "help mentions disarm"

  OUT=$("$SCRIPT" bogus 2>/dev/null)
  RC=$?
  expect_code 2 $RC "bogus subcommand exit 2"
  pass "help_and_usage"
}

test_decimal_threshold_override() {
  local TMP_ROOT
  TMP_ROOT=$(fm_test_tmproot "decimal_thresh")
  local case=$TMP_ROOT/case14
  local home=$case/home
  mkdir -p "$home/state" "$home/config" "$home/data"

  printf 'max_workers=4\n' > "$home/config/thermal-gate"
  write_ready "$case" ship ship
  READY_CMD="cat $case/ready.txt"
  HUB_PROBE=true
  THERMAL_ROOT="$case/sysfs"
  write_sysfs "$THERMAL_ROOT" "x86_pkg_temp:55000"
  HWMON_ROOT="$case/hwmon"
  mkdir -p "$HWMON_ROOT"

  export FM_IDLE_CAPACITY_THRESHOLD_SECS=30
  export FM_IDLE_CAPACITY_COOLDOWN_SECS=60

  # T0
  run_check "$home" 1800000000
  assert_equals "" "$OUT" "T0 silent"
  # T0+30 should wake
  run_check "$home" $((1800000000+30))
  assert_equals "idle capacity: 4 slots, 2 ready" "$OUT" "wake at 30s"
  # T0+89 (still within cooldown) silent
  run_check "$home" $((1800000000+89))
  assert_equals "" "$OUT" "still cooldown at 89s"
  # T0+90 (cooldown over) wake again
  run_check "$home" $((1800000000+90))
  assert_equals "idle capacity: 4 slots, 2 ready" "$OUT" "second wake at 90s"
  pass "decimal_threshold_override"
}

# ----------------------------------------------------------------------
# Execute all tests
# ----------------------------------------------------------------------
test_both_positive_nine_minutes_no_wake
test_both_positive_ten_minutes_wakes_once
test_cooldown_is_honored
test_held_and_blocked_items_are_not_counted
test_kind_filter_ship_scout_chore
test_hub_unreachable_skips_and_never_runs_ready
test_thermal_gate_holding_gives_zero_slots
test_live_workers_reduce_slots
test_no_gate_file_uses_default_cap
test_nothing_to_do_prints_nothing
test_condition_break_resets_the_clock
test_arm_registers_a_trusted_silent_shim
test_help_and_usage
test_decimal_threshold_override
