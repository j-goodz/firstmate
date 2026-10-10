#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-refill.sh"
FIXTURE="$ROOT/tests/fixtures/refill/ready_now.json"

# shellcheck disable=SC2034
FM_REFILL_DEFAULT_CAP=4

write_sysfs() {
    local dir="$1"
    mkdir -p "$dir/thermal_zone0"
    echo "x86_pkg_temp" > "$dir/thermal_zone0/type"
    echo "55000" > "$dir/thermal_zone0/temp"
}

make_stubs() {
    local case_dir="$1"
    mkdir -p "$case_dir"
    export CASE="$case_dir"
    cat > "$case_dir/nexus" <<'STUB'
#!/usr/bin/env bash
set -u
echo "nexus $*" >> "$CASE/calls.log"
if [[ "$1" == "task" && "$2" == "claim" ]]; then
    if [[ -f "$CASE/claim-fails" && "$3" == "$(cat "$CASE/claim-fails")" ]]; then
        exit 1
    fi
    exit 0
fi
if [[ "$1" == "exists" ]]; then
    echo "noise"
    echo 'EXISTS-RECEIPT systems=stubsys'
    exit 0
fi
exit 0
STUB
    chmod +x "$case_dir/nexus"

    cat > "$case_dir/tasks" <<'STUB'
#!/usr/bin/env bash
set -u
echo "tasks $*" >> "$CASE/calls.log"
exit 0
STUB
    chmod +x "$case_dir/tasks"

    cat > "$case_dir/brief" <<'STUB'
#!/usr/bin/env bash
set -u
echo "brief $*" >> "$CASE/calls.log"
brief_dir="$FM_HOME/data/$1"
mkdir -p "$brief_dir"
cat > "$brief_dir/brief.md" <<'BRIEF'
# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}

## Exists receipt
Run `nexus exists "<x>"` and paste its final line here; spawn verifies it against the nexus ledger.
BRIEF
STUB
    chmod +x "$case_dir/brief"

    cat > "$case_dir/spawn" <<'STUB'
#!/usr/bin/env bash
set -u
echo "spawn $*" >> "$CASE/calls.log"
exit 0
STUB
    chmod +x "$case_dir/spawn"

    cat > "$case_dir/resolve" <<'STUB'
#!/usr/bin/env bash
set -u
echo "resolve $*" >> "$CASE/calls.log"
exit 0
STUB
    chmod +x "$case_dir/resolve"
}

run_refill() {
    OUT=$("$SCRIPT" "$@" 2>"$CASE/err")
    RC=$?
}

test_real_fixture_keeps_auto_build_rows() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "real_fixture_keeps")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
- buzz [direct-PR +yolo] - buzz
- hive [local-only] - hive
- dotfiles [direct-PR +yolo] - dotfiles
- firstmate [no-mistakes] - firstmate
- zentop-config [] - zentop-config
REG

    run_refill select --projects nexus,buzz,hive,dotfiles,firstmate --ready-file "$FIXTURE"
    expect_code 0 "$RC" "select exit"
    local select_out="$OUT"
    local line_count
    line_count=$(echo "$select_out" | grep -c '^' || true)
    assert_equals 299 "$line_count" "select prints 299 ids"

    run_refill count --projects nexus,buzz,hive,dotfiles,firstmate --ready-file "$FIXTURE"
    expect_code 0 "$RC" "count exit"
    local count_out="$OUT"
    local first_word
    first_word=$(echo "$count_out" | awk '{print $1}')
    assert_equals 299 "$first_word" "count first word 299"
    local second_word
    second_word=$(echo "$count_out" | awk '{print $2}')
    local comma_count
    comma_count=$(echo "$second_word" | tr ',' '\n' | wc -l)
    assert_equals 3 "$comma_count" "count second word has 3 ids"

    local expected_ids
    expected_ids=$(jq -r '
        .ready[]
        | select(.mode == "auto")
        | select(.type == "bug" or .type == "chore" or .type == "feature")
        | select(.tier == "" or .tier == null or .tier == "sonnet" or .tier == "free-direct" or .tier == "swarm")
        | select(.status == "open")
        | select(.claimed_by == "" or .claimed_by == null)
        | select(.project == "nexus" or .project == "buzz" or .project == "hive" or .project == "dotfiles" or .project == "firstmate")
        | .id
    ' "$FIXTURE")
    assert_equals "$expected_ids" "$select_out" "select output matches jq filter"

    assert_not_contains "$select_out" "9c9d6860e516" "claimed id absent"
    pass "real_fixture_keeps_auto_build_rows"
}

