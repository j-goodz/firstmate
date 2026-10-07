#!/usr/bin/env bash
# Tests for retiring a finished task's own Lavish boards (poll review A6):
# `fm-procevent.sh retire-task <task-id>` retires every board the task owns,
# keeps a board whose captured round is still unacknowledged, leaves other
# tasks' boards alone, and `reconcile` retires a board past its maximum age.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-task-retire)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
HOME1="$TMP_ROOT/home"
mkdir -p "$HOME1/state"
fm_test_track_procevent_home "$HOME1"

pe() { FM_HOME="$HOME1" "$ROOT/bin/fm-procevent.sh" "$@"; }
new_task_endpoint() {
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$1" "$HOME1" "$1" \
    > "$HOME1/state/$1.meta"
}
board() { # <source-id> <task-id>
  new_task_endpoint "$2"
  pe register-task lavish "$1" "$2" -- /bin/sleep 3600 >/dev/null || fail "could not register board $1 for $2"
}
registered() { [ -e "$HOME1/state/procevent/$1.source" ]; }

board lavish-aaaa1 task-one
board lavish-aaaa2 task-one
board lavish-bbbb1 task-two
pe register lavish lavish-firstmate -- /bin/sleep 3600 >/dev/null || fail "could not register a firstmate board"

out=$(pe retire-task task-one 2>&1) || fail "retire-task failed: $out"
registered lavish-aaaa1 && fail "task-one board 1 still registered"
registered lavish-aaaa2 && fail "task-one board 2 still registered"
registered lavish-bbbb1 || fail "retire-task removed another task's board"
registered lavish-firstmate || fail "retire-task removed a firstmate-owned board"
assert_contains "$out" "retired: lavish-aaaa1" "retire-task did not report the retired board"
pass "retire-task retires every board the task owns and no other"

out=$(pe retire-task task-one 2>&1) || fail "second retire-task not idempotent: $out"
pe retire-task 'bad/id' >/dev/null 2>&1 && fail "retire-task accepted an unsafe task id"
pass "retire-task is idempotent and validates the task id"

# A board with an unacknowledged captured round stays with its owner.
board lavish-cccc1 task-three
mkdir -p "$HOME1/state/procevent-inbox"
printf 'session:\n  status: feedback\n' > "$HOME1/state/procevent-inbox/lavish-cccc1.1.result"
out=$(pe retire-task task-three 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "retire-task retired a board with an unacknowledged round"
registered lavish-cccc1 || fail "the pending board was removed"
assert_contains "$out" "kept: lavish-cccc1" "pending board not reported as kept"
pass "a board with an unacknowledged round is kept and reported"

# Maximum age: an old idle board is retired by reconcile, a fresh one is kept.
touch -d '10 days ago' "$HOME1/state/procevent/lavish-bbbb1.source"
board lavish-dddd1 task-four
FM_PROCEVENT_BOARD_MAX_AGE_SECONDS=86400 pe reconcile >/dev/null 2>&1
registered lavish-bbbb1 && fail "reconcile kept a board older than the maximum age"
registered lavish-dddd1 || fail "reconcile retired a fresh board"
pass "reconcile retires a board past its maximum age and keeps a fresh one"

printf '\nall procevent task-retire tests passed\n'
