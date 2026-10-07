#!/usr/bin/env bash
# Behavior tests for the immediate re-arm of a Lavish poll that merely ended (browser_disconnected or a
# missing session): the runner relaunches the same source itself, bounded, with no wake and no second
# poller. Driven through the adapter's public commands and the real runner with a fake lavish-axi on PATH;
# no live Lavish server and no real board is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-rearm-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_PROCEVENT_REARM_BACKOFF_SECONDS=1

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
new_home() { mkdir -p "$1/state"; fm_test_track_procevent_home "$1"; }
new_task_endpoint() {  # <home> <task-id>
  mkdir -p "$1/state"
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$2" "$1" "$2" > "$1/state/$2.meta"
}
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }
count_results() {  # <home> <source-id>
  local g n=0
  for g in "$1/state/procevent-inbox/$2".*.result; do [ -e "$g" ] && n=$((n + 1)); done
  printf '%s\n' "$n"
}

# --- helpers ---------------------------------------------------------------
wait_for() {
  local file="$1"
  local tries="${2:-100}"
  local i=0
  while [ "$i" -lt "$tries" ]; do
    if [ -s "$file" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

ra_reset() {
  local name="$1"
  local base="$TMP_ROOT/ra-$name"
  mkdir -p "$base"
  rm -f "$base/count" "$base/times" "$base/overlap" "$base/release"
  rm -rf "$base/lock"
  export RA_COUNT="$base/count"
  export RA_TIMES="$base/times"
  export RA_LOCK="$base/lock"
  export RA_OVERLAP="$base/overlap"
  export RA_RELEASE="$base/release"
  export RA_SCRIPT=""
}

ra_polls() {
  if [ -f "$RA_COUNT" ]; then
    cat "$RA_COUNT"
  else
    echo 0
  fi
}

ra_wait_polls() {
  local n="$1"
  local tries="${2:-100}"
  local i=0
  while [ "$i" -lt "$tries" ]; do
    local polls
    polls=$(ra_polls)
    if [ "$polls" -ge "$n" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- fake lavish-axi -------------------------------------------------------
REARM2_BIN=$(fm_fakebin "$TMP_ROOT/lavish-rearm2-stub")
cat > "$REARM2_BIN/lavish-axi" <<'STUB'
#!/usr/bin/env bash
set -u

# Increment counter
if [ -f "$RA_COUNT" ]; then
  count=$(cat "$RA_COUNT")
else
  count=0
fi
count=$((count + 1))
echo "$count" > "$RA_COUNT"

# Append timestamp
date +%s.%N >> "$RA_TIMES"

# Overlap detection
lock_acquired=0
if mkdir "$RA_LOCK" 2>/dev/null; then
  lock_acquired=1
else
  echo "overlap at $(date +%s.%N)" >> "$RA_OVERLAP"
fi

# Determine action
read -ra words <<< "$RA_SCRIPT"
num_words=${#words[@]}
if [ "$num_words" -eq 0 ]; then
  word="disconnect"
else
  idx=$(( (count - 1) < num_words ? count - 1 : num_words - 1 ))
  word="${words[$idx]}"
fi

# Prepare output and exit code
output=""
exit_code=0
block_wait=0

case "$word" in
  disconnect)
    output='session:\n  file: /board.html\n  status: browser_disconnected\nnext_step: closed\n'
    exit_code=0
    ;;
  missing)
    output='error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n'
    exit_code=1
    ;;
  ended)
    output='session:\n  file: /board.html\n  status: ended\n'
    exit_code=0
    ;;
  feedback)
    output='session:\n  file: /board.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n'
    exit_code=0
    ;;
  block)
    block_wait=1
    output='session:\n  file: /board.html\n  status: browser_disconnected\nnext_step: closed\n'
    exit_code=0
    ;;
  *)
    output='session:\n  file: /board.html\n  status: browser_disconnected\nnext_step: closed\n'
    exit_code=0
    ;;
esac

# If block, wait for release (holding the lock)
if [ "$block_wait" -eq 1 ]; then
  if [ "$lock_acquired" -eq 1 ]; then
    timeout="${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}"
    start=$(date +%s)
    while [ ! -e "$RA_RELEASE" ]; do
      now=$(date +%s)
      if [ $((now - start)) -ge "$timeout" ]; then
        echo "block timeout" >&2
        exit 75
      fi
      sleep 0.05
    done
  fi
fi

# Release lock if acquired
if [ "$lock_acquired" -eq 1 ]; then
  rmdir "$RA_LOCK"
fi

# Output and exit
printf "$output"
exit "$exit_code"
STUB
chmod +x "$REARM2_BIN/lavish-axi"

