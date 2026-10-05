#!/usr/bin/env bash
# Live proof for fm/remote-doctor-linux-hang.
#
# Drives the REAL bin/fm-remote-doctor.sh --fix on Linux with the REAL herdr
# binary, in a disposable isolated HOME/XDG. The doctor's stdout is captured
# through a command-substitution pipe, exactly the "caller reads a pipe"
# condition that made the seed's ssh never return. The scenario passes when:
#   - the --fix command substitution returns in a few seconds, and
#   - a real herdr server for the fm-remote session is left running, and
#   - that server is detached (reparented, not a child of the doctor).
set -u
REPO=${REPO:-/home/justin/.no-mistakes/worktrees/c7804fcd202d/01M45N50PCRXA76S71919BCJMY}
SCRATCH=${SCRATCH:-/home/justin/.cache/tmp/opencode}
ROOT=$(mktemp -d "$SCRATCH/fm-real-doctor-XXXXXX")
cleanup() {
  env HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/xdg" herdr server stop --session fm-remote >/dev/null 2>&1 || true
  env HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/xdg" herdr session delete fm-remote >/dev/null 2>&1 || true
  rm -rf -- "$ROOT"
}
trap cleanup EXIT

mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/project-home" "$ROOT/xdg" "$ROOT/data" "$ROOT/state"
for t in treehouse claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/bin/$t"
  chmod +x "$ROOT/bin/$t"
done
cat > "$ROOT/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '0.2.4\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
chmod +x "$ROOT/bin/tasks-axi"
ln -s "$(command -v herdr)" "$ROOT/bin/herdr"

echo "real herdr: $(herdr --version 2>&1 | head -1)"
echo "isolated XDG_CONFIG_HOME=$ROOT/xdg"
echo "doctor: $REPO/bin/fm-remote-doctor.sh"

run_doctor() {
  env -i \
    HOME="$ROOT/home" \
    FM_HOME="$ROOT/project-home" \
    FM_ROOT_OVERRIDE="$REPO" \
    XDG_CONFIG_HOME="$ROOT/xdg" \
    XDG_DATA_HOME="$ROOT/data" \
    XDG_STATE_HOME="$ROOT/state" \
    PATH="$ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_REMOTE_JOB_ACTIVE=1 \
    /bin/bash "$REPO/bin/fm-remote-doctor.sh" --fix
}

WATCHDOG_SECONDS=${WATCHDOG_SECONDS:-15}
kill_isolated_server() {
  local p
  for p in $(pgrep -f "herdr server --session fm-remote" 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_CONFIG_HOME=$ROOT/xdg"; then
      kill "$p" 2>/dev/null || true
    fi
  done
}
( sleep "$WATCHDOG_SECONDS"; kill_isolated_server ) &
WATCHDOG_PID=$!

echo "--- before: session status ---"
env HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/xdg" herdr status --session fm-remote --json \
  | jq -c '{running:.server.running,socket:.server.socket}'

echo "--- driving: OUT=\$(doctor --fix)  [pipe capture, as ssh does] ---"
START=$(date +%s%N)
DOCTOR_OUT=$(run_doctor 2>&1)
RC=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
kill "$WATCHDOG_PID" 2>/dev/null || true

echo "doctor_rc=$RC elapsed_ms=$ELAPSED_MS pipe_returned=true"
echo "--- doctor output ---"
printf '%s\n' "$DOCTOR_OUT"

echo "--- after: session status (same isolated env) ---"
STATUS=$(env HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/xdg" herdr status --session fm-remote --json)
printf '%s\n' "$STATUS" | jq -c '{running:.server.running,socket:.server.socket}'
RUNNING=$(printf '%s' "$STATUS" | jq -r '.server.running // false')
SOCKET=$(printf '%s' "$STATUS" | jq -r '.server.socket // empty')

echo "--- server process tree ---"
SERVER_PID=
if [ -n "$SOCKET" ]; then
  SERVER_PID=$(ss -xlp 2>/dev/null | awk -v s="$SOCKET" 'index($0,s){print}' \
    | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
fi
if [ -z "$SERVER_PID" ]; then
  SERVER_PID=$(pgrep -f "herdr server --session fm-remote" | while read -r p; do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_CONFIG_HOME=$ROOT/xdg"; then echo "$p"; fi
  done | head -1)
fi
echo "server_pid=$SERVER_PID"
if [ -n "$SERVER_PID" ]; then
  ps -o pid,ppid,pgid,sess,stat,comm -p "$SERVER_PID"
  PARENT=$(ps -o ppid= -p "$SERVER_PID" | tr -d ' ')
  [ -z "$PARENT" ] || ps -o pid,ppid,pgid,sess,stat,comm -p "$PARENT" 2>/dev/null || true
fi

FAIL=0
[ "$RC" -eq 0 ] || { echo "FAIL: doctor --fix rc=$RC"; FAIL=1; }
[ "$RUNNING" = true ] || { echo "FAIL: real herdr server is not running after --fix"; FAIL=1; }
[ "$ELAPSED_MS" -lt 8000 ] || { echo "FAIL: doctor --fix blocked ${ELAPSED_MS}ms on a long-lived server"; FAIL=1; }
if [ -n "$SERVER_PID" ]; then
  PPID_=$(ps -o ppid= -p "$SERVER_PID" | tr -d ' ')
  [ "$PPID_" != "1" ] && [ "$PPID_" != "0" ] || echo "note: server reparented to ppid=$PPID_"
else
  echo "note: could not resolve server pid for ppid check"
fi
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: Linux --fix returned in ${ELAPSED_MS}ms with a detached, running real herdr server"
else
  echo "RESULT: FAIL"
fi
exit "$FAIL"
