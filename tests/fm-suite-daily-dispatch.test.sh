#!/usr/bin/env bash
# tests/fm-suite-daily-dispatch.test.sh - the `dispatch` subcommand of
# bin/fm-suite-daily.sh: candidate order from the placement command, trying the
# next machine when one cannot run, the once-per-failure alert, the dispatcher
# log, --dry-run, and the single-machine fallback when placement is unusable.
#
# Placement, ssh and the alert command are fakes driven by files in the case
# directory, so the assertions read what dispatch asked for and what it logged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_SUITE_SLOT_HELD FM_SUITE_SLOTS FM_SUITE_NPROC FM_HOME FM_THERMAL_SYSFS FM_TASK_ID FM_SUITE_MIN_AVAILABLE_MB

DAILY="$ROOT/bin/fm-suite-daily.sh"
TMP_ROOT=$(fm_test_tmproot fm-suite-daily-dispatch)

PLACE_JSON='{"class":"heavy","place":null,"machines":[
 {"machine":"swift","mate":"swiftmate","verdict":"ok","reason":"ok","root":"/r/swift","home":"/h/swift"},
 {"machine":"homelab","mate":"homelabmate","verdict":"busy","reason":"load-busy","root":"/r/homelab","home":"/h/homelab"},
 {"machine":"old","mate":"oldmate","verdict":"no","reason":"no-suite-slots","root":"/r/old","home":"/h/old"},
 {"machine":"hold","mate":"holdmate","verdict":"no","reason":"heat-hold","root":"/r/hold","home":"/h/hold"}]}'

# new_case <name>: fakes for placement, ssh and alert, and a two-repo config.
new_case() {
    CASE="$TMP_ROOT/$1"
    mkdir -p "$CASE"
    printf '%s\n' "$PLACE_JSON" > "$CASE/place.json"
    printf '#!/bin/sh\ncat "%s/place.json"\n' "$CASE" > "$CASE/place"
    cat > "$CASE/ssh" <<EOF
#!/bin/sh
# called as: ssh -o BatchMode=yes -o ConnectTimeout=5 <machine> "<command>"
cat > /dev/null
echo "\$5 \$6" >> "$CASE/calls"
if [ -f "$CASE/reply-\$5" ]; then
  cat "$CASE/reply-\$5"
  exit "\$(cat "$CASE/rc-\$5" 2> /dev/null || echo 0)"
fi
exit 255
EOF
    cat > "$CASE/alert" <<EOF
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a" >> "$CASE/alerts"; done
echo ---- >> "$CASE/alerts"
EOF
    chmod +x "$CASE/place" "$CASE/ssh" "$CASE/alert"
    printf 'a|/nonexistent|none|true\nb|/nonexistent|none|true\n' > "$CASE/config"
    export FM_SUITE_DAILY_CONFIG="$CASE/config" FM_SUITE_STATE_DIR="$CASE/state" FM_SUITE_DAILY_LOG="$CASE/log.jsonl"
    export FM_SUITE_DAILY_PLACE="$CASE/place" FM_SUITE_DAILY_SSH="$CASE/ssh" FM_SUITE_DAILY_ALERT="$CASE/alert"
}

# reply <machine> <rc> <status> [failed ids...]: canned answer of a machine's `run`.
reply() {
    local machine=$1 rc=$2 status=$3 ids json
    shift 3
    ids=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length > 0))')
    json=$(jq -cn --arg host "$machine" --arg status "$status" --argjson ids "$ids" \
        '{ts: "2026-10-05T07:30:00Z", event: "daily-run", host: $host, key: "a", sha: "0123456789abcdef0123456789abcdef01234567", status: $status, reason: "", rc: 0, failures: ($ids | length), failed_ids: $ids, duration_s: 3}')
    printf 'some suite chatter\nRESULT %s\n' "$json" > "$CASE/reply-$machine"
    printf '%s\n' "$rc" > "$CASE/rc-$machine"
}

called_machines() {
    awk '{ print $1 }' "$CASE/calls" 2> /dev/null | paste -sd, -
}

test_candidates_are_tried_in_ranked_order() {
    new_case order
    reply swift 11 skipped
    reply homelab 10 skipped
    reply old 0 pass
    reply hold 0 pass
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    expect_code 0 "$?" "dispatch"
    assert_equals "swift,homelab,old" "$(called_machines)" "ok, then busy, then the light-only machine; never the heat-held one"
    assert_contains "$(head -n1 "$CASE/calls")" "/r/swift/bin/fm-suite-daily.sh run a" "the remote command"
    pass "candidates are tried ok, busy, light-only, never a heat-held machine"
}

