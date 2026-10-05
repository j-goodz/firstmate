#!/usr/bin/env bash
# Behavior tests for bin/fm-idle-session-reap.sh, written from its contract:
# close only an agent session that is BOTH idle past the window AND finished or
# ownerless; never a secondmate or supervisor pane, a lane with unlanded work, a
# lane whose task is still in flight, or a pane someone may be typing in; log
# every close and skip as JSONL with a reason; one attempt per run.
# The Herdr reads and the pane close are replaced through the script's
# source-only seams; discovery, ownership, idle markers, the owning home's own
# crew-state and control scripts, git landed checks, the log, the observation
# store, the lock, and the timer installer all run for real.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-session-reap)
FIX="$TMP_ROOT/fixture"
mkdir -p "$FIX"
fm_git_identity
# Homes are discovered under $HOME, so point discovery at the fixture root for
# every run; the fixture homes stand in for a machine's real homes.
export HOME="$TMP_ROOT"

export FM_IDLE_REAP_LOG="$TMP_ROOT/reaper.jsonl"
export FM_IDLE_REAP_SEEN="$TMP_ROOT/seen.tsv"
export FM_IDLE_REAP_LOCK="$TMP_ROOT/reaper.lock"
CLOSE_LOG="$TMP_ROOT/closes.log"
CONTROL_LOG="$TMP_ROOT/control.log"
: > "$CLOSE_LOG"
: > "$CONTROL_LOG"

NOW=$(date +%s)
OLD=$((NOW - 7200))

# --- fake firstmate homes ----------------------------------------------------

make_home() {  # <dir>
  local h=$1
  mkdir -p "$h/bin" "$h/state" "$h/data" "$h/crew-fixture"
  : > "$h/AGENTS.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/fm-spawn.sh"
  cat > "$h/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
f="$FM_HOME/crew-fixture/$1"
if [ -f "$f" ]; then cat "$f"; else echo "state: unknown · source: none · no fixture"; fi
SH
  cat > "$h/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
printf '%s %s %s\n' "\$FM_HOME" "\$1" "\$2" >> "$CONTROL_LOG"
[ ! -e "\$FM_HOME/control-fail" ] || { echo "error: exit=unconfirmed" >&2; exit 3; }
echo "exit: stopped"
SH
  chmod +x "$h/bin/"*.sh
}

H1="$TMP_ROOT/home1"
H2="$TMP_ROOT/home2"
make_home "$H1"
make_home "$H2"
printf 'mate2\n' > "$H2/.fm-secondmate-home"
export FM_IDLE_REAP_HOMES="$H1:$H2"

# A landed clean worktree, one with uncommitted edits, one with unpushed commits.
REPO="$TMP_ROOT/repo"
fm_git_worktree "$REPO" "$TMP_ROOT/wt-clean" fm/clean >/dev/null 2>&1
git -C "$REPO" worktree add --quiet -b fm/dirty "$TMP_ROOT/wt-dirty" main
printf 'edit\n' >> "$TMP_ROOT/wt-dirty/README.md"
git -C "$REPO" worktree add --quiet -b fm/unpushed "$TMP_ROOT/wt-unpushed" main
printf 'x\n' > "$TMP_ROOT/wt-unpushed/new.txt"
git -C "$TMP_ROOT/wt-unpushed" add new.txt
git -C "$TMP_ROOT/wt-unpushed" commit -qm unpushed
git -C "$REPO" fetch -q origin

lane_meta() {  # <home> <id> <pane> <worktree> [kind]
  fm_write_meta "$1/state/$2.meta" \
    "window=s1:$3" "harness=claude" "kind=${5:-ship}" "backend=herdr" \
    "herdr_session=s1" "herdr_pane_id=$3" "worktree=$4"
  fm_touch_epoch "$OLD" "$1/state/$2.meta"
}
crew() {  # <home> <id> <crew-state line>
  printf '%s\n' "$3" > "$1/crew-fixture/$2"
}

# --- Herdr fixture -----------------------------------------------------------
# One row per pane: pane|tab label|workspace label|agent|agent_status|focused|cwd

ROWS="$FIX/rows"
: > "$ROWS"
row() { printf '%s\n' "$*" >> "$ROWS"; }

