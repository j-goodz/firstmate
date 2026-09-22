#!/usr/bin/env bash
# live-wedge-lab.sh - drive the REAL bin/fm-watch.sh against a REAL tmux pane.
#
# Every scenario here runs the product the way firstmate runs it: a real tmux
# server (isolated on its own TMUX_TMPDIR socket so the operator's live tmux
# sessions are never touched), a real pane running a real shell loop, real
# state/ records, the real bin/fm-crew-state.sh reader, and the real
# supervision loop - watcher runs, exits on an actionable wake, the wake queue
# is drained and acknowledged, the watcher is re-armed - exactly as firstmate
# re-arms after each printed reason.
#
# usage: live-wedge-lab.sh <scenario> <bin-dir> <lab-dir> <run-seconds>
#
# scenarios:
#   poll-progress    healthy worker polling on a fixed cadence, byte-identical
#                    output, Pi-shaped state/<id>.progress refreshed each cycle
#                    through the real bin/fm-busy-event.sh writer
#   poll-turnended   same repeating pane, claude-shaped state/<id>.turn-ended
#                    touched at a turn boundary inside each quiet window
#   frozen           a genuinely wedged pane: prints one block, then nothing,
#                    and writes no harness marker at all
#   frozen-oldmarker a genuinely wedged pane carrying a progress marker left
#                    over from an earlier turn (nothing observed since)
#   paused-progress  a declared `paused:` external wait whose pane keeps
#                    polling and keeps refreshing its progress marker
#   write-chain      a pane whose worktree is written during the first quiet
#                    window and whose progress marker advances afterwards
set -u

SCEN=${1:?scenario}
BINDIR=${2:?bin dir}
LAB=${3:?lab dir}
RUNSECS=${4:-90}

SESSION="fm-lab-wedge-$SCEN"
TASK="crew$(printf '%s' "$SCEN" | tr -cd 'a-z')"
export TMUX_TMPDIR="$LAB/tmuxtmp"
STATE="$LAB/state"
WT="$LAB/wt"
POLL_SECS=3
ESCALATE=20
PAUSE_RESURFACE=25

rm -rf "$LAB"
mkdir -p "$STATE" "$TMUX_TMPDIR" "$WT"
chmod 700 "$TMUX_TMPDIR"

cleanup() {
  tmux kill-server 2>/dev/null || true
}
trap cleanup EXIT

# --- the pane program: a real worker, printing a byte-identical block ---------
cat > "$LAB/pane.sh" <<'PANE'
#!/usr/bin/env bash
# A healthy worker polling on a fixed cadence. Every cycle prints the SAME
# block, which is what pins the watcher's pane hash.
set -u
mode=$1; state=$2; task=$3; gen=$4; bindir=$5; wt=$6; secs=$7
block() {
  printf 'no-mistakes axi status\n'
  printf '  run 01M34XZN4KMTPTQQKZSSQYDHG0  running  step=test\n'
  printf '  gate: none pending\n'
}
case "$mode" in
  frozen|frozen-oldmarker)
    block
    sleep 100000
    ;;
  poll-progress|paused-progress)
    while true; do
      block
      "$bindir/fm-busy-event.sh" progress "$state" "$task" --gen "$gen" >/dev/null 2>&1 || true
      sleep "$secs"
    done
    ;;
  poll-turnended)
    while true; do
      block
      touch "$state/$task.turn-ended"
      sleep "$secs"
    done
    ;;
  write-chain)
    i=0
    while true; do
      block
      i=$((i + 1))
      # Writes must still be landing when the watcher opens its first quiet
      # window (the lab spends its first 75s letting the pane fill), so the
      # worktree probe is what defers that window and opens the write chain.
      # After the write phase the pane only refreshes its progress marker, so
      # every later window is deferred by the harness-progress check instead.
      if [ "$i" -le 40 ]; then
        printf 'work %s\n' "$i" > "$wt/artifact-$i.txt"
      else
        "$bindir/fm-busy-event.sh" progress "$state" "$task" --gen "$gen" >/dev/null 2>&1 || true
      fi
      sleep "$secs"
    done
    ;;
esac
PANE
chmod +x "$LAB/pane.sh"

# --- task record, exactly the shape fm-spawn.sh writes ------------------------
harness=claude
case "$SCEN" in
  poll-progress|paused-progress|write-chain) harness=pi ;;
  frozen|frozen-oldmarker) harness=cursor ;;
esac
printf 'window=%s:%s\nkind=ship\nbackend=tmux\nharness=%s\nworktree=%s\n' \
  "$SESSION" "$TASK" "$harness" "$WT" > "$STATE/$TASK.meta"

case "$SCEN" in
  paused-progress)
    printf 'paused: awaiting the upstream release cut\n' > "$STATE/$TASK.status" ;;
  *)
    printf 'working: driving no-mistakes validation\n' > "$STATE/$TASK.status" ;;
esac

# Arm the semantic busy-state record through its only writer, idle so the pane
# takes the ordinary stale path rather than the separate busy-turn bound.
GEN=$("$BINDIR/fm-busy-event.sh" arm "$STATE" "$TASK" --state idle --source fm-spawn --event launch-brief)

# Everything already on the status log was surfaced before this window opens,
# through the production signature owner.
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
  _ "$BINDIR/fm-wake-lib.sh" "$STATE" "$STATE/$TASK.status"

if [ "$SCEN" = frozen-oldmarker ]; then
  touch -t 202001010000 "$STATE/$TASK.progress"
fi

