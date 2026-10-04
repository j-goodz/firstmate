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

run_calls() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_CALLS_PAGE_TODAY=$TODAY FM_CALLS_PAGE_NOW=2026-10-04T21:00:00Z \
    FM_CALLS_PAGE_FM_ON="$home/fm-on-stub.sh" \
    FM_TEST_REMOTE_DIR="$home/remote-swiftmate" FM_TEST_LOG="$home/calls.log" \
    "$CALLS" "$@"
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
# Groups by project in a stable order, each call under its own project.
b=$(line_of "$PAGE" 'data-project="buzz"')
m=$(line_of "$PAGE" 'data-project="marketwatch"')
n=$(line_of "$PAGE" 'data-project="nexus"')
if [ -n "$b" ] && [ -n "$m" ] && [ -n "$n" ] && [ "$b" -lt "$m" ] && [ "$m" -lt "$n" ]; then
  pass "projects render in stable alphabetical order"
else
  fail "projects render in stable alphabetical order (buzz=$b marketwatch=$m nexus=$n)"
fi
e=$(line_of "$PAGE" 'data-call="e1"'); a=$(line_of "$PAGE" 'data-call="a1"')
if [ "$e" -gt "$m" ] && [ "$e" -lt "$n" ] && [ "$a" -gt "$n" ]; then
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
assert_no_grep 'held by swiftmate' "$PAGE" "cards carry no internal home line"
assert_no_grep 'task a1' "$PAGE" "cards carry no internal task id line"
assert_grep 'open-call-answer.v1' "$PAGE" "saves carry the open-call-answer.v1 schema"
assert_grep 'sendQueuedPrompts' "$PAGE" "a save sends its one prompt at once"
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
ctx_count=$(grep -c 'Legion runs Logi Options today' "$PAGE")
assert_equals "1" "$ctx_count" "a curated feature's shared context renders once"
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
assert_contains "$LOG" "HOLD [answer] [w1] [--decision-file]" "a text answer records through answer"
assert_contains "$(grep -F 'HOLD [answer] [w1]' <<<"$LOG")" "[--release]" "an answer on held work releases it"
assert_contains "$LOG" "DECISION Answer: Build it narrower" "a text answer records the captain's words"
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
assert_contains "$out" "talk: local/e1" "Let's talk is reported for firstmate to raise in chat"
e1_count=$(grep -c -F '[e1]' <<<"$LOG")
assert_equals "1" "$e1_count" "Let's talk records nothing on the call"
assert_contains "$out" "rendered:" "apply re-renders the page"
pass "apply maps option, text, Later, and Not needed answers onto the owning home's captain-hold record"

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
