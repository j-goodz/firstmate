#!/usr/bin/env bash
# Live driver: exercise the real bin/fm-teardown.sh against disposable fixtures.
set -u

export FM_GATE_REFUSE_BYPASS=1

ROOT=/home/justin/.no-mistakes/worktrees/c7804fcd202d/01M45H8V5TGC73BJZH6G3WJT4E
TEARDOWN="$ROOT/bin/fm-teardown.sh"
PRE_TEARDOWN=${PRE_TEARDOWN:-}
WORK=/tmp/fm-teardown-live/scenes
rm -rf "$WORK"
mkdir -p "$WORK"

PASS=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

make_case() {
  local name="$1"
  local case_dir="$WORK/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data"
  local fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  local tool
  for tool in treehouse tmux no-mistakes gh gh-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir="$1" worktree="$2" project="$3" extra="${4:-}"
  {
    printf 'window=firstmate:fm-task-x1\n'
    printf 'endpoint_task_id=task-x1\n'
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$project"
    printf 'harness=codex\n'
    printf 'kind=ship\n'
    printf 'mode=local-only\n'
    printf 'spawn_gen=live-guard-task-x1\n'
    [ -n "$extra" ] && printf '%s\n' "$extra"
  } > "$case_dir/state/task-x1.meta"
}

run_teardown() {
  local case_dir="$1" teardown="$2"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" "$teardown" task-x1 --force \
    > "$case_dir/teardown.out" 2> "$case_dir/teardown.err"
  printf '%s' "$?" > "$case_dir/teardown.rc"
}

head_branch() { git -C "$1" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED; }
has_branch()  { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }

# ---- Scenario 1: plain directory inside an enclosing primary checkout -------
s1() {
  local case_dir outer wt head
  case_dir=$(make_case plain-dir)
  outer="$case_dir/outer"
  git -C "$outer" init -q -b main 2>/dev/null || { mkdir -p "$outer"; git -C "$outer" init -q -b main; }
  printf '# outer\n' > "$outer/README.md"
  git -C "$outer" add README.md
  git -C "$outer" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  wt="$outer/data/inner/wt"
  mkdir -p "$wt"
  write_meta "$case_dir" "$wt" "$outer"
  run_teardown "$case_dir" "$TEARDOWN"
  head=$(head_branch "$outer")
  printf 'scenario1: outer HEAD=%s main_exists=%s\n' "$head" "$(has_branch "$outer" main && echo yes || echo no)"
  printf 'scenario1 stderr: '; tr '\n' ' ' < "$case_dir/teardown.err"; printf '\n'
  if [ "$head" = main ] && has_branch "$outer" main; then ok "scenario1 plain-dir-inside-checkout keeps main (FIXED)"; else bad "scenario1 main destroyed by fixed teardown"; fi
}

# ---- Scenario 2: reproduction against the PRE-FIX teardown -----------------
s2() {
  [ -n "$PRE_TEARDOWN" ] || { bad "scenario2 no PRE_TEARDOWN supplied"; return; }
  local case_dir outer wt head
  case_dir=$(make_case pre-fix)
  outer="$case_dir/outer"
  mkdir -p "$outer"; git -C "$outer" init -q -b main
  printf '# outer\n' > "$outer/README.md"
  git -C "$outer" add README.md
  git -C "$outer" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  wt="$outer/data/inner/wt"
  mkdir -p "$wt"
  write_meta "$case_dir" "$wt" "$outer"
  run_teardown "$case_dir" "$PRE_TEARDOWN"
  head=$(head_branch "$outer")
  printf 'scenario2 (PRE-FIX): outer HEAD=%s main_exists=%s rc=%s\n' "$head" "$(has_branch "$outer" main && echo yes || echo no)" "$(cat "$case_dir/teardown.rc")"
  if [ "$head" = DETACHED ] || ! has_branch "$outer" main; then ok "scenario2 PRE-FIX reproduces the incident (main deleted/detached)"; else bad "scenario2 PRE-FIX did not reproduce the incident"; fi
}

# ---- Scenario 3: the primary checkout itself passed as the worktree --------
s3() {
  local case_dir project head
  case_dir=$(make_case primary-as-wt)
  project="$case_dir/project"
  mkdir -p "$project"; git -C "$project" init -q -b main
  printf '# p\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  write_meta "$case_dir" "$project" "$project"
  run_teardown "$case_dir" "$TEARDOWN"
  head=$(head_branch "$project")
  printf 'scenario3: HEAD=%s main_exists=%s\n' "$head" "$(has_branch "$project" main && echo yes || echo no)"
  if [ "$head" = main ] && has_branch "$project" main; then ok "scenario3 primary checkout as worktree keeps main"; else bad "scenario3 primary checkout main destroyed"; fi
}

# ---- Scenario 4: linked worktree checked out on the default branch ---------
s4() {
  local case_dir project wt
  case_dir=$(make_case linked-on-default)
  project="$case_dir/project"
  mkdir -p "$project"; git -C "$project" init -q -b main
  printf '# p\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  git -C "$project" checkout --quiet --detach
  wt="$case_dir/wt"
  git -C "$project" worktree add --quiet "$wt" main
  write_meta "$case_dir" "$wt" "$project"
  run_teardown "$case_dir" "$TEARDOWN"
  printf 'scenario4: main_exists=%s warning=%s\n' "$(has_branch "$project" main && echo yes || echo no)" "$(grep -c 'not detaching' "$case_dir/teardown.err" || true)"
  if has_branch "$project" main && grep -q 'not detaching' "$case_dir/teardown.err"; then ok "scenario4 linked worktree on default branch keeps main"; else bad "scenario4 default branch was removed from linked worktree"; fi
}

