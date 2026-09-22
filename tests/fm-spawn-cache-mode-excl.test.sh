#!/usr/bin/env bash
# tests/fm-spawn-cache-mode-excl.test.sh - every agent this fleet launches -
# ship, scout, and secondmate alike - must start with NEXUS_CACHE_MODE=off in
# its environment, so nexus's session cycler never targets a fanned-out worker
# mid-build (nexus task ce5555be7b2d). A worker session runs to completion and
# is then torn down, so clearing its context mid-build only loses build state
# it is holding; the long-lived brain session keeps auto-cycling on, so this
# switch must never appear in the machine or project default, only the
# per-launch worker environment.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real
# spawn against a fake pane and a real isolated git worktree, then EXECUTE the
# launch command the pane actually received, under a synthetic pane
# environment, with the harness binary replaced by a probe that prints the
# environment it was started with. What the probe prints is what a real agent
# would have received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-cache-mode-excl)

# A synthetic pane value the launch must override rather than inherit: the
# switch is a floor, so a pane that already carries a live value still has to
# start its agent with off.
CONTRARY=auto

install_env_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s\n' "${NEXUS_CACHE_MODE-unset}"
SH
  chmod +x "$1/$2"
}

emitted_launch_env() {  # <fakebin> <launch-log> <pane-log>
  local fakebin=$1 launchlog=$2 panelog=$3 launch preamble
  launch=$(cat "$launchlog")
  # The pane exports run before the launch command in the real pane shell, so
  # replay them here in the same order: a launch that only forwarded the
  # ambient environment would be caught here rather than reported as a pass.
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane NEXUS_CACHE_MODE="$CONTRARY" \
    /bin/sh -c "$preamble
$launch"
}

test_ship_launch_excludes_cache() {
  local case_dir home proj wt fakebin launchlog panelog out status seen
  case_dir="$TMP_ROOT/ship"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" wt-ship-cache-excl
  fm_test_spawn_brief "$home" ship-cache-excl-a1
  : > "$launchlog"
  : > "$panelog"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" ship-cache-excl-a1 "$proj" \
    --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn should succeed: $out"
  grep -qx 'export NEXUS_CACHE_MODE=off' "$panelog" \
    || fail "ship spawn did not export NEXUS_CACHE_MODE=off into the pane shell"
  install_env_probe "$fakebin" codex
  seen=$(emitted_launch_env "$fakebin" "$launchlog" "$panelog") \
    || fail "ship, cache-mode: the emitted launch failed to run"
  assert_equals off "$seen" \
    "a ship worker launched with a contrary ambient cache mode must start with NEXUS_CACHE_MODE=off"
  pass "ship launch starts its agent with the cache-cycle exclusion on"
}

test_secondmate_launch_excludes_cache() {
  local case_dir sm out status seen fakebin launchlog panelog
  case_dir="$TMP_ROOT/secondmate"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fm_test_spawn_home "$case_dir/home" codex
  fm_test_spawn_brief "$case_dir/home" sm-cache-excl
  sm="$case_dir/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' sm-cache-excl > "$sm/.fm-secondmate-home"
  printf 'charter for sm-cache-excl\n' > "$sm/data/charter.md"
  : > "$launchlog"
  : > "$panelog"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    fm_test_run_spawn "$case_dir/home" "$sm" "$fakebin" sm-cache-excl "$sm" \
    --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  grep -qx 'export NEXUS_CACHE_MODE=off' "$panelog" \
    || fail "secondmate spawn did not export NEXUS_CACHE_MODE=off into the pane shell"
  install_env_probe "$fakebin" codex
  seen=$(emitted_launch_env "$fakebin" "$launchlog" "$panelog") \
    || fail "secondmate, cache-mode: the emitted launch failed to run"
  assert_equals off "$seen" \
    "a secondmate launched with a contrary ambient cache mode must start with NEXUS_CACHE_MODE=off"
  pass "secondmate launch starts its agent with the cache-cycle exclusion on"
}

test_ship_launch_excludes_cache
test_secondmate_launch_excludes_cache
