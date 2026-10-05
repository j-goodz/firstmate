#!/usr/bin/env bash
# Behavior tests for bin/fm-calls-page.sh, the captain's open-calls page that is
# generated from the live captain-hold records: which calls render, how they
# group, how a saved answer maps onto bin/fm-captain-hold.sh, and the
# best-effort re-render that every captain-hold mutation runs.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

CALLS="$ROOT/bin/fm-calls-page.sh"
TMP_ROOT=$(fm_test_tmproot fm-calls-page)
TODAY=2026-10-04

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' "$home"
}

# The local fixture backlog: open calls in two projects, one with a
# call-options block, a work item held for the captain, a hold whose park date
# has passed, a hold parked into the future, a non-captain hold, a call the
# status log already reads as answered, and an answered (Done) call.
write_local_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] w1 - Ship the widget (repo: nexus) (kind: ship) (since 2026-10-01) (hold: Approve the widget shape before build) (hold-kind: captain)
  Captain hold set: 2026-10-01T10:00:00Z
## Queued
- [ ] a1 - Pick the mouse path (repo: nexus) (kind: captain) (since 2026-10-02) (hold: Which mouse software should run on legion) (hold-kind: captain)
  Captain hold set: 2026-10-02T10:00:00Z

  call-options:
  - Keep Logi Options
  - Switch to Solaar
  Origin: mouse-scout
- [ ] e1 - Expired park call (repo: marketwatch) (kind: captain) (since 2026-09-20) (hold: Parked earlier and now due) (hold-kind: captain) (hold-until: 2026-10-01)
  Captain hold set: 2026-09-20T10:00:00Z
- [ ] p1 - Future parked call (repo: nexus) (kind: captain) (since 2026-09-20) (hold: Parked by the captain) (hold-kind: captain) (hold-until: 2026-10-12)
  Captain hold set: 2026-09-20T10:00:00Z
- [ ] x1 - Waiting on upstream (repo: nexus) (kind: ship) (since 2026-10-01) (hold: upstream release)
- [ ] v1 - Chat answered call (repo: nexus) (kind: captain) (since 2026-10-01) (hold: answered in chat already) (hold-kind: captain)
  Captain hold set: 2026-10-01T10:00:00Z
## Done
- [x] d1 - Answered call (repo: nexus) (kind: captain) (since 2026-09-01) (done 2026-10-03)
EOF
  printf '%s\n' 'needs-decision [key=v1]: which way' 'resolved [key=v1]: answered: left' \
    > "$1/state/origin.status"
}

# A remote secondmate route plus the backlog the stubbed transport serves for it.
add_remote_mate() {  # <home>
  local home=$1
  cat > "$home/data/secondmates.md" <<'EOF'
# Second mates

- swiftmate - Heavy work on swift. (host: swift; root: /srv/firstmate; home: /srv/swiftmate-home; scope: heavy build work; projects: nexus, buzz; added 2026-09-26)
EOF
  mkdir -p "$home/remote-swiftmate"
  cat > "$home/remote-swiftmate/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] r1 - Buzz calendar shape (repo: buzz) (kind: captain) (since 2026-10-02) (hold: Approve the calendar layout) (hold-kind: captain)
  Captain hold set: 2026-10-02T10:00:00Z
- [ ] r2 - Buzz answered in chat (repo: buzz) (kind: captain) (since 2026-10-02) (hold: Already answered through the parent) (hold-kind: captain)
  Captain hold set: 2026-10-02T10:00:00Z
- [ ] r3 - Buzz parked and answered (repo: buzz) (kind: captain) (since 2026-10-02) (hold: Parked but already answered) (hold-kind: captain) (hold-until: 2026-10-20)
  Captain hold set: 2026-10-02T10:00:00Z
## Done
EOF
  printf '%s\n' \
    'needs-decision [key=captain-hold-r1-1]: captain hold r1: Approve the calendar layout' \
    'needs-decision [key=captain-hold-r2-1]: captain hold r2: Already answered' \
    'resolved [key=captain-hold-r2-1]: answered: yes' \
    'needs-decision [key=captain-hold-r3-1]: captain hold r3: Parked but already answered' \
    'resolved [key=captain-hold-r3-1]: answered: yes' \
    > "$home/state/swiftmate.status"
}

# Stub transport standing in for bin/fm-on.sh: it serves the fixture remote
# backlog and logs every other remote command with its stdin.
write_fm_on_stub() {  # <home>
  local home=$1
  cat > "$home/fm-on-stub.sh" <<'SH'
#!/usr/bin/env bash
stdin_mode=0
if [ "${1:-}" = --stdin ]; then stdin_mode=1; shift; fi
route=$1; cmd=$2; shift 2
if [ -n "${FM_TEST_ON_FAIL:-}" ]; then echo "ssh: connect to host swift: No route to host" >&2; exit 255; fi
if [ "$cmd" = fm-remote-file.sh ] && [ "${1:-}" = get ] && [ "${2:-}" = data/backlog.md ]; then
  cat "$FM_TEST_REMOTE_DIR/backlog.md"
  exit 0
fi
{
  printf 'ON %s %s' "$route" "$cmd"
  printf ' [%s]' "$@"
  printf '\n'
  if [ "$stdin_mode" = 1 ]; then sed 's/^/STDIN /'; fi
} >> "$FM_TEST_LOG"
SH
  chmod +x "$home/fm-on-stub.sh"
}

# Stub captain-hold standing in for bin/fm-captain-hold.sh during apply: it
# passes the read-only divergence question to the real script and logs
# mutations instead of performing them.
write_captain_stub() {  # <home>
  local home=$1
  cat > "$home/captain-stub.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = diverged ] && exec "$FM_TEST_REAL_CAPTAIN" diverged
{
  printf 'HOLD'
  printf ' [%s]' "$@"
  printf '\n'
  prev=
  for a in "$@"; do
    if [ "$prev" = --decision-file ]; then sed 's/^/DECISION /' "$a"; fi
    prev=$a
  done
} >> "$FM_TEST_LOG"
SH
  chmod +x "$home/captain-stub.sh"
}

# Stub second-mate send standing in for bin/fm-send.sh: it logs the target and
# message so routing is asserted without a real backend.
write_fm_send_stub() {  # <home>
  local home=$1
  cat > "$home/fm-send-stub.sh" <<'SH'
#!/usr/bin/env bash
printf 'SEND [%s]\n' "$*" >> "$FM_TEST_LOG"
SH
  chmod +x "$home/fm-send-stub.sh"
}