# Two scenarios need the authoritative current-state verdict to be `working`:
# the declared-wait one, because `working` is what routes a `paused:` pane into
# the wedge ladder at all (pause_state_class -> working -> wedge_timer_check),
# and the claude turn-ended one, because that is the 2026-09-22 incident's own
# shape - a provably-working validation worker whose turn-end signals are
# absorbed and whose repeating pane then accrues toward the wedge timer. The
# verdict is supplied through the product's own documented FM_CREW_STATE_BIN
# seam; everything else here - the watcher, tmux, the pane, the harness markers,
# the state records, the wake queue - is real.
CREW_BIN="$BINDIR/fm-crew-state.sh"   # the product default: the real reader
if [ "$SCEN" = paused-progress ] || [ "$SCEN" = poll-turnended ]; then
  cat > "$LAB/crew-state.sh" <<'CS'
#!/usr/bin/env bash
printf 'state: working · source: run-step · validating (running)\n'
CS
  chmod +x "$LAB/crew-state.sh"
  CREW_BIN="$LAB/crew-state.sh"
fi

tmux new-session -d -s "$SESSION" -n "$TASK" \
  "$LAB/pane.sh $SCEN $STATE $TASK $GEN $BINDIR $WT $POLL_SECS"

# Let the pane fill its viewport and reach steady state, so repeated output
# genuinely pins the hash the way it does on a long-lived crew pane.
sleep 75
tmux capture-pane -p -t "$SESSION:$TASK" -S -40 > "$LAB/pane-capture.txt"
h1=$(tmux capture-pane -p -t "$SESSION:$TASK" -S -40 | md5sum | cut -d' ' -f1)
sleep "$POLL_SECS"
h2=$(tmux capture-pane -p -t "$SESSION:$TASK" -S -40 | md5sum | cut -d' ' -f1)
sleep "$POLL_SECS"
h3=$(tmux capture-pane -p -t "$SESSION:$TASK" -S -40 | md5sum | cut -d' ' -f1)
{
  echo "scenario:        $SCEN"
  echo "watcher under test: $BINDIR/fm-watch.sh (md5 $(md5sum "$BINDIR/fm-watch.sh" | cut -d' ' -f1))"
  echo "tmux session:    $SESSION (private socket $TMUX_TMPDIR)"
  echo "harness:         $harness"
  echo "pane capture hash over three poll cycles (the wedge signal itself):"
  echo "  $h1"
  echo "  $h2"
  echo "  $h3"
  if [ "$h1" = "$h2" ] && [ "$h2" = "$h3" ]; then
    echo "  => byte-identical: the pane hash is pinned, exactly as a frozen pane pins it"
  else
    echo "  => NOT pinned (scenario setup failed)"
  fi
  echo
  echo "--- what the pane actually shows (live tmux capture, last 12 rows) ---"
  tail -12 "$LAB/pane-capture.txt"
  echo
  echo "crew-state reader: $CREW_BIN"
  echo
} > "$LAB/report.txt"

# --- the supervision loop -----------------------------------------------------
# firstmate's own cycle: run the watcher, let it exit on an actionable wake,
# drain and acknowledge the queue, re-arm. Runs for <run-seconds>.
deadline=$(( $(date +%s) + RUNSECS ))
round=0
: > "$LAB/wakes.txt"
while [ "$(date +%s)" -lt "$deadline" ]; do
  round=$((round + 1))
  left=$(( deadline - $(date +%s) ))
  [ "$left" -gt 0 ] || break
  TMUX_TMPDIR="$TMUX_TMPDIR" FM_HOME="$LAB" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_BIN="$CREW_BIN" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS="$ESCALATE" FM_PAUSE_RESURFACE_SECS="$PAUSE_RESURFACE" \
    timeout "$left" "$BINDIR/fm-watch.sh" >> "$LAB/wakes.txt" 2>>"$LAB/watch.err" || true
  # Drain and acknowledge exactly as firstmate does after a printed reason.
  err="$LAB/drain.err"
  FM_STATE_OVERRIDE="$STATE" "$BINDIR/fm-wake-drain.sh" >> "$LAB/drain.out" 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    FM_STATE_OVERRIDE="$STATE" "$BINDIR/fm-wake-drain.sh" --ack-through "$seq" \
      --recovery-generation "$gen" >/dev/null 2>&1 || true
  fi
done

{
  echo "watcher rounds run: $round over ${RUNSECS}s (escalation threshold ${ESCALATE}s)"
  echo
  echo "--- every reason the watcher printed (what firstmate would be woken for) ---"
  if [ -s "$LAB/wakes.txt" ]; then cat "$LAB/wakes.txt"; else echo "(none - the watcher never surfaced a wake)"; fi
  echo
  echo "--- wedge escalations ---"
  printf 'possible-wedge wakes: %s\n' "$(grep -c 'possible wedge' "$LAB/wakes.txt" 2>/dev/null || echo 0)"
  echo
  echo "--- watcher triage log (its own record of each absorb decision) ---"
  if [ -s "$STATE/.watch-triage.log" ]; then tail -25 "$STATE/.watch-triage.log"; else echo "(empty)"; fi
  echo
  echo "--- durable state left behind ---"
  key=$(printf '%s' "$SESSION:$TASK" | tr ':/.' '___')
  for f in ".stale-since-$key" ".wedge-escalations-$key" ".writing-since-$key" ".writing-resurfaced-$key" ".paused-resurfaced-$key"; do
    if [ -e "$STATE/$f" ]; then
      printf '%s: present (content=%s, age=%ss)\n' "$f" "$(cat "$STATE/$f" 2>/dev/null | head -c 40)" \
        "$(( $(date +%s) - $(stat -c %Y "$STATE/$f") ))"
    else
      printf '%s: absent\n' "$f"
    fi
  done
} >> "$LAB/report.txt"

cat "$LAB/report.txt"
