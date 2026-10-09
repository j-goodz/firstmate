#!/usr/bin/env bash
# Test bin/fm-research-post.sh

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" # shellcheck source=tests/lib.sh

new_home() {
    TMP=$(fm_test_tmproot fm-research-post)
    HOME_DIR=$TMP/home
    mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
}

make_helper() {
    cat > "$TMP/fake-helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/calls.log"
exit "${FAKE_RC:-0}"
EOF
    chmod +x "$TMP/fake-helper"
}

make_report() {
    local id=$1
    local first_line=$2
    mkdir -p "$HOME_DIR/data/$id"
    cat > "$HOME_DIR/data/$id/report.md" <<EOF
$first_line
body text
EOF
}

test_help_and_usage() {
    local rc=0
    new_home
    "$ROOT/bin/fm-research-post.sh" --help | grep -q "Usage" || fail "help does not print Usage"
    pass "help prints Usage"

    "$ROOT/bin/fm-research-post.sh" || rc=$?
    assert_equals 2 "$rc" "missing task id exits 2"
    pass "missing task id exits 2"
}

test_posts_scout_report() {
    new_home
    local id=t1
    make_report "$id" "# Scout: widget audit"
    make_helper

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-research-post.sh" "$id" --source scout

    assert_grep '--source scout' "$TMP/calls.log" "call has --source scout"
    assert_grep "--path $HOME_DIR/data/t1/report.md" "$TMP/calls.log" "call has --path"
    assert_grep '--title Scout: widget audit' "$TMP/calls.log" "call has title from heading"
    assert_present "$HOME_DIR/state/research-post.posted" "posted file exists"
    assert_grep 't1' "$HOME_DIR/state/research-post.posted" "posted file contains id"
    assert_grep '"outcome":"ok"' "$HOME_DIR/state/research-post.jsonl" "jsonl has outcome ok"
    pass "scout report posts successfully"
}

test_title_falls_back_to_task_id() {
    new_home
    local id=t2
    make_report "$id" ""
    make_helper

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-research-post.sh" "$id"

    assert_grep '--title t2' "$TMP/calls.log" "call falls back to task id"
    pass "title falls back to task id"
}

test_idempotent_rerun() {
    new_home
    local id=t3
    make_report "$id" ""
    make_helper

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-research-post.sh" "$id"
    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-research-post.sh" "$id"

    assert_equals 1 "$(wc -l < "$TMP/calls.log")" "calls.log has exactly 1 line"
    assert_grep '"outcome":"duplicate"' "$HOME_DIR/state/research-post.jsonl" "jsonl has duplicate outcome"
    pass "idempotent rerun"
}

test_fail_open_helper_error() {
    local rc=0
    new_home
    local id=t4
    make_report "$id" ""
    make_helper

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper FAKE_RC=3 "$ROOT/bin/fm-research-post.sh" "$id" || rc=$?
    assert_equals 1 "$rc" "script exits 1 on helper error"
    assert_no_grep 't4' "$HOME_DIR/state/research-post.posted" "posted file lacks id"
    assert_grep '"outcome":"error"' "$HOME_DIR/state/research-post.jsonl" "jsonl has error outcome"
    assert_grep '"rc":3' "$HOME_DIR/state/research-post.jsonl" "jsonl has rc 3"

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper FAKE_RC=0 "$ROOT/bin/fm-research-post.sh" "$id"
    assert_equals 2 "$(wc -l < "$TMP/calls.log")" "calls.log has 2 lines"
    pass "failed post is retried"
}

test_missing_helper_command_does_not_crash() {
    local rc=0
    new_home
    local id=t5
    make_report "$id" ""

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=/nonexistent/helper "$ROOT/bin/fm-research-post.sh" "$id" || rc=$?
    assert_equals 1 "$rc" "script exits 1 on missing helper"
    assert_grep '"outcome":"error"' "$HOME_DIR/state/research-post.jsonl" "jsonl has error outcome"
    pass "missing helper does not crash"
}

test_no_report_no_post() {
    new_home
    local id=t6
    make_helper

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-research-post.sh" "$id"

    assert_absent "$TMP/calls.log" "calls.log absent"
    assert_grep '"outcome":"no-report"' "$HOME_DIR/state/research-post.jsonl" "jsonl has no-report outcome"
    pass "no report no post"
}

test_dry_run_posts_nothing() {
    new_home
    local id=t7
    make_report "$id" ""
    make_helper

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-research-post.sh" "$id" --dry-run

    assert_absent "$TMP/calls.log" "calls.log absent"
    assert_absent "$HOME_DIR/state/research-post.posted" "posted file absent"
    assert_grep '"outcome":"dry-run"' "$HOME_DIR/state/research-post.jsonl" "jsonl has dry-run outcome"
    pass "dry run posts nothing"
}

