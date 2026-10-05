#!/usr/bin/env bash
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-imports-approved)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

make_checkout() {
    local dir="$1"
    local origin_url="$2"
    mkdir -p "$dir"
    git init -q "$dir"
    git -C "$dir" remote add origin "$origin_url"
}

write_store() {
    local file="$1"
    local json="$2"
    mkdir -p "$(dirname "$file")"
    printf '%s' "$json" > "$file"
}

test_approved_when_store_has_explicit_approval_for_same_origin() {
    local case="$TMP_ROOT/approved_same_origin"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local checkout_dir="$case/checkout"
    local origin_url="https://github.com/acme/widget.git"
    make_checkout "$checkout_dir" "$origin_url"
    write_store "$claude_config_dir/.claude.json" '{"projects":{"'"$checkout_dir"'":{"hasClaudeMdExternalIncludesApproved":true}}}'
    local output
    output=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code=$?
    expect_code 0 "$code" "approved_when_store_has_explicit_approval_for_same_origin: exit code"
    if [ "$output" != "approved" ]; then
        fail "approved_when_store_has_explicit_approval_for_same_origin: expected 'approved' but got '$output'"
    fi
    pass "approved_when_store_has_explicit_approval_for_same_origin"
}

test_same_repo_in_scp_form_and_without_dot_git_matches() {
    local case="$TMP_ROOT/same_repo_forms"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local checkout_dir="$case/checkout"
    local origin_url="https://github.com/acme/widget.git"
    make_checkout "$checkout_dir" "$origin_url"
    write_store "$claude_config_dir/.claude.json" '{"projects":{"'"$checkout_dir"'":{"hasClaudeMdExternalIncludesApproved":true}}}'
    local output1
    output1=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "git@github.com:acme/widget" 2>&1)
    local code1=$?
    expect_code 0 "$code1" "same_repo_in_scp_form_and_without_dot_git_matches: exit code for scp form"
    if [ "$output1" != "approved" ]; then
        fail "same_repo_in_scp_form_and_without_dot_git_matches: expected 'approved' for scp form but got '$output1'"
    fi
    local output2
    output2=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "https://GitHub.com/acme/widget/" 2>&1)
    local code2=$?
    expect_code 0 "$code2" "same_repo_in_scp_form_and_without_dot_git_matches: exit code for https form"
    if [ "$output2" != "approved" ]; then
        fail "same_repo_in_scp_form_and_without_dot_git_matches: expected 'approved' for https form but got '$output2'"
    fi
    pass "same_repo_in_scp_form_and_without_dot_git_matches"
}

test_none_when_no_entry_exists() {
    local case="$TMP_ROOT/no_entry"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local checkout_dir="$case/checkout"
    local origin_url="https://github.com/acme/widget.git"
    make_checkout "$checkout_dir" "$origin_url"
    write_store "$claude_config_dir/.claude.json" '{"projects":{}}'
    local output
    output=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code=$?
    expect_code 1 "$code" "none_when_no_entry_exists: exit code"
    if [ "$output" != "none" ]; then
        fail "none_when_no_entry_exists: expected 'none' but got '$output'"
    fi
    pass "none_when_no_entry_exists"
}

test_none_when_approval_is_for_a_different_origin() {
    local case="$TMP_ROOT/different_origin"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local checkout_dir="$case/checkout"
    local other_origin="https://github.com/acme/other.git"
    make_checkout "$checkout_dir" "$other_origin"
    write_store "$claude_config_dir/.claude.json" '{"projects":{"'"$checkout_dir"'":{"hasClaudeMdExternalIncludesApproved":true}}}'
    local output
    output=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "https://github.com/acme/widget.git" 2>&1)
    local code=$?
    expect_code 1 "$code" "none_when_approval_is_for_a_different_origin: exit code"
    if [ "$output" != "none" ]; then
        fail "none_when_approval_is_for_a_different_origin: expected 'none' but got '$output'"
    fi
    pass "none_when_approval_is_for_a_different_origin"
}

test_never_asked_default_flags_are_not_an_approval() {
    local case="$TMP_ROOT/never_asked"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local checkout_dir="$case/checkout"
    local origin_url="https://github.com/acme/widget.git"
    make_checkout "$checkout_dir" "$origin_url"
    write_store "$claude_config_dir/.claude.json" '{"projects":{"'"$checkout_dir"'":{"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":false}}}'
    local output
    output=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code=$?
    expect_code 1 "$code" "never_asked_default_flags_are_not_an_approval: exit code"
    if [ "$output" != "none" ]; then
        fail "never_asked_default_flags_are_not_an_approval: expected 'none' but got '$output'"
    fi
    pass "never_asked_default_flags_are_not_an_approval"
}