build_snapshot() {
  jq -Rn '
    [inputs | split("|")] as $r
    | {result:{snapshot:{
        panes: [$r[] | {pane_id:.[0], tab_id:(.[0]|sub(":p";":t")), workspace_id:(.[0]|split(":")[0]),
                        agent:(if .[3]=="" then null else .[3] end), agent_status:.[4],
                        focused:(.[5]=="1"), cwd:.[6], foreground_cwd:.[6],
                        terminal_id:("term-"+.[0]), revision:1}],
        tabs: [$r[] | {tab_id:(.[0]|sub(":p";":t")), label:.[1]}],
        workspaces: [$r[] | {workspace_id:(.[0]|split(":")[0]), label:.[2]}]}}}' < "$ROWS"
}

export FM_IDLE_REAP_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-idle-session-reap.sh"
unset FM_IDLE_REAP_SOURCE_ONLY

# Seams replaced for the fixture; invoked indirectly by the script under test.
# shellcheck disable=SC2329
fm_idle_reap_herdr_sessions() { printf 's1\n'; [ ! -e "$FIX/lab" ] || printf 'fm-lab-x\n'; }
# shellcheck disable=SC2329
fm_idle_reap_snapshot() {
  [ "$1" = s1 ] || { echo "lab session $1 was read" >> "$CLOSE_LOG"; return 1; }
  build_snapshot
}
# shellcheck disable=SC2329
fm_idle_reap_fingerprint() { cat "$FIX/fp-${2//:/_}" 2>/dev/null || printf 'fp-%s' "$2"; }
# shellcheck disable=SC2329
fm_idle_reap_composer_state() { cat "$FIX/composer-${2//:/_}" 2>/dev/null || printf 'empty'; }
# shellcheck disable=SC2329
fm_idle_reap_agent_stopped() { [ -e "$FIX/stopped-${2//:/_}" ]; }
# shellcheck disable=SC2329
fm_idle_reap_viewer_present() { [ -e "$FIX/viewer" ]; }
# shellcheck disable=SC2329
fm_idle_reap_close_pane() { printf '%s %s\n' "$1" "$2" >> "$CLOSE_LOG"; }