test_real_fixture_drops_other_classes() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "real_fixture_drops")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
- buzz [direct-PR +yolo] - buzz
- hive [local-only] - hive
- dotfiles [direct-PR +yolo] - dotfiles
- firstmate [no-mistakes] - firstmate
- zentop-config [] - zentop-config
REG

    run_refill select --projects nexus,buzz,hive,dotfiles,firstmate --ready-file "$FIXTURE"
    expect_code 0 "$RC" "select exit"
    local select_out="$OUT"

    local dropped_mode
    dropped_mode=$(jq -r '
        .ready[]
        | select(.mode != "auto")
        | select(.project == "nexus" or .project == "buzz" or .project == "hive" or .project == "dotfiles" or .project == "firstmate")
        | .id
    ' "$FIXTURE")
    local dropped_type
    dropped_type=$(jq -r '
        .ready[]
        | select(.type == "research" or .type == "decision" or .type == "milestone")
        | select(.project == "nexus" or .project == "buzz" or .project == "hive" or .project == "dotfiles" or .project == "firstmate")
        | .id
    ' "$FIXTURE")
    local dropped_tier
    dropped_tier=$(jq -r '
        .ready[]
        | select(.tier == "opus" or .tier == "fable" or .tier == "operator")
        | select(.project == "nexus" or .project == "buzz" or .project == "hive" or .project == "dotfiles" or .project == "firstmate")
        | .id
    ' "$FIXTURE")

    local non_empty_mode=0
    local non_empty_type=0
    local non_empty_tier=0
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        non_empty_mode=1
        assert_not_contains "$select_out" "$id" "mode!=auto id $id absent"
    done <<< "$dropped_mode"
    assert_equals 1 "$non_empty_mode" "dropped mode set non-empty"

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        non_empty_type=1
        assert_not_contains "$select_out" "$id" "type research/decision/milestone id $id absent"
    done <<< "$dropped_type"
    assert_equals 1 "$non_empty_type" "dropped type set non-empty"

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        non_empty_tier=1
        assert_not_contains "$select_out" "$id" "tier opus/fable/operator id $id absent"
    done <<< "$dropped_tier"
    assert_equals 1 "$non_empty_tier" "dropped tier set non-empty"

    pass "real_fixture_drops_other_classes"
}

test_scope_limits_projects() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "scope_limits")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
- buzz [direct-PR +yolo] - buzz
- hive [local-only] - hive
- dotfiles [direct-PR +yolo] - dotfiles
- firstmate [no-mistakes] - firstmate
- zentop-config [] - zentop-config
REG

    run_refill select --projects zentop-config --ready-file "$FIXTURE"
    expect_code 0 "$RC" "select zentop-config"
    assert_equals "aba069844b8b" "$OUT" "select prints zentop-config id"

    run_refill count --projects zentop-config --ready-file "$FIXTURE"
    expect_code 0 "$RC" "count zentop-config"
    assert_equals "1 aba069844b8b" "$OUT" "count prints 1 and id"

    run_refill count --projects nonesuch --ready-file "$FIXTURE"
    expect_code 0 "$RC" "count nonesuch"
    assert_equals "0" "$OUT" "count prints 0 for unknown project"

    pass "scope_limits_projects"
}

