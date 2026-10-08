#!/usr/bin/env bash
# Tests for fan-out gate callers
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_merge_local_refuses_without_fanout() {
    local tmp
    tmp=$(fm_test_tmproot)
    mkdir -p "$tmp/state" "$tmp/data"

    fm_write_meta "$tmp/state/t1.meta" \
        project="$tmp/proj" \
        kind=ship \
        mode=local-only \
        window=fm-t1 \
        worktree="$tmp/wt"

    local err
    err="$tmp/err"
    local rc
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_FANOUT_LEDGER="$tmp/units.jsonl" \
        "$ROOT/bin/fm-merge-local.sh" t1 >"$tmp/out" 2>"$err"
    rc=$?

    expect_code 1 $rc "merge-local without fanout should fail"
    assert_grep "fan-out evidence" "$err" "error message should mention fan-out evidence"
}

test_merge_local_override_passes_gate_and_records_reason() {
    local tmp
    tmp=$(fm_test_tmproot)
    mkdir -p "$tmp/state" "$tmp/data"

    fm_write_meta "$tmp/state/t1.meta" \
        project="$tmp/proj" \
        kind=ship \
        mode=local-only \
        window=fm-t1 \
        worktree="$tmp/wt"

    local err
    err="$tmp/err"
    local rc
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_FANOUT_LEDGER="$tmp/units.jsonl" \
        "$ROOT/bin/fm-merge-local.sh" t1 --allow-no-fanout "docs only" >"$tmp/out" 2>"$err"
    rc=$?

    assert_no_grep "fan-out evidence" "$err" "stderr should not contain fan-out evidence"
    assert_grep "fanout_override=docs only" "$tmp/state/t1.meta" "meta should contain fanout_override"
}

test_merge_local_override_needs_reason() {
    local tmp
    tmp=$(fm_test_tmproot)
    mkdir -p "$tmp/state" "$tmp/data"

    fm_write_meta "$tmp/state/t1.meta" \
        project="$tmp/proj" \
        kind=ship \
        mode=local-only \
        window=fm-t1 \
        worktree="$tmp/wt"

    local err
    err="$tmp/err"
    local rc
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_FANOUT_LEDGER="$tmp/units.jsonl" \
        "$ROOT/bin/fm-merge-local.sh" t1 --allow-no-fanout >"$tmp/out" 2>"$err"
    rc=$?

    expect_code 2 $rc "override without reason should fail with code 2"
}

test_brief_text_is_free_only() {
    local home
    home=$(fm_test_tmproot)
    mkdir -p "$home/data"

    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-gate-a1 some-proj --mode no-mistakes >/dev/null

    local brief
    brief="$home/data/brief-gate-a1/brief.md"

    assert_no_grep "iron rule" "$brief" "brief should not contain iron rule"
    assert_no_grep "may go to a paid model" "$brief" "brief should not mention paid model"
    assert_grep "the merge is refused" "$brief" "brief should mention merge refused"

    local build_section
    build_section=$(sed -n '/^# Build method/,/^# Definition of done/p' "$brief")
    if echo "$build_section" | grep -q "blocked:"; then
        pass "Build method section contains blocked:"
    else
        fail "Build method section should contain blocked:"
    fi
}

test_pr_merge_refuses_without_fanout() {
    local tmp
    tmp=$(fm_test_tmproot)
    mkdir -p "$tmp/state" "$tmp/data"

    fm_write_meta "$tmp/state/t1.meta" \
        project="$tmp/proj" \
        kind=ship \
        mode=no-mistakes \
        window=fm-t1 \
        worktree="$tmp/wt"

    mkdir -p "$tmp/fakebin"
    cat > "$tmp/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$tmp/fakebin/gh"

    local err
    err="$tmp/err"
    local rc
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_FANOUT_LEDGER="$tmp/units.jsonl" \
        PATH="$tmp/fakebin:$PATH" \
        "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/example/repo/pull/9 >"$tmp/out" 2>"$err"
    rc=$?

    expect_code 1 $rc "pr-merge without fanout should fail"
    assert_grep "fan-out evidence" "$err" "error message should mention fan-out evidence"
}

test_pr_merge_refuses_free_exhausted_unit() {
    local tmp
    tmp=$(fm_test_tmproot)
    mkdir -p "$tmp/state" "$tmp/data"

    fm_write_meta "$tmp/state/t1.meta" \
        project="$tmp/proj" \
        kind=ship \
        mode=no-mistakes \
        window=fm-t1 \
        worktree="$tmp/wt"

    mkdir -p "$tmp/fakebin"
    cat > "$tmp/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$tmp/fakebin/gh"

    echo "working [at=1]: fan-out runs fr-20261005T010203Z-abc123" > "$tmp/state/t1.status"
    echo '{"run_id":"fr-20261005T010203Z-abc123","label":"u1","outcome":"free_exhausted"}' > "$tmp/units.jsonl"

    local err
    err="$tmp/err"
    local rc
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_FANOUT_LEDGER="$tmp/units.jsonl" \
        PATH="$tmp/fakebin:$PATH" \
        "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/example/repo/pull/9 >"$tmp/out" 2>"$err"
    rc=$?

    expect_code 1 $rc "pr-merge with free_exhausted should fail"
    assert_grep "fan-out evidence" "$err" "error message should mention fan-out evidence"
}

test_pr_merge_override_passes_gate_and_records_reason() {
    local tmp
    tmp=$(fm_test_tmproot)
    mkdir -p "$tmp/state" "$tmp/data"

    fm_write_meta "$tmp/state/t1.meta" \
        project="$tmp/proj" \
        kind=ship \
        mode=no-mistakes \
        window=fm-t1 \
        worktree="$tmp/wt"

    mkdir -p "$tmp/fakebin"
    cat > "$tmp/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$tmp/fakebin/gh"

    local err
    err="$tmp/err"
    local rc
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" FM_FANOUT_LEDGER="$tmp/units.jsonl" \
        PATH="$tmp/fakebin:$PATH" \
        "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/example/repo/pull/9 --allow-no-fanout "docs only" >"$tmp/out" 2>"$err"
    rc=$?

    assert_grep "fanout gate skipped: docs only" "$err" "stderr should contain fanout gate skipped"
    assert_no_grep "fan-out evidence" "$err" "stderr should not contain fan-out evidence"
    assert_grep "fanout_override=docs only" "$tmp/state/t1.meta" "meta should contain fanout_override"
}

test_merge_local_refuses_without_fanout
test_merge_local_override_passes_gate_and_records_reason
test_merge_local_override_needs_reason
test_brief_text_is_free_only
test_pr_merge_refuses_without_fanout
test_pr_merge_refuses_free_exhausted_unit
test_pr_merge_override_passes_gate_and_records_reason