test_log_has_latency() {
    new_home
    local id=t8
    make_report "$id" ""
    make_helper

    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-research-post.sh" "$id"

    grep -Eq '"latency_ms":[0-9]+' "$HOME_DIR/state/research-post.jsonl" || fail "jsonl lacks latency_ms"
    pass "log has latency"
}

test_no_secret_or_port_in_log() {
    new_home
    local id=t9
    make_report "$id" ""
    make_helper

    FAKE_SECRET=hunter2-secret FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-research-post.sh" "$id"

    assert_no_grep 'hunter2-secret' "$HOME_DIR/state/research-post.jsonl" "jsonl does not contain secret"
    pass "no secret or port in log"
}

new_scout_home() {  # <id>: a manual-backlog home with a recorded scout report; sets TMP and HOME_DIR
    local id=$1
    new_home
    mkdir -p "$HOME_DIR/config" "$HOME_DIR/projects/sample" "$HOME_DIR/data/$id"
    echo manual > "$HOME_DIR/config/backlog-backend"
    git -C "$HOME_DIR/projects/sample" init -q || fail "could not init sample project"
    printf '# Scout: teardown probe\nbody text\n' > "$HOME_DIR/data/$id/report.md"
    fm_write_meta "$HOME_DIR/state/$id.meta" "window=rptest:fm-$id" "worktree=$HOME_DIR/projects/missing-$id" \
        "project=$HOME_DIR/projects/sample" "harness=codex" "kind=scout" "spawn_gen=fixture-$id" "decisions_reviewed=1"
    printf 'done: report complete\n' > "$HOME_DIR/state/$id.status"
}

test_teardown_posts_scout_report_once() {
    local id=rpt-sc1
    new_scout_home "$id"
    make_helper
    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 || fail "teardown of a scout with a report failed"
    assert_grep "--source scout --path $HOME_DIR/data/$id/report.md --title Scout: teardown probe" "$TMP/calls.log" "teardown posted the scout report"
    assert_equals 1 "$(wc -l < "$TMP/calls.log")" "teardown posted exactly once"
    assert_grep "$id" "$HOME_DIR/state/research-post.posted" "teardown recorded the post"
    pass "scout teardown posts the report once"
}

test_teardown_survives_post_failure() {
    local id=rpt-sc2
    new_scout_home "$id"
    make_helper
    FAKE_RC=3 FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 || fail "a failing post blocked scout teardown"
    assert_absent "$HOME_DIR/state/$id.meta" "teardown completed and removed the task record despite the post failure"
    assert_grep '"outcome":"error"' "$HOME_DIR/state/research-post.jsonl" "the failed post was logged"
    pass "scout teardown is fail-open when the post fails"
}

new_mate_home() {  # sets TMP, HOME_DIR (the secondmate home) and a local parent home
    new_home
    mkdir -p "$TMP/parent/state" "$HOME_DIR/data/x"
    printf 'mate1\n' > "$HOME_DIR/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP/parent" > "$HOME_DIR/.fm-secondmate-parent"
    printf '# Mate report\nbody text\n' > "$HOME_DIR/data/x/report.md"
}

test_secondmate_done_doc_posts_report() {
    new_mate_home
    make_helper
    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-secondmate-report.sh" --doc done 0123456789abcdef data/x/report.md "audit clean" >/dev/null || fail "secondmate report helper failed"
    assert_grep "--source scout --path $HOME_DIR/data/x/report.md --title Mate report" "$TMP/calls.log" "done --doc posted the report"
    assert_grep 'sm-0123456789abcdef' "$HOME_DIR/state/research-post.posted" "post recorded under the correlation id"
    assert_grep 'done [' "$TMP/parent/state/mate1.status" "the parent status line was still written"
    pass "secondmate done --doc report is posted to research"
}

test_secondmate_non_done_or_failing_post_is_harmless() {
    new_mate_home
    make_helper
    FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-secondmate-report.sh" --doc working 0123456789abcdef data/x/report.md "still going" >/dev/null || fail "working report failed"
    assert_absent "$TMP/calls.log" "a non-done report must not post"
    FAKE_RC=3 FM_HOME=$HOME_DIR FM_RESEARCH_POST_CMD=$TMP/fake-helper "$ROOT/bin/fm-secondmate-report.sh" --doc done 0123456789abcdef data/x/report.md "audit clean" >/dev/null || fail "a failing post changed the helper exit status"
    pass "non-done secondmate reports do not post and a failing post is harmless"
}

test_help_and_usage
test_posts_scout_report
test_title_falls_back_to_task_id
test_idempotent_rerun
test_fail_open_helper_error
test_missing_helper_command_does_not_crash
test_no_report_no_post
test_dry_run_posts_nothing
test_log_has_latency
test_no_secret_or_port_in_log
test_teardown_posts_scout_report_once
test_teardown_survives_post_failure
test_secondmate_done_doc_posts_report
test_secondmate_non_done_or_failing_post_is_harmless