test_not_to_build_markers_drop_rows() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "not_to_build")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
- buzz [direct-PR +yolo] - buzz
- hive [local-only] - hive
- dotfiles [direct-PR +yolo] - dotfiles
- firstmate [no-mistakes] - firstmate
- zentop-config [] - zentop-config
REG

    local kept_ids
    kept_ids=$(jq -r '
        .ready[]
        | select(.mode == "auto")
        | select(.type == "bug" or .type == "chore" or .type == "feature")
        | select(.tier == "" or .tier == null or .tier == "sonnet" or .tier == "free-direct" or .tier == "swarm")
        | select(.status == "open")
        | select(.claimed_by == "" or .claimed_by == null)
        | select(.project == "nexus" or .project == "buzz" or .project == "hive" or .project == "dotfiles" or .project == "firstmate")
        | .id
    ' "$FIXTURE" | head -6)

    local modified_fixture="$CASE/modified.json"
    jq --argjson ids "$(echo "$kept_ids" | jq -R . | jq -s .)" '
        .ready |= map(
            if .id == $ids[0] then .body = "Add the thing. Do not build this until the design is signed off."
            elif .id == $ids[1] then .body = "SPEC FIRST\nthen build"
            elif .id == $ids[2] then .body = "Build later, after the migration."
            elif .id == $ids[3] then .body = "Reuse it; do not build a second mechanism."
            elif .id == $ids[4] then .body = "Regression test written from this spec first; affected tests only."
            elif .id == $ids[5] then .body = "Later: revisit when the hub is quiet."
            else . end
        )
    ' "$FIXTURE" > "$modified_fixture"

    run_refill select --projects nexus,buzz,hive,dotfiles,firstmate --ready-file "$modified_fixture"
    expect_code 0 "$RC" "select modified"
    local select_out="$OUT"

    local id1 id2 id3 id4 id5 id6
    id1=$(echo "$kept_ids" | sed -n '1p')
    id2=$(echo "$kept_ids" | sed -n '2p')
    id3=$(echo "$kept_ids" | sed -n '3p')
    id4=$(echo "$kept_ids" | sed -n '4p')
    id5=$(echo "$kept_ids" | sed -n '5p')
    id6=$(echo "$kept_ids" | sed -n '6p')

    assert_not_contains "$select_out" "$id1" "id1 dropped (do not build until)"
    assert_not_contains "$select_out" "$id2" "id2 dropped (SPEC FIRST)"
    assert_not_contains "$select_out" "$id3" "id3 dropped (Build later)"
    assert_contains "$select_out" "$id4" "id4 kept (reuse not marker)"
    assert_contains "$select_out" "$id5" "id5 kept (written from this spec first not marker)"
    assert_not_contains "$select_out" "$id6" "id6 dropped (Later:)"

    pass "not_to_build_markers_drop_rows"
}