test_an_explicit_decline_wins_over_an_approval_in_another_store() {
    local case="$TMP_ROOT/decline_wins"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local origin_url="https://github.com/acme/widget.git"
    local approval_checkout="$case/approval_checkout"
    make_checkout "$approval_checkout" "$origin_url"
    write_store "$claude_config_dir/.claude.json" '{"projects":{"'"$approval_checkout"'":{"hasClaudeMdExternalIncludesApproved":true}}}'
    local decline_checkout="$case/decline_checkout"
    make_checkout "$decline_checkout" "$origin_url"
    local account_store_dir="$case/account_store"
    mkdir -p "$account_store_dir"
    write_store "$account_store_dir/.claude.json" '{"projects":{"'"$decline_checkout"'":{"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":true}}}'
    local accounts_file="$fm_config_override/claude-accounts"
    mkdir -p "$(dirname "$accounts_file")"
    printf 'account acct1 %s\n' "$account_store_dir" > "$accounts_file"
    local output
    output=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code=$?
    expect_code 1 "$code" "an_explicit_decline_wins_over_an_approval_in_another_store: exit code"
    if [ "$output" != "none" ]; then
        fail "an_explicit_decline_wins_over_an_approval_in_another_store: expected 'none' but got '$output'"
    fi
    pass "an_explicit_decline_wins_over_an_approval_in_another_store"
}

test_approval_in_an_account_store_listed_in_claude_accounts_counts() {
    local case="$TMP_ROOT/account_store_approval"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local origin_url="https://github.com/acme/widget.git"
    local approval_checkout="$case/approval_checkout"
    make_checkout "$approval_checkout" "$origin_url"
    local account_store_dir="$case/account_store"
    mkdir -p "$account_store_dir"
    write_store "$account_store_dir/.claude.json" '{"projects":{"'"$approval_checkout"'":{"hasClaudeMdExternalIncludesApproved":true}}}'
    local accounts_file="$fm_config_override/claude-accounts"
    mkdir -p "$(dirname "$accounts_file")"
    printf '# comment line\n\nsnapshot /nonexistent/snap.json\naccount acct1 %s\n' "$account_store_dir" > "$accounts_file"
    local output
    output=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code=$?
    expect_code 0 "$code" "approval_in_an_account_store_listed_in_claude_accounts_counts: exit code"
    if [ "$output" != "approved" ]; then
        fail "approval_in_an_account_store_listed_in_claude_accounts_counts: expected 'approved' but got '$output'"
    fi
    pass "approval_in_an_account_store_listed_in_claude_accounts_counts"
}