run_calls_at() {  # <home> <now> <args...>
  local home=$1 now=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_CALLS_PAGE_TODAY=$TODAY FM_CALLS_PAGE_NOW="$now" \
    FM_CALLS_PAGE_FM_ON="$home/fm-on-stub.sh" \
    FM_CALLS_PAGE_FM_SEND="$home/fm-send-stub.sh" \
    FM_TEST_REMOTE_DIR="$home/remote-swiftmate" FM_TEST_LOG="$home/calls.log" \
    "$CALLS" "$@"
}

run_calls() {  # <home> <args...>
  local home=$1
  shift
  run_calls_at "$home" 2026-10-04T21:00:00Z "$@"
}

page_of() { printf '%s/data/open-calls/calls.html\n' "$1"; }

# Line number of the first match, for ordering assertions.
line_of() {  # <file> <fixed-string>
  grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1
}

# --- render: inclusion, exclusion, grouping ---------------------------------

H=$(make_home render)
write_local_backlog "$H"
add_remote_mate "$H"
write_fm_on_stub "$H"
out=$(run_calls "$H" render 2>"$H/err"); rc=$?
PAGE=$(page_of "$H")
expect_code 0 "$rc" "render succeeds"
assert_present "$PAGE" "render writes data/open-calls/calls.html"
for id in a1 w1 e1; do
  assert_grep "data-call=\"$id\" data-home=\"local\"" "$PAGE" "open local call $id renders as a card"
done
assert_grep 'data-call="r1" data-home="swiftmate"' "$PAGE" "open second-mate call renders with its owning home"
assert_no_grep 'data-call="r2"' "$PAGE" "a second-mate call whose latest captain-hold record is resolved never renders"
assert_no_grep 'data-call="r3"' "$PAGE" "a resolved second-mate call is not listed even while its park date is still in the future"
assert_no_grep 'data-call="v1"' "$PAGE" "a local call the status log reads as already answered never renders"
assert_no_grep 'data-call="d1"' "$PAGE" "an answered call never renders"
assert_no_grep 'data-call="x1"' "$PAGE" "a hold that is not the captain's never renders"
assert_no_grep 'data-call="p1" data-home=' "$PAGE" "a call parked into the future is not a card"
assert_grep 'class="parked-call" data-call="p1"' "$PAGE" "a parked call is listed in the parked list"
assert_grep 'Oct 12' "$PAGE" "a parked call shows its date"
assert_contains "$out" "open=4 parked=1" "render reports open and parked counts"
assert_grep '4 open' "$PAGE" "header shows the open count"
assert_grep '1 parked' "$PAGE" "header shows the parked count"
assert_grep '2026-10-04 21:00 UTC' "$PAGE" "header shows the build time"
assert_no_grep ' checked' "$PAGE" "nothing is pre-selected"
# Project sections run newest call first, each call under its own project.
b=$(line_of "$PAGE" 'data-project="buzz"')
m=$(line_of "$PAGE" 'data-project="marketwatch"')
n=$(line_of "$PAGE" 'data-project="nexus"')
if [ -n "$b" ] && [ -n "$m" ] && [ -n "$n" ] && [ "$n" -lt "$b" ] && [ "$b" -lt "$m" ]; then
  pass "project sections run newest call first"
else
  fail "project sections run newest call first (buzz=$b marketwatch=$m nexus=$n)"
fi
e=$(line_of "$PAGE" 'data-call="e1"'); a=$(line_of "$PAGE" 'data-call="a1"')
if [ "$e" -gt "$m" ] && [ "$a" -gt "$n" ]; then
  pass "each call renders under its own project"
else
  fail "each call renders under its own project (e1=$e a1=$a)"
fi
# Card content: options from the call-options block, the shared choices.
assert_grep 'value="Keep Logi Options"' "$PAGE" "call-options lines become radio options"
assert_grep 'value="Switch to Solaar"' "$PAGE" "every call-options line becomes an option"
assert_grep 'Which mouse software should run on legion' "$PAGE" "the hold reason is the card context"
later=$(grep -c 'value="__later__"' "$PAGE")
notneeded=$(grep -c 'value="__not_needed__"' "$PAGE")
talk=$(grep -c 'value="__talk__"' "$PAGE")
assert_equals "4" "$talk" "every card offers Let's talk"
assert_equals "4" "$later" "every card offers Later, park one week"
assert_equals "4" "$notneeded" "every card offers Not needed, close it"
assert_grep 'Save this answer' "$PAGE" "each card has its own save button"
assert_grep 'Asked Oct 2' "$PAGE" "each card shows when the call was asked"
assert_grep 'data-sort="newest"' "$PAGE" "the page offers the Newest sort"
assert_grep 'data-sort="project"' "$PAGE" "the page offers the By project sort"
assert_no_grep 'held by swiftmate' "$PAGE" "cards carry no internal home line"
assert_no_grep 'task a1' "$PAGE" "cards carry no internal task id line"
assert_grep 'open-call-answer.v1' "$PAGE" "saves carry the open-call-answer.v1 schema"
assert_grep 'width=device-width' "$PAGE" "the page is mobile first"
if [ -z "$(find "$H/data/open-calls" -name '*.tmp*' -print)" ]; then
  pass "render leaves no temporary file behind"
else
  fail "render leaves no temporary file behind"
fi
pass "render includes open calls and excludes answered, parked, and non-captain holds"

# --- render: curated groups --------------------------------------------------

cat > "$H/data/open-calls/calls.json" <<'EOF'
[
  {"project": "Nexus", "feature": "Mouse software", "context": "Legion runs Logi Options today and it crashes on wake.",
   "calls": [
     {"id": "a1", "home": "local", "question": "Which mouse software should legion run?",
      "options": [{"value": "keep", "label": "Keep Logi Options", "detail": "No change"},
                  {"value": "solaar", "label": "Switch to Solaar", "detail": "Open source"}],
      "recommendation": "solaar"},
     {"id": "w1", "home": "local", "question": "Approve the widget shape?"},
     {"id": "gone1", "home": "local", "question": "This call is no longer held"}
   ]}
]
EOF
run_calls "$H" render >/dev/null 2>&1
shared_count=$(grep -c '<details class="shared">' "$PAGE")
assert_equals "1" "$shared_count" "a curated feature's long context folds once above its cards"
assert_grep '<details class="shared"><summary>Why this is asked</summary>' "$PAGE" "the feature context is folded, collapsed by default"
assert_grep 'Which mouse software should legion run?' "$PAGE" "the curated question replaces the task title"
assert_grep 'Mouse software' "$PAGE" "the curated feature heading renders"
assert_grep 'Open source' "$PAGE" "a curated option's detail renders"
assert_grep 'Suggested' "$PAGE" "the recommendation is marked"
assert_no_grep ' checked' "$PAGE" "the recommendation is never pre-selected"
assert_no_grep 'This call is no longer held' "$PAGE" "a curated call that is no longer held never renders"
assert_grep 'data-call="e1"' "$PAGE" "a held call missing from the curated file still renders"
f=$(line_of "$PAGE" 'Mouse software'); a=$(line_of "$PAGE" 'data-call="a1"'); w=$(line_of "$PAGE" 'data-call="w1"')
if [ -n "$f" ] && [ "$a" -gt "$f" ] && [ "$w" -gt "$f" ]; then
  pass "curated calls render under their feature group with one shared context"
