#!/usr/bin/env bash
# tests/fm-spawn-opencode-provider.test.sh - an opencode launch must start with
# the provider keys its model needs, and must refuse rather than silently fall
# back when the provider is unavailable in the launch environment.
#
# A lane pane loads the operator's ~/.env.<service> provider keys because its
# shell is interactive; the remote second-mate path never runs an interactive
# shell, so opencode there treats a requested provider as unknown and dies on an
# invalid key. fm-spawn now resolves the fleet's with-keys loader, wraps the
# opencode launch in it, and preflights `opencode models <provider>` in that same
# environment before starting the agent. These tests drive the real spawn with a
# stubbed opencode and with-keys, then read back both the refusal and the launch
# command the pane received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-spawn-opencode-provider)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# --- local spawn path -------------------------------------------------------

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
  make_opencode_stub "$fakebin"
  fm_test_spawn_home "$home" opencode
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

# overwrite the shared exit-0 opencode with one whose provider probe is
# controllable, so the same fixture proves both the refusal and the success.
make_opencode_stub() { # <fakebin>
  cat > "$1/opencode" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = models ]; then
  if [ -n "${FM_FAKE_OPENCODE_PROVIDER_OK:-}" ]; then
    printf '%s\n' "${2:-}/some-model"
    exit 0
  fi
  printf 'Provider not found: %s\n' "${2:-}" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$1/opencode"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

make_seeded_secondmate_home() { # <home> <id>
  mkdir -p "$1/bin" "$1/data"
  printf '# Firstmate\n' > "$1/AGENTS.md"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf 'charter for %s\n' "$2" > "$1/data/charter.md"
}