test_missing_or_corrupt_stores_are_skipped() {
    local case="$TMP_ROOT/corrupt_stores"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local origin_url="https://github.com/acme/widget.git"
    local approval_checkout="$case/approval_checkout"
    make_checkout "$approval_checkout" "$origin_url"
    local account_store_dir="$case/account_store"
    mkdir -p "$account_store_dir"
    write_store "$account_store_dir/.claude.json" '{"projects":{"'"$approval_checkout"'":{"hasClaudeMdExternalIncludesApproved":true}}}'
    local accounts_file="$fm_config_override/claude-accounts"
    printf 'account acct1 %s\n' "$account_store_dir" > "$accounts_file"

    printf 'not json' > "$claude_config_dir/.claude.json"
    local output1
    output1=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code1=$?
    expect_code 0 "$code1" "test_missing_or_corrupt_stores_are_skipped: exit code for corrupt default store with valid account store"
    if [ "$output1" != "approved" ]; then
        fail "test_missing_or_corrupt_stores_are_skipped: expected 'approved' but got '$output1'"
    fi

    local case2="$TMP_ROOT/corrupt_only"
    local home2="$case2/home"
    local claude_config_dir2="$case2/claude_config"
    local fm_home2="$case2/fm_home"
    local fm_config_override2="$case2/fm_config_override"
    mkdir -p "$home2" "$claude_config_dir2" "$fm_home2" "$fm_config_override2"
    printf 'not json' > "$claude_config_dir2/.claude.json"
    local output2
    output2=$(HOME="$home2" CLAUDE_CONFIG_DIR="$claude_config_dir2" FM_HOME="$fm_home2" FM_CONFIG_OVERRIDE="$fm_config_override2" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code2=$?
    expect_code 1 "$code2" "test_missing_or_corrupt_stores_are_skipped: exit code for only corrupt store"
    if [ "$output2" != "none" ]; then
        fail "test_missing_or_corrupt_stores_are_skipped: expected 'none' but got '$output2'"
    fi
    pass "test_missing_or_corrupt_stores_are_skipped"
}

test_approval_whose_path_is_not_a_directory_is_ignored() {
    local case="$TMP_ROOT/nonexistent_path"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local origin_url="https://github.com/acme/widget.git"
    local fake_path="$case/nonexistent"
    write_store "$claude_config_dir/.claude.json" '{"projects":{"'"$fake_path"'":{"hasClaudeMdExternalIncludesApproved":true}}}'
    local output
    output=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code=$?
    expect_code 1 "$code" "test_approval_whose_path_is_not_a_directory_is_ignored: exit code"
    if [ "$output" != "none" ]; then
        fail "test_approval_whose_path_is_not_a_directory_is_ignored: expected 'none' but got '$output'"
    fi
    pass "test_approval_whose_path_is_not_a_directory_is_ignored"
}

test_wrong_arguments_exit_two() {
    local case="$TMP_ROOT/wrong_args"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local stdout1="$case/stdout1"
    local stderr1="$case/stderr1"
    HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" >"$stdout1" 2>"$stderr1"
    local code1=$?
    expect_code 2 "$code1" "test_wrong_arguments_exit_two: exit code for no argument"
    if [ -s "$stdout1" ]; then
        fail "test_wrong_arguments_exit_two: expected empty stdout for no argument"
    fi
    if [ ! -s "$stderr1" ]; then
        fail "test_wrong_arguments_exit_two: expected non-empty stderr for no argument"
    fi
    local stdout2="$case/stdout2"
    local stderr2="$case/stderr2"
    HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "arg1" "arg2" >"$stdout2" 2>"$stderr2"
    local code2=$?
    expect_code 2 "$code2" "test_wrong_arguments_exit_two: exit code for two arguments"
    if [ -s "$stdout2" ]; then
        fail "test_wrong_arguments_exit_two: expected empty stdout for two arguments"
    fi
    if [ ! -s "$stderr2" ]; then
        fail "test_wrong_arguments_exit_two: expected non-empty stderr for two arguments"
    fi
    pass "test_wrong_arguments_exit_two"
}

test_never_writes_the_store() {
    local case="$TMP_ROOT/never_writes"
    local home="$case/home"
    local claude_config_dir="$case/claude_config"
    local fm_home="$case/fm_home"
    local fm_config_override="$case/fm_config_override"
    mkdir -p "$home" "$claude_config_dir" "$fm_home" "$fm_config_override"
    local checkout_dir="$case/checkout"
    local origin_url="https://github.com/acme/widget.git"
    make_checkout "$checkout_dir" "$origin_url"
    local store_file="$claude_config_dir/.claude.json"
    write_store "$store_file" '{"projects":{"'"$checkout_dir"'":{"hasClaudeMdExternalIncludesApproved":true}}}'
    local before_file="$case/store_before"
    cp "$store_file" "$before_file"
    local output
    output=$(HOME="$home" CLAUDE_CONFIG_DIR="$claude_config_dir" FM_HOME="$fm_home" FM_CONFIG_OVERRIDE="$fm_config_override" "$ROOT/bin/fm-claude-imports-approved.sh" "$origin_url" 2>&1)
    local code=$?
    expect_code 0 "$code" "test_never_writes_the_store: exit code"
    if [ "$output" != "approved" ]; then
        fail "test_never_writes_the_store: expected 'approved' but got '$output'"
    fi
    if ! cmp -s "$store_file" "$before_file"; then
        fail "test_never_writes_the_store: store file was modified"
    fi
    pass "test_never_writes_the_store"
}

test_approved_when_store_has_explicit_approval_for_same_origin
test_same_repo_in_scp_form_and_without_dot_git_matches
test_none_when_no_entry_exists
test_none_when_approval_is_for_a_different_origin
test_never_asked_default_flags_are_not_an_approval
test_an_explicit_decline_wins_over_an_approval_in_another_store
test_approval_in_an_account_store_listed_in_claude_accounts_counts
test_missing_or_corrupt_stores_are_skipped
test_approval_whose_path_is_not_a_directory_is_ignored
test_wrong_arguments_exit_two
test_never_writes_the_store
