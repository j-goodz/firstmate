#!/usr/bin/env bash
# tests/fm-spawn-cache-mode-excl.test.sh - a ship or scout this fleet launches
# must start with NEXUS_CACHE_MODE=off in its environment, so nexus's session
# cycler never targets a fanned-out worker mid-build (nexus task ce5555be7b2d).
# A worker session runs to completion and is then torn down, so clearing its
# context mid-build only loses build state it is holding.
#
# A secondmate is the opposite shape: a persistent firstmate home, the same
# long-lived shape as the brain session the cycler exists to serve, so its
# launch must NOT force the value and must leave the machine and project
# cache-mode defaults in force. The switch never appears in a config file, only
# in the per-launch worker environment.
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

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-cache-mode-excl)

# A synthetic pane value a worker launch must override rather than inherit: the
# exclusion is a floor, so a pane that already carries a live cycling value
# still has to start its agent with off. On the secondmate it is the opposite
# probe - this exact value has to survive the launch untouched.
CONTRARY=auto

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<XEOF
$1
XEOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Replace the harness binary with a probe that reports the single environment
# fact under test, so executing the emitted launch answers "what would the agent
# have seen" rather than "what does the command text look like".
install_env_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s\n' "${NEXUS_CACHE_MODE-unset}"
SH
  chmod +x "$1/$2"
}

# Run the emitted launch command in a synthetic pane shell that carries the
# CONTRARY value, with the pane's own pre-launch exports replayed first exactly
# as the real pane shell runs them. This is the whole-pane result.
#   emitted_launch_env <fakebin> <launch-log> <pane-log>
emitted_launch_env() {
  local fakebin=$1 launchlog=$2 panelog=$3 launch preamble
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane NEXUS_CACHE_MODE="$CONTRARY" \
    /bin/sh -c "$preamble
$launch"
}