else
  fail "curated calls render under their feature group (feature=$f a1=$a w1=$w)"
fi
# The curated file may also be an object with a groups array, naming homes by
# machine; an id open in exactly one home still finds its card.
cat > "$H/data/open-calls/calls.json" <<'EOF'
{"schema": "calls-regroup.v1", "groups": [
  {"project": "Buzz", "feature": "Calendar", "context": "One calendar for every agent.",
   "calls": [{"id": "r1", "home": "swift", "question": "Which calendar should Buzz show?",
              "options": [{"value": "google", "label": "Google calendar", "detail": "Shared"}],
              "recommendation": null, "his_prior_words": "2026-09-28: we can use google calendar"}]}
]}
EOF
run_calls "$H" render >/dev/null 2>&1
assert_grep 'Which calendar should Buzz show?' "$PAGE" "a groups-object curated file is read"
assert_grep 'data-call="r1" data-home="swiftmate"' "$PAGE" "a curated call named by machine keeps its owning home"
assert_grep '<details class="prior"><summary>You said earlier</summary>' "$PAGE" "the captain's earlier words fold above the question"
assert_grep '2026-09-28: we can use google calendar' "$PAGE" "the captain's earlier words show above the question"
pass "a curated groups object with machine-named homes renders"
rm -f "$H/data/open-calls/calls.json"

# --- render: unreachable second mate -----------------------------------------

FM_TEST_ON_FAIL=1 run_calls "$H" render >/dev/null 2>"$H/err"; rc=$?
expect_code 0 "$rc" "render still writes the page when a second mate is unreachable"
assert_grep 'Could not read' "$PAGE" "the page says which home could not be read"
assert_grep 'data-call="a1"' "$PAGE" "local calls still render when a second mate is unreachable"
assert_contains "$(cat "$H/err")" "swiftmate" "the unreachable home is reported"
pass "an unreachable second mate is disclosed without losing local calls"

# --- render: large backlog ----------------------------------------------------

L=$(make_home large)
write_local_backlog "$L"
{
  printf '\n'
  i=0
  while [ "$i" -lt 900 ]; do
    printf -- '- [x] filler-%s - Filler task number %s with a long enough title to grow the backlog file well past the argument limit (repo: nexus) (kind: ship) (since 2026-01-01) (done 2026-01-02)\n' "$i" "$i"
    i=$((i + 1))
  done
} >> "$L/data/backlog.md"
write_fm_on_stub "$L"
run_calls "$L" render >/dev/null 2>"$L/err"; rc=$?
expect_code 0 "$rc" "render reads a backlog larger than one command argument"
assert_grep 'data-call="a1"' "$(page_of "$L")" "a large backlog still yields its open calls"
pass "render reads a large backlog"

# --- --if-present -------------------------------------------------------------

N=$(make_home ifpresent)
write_local_backlog "$N"
run_calls "$N" render --if-present >/dev/null 2>&1; rc=$?
expect_code 0 "$rc" "render --if-present is a quiet no-op without a page"
assert_absent "$(page_of "$N")" "render --if-present never creates the page"
pass "render --if-present never creates a page"

# --- apply ---------------------------------------------------------------------

A=$(make_home apply)
write_local_backlog "$A"
add_remote_mate "$A"
write_fm_on_stub "$A"
write_captain_stub "$A"
write_fm_send_stub "$A"
run_calls "$A" render >/dev/null 2>&1
cat > "$A/result.txt" <<'EOF'
session:
  file: /tmp/calls.html
  status: feedback
prompts[8]{uid,prompt,selector,tag,text}:
  "1","Call a1: Switch to Solaar\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"a1\",\n  \"home\": \"local\",\n  \"kind\": \"option\",\n  \"value\": \"solaar\",\n  \"answer\": \"Switch to Solaar\",\n  \"note\": \"and remove Logi\"\n}","form",call-answer,"Pick the mouse path"
  "2","Call w1: text\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"w1\",\n  \"home\": \"local\",\n  \"kind\": \"text\",\n  \"answer\": \"\",\n  \"note\": \"Build it narrower\"\n}","form",call-answer,"Ship the widget"
  "3","Call e1: later\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"e1\",\n  \"home\": \"local\",\n  \"kind\": \"later\",\n  \"answer\": \"Later, park one week\",\n  \"note\": \"\"\n}","form",call-answer,"Expired park call"
  "4","Call r1: not needed\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"r1\",\n  \"home\": \"swiftmate\",\n  \"kind\": \"not-needed\",\n  \"answer\": \"Not needed, close it\",\n  \"note\": \"\"\n}","form",call-answer,"Buzz calendar shape"
  "5","Call v1: text\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"v1\",\n  \"home\": \"local\",\n  \"kind\": \"text\",\n  \"answer\": \"\",\n  \"note\": \"answered twice\"\n}","form",call-answer,"Chat answered call"
  "6","Call a1: reconcile\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"a1\",\n  \"home\": \"local\",\n  \"kind\": \"text\",\n  \"answer\": \"\",\n  \"note\": \"reconcile\"\n}","form",call-answer,"Pick the mouse path"
  "7","Freeform words only","body",note,"Your open calls"
  "8","Call e1: talk\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"e1\",\n  \"home\": \"local\",\n  \"kind\": \"talk\",\n  \"answer\": \"Let us talk\",\n  \"note\": \"call me\"\n}","form",call-answer,"Expired park call"
