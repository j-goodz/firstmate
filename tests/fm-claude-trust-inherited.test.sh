#!/usr/bin/env bash
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-claude-trust-inherited)
TRUST="$ROOT/bin/fm-claude-trust.sh"

make_case() {
  local name="$1"
  CASE_DIR="$TMP_ROOT/$name"
  PROJ="$CASE_DIR/project"
  WT="$CASE_DIR/wt"
  CONFIG="$CASE_DIR/claude-config"
  mkdir -p "$CONFIG"
  fm_git_worktree "$PROJ" "$WT" "wt-$name"
}

run_trust() {
  local approvals="$1"
  mkdir -p "$CASE_DIR/home"
  if [ -z "$approvals" ]; then
    OUT=$(CLAUDE_CONFIG_DIR="$CONFIG" HOME="$CASE_DIR/home" env -u FM_CLAUDE_IMPORT_APPROVALS "$TRUST" "$WT" "$PROJ" 2>&1)
  else
    OUT=$(CLAUDE_CONFIG_DIR="$CONFIG" HOME="$CASE_DIR/home" FM_CLAUDE_IMPORT_APPROVALS="$approvals" "$TRUST" "$WT" "$PROJ" 2>&1)
  fi
  local rc=$?
  return "$rc"
}

flag() {
  local path="$1"
  local flag_name="$2"
  CONFIG="$CONFIG" TARGET_PATH="$path" FLAG="$flag_name" node -e '
    const fs = require("fs");
    const file = process.env.CONFIG + "/.claude.json";
    let data;
    try {
      data = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
      console.log("null");
      process.exit(0);
    }
    const entry = data.projects && data.projects[process.env.TARGET_PATH];
    if (!entry) {
      console.log("null");
    } else {
      console.log(entry[process.env.FLAG] !== undefined ? entry[process.env.FLAG] : null);
    }
  '
}

assert_imports_true() {
  local path="$1"
  local msg="$2"
  local trust_dialog accepted warned
  trust_dialog=$(flag "$path" "hasTrustDialogAccepted")
  accepted=$(flag "$path" "hasClaudeMdExternalIncludesApproved")
  warned=$(flag "$path" "hasClaudeMdExternalIncludesWarningShown")
  if [ "$trust_dialog" = "true" ] && [ "$accepted" = "true" ] && [ "$warned" = "true" ]; then
    return 0
  else
    fail "$msg: expected all true, got trust=$trust_dialog accepted=$accepted warned=$warned"
  fi
}

assert_imports_not_true() {
  local path="$1"
  local msg="$2"
  local trust_dialog accepted
  trust_dialog=$(flag "$path" "hasTrustDialogAccepted")
  accepted=$(flag "$path" "hasClaudeMdExternalIncludesApproved")
  if [ "$trust_dialog" = "true" ] && [ "$accepted" != "true" ]; then
    return 0
  else
    fail "$msg: expected trust true and approved not true, got trust=$trust_dialog accepted=$accepted"
  fi
}

test_inherited_approval_is_carried_to_the_project_and_worktree_entries() {
  make_case inherit-approved
  echo "$PROJ" > "$CASE_DIR/approvals"
  run_trust "$CASE_DIR/approvals"
  expect_code 0 $? "exit 0"
  assert_imports_true "$WT" "worktree entry"
  assert_imports_true "$PROJ" "project entry"
  pass "fm-claude-trust.sh: inherited approval carried to both entries"
}

test_inherited_approval_listed_through_a_symlinked_path_still_matches() {
  make_case inherit-realpath
  ln -s "$PROJ" "$CASE_DIR/link"
  echo "$CASE_DIR/link" > "$CASE_DIR/approvals"
  run_trust "$CASE_DIR/approvals"
  expect_code 0 $? "exit 0"
  assert_imports_true "$PROJ" "project entry via symlink"
  pass "fm-claude-trust.sh: symlinked path matches"
}