test_the_first_machine_that_runs_it_ends_the_search() {
    new_case first
    reply swift 0 pass
    reply homelab 0 pass
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    assert_equals "swift" "$(called_machines)" "only the first machine"
    pass "the first machine that runs the repo ends the search"
}

test_an_unreachable_machine_falls_through_to_the_next() {
    new_case unreachable
    reply homelab 0 pass
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    assert_equals "swift,homelab" "$(called_machines)" "swift answers 255, homelab runs it"
    pass "an ssh failure makes dispatch try the next machine"
}

test_repo_selection() {
    new_case repos
    reply swift 0 pass
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    assert_equals 1 "$(wc -l < "$CASE/calls" | tr -d ' ')" "one repo, one call"
    assert_contains "$(cat "$CASE/calls")" " run a" "repo a"
    rm -f "$CASE/calls"
    "$DAILY" dispatch > /dev/null 2>&1
    assert_contains "$(cat "$CASE/calls")" " run a" "all repos: a"
    assert_contains "$(cat "$CASE/calls")" " run b" "all repos: b"
    pass "--repo limits dispatch to one repo and the default is every configured repo"
}

test_a_failure_alerts_once_per_failing_set() {
    local sig1 sig2 sig3 msg
    new_case alert
    reply swift 0 fail tests/x.test.sh tests/y.test.sh
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    assert_equals "--tag" "$(sed -n 1p "$CASE/alerts")" "first alert argument"
    assert_equals "[suite-daily]" "$(sed -n 2p "$CASE/alerts")" "tag"
    assert_equals "--sig" "$(sed -n 3p "$CASE/alerts")" "sig flag"
    sig1=$(sed -n 4p "$CASE/alerts")
    msg=$(sed -n 5p "$CASE/alerts")
    case "$sig1" in suite-daily:a:0123456789abcdef0123456789abcdef01234567:*) ;; *) fail "unexpected sig: $sig1" ;; esac
    assert_contains "$msg" "a" "message names the repo"
    assert_contains "$msg" "0123456" "message names the short sha"
    assert_contains "$msg" "swift" "message names the machine"
    assert_contains "$msg" "2 failing" "message counts the failures"
    assert_contains "$msg" "tests/x.test.sh" "message lists a failing id"
    assert_json_has_alerted_true "$CASE/log.jsonl"
    : > "$CASE/alerts"
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    sig2=$(sed -n 4p "$CASE/alerts")
    assert_equals "$sig1" "$sig2" "the same failing set must give the same sig"
    reply swift 0 fail tests/x.test.sh tests/z.test.sh
    : > "$CASE/alerts"
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    sig3=$(sed -n 4p "$CASE/alerts")
    assert_not_equals "$sig1" "$sig3" "a different failing set must give a different sig"
    pass "a failure calls the alert command with a sig that depends on the failing set"
}

assert_json_has_alerted_true() {  # <log>
    jq -s -e 'any(.[]; .event == "dispatch" and .alerted == true)' "$1" > /dev/null || fail "no dispatch line with alerted true: $(cat "$1")"
}

test_a_pass_does_not_alert() {
    new_case nopass
    reply swift 0 pass
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    assert_absent "$CASE/alerts" "a passing run must not alert"
    pass "a passing run raises no alert"
}

test_no_alert_command_still_logs_the_failure() {
    new_case noalert
    reply swift 0 fail tests/x.test.sh
    mkdir -p "$CASE/emptyhome"
    HOME="$CASE/emptyhome" FM_SUITE_DAILY_ALERT='' "$DAILY" dispatch --repo a > /dev/null 2>&1
    expect_code 0 "$?" "dispatch without an alert command"
    assert_absent "$CASE/alerts" "no alert command, no alert"
    jq -s -e 'any(.[]; .event == "dispatch" and .status == "fail" and .alerted == false)' "$CASE/log.jsonl" > /dev/null \
        || fail "the failure must still be logged: $(cat "$CASE/log.jsonl")"
    pass "without an alert command the failure is still logged"
}