EOF
out=$(FM_CALLS_PAGE_CAPTAIN_HOLD="$A/captain-stub.sh" FM_TEST_REAL_CAPTAIN="$ROOT/bin/fm-captain-hold.sh" run_calls "$A" apply "$A/result.txt" 2>"$A/err"); rc=$?
LOG=$(cat "$A/calls.log" 2>/dev/null)
expect_code 0 "$rc" "apply succeeds when every item is handled or reported"
# An option answer on a call-only task closes it with the captain's words.
assert_contains "$LOG" "HOLD [answer] [a1] [--decision-file]" "an option answer records through answer"
assert_not_contains "$(grep -F 'HOLD [answer] [a1]' <<<"$LOG")" "--release" "a call-only task closes rather than releases"
assert_contains "$LOG" "DECISION Answer: Switch to Solaar" "the decision records the chosen option"
assert_contains "$LOG" "and remove Logi" "the decision keeps the captain's own words"
# A text answer on a held work item releases the hold so the work resumes.
assert_not_contains "$LOG" "HOLD [answer] [w1]" "typed words with no option picked never close or release the call"
assert_contains "$(grep -F 'HOLD [hold] [w1]' <<<"$LOG")" "Build it narrower" "typed words re-hold the call with the captain's words"
assert_contains "$out" "route: local/w1 Build it narrower" "typed words are routed to firstmate"
# Later parks the call for one week.
assert_contains "$LOG" "HOLD [hold] [e1] [--reason]" "Later re-holds the call"
assert_contains "$(grep -F 'HOLD [hold] [e1]' <<<"$LOG")" "[--until] [2026-10-11]" "Later parks it until today plus seven days"
# Not needed on a remote call closes it in the owning home over the transport.
assert_contains "$LOG" "ON swiftmate fm-captain-hold.sh [answers] [--source]" "a remote answer goes to the owning home's keyed intake"
assert_contains "$LOG" "$(printf 'STDIN r1\tNot needed\t\tdone')" "Not needed closes the remote call"
# A call that is no longer open is skipped, never re-answered.
assert_not_contains "$LOG" "[v1]" "an already-answered call is never re-applied"
assert_contains "$out" "skipped: local/v1" "the skip is reported"
# The reserved value reconcile is never applied.
a1_count=$(grep -c -F 'HOLD [answer] [a1]' <<<"$LOG")
assert_equals "1" "$a1_count" "the reserved value reconcile is never applied"
assert_contains "$out" "refused: local/a1" "the reconcile item is reported as refused"
# Let's talk with the captain's words re-holds the call with those words and
# routes it to firstmate; it never closes or releases the call.
assert_contains "$LOG" "Captain asked to talk first on 2026-10-04: call me" "Let's talk records the captain's words on the call"
assert_contains "$out" "route: local/e1 call me" "Let's talk routes the captain's words to firstmate"
assert_contains "$out" "route: local/a1 Switch to Solaar" "a local answer prints a route line"
assert_contains "$out" "route: swiftmate/r1 Not needed" "a second-mate answer prints a route line"
assert_contains "$LOG" "SEND [fm-swiftmate Call r1: Not needed]" "a second-mate answer is sent to that mate through fm-send"
assert_not_contains "$LOG" "SEND [fm-local" "a local answer is not sent as a second-mate message"
assert_contains "$out" "rendered:" "apply re-renders the page"
pass "apply maps option, text, Later, and Not needed answers onto the owning home's captain-hold record"

# --- apply: a second-mate answer is always delivered, and retried if it was not ---

write_send_env_stub() {  # <home>: logs FM_HOME and fails while FM_TEST_SEND_FAIL=1
  cat > "$1/fm-send-stub.sh" <<'SH'
#!/usr/bin/env bash
printf 'SEND home=[%s] [%s]\n' "${FM_HOME:-}" "$*" >> "$FM_TEST_LOG"
[ "${FM_TEST_SEND_FAIL:-0}" != 1 ] || { echo "FM_HOME is not set" >&2; exit 1; }
SH
  chmod +x "$1/fm-send-stub.sh"
}

SD=$(make_home senddeliver)
write_local_backlog "$SD"
add_remote_mate "$SD"
write_fm_on_stub "$SD"
write_captain_stub "$SD"
write_send_env_stub "$SD"
run_calls "$SD" render >/dev/null 2>&1
cat > "$SD/result.txt" <<'EOF'
session:
  file: /tmp/calls.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Call r1: not needed\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"r1\",\n  \"home\": \"swiftmate\",\n  \"kind\": \"not-needed\",\n  \"answer\": \"Not needed, close it\",\n  \"note\": \"\"\n}","form",call-answer,"Buzz calendar shape"
EOF
# First apply: no FM_HOME in the environment (the process-event path) and the
# send fails. The answer is recorded; the delivery must be kept for a retry.
env -u FM_HOME FM_STATE_OVERRIDE="$SD/state" FM_DATA_OVERRIDE="$SD/data" \
  FM_CALLS_PAGE_TODAY=$TODAY FM_CALLS_PAGE_NOW=2026-10-04T21:00:00Z \
  FM_CALLS_PAGE_FM_ON="$SD/fm-on-stub.sh" FM_CALLS_PAGE_FM_SEND="$SD/fm-send-stub.sh" \
  FM_TEST_REMOTE_DIR="$SD/remote-swiftmate" FM_TEST_LOG="$SD/calls.log" FM_TEST_SEND_FAIL=1 \
  "$CALLS" apply "$SD/result.txt" >"$SD/out1" 2>"$SD/err1"
assert_contains "$(grep -F 'SEND' "$SD/calls.log")" "home=[$ROOT]" "apply without FM_HOME hands fm-send the home derived from the script location"
# The stub transport does not close the call, so mark it answered the way the
# owning home's status log would after the recorded answer.
printf '%s\n' 'resolved [key=captain-hold-r1-1]: answered: not needed' >> "$SD/state/swiftmate.status"
# Second apply with the send working: the call is no longer open, yet the
# recorded answer is delivered rather than skipped.
FM_TEST_SEND_FAIL=0 run_calls "$SD" apply "$SD/result.txt" >"$SD/out2" 2>"$SD/err2"
send_count=$(grep -c -F 'Call r1: Not needed' "$SD/calls.log")
assert_equals "2" "$send_count" "the undelivered answer is sent again on the next apply"
FM_TEST_SEND_FAIL=0 run_calls "$SD" apply "$SD/result.txt" >"$SD/out3" 2>"$SD/err3"
send_count=$(grep -c -F 'Call r1: Not needed' "$SD/calls.log")
assert_equals "2" "$send_count" "a delivered answer is not sent a third time"
pass "a second-mate answer is delivered without FM_HOME and retried after a failed send"

