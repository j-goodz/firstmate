#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-remote-import-approval)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# Setup
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"

# Create parent and remote directories
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"
mkdir -p "$REMOTE_ROOT" "$TMP_ROOT/parent-home" "$TMP_ROOT/remote-user-home"
git init -q --bare "$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$TMP_ROOT/alpha.git"

# Copy repo to remote root
(cd "$ROOT" && tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .) | (cd "$REMOTE_ROOT" && tar -xf -)
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -q -m "Initial commit"
git -C "$REMOTE_ROOT" branch -M main
git -C "$REMOTE_ROOT" remote add origin "file://$TMP_ROOT/firstmate-origin.git"
git -C "$REMOTE_ROOT" push -q -u origin main
git -C "$TMP_ROOT/firstmate-origin.git" symbolic-ref HEAD refs/heads/main

# Create project alpha
git init -q -b main "$PARENT/projects/alpha"
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -q -m "Initial commit"
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
git -C "$TMP_ROOT/alpha.git" symbolic-ref HEAD refs/heads/main

printf -- '- alpha [direct-PR] - alpha project (added 2026-08-04)\n' > "$PARENT/data/projects.md"
printf 'tmux\n' > "$PARENT/config/backend"

# Create fake ssh
cat > "$FAKEBIN/fake-ssh" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF2
$command_fields
EOF2
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
EOF
chmod +x "$FAKEBIN/fake-ssh"

# Helper functions
seed_remote() {
  local id="$1"
  local remote_home="$2"
  local parent_claude_config_dir="$3"
  FM_SECONDMATE_CHARTER='Own alpha delivery.' FM_SECONDMATE_SCOPE='alpha work' \
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  CLAUDE_CONFIG_DIR="$parent_claude_config_dir" HOME="$TMP_ROOT/parent-home" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$ROOT/bin/fm-remote-home-seed.sh" "$id" remote-mac "$REMOTE_ROOT" "$remote_home" alpha >/dev/null 2>&1
}

remote_worktree() {
  local remote_home="$1"
  local name="$2"
  git -C "$remote_home/projects/alpha" config user.email test@example.com
  git -C "$remote_home/projects/alpha" config user.name Test
  git -C "$remote_home/projects/alpha" worktree add -q -b "wt-$name" "$remote_home/wt-$name"
  echo "$remote_home/wt-$name"
}

run_trust() {
  local remote_home="$1"
  local remote_claude_config_dir="$2"
  local worktree="$3"
  OUT=$(FM_CLAUDE_IMPORT_APPROVALS="$remote_home/config/claude-import-approvals" \
    CLAUDE_CONFIG_DIR="$remote_claude_config_dir" HOME="$TMP_ROOT/remote-user-home" \
    "$ROOT/bin/fm-claude-trust.sh" "$worktree" "$remote_home/projects/alpha" 2>&1)
  local rc=$?
  echo "$OUT"
  return "$rc"
}

flag() {
  local store="$1"
  local path="$2"
  local flag="$3"
  if command -v node >/dev/null 2>&1; then
    node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync('$store'));console.log(data.projects['$path']?.['$flag'] ?? null);"
  else
    jq -r --arg path "$path" --arg flag "$flag" '.[$path][$flag] // null' "$store"
  fi
}

assert_flag_true() {
  local store="$1"
  local path="$2"
  local flag="$3"
  local msg="$4"
  local value
  value=$(flag "$store" "$path" "$flag")
  if [ "$value" != "true" ]; then
    fail "$msg: expected $flag to be true, got $value"
  fi
}

assert_not_true() {
  local store="$1"
  local path="$2"
  local flag="$3"
  local msg="$4"
  local value
  value=$(flag "$store" "$path" "$flag")
  if [ "$value" = "true" ]; then
    fail "$msg: expected $flag to not be true, got $value"
  fi
}