test_dry_run_runs_nothing_and_logs() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "dry_run")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
- buzz [direct-PR +yolo] - buzz
- hive [local-only] - hive
- dotfiles [direct-PR +yolo] - dotfiles
- firstmate [no-mistakes] - firstmate
- zentop-config [] - zentop-config
REG

    run_refill run --dry-run --slots 2 --projects nexus --ready-file "$FIXTURE"
    expect_code 0 "$RC" "dry-run exit"
    local out_lines
    out_lines=$(echo "$OUT" | grep -c '^would dispatch ' || true)
    assert_equals 2 "$out_lines" "two would dispatch lines"

    local first_two
    first_two=$(run_refill select --projects nexus --ready-file "$FIXTURE" && echo "$OUT" | head -2)
    local expected1 expected2
    expected1=$(echo "$first_two" | sed -n '1p')
    expected2=$(echo "$first_two" | sed -n '2p')
    assert_contains "$OUT" "would dispatch $expected1" "first would dispatch matches"
    assert_contains "$OUT" "would dispatch $expected2" "second would dispatch matches"

    assert_absent "$CASE/calls.log" "calls.log absent in dry-run"

    local log_valid=1
    while IFS= read -r line; do
        echo "$line" | jq -e . >/dev/null 2>&1 || log_valid=0
    done < "$FM_REFILL_LOG"
    assert_equals 1 "$log_valid" "all log lines valid JSON"

    local would_count
    would_count=$(jq -s 'map(select(.decision == "would_dispatch")) | length' "$FM_REFILL_LOG")
    assert_equals 2 "$would_count" "two would_dispatch log rows"

    local dry_run_true
    dry_run_true=$(jq -s 'map(select(.decision == "would_dispatch" and .dry_run == true)) | length' "$FM_REFILL_LOG")
    assert_equals 2 "$dry_run_true" "would_dispatch rows have dry_run true"

    local fill_row
    fill_row=$(jq -s 'map(select(.decision == "fill")) | .[0]' "$FM_REFILL_LOG")
    local filled
    filled=$(echo "$fill_row" | jq -r '.filled')
    local slots
    slots=$(echo "$fill_row" | jq -r '.slots')
    assert_equals 2 "$filled" "fill row filled=2"
    assert_equals 2 "$slots" "fill row slots=2"

    pass "dry_run_runs_nothing_and_logs"
}

