#!/usr/bin/env bash
# Discriminating live proof. The lab pane shell resolves bare `claude` to the
# operator's ~/bin/claude, so to tell "fm-spawn named the wrapper" apart from
# "the pane PATH happened to find it", fm-spawn runs with HOME=<fake home>
# whose bin/claude is a marker that logs, then execs the real wrapper with the
# real HOME. Case A has the marker; case B (control) has no fake wrapper.
set -u
ROOT=/home/justin/.no-mistakes/worktrees/c7804fcd202d/01M401Q4A8T9FG4JXJ4QKHSSJV
LAB="$ROOT/bin/fm-herdr-lab.sh"
REAL_HOME=$HOME
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-wrapper-marker.XXXXXX")
SESSION=$("$LAB" name wrapper-mark)
export HERDR_SESSION="$SESSION"
cleanup() { HOME=$REAL_HOME herdr_safe_stop_and_delete "$SESSION"; echo "teardown rc=$?"; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
"$LAB" provision "$SESSION" >/dev/null || { echo "provision failed"; exit 1; }
echo "lab session: $SESSION (provisioned)"
ACCT=$REAL_HOME/.config/claude-accounts/account-3
MARKLOG="$TMP_ROOT/marker.log"; : > "$MARKLOG"
# Herdr locates its session socket under HOME, so only herdr calls get the real HOME back.
SHIM="$TMP_ROOT/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\nHOME=%s exec %s "$@"\n' "$REAL_HOME" "$(command -v herdr)" > "$SHIM/herdr"; chmod +x "$SHIM/herdr"

make_homes() { # <tag>
  local t=$1
  mkdir -p "$TMP_ROOT/$t/primary/state" "$TMP_ROOT/$t/primary/config"
  printf 'off\n' > "$TMP_ROOT/$t/primary/config/herdr-presentation-spaces"
  local sm="$TMP_ROOT/$t/sm"
  mkdir -p "$sm/state" "$sm/config" "$sm/projects" "$sm/bin" "$sm/data"
  printf 'off\n' > "$sm/config/herdr-presentation-spaces"
  printf '# scratch secondmate home\n' > "$sm/AGENTS.md"
  printf '%s\n' "$2" > "$sm/.fm-secondmate-home"
  printf 'trivial live-test secondmate charter: do nothing, wait.\n' > "$sm/data/charter.md"
}

spawn_case() { # <tag> <id> <fake-home>
  local t=$1 id=$2 fh=$3 pane
  make_homes "$t" "$id"
  PATH="$SHIM:$PATH" HOME="$fh" CLAUDE_CONFIG_DIR="$ACCT" FM_SPAWN_NO_GUARD=1 FM_HOME="$TMP_ROOT/$t/primary" FM_ROOT_OVERRIDE="$ROOT" \
    "${SPAWN_SH:-$ROOT/bin/fm-spawn.sh}" "$id" "$TMP_ROOT/$t/sm" --harness claude --secondmate --backend herdr \
    >"$TMP_ROOT/$t.out" 2>"$TMP_ROOT/$t.err"
  echo "fm-spawn rc=$? :: $(grep -a '^spawned' "$TMP_ROOT/$t.out" | cut -c1-120)"; tail -3 "$TMP_ROOT/$t.err" | cut -c1-300
  pane=$(grep '^herdr_pane_id=' "$TMP_ROOT/$t/primary/state/$id.meta" | cut -d= -f2-)
  sleep 12
  echo "agent: $("$LAB" run "$SESSION" agent get "$pane" 2>/dev/null | jq -c '.result.agent | {agent, agent_status}')"
  "$LAB" run "$SESSION" pane read "$pane" --source recent --lines 200 > "$TMP_ROOT/$t.screen"
  grep -aiq '401\|OAuth access token has expired\|Please run /login' "$TMP_ROOT/$t.screen" && echo "AUTH ERROR on pane" || echo "no 401/login error on pane"
}

echo "== case A: fake HOME carries bin/claude marker wrapper =="
FH_A="$TMP_ROOT/fakehome-a"; mkdir -p "$FH_A/bin"
cat > "$FH_A/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'MARKER-WRAPPER-INVOKED argv0=%s CLAUDE_CONFIG_DIR=%s first-arg=%s\n' "\$0" "\${CLAUDE_CONFIG_DIR:-<unset>}" "\${1:-}" >> '$MARKLOG'
HOME='$REAL_HOME' exec '$REAL_HOME/bin/claude' "\$@"
EOF
chmod +x "$FH_A/bin/claude"
spawn_case a wrapa1 "$FH_A"
echo "marker log after case A:"; cat "$MARKLOG"

echo "== case B (control): fake HOME without bin/claude =="
FH_B="$TMP_ROOT/fakehome-b"; mkdir -p "$FH_B"
before=$(wc -l < "$MARKLOG")
spawn_case b wrapb1 "$FH_B"
after=$(wc -l < "$MARKLOG")
echo "marker log lines before=$before after=$after (control must not invoke the marker)"