# Test cases
parent_approval_is_inherited_by_the_remote_clone() {
  local case_dir="$TMP_ROOT/A"
  local remote_home="$case_dir/remote-home"
  local parent_claude="$case_dir/parent-claude"
  mkdir -p "$case_dir" "$parent_claude"

  # Set up parent approval
  local parent_alpha_path="$PARENT/projects/alpha"
  cat > "$parent_claude/.claude.json" <<EOF
{
  "projects": {
    "$parent_alpha_path": {
      "hasTrustDialogAccepted": true,
      "hasClaudeMdExternalIncludesApproved": true,
      "hasClaudeMdExternalIncludesWarningShown": true
    }
  }
}
EOF

  # Seed remote home
  seed_remote imp-approved "$remote_home" "$parent_claude"
  expect_code 0 $? "seed should succeed"

  # Check approvals file
  local approvals_file="$remote_home/config/claude-import-approvals"
  assert_present "$approvals_file" "approvals file should exist"
  local expected_path="$remote_home/projects/alpha"
  assert_contains "$(cat "$approvals_file")" "$expected_path" "approvals file should contain project path"

  # Create worktree and run trust
  local wt
  wt=$(remote_worktree "$remote_home" "A")
  local remote_claude="$case_dir/remote-claude"
  mkdir -p "$remote_claude"
  run_trust "$remote_home" "$remote_claude" "$wt"
  expect_code 0 $? "trust should succeed"

  # Verify flags
  local store="$remote_claude/.claude.json"
  assert_flag_true "$store" "$expected_path" "hasTrustDialogAccepted" "project should have trust accepted"
  assert_flag_true "$store" "$expected_path" "hasClaudeMdExternalIncludesApproved" "project should have imports approved"
  assert_flag_true "$store" "$expected_path" "hasClaudeMdExternalIncludesWarningShown" "project should have warning shown"
  assert_flag_true "$store" "$wt" "hasTrustDialogAccepted" "worktree should have trust accepted"
  assert_flag_true "$store" "$wt" "hasClaudeMdExternalIncludesApproved" "worktree should have imports approved"
  assert_flag_true "$store" "$wt" "hasClaudeMdExternalIncludesWarningShown" "worktree should have warning shown"

  pass "parent approval is inherited by remote clone"
}

no_parent_approval_means_no_remote_approval() {
  local case_dir="$TMP_ROOT/B"
  local remote_home="$case_dir/remote-home"
  local parent_claude="$case_dir/parent-claude"
  mkdir -p "$case_dir" "$parent_claude"

  # Set up empty parent store
  cat > "$parent_claude/.claude.json" <<EOF
{
  "projects": {}
}
EOF

  # Seed remote home
  seed_remote imp-none "$remote_home" "$parent_claude"
  expect_code 0 $? "seed should succeed"

  # Check approvals file
  local approvals_file="$remote_home/config/claude-import-approvals"
  assert_present "$approvals_file" "approvals file should exist"
  local expected_path="$remote_home/projects/alpha"
  if grep -q "$expected_path" "$approvals_file"; then
    fail "approvals file should not contain project path"
  fi

  # Create worktree and run trust
  local wt
  wt=$(remote_worktree "$remote_home" "B")
  local remote_claude="$case_dir/remote-claude"
  mkdir -p "$remote_claude"
  run_trust "$remote_home" "$remote_claude" "$wt"
  expect_code 0 $? "trust should succeed"

  # Verify flags
  local store="$remote_claude/.claude.json"
  assert_flag_true "$store" "$expected_path" "hasTrustDialogAccepted" "project should have trust accepted"
  assert_not_true "$store" "$expected_path" "hasClaudeMdExternalIncludesApproved" "project should not have imports approved"

  pass "no parent approval means no remote approval"
}