test_run_claims_before_spawning_and_fills_exactly_slots() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "run_claims")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- dotfiles [direct-PR +yolo] - dotfiles
- nexus [no-mistakes-prod-only] - nexus
REG

    local kept_ids
    kept_ids=$(run_refill select --projects nexus,dotfiles --ready-file "$FIXTURE" && echo "$OUT")
    local id1 id2
    id1=$(echo "$kept_ids" | sed -n '1p')
    id2=$(echo "$kept_ids" | sed -n '2p')
    local proj1 proj2
    proj1=$(jq -r --arg id "$id1" '.ready[] | select(.id == $id) | .project' "$FIXTURE")
    proj2=$(jq -r --arg id "$id2" '.ready[] | select(.id == $id) | .project' "$FIXTURE")

    run_refill run --slots 2 --projects nexus,dotfiles --ready-file "$FIXTURE" --limit 2
    expect_code 0 "$RC" "run exit"

    local spawn_count
    spawn_count=$(grep -c '^spawn ' "$CASE/calls.log" || true)
    assert_equals 2 "$spawn_count" "two spawn calls"

    local nx1="nx-${id1:0:8}"
    local nx2="nx-${id2:0:8}"

    local claim1_line claim2_line spawn1_line spawn2_line brief1_line brief2_line
    claim1_line=$(grep -n "nexus task claim $id1" "$CASE/calls.log" | head -1 | cut -d: -f1)
    claim2_line=$(grep -n "nexus task claim $id2" "$CASE/calls.log" | head -1 | cut -d: -f1)
    spawn1_line=$(grep -n "spawn $nx1" "$CASE/calls.log" | head -1 | cut -d: -f1)
    spawn2_line=$(grep -n "spawn $nx2" "$CASE/calls.log" | head -1 | cut -d: -f1)
    brief1_line=$(grep -n "brief $nx1" "$CASE/calls.log" | head -1 | cut -d: -f1)
    brief2_line=$(grep -n "brief $nx2" "$CASE/calls.log" | head -1 | cut -d: -f1)

    [[ -n "$claim1_line" && -n "$spawn1_line" && -n "$brief1_line" ]] || fail "missing lines for id1"
    [[ -n "$claim2_line" && -n "$spawn2_line" && -n "$brief2_line" ]] || fail "missing lines for id2"
    assert_equals 1 $((claim1_line < spawn1_line && claim1_line < brief1_line)) "claim before spawn/brief for id1"
    assert_equals 1 $((claim2_line < spawn2_line && claim2_line < brief2_line)) "claim before spawn/brief for id2"

    local spawn1_args spawn2_args
    spawn1_args=$(grep "spawn $nx1" "$CASE/calls.log" | head -1)
    spawn2_args=$(grep "spawn $nx2" "$CASE/calls.log" | head -1)

    if [[ "$proj1" == "dotfiles" ]]; then
        assert_contains "$spawn1_args" "--mode direct-PR" "dotfiles spawn mode direct-PR"
        assert_contains "$spawn1_args" "--yolo on" "dotfiles spawn yolo on"
    else
        assert_contains "$spawn1_args" "--mode no-mistakes" "nexus spawn mode no-mistakes"
        assert_contains "$spawn1_args" "--yolo off" "nexus spawn yolo off"
    fi
    if [[ "$proj2" == "dotfiles" ]]; then
        assert_contains "$spawn2_args" "--mode direct-PR" "dotfiles spawn mode direct-PR"
        assert_contains "$spawn2_args" "--yolo on" "dotfiles spawn yolo on"
    else
        assert_contains "$spawn2_args" "--mode no-mistakes" "nexus spawn mode no-mistakes"
        assert_contains "$spawn2_args" "--yolo off" "nexus spawn yolo off"
    fi
    assert_contains "$spawn1_args" "--harness claude --model sonnet --effort medium" "spawn1 has harness flags"
    assert_contains "$spawn2_args" "--harness claude --model sonnet --effort medium" "spawn2 has harness flags"

    local brief1_file="$home/data/$nx1/brief.md"
    local brief2_file="$home/data/$nx2/brief.md"
    assert_present "$brief1_file" "brief1 exists"
    assert_present "$brief2_file" "brief2 exists"
    assert_not_contains "$(cat "$brief1_file")" "{TASK}" "brief1 no TASK placeholder"
    assert_not_contains "$(cat "$brief1_file")" "{FIRSTMATE_SPEC}" "brief1 no FIRSTMATE_SPEC placeholder"
    assert_not_contains "$(cat "$brief2_file")" "{TASK}" "brief2 no TASK placeholder"
    assert_not_contains "$(cat "$brief2_file")" "{FIRSTMATE_SPEC}" "brief2 no FIRSTMATE_SPEC placeholder"
    assert_contains "$(cat "$brief1_file")" "EXISTS-RECEIPT systems=stubsys" "brief1 has receipt"
    assert_contains "$(cat "$brief2_file")" "EXISTS-RECEIPT systems=stubsys" "brief2 has receipt"
    assert_contains "$(cat "$brief1_file")" "$id1" "brief1 contains task id"
    assert_contains "$(cat "$brief2_file")" "$id2" "brief2 contains task id"

    local dispatched_count
    dispatched_count=$(jq -s 'map(select(.decision == "dispatched")) | length' "$FM_REFILL_LOG")
    assert_equals 2 "$dispatched_count" "two dispatched log rows"

    local backlog_ids
    backlog_ids=$(jq -sr 'map(select(.decision == "dispatched")) | .[].backlog_id' "$FM_REFILL_LOG")
    echo "$backlog_ids" | grep -q "^nx-" || fail "backlog_id starts with nx-"

    local fill_row
    fill_row=$(jq -s 'map(select(.decision == "fill")) | .[0]' "$FM_REFILL_LOG")
    local filled
    filled=$(echo "$fill_row" | jq -r '.filled')
    assert_equals 2 "$filled" "fill row filled=2"

    pass "run_claims_before_spawning_and_fills_exactly_slots"
}