SM=$(make_home sendmulti)
write_local_backlog "$SM"
add_remote_mate "$SM"
write_fm_on_stub "$SM"
write_captain_stub "$SM"
write_send_env_stub "$SM"
run_calls "$SM" render >/dev/null 2>&1
cat > "$SM/result.txt" <<'EOF'
session:
  file: /tmp/calls.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Call r1: not needed\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"r1\",\n  \"home\": \"swiftmate\",\n  \"kind\": \"option\",\n  \"answer\": \"first line\\nsecond line\",\n  \"note\": \"\"\n}","form",call-answer,"Buzz calendar shape"
EOF
FM_TEST_SEND_FAIL=1 run_calls "$SM" apply "$SM/result.txt" >"$SM/out1" 2>"$SM/err1"
printf '%s\n' 'resolved [key=captain-hold-r1-1]: answered: not needed' >> "$SM/state/swiftmate.status"
FM_TEST_SEND_FAIL=0 run_calls "$SM" apply "$SM/result.txt" >"$SM/out2" 2>"$SM/err2"
assert_equals "2" "$(grep -c -F 'SEND' "$SM/calls.log")" "a multi-line answer is one undelivered record, retried once"
assert_contains "$(grep -F 'SEND' "$SM/calls.log" | tail -1)" "first line second line" "the retried multi-line answer arrives whole"
pass "a multi-line second-mate answer survives the undelivered queue"

# --- apply: typed text with no option picked never closes a call (state/calls-page.jsonl, 2026-10-05 15:21:41Z) ---

TX=$(make_home textonly)
cat > "$TX/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] twitter-follow-execute - Run the follow cleanup (repo: nexus) (kind: captain) (since 2026-10-02) (hold: Start the follow cleanup) (hold-kind: captain)
  Captain hold set: 2026-10-02T10:00:00Z
EOF
add_remote_mate "$TX"
sed -i 's/^- \[ \] r1 - Buzz calendar shape/- [ ] intake-agent-build - Build the intake agent/' "$TX/remote-swiftmate/backlog.md"
sed -i 's/captain-hold-r1-1/captain-hold-intake-agent-build-1/' "$TX/state/swiftmate.status"
write_fm_on_stub "$TX"
write_captain_stub "$TX"
write_fm_send_stub "$TX"
# The two real apply lines that closed live work.
cat > "$TX/real-lines.jsonl" <<'EOF'
{"at":"2026-10-05T15:21:41Z","event":"apply","home":"swiftmate","call":"intake-agent-build","kind":"text","outcome":"applied"}
{"at":"2026-10-05T15:21:41Z","event":"apply","home":"local","call":"twitter-follow-execute","kind":"text","outcome":"applied"}
EOF
run_calls "$TX" render >/dev/null 2>&1
{
  printf 'session:\n  file: /tmp/calls.html\n  status: feedback\nprompts[2]{uid,prompt,selector,tag,text}:\n'
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    h=$(jq -r .home <<<"$line"); c=$(jq -r .call <<<"$line"); k=$(jq -r .kind <<<"$line")
    printf '  "%s","Call %s: text\\n\\nContext data:\\n{\\n  \\"schema\\": \\"open-call-answer.v1\\",\\n  \\"call\\": \\"%s\\",\\n  \\"home\\": \\"%s\\",\\n  \\"kind\\": \\"%s\\",\\n  \\"answer\\": \\"\\",\\n  \\"note\\": \\"why are you asking me this\\"\\n}","form",call-answer,"%s"\n' "$n" "$c" "$c" "$h" "$k" "$c"
  done < "$TX/real-lines.jsonl"
} > "$TX/result.txt"
txout=$(FM_CALLS_PAGE_CAPTAIN_HOLD="$TX/captain-stub.sh" FM_TEST_REAL_CAPTAIN="$ROOT/bin/fm-captain-hold.sh" run_calls "$TX" apply "$TX/result.txt" 2>/dev/null)
TXLOG=$(cat "$TX/calls.log" 2>/dev/null)
assert_not_contains "$TXLOG" "HOLD [answer]" "a local text-only save never records an answer"
assert_not_contains "$TXLOG" "answers" "a second-mate text-only save never records an answer"
assert_contains "$TXLOG" "HOLD [hold] [twitter-follow-execute]" "the local call stays held with the captain's words"
assert_contains "$TXLOG" "ON swiftmate fm-captain-hold.sh [hold] [intake-agent-build]" "the second-mate call stays held with the captain's words"
assert_contains "$txout" "route: local/twitter-follow-execute why are you asking me this" "the local words are raised to firstmate"
assert_contains "$txout" "route: swiftmate/intake-agent-build why are you asking me this" "the second-mate words are raised to firstmate"
assert_not_contains "$txout" "applied: local/twitter-follow-execute text" "a text-only save is not reported as an applied answer"
pass "typed text with no option picked is raised, never recorded as a decision"

# --- apply: talk with no words records nothing and still routes ------------------

TW=$(make_home talkempty)
write_local_backlog "$TW"
write_captain_stub "$TW"
write_fm_send_stub "$TW"
run_calls "$TW" render >/dev/null 2>&1
cat > "$TW/result.txt" <<'EOF'
session:
  file: /tmp/calls.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Call a1: talk\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"a1\",\n  \"home\": \"local\",\n  \"kind\": \"talk\",\n  \"answer\": \"Let's talk about it first\",\n  \"note\": \"\"\n}","form",call-answer,"Pick the mouse path"
EOF
out=$(FM_CALLS_PAGE_CAPTAIN_HOLD="$TW/captain-stub.sh" FM_TEST_REAL_CAPTAIN="$ROOT/bin/fm-captain-hold.sh" run_calls "$TW" apply "$TW/result.txt" 2>"$TW/err"); rc=$?
LOG=$(cat "$TW/calls.log" 2>/dev/null)
expect_code 0 "$rc" "talk with no words applies cleanly"
assert_contains "$out" "talk: local/a1" "talk with no words is reported for firstmate"
assert_contains "$out" "route: local/a1 Let's talk about it first" "talk with no words still prints a route line"
assert_not_contains "$LOG" "HOLD" "talk with no words records nothing on the call"
pass "talk with no words records nothing and still routes"

# --- apply: a failed post-apply re-render never fails the apply ------------------

