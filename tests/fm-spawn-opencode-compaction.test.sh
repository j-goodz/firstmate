#!/usr/bin/env bash
# tests/fm-spawn-opencode-compaction.test.sh - the opt-in
# config/opencode-compaction setting must merge opencode's documented compaction
# options into an opencode launch's OPENCODE_CONFIG_CONTENT, leave the launch
# unchanged when absent, record opencode_compaction=on in the lane's meta when
# active, and refuse a malformed file with a clear error before any launch.
#
# These tests drive the real spawn with the shared fakebin stubs (exit-0
# opencode, pass-through with-keys), then read back the launch command the pane
# received and the task meta.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-spawn-opencode-compaction)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

RECOMMENDED='{"auto":true,"prune":true,"tail_turns":15,"preserve_recent_tokens":60000,"reserved":20000}'

make_case() { # <name>
  local name=$1 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  fm_test_spawn_home "$home" opencode
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_case() { # <home> <wt> <fakebin> <launchlog> [spawn-args...]
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

write_compaction() { # <home> <content>
  printf '%s\n' "$2" > "$1/config/opencode-compaction"
}

test_absent_setting_leaves_launch_unchanged() {
  local rec id out status launch
  id=oc-compaction-off-a1
  rec=$(make_case "$id")
  read_case_record "$rec"

  out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an opencode spawn without the setting should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}'" \
    "an unconfigured opencode launch must carry exactly the base config content"
  assert_not_contains "$launch" '"compaction"' \
    "an unconfigured opencode launch must not carry any compaction block"
  assert_no_grep "opencode_compaction=" "$HOME_DIR/state/$id.meta" \
    "a lane without the setting must not record opencode_compaction"
  pass "an absent opencode-compaction setting leaves the launch unchanged"
}

test_recommended_setting_lands_in_the_launch_config() {
  local rec id out status launch
  id=oc-compaction-on-a2
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_compaction "$HOME_DIR" "$RECOMMENDED"

  out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an opencode spawn with the setting should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '"prune":true' \
    "the launch config must enable tool-output pruning"
  assert_contains "$launch" '"preserve_recent_tokens":60000' \
    "the launch config must keep the recent-turn token budget"
  assert_contains "$launch" '"tail_turns":15' \
    "the launch config must bound the verbatim recent turns"
  assert_contains "$launch" '"permission":{"*":"allow"}' \
    "the launch config must keep the permission allow block beside compaction"
  assert_grep "opencode_compaction=on" "$HOME_DIR/state/$id.meta" \
    "an opencode lane with the setting on must record opencode_compaction=on"
  pass "the opt-in compaction setting lands in the opencode launch config"
}

test_partial_object_merges_only_its_keys() {
  local rec id out status launch
  id=oc-compaction-partial-a3
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_compaction "$HOME_DIR" '{"prune":true}'

  out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an opencode spawn with a partial object should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '"compaction":{"prune":true}' \
    "a partial object must merge exactly its own keys"
  pass "a partial compaction object merges only its keys"
}

test_malformed_json_refuses() {
  local rec id out status
  id=oc-compaction-badjson-a4
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_compaction "$HOME_DIR" '{not json'

  out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed opencode-compaction file must refuse the spawn"
  assert_contains "$out" "config/opencode-compaction is not valid JSON" \
    "the refusal must name the invalid JSON"
  [ -s "$LAUNCH_LOG" ] && fail "a refused spawn must not deliver a launch command"
  pass "malformed JSON refuses the spawn with a clear error"
}

test_unknown_key_refuses() {
  local rec id out status
  id=oc-compaction-unknown-a5
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_compaction "$HOME_DIR" '{"bogus":1}'

  out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown opencode-compaction key must refuse the spawn"
  assert_contains "$out" "unknown key(s): bogus" \
    "the refusal must name the unknown key"
  [ -s "$LAUNCH_LOG" ] && fail "a refused spawn must not deliver a launch command"
  pass "an unknown compaction key refuses the spawn with a clear error"
}

test_wrong_type_refuses() {
  local rec id out status
  id=oc-compaction-type-a6
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_compaction "$HOME_DIR" '{"tail_turns":"many"}'

  out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an invalid opencode-compaction value must refuse the spawn"
  assert_contains "$out" "values are invalid" \
    "the refusal must name the invalid value shape"
  [ -s "$LAUNCH_LOG" ] && fail "a refused spawn must not deliver a launch command"
  pass "an invalid compaction value refuses the spawn with a clear error"
}

test_empty_object_refuses() {
  local rec id out status
  id=oc-compaction-empty-a7
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_compaction "$HOME_DIR" '{}'

  out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an empty opencode-compaction object must refuse the spawn"
  assert_contains "$out" "at least one option is required" \
    "the refusal must say an empty object changes nothing"
  [ -s "$LAUNCH_LOG" ] && fail "a refused spawn must not deliver a launch command"
  pass "an empty compaction object refuses the spawn with a clear error"
}

test_absent_setting_leaves_launch_unchanged
test_recommended_setting_lands_in_the_launch_config
test_partial_object_merges_only_its_keys
test_malformed_json_refuses
test_unknown_key_refuses
test_wrong_type_refuses
test_empty_object_refuses

echo "# all fm-spawn-opencode-compaction tests passed"