# --- S1 adapter verdict ----------------------------------------------------
# --- end-user-aligned regression: S1 adapter verdict
home="$TMP_ROOT/home-1"; new_home "$home"
# Create result files for each classification
printf 'session:\n  file: /board.html\n  status: browser_disconnected\nnext_step: closed\n' > "$home/disconnect.result"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$home/missing.result"
printf 'session:\n  file: /board.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' > "$home/feedback.result"
printf 'session:\n  file: /board.html\n  status: ended\n' > "$home/ended.result"
printf 'session:\n  file: /board.html\n  status: waiting\n' > "$home/waiting.result"
printf 'garbage\n' > "$home/unknown.result"
printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n' > "$home/error.result"

# Test rearm command
if FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" rearm "$home/disconnect.result"; then pass "disconnect rearm exits 0"; else fail "disconnect rearm should exit 0"; fi
if FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" rearm "$home/missing.result"; then pass "missing rearm exits 0"; else fail "missing rearm should exit 0"; fi
if FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" rearm "$home/feedback.result"; then fail "feedback rearm should exit non-zero"; else pass "feedback rearm exits non-zero"; fi
if FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" rearm "$home/ended.result"; then fail "ended rearm should exit non-zero"; else pass "ended rearm exits non-zero"; fi
if FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" rearm "$home/waiting.result"; then fail "waiting rearm should exit non-zero"; else pass "waiting rearm exits non-zero"; fi
if FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" rearm "$home/unknown.result"; then fail "unknown rearm should exit non-zero"; else pass "unknown rearm exits non-zero"; fi
if FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" rearm "$home/error.result"; then fail "error rearm should exit non-zero"; else pass "error rearm exits non-zero"; fi

# --- S2 disconnected re-arms at once ---------------------------------------
# --- end-user-aligned regression: S2 disconnected re-arms at once
home="$TMP_ROOT/home-2"; new_home "$home"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s2"
export RA_SCRIPT="disconnect block"
export FM_PROCEVENT_REARM_MAX=5
export FM_PROCEVENT_REARM_WINDOW_SECONDS=600

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
ra_wait_polls 2 || fail "S2: poll count did not reach 2"

sleep 1
polls=$(ra_polls)
[ "$polls" -eq 2 ] || fail "S2: poll count should be 2, got $polls"
[ -e "$home/state/procevent-inbox/$id.1.handled" ] || fail "S2: handled marker missing"
count=$(count_results "$home" "$id")
[ "$count" -eq 1 ] || fail "S2: result count should be 1, got $count"
wake=$(wake_payloads "$home")
[ -z "$wake" ] || fail "S2: wake should be empty, got $wake"
[ -e "$FM_PROCEVENT_CLAIM_ROOT/$id.claim" ] || fail "S2: claim file missing"
[ -e "$home/state/procevent/$id.source" ] || fail "S2: source registration missing"
[ ! -s "$RA_OVERLAP" ] || fail "S2: overlap file should be empty"

touch "$RA_RELEASE"
pe "$home" retire "$id" >/dev/null
sleep 1

# --- S3 missing re-arms ----------------------------------------------------
# --- end-user-aligned regression: S3 missing re-arms at once
home="$TMP_ROOT/home-3"; new_home "$home"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s3"
export RA_SCRIPT="missing block"
export FM_PROCEVENT_REARM_MAX=5
export FM_PROCEVENT_REARM_WINDOW_SECONDS=600

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
ra_wait_polls 2 || fail "S3: poll count did not reach 2"

sleep 1
polls=$(ra_polls)
[ "$polls" -eq 2 ] || fail "S3: poll count should be 2, got $polls"
[ -e "$home/state/procevent-inbox/$id.1.handled" ] || fail "S3: handled marker missing"
count=$(count_results "$home" "$id")
[ "$count" -eq 1 ] || fail "S3: result count should be 1, got $count"
wake=$(wake_payloads "$home")
[ -z "$wake" ] || fail "S3: wake should be empty, got $wake"
[ -e "$FM_PROCEVENT_CLAIM_ROOT/$id.claim" ] || fail "S3: claim file missing"
[ -e "$home/state/procevent/$id.source" ] || fail "S3: source registration missing"
[ ! -s "$RA_OVERLAP" ] || fail "S3: overlap file should be empty"

touch "$RA_RELEASE"
pe "$home" retire "$id" >/dev/null
sleep 1