BR=$(make_home besteffort)
write_local_backlog "$BR"
write_captain_stub "$BR"
write_fm_send_stub "$BR"
run_calls "$BR" render >/dev/null 2>&1
cat > "$BR/result.txt" <<'EOF'
session:
  file: /tmp/calls.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Call a1: option\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"a1\",\n  \"home\": \"local\",\n  \"kind\": \"option\",\n  \"value\": \"solaar\",\n  \"answer\": \"Switch to Solaar\",\n  \"note\": \"\"\n}","form",call-answer,"Pick the mouse path"
EOF
chmod 555 "$BR/data/open-calls"
out=$(FM_CALLS_PAGE_CAPTAIN_HOLD="$BR/captain-stub.sh" FM_TEST_REAL_CAPTAIN="$ROOT/bin/fm-captain-hold.sh" run_calls "$BR" apply "$BR/result.txt" 2>"$BR/err"); rc=$?
chmod 755 "$BR/data/open-calls"
LOG=$(cat "$BR/calls.log" 2>/dev/null)
expect_code 0 "$rc" "a failed re-render does not fail the apply"
assert_contains "$LOG" "HOLD [answer] [a1]" "the answer is still recorded when the re-render fails"
assert_contains "$out" "applied: local/a1 option" "the answer is reported applied"
assert_contains "$(cat "$BR/err")" "the calls page was not rebuilt" "the failed re-render is warned on stderr"
pass "a failed post-apply re-render never fails the apply"

# --- apply: not-needed on a held work item never releases ------------------------
#
# "Not needed, close it" is offered on every card, including a work item held for
# the captain. Choosing it records a done close that abandons the gated work; it
# must never lift the hold (local --release, or the remote release mode), unlike
# an option or text answer on the same held work item.

NE=$(make_home notneeded)
cat > "$NE/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] wl1 - Local held work (repo: nexus) (kind: ship) (since 2026-10-01) (hold: Approve the build) (hold-kind: captain)
  Captain hold set: 2026-10-01T10:00:00Z
## Queued
## Done
EOF
cat > "$NE/data/secondmates.md" <<'EOF'
# Second mates

- swiftmate - Heavy work on swift. (host: swift; root: /srv/firstmate; home: /srv/swiftmate-home; scope: heavy build work; projects: nexus, buzz; added 2026-09-26)
EOF
mkdir -p "$NE/remote-swiftmate"
cat > "$NE/remote-swiftmate/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] rw1 - Remote held work (repo: buzz) (kind: ship) (since 2026-10-02) (hold: Approve the layout) (hold-kind: captain)
  Captain hold set: 2026-10-02T10:00:00Z
## Done
EOF
write_fm_on_stub "$NE"
write_captain_stub "$NE"
write_fm_send_stub "$NE"
run_calls "$NE" render >/dev/null 2>&1
cat > "$NE/result.txt" <<'EOF'
session:
  file: /tmp/calls.html
  status: feedback
prompts[2]{uid,prompt,selector,tag,text}:
  "1","Call wl1: not needed\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"wl1\",\n  \"home\": \"local\",\n  \"kind\": \"not-needed\",\n  \"answer\": \"Not needed, close it\",\n  \"note\": \"\"\n}","form",call-answer,"Local held work"
  "2","Call rw1: not needed\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"rw1\",\n  \"home\": \"swiftmate\",\n  \"kind\": \"not-needed\",\n  \"answer\": \"Not needed, close it\",\n  \"note\": \"\"\n}","form",call-answer,"Remote held work"
EOF
out=$(FM_CALLS_PAGE_CAPTAIN_HOLD="$NE/captain-stub.sh" FM_TEST_REAL_CAPTAIN="$ROOT/bin/fm-captain-hold.sh" run_calls "$NE" apply "$NE/result.txt" 2>"$NE/err"); rc=$?
LOG=$(cat "$NE/calls.log" 2>/dev/null)
expect_code 0 "$rc" "not-needed on held work items applies cleanly"
assert_contains "$LOG" "HOLD [answer] [wl1] [--decision-file]" "not-needed on a local held work item records through answer"
assert_not_contains "$(grep -F 'HOLD [answer] [wl1]' <<<"$LOG")" "--release" "not-needed on a local held work item closes without releasing the hold"
assert_contains "$LOG" "$(printf 'STDIN rw1\tNot needed\t\tdone')" "not-needed on a remote held work item closes in done mode, never release"
assert_contains "$out" "applied: local/wl1 not-needed" "the local not-needed close is reported applied"
assert_contains "$out" "applied: swiftmate/rw1 not-needed" "the remote not-needed close is reported applied"
pass "not-needed on a held work item closes without release, local and remote"

# --- re-render hook in fm-captain-hold.sh ---------------------------------------

K=$(make_home hook)
printf '## In flight\n\n## Queued\n\n## Done\n' > "$K/data/backlog.md"
captain() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_CALLS_PAGE_TODAY=$TODAY "$ROOT/bin/fm-captain-hold.sh" "$@"
}
run_calls "$K" render >/dev/null 2>&1
KPAGE=$(page_of "$K")
captain "$K" hold hook1 --title "Throwaway hook call" --repo nexus --reason "Hook test call" >/dev/null 2>"$K/err"; rc=$?
expect_code 0 "$rc" "hold succeeds"
assert_grep 'data-call="hook1"' "$KPAGE" "a new hold re-renders the page with its card"
printf 'Yes, do it\n' > "$K/decision.txt"
captain "$K" answer hook1 --decision-file "$K/decision.txt" >/dev/null 2>"$K/err"; rc=$?
expect_code 0 "$rc" "answer succeeds"
assert_no_grep 'data-call="hook1"' "$KPAGE" "an answer re-renders the page without the card"
captain "$K" hold hook2 --title "Second hook call" --repo nexus --reason "Second hook call" >/dev/null 2>&1
captain "$K" hold hook3 --title "Third hook call" --repo nexus --reason "Third hook call" >/dev/null 2>&1
printf 'hook2\tyes\t\n' | captain "$K" answers --source "chat" >/dev/null 2>"$K/err"; rc=$?
expect_code 0 "$rc" "a keyed chat answer succeeds"
assert_no_grep 'data-call="hook2"' "$KPAGE" "a keyed chat answer removes its card"
assert_grep 'data-call="hook3"' "$KPAGE" "other open calls stay on the page"
pass "every captain-hold mutation re-renders the page"
# A render failure never fails the mutation and logs one line.
chmod 555 "$K/data/open-calls"
captain "$K" hold hook3 --reason "Third hook call, again" >/dev/null 2>"$K/err"; rc=$?
chmod 755 "$K/data/open-calls"
expect_code 0 "$rc" "a failed re-render does not fail the mutation"
lines=$(grep -c 'calls page' "$K/err")
assert_equals "1" "$lines" "a failed re-render logs exactly one line"
pass "a failed re-render never fails the mutation"
# A home without the page pays nothing and creates nothing.
Q=$(make_home nohook)
printf '## In flight\n\n## Queued\n\n## Done\n' > "$Q/data/backlog.md"
captain "$Q" hold q1 --title "No page call" --repo nexus --reason "No page here" >/dev/null 2>&1
assert_absent "$(page_of "$Q")" "a home that never rendered the page gets none from a mutation"
pass "a home without the page gets none from a mutation"

