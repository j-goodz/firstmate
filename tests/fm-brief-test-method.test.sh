#!/usr/bin/env bash
# tests/fm-brief-test-method.test.sh - the "Test method (the standard method)"
# section that bin/fm-brief.sh puts in ship and scout briefs.
#
# Every ship brief (all three delivery modes) and every scout brief carries the
# section; a secondmate charter does not. The assertions scaffold real briefs
# into a temp home and read the generated file, never the script source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_SUITE_SLOT_HELD FM_SUITE_SLOTS FM_SUITE_NPROC FM_HOME FM_THERMAL_SYSFS FM_HWMON_SYSFS FM_TASK_ID

TMP_ROOT=$(fm_test_tmproot fm-brief-test-method)
HEADING='# Test method (the standard method)'

new_home() {  # <name>
  mkdir -p "$TMP_ROOT/$1/data"
  printf '%s\n' "$TMP_ROOT/$1"
}

# scaffold <home> <task-id> <fm-brief args...>: writes the brief, prints its path.
scaffold() {
  local home=$1 id=$2 out
  shift 2
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$@" 2>&1) \
    || fail "fm-brief.sh $id $*: scaffold failed: $out"
  printf '%s\n' "$home/data/$id/brief.md"
}

assert_has_section() {  # <label> <brief-file>
  local label=$1 content
  content=$(cat "$2")
  assert_contains "$content" "$HEADING" "$label: Test method heading present"
  assert_contains "$content" "docs/test-capacity-standard.md" "$label: names the standard document"
  assert_contains "$content" "$ROOT/bin/fm-test-run.sh --changed" "$label: names the firstmate picker"
  assert_contains "$content" "NEXUS_GATE_SCOPE=1" "$label: names the nexus picker"
  assert_contains "$content" "on main" "$label: says to check one file on main"
  assert_contains "$content" "$ROOT/bin/fm-suite-slot.sh run" "$label: routes whole-suite runs through the slot gate"
  assert_contains "$content" "per-task exception" "$label: allows a per-task exception"
  assert_not_contains "$content" "baseline" "$label: carries no main baseline instruction"
}

assert_ship_headings() {  # <label> <brief-file>
  local label=$1 content
  content=$(cat "$2")
  assert_contains "$content" "# Setup" "$label: keeps the Setup heading"
  assert_contains "$content" "# Rules" "$label: keeps the Rules heading"
  assert_contains "$content" "# Definition of done" "$label: keeps the Definition of done heading"
}

line_of() {  # <heading> <file>
  grep -n -x -F -- "$1" "$2" | head -n1 | cut -d: -f1
}

test_ship_no_mistakes() {
  local home brief
  home=$(new_home ship-nm)
  brief=$(scaffold "$home" ship-nm-a1 some-proj --mode no-mistakes)
  assert_has_section "ship no-mistakes" "$brief"
  assert_ship_headings "ship no-mistakes" "$brief"
  pass "ship no-mistakes brief carries the test method section"
}

test_ship_direct_pr() {
  local home brief
  home=$(new_home ship-dp)
  brief=$(scaffold "$home" ship-dp-a1 some-proj --mode direct-PR)
  assert_has_section "ship direct-PR" "$brief"
  assert_ship_headings "ship direct-PR" "$brief"
  pass "ship direct-PR brief carries the test method section"
}

test_ship_local_only() {
  local home brief
  home=$(new_home ship-lo)
  brief=$(scaffold "$home" ship-lo-a1 some-proj --mode local-only)
  assert_has_section "ship local-only" "$brief"
  assert_ship_headings "ship local-only" "$brief"
  pass "ship local-only brief carries the test method section"
}

test_scout() {
  local home brief
  home=$(new_home scout)
  brief=$(scaffold "$home" scout-a1 some-proj --scout)
  assert_has_section "scout" "$brief"
  pass "scout brief carries the test method section"
}

test_secondmate_charter_has_no_section() {
  local home brief content
  home=$(new_home charter)
  brief=$(FM_SECONDMATE_CHARTER='charter text' scaffold "$home" charter-a1 --secondmate some-proj)
  [ -f "$brief" ] || fail "secondmate charter: brief file not created: $brief"
  content=$(cat "$brief")
  assert_not_contains "$content" "$HEADING" "secondmate charter must not carry the test method section"
  pass "a secondmate charter has no test method section"
}

test_section_precedes_project_memory() {
  local home brief method_line memory_line
  home=$(new_home order)
  brief=$(scaffold "$home" order-a1 some-proj --mode no-mistakes)
  method_line=$(line_of "$HEADING" "$brief")
  memory_line=$(line_of '# Project memory' "$brief")
  [ -n "$method_line" ] || fail "ordering: Test method heading missing"
  [ -n "$memory_line" ] || fail "ordering: Project memory heading missing"
  [ "$method_line" -lt "$memory_line" ] || fail "ordering: Test method heading (line $method_line) must come before Project memory (line $memory_line)"
  pass "the test method section sits before Project memory in a ship brief"
}

test_home_brief_additions_stay_last() {
  local home brief method_line additions_line total_lines
  home=$(new_home include)
  mkdir -p "$home/config"
  printf '%s\n' 'Standing home instruction for the include test.' > "$home/config/brief-include.md"
  brief=$(scaffold "$home" include-a1 some-proj --mode no-mistakes)
  method_line=$(line_of "$HEADING" "$brief")
  additions_line=$(line_of '# Home brief additions' "$brief")
  [ -n "$method_line" ] || fail "include: Test method heading missing"
  [ -n "$additions_line" ] || fail "include: Home brief additions heading missing"
  [ "$additions_line" -gt "$method_line" ] || fail "include: Home brief additions (line $additions_line) must come after Test method (line $method_line)"
  total_lines=$(wc -l < "$brief")
  [ "$(awk -v start="$additions_line" 'NR > start && /^# / { n++ } END { print n + 0 }' "$brief")" -eq 0 ] \
    || fail "include: another top-level section follows Home brief additions (brief has $total_lines lines)"
  pass "the home brief additions section stays last, after the test method section"
}

test_ship_no_mistakes
test_ship_direct_pr
test_ship_local_only
test_scout
test_secondmate_charter_has_no_section
test_section_precedes_project_memory
test_home_brief_additions_stay_last