# ---- Scenario 5: normal linked worktree on an fm/ branch still cleaned -----
s5() {
  local case_dir project wt
  case_dir=$(make_case normal-linked)
  project="$case_dir/project"
  mkdir -p "$project"; git -C "$project" init -q -b main
  printf '# p\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  git -C "$project" clone --quiet --bare "$project" "$project.origin.git"
  git -C "$project" remote add origin "file://$project.origin.git"
  wt="$case_dir/wt"
  git -C "$project" worktree add --quiet -b fm/task-x1 "$wt"
  write_meta "$case_dir" "$wt" "$project"
  run_teardown "$case_dir" "$TEARDOWN"
  printf 'scenario5: fm_branch_exists=%s wt_head=%s warning=%s\n' \
    "$(has_branch "$project" fm/task-x1 && echo yes || echo no)" "$(head_branch "$wt")" \
    "$(grep -c 'not detaching' "$case_dir/teardown.err" || true)"
  if ! has_branch "$project" fm/task-x1 && [ "$(head_branch "$wt")" = DETACHED ] && ! grep -q 'not detaching' "$case_dir/teardown.err"; then
    ok "scenario5 normal linked worktree fm/ branch still deleted + detached"
  else
    bad "scenario5 normal cleanup regressed"
  fi
}

# ---- Scenario 6: GIT_CEILING_DIRECTORIES contains fixture discovery --------
s6() {
  local outer scratch verdict
  outer="$WORK/ceiling/outer"
  mkdir -p "$outer"; git -C "$outer" init -q -b main
  printf '# o\n' > "$outer/README.md"
  git -C "$outer" add README.md
  git -C "$outer" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  scratch="$outer/data/scratch"
  mkdir -p "$scratch"
  verdict=$(env -u GIT_CEILING_DIRECTORIES TMPDIR="$scratch" bash -c \
    '. "$1/tests/lib.sh"; root=$(fm_test_tmproot probe); if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then echo ESCAPED; else echo CONTAINED; fi' \
    _ "$ROOT" 2>/dev/null | tail -1)
  printf 'scenario6: verdict=%s ceiling=%s\n' "$verdict" "${GIT_CEILING_DIRECTORIES:-unset}"
  if [ "$verdict" = CONTAINED ]; then ok "scenario6 fixture temp root cannot climb into enclosing checkout"; else bad "scenario6 fixture discovery escaped into enclosing checkout"; fi
}

# ---- Scenario 6b: control WITHOUT the ceiling fix (pre-fix lib.sh) ---------
s6b() {
  [ -n "${PRE_LIB:-}" ] || { bad "scenario6b no PRE_LIB supplied"; return; }
  local outer scratch verdict
  outer="$WORK/ceiling-pre/outer"
  mkdir -p "$outer"; git -C "$outer" init -q -b main
  printf '# o\n' > "$outer/README.md"
  git -C "$outer" add README.md
  git -C "$outer" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  scratch="$outer/data/scratch"
  mkdir -p "$scratch"
  verdict=$(env -u GIT_CEILING_DIRECTORIES TMPDIR="$scratch" bash -c \
    '. "$1"; root=$(fm_test_tmproot probe); if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then echo ESCAPED; else echo CONTAINED; fi' \
    _ "$PRE_LIB" 2>/dev/null | tail -1)
  printf 'scenario6b (PRE-FIX lib): verdict=%s\n' "$verdict"
  if [ "$verdict" = ESCAPED ]; then ok "scenario6b PRE-FIX lib escapes into enclosing checkout (reproduces)"; else bad "scenario6b PRE-FIX lib did not escape"; fi
}

# ---- Scenario 7: orca branch reaches the same guard ------------------------
s7() {
  local case_dir outer wt head fakebin
  case_dir=$(make_case orca-plain-dir)
  fakebin="$case_dir/fakebin"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"worktree show"*) printf '{"ok":true,"result":{"worktree":{"id":"repo1::%s","path":"%s"}}}' "$ORCA_FAKE_WT" "$ORCA_FAKE_WT"; exit 0 ;;
  *status*) printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'; exit 0 ;;
  *) printf '{"ok":true,"result":{}}'; exit 0 ;;
esac
SH
  chmod +x "$fakebin/orca"
  outer="$case_dir/outer"
  mkdir -p "$outer"; git -C "$outer" init -q -b main
  printf '# outer\n' > "$outer/README.md"
  git -C "$outer" add README.md
  git -C "$outer" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  wt="$outer/data/inner/wt"
  mkdir -p "$wt"
  {
    printf 'window=fm-task-x1\n'
    printf 'endpoint_task_id=task-x1\n'
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$outer"
    printf 'harness=codex\n'
    printf 'kind=ship\n'
    printf 'mode=local-only\n'
    printf 'spawn_gen=live-guard-task-x1\n'
    printf 'backend=orca\n'
    printf 'terminal=term-7\n'
    printf 'orca_worktree_id=repo1::%s\n' "$wt"
  } > "$case_dir/state/task-x1.meta"
  ORCA_FAKE_WT="$wt"
  export ORCA_FAKE_WT
  run_teardown "$case_dir" "$TEARDOWN"
  head=$(head_branch "$outer")
  printf 'scenario7: rc=%s HEAD=%s main_exists=%s warning=%s\n' "$(cat "$case_dir/teardown.rc")" "$head" \
    "$(has_branch "$outer" main && echo yes || echo no)" "$(grep -c 'not detaching' "$case_dir/teardown.err" || true)"
  if [ "$head" = main ] && has_branch "$outer" main && grep -q 'not detaching' "$case_dir/teardown.err"; then
    ok "scenario7 orca block uses the guard and keeps main"
  else
    bad "scenario7 orca block did not protect the enclosing checkout"
  fi
}

s1
s2
s3
s4
s5
s6
s6b
s7

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