test_every_machine_skipping_is_logged_and_exits_zero() {
    new_case allskip
    reply swift 11 skipped
    reply homelab 11 skipped
    reply old 11 skipped
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    expect_code 0 "$?" "dispatch itself must exit 0"
    jq -s -e 'any(.[]; .event == "dispatch" and .status == "skipped" and .reason == "no-machine-ran" and .tried == ["swift","homelab","old"])' "$CASE/log.jsonl" > /dev/null \
        || fail "skipped dispatch line missing: $(cat "$CASE/log.jsonl")"
    pass "when every machine skips, dispatch logs no-machine-ran and exits 0"
}

test_unusable_placement_falls_back_to_this_machine() {
    local src="$TMP_ROOT/fallback-src"
    new_case fallback
    printf '#!/bin/sh\nexit 1\n' > "$CASE/place"
    fm_git_init_commit "$src"
    printf 'echo "FM_TEST_END 2026-10-05T00:00:00Z tests/a.test.sh exit=0 duration_ms=1 gate_skip=false"\n' > "$src/suite.sh"
    git -C "$src" add suite.sh
    git -C "$src" -c user.name=t -c user.email=t@example.invalid commit -qm suite
    printf 'c|%s|fm-test|bash suite.sh\n' "$src" > "$CASE/config"
    printf '0.10 0.10 0.10 1/100 1\n' > "$CASE/loadavg"
    printf 'MemAvailable:    4194304 kB\n' > "$CASE/meminfo"
    mkdir -p "$CASE/sysfs"
    FM_SUITE_DAILY_FETCH=0 FM_SUITE_DAILY_REF=main FM_SUITE_SLOTS=1 FM_SUITE_NPROC=4 FM_SUITE_CONFIG="$CASE/none" \
        FM_SUITE_DAILY_LOADAVG="$CASE/loadavg" FM_SUITE_MEMINFO="$CASE/meminfo" FM_THERMAL_SYSFS="$CASE/sysfs" \
        "$DAILY" dispatch --repo c > /dev/null 2>&1
    expect_code 0 "$?" "dispatch with unusable placement"
    jq -s -e --arg host "$(hostname -s)" 'any(.[]; .event == "dispatch" and .key == "c" and .status == "pass" and .machine == $host)' "$CASE/log.jsonl" > /dev/null \
        || fail "the local fallback run is missing: $(cat "$CASE/log.jsonl")"
    assert_absent "$CASE/calls" "no ssh in the fallback"
    pass "an unusable placement falls back to running on this machine"
}

test_dry_run_plans_without_running() {
    local out
    new_case dry
    reply swift 0 pass
    out=$("$DAILY" dispatch --dry-run)
    expect_code 0 "$?" "dry run"
    assert_contains "$out" "PLAN a -> swift,homelab,old" "plan for a"
    assert_contains "$out" "PLAN b -> swift,homelab,old" "plan for b"
    assert_absent "$CASE/calls" "a dry run must not call ssh"
    assert_absent "$FM_SUITE_DAILY_LOG" "a dry run must not log"
    pass "--dry-run prints the plan and runs nothing"
}

test_dispatch_needs_a_repo() {
    new_case norepo
    : > "$CASE/config"
    "$DAILY" dispatch > /dev/null 2>&1
    expect_code 2 "$?" "no repos configured and no --repo"
    pass "dispatch without any repo exits 2"
}

test_dispatch_log_lines_are_documented_json() {
    new_case logshape
    reply swift 0 pass
    "$DAILY" dispatch --repo a > /dev/null 2>&1
    jq -s -e 'length >= 1 and all(.[]; .event == "dispatch" and has("ts") and has("host") and has("key") and has("machine") and has("status") and has("reason") and has("sha") and has("failures") and has("tried"))' \
        "$CASE/log.jsonl" > /dev/null || fail "dispatch log shape: $(cat "$CASE/log.jsonl")"
    pass "dispatch log lines carry the documented keys"
}

test_candidates_are_tried_in_ranked_order
test_the_first_machine_that_runs_it_ends_the_search
test_an_unreachable_machine_falls_through_to_the_next
test_repo_selection
test_a_failure_alerts_once_per_failing_set
test_a_pass_does_not_alert
test_no_alert_command_still_logs_the_failure
test_every_machine_skipping_is_logged_and_exits_zero
test_unusable_placement_falls_back_to_this_machine
test_dry_run_plans_without_running
test_dispatch_needs_a_repo
test_dispatch_log_lines_are_documented_json