test_claim_failure_skips_to_next_candidate() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "claim_fail")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
REG

    local kept_ids
    kept_ids=$(run_refill select --projects nexus --ready-file "$FIXTURE" && echo "$OUT")
    local id1 id2
    id1=$(echo "$kept_ids" | sed -n '1p')
    id2=$(echo "$kept_ids" | sed -n '2p')

    echo "$id1" > "$CASE/claim-fails"

    run_refill run --slots 1 --projects nexus --ready-file "$FIXTURE"
    expect_code 0 "$RC" "run with claim fail"

    local spawn_count
    spawn_count=$(grep -c '^spawn ' "$CASE/calls.log" || true)
    assert_equals 1 "$spawn_count" "one spawn call"

    local nx1="nx-${id1:0:8}"
    local nx2="nx-${id2:0:8}"
    assert_not_contains "$(cat "$CASE/calls.log")" "spawn $nx1" "no spawn for failed claim id"
    assert_contains "$(cat "$CASE/calls.log")" "spawn $nx2" "spawn for second id"

    local claim_failed_count
    claim_failed_count=$(jq -s 'map(select(.decision == "claim_failed")) | length' "$FM_REFILL_LOG")
    assert_equals 1 "$claim_failed_count" "one claim_failed log row"
    local claim_failed_task
    claim_failed_task=$(jq -sr 'map(select(.decision == "claim_failed")) | .[0].task' "$FM_REFILL_LOG")
    assert_equals "$id1" "$claim_failed_task" "claim_failed task is first id"

    local dispatched_count
    dispatched_count=$(jq -s 'map(select(.decision == "dispatched")) | length' "$FM_REFILL_LOG")
    assert_equals 1 "$dispatched_count" "one dispatched log row"
    local dispatched_task
    dispatched_task=$(jq -sr 'map(select(.decision == "dispatched")) | .[0].task' "$FM_REFILL_LOG")
    assert_equals "$id2" "$dispatched_task" "dispatched task is second id"

    local fill_row
    fill_row=$(jq -s 'map(select(.decision == "fill")) | .[0]' "$FM_REFILL_LOG")
    local filled
    filled=$(echo "$fill_row" | jq -r '.filled')
    assert_equals 1 "$filled" "fill row filled=1"

    pass "claim_failure_skips_to_next_candidate"
}

test_no_free_slots_does_nothing() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "no_free_slots")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
REG

    run_refill run --slots 0 --projects nexus --ready-file "$FIXTURE"
    expect_code 0 "$RC" "run slots 0 exit"
    assert_contains "$OUT" "nothing to fill" "output contains nothing to fill"

    assert_absent "$CASE/calls.log" "calls.log absent"

    local log_rows
    log_rows=$(jq -s 'length' "$FM_REFILL_LOG")
    assert_equals 1 "$log_rows" "exactly one log row"
    local fill_row
    fill_row=$(jq -s '.[0]' "$FM_REFILL_LOG")
    local decision
    decision=$(echo "$fill_row" | jq -r '.decision')
    local reason
    reason=$(echo "$fill_row" | jq -r '.reason')
    assert_equals "fill" "$decision" "decision is fill"
    assert_equals "no free slots" "$reason" "reason is no free slots"

    pass "no_free_slots_does_nothing"
}

test_slots_default_to_thermal_cap_minus_busy() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "slots_default")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
REG

    echo "max_workers=2" > "$home/config/thermal-gate"

    run_refill run --dry-run --projects nexus --ready-file "$FIXTURE"
    expect_code 0 "$RC" "dry-run no busy"
    local out_lines
    out_lines=$(echo "$OUT" | grep -c '^would dispatch ' || true)
    assert_equals 2 "$out_lines" "two would dispatch with 2 max_workers"

    local w1_meta="$home/state/w1.meta"
    cat > "$w1_meta" <<'META'
window=firstmate:fm-w1
endpoint_task_id=w1
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
    echo "gen-w1" > "$home/state/w1.busy-gen"
    echo "v1 gen=gen-w1 seq=1 state=busy source=claude-hook event=ev-w1 ts=1700000000" > "$home/state/w1.busy-state"

    run_refill run --dry-run --projects nexus --ready-file "$FIXTURE"
    expect_code 0 "$RC" "dry-run with busy"
    out_lines=$(echo "$OUT" | grep -c '^would dispatch ' || true)
    assert_equals 1 "$out_lines" "one would dispatch with one busy worker"

    pass "slots_default_to_thermal_cap_minus_busy"
}

