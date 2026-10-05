#!/usr/bin/env bash
# Test that fm-teardown.sh guards against detaching/deleting when $WT is not a linked worktree or is on default branch.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-guard)

make_case() {
  local name="$1"
  local case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data"
  local fakebin
  fakebin=$(fm_fakebin "$case_dir")
  fm_fake_exit0 "$fakebin" treehouse tmux no-mistakes gh gh-axi
  touch "$case_dir/state/.last-watcher-beat"
  echo "$case_dir"
}

write_meta() {
  local case_dir="$1"
  local worktree="$2"
  local project="$3"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$worktree" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=teardown-guard-task-x1"
}

run_teardown() {
  local case_dir="$1"
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" task-x1 --force \
    > "$case_dir/teardown.out" 2> "$case_dir/teardown.err"
  # TEARDOWN_RC=$?  # not used
  :
}

assert_main_intact() {
  local repo="$1"
  local label="$2"
  local head
  head=$(git -C "$repo" symbolic-ref --short HEAD) || fail "$label: symbolic-ref HEAD failed"
  if [ "$head" != "main" ]; then
    fail "$label: HEAD is not main, got $head"
  fi
  if ! git -C "$repo" show-ref --verify --quiet refs/heads/main; then
    fail "$label: main branch does not exist"
  fi
  if git -C "$repo" reflog show HEAD | grep -q "moving from main to HEAD"; then
    fail "$label: reflog shows moving from main to HEAD"
  fi
}

test_plain_dir_inside_primary_checkout_keeps_main() {
  local case_dir
  case_dir=$(make_case "plain-dir-inside-primary")
  local outer="$case_dir/outer"
  fm_git_init_commit "$outer"
  local wt="$outer/data/inner/wt"
  mkdir -p "$wt"
  write_meta "$case_dir" "$wt" "$outer"
  run_teardown "$case_dir"
  assert_main_intact "$outer" "plain dir inside primary"
  if ! grep -q "not detaching" "$case_dir/teardown.err"; then
    fail "plain dir inside primary: stderr did not contain 'not detaching'"
  fi
  pass "plain dir inside primary checkout keeps main"
}

test_primary_checkout_as_worktree_keeps_main() {
  local case_dir
  case_dir=$(make_case "primary-checkout-as-worktree")
  local project="$case_dir/project"
  fm_git_init_commit "$project"
  write_meta "$case_dir" "$project" "$project"
  run_teardown "$case_dir"
  assert_main_intact "$project" "primary checkout as worktree"
  if ! grep -q "not detaching" "$case_dir/teardown.err"; then
    fail "primary checkout as worktree: stderr did not contain 'not detaching'"
  fi
  pass "primary checkout as worktree keeps main"
}

test_linked_worktree_on_default_branch_keeps_main() {
  local case_dir
  case_dir=$(make_case "linked-worktree-on-default-branch")
  local project="$case_dir/project"
  fm_git_init_commit "$project"
  git -C "$project" checkout --quiet --detach
  local wt="$case_dir/wt"
  git -C "$project" worktree add --quiet "$wt" main
  write_meta "$case_dir" "$wt" "$project"
  run_teardown "$case_dir"
  if ! git -C "$project" show-ref --verify --quiet refs/heads/main; then
    fail "linked worktree on default branch: main branch missing"
  fi
  if ! grep -q "not detaching" "$case_dir/teardown.err"; then
    fail "linked worktree on default branch: stderr did not contain 'not detaching'"
  fi
  pass "linked worktree on default branch keeps main"
}

test_normal_linked_worktree_still_gets_its_branch_deleted() {
  local case_dir
  case_dir=$(make_case "normal-linked-worktree-branch-deleted")
  local project="$case_dir/project"
  local wt="$case_dir/wt"
  fm_git_worktree "$project" "$wt" fm/task-x1
  write_meta "$case_dir" "$wt" "$project"
  run_teardown "$case_dir"
  assert_main_intact "$project" "normal linked worktree"
  if git -C "$project" show-ref --verify --quiet refs/heads/fm/task-x1; then
    fail "normal linked worktree: branch fm/task-x1 still exists"
  fi
  if git -C "$wt" symbolic-ref --quiet HEAD; then
    fail "normal linked worktree: worktree HEAD is not detached"
  fi
  if grep -q "not detaching" "$case_dir/teardown.err"; then
    fail "normal linked worktree: stderr unexpectedly contained 'not detaching'"
  fi
  pass "normal linked worktree gets its branch deleted"
}

test_fixture_temp_root_inside_a_checkout_cannot_resolve_it() {
    case_dir=$(make_case "temp-root-inside-checkout")
    outer="$case_dir/outer"
    fm_git_init_commit "$outer"
    scratch="$outer/data/scratch"
    mkdir -p "$scratch"
    # shellcheck disable=SC2016
    verdict=$(env -u GIT_CEILING_DIRECTORIES TMPDIR="$scratch" bash -c '. "$1/tests/lib.sh"; root=$(fm_test_tmproot probe); if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then echo ESCAPED; else echo CONTAINED; fi' _ "$ROOT" 2>/dev/null | tail -1)
    if [ "$verdict" != "CONTAINED" ]; then
        fail "fixture temp root inside a checkout resolved the enclosing checkout (got '$verdict')"
    else
        pass "fixture temp root inside a checkout cannot resolve it"
    fi
}

test_plain_dir_inside_primary_checkout_keeps_main
test_primary_checkout_as_worktree_keeps_main
test_linked_worktree_on_default_branch_keeps_main
test_normal_linked_worktree_still_gets_its_branch_deleted
test_fixture_temp_root_inside_a_checkout_cannot_resolve_it