# --- saved marker scoped to one page build ---------------------------------------
#
# The saved marker keeps a just-saved card collapsed if the browser reloads
# before the answer is applied, but it must not outlive the page build: a
# re-render (after a recorded answer, a talk note, or a failed apply) has to
# leave every still-open card answerable. tests/assets/calls-page-harness.mjs
# runs the page's own inline script under a minimal DOM shim and reports the
# marker it wrote and the cards it collapsed.

if command -v node >/dev/null 2>&1; then
  S=$(make_home savedmarker)
  write_local_backlog "$S"
  add_remote_mate "$S"
  write_fm_on_stub "$S"
  HARNESS="$ROOT/tests/assets/calls-page-harness.mjs"
  SPAGE=$(page_of "$S")
  run_calls_at "$S" 2026-10-04T21:00:00Z render >/dev/null 2>&1
  cp "$SPAGE" "$S/build-a.html"
  run_calls_at "$S" 2026-10-04T22:00:00Z render >/dev/null 2>&1
  cp "$SPAGE" "$S/build-b.html"

  # A save confirms on the card first (its one prompt was queued), then
  # collapses after the 1.5s timer, keeping the next card anchored.
  cat > "$S/option.json" <<'EOF'
{"submit": {"call": "a1", "home": "local", "choice": "Keep Logi Options"}}
EOF
  opt_out=$(node "$HARNESS" "$S/build-a.html" "$S/option.json")
  assert_equals "true" "$(jq -r '.confirmed == ["a1"]' <<<"$opt_out")" "a save confirms on its card before collapsing"
  assert_equals "1" "$(jq -r '.queued | length' <<<"$opt_out")" "a save queues exactly one prompt"
  assert_equals "1" "$(jq -r '.sent' <<<"$opt_out")" "a save sends its one queued prompt at once"
  assert_equals "option" "$(jq -r '.queued[0].kind' <<<"$opt_out")" "the queued prompt carries the saved kind"
  assert_equals "true" "$(jq -r '.collapsed == ["a1"]' <<<"$opt_out")" "the card collapses after the confirmation"
  assert_equals "1" "$(jq -r '.store | length' <<<"$opt_out")" "a recorded save persists one saved marker"
  assert_equals "true" "$(jq -r '(.scrolled | length) > 0' <<<"$opt_out")" "collapsing keeps the next card anchored"
  printf '{"store": %s}\n' "$(jq -c '.store' <<<"$opt_out")" > "$S/reload-option.json"
  failed_out=$(node "$HARNESS" "$S/build-b.html" "$S/reload-option.json")
  assert_equals "false" "$(jq -r '.loaded | index("a1") != null' <<<"$failed_out")" "a failed apply leaves the card answerable after a re-render"

  # A talk save confirms and collapses too, but records nothing and persists no
  # marker, so the card stays answerable after a re-render.
  cat > "$S/talk.json" <<'EOF'
{"submit": {"call": "a1", "home": "local", "choice": "__talk__"}}
EOF
  talk_out=$(node "$HARNESS" "$S/build-a.html" "$S/talk.json")
  assert_equals "true" "$(jq -r '.confirmed == ["a1"]' <<<"$talk_out")" "a talk save confirms on the card"
  assert_equals "0" "$(jq -r '.store | length' <<<"$talk_out")" "a talk save persists no saved marker"
  printf '{"store": %s}\n' "$(jq -c '.store' <<<"$talk_out")" > "$S/reload-talk.json"
  reload_out=$(node "$HARNESS" "$S/build-b.html" "$S/reload-talk.json")
  assert_equals "false" "$(jq -r '.loaded | index("a1") != null' <<<"$reload_out")" "a talked-about call is answerable after a re-render"

  # The default order is newest asked first; the By project switch regroups.
  printf '{}\n' > "$S/none.json"
  printf '{"sort": "project"}\n' > "$S/sort.json"
  sort_default=$(node "$HARNESS" "$S/build-a.html" "$S/none.json")
  assert_equals "newest" "$(jq -r '.sortMode' <<<"$sort_default")" "the page defaults to the Newest sort"
  assert_equals "r1,a1,w1,e1" "$(jq -r '.visualOrder | join(",")' <<<"$sort_default")" "the default order is newest asked first"
  sort_project=$(node "$HARNESS" "$S/build-a.html" "$S/sort.json")
  assert_equals "project" "$(jq -r '.sortMode' <<<"$sort_project")" "the By project switch is active after clicking it"
  assert_equals "a1,w1,r1,e1" "$(jq -r '.visualOrder | join(",")' <<<"$sort_project")" "By project groups each call under its project"

  # A recorded answer removes the card from the re-render entirely.
  printf 'Yes, do it\n' > "$S/decision.txt"
  FM_HOME="$S" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_CALLS_PAGE_TODAY=$TODAY "$ROOT/bin/fm-captain-hold.sh" answer a1 --decision-file "$S/decision.txt" >/dev/null 2>&1
  assert_no_grep 'data-call="a1"' "$SPAGE" "a recorded answer removes the card from the re-render"
  pass "the saved marker is scoped to one page build and never hides a still-open call"
else
  pass "saved-marker browser behavior (node absent, skipped)"
fi

# --- an armed page is never rewritten under the captain ---------------------------
#
# Once a page is armed (shown to him), apply and every captain-hold mutation
# record their answers but leave its file alone; render without arming writes a
# preview file instead; only `arm --new` builds a NEW file and board, and the
# old file keeps serving unchanged.