test_scope_defaults_to_registry() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "scope_default")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- dotfiles [direct-PR +yolo] - x
REG

    run_refill select --ready-file "$FIXTURE"
    expect_code 0 "$RC" "select no --projects"
    local select_out="$OUT"
    local line_count
    line_count=$(echo "$select_out" | grep -c '^' || true)
    assert_equals 1 $((line_count > 0)) "output non-empty"

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        local proj
        proj=$(jq -r --arg id "$id" '.ready[] | select(.id == $id) | .project' "$FIXTURE")
        assert_equals "dotfiles" "$proj" "id $id project is dotfiles"
    done <<< "$select_out"

    pass "scope_defaults_to_registry"
}

test_no_scope_is_a_usage_error() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "no_scope")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/missing.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    run_refill run --slots 1 --ready-file "$FIXTURE"
    expect_code 2 "$RC" "run exits 2"
    assert_contains "$(cat "$CASE/err")" "no project scope" "stderr contains no project scope"

    run_refill count --ready-file "$FIXTURE"
    expect_code 0 "$RC" "count exits 0"
    assert_equals "0" "$OUT" "count prints 0"

    pass "no_scope_is_a_usage_error"
}

test_ready_command_failure_is_soft_for_count_and_hard_for_run() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "ready_fail")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"
    export FM_REFILL_READY_CMD="false"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
REG

    run_refill count --projects nexus
    expect_code 0 "$RC" "count exits 0"
    assert_equals "0" "$OUT" "count prints 0"

    run_refill run --slots 1 --projects nexus
    expect_code 1 "$RC" "run exits 1"
    local fill_row
    fill_row=$(jq -s 'map(select(.decision == "fill")) | .[0]' "$FM_REFILL_LOG")
    local reason
    reason=$(echo "$fill_row" | jq -r '.reason')
    assert_equals "ready list unavailable" "$reason" "fill reason ready list unavailable"

    pass "ready_command_failure_is_soft_for_count_and_hard_for_run"
}

test_help_exits_zero() {
    local TMP_ROOT; TMP_ROOT=$(fm_test_tmproot "help")
    CASE="$TMP_ROOT"
    make_stubs "$CASE"
    local home="$CASE/home"
    mkdir -p "$home/state" "$home/config" "$home/data"
    local thermal="$CASE/thermal"
    write_sysfs "$thermal"

    export FM_HOME="$home"
    export FM_REFILL_LOG="$CASE/refill.jsonl"
    export FM_REFILL_PROJECTS_FILE="$CASE/projects.md"
    export FM_REFILL_NEXUS_BIN="$CASE/nexus"
    export FM_REFILL_TASKS_BIN="$CASE/tasks"
    export FM_REFILL_BRIEF_BIN="$CASE/brief"
    export FM_REFILL_SPAWN_BIN="$CASE/spawn"
    export FM_REFILL_RESOLVE_BIN="$CASE/resolve"
    export FM_THERMAL_SYSFS="$thermal"
    export FM_HWMON_SYSFS="$CASE/hwmon"
    mkdir -p "$FM_HWMON_SYSFS"

    cat > "$FM_REFILL_PROJECTS_FILE" <<'REG'
- nexus [no-mistakes-prod-only] - nexus
REG

    run_refill --help
    expect_code 0 "$RC" "help exits 0"
    assert_contains "$OUT" "fm-refill.sh" "help text contains script name"

    pass "help_exits_zero"
}

test_real_fixture_keeps_auto_build_rows
test_real_fixture_drops_other_classes
test_scope_limits_projects
test_not_to_build_markers_drop_rows
test_dry_run_runs_nothing_and_logs
test_run_claims_before_spawning_and_fills_exactly_slots
test_claim_failure_skips_to_next_candidate
test_no_free_slots_does_nothing
test_slots_default_to_thermal_cap_minus_busy
test_scope_defaults_to_registry
test_no_scope_is_a_usage_error
test_ready_command_failure_is_soft_for_count_and_hard_for_run
test_help_exits_zero