# The launch command ALONE, for the raw-command case whose agent never reaches
# the pane's pre-launch exports.
#   launch_only_env <fakebin> <launch-log>
launch_only_env() {
  local fakebin=$1 launchlog=$2 launch
  launch=$(cat "$launchlog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane NEXUS_CACHE_MODE="$CONTRARY" \
    /bin/sh -c "$launch"
}

# run_worker_case <name> <kind> <allowlist-setting>
# Drives one ship or scout spawn and leaves the case record in the globals.
run_worker_case() {  # <name> <kind> <allowlist-setting>
  local name=$1 kind=$2 setting=$3 rec out status
  rec=$(make_case "$name" codex "$name-a1")
  read_case "$rec"
  [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
  if [ "$kind" = scout ]; then
    out=$(run_case_spawn "$name-a1" "$PROJ_DIR" --scout)
  else
    out=$(run_case_spawn "$name-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
  fi
  status=$?
  expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
}

test_worker_launch_excludes_cache() {
  local kind setting seen launch
  for kind in ship scout; do
    for setting in absent enabled; do
      run_worker_case "$kind-$setting" "$kind" "$setting"
      if [ "$setting" = enabled ]; then
        launch=$(cat "$LAUNCH_LOG")
        assert_contains "$launch" '/usr/bin/env -i' \
          "an enabled allowlist should launch under a cleared environment"
      fi
      install_env_probe "$FAKEBIN_DIR" codex
      seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
        || fail "$kind, allowlist $setting: the emitted launch failed to run"
      assert_equals off "$seen" \
        "a $kind worker launched with allowlist=$setting and a contrary ambient cache mode must start with NEXUS_CACHE_MODE=off"
    done
  done
  pass "ship and scout launches start their agent with the cache-cycle exclusion on, in both allowlist postures"
}

# A command-prefix assignment only covers the first simple command. A raw
# compound launch such as `cd <dir> && <probe>` must still start the probe with
# the exclusion on, so this drives that escape hatch and executes the pane's
# launch under a contrary ambient value with no preamble.
test_raw_compound_launch_command_carries_the_switch() {
  local rec out status seen probe_dir
  rec=$(make_case raw-compound claude raw-compound-a1)
  read_case "$rec"
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$HOME_DIR/config/crew-dispatch.json"

  probe_dir="$CASE_DIR/agent-cwd"
  mkdir -p "$probe_dir"
  cat > "$probe_dir/probe" <<'SH'
#!/bin/sh
printf '%s\n' "${NEXUS_CACHE_MODE-unset}"
SH
  chmod +x "$probe_dir/probe"

  out=$(run_case_spawn raw-compound-a1 "$PROJ_DIR" --mode no-mistakes --yolo off \
    "cd $probe_dir && ./probe")
  status=$?
  expect_code 0 "$status" "raw compound launch spawn should succeed: $out"
  [ -s "$LAUNCH_LOG" ] || fail "raw compound launch spawn sent no launch command"
  seen=$(launch_only_env "$FAKEBIN_DIR" "$LAUNCH_LOG") \
    || fail "raw compound launch: the emitted launch failed to run"
  assert_equals off "$seen" \
    "a raw compound launch must start its agent with the cache-cycle exclusion on, even after cd"
  pass "a compound raw launch-command still starts its agent with the cache-cycle exclusion on"
}

# make_secondmate_home <case-dir> <id>: the isolated firstmate home a
# --secondmate spawn launches from. Echoes its path.
make_secondmate_home() {
  local sm="$1/secondmate-home" id=$2
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$sm"
}

# A secondmate is a persistent home, not a fanned-out worker, so its launch
# must leave the cache mode exactly as the pane presents it: a live ambient
# value survives into the agent untouched.
test_secondmate_launch_keeps_the_ambient_cache_mode() {
  local rec sm out status seen
  rec=$(make_case secondmate-absent codex sm-absent)
  read_case "$rec"
  sm=$(make_secondmate_home "$CASE_DIR" sm-absent)
  out=$(run_case_spawn sm-absent "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "secondmate: the emitted launch failed to run"
  assert_equals "$CONTRARY" "$seen" \
    "a secondmate must inherit the ambient cache mode rather than be forced out of the cycle"
  pass "a secondmate launch leaves the machine and project cache-mode defaults in force"
}

# Under an enabled allowlist the cleared environment drops every unlisted name,
# and NEXUS_CACHE_MODE is deliberately not on the floor list. A secondmate
# therefore starts with the name absent, which is still the machine default
# rather than the worker exclusion: what it must never be is off.
test_secondmate_launch_under_allowlist_is_not_excluded() {
  local rec sm out status seen
  rec=$(make_case secondmate-enabled codex sm-enabled)
  read_case "$rec"
  sm=$(make_secondmate_home "$CASE_DIR" sm-enabled)
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn sm-enabled "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn under an allowlist should succeed: $out"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "secondmate under an allowlist: the emitted launch failed to run"
  assert_not_equals off "$seen" \
    "a secondmate under an enabled allowlist must not be forced out of the session cycle"
  pass "a secondmate launch under an enabled allowlist is still not excluded from the cycle"
}

# --- relaunch ---------------------------------------------------------------
#
# docs/configuration.md states the guarantee holds on a relaunch as well as a
# fresh spawn. bin/fm-control.sh relaunch stops the agent and rebuilds the
# launch through bin/fm-spawn.sh --relaunch, restoring the kind the gate reads
# from the task's own metadata record, so this drives the operator-facing verb
# rather than the rebuild alone. The stub below models just enough pane
# lifecycle for that transaction: the harness exit command leaves a bare shell
# behind, and the launch literal starts the harness again.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_rebuilds_the_exclusion() {
  local kind dir home proj wt id out status seen launch want
  # secondmate is the iteration that proves the kind actually comes from the
  # task record: bin/fm-spawn.sh falls back to ship on an empty read, so only a
  # kind that must NOT be excluded can detect a broken restore.
  for kind in ship scout secondmate; do
    id="relaunch-$kind-a1"
    dir="$TMP_ROOT/relaunch-$kind"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
    touch "$home/state/.last-watcher-beat"
    make_relaunch_stub "$dir"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$kind"
    fm_test_spawn_brief "$home" "$id"
    : > "$dir/fake/literal"
    : > "$dir/fake/keys"
    printf 'codex' > "$dir/fake/command"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$wt" > "$dir/fake/cwd"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "harness=codex"
      echo "kind=$kind"
      echo "yolo=off"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"
    if [ "$kind" = secondmate ]; then
      # A secondmate relaunches from its own seeded firstmate home, whose
      # durable child records fm-control.sh proves readable before it stops the
      # agent.
      mkdir -p "$wt/state" "$wt/data" "$wt/bin"
      # A secondmate relaunch re-resolves its durable configured harness pin
      # rather than freezing the running one, so pin it to the adapter this
      # case probes.
      printf 'codex\n' > "$home/config/secondmate-harness"
      printf '%s\n' "$id" > "$wt/.fm-secondmate-home"
      printf '# Firstmate\n' > "$wt/AGENTS.md"
      printf 'charter for %s\n' "$id" > "$wt/data/charter.md"
      {
        echo "project=$wt"
        echo "home=$wt"
        echo "mode=secondmate"
      } >> "$home/state/$id.meta"
      want=$CONTRARY
    else
      {
        echo "project=$proj"
        echo "mode=no-mistakes"
        echo "tasktmp=$dir/tasktmp"
      } >> "$home/state/$id.meta"
      want=off
    fi

    mkdir -p "$dir/user-home"
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "$kind relaunch should succeed: $out"

    launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
    [ -n "$launch" ] || fail "$kind relaunch sent no replacement launch command"
    install_env_probe "$dir/fakebin" codex
    seen=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" TERM=xterm \
      TMUX=synthetic-pane NEXUS_CACHE_MODE="$CONTRARY" \
      /bin/sh -c "$launch") \
      || fail "$kind relaunch: the replacement launch failed to run"
    assert_equals "$want" "$seen" \
      "a relaunched $kind must reach its agent with NEXUS_CACHE_MODE=$want, exactly as a fresh spawn of that kind does"
  done
  pass "relaunch rebuilds the cache-cycle exclusion for workers and withholds it from a secondmate, kind restored from the task record"
}

test_worker_launch_excludes_cache
test_raw_compound_launch_command_carries_the_switch
test_secondmate_launch_keeps_the_ambient_cache_mode
test_secondmate_launch_under_allowlist_is_not_excluded
test_relaunch_rebuilds_the_exclusion