# --- S4 terminal results are not re-armed ----------------------------------
# --- end-user-aligned regression: S4a terminal feedback not re-armed
home="$TMP_ROOT/home-4"; new_home "$home"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s4a"
export RA_SCRIPT="feedback block"
export FM_PROCEVENT_REARM_MAX=5
export FM_PROCEVENT_REARM_WINDOW_SECONDS=600

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
wait_for "$home/state/.wake-queue" || fail "S4a: wake queue not created"
wake=$(wake_payloads "$home")
assert_contains "$wake" "procevent lavish $id 1" "S4a: wake should contain procevent lavish"
sleep 1
polls=$(ra_polls)
[ "$polls" -eq 1 ] || fail "S4a: poll count should be 1, got $polls"
pe "$home" retire "$id" >/dev/null 2>&1
sleep 1

# --- end-user-aligned regression: S4b ended not re-armed
home="$TMP_ROOT/home-5"; new_home "$home"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s4b"
export RA_SCRIPT="ended block"

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
for i in $(seq 1 100); do
  [ ! -e "$home/state/procevent/$id.source" ] && break
  sleep 0.1
done
[ ! -e "$home/state/procevent/$id.source" ] || fail "S4b: source registration still exists"
polls=$(ra_polls)
[ "$polls" -eq 1 ] || fail "S4b: poll count should be 1, got $polls"

# --- S5 cap and backoff ---------------------------------------------------
# --- end-user-aligned regression: S5 cap and backoff
home="$TMP_ROOT/home-6"; new_home "$home"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s5"
export RA_SCRIPT="disconnect"
export FM_PROCEVENT_REARM_MAX=3
export FM_PROCEVENT_REARM_WINDOW_SECONDS=600

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
rearm_record="$home/state/procevent/.$id.rearm"
for i in $(seq 1 300); do
  if [ -f "$rearm_record" ]; then
    third=$(awk '{print $3}' "$rearm_record")
    if [ "$third" -ne 0 ]; then
      break
    fi
  fi
  sleep 0.1
done
[ -f "$rearm_record" ] || fail "S5: rearm record not created"
third=$(awk '{print $3}' "$rearm_record")
[ "$third" -ne 0 ] || fail "S5: third field should be non-zero"

sleep 2
polls=$(ra_polls)
[ "$polls" -eq 4 ] || fail "S5: poll count should be 4, got $polls"

# Check gaps between poll start times
gaps=$(awk 'NR>1{diff=$1-prev; if(diff<0)diff=-diff; print diff; prev=$1} NR==1{prev=$1}' "$RA_TIMES")
gap2=$(echo "$gaps" | sed -n '2p')
gap3=$(echo "$gaps" | sed -n '3p')
awk -v g2="$gap2" 'BEGIN{exit !(g2 >= 0.9)}' || fail "S5: gap2 should be >= 0.9, got $gap2"
awk -v g3="$gap3" 'BEGIN{exit !(g3 >= 1.9)}' || fail "S5: gap3 should be >= 1.9, got $gap3"

rearm_jsonl="$home/state/procevent-rearm.jsonl"
rearmed_count=$(grep -c '"action":"rearmed"' "$rearm_jsonl")
[ "$rearmed_count" -eq 3 ] || fail "S5: expected 3 rearm lines, got $rearmed_count"
gaveup_count=$(grep -c '"action":"gave-up"' "$rearm_jsonl")
[ "$gaveup_count" -eq 1 ] || fail "S5: expected 1 gave-up line, got $gaveup_count"

[ -e "$home/state/procevent/$id.source" ] || fail "S5: source registration missing"
[ ! -s "$RA_OVERLAP" ] || fail "S5: overlap file should be empty"
wake=$(wake_payloads "$home")
[ -z "$wake" ] || fail "S5: wake should be empty"

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1
ra_wait_polls 5 || fail "S5: poll count did not reach 5"
polls=$(ra_polls)
[ "$polls" -eq 5 ] || fail "S5: poll count should be 5 after reconcile, got $polls"

pe "$home" retire "$id" >/dev/null
sleep 1

# --- S6 window reset ------------------------------------------------------
# --- end-user-aligned regression: S6 window reset
home="$TMP_ROOT/home-7"; new_home "$home"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s6"
export RA_SCRIPT="disconnect"
export FM_PROCEVENT_REARM_MAX=1
export FM_PROCEVENT_REARM_WINDOW_SECONDS=4

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
ra_wait_polls 2 || fail "S6: poll count did not reach 2"
rearm_record="$home/state/procevent/.$id.rearm"
for i in $(seq 1 100); do
  if [ -f "$rearm_record" ]; then
    third=$(awk '{print $3}' "$rearm_record")
    [ "$third" -ne 0 ] && break
  fi
  sleep 0.1