parent_decline_is_not_inherited() {
  local case_dir="$TMP_ROOT/C"
  local remote_home="$case_dir/remote-home"
  local parent_claude="$case_dir/parent-claude"
  mkdir -p "$case_dir" "$parent_claude"

  # Set up parent decline
  local parent_alpha_path="$PARENT/projects/alpha"
  cat > "$parent_claude/.claude.json" <<EOF
{
  "projects": {
    "$parent_alpha_path": {
      "hasTrustDialogAccepted": false,
      "hasClaudeMdExternalIncludesApproved": false,
      "hasClaudeMdExternalIncludesWarningShown": true
    }
  }
}
EOF

  # Seed remote home
  seed_remote imp-decline "$remote_home" "$parent_claude"
  expect_code 0 $? "seed should succeed"

  # Check approvals file
  local approvals_file="$remote_home/config/claude-import-approvals"
  assert_present "$approvals_file" "approvals file should exist"
  if [ -s "$approvals_file" ]; then
    fail "approvals file should be empty"
  fi

  # Create worktree and run trust
  local wt
  wt=$(remote_worktree "$remote_home" "C")
  local remote_claude="$case_dir/remote-claude"
  mkdir -p "$remote_claude"
  run_trust "$remote_home" "$remote_claude" "$wt"
  expect_code 0 $? "trust should succeed"

  # Verify flags
  local store="$remote_claude/.claude.json"
  local expected_path="$remote_home/projects/alpha"
  assert_not_true "$store" "$expected_path" "hasClaudeMdExternalIncludesApproved" "project should not have imports approved"

  pass "parent decline is not inherited"
}

approval_for_a_different_origin_is_not_inherited() {
  local case_dir="$TMP_ROOT/D"
  local remote_home="$case_dir/remote-home"
  local parent_claude="$case_dir/parent-claude"
  mkdir -p "$case_dir" "$parent_claude"

  # Create other project
  git init -q -b main "$PARENT/projects/other"
  git -C "$PARENT/projects/other" config user.email test@example.com
  git -C "$PARENT/projects/other" config user.name Test
  git -C "$PARENT/projects/other" remote add origin "file://$TMP_ROOT/other.git"

  # Set up parent approval for other project
  local parent_other_path="$PARENT/projects/other"
  cat > "$parent_claude/.claude.json" <<EOF
{
  "projects": {
    "$parent_other_path": {
      "hasTrustDialogAccepted": true,
      "hasClaudeMdExternalIncludesApproved": true,
      "hasClaudeMdExternalIncludesWarningShown": true
    }
  }
}
EOF

  # Seed remote home
  seed_remote imp-other "$remote_home" "$parent_claude"
  expect_code 0 $? "seed should succeed"

  # Check approvals file
  local approvals_file="$remote_home/config/claude-import-approvals"
  assert_present "$approvals_file" "approvals file should exist"
  if [ -s "$approvals_file" ]; then
    fail "approvals file should be empty"
  fi

  pass "approval for a different origin is not inherited"
}

re_provision_rewrites_the_record() {
  local case_dir="$TMP_ROOT/E"
  local remote_home="$case_dir/remote-home"
  local parent_claude="$case_dir/parent-claude"
  mkdir -p "$case_dir" "$parent_claude"

  # First seed with approval
  local parent_alpha_path="$PARENT/projects/alpha"
  cat > "$parent_claude/.claude.json" <<EOF
{
  "projects": {
    "$parent_alpha_path": {
      "hasTrustDialogAccepted": true,
      "hasClaudeMdExternalIncludesApproved": true,
      "hasClaudeMdExternalIncludesWarningShown": true
    }
  }
}
EOF
  seed_remote imp-rewrite "$remote_home" "$parent_claude"
  expect_code 0 $? "first seed should succeed"

  # Verify initial approval
  local approvals_file="$remote_home/config/claude-import-approvals"
  local expected_path="$remote_home/projects/alpha"
  assert_contains "$(cat "$approvals_file")" "$expected_path" "initial approval should be present"

  # Second seed with no approval
  cat > "$parent_claude/.claude.json" <<EOF
{
  "projects": {}
}
EOF
  seed_remote imp-rewrite "$remote_home" "$parent_claude"
  expect_code 0 $? "second seed should succeed"

  # Verify approval is removed
  if grep -q "$expected_path" "$approvals_file"; then
    fail "approval should be removed after second seed"
  fi

  pass "re-provision rewrites the record"
}

# Run tests
parent_approval_is_inherited_by_the_remote_clone
no_parent_approval_means_no_remote_approval
parent_decline_is_not_inherited
approval_for_a_different_origin_is_not_inherited
re_provision_rewrites_the_record