run_case() { # <home> <wt> <fakebin> <launchlog> [spawn-args...]
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is pinned empty so the claude launch prefix never leaks the
  # developer's store; opencode ignores it.
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

test_unavailable_provider_refuses_before_launch() {
  local rec id out status
  id=oc-provider-missing-z1
  rec=$(make_case "$id")
  read_case_record "$rec"

  out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an opencode spawn on an unavailable provider must refuse"
  assert_contains "$out" "Provider not found: deepseek" \
    "the refusal must surface the provider probe's own message"
  assert_contains "$out" "provider 'deepseek' is not available" \
    "the refusal must name the unavailable provider"
  [ -s "$LAUNCH_LOG" ] && fail "a refused opencode spawn must not deliver a launch command"
  pass "an opencode spawn refuses when the requested provider is unavailable"
}

test_available_provider_launches_under_the_key_loader() {
  local rec id out status launch
  id=oc-provider-ok-z2
  rec=$(make_case "$id")
  read_case_record "$rec"

  out=$(FM_FAKE_OPENCODE_PROVIDER_OK=1 \
    run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an opencode spawn on an available provider should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "with-keys' opencode -- opencode --model 'deepseek/deepseek-flash'" \
    "the opencode launch must run under with-keys with the provider's service file"
  assert_contains "$launch" "OPENCODE_CONFIG_CONTENT=" \
    "the with-keys wrapper must keep opencode's config content prefix"
  pass "an opencode spawn on an available provider launches through the key loader"
}

test_providerless_opencode_launch_still_loads_a_base_service() {
  local rec id out status launch
  id=oc-provider-none-z3
  rec=$(make_case "$id")
  read_case_record "$rec"

  # No --model: opencode falls back to its configured default provider, so the
  # launch must still load a base key set rather than starting bare.
  out=$(FM_FAKE_OPENCODE_PROVIDER_OK=1 \
    run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an opencode spawn without a model should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "with-keys' opencode freellmapi -- opencode" \
    "a providerless opencode launch must load the base service set"
  pass "a providerless opencode launch loads the base provider services"
}

test_local_secondmate_opencode_launch_uses_the_key_loader() {
  local rec id out status launch
  id=oc-sm-provider-z4
  rec=$(make_case "$id")
  read_case_record "$rec"
  make_seeded_secondmate_home "$CASE_DIR/secondmate-home" "$id"

  out=$(FM_FAKE_OPENCODE_PROVIDER_OK=1 \
    run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$CASE_DIR/secondmate-home" --secondmate --model deepseek/deepseek-flash 2>&1)
  status=$?
  expect_code 0 "$status" "a local opencode second-mate spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "with-keys' opencode -- opencode --model 'deepseek/deepseek-flash'" \
    "a local opencode second-mate launch must run under the key loader"
  pass "a local opencode second mate launches through the key loader"
}

# Write <home>/user-home/.config/opencode/opencode.json (the config the launched
# process resolves) and seed the named provider key files as empty placeholders.
write_opencode_json() { # <home> <json>
  mkdir -p "$1/user-home/.config/opencode"
  printf '%s\n' "$2" > "$1/user-home/.config/opencode/opencode.json"
}
seed_key_file() { # <home> <service>
  : > "$1/user-home/.env.$2"
}

test_small_model_provider_key_is_loaded_alongside_requested() {
  local rec id out status launch
  id=oc-secondary-small-z5
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_opencode_json "$HOME_DIR" '{"model":"freellm/auto","small_model":"freellm/auto"}'
  seed_key_file "$HOME_DIR" opencode
  seed_key_file "$HOME_DIR" freellmapi

  out=$(FM_FAKE_OPENCODE_PROVIDER_OK=1 \
    run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an opencode spawn with a secondary small_model provider should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "with-keys' opencode freellmapi -- opencode --model 'deepseek/deepseek-flash'" \
    "the launch must load the requested provider and the small_model provider in one with-keys call"
  pass "an opencode spawn loads the small_model provider's key file too"
}

test_small_model_provider_equal_to_requested_is_not_duplicated() {
  local rec id out status launch
  id=oc-secondary-dup-z6
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_opencode_json "$HOME_DIR" '{"small_model":"deepseek/deepseek-chat"}'
  seed_key_file "$HOME_DIR" opencode

  out=$(FM_FAKE_OPENCODE_PROVIDER_OK=1 \
    run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an opencode spawn whose small_model shares the requested provider should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "with-keys' opencode -- opencode --model 'deepseek/deepseek-flash'" \
    "a small_model on the requested provider must not add a duplicate service"
  assert_not_contains "$launch" "with-keys' opencode opencode" \
    "the requested provider's service must appear only once"
  pass "an opencode spawn does not duplicate the requested provider's service"
}

test_missing_secondary_key_warns_and_still_launches() {
  local rec id out status launch
  id=oc-secondary-missing-z7
  rec=$(make_case "$id")
  read_case_record "$rec"
  write_opencode_json "$HOME_DIR" '{"small_model":"freellm/auto"}'
  seed_key_file "$HOME_DIR" opencode

  out=$(FM_FAKE_OPENCODE_PROVIDER_OK=1 \
    run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "a missing secondary key must not refuse the launch: $out"
  assert_contains "$out" "warning:" "a missing secondary key must warn"
  assert_contains "$out" "freellmapi" "the warning must name the missing service"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "with-keys' opencode -- opencode --model 'deepseek/deepseek-flash'" \
    "the launch must still run with the requested provider's key"
  assert_not_contains "$launch" "freellmapi" \
    "a service whose key file is missing must be dropped from the wrap"
  pass "a missing secondary key warns and launches without it"
}

test_missing_primary_key_still_refuses() {
  local rec id out status
  id=oc-primary-missing-z8
  rec=$(make_case "$id")
  read_case_record "$rec"
  # A real with-keys refuses when any named ~/.env.<service> is absent; the shared
  # fixture stub skips service names, so install the faithful one for this case.
  cat > "$FAKEBIN_DIR/with-keys" <<'SH'
#!/usr/bin/env bash
set -u
services=()
while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do services+=("$1"); shift; done
[ "${1:-}" = "--" ] || { echo "with-keys: missing -- before the command" >&2; exit 2; }
shift
for s in ${services[@]+"${services[@]}"}; do
  [ -f "$HOME/.env.$s" ] || { echo "with-keys: no $HOME/.env.$s" >&2; exit 2; }
done
exec "$@"
SH
  chmod +x "$FAKEBIN_DIR/with-keys"
  # deepseek's key file (~/.env.opencode) is absent, so the requested provider
  # cannot be authenticated even though the probe stub would answer.
  out=$(FM_FAKE_OPENCODE_PROVIDER_OK=1 \
    run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing primary key must still refuse the launch"
  assert_contains "$out" "provider 'deepseek' is not available" \
    "the refusal must name the requested provider"
  assert_contains "$out" "with-keys: no " "the refusal must surface the missing key file"
  [ -s "$LAUNCH_LOG" ] && fail "a refused spawn must not deliver a launch command"
  pass "a missing primary key still refuses the launch"
}

test_opencode_config_content_small_model_wins_over_file() {
  local rec id out status launch
  id=oc-content-precedence-z9
  rec=$(make_case "$id")
  read_case_record "$rec"
  # The file points small_model at the requested provider (no extra service); the
  # inline config points it at the free chain, whose service must therefore load.
  write_opencode_json "$HOME_DIR" '{"small_model":"deepseek/deepseek-chat"}'
  seed_key_file "$HOME_DIR" opencode
  seed_key_file "$HOME_DIR" freellmapi

  out=$(OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"},"small_model":"freellm/auto"}' \
    FM_FAKE_OPENCODE_PROVIDER_OK=1 \
    run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model deepseek/deepseek-flash --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an opencode spawn with inline config should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "with-keys' opencode freellmapi -- opencode --model 'deepseek/deepseek-flash'" \
    "OPENCODE_CONFIG_CONTENT's small_model must win over the file's"
  pass "OPENCODE_CONFIG_CONTENT's small_model wins over the file"
}

test_unavailable_provider_refuses_before_launch
test_available_provider_launches_under_the_key_loader
test_providerless_opencode_launch_still_loads_a_base_service
test_local_secondmate_opencode_launch_uses_the_key_loader
test_small_model_provider_key_is_loaded_alongside_requested
test_small_model_provider_equal_to_requested_is_not_duplicated
test_missing_secondary_key_warns_and_still_launches
test_missing_primary_key_still_refuses
test_opencode_config_content_small_model_wins_over_file

# --- remote second-mate path ------------------------------------------------

PARENT="$TMP_ROOT/remote/parent"
REMOTE_ROOT="$TMP_ROOT/remote/root"
REMOTE_HOME="$TMP_ROOT/remote/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/remote/fake")
PROBEBIN="$TMP_ROOT/remote/probebin"
HERDR_LOG="$TMP_ROOT/remote/herdr.log"
HERDR_STATE="$TMP_ROOT/remote/herdr.state"
CLAIMS="$TMP_ROOT/remote/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" \
  "$REMOTE_ROOT" "$CLAIMS" "$PROBEBIN"

cleanup_remote() {
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote/jobs/worker.pid" ]; then
    kill "$(cat "$TMP_ROOT/remote/jobs/worker.pid")" 2>/dev/null || true
  fi
}
trap 'cleanup_remote; rm -rf -- "$TMP_ROOT"' EXIT

(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)

# The remote pane's key loader and harness resolve to stubs through the remote
# child PATH, whose first entry is the remote code root's bin. with-keys execs
# what it wraps; opencode answers any provider probe with success.
cat > "$REMOTE_ROOT/bin/with-keys" <<'SH'
#!/usr/bin/env bash
while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do shift; done
[ "$#" -gt 0 ] && shift
exec "$@"
SH
cat > "$REMOTE_ROOT/bin/opencode" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/with-keys" "$REMOTE_ROOT/bin/opencode"

cat > "$REMOTE_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/remote/herdr-send-fail" "$TMP_ROOT/remote/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
if printf '%s' "$4" | base64 --decode 2>/dev/null | tr '\0' '\n' | head -1 | grep -q '^fm-remote-doctor.sh$'; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'opencode deepseek/deepseek-flash\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'opencode\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"
printf '%s\n' "$$" > "$PARENT/state/.lock"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote/jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

remote_pane_payload() {  # <verb>
  sed -n "s/^pane $1 [^ ]* \\(.*\\) --session [^ ]*\$/\\1/p" "$HERDR_LOG"
}
remote_launch_command() {
  local source_line staged
  source_line=$(remote_pane_payload send-text | grep "^\. '.*'\$" | tail -1)
  staged=${source_line#". '"}
  staged=${staged%"'"}
  [ -n "$staged" ] && [ -f "$staged" ] || return 1
  cat "$staged"
}

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route under test"

reset_remote_herdr_fixture "$HERDR_STATE"
: > "$HERDR_LOG"
remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1 \
  || fail "the remote opencode second-mate launch failed"

LAUNCH=$(remote_launch_command) || fail "the remote pane received no launch command"
# The remote launch composes on the remote host and reads that account's own
# opencode config, so its secondary service list is host-dependent; assert the
# loader wraps the requested provider and keeps the requested model.
assert_contains "$LAUNCH" "with-keys' opencode" \
  "the remote second-mate launch must run under the key loader with the requested provider's service file"
assert_contains "$LAUNCH" "-- opencode --model 'deepseek/deepseek-flash'" \
  "the remote second-mate launch must keep the requested model"
pass "a remote opencode second mate launches through the key loader on the remote host"

echo "# all fm-spawn-opencode-provider tests passed"
