#!/usr/bin/env bash
# Live proof: real bin/fm-spawn.sh launches a claude secondmate in an isolated
# fm-lab-* Herdr session; observe which claude the pane launched and the auth
# each launch form resolves inside a lab pane.
set -u
ROOT=/home/justin/.no-mistakes/worktrees/c7804fcd202d/01M401Q4A8T9FG4JXJ4QKHSSJV
LAB="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-wrapper-live.XXXXXX")
SESSION=$("$LAB" name wrapper-live)
export HERDR_SESSION="$SESSION"
cleanup() { herdr_safe_stop_and_delete "$SESSION"; echo "teardown rc=$?"; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
"$LAB" provision "$SESSION" >/dev/null || { echo "provision failed"; exit 1; }
echo "lab session: $SESSION (provisioned)"

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin" "$SM_HOME/data"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home\n' > "$SM_HOME/AGENTS.md"
printf 'wrapsm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial live-test secondmate charter: do nothing, wait.\n' > "$SM_HOME/data/charter.md"
ACCT=$HOME/.config/claude-accounts/account-3

echo "== bare claude resolution inside a lab pane (daemon-created shell) =="
WS=$("$LAB" run "$SESSION" workspace create --cwd "$TMP_ROOT" --label probe --no-focus)
PP=$(printf '%s' "$WS" | jq -r .result.root_pane.pane_id)
"$LAB" run "$SESSION" pane run "$PP" 'echo RESOLVED=$(command -v claude)' >/dev/null
sleep 2
"$LAB" run "$SESSION" pane read "$PP" --source recent --lines 20 | grep -a 'RESOLVED=/'

echo "== real fm-spawn: claude secondmate with CLAUDE_CONFIG_DIR=account-3 =="
CLAUDE_CONFIG_DIR="$ACCT" FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" wrapsm1 "$SM_HOME" --harness claude --secondmate --backend herdr >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
echo "fm-spawn rc=$?"; tail -3 "$TMP_ROOT/out"; tail -3 "$TMP_ROOT/err"
PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/wrapsm1.meta" | cut -d= -f2-)
echo "pane=$PANE"
sleep 10
echo "== launch command fm-spawn staged/delivered for the pane =="
grep -raoh "CLAUDE_CONFIG_DIR=[^ ]* env -u[^|]*--dangerously-skip-permissions" "$TMP_ROOT" 2>/dev/null | sed -E 's/(env -u [A-Z_]+ -u [A-Z_]+ -u [A-Z_]+).*(CLAUDE_CODE_SEND_FEEDBACK=0)/\1 ... \2/' | sort -u | head -3
echo "== pane foreground process info =="
"$LAB" run "$SESSION" pane process-info "$PANE" 2>/dev/null | jq -c '.' | cut -c1-400
"$LAB" run "$SESSION" pane read "$PANE" --source recent --lines 400 > "$TMP_ROOT/screen"
echo "== agent status of the spawned pane =="
"$LAB" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -c '.result.agent | {agent, agent_status}' 2>/dev/null
echo "== spawned pane tail =="
grep -av '^\s*$' "$TMP_ROOT/screen" | tail -12 | cut -c1-160
grep -aiq '401\|OAuth access token has expired\|Please run /login' "$TMP_ROOT/screen" && echo "AUTH ERROR SEEN" || echo "no 401/login error on the spawned pane"

echo "== /status inside the spawned secondmate claude =="
"$LAB" run "$SESSION" pane send-keys "$PANE" Enter >/dev/null; sleep 4
"$LAB" run "$SESSION" pane send-text "$PANE" "/status" >/dev/null; sleep 1
"$LAB" run "$SESSION" pane send-keys "$PANE" Enter >/dev/null; sleep 5
"$LAB" run "$SESSION" pane read "$PANE" --source recent --lines 80 | grep -aiE "auth|login|token|config|account|organization" | grep -av "^\s*$" | head -12 | cut -c1-160
echo "== auth each launch form resolves inside the lab pane (account-3) =="
"$LAB" run "$SESSION" pane run "$PP" "echo BARE; CLAUDE_CONFIG_DIR='$ACCT' claude auth status | grep -a authMethod; echo WRAPPED; CLAUDE_CONFIG_DIR='$ACCT' '$HOME/bin/claude' auth status | grep -a authMethod" >/dev/null
sleep 12
"$LAB" run "$SESSION" pane read "$PP" --source recent --lines 30 | grep -a '^BARE\|^WRAPPED\|authMethod'