run_reap() {  # [args...] - one run at FM_IDLE_REAP_NOW
  ( fm_idle_reap_main "$@" ) > "$TMP_ROOT/run.out" 2>&1
}
run_reap_no_homes() {  # [args...] - discovery sees no Firstmate home
  ( export HOME="$EMPTY_HOME"; unset FM_IDLE_REAP_HOMES; fm_idle_reap_main "$@" ) \
    > "$TMP_ROOT/run.out" 2>&1
}
last_decision() {  # <pane> -> "<action> <reason>" from that pane's newest log line
  jq -r --arg p "$1" 'select(.event=="pane" and .pane==$p) | "\(.action) \(.reason)"' "$FM_IDLE_REAP_LOG" | tail -n 1
}
reset_run() {
  : > "$ROWS"; : > "$CLOSE_LOG"; : > "$CONTROL_LOG"; : > "$FM_IDLE_REAP_LOG"
  rm -f "$FM_IDLE_REAP_SEEN" "$FIX"/fp-* "$FIX"/composer-* "$FIX"/stopped-* "$FIX/viewer" "$FIX/lab" "$H1/control-fail"
  rm -rf "${H1:?}"/state/* "${H2:?}"/state/* "${H1:?}"/crew-fixture/* "${H2:?}"/crew-fixture/* "${H1:?}"/data/*
}

# --- 1. ownerless idle lane: observed first, closed once idle past the window --
reset_run
row "w1:p2|fm-gone-task|└ gone-task · p:x|opencode|idle|0|$TMP_ROOT/wt-clean"
FM_IDLE_REAP_NOW=$((NOW - 3600)) run_reap --apply || fail "first run failed: $(cat "$TMP_ROOT/run.out")"
assert_equals "observed first-sight-idle" "$(last_decision w1:p2)" "first sight only observes an ownerless pane"
[ ! -s "$CLOSE_LOG" ] || fail "first sight closed a pane"
FM_IDLE_REAP_NOW=$NOW run_reap --apply || fail "second run failed: $(cat "$TMP_ROOT/run.out")"
assert_equals "closed ownerless-idle" "$(last_decision w1:p2)" "an unchanged ownerless lane idle past the window is closed"
assert_equals "s1 w1:p2" "$(cat "$CLOSE_LOG")" "the exact ownerless pane is closed"
pass "ownerless idle lane is observed, then closed after the idle window"

# --- 2. ownerless lane whose screen changed is kept ---------------------------
reset_run
row "w1:p2|fm-gone-task|└ gone-task · p:x|opencode|idle|0|$TMP_ROOT/wt-clean"
FM_IDLE_REAP_NOW=$((NOW - 3600)) run_reap --apply
printf 'changed' > "$FIX/fp-w1_p2"
FM_IDLE_REAP_NOW=$NOW run_reap --apply
assert_equals "observed activity-seen" "$(last_decision w1:p2)" "a changed screen restarts the idle clock"
[ ! -s "$CLOSE_LOG" ] || fail "an ownerless pane with new activity was closed"
pass "ownerless lane with new screen activity is kept"

# --- 3. ownerless but unchanged for less than the window is kept --------------
reset_run
row "w1:p2|fm-gone-task|└ gone-task · p:x|opencode|idle|0|$TMP_ROOT/wt-clean"
FM_IDLE_REAP_NOW=$((NOW - 600)) run_reap --apply
FM_IDLE_REAP_NOW=$NOW run_reap --apply
assert_equals "skipped recent-activity" "$(last_decision w1:p2)" "10 minutes unchanged is under the 30 minute window"
[ ! -s "$CLOSE_LOG" ] || fail "a pane idle under the window was closed"
FM_IDLE_REAP_NOW=$NOW run_reap --apply --idle-minutes 5
assert_equals "closed ownerless-idle" "$(last_decision w1:p2)" "--idle-minutes shortens the window"
pass "a pane idle for less than the window is kept, and the window is configurable"

# --- 4. protected panes: working, secondmate, supervisor, captain, labs -------
reset_run
touch "$FIX/lab"
row "w1:p2|fm-busy|└ busy · p:x|claude|working|0|$TMP_ROOT/wt-clean"
row "w2:p2|fm-mate2|2ndmate-mate2|opencode|idle|0|$H2"
row "w3:p2|fm-mate9|└ mate9 · p:x|opencode|idle|0|$TMP_ROOT/wt-clean"
row "w4:p1|FIRSTMATE - talk here|nexus-brain|claude|idle|0|$H1"
row "w5:p1|1|~|claude|idle|0|$TMP_ROOT"
row "w6:p1|fm-shell-only|└ shell-only · p:x||unknown|0|$TMP_ROOT/wt-clean"
row "w7:p2|fm-sup|firstmate|claude|idle|0|$H1"
fm_write_meta "$H1/state/mate9.meta" "window=remote:mate9" "kind=secondmate" "harness=opencode" "home=$TMP_ROOT/mate9-home" "remote_host=elsewhere"
FM_IDLE_REAP_NOW=$((NOW - 3600)) run_reap --apply
FM_IDLE_REAP_NOW=$NOW run_reap --apply
assert_equals "skipped working" "$(last_decision w1:p2)" "a working agent is kept"
assert_equals "skipped supervisor-pane" "$(last_decision w2:p2)" "a secondmate's own pane is kept"
assert_equals "skipped supervisor-pane" "$(last_decision w3:p2)" "a pane labelled for a registered secondmate is kept"
assert_equals "skipped not-a-firstmate-lane" "$(last_decision w4:p1)" "the primary supervisor pane is kept"
assert_equals "skipped not-a-firstmate-lane" "$(last_decision w5:p1)" "a captain pane outside firstmate lanes is kept"
assert_equals "skipped no-agent" "$(last_decision w6:p1)" "a pane with no agent is kept"
assert_equals "skipped supervisor-pane" "$(last_decision w7:p2)" "a pane in the firstmate supervisor workspace is kept"
[ ! -s "$CLOSE_LOG" ] || fail "a protected pane or lab session was touched: $(cat "$CLOSE_LOG")"
pass "working, secondmate, supervisor, captain and shell-only panes and lab sessions are never closed"

# --- 5. typing guards: focused with a viewer, non-empty composer --------------
reset_run
row "w1:p2|fm-gone-a|└ gone-a · p:x|claude|idle|1|$TMP_ROOT/wt-clean"
row "w2:p2|fm-gone-b|└ gone-b · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
printf 'pending' > "$FIX/composer-w2_p2"
touch "$FIX/viewer"
FM_IDLE_REAP_NOW=$((NOW - 3600)) run_reap --apply
FM_IDLE_REAP_NOW=$NOW run_reap --apply
assert_equals "skipped focused-with-viewer" "$(last_decision w1:p2)" "a focused pane with a viewer attached is kept"
assert_equals "skipped composer-pending" "$(last_decision w2:p2)" "a pane with typed input is kept"
[ ! -s "$CLOSE_LOG" ] || fail "a pane someone may be typing in was closed"
pass "a pane someone may be typing in is kept"

# --- 6. ownerless pane sitting in a worktree with unlanded work ---------------
reset_run
row "w1:p2|fm-gone-a|└ gone-a · p:x|claude|idle|0|$TMP_ROOT/wt-dirty"
row "w2:p2|fm-gone-b|└ gone-b · p:x|claude|idle|0|$TMP_ROOT/wt-unpushed"
FM_IDLE_REAP_NOW=$((NOW - 3600)) run_reap --apply
FM_IDLE_REAP_NOW=$NOW run_reap --apply
assert_equals "skipped uncommitted-work" "$(last_decision w1:p2)" "uncommitted work keeps an ownerless pane"
assert_equals "skipped unlanded-commits" "$(last_decision w2:p2)" "unpushed commits keep an ownerless pane"
[ ! -s "$CLOSE_LOG" ] || fail "an ownerless pane with unlanded work was closed"
pass "an ownerless pane in a worktree with unlanded work is kept"

# --- 7. owned finished lane: exited through the owning home's control plane ---
reset_run
export FM_IDLE_REAP_NOW=$NOW
row "w1:p2|fm-done-task|└ done-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" done-task w1:p2 "$TMP_ROOT/wt-clean"
printf 'done [at=%s]: PR https://example.invalid/pr/1 checks green\n' "$OLD" > "$H1/state/done-task.status"
fm_touch_epoch "$OLD" "$H1/state/done-task.status"
crew "$H1" done-task "state: done · source: status-log · PR merged"
run_reap --apply || fail "owned run failed: $(cat "$TMP_ROOT/run.out")"
assert_equals "exited finished-idle" "$(last_decision w1:p2)" "a finished idle owned lane is exited"
assert_equals "$H1 done-task exit" "$(cat "$CONTROL_LOG")" "the exit goes through the owning home's fm-control.sh"
[ ! -s "$CLOSE_LOG" ] || fail "an owned lane's pane was closed directly instead of through its home"
assert_contains "$(tail -n 1 "$H1/state/done-task.status")" "note [at=" "the owning home is told why the agent stopped"
assert_contains "$(tail -n 1 "$H1/state/done-task.status")" "idle-session-reaper" "the note names the reaper"
pass "a finished idle owned lane is exited through its home and the home is told"

# --- 7b. an agent already stopped is not stopped again ----------------------
# Herdr keeps the last agent label on a pane after the agent exits, so a pane
# whose only process is an idle shell must not be exited or noted every hour.
reset_run
row "w1:p2|fm-done-task|└ done-task · p:x|claude|done|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" done-task w1:p2 "$TMP_ROOT/wt-clean"
crew "$H1" done-task "state: done · source: status-log · done"
row "w2:p2|fm-gone|└ gone · p:x|claude|done|0|$TMP_ROOT/wt-clean"
touch "$FIX/stopped-w1_p2" "$FIX/stopped-w2_p2"
FM_IDLE_REAP_NOW=$((NOW - 3600)) run_reap --apply
FM_IDLE_REAP_NOW=$NOW run_reap --apply
assert_equals "skipped agent-stopped" "$(last_decision w1:p2)" "an owned pane holding only a shell is left alone"
assert_equals "skipped agent-stopped" "$(last_decision w2:p2)" "an ownerless pane holding only a shell is left alone"
[ ! -s "$CONTROL_LOG" ] && [ ! -s "$CLOSE_LOG" ] || fail "a pane whose agent already exited was acted on again"
[ ! -e "$H1/state/done-task.status" ] || fail "a note was appended for an agent that had already stopped"
pass "a pane whose agent already exited is not exited or noted again"

# --- 8. owned lanes that must stay -------------------------------------------
reset_run
row "w1:p2|fm-busy-task|└ busy-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" busy-task w1:p2 "$TMP_ROOT/wt-clean"
crew "$H1" busy-task "state: working · source: run-step · ci"
row "w2:p2|fm-fresh-task|└ fresh-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" fresh-task w2:p2 "$TMP_ROOT/wt-clean"
touch "$H1/state/fresh-task.turn-ended"
crew "$H1" fresh-task "state: done · source: status-log · done"
row "w3:p2|fm-dirty-task|└ dirty-task · p:x|claude|idle|0|$TMP_ROOT/wt-dirty"
lane_meta "$H1" dirty-task w3:p2 "$TMP_ROOT/wt-dirty"
crew "$H1" dirty-task "state: done · source: status-log · done"
row "w4:p2|fm-unpushed-task|└ unpushed-task · p:x|claude|idle|0|$TMP_ROOT/wt-unpushed"
lane_meta "$H1" unpushed-task w4:p2 "$TMP_ROOT/wt-unpushed"
crew "$H1" unpushed-task "state: done · source: status-log · done"
row "w5:p2|fm-gate-task|└ gate-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" gate-task w5:p2 "$TMP_ROOT/wt-clean"
crew "$H1" gate-task "state: paused · source: run-step · waiting on validation"
row "w6:p2|fm-ask-task|└ ask-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" ask-task w6:p2 "$TMP_ROOT/wt-clean"
crew "$H1" ask-task "state: blocked · source: status-log · needs-decision"
row "w7:p2|fm-scout-task|└ scout-task · p:x|claude|idle|0|$TMP_ROOT/wt-dirty"
lane_meta "$H1" scout-task w7:p2 "$TMP_ROOT/wt-dirty" scout
crew "$H1" scout-task "state: done · source: status-log · done"
row "w8:p2|fm-dup-task|└ dup-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" dup-task w8:p2 "$TMP_ROOT/wt-clean"
lane_meta "$H2" dup-task w8:p2 "$TMP_ROOT/wt-clean"
crew "$H1" dup-task "state: done · source: status-log · done"
row "w9:p2|fm-parked-scout|└ parked-scout · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" parked-scout w9:p2 "$TMP_ROOT/wt-clean" secondmate
run_reap --apply
assert_equals "skipped in-flight:working" "$(last_decision w1:p2)" "a lane in flight is kept"
assert_equals "skipped recent-activity" "$(last_decision w2:p2)" "a lane with a recent turn is kept"
assert_equals "skipped uncommitted-work" "$(last_decision w3:p2)" "a lane with uncommitted work is kept"
assert_equals "skipped unlanded-commits" "$(last_decision w4:p2)" "a lane with unpushed commits is kept"
assert_equals "skipped in-flight:paused-validation" "$(last_decision w5:p2)" "a lane waiting on its own validation run is kept"
assert_equals "skipped in-flight:blocked" "$(last_decision w6:p2)" "a lane awaiting a decision is kept"
assert_equals "skipped scout-no-report" "$(last_decision w7:p2)" "a scout without its report is kept"
assert_equals "skipped ambiguous-owner" "$(last_decision w8:p2)" "a pane two records claim is kept"
assert_equals "skipped supervisor-pane" "$(last_decision w9:p2)" "a pane a secondmate record owns is kept"
[ ! -s "$CONTROL_LOG" ] || fail "an in-flight or unlanded lane was exited: $(cat "$CONTROL_LOG")"
pass "in-flight, recently active, unlanded, reportless, ambiguous and secondmate lanes are kept"

# --- 9. paused-but-finished lane and a reported scout are exited --------------
reset_run
row "w1:p2|fm-parked|└ parked · p:x|opencode|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" parked w1:p2 "$TMP_ROOT/wt-clean"
crew "$H1" parked "state: paused · source: status-log · PR merged, teardown deferred"
row "w2:p2|fm-scouted|└ scouted · p:x|opencode|idle|0|$TMP_ROOT/wt-dirty"
lane_meta "$H1" scouted w2:p2 "$TMP_ROOT/wt-dirty" scout
mkdir -p "$H1/data/scouted"
: > "$H1/data/scouted/report.md"
crew "$H1" scouted "state: paused · source: status-log · board armed"
run_reap --apply
assert_equals "exited finished-idle" "$(last_decision w1:p2)" "a paused lane with landed work and no live run is exited"
assert_equals "exited finished-idle" "$(last_decision w2:p2)" "a paused scout with its report is exited"
pass "paused lanes with nothing left in flight are exited"

# --- 10. a control-plane refusal is logged, not retried -----------------------
reset_run
row "w1:p2|fm-done-task|└ done-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" done-task w1:p2 "$TMP_ROOT/wt-clean"
crew "$H1" done-task "state: done · source: status-log · done"
touch "$H1/control-fail"
run_reap --apply
assert_equals "failed control-exit-failed" "$(last_decision w1:p2)" "a refused exit is logged as failed"
assert_equals 1 "$(wc -l < "$CONTROL_LOG" | tr -d ' ')" "exactly one attempt per run"
pass "a refused exit is logged once with no retry"

# --- 11. dry run changes nothing ---------------------------------------------
reset_run
row "w1:p2|fm-done-task|└ done-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H1" done-task w1:p2 "$TMP_ROOT/wt-clean"
crew "$H1" done-task "state: done · source: status-log · done"
row "w2:p2|fm-gone|└ gone · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
FM_IDLE_REAP_NOW=$((NOW - 3600)) run_reap
FM_IDLE_REAP_NOW=$NOW run_reap
assert_equals "would-exit finished-idle" "$(last_decision w1:p2)" "dry run reports the exit it would make"
assert_equals "would-close ownerless-idle" "$(last_decision w2:p2)" "dry run reports the close it would make"
[ ! -s "$CONTROL_LOG" ] && [ ! -s "$CLOSE_LOG" ] || fail "dry run changed something"
[ ! -e "$H1/state/done-task.status" ] || fail "dry run wrote a status note"
pass "dry run reports decisions and changes nothing"

# --- 12. log shape and run summary -------------------------------------------
jq -e . "$FM_IDLE_REAP_LOG" >/dev/null || fail "the log is not valid JSONL"
summary=$(jq -c 'select(.event=="run")' "$FM_IDLE_REAP_LOG" | tail -n 1)
assert_contains "$summary" '"mode":"dry-run"' "the summary records the mode"
assert_contains "$summary" '"acted":2' "the summary counts the decisions that act"
assert_contains "$summary" '"duration_ms":' "the summary records the run time"
[ "$(jq -s '[.[] | select(.event=="pane") | select((.ts and .host and .session and .pane and .action and .reason) | not)] | length' "$FM_IDLE_REAP_LOG")" = 0 ] \
  || fail "a pane line is missing a required field"
pass "every decision is one JSON line with a reason, plus a run summary"

# --- 13. an overlapping run is refused, not queued ----------------------------
reset_run
fm_lock_try_acquire "$FM_IDLE_REAP_LOCK" || fail "test could not take the reaper lock"
run_reap --apply
rc=$?
fm_lock_release "$FM_IDLE_REAP_LOCK"
assert_equals 0 "$rc" "an overlapping run exits cleanly"
assert_equals overlap "$(jq -r 'select(.event=="run") | .result' "$FM_IDLE_REAP_LOG")" "an overlapping run is logged"
pass "an overlapping run is logged and skipped"

# --- 14. hourly timer install ------------------------------------------------
UNIT_DIR="$TMP_ROOT/systemd-user"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/systemctl.log"
SH
chmod +x "$FAKEBIN/systemctl"
PATH="$FAKEBIN:$PATH" HOME="$TMP_ROOT" FM_IDLE_REAP_SYSTEMD_DIR="$UNIT_DIR" bash "$ROOT/bin/fm-idle-session-reap.sh" install-timer \
  > "$TMP_ROOT/install.out" 2>&1 || fail "install-timer failed: $(cat "$TMP_ROOT/install.out")"
timer=$(cat "$UNIT_DIR/fm-idle-session-reap.timer")
service=$(cat "$UNIT_DIR/fm-idle-session-reap.service")
assert_contains "$timer" "OnCalendar=hourly" "the timer fires hourly"
assert_contains "$service" "ExecStart=$ROOT/bin/fm-idle-session-reap.sh --apply" "the service runs this script in apply mode"
assert_contains "$service" "Type=oneshot" "one attempt per run"
assert_not_contains "$service" "Restart=" "no retry loop"
assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now fm-idle-session-reap.timer" "the timer is enabled"
recorded_homes=$(printf '%s\n' "$service" | sed -n 's/^Environment="FM_IDLE_REAP_HOMES=\(.*\)"$/\1/p')
assert_equals "$H1:$H2" "$recorded_homes" "the unit records the discovered homes so the hourly run does not rely on HOME discovery"
pass "install-timer writes and enables an hourly one-shot timer"

# --- 14b. a spinner frame is not activity -----------------------------------
# A tool left in a running state animates a spinner forever, so the screen
# digest must not change when only a spinner glyph does.
d1=$(printf '  ┃  ⠼ timeout 180 ssh host\n  done\n' | fm_idle_reap_screen_digest)
d2=$(printf '  ┃  ⠧ timeout 180 ssh host\n  done\n' | fm_idle_reap_screen_digest)
d3=$(printf '  ┃  ⠧ timeout 180 ssh other\n  done\n' | fm_idle_reap_screen_digest)
[ -n "$d1" ] || fail "screen digest is empty"
assert_equals "$d1" "$d2" "a spinner frame change leaves the digest unchanged"
assert_not_equals "$d1" "$d3" "a real text change changes the digest"
pass "a spinner frame is not counted as screen activity"

# --- 15. help ----------------------------------------------------------------
bash "$ROOT/bin/fm-idle-session-reap.sh" --help > "$TMP_ROOT/help.out" 2>&1 || fail "--help failed"
assert_contains "$(cat "$TMP_ROOT/help.out")" "Usage: fm-idle-session-reap.sh" "--help prints usage"
pass "--help prints usage"

# --- 16. discovery finding no home fails closed, never an ownerless close -----
# With no Firstmate home discovered, ownership cannot be judged: an fm-<task>
# pane must not be treated as ownerless and closed directly.
reset_run
EMPTY_HOME="$TMP_ROOT/empty-home"
mkdir -p "$EMPTY_HOME"
row "w1:p2|fm-gone-task|└ gone-task · p:x|opencode|idle|0|$TMP_ROOT/wt-clean"
FM_IDLE_REAP_NOW=$((NOW - 3600)) run_reap_no_homes --apply || fail "no-home run failed: $(cat "$TMP_ROOT/run.out")"
FM_IDLE_REAP_NOW=$NOW run_reap_no_homes --apply || fail "no-home run failed: $(cat "$TMP_ROOT/run.out")"
assert_equals "skipped no-owner-home" "$(last_decision w1:p2)" "with no Firstmate home discovered no pane owner can be judged"
[ ! -s "$CLOSE_LOG" ] || fail "a pane was closed with no home discovered: $(cat "$CLOSE_LOG")"
pass "discovery finding no home fails closed and closes nothing"

# --- 17. a home added after install is still discovered fresh ----------------
# install-timer froze the homes it saw; a home created later must still claim
# its lane, so its pane is exited through that home, never closed as ownerless.
reset_run
H3="$TMP_ROOT/home3"
make_home "$H3"
row "w1:p2|fm-late-task|└ late-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H3" late-task w1:p2 "$TMP_ROOT/wt-clean"
crew "$H3" late-task "state: done · source: status-log · done"
FM_IDLE_REAP_NOW=$NOW run_reap --apply || fail "late-home run failed: $(cat "$TMP_ROOT/run.out")"
assert_equals "exited finished-idle" "$(last_decision w1:p2)" "a home added after install still owns its finished idle lane"
assert_equals "$H3 late-task exit" "$(cat "$CONTROL_LOG")" "the exit goes through the added home's fm-control.sh"
[ ! -s "$CLOSE_LOG" ] || fail "a home-owned pane was closed as ownerless: $(cat "$CLOSE_LOG")"
pass "a home added after install is discovered fresh and its lane is exited, not closed"

# --- 18. a changed Herdr pane id does not orphan a home-owned lane -----------
# Herdr pane ids are not stable across server restarts. Ownership comes from
# state/<task>.meta by lane id, so a pane whose recorded pane id is stale is
# still exited through its home, never closed directly.
reset_run
row "w1:p2|fm-moved-task|└ moved-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
fm_write_meta "$H1/state/moved-task.meta" \
  "window=s1:w9:p9" "harness=claude" "kind=ship" "backend=herdr" \
  "herdr_session=s1" "herdr_pane_id=w9:p9" "worktree=$TMP_ROOT/wt-clean"
fm_touch_epoch "$OLD" "$H1/state/moved-task.meta"
crew "$H1" moved-task "state: done · source: status-log · done"
FM_IDLE_REAP_NOW=$NOW run_reap --apply || fail "moved-pane run failed: $(cat "$TMP_ROOT/run.out")"
assert_equals "exited finished-idle" "$(last_decision w1:p2)" "a stale recorded pane id still resolves the owning home"
assert_equals "$H1 moved-task exit" "$(cat "$CONTROL_LOG")" "the exit goes through the owning home"
[ ! -s "$CLOSE_LOG" ] || fail "a home-owned pane with a changed pane id was closed: $(cat "$CLOSE_LOG")"
pass "a changed Herdr pane id is not treated as ownerless"

# --- 19. FM_IDLE_REAP_HOMES is additional, never the only set ----------------
# A recorded list missing the owning home must not make that home's lane
# ownerless; discovery still finds the home under $HOME.
reset_run
row "w1:p2|fm-partial-task|└ partial-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H2" partial-task w1:p2 "$TMP_ROOT/wt-clean"
crew "$H2" partial-task "state: done · source: status-log · done"
FM_IDLE_REAP_HOMES="$H1" FM_IDLE_REAP_NOW=$NOW run_reap --apply || fail "partial-homes run failed: $(cat "$TMP_ROOT/run.out")"
assert_equals "exited finished-idle" "$(last_decision w1:p2)" "a home absent from FM_IDLE_REAP_HOMES is still discovered"
assert_equals "$H2 partial-task exit" "$(cat "$CONTROL_LOG")" "the exit goes through the discovered home"
[ ! -s "$CLOSE_LOG" ] || fail "a home-owned pane was closed as ownerless: $(cat "$CLOSE_LOG")"
pass "FM_IDLE_REAP_HOMES adds homes and never limits discovery"

# --- 20. a home registered in data/secondmates.md is discovered --------------
# A secondmate home that is not a direct child of $HOME is found through the
# registering home's registry, so its lane is exited, never closed.
reset_run
H4="$TMP_ROOT/nested/home4"
make_home "$H4"
printf 'mate4\n' > "$H4/.fm-secondmate-home"
cat > "$H1/data/secondmates.md" <<EOF
- mate4 - nested secondmate (home: $H4; scope: nested work; projects: alpha; added 2026-08-02)
EOF
row "w1:p2|fm-nested-task|└ nested-task · p:x|claude|idle|0|$TMP_ROOT/wt-clean"
lane_meta "$H4" nested-task w1:p2 "$TMP_ROOT/wt-clean"
crew "$H4" nested-task "state: done · source: status-log · done"
FM_IDLE_REAP_NOW=$NOW run_reap --apply || fail "registry run failed: $(cat "$TMP_ROOT/run.out")"
assert_equals "exited finished-idle" "$(last_decision w1:p2)" "a registered home outside the direct \$HOME children still owns its lane"
assert_equals "$H4 nested-task exit" "$(cat "$CONTROL_LOG")" "the exit goes through the registered home"
[ ! -s "$CLOSE_LOG" ] || fail "a registered home's pane was closed as ownerless: $(cat "$CLOSE_LOG")"
pass "a home registered in data/secondmates.md is discovered and its lane is exited, not closed"
