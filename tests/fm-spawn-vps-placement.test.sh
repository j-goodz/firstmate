#!/usr/bin/env bash
#
# fm-spawn-vps-placement.test.sh
#
# Tests for VPS placement logic in fm-spawn.
#
# The tests exercise the behaviour of the spawn script when it is run on
# different hosts (cloud‑server, swift, zentop) and with/without the
# FM_VPS_HEAVY_OK override.
#
# The style follows that of tests/fm-spawn-thermal-gate.test.sh.
#
set -u

# shellcheck source=./fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-vps-placement)

# ----------------------------------------------------------------------
# Helpers (copied from the thermal‑gate test, without the sysfs bits)
# ----------------------------------------------------------------------
make_case() {
  local case_dir id
  id="$1"
  case_dir=$(mktemp -d "$TMP_ROOT/case-XXXX")

  # Create a fake home (with the harness) and a fake project/worktree.
  fm_test_spawn_home "$case_dir/home" "codex"
  fm_git_worktree "$case_dir/proj" "$case_dir/wt" "wt-$id"

  # Create a brief for the given task id.
  fm_test_spawn_brief "$case_dir/home" "$id"

  # Create a fake bin directory that the spawn script will use.
  fm_test_make_spawn_fakebin "$case_dir/fakebin" > /dev/null

  echo "$case_dir"
}

read_case() {
  CASE_DIR="$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/proj"
  WT_DIR="$CASE_DIR/wt"
  FAKEBIN_DIR="$CASE_DIR/fakebin/fakebin"
  LAUNCH_LOG="$CASE_DIR/launch.log"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# ----------------------------------------------------------------------
# Test cases
# ----------------------------------------------------------------------
vps_ship_refused() {
  local case_dir id out rc
  id="vps-ship-a1"
  case_dir=$(make_case "$id")
  read_case "$case_dir"

  out=$(FM_SELF_HOST=cloud-server run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 1 "$rc" "ship spawn should be refused on cloud‑server without override"
  assert_contains "$out" "cloud-server" "output should mention host name"
  assert_contains "$out" "swift" "output should mention swift (placement target)"
  assert_contains "$out" "bin/fm-place.sh --class heavy" "output should mention heavy placement command"
  assert_contains "$out" "FM_VPS_HEAVY_OK=OPERATOR_APPROVED" "output should mention the required env var"

  if [[ -f "$HOME_DIR/state/${id}.meta" ]]; then
    fail "state file $HOME_DIR/state/${id}.meta should not exist after refusal"
  else
    pass "state file correctly absent after refusal"
  fi

  pass "vps_ship_refused"
}

vps_scout_allowed() {
  local case_dir id out rc
  id="vps-scout-a1"
  case_dir=$(make_case "$id")
  read_case "$case_dir"

  out=$(FM_SELF_HOST=cloud-server run_case_spawn "$id" "$PROJ_DIR" --scout 2>&1)
  rc=$?
  expect_code 0 "$rc" "scout spawn should be allowed on cloud‑server"
  assert_contains "$out" "spawned $id" "output should contain spawned message"

  pass "vps_scout_allowed"
}

swift_ship_allowed() {
  local case_dir id out rc
  id="swift-ship-a1"
  case_dir=$(make_case "$id")
  read_case "$case_dir"

  out=$(FM_SELF_HOST=swift run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 0 "$rc" "ship spawn should be allowed on swift"
  assert_contains "$out" "spawned $id" "output should contain spawned message"

  pass "swift_ship_allowed"
}

zentop_ship_allowed() {
  local case_dir id out rc
  id="zentop-ship-a1"
  case_dir=$(make_case "$id")
  read_case "$case_dir"

  out=$(FM_SELF_HOST=zentop run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 0 "$rc" "ship spawn should be allowed on zentop"
  assert_contains "$out" "spawned $id" "output should contain spawned message"

  pass "zentop_ship_allowed"
}

vps_override_allows() {
  local case_dir id out rc
  id="vps-override-a1"
  case_dir=$(make_case "$id")
  read_case "$case_dir"

  out=$(FM_SELF_HOST=cloud-server FM_VPS_HEAVY_OK=OPERATOR_APPROVED \
        run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 0 "$rc" "ship spawn should be allowed on cloud‑server with override"
  assert_contains "$out" "spawned $id" "output should contain spawned message"

  pass "vps_override_allows"
}

vps_wrong_token_refused() {
  local case_dir id out rc
  id="vps-wrong-token-a1"
  case_dir=$(make_case "$id")
  read_case "$case_dir"

  out=$(FM_SELF_HOST=cloud-server FM_VPS_HEAVY_OK=yes \
        run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 1 "$rc" "ship spawn should be refused when FM_VPS_HEAVY_OK has wrong token"
  pass "vps_wrong_token_refused"
}

spawn_help_documents_override() {
  local out rc
  out=$("$ROOT/bin/fm-spawn.sh" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "fm-spawn --help should exit zero"
  assert_contains "$out" "FM_VPS_HEAVY_OK" "help should document FM_VPS_HEAVY_OK"
  assert_contains "$out" "OPERATOR_APPROVED" "help should document the approved token"
  pass "spawn_help_documents_override"
}

brief_caps_fanout_width_on_vps() {
  local home brief_dir out rc

  # --- VPS (cloud‑server) case: should get --workers 2
  home="$TMP_ROOT/brief-vps"
  mkdir -p "$home/data"
  out=$(
    FM_SELF_HOST=cloud-server FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" vps-brief-a1 some-proj --mode direct-PR 2>&1
  )
  rc=$?
  expect_code 0 "$rc" "fm-brief should succeed on VPS"
  brief_dir="$home/data/vps-brief-a1"
  if [[ ! -f "$brief_dir/brief.md" ]]; then
    fail "brief markdown not generated at $brief_dir/brief.md"
  fi
  if grep -q -- '--workers 2' "$brief_dir/brief.md"; then
    pass "VPS brief contains --workers 2"
  else
    fail "VPS brief missing '--workers 2'"
  fi

  # --- Swift case: must NOT contain --workers 2
  home="$TMP_ROOT/brief-swift"
  mkdir -p "$home/data"
  out=$(
    FM_SELF_HOST=swift FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" swift-brief-a1 some-proj --mode direct-PR 2>&1
  )
  rc=$?
  expect_code 0 "$rc" "fm-brief should succeed on swift"
  brief_dir="$home/data/swift-brief-a1"
  if [[ ! -f "$brief_dir/brief.md" ]]; then
    fail "brief markdown not generated at $brief_dir/brief.md"
  fi
  if grep -q -- '--workers 2' "$brief_dir/brief.md"; then
    fail "Swift brief should NOT contain '--workers 2'"
  else
    pass "Swift brief correctly omits --workers 2"
  fi

  pass "brief_caps_fanout_width_on_vps"
}

# ----------------------------------------------------------------------
# Run all tests
# ----------------------------------------------------------------------
vps_ship_refused
vps_scout_allowed
swift_ship_allowed
zentop_ship_allowed
vps_override_allows
vps_wrong_token_refused
spawn_help_documents_override
brief_caps_fanout_width_on_vps

exit 0