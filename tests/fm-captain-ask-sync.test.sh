#!/usr/bin/env bash
# Behavior tests for the captain-ask sync hook on the backlog done path:
# fm_backlog_done (used by bin/fm-teardown.sh) and `bin/fm-tasks-axi.sh done`
# call the nexus captain-ask bridge with the closed item's id, skip silently
# when the bridge is absent, and never let a failing or hung bridge fail the close.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-ask-sync)
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A bridge stub that records its argv and exits with $BRIDGE_EXIT (default 0).
make_bridge() {  # <dir> -> prints script path
  local dir=$1
  cat > "$dir/bridge.py" <<'PY'
#!/usr/bin/env python3
import os, sys
open(os.environ["BRIDGE_LOG"], "a").write(" ".join(sys.argv[1:]) + "\n")
if os.environ.get("BRIDGE_SLEEP"):
    import time; time.sleep(int(os.environ["BRIDGE_SLEEP"]))
sys.exit(int(os.environ.get("BRIDGE_EXIT", "0")))
PY
  printf '%s\n' "$dir/bridge.py"
}

make_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
  printf '%s\n' "$dir"
}

run_done() {  # <case-dir> <id>; extra env passed through the caller
  local dir=$1 id=$2
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    "$WRAPPER" add "$id" "sync fixture" >/dev/null 2>&1 \
    && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" start "$id" >/dev/null 2>&1; \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "done" "$id" 2>&1)
}

test_sync_called_with_id() {
  local dir out
  dir=$(make_case called)
  export BRIDGE_LOG="$dir/log" FM_CAPTAIN_ASK_BRIDGE
  FM_CAPTAIN_ASK_BRIDGE=$(make_bridge "$dir")
  out=$(run_done "$dir" t-sync1) || fail "done failed: $out"
  assert_grep "sync --backlog-id t-sync1" "$dir/log" "bridge not called with the closed id"
  pass "done calls the bridge with the closed backlog id"
}

test_missing_bridge_is_silent() {
  local dir out
  dir=$(make_case missing)
  export FM_CAPTAIN_ASK_BRIDGE="$dir/nope.py"
  out=$(run_done "$dir" t-sync2) || fail "done failed without bridge: $out"
  case "$out" in *warning*|*captain-ask*) fail "missing bridge was not silent: $out" ;; esac
  pass "a missing bridge is skipped silently"
}

test_failing_bridge_does_not_fail_close() {
  local dir out
  dir=$(make_case failing)
  export BRIDGE_LOG="$dir/log" BRIDGE_EXIT=3 FM_CAPTAIN_ASK_BRIDGE
  FM_CAPTAIN_ASK_BRIDGE=$(make_bridge "$dir")
  out=$(run_done "$dir" t-sync3) || fail "a failing bridge failed the close: $out"
  assert_grep "sync --backlog-id t-sync3" "$dir/log" "bridge was not attempted"
  case "$out" in *"captain-ask sync"*) : ;; *) fail "no warning line on bridge failure: $out" ;; esac
  unset BRIDGE_EXIT
  pass "a failing bridge warns and the close still succeeds"
}

test_hung_bridge_is_bounded() {
  local dir out
  dir=$(make_case hung)
  export BRIDGE_LOG="$dir/log" BRIDGE_SLEEP=30 FM_CAPTAIN_ASK_SYNC_TIMEOUT=1 FM_CAPTAIN_ASK_BRIDGE
  FM_CAPTAIN_ASK_BRIDGE=$(make_bridge "$dir")
  out=$(run_done "$dir" t-sync4) || fail "a hung bridge failed the close: $out"
  unset BRIDGE_SLEEP FM_CAPTAIN_ASK_SYNC_TIMEOUT
  pass "a hung bridge is cut off by the timeout"
}

# The teardown path closes through fm_backlog_done, not the wrapper.
test_teardown_close_path_syncs() {
  local dir
  dir=$(make_case teardown)
  export BRIDGE_LOG="$dir/log" FM_CAPTAIN_ASK_BRIDGE
  FM_CAPTAIN_ASK_BRIDGE=$(make_bridge "$dir")
  run_done "$dir" t-sync5 >/dev/null
  : > "$dir/log"
  tasks-axi add t-sync6 "x" --file "$dir/home/data/backlog.md" >/dev/null 2>&1
  tasks-axi start t-sync6 --file "$dir/home/data/backlog.md" >/dev/null 2>&1
  (
    # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    FM_HOME="$dir/home" fm_backlog_done "$dir/home/data" t-sync6 >/dev/null 2>&1
  )
  assert_grep "sync --backlog-id t-sync6" "$dir/log" "fm_backlog_done did not call the bridge"
  pass "fm_backlog_done (teardown path) calls the bridge"
}

test_sync_called_with_id
test_teardown_close_path_syncs
test_missing_bridge_is_silent
test_failing_bridge_does_not_fail_close
test_hung_bridge_is_bounded