AR=$(make_home armed)
write_local_backlog "$AR"
write_fm_on_stub "$AR"
write_captain_stub "$AR"
write_fm_send_stub "$AR"
mkdir -p "$AR/bin-stubs"
cat > "$AR/bin-stubs/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'opened %s\nhttp://box.example.ts.net:4387/session/key-%s\n' "$1" "$(basename "$1" .html)"
SH
cat > "$AR/bin-stubs/lavish-sys" <<'SH'
#!/usr/bin/env bash
printf 'http://lavish-box.sys/session/%s\n' "${2##*/}"
SH
cat > "$AR/procevent-stub.sh" <<'SH'
#!/usr/bin/env bash
printf 'ARM %s\n' "$*" >> "$FM_TEST_LOG"
SH
chmod +x "$AR/bin-stubs/lavish-axi" "$AR/bin-stubs/lavish-sys" "$AR/procevent-stub.sh"
run_armed() {  # <args...>
  PATH="$AR/bin-stubs:$PATH" FM_CALLS_PAGE_PROCEVENT_LAVISH="$AR/procevent-stub.sh" run_calls "$AR" "$@"
}
armed_captain() {  # <args...>
  FM_HOME="$AR" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_CALLS_PAGE_TODAY=$TODAY "$ROOT/bin/fm-captain-hold.sh" "$@"
}
APAGE=$(page_of "$AR")

out=$(run_armed arm 2>"$AR/err"); rc=$?
expect_code 0 "$rc" "arm succeeds"
assert_present "$APAGE" "arm renders the first page"
assert_contains "$out" "link: http://lavish-box.sys/session/key-calls" "arm prints the page's link"
FIRST_SUM=$(cksum < "$APAGE")

# A hold mutation and a recorded answer leave the armed file byte-identical.
armed_captain hold armed1 --title "Added while armed" --repo nexus --reason "New call while armed" >/dev/null 2>"$AR/err"; rc=$?
expect_code 0 "$rc" "a hold mutation succeeds on an armed page"
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "a hold mutation leaves the armed page's bytes unchanged"
printf 'Yes\n' > "$AR/decision.txt"
armed_captain answer armed1 --decision-file "$AR/decision.txt" >/dev/null 2>"$AR/err"; rc=$?
expect_code 0 "$rc" "an answer succeeds on an armed page"
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "an answer leaves the armed page's bytes unchanged"
printf 'a1\tyes\t\n' | armed_captain answers --source "chat" >/dev/null 2>&1
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "a keyed chat answer leaves the armed page's bytes unchanged"

# apply records the answer and leaves the armed file alone.
cat > "$AR/result.txt" <<'EOF'
session:
  file: /tmp/calls.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Call w1: Build it narrower\n\nContext data:\n{\n  \"schema\": \"open-call-answer.v1\",\n  \"call\": \"w1\",\n  \"home\": \"local\",\n  \"kind\": \"option\",\n  \"value\": \"narrow\",\n  \"answer\": \"Build it narrower\",\n  \"note\": \"\"\n}","form",call-answer,"Ship the widget"
EOF
out=$(FM_CALLS_PAGE_CAPTAIN_HOLD="$AR/captain-stub.sh" FM_TEST_REAL_CAPTAIN="$ROOT/bin/fm-captain-hold.sh" run_armed apply "$AR/result.txt" 2>"$AR/err"); rc=$?
expect_code 0 "$rc" "apply succeeds on an armed page"
assert_contains "$out" "applied: local/w1 option" "apply still records the answer"
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "apply leaves the armed page's bytes unchanged"

# render without arming and --if-present never write over the armed file.
out=$(run_armed render 2>"$AR/err"); rc=$?
expect_code 0 "$rc" "render succeeds while a page is armed"
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "render leaves the armed page's bytes unchanged"
PREVIEW=$(printf '%s\n' "$out" | sed -n 's/^rendered: \([^ ]*\) .*/\1/p')
assert_not_equals "$APAGE" "$PREVIEW" "render writes its preview to a different file"
assert_present "$PREVIEW" "the preview file exists"
run_armed render --if-present >/dev/null 2>&1; rc=$?
expect_code 0 "$rc" "render --if-present succeeds while a page is armed"
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "render --if-present leaves the armed page's bytes unchanged"

# Arming again resumes the same page and rewrites nothing.
out2=$(run_armed arm 2>"$AR/err"); rc=$?
expect_code 0 "$rc" "arm again succeeds"
assert_contains "$out2" "link: http://lavish-box.sys/session/key-calls" "arm again keeps the same link"
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "arm again leaves the armed page's bytes unchanged"

# An explicit new page writes a NEW file, arms a new board, and says so.
out3=$(run_armed arm --new 2>"$AR/err"); rc=$?
expect_code 0 "$rc" "arm --new succeeds"
NEW_LINK=$(printf '%s\n' "$out3" | sed -n 's/^link: //p')
assert_not_equals "http://lavish-box.sys/session/key-calls" "$NEW_LINK" "arm --new prints a different link"
assert_contains "$out3" "replaced:" "arm --new reports the page it replaced"
assert_contains "$out3" "tell the captain a new page replaced the old one" "arm --new prints the note for firstmate"
assert_contains "$out3" "http://lavish-box.sys/session/key-calls" "the note names the old link, which keeps working"
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "the old page's bytes are unchanged after arm --new"
NEW_PAGES=("$AR"/data/open-calls/calls-2*.html)
NEW_PAGE=${NEW_PAGES[0]}
assert_present "$NEW_PAGE" "arm --new writes a new page file"
assert_not_equals "$APAGE" "$NEW_PAGE" "the new page is a different file"
assert_grep 'data-call="e1"' "$NEW_PAGE" "the new page carries the current open calls"
assert_no_grep 'data-call="a1"' "$NEW_PAGE" "the new page no longer carries a call answered since the old page"
assert_grep 'data-call="a1"' "$APAGE" "the old page still serves its original content"
assert_grep "ARM arm $NEW_PAGE" "$AR/calls.log" "arm --new arms the new board"
NEW_SUM=$(cksum < "$NEW_PAGE")

# The new page is now the armed one: mutations leave it alone too.
armed_captain hold armed2 --title "After the new page" --repo nexus --reason "Another call" >/dev/null 2>&1
assert_equals "$NEW_SUM" "$(cksum < "$NEW_PAGE")" "the newly armed page is never rewritten by a mutation"
assert_equals "$FIRST_SUM" "$(cksum < "$APAGE")" "the old page stays unchanged after later mutations"

# A second --new in the same second still gets its own file.
run_armed arm --new >/dev/null 2>&1; rc=$?
expect_code 0 "$rc" "a second arm --new succeeds"
pages=("$AR"/data/open-calls/calls-2*.html)
assert_equals "2" "${#pages[@]}" "each arm --new keeps a separate page file"
pass "an armed page is never rewritten; only arm --new builds a new page and board"