test_unset_variable_changes_nothing() {
  make_case inherit-unset
  run_trust ""
  expect_code 0 $? "exit 0"
  assert_imports_not_true "$WT" "worktree entry"
  assert_imports_not_true "$PROJ" "project entry"
  pass "fm-claude-trust.sh: unset variable changes nothing"
}

test_absent_empty_or_non_matching_file_creates_no_consent() {
  # sub-case a: missing file
  make_case inherit-none-a
  run_trust "$CASE_DIR/missing"
  expect_code 0 $? "exit 0 for missing"
  assert_imports_not_true "$WT" "worktree entry missing"
  assert_imports_not_true "$PROJ" "project entry missing"

  # sub-case b: empty file
  make_case inherit-none-b
  touch "$CASE_DIR/approvals"
  run_trust "$CASE_DIR/approvals"
  expect_code 0 $? "exit 0 for empty"
  assert_imports_not_true "$WT" "worktree entry empty"
  assert_imports_not_true "$PROJ" "project entry empty"

  # sub-case c: non-matching line
  make_case inherit-none-c
  mkdir -p "$CASE_DIR/some-other-checkout"
  echo "$CASE_DIR/some-other-checkout" > "$CASE_DIR/approvals"
  run_trust "$CASE_DIR/approvals"
  expect_code 0 $? "exit 0 for non-matching"
  assert_imports_not_true "$WT" "worktree entry non-matching"
  assert_imports_not_true "$PROJ" "project entry non-matching"

  pass "fm-claude-trust.sh: absent/empty/non-matching creates no consent"
}

test_symlinked_approvals_file_is_ignored() {
  make_case inherit-symlink
  echo "$PROJ" > "$CASE_DIR/real-approvals"
  ln -s "$CASE_DIR/real-approvals" "$CASE_DIR/approvals"
  run_trust "$CASE_DIR/approvals"
  expect_code 0 $? "exit 0"
  assert_imports_not_true "$PROJ" "project entry"
  pass "fm-claude-trust.sh: symlinked approvals file ignored"
}

test_inherited_approval_never_overrides_a_recorded_decline() {
  make_case inherit-decline
  cat > "$CONFIG/.claude.json" <<EOF
{"hasCompletedOnboarding":true,"projects":{"$PROJ":{"hasTrustDialogAccepted":true,"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":true}}}
EOF
  before=$(cat "$CONFIG/.claude.json")
  echo "$PROJ" > "$CASE_DIR/approvals"
  run_trust "$CASE_DIR/approvals"
  expect_code 1 $? "exit 1 on decline"
  assert_contains "$OUT" "declined external CLAUDE.md imports" "message"
  after=$(cat "$CONFIG/.claude.json")
  if [ "$before" != "$after" ]; then
    fail "store changed"
  fi
  local wt_trust
  wt_trust=$(flag "$WT" "hasTrustDialogAccepted")
  if [ "$wt_trust" = "true" ]; then
    fail "worktree trust dialog accepted should not be true"
  fi
  pass "fm-claude-trust.sh: decline overrides inherited approval"
}

test_never_asked_default_entry_is_not_a_decline() {
  make_case inherit-default
  cat > "$CONFIG/.claude.json" <<EOF
{"hasCompletedOnboarding":true,"projects":{"$PROJ":{"hasTrustDialogAccepted":false,"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":false}}}
EOF
  echo "$PROJ" > "$CASE_DIR/approvals"
  run_trust "$CASE_DIR/approvals"
  expect_code 0 $? "exit 0"
  assert_imports_true "$PROJ" "project entry"
  pass "fm-claude-trust.sh: default entry not a decline"
}

test_inherited_approval_is_carried_to_the_project_and_worktree_entries
test_inherited_approval_listed_through_a_symlinked_path_still_matches
test_unset_variable_changes_nothing
test_absent_empty_or_non_matching_file_creates_no_consent
test_symlinked_approvals_file_is_ignored
test_inherited_approval_never_overrides_a_recorded_decline
test_never_asked_default_entry_is_not_a_decline