done
[ -f "$rearm_record" ] || fail "S6: rearm record not created"
third=$(awk '{print $3}' "$rearm_record")
[ "$third" -ne 0 ] || fail "S6: third field should be non-zero"

sleep 5
PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1
ra_wait_polls 4 || fail "S6: poll count did not reach 4"
polls=$(ra_polls)
[ "$polls" -ge 4 ] || fail "S6: poll count should be >= 4, got $polls"

pe "$home" retire "$id" >/dev/null
sleep 1

# --- S7 missing beyond cap falls back -------------------------------------
# --- end-user-aligned regression: S7 missing beyond cap falls back
home="$TMP_ROOT/home-8"; new_home "$home"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s7"
export RA_SCRIPT="missing"
export FM_PROCEVENT_REARM_MAX=1
export FM_PROCEVENT_REARM_WINDOW_SECONDS=600

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
wait_for "$home/state/.wake-queue" || fail "S7: wake queue not created"
wake=$(wake_payloads "$home")
assert_contains "$wake" "procevent lavish $id " "S7: wake should contain procevent lavish"

polls=$(ra_polls)
[ "$polls" -eq 2 ] || fail "S7: poll count should be 2, got $polls"
[ ! -e "$home/state/procevent/$id.source" ] || fail "S7: source registration still exists"
assert_contains "$wake" "procevent lavish $id 2" "S7: wake should contain sequence 2"
[ ! -e "$home/state/procevent-inbox/$id.2.handled" ] || fail "S7: $id.2.handled should not exist"
[ -e "$home/state/procevent-inbox/$id.1.handled" ] || fail "S7: $id.1.handled should exist"

pe "$home" retire "$id" >/dev/null 2>&1
sleep 1

# --- S8 task-owned board --------------------------------------------------
# --- end-user-aligned regression: S8 task-owned board
home="$TMP_ROOT/home-9"; new_home "$home"
new_task_endpoint "$home" "worker-ra"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s8"
export RA_SCRIPT="disconnect block"
export FM_PROCEVENT_REARM_MAX=5
export FM_PROCEVENT_REARM_WINDOW_SECONDS=600

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art" --for worker-ra
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

cp "$home/state/procevent/$id.source" "$TMP_ROOT/ra-reg-before"

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
ra_wait_polls 2 || fail "S8: poll count did not reach 2"

cmp -s "$home/state/procevent/$id.source" "$TMP_ROOT/ra-reg-before" || fail "S8: registration changed"
[ -e "$home/state/procevent-inbox/$id.1.handled" ] || fail "S8: handled marker missing"
[ -e "$home/state/procevent-inbox/$id.1.owner-task" ] || fail "S8: owner-task marker missing"

inbox_dir="$home/state/worker-ra.inbox"
if [ -d "$inbox_dir" ]; then
  for msg in "$inbox_dir"/*.msg; do
    [ -e "$msg" ] && fail "S8: unexpected msg file in inbox: $msg"
  done
fi

wake=$(wake_payloads "$home")
[ -z "$wake" ] || fail "S8: wake should be empty"
count=$(count_results "$home" "$id")
[ "$count" -eq 1 ] || fail "S8: result count should be 1, got $count"
[ ! -s "$RA_OVERLAP" ] || fail "S8: overlap file should be empty"

touch "$RA_RELEASE"
pe "$home" retire "$id" >/dev/null
sleep 1

# --- S9 retire during backoff stops re-arm --------------------------------
# --- end-user-aligned regression: S9 retire during backoff stops re-arm
home="$TMP_ROOT/home-10"; new_home "$home"
art="$home/artifact.html"
printf '<h1>test</h1>\n' > "$art"

ra_reset "s9"
export RA_SCRIPT="disconnect"
export FM_PROCEVENT_REARM_MAX=5
export FM_PROCEVENT_REARM_WINDOW_SECONDS=600
export FM_PROCEVENT_REARM_BACKOFF_SECONDS=3

PATH="$REARM2_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" arm "$art"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")

PATH="$REARM2_BIN:$PATH" pe "$home" reconcile >/dev/null 2>&1 &
ra_wait_polls 2 || fail "S9: poll count did not reach 2"

pe "$home" retire "$id" >/dev/null
sleep 4

polls=$(ra_polls)
[ "$polls" -eq 2 ] || fail "S9: poll count should be 2, got $polls"
[ ! -e "$FM_PROCEVENT_CLAIM_ROOT/$id.claim" ] || fail "S9: claim file should be gone"

sleep 1

printf '\nall procevent rearm tests passed\n'
