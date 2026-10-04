#!/usr/bin/env bash
# tests/fm-spawn-thermal-gate.test.sh - behavior tests for the optional
# per-home thermal gate (config/thermal-gate) in bin/fm-spawn.sh.
#
# The gate is opt-in and only exists when the local config file does. When it
# does, a fresh ship or scout spawn reads bin/fm-host-temp.sh and this home's
# live worker count before creating any endpoint, worktree, or record, and
# refuses over the temperature-dependent limit. The assertions drive the real
# spawn against a fake pane, a real isolated git worktree, and fixture sysfs
# trees, rather than reading bin/fm-spawn.sh's source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-thermal-gate)

# A synthetic sysfs tree with one directory per "type:temp" argument. A temp of
# "none" leaves that zone without its temp file.
write_sysfs() {  # <root> <type:temp>...
  local root=$1 spec i=0 type temp
  mkdir -p "$root"
  for spec in "$@"; do
    type=${spec%%:*}
    temp=${spec#*:}
    mkdir -p "$root/thermal_zone$i"
    printf '%s\n' "$type" > "$root/thermal_zone$i/type"
    if [ "$temp" != none ]; then
      printf '%s\n' "$temp" > "$root/thermal_zone$i/temp"
    fi
    i=$((i + 1))
  done
}

# make_case <name> [harness]: echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>".
make_case() {
  local name=$1 harness=${2:-codex} case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name-a1"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<XEOF
$1
XEOF
}

# Set this case's sysfs tree. Call after read_case and before run_case_spawn.
set_sysfs() {  # <type:temp>...
  write_sysfs "$CASE_DIR/sysfs" "$@"
}

run_case_spawn() {  # <args...>
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_THERMAL_SYSFS="$CASE_DIR/sysfs" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# seed_worker <home> <id> <busy|idle|missing>: a plain kind=ship task record plus
# its semantic busy-state sidecars. The gate counts only a record whose busy
# state classifies as busy, so an idle or missing record must not count. The
# harness is claude so the record's claude-hook source is trusted without any
# harness-specific verification gate.
seed_worker() {  # <home> <id> <busy|idle|missing>
  local home=$1 id=$2 state=$3
  local gen="gen-$id"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "yolo=off"
  [ "$state" = missing ] && return 0
  printf '%s\n' "$gen" > "$home/state/$id.busy-gen"
  printf 'v1 gen=%s seq=1 state=%s source=claude-hook event=%s ts=1700000000\n' \
    "$gen" "$state" "ev-$id" > "$home/state/$id.busy-state"
}

# --- gate absent / cool -----------------------------------------------------

test_gate_absent_leaves_spawn_unchanged() {
  local rec out status
  rec=$(make_case absent)
  read_case "$rec"
  # A hostile fixture temperature must be irrelevant when no config file exists.
  set_sysfs "x86_pkg_temp:99000"
  out=$(run_case_spawn absent-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with no thermal-gate config must succeed: $out"
  assert_contains "$out" "spawned absent-a1" "an absent gate must not change spawning"
  pass "an absent config/thermal-gate leaves spawning unchanged"
}

test_cool_under_the_cap_spawns() {
  local rec out status
  rec=$(make_case cool)
  read_case "$rec"
  set_sysfs "x86_pkg_temp:55000" "acpitz:60000"
  printf 'max_workers=4\n' > "$HOME_DIR/config/thermal-gate"
  out=$(run_case_spawn cool-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a cool spawn under the cap must succeed: $out"
  assert_contains "$out" "spawned cool-a1" "a cool spawn under the cap must launch"
  pass "a cool temperature below the cap permits the spawn"
}

# --- at the cap / hot / hold ------------------------------------------------

test_at_the_cap_refuses() {
  local rec out status
  rec=$(make_case at-cap)
  read_case "$rec"
  set_sysfs "x86_pkg_temp:55000"
  printf 'max_workers=1\n' > "$HOME_DIR/config/thermal-gate"
  seed_worker "$HOME_DIR" live-one busy
  out=$(run_case_spawn at-cap-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn at the cap must be refused"
  assert_contains "$out" "spawn refused" "the refusal must say it refused"
  assert_contains "$out" "temperature 55" "the refusal must name the temperature"
  assert_contains "$out" "limit 1" "the refusal must name the limit"
  assert_contains "$out" "live 1" "the refusal must name the live count"
  pass "a spawn at the max_workers cap is refused with a clear line"
}

# Swift's failure mode: many finished or waiting task records, none of them
# running work. They must not consume the cap, or the gate holds every spawn
# forever on an idle home.
test_idle_records_do_not_count_toward_the_cap() {
  local rec out status
  rec=$(make_case idle)
  read_case "$rec"
  set_sysfs "x86_pkg_temp:50000"
  printf 'max_workers=1\n' > "$HOME_DIR/config/thermal-gate"
  seed_worker "$HOME_DIR" idle-one idle
  seed_worker "$HOME_DIR" idle-two idle
  seed_worker "$HOME_DIR" missing-one missing
  out=$(run_case_spawn idle-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "idle, finished, and missing records must not hold the cap: $out"
  assert_contains "$out" "spawned idle-a1" "an idle home must still be able to spawn"
  pass "idle, finished, and missing task records do not count toward the cap"
}

test_busy_records_consume_the_cap() {
  local rec out status
  rec=$(make_case busy)
  read_case "$rec"
  set_sysfs "x86_pkg_temp:50000"
  printf 'max_workers=1\n' > "$HOME_DIR/config/thermal-gate"
  seed_worker "$HOME_DIR" idle-one idle
  seed_worker "$HOME_DIR" busy-one busy
  out=$(run_case_spawn busy-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a busy record must consume the cap"
  assert_contains "$out" "live 1" "only the busy record must count as live"
  pass "a busy task record counts toward the cap while its idle sibling does not"
}

test_hot_caps_at_one_worker() {
  local rec out status
  rec=$(make_case hot-empty)
  read_case "$rec"
  set_sysfs "x86_pkg_temp:75000"
  printf 'max_workers=4\nhot_c=70\n' > "$HOME_DIR/config/thermal-gate"
  out=$(run_case_spawn hot-empty-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "one worker may start while hot: $out"

  rec=$(make_case hot-full)
  read_case "$rec"
  set_sysfs "x86_pkg_temp:75000"
  printf 'max_workers=4\nhot_c=70\n' > "$HOME_DIR/config/thermal-gate"
  seed_worker "$HOME_DIR" live-one busy
  out=$(run_case_spawn hot-full-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a second worker while hot must be refused"
  assert_contains "$out" "temperature 75" "the hot refusal must name the temperature"
  assert_contains "$out" "limit 1" "the hot tier must cap at one worker"
  pass "the hot threshold caps the home at one worker"
}

test_hold_refuses_even_when_idle() {
  local rec out status
  rec=$(make_case hold)
  read_case "$rec"
  set_sysfs "x86_pkg_temp:90000"
  printf 'max_workers=4\nhold_c=85\n' > "$HOME_DIR/config/thermal-gate"
  out=$(run_case_spawn hold-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn at the hold threshold must be refused"
  assert_contains "$out" "temperature 90" "the hold refusal must name the temperature"
  assert_contains "$out" "limit 0" "the hold threshold allows no worker"
  pass "the hold threshold refuses a spawn even when the home is idle"
}

# --- unreadable sensor ------------------------------------------------------

test_unreadable_sensor_warns_and_applies_max_workers() {
  local rec out status
  rec=$(make_case unreadable-idle)
  read_case "$rec"
  mkdir -p "$CASE_DIR/sysfs"  # no zones at all
  printf 'max_workers=1\n' > "$HOME_DIR/config/thermal-gate"
  out=$(run_case_spawn unreadable-idle-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an idle home with an unreadable sensor must still spawn: $out"
  assert_contains "$out" "unreadable" "an unreadable sensor must warn"

  rec=$(make_case unreadable-full)
  read_case "$rec"
  mkdir -p "$CASE_DIR/sysfs"
  printf 'max_workers=1\n' > "$HOME_DIR/config/thermal-gate"
  seed_worker "$HOME_DIR" live-one busy
  out=$(run_case_spawn unreadable-full-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unreadable sensor must still apply max_workers"
  assert_contains "$out" "unreadable" "the unreadable warning must accompany the refusal"
  assert_contains "$out" "limit 1" "the fallback cap must be max_workers"
  pass "an unreadable sensor warns and falls back to max_workers"
}

# --- secondmate parent channel ----------------------------------------------

# Make a marked secondmate home bound to <main-home>, plus its own worktree.
make_mate_home() {  # <case-dir> <main-home> <id>; echoes "<mate>|<mate-wt>"
  local case_dir=$1 main=$2 id=$3 mate wt proj
  mate="$case_dir/mate"
  proj="$case_dir/mate-proj"
  wt="$case_dir/mate-wt"
  mkdir -p "$mate/data" "$mate/projects" "$mate/state" "$mate/config"
  touch "$mate/state/.last-watcher-beat"
  printf 'codex\n' > "$mate/config/crew-harness"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  cat > "$mate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$main
EOF
  fm_git_worktree "$proj" "$wt" "wt-$id"
  printf '%s\n' "$mate|$wt"
}

test_refusal_in_a_secondmate_home_reports_the_parent_once() {
  local rec main mate_wt out status lines
  rec=$(make_case parent)
  read_case "$rec"
  main="$CASE_DIR/main"
  mkdir -p "$main/state" "$main/data" "$main/config" "$main/projects"
  SM_OUT=$(make_mate_home "$CASE_DIR" "$main" mate)
  IFS='|' read -r SM_DIR mate_wt <<EOF
$SM_OUT
EOF
  # A marked secondmate home has its own sysfs tree and gate config.
  write_sysfs "$SM_DIR/sysfs" "x86_pkg_temp:92000"
  printf 'max_workers=4\nhold_c=85\n' > "$SM_DIR/config/thermal-gate"
  : > "$LAUNCH_LOG"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_THERMAL_SYSFS="$SM_DIR/sysfs" \
    fm_test_run_spawn "$SM_DIR" "$mate_wt" "$FAKEBIN_DIR" mate-a1 "$PROJ_DIR" \
    --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a hold refusal in a secondmate home must refuse"
  [ -f "$main/state/mate.status" ] || fail "the refusal did not reach the parent channel"
  lines=$(grep -c 'paused \[key=thermal-gate-' "$main/state/mate.status" || true)
  [ "$lines" = 1 ] || fail "expected exactly one paused parent-channel line, got $lines: $(cat "$main/state/mate.status")"
  assert_grep 'thermal gate' "$main/state/mate.status" \
    "the parent line must say the thermal gate held the spawn"
  grep -Eq '^paused \[key=thermal-gate-[^]]+\] \[at=[0-9]+\]:' "$main/state/mate.status" \
    || fail "the paused parent line must carry an [at=<epoch>] stamp like every other status line: $(cat "$main/state/mate.status")"
  pass "a refusal in a secondmate home publishes exactly one stamped paused parent line"
}

# --- jobs env ---------------------------------------------------------------

test_jobs_reaches_the_launch_file() {
  local rec out status launch
  rec=$(make_case jobs)
  read_case "$rec"
  set_sysfs "x86_pkg_temp:50000"
  printf 'max_workers=4\njobs=3\n' > "$HOME_DIR/config/thermal-gate"
  out=$(run_case_spawn jobs-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with jobs set must succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CARGO_BUILD_JOBS=3" "the jobs value must reach CARGO_BUILD_JOBS"
  assert_contains "$launch" "MAKEFLAGS=-j3" "the jobs value must reach MAKEFLAGS"
  assert_contains "$launch" "PYTEST_XDIST_AUTO_NUM_WORKERS=3" "the jobs value must reach the pytest worker count"
  pass "a configured jobs value reaches the worker launch environment"
}

test_gate_absent_leaves_spawn_unchanged
test_cool_under_the_cap_spawns
test_at_the_cap_refuses
test_idle_records_do_not_count_toward_the_cap
test_busy_records_consume_the_cap
test_hot_caps_at_one_worker
test_hold_refuses_even_when_idle
test_unreadable_sensor_warns_and_applies_max_workers
test_refusal_in_a_secondmate_home_reports_the_parent_once
test_jobs_reaches_the_launch_file
