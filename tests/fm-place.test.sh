#!/usr/bin/env bash
# tests/fm-place.test.sh - bin/fm-place.sh ranks machines for new work.
#
# The assertions drive the real script against a fake ssh, canned probe output
# and a registry file: verdict rules for heavy and light work, ranking and tie
# order, the PLACE line, the JSON shape, the placement log, and option errors.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_SUITE_SLOT_HELD FM_SUITE_SLOTS FM_SUITE_NPROC FM_HOME FM_THERMAL_SYSFS FM_TASK_ID

# Helper to create a fake ssh script that reads canned probe files
create_fakessh() {
    local tmp_root="$1"
    cat >"$tmp_root/fakessh" <<EOF
#!/usr/bin/env bash
# Fake ssh for fm-place.sh testing: the host is the 5th argument
# (-o BatchMode=yes -o ConnectTimeout=5 <host> sh -s -- <root> <home>).
cat >/dev/null
host="\$5"
probe_file="$tmp_root/probe-\${host}.txt"
if [[ -f "\$probe_file" ]]; then
    cat "\$probe_file"
    exit 0
fi
exit 255
EOF
    chmod +x "$tmp_root/fakessh"
}

# Helper to write a probe file
write_probe() {  # <root> <host>; the probe lines come on stdin
    local tmp_root="$1"
    local host="$2"
    cat >"$tmp_root/probe-${host}.txt"
}

assert_file_contains() {  # <file> <needle> <msg>
    assert_contains "$(cat "$1")" "$2" "$3"
}

# Test 1: --help prints header and exits 0
test_help() {
    TMP_ROOT=$(fm_test_tmproot test_help)
    "$ROOT/bin/fm-place.sh" --help >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
    assert_equals 0 "$?" "exit code for --help"
    assert_contains "$(cat "$TMP_ROOT/out")" "fm-place.sh" "help output contains script name"
    pass "help works"
}

# Test 2: unknown option prints error and exits 2
test_unknown_option() {
    TMP_ROOT=$(fm_test_tmproot test_unknown_option)
    "$ROOT/bin/fm-place.sh" --unknown 2>"$TMP_ROOT/err"
    assert_equals 2 "$?" "exit code for unknown option"
    assert_contains "$(cat "$TMP_ROOT/err")" "fm-place:" "error message includes script name"
    pass "unknown option handled"
}

# Test 3: invalid --class value exits 2
test_class_validation() {
    TMP_ROOT=$(fm_test_tmproot test_class_validation)
    "$ROOT/bin/fm-place.sh" --class invalid 2>"$TMP_ROOT/err"
    assert_equals 2 "$?" "exit code for invalid class"
    assert_contains "$(cat "$TMP_ROOT/err")" "fm-place:" "error message includes script name"
    pass "class validation"
}

# Test 4: registry parsing and basic output
test_registry_parsing() {
    TMP_ROOT=$(fm_test_tmproot test_registry_parsing)
    # Create registry with two hosts
    cat >"$TMP_ROOT/registry.md" <<'EOF'
- hostA - Host A (host: hostA; root: /hostA/root; home: /hostA/home; scope: heavy)
- hostB - Host B (host: hostB; root: /hostB/root; home: /hostB/home; scope: heavy)
EOF
    # Create fake ssh
    create_fakessh "$TMP_ROOT"
    # Write probe files
    write_probe "$TMP_ROOT" hostA <<'EOF'
cores=4
load1=2.0
capacity=1
base=1
temp=60
tier=cool
held=0
free=1
avail_mb=3000
EOF
    write_probe "$TMP_ROOT" hostB <<'EOF'
cores=2
load1=1.5
capacity=1
base=1
temp=70
tier=hot
held=0
free=1
avail_mb=3000
EOF
    # Local machine probe (self)
    write_probe "$TMP_ROOT" local <<'EOF'
cores=8
load1=0.5
capacity=1
base=1
temp=55
tier=cool
held=0
free=1
avail_mb=3100
EOF
    # Environment
    export FM_PLACE_SSH="$TMP_ROOT/fakessh"
    export FM_SUITE_STATE_DIR="$TMP_ROOT/state"
    mkdir -p "$FM_SUITE_STATE_DIR"
    export FM_PLACE_LOCAL_OUTPUT="$TMP_ROOT/probe-local.txt"
    # Run script
    "$ROOT/bin/fm-place.sh" --registry "$TMP_ROOT/registry.md" --self local --class heavy >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
    # Check exit code (should be 0 because at least one ok machine)
    assert_equals 0 "$?" "exit code for placement"
    # Check that output contains the three machines
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=hostA" "output includes hostA"
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=hostB" "output includes hostB"
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=local" "output includes local"
    # Check verdicts: hostA ok, hostB no (tier hot), local ok
    assert_contains "$(cat "$TMP_ROOT/out")" "verdict=ok" "output contains ok verdicts"
    assert_contains "$(cat "$TMP_ROOT/out")" "verdict=no" "output contains no verdict"
    # Check PLACE line: local is chosen (lowest load per core among ok)
    assert_contains "$(cat "$TMP_ROOT/out")" "PLACE local mate=self verdict=ok class=heavy" "PLACE line correct"
    # Check placement log exists and contains a JSON line
    assert_file_contains "$FM_SUITE_STATE_DIR/placements.jsonl" "\"ts\"" "placement log created"
    pass "registry parsing and basic output"
}

# Test 5: heavy verdict rules
test_heavy_verdict_rules() {
    TMP_ROOT=$(fm_test_tmproot test_heavy_verdict_rules)
    # Create registry with one host per rule
    cat >"$TMP_ROOT/registry.md" <<'EOF'
- unreachable - Host unreachable (host: unreachable; root: /unreachable/root; home: /unreachable/home)
- hold - Tier hold (host: hold; root: /hold/root; home: /hold/home)
- unknown - Slots unknown (host: unknown; root: /unknown/root; home: /unknown/home)
- zero - Base zero (host: zero; root: /zero/root; home: /zero/home)
- hot - Tier hot (host: hot; root: /hot/root; home: /hot/home)
- loadlimit - Load limit (host: loadlimit; root: /loadlimit/root; home: /loadlimit/home)
- mempress - Memory pressure (host: mempress; root: /mempress/root; home: /mempress/home)
- busyfree - Free zero (host: busyfree; root: /busyfree/root; home: /busyfree/home)
- busyload - Load busy (host: busyload; root: /busyload/root; home: /busyload/home)
- ok - Ok machine (host: ok; root: /ok/root; home: /ok/home)
EOF
    create_fakessh "$TMP_ROOT"
    # Unreachable: no probe file -> exit 255
    # Tier hold: tier=hold
    write_probe "$TMP_ROOT" hold <<'EOF'
cores=4
load1=1.0
capacity=2
base=2
temp=60
tier=hold
held=0
free=2
avail_mb=3000
EOF
    # Slots unknown: omit base line (or blank)
    write_probe "$TMP_ROOT" unknown <<'EOF'
cores=4
load1=1.0
capacity=2
temp=60
tier=cool
held=0
free=2
avail_mb=3000
EOF
    # Base zero: base=0
    write_probe "$TMP_ROOT" zero <<'EOF'
cores=4
load1=1.0
capacity=2
base=0
temp=60
tier=cool
held=0
free=2
avail_mb=3000
EOF
    # Tier hot: tier=hot
    write_probe "$TMP_ROOT" hot <<'EOF'
cores=4
load1=1.0
capacity=2
base=2
temp=80
tier=hot
held=0
free=2
avail_mb=3000
EOF
    # Load limit: LPC >= MAX (default 1.0). Use cores=2, load1=2.5 => LPC=1.25
    write_probe "$TMP_ROOT" loadlimit <<'EOF'
cores=2
load1=2.5
capacity=2
base=2
temp=60
tier=cool
held=0
free=2
avail_mb=3000
EOF
    # Memory pressure: avail_mb < MINMEM (default 600). Use avail_mb=500
    write_probe "$TMP_ROOT" mempress <<'EOF'
cores=4
load1=1.0
capacity=2
base=2
temp=60
tier=cool
held=0
free=2
avail_mb=500
EOF
    # Free zero: free=0
    write_probe "$TMP_ROOT" busyfree <<'EOF'
cores=4
load1=1.0
capacity=2
base=2
temp=60
tier=cool
held=0
free=0
avail_mb=3000
EOF
    # Load busy: LPC >= BUSY (default 0.75). Use cores=4, load1=3.0 => LPC=0.75
    write_probe "$TMP_ROOT" busyload <<'EOF'
cores=4
load1=3.0
capacity=2
base=2
temp=60
tier=cool
held=0
free=2
avail_mb=3000
EOF
    # Ok machine: low load, enough memory, free slot
    write_probe "$TMP_ROOT" ok <<'EOF'
cores=8
load1=0.5
capacity=2
base=2
temp=55
tier=cool
held=0
free=2
avail_mb=3100
EOF
    # Local machine (self) also ok
    write_probe "$TMP_ROOT" local <<'EOF'
cores=8
load1=0.5
capacity=2
base=2
temp=55
tier=cool
held=0
free=2
avail_mb=3100
EOF
    export FM_PLACE_SSH="$TMP_ROOT/fakessh"
    export FM_SUITE_STATE_DIR="$TMP_ROOT/state"
    mkdir -p "$FM_SUITE_STATE_DIR"
    export FM_PLACE_LOCAL_OUTPUT="$TMP_ROOT/probe-local.txt"
    # Run heavy class
    "$ROOT/bin/fm-place.sh" --registry "$TMP_ROOT/registry.md" --self local --class heavy >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
    # Expect exit 0 (at least ok machine)
    assert_equals 0 "$?" "exit code for heavy placement"
    # Check that each machine's verdict matches expectation
    # We'll grep each line and assert verdict
    # Unreachable: verdict=no, reason=unreachable
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=unreachable mate=unreachable verdict=no reason=unreachable" "unreachable machine verdict"
    # hold: verdict=no, reason=heat-hold
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=hold mate=hold verdict=no reason=heat-hold" "hold machine verdict"
    # unknown: verdict=no, reason=slots-unknown
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=unknown mate=unknown verdict=no reason=slots-unknown" "unknown slots verdict"
    # zero: verdict=no, reason=no-suite-slots
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=zero mate=zero verdict=no reason=no-suite-slots" "zero base verdict"
    # hot: verdict=no, reason=heat-hot
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=hot mate=hot verdict=no reason=heat-hot" "hot tier verdict"
    # loadlimit: verdict=no, reason=load-limit
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=loadlimit mate=loadlimit verdict=no reason=load-limit" "load limit verdict"
    # mempress: verdict=no, reason=memory-pressure
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=mempress mate=mempress verdict=no reason=memory-pressure" "memory pressure verdict"
    # busyfree: verdict=busy, reason=no-free-slot
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=busyfree mate=busyfree verdict=busy reason=no-free-slot" "busy free verdict"
    # busyload: verdict=busy, reason=load-busy
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=busyload mate=busyload verdict=busy reason=load-busy" "busy load verdict"
    # ok and local: verdict=ok
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=ok mate=ok verdict=ok" "ok machine verdict"
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=local mate=self verdict=ok" "local machine verdict"
    # PLACE line should be the first ok machine (lowest load per core among ok)
    # Both ok and local have same load per core (0.0625). Ties keep list order: registry order then local last.
    # So ok (registry) should be chosen before local.
    assert_contains "$(cat "$TMP_ROOT/out")" "PLACE ok mate=ok verdict=ok class=heavy" "PLACE line chooses ok machine"
    # Check placement log
    assert_file_contains "$FM_SUITE_STATE_DIR/placements.jsonl" "\"ts\"" "placement log created"
    pass "heavy verdict rules"
}

# Test 6: light verdict rules (ignore slots and tier hot)
test_light_verdict_rules() {
    TMP_ROOT=$(fm_test_tmproot test_light_verdict_rules)
    # Create registry with machines that would be no for heavy but ok for light
    cat >"$TMP_ROOT/registry.md" <<'EOF'
- hot - Tier hot (host: hot; root: /hot/root; home: /hot/home)
- zero - Base zero (host: zero; root: /zero/root; home: /zero/home)
- unknown - Slots unknown (host: unknown; root: /unknown/root; home: /unknown/home)
- hold - Tier hold (host: hold; root: /hold/root; home: /hold/home)
- mempress - Memory pressure (host: mempress; root: /mempress/root; home: /mempress/home)
- loadlimit - Load limit (host: loadlimit; root: /loadlimit/root; home: /loadlimit/home)
- busyload - Load busy (host: busyload; root: /busyload/root; home: /busyload/home)
- ok - Ok machine (host: ok; root: /ok/root; home: /ok/home)
EOF
    create_fakessh "$TMP_ROOT"
    # Tier hot: tier=hot (should be no for heavy, but for light tier hot is ignored)
    write_probe "$TMP_ROOT" hot <<'EOF'
cores=4
load1=1.0
capacity=2
base=2
temp=80
tier=hot
held=0
free=2
avail_mb=3000
EOF
    # Base zero: base=0 (should be no for heavy, but for light base zero is ignored)
    write_probe "$TMP_ROOT" zero <<'EOF'
cores=4
load1=1.0
capacity=2
base=0
temp=60
tier=cool
held=0
free=2
avail_mb=3000
EOF
    # Slots unknown: omit base line (should be no for heavy, but for light ignored)
    write_probe "$TMP_ROOT" unknown <<'EOF'
cores=4
load1=1.0
capacity=2
temp=60
tier=cool
held=0
free=2
avail_mb=3000
EOF
    # Tier hold: tier=hold (should be no for both)
    write_probe "$TMP_ROOT" hold <<'EOF'
cores=4
load1=1.0
capacity=2
base=2
temp=60
tier=hold
held=0
free=2
avail_mb=3000
EOF
    # Memory pressure: avail_mb=500 (<600)
    write_probe "$TMP_ROOT" mempress <<'EOF'
cores=4
load1=1.0
capacity=2
base=2
temp=60
tier=cool
held=0
free=2
avail_mb=500
EOF
    # Load limit: LPC >= MAX (1.0). Use cores=2, load1=2.5
    write_probe "$TMP_ROOT" loadlimit <<'EOF'
cores=2
load1=2.5
capacity=2
base=2
temp=60
tier=cool
held=0
free=2
avail_mb=3000
EOF
    # Load busy: LPC >= BUSY (0.75). Use cores=4, load1=3.0
    write_probe "$TMP_ROOT" busyload <<'EOF'
cores=4
load1=3.0
capacity=2
base=2
temp=60
tier=cool
held=0
free=2
avail_mb=3000
EOF
    # Ok machine
    write_probe "$TMP_ROOT" ok <<'EOF'
cores=8
load1=0.5
capacity=2
base=2
temp=55
tier=cool
held=0
free=2
avail_mb=3100
EOF
    # Local machine (self) also ok
    write_probe "$TMP_ROOT" local <<'EOF'
cores=8
load1=0.5
capacity=2
base=2
temp=55
tier=cool
held=0
free=2
avail_mb=3100
EOF
    export FM_PLACE_SSH="$TMP_ROOT/fakessh"
    export FM_SUITE_STATE_DIR="$TMP_ROOT/state"
    mkdir -p "$FM_SUITE_STATE_DIR"
    export FM_PLACE_LOCAL_OUTPUT="$TMP_ROOT/probe-local.txt"
    # Run light class
    "$ROOT/bin/fm-place.sh" --registry "$TMP_ROOT/registry.md" --self local --class light >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
    assert_equals 0 "$?" "exit code for light placement"
    # For light, tier hot, base zero, slots unknown are ignored, so hot, zero, unknown should be ok (if other criteria pass)
    # However, hot has tier=hot but light ignores tier hot, so it should be ok (provided other criteria pass)
    # zero has base=0 but light ignores base zero, so ok
    # unknown has slots unknown but light ignores slots, so ok
    # hold is still no (tier hold applies to both)
    # mempress is no (memory pressure)
    # loadlimit is no (load limit)
    # busyload is busy (load busy)
    # ok and local are ok
    # So we expect verdicts:
    # hold: no/heat-hold
    # mempress: no/memory-pressure
    # loadlimit: no/load-limit
    # busyload: busy/load-busy
    # hot: ok (since tier hot ignored)
    # zero: ok
    # unknown: ok
    # ok: ok
    # local: ok
    # Ranking: ok first (hot, zero, unknown, ok, local) sorted by load per core ascending.
    # Compute load per core:
    # hot: load1=1.0, cores=4 => 0.25
    # zero: same 0.25
    # unknown: same 0.25
    # ok: 0.0625
    # local: 0.0625
    # So order among ok: hot, zero, unknown (tie, keep registry order), then ok, then local.
    # Among busy: busyload (load per core = 0.75)
    # Among no: hold, mempress, loadlimit (order registry)
    # So final order: hot, zero, unknown, ok, local, busyload, hold, mempress, loadlimit
    # PLACE line should be first ok: hot (since it has lowest load per core among ok)
    # Check PLACE line
    assert_contains "$(cat "$TMP_ROOT/out")" "PLACE ok mate=ok verdict=ok class=light" "PLACE line chooses the lowest load per CPU for light"
    # Check that hot verdict is ok (not no)
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=hot mate=hot verdict=ok" "hot machine verdict ok for light"
    # Check that zero and unknown are ok
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=zero mate=zero verdict=ok" "zero machine verdict ok for light"
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=unknown mate=unknown verdict=ok" "unknown machine verdict ok for light"
    # Check that hold is no
    assert_contains "$(cat "$TMP_ROOT/out")" "machine=hold mate=hold verdict=no" "hold machine verdict no"
    # Check placement log
    assert_file_contains "$FM_SUITE_STATE_DIR/placements.jsonl" "\"ts\"" "placement log created"
    pass "light verdict rules"
}

# Test 7: JSON output
test_json_output() {
    TMP_ROOT=$(fm_test_tmproot test_json_output)
    cat >"$TMP_ROOT/registry.md" <<'EOF'
- hostA - Host A (host: hostA; root: /hostA/root; home: /hostA/home)
- hostB - Host B (host: hostB; root: /hostB/root; home: /hostB/home)
EOF
    create_fakessh "$TMP_ROOT"
    write_probe "$TMP_ROOT" hostA <<'EOF'
cores=4
load1=2.0
capacity=1
base=1
temp=60
tier=cool
held=0
free=1
avail_mb=3000
EOF
    write_probe "$TMP_ROOT" hostB <<'EOF'
cores=2
load1=1.5
capacity=1
base=1
temp=70
tier=hot
held=0
free=1
avail_mb=3000
EOF
    write_probe "$TMP_ROOT" local <<'EOF'
cores=8
load1=0.5
capacity=1
base=1
temp=55
tier=cool
held=0
free=1
avail_mb=3100
EOF
    export FM_PLACE_SSH="$TMP_ROOT/fakessh"
    export FM_SUITE_STATE_DIR="$TMP_ROOT/state"
    mkdir -p "$FM_SUITE_STATE_DIR"
    export FM_PLACE_LOCAL_OUTPUT="$TMP_ROOT/probe-local.txt"
    # Run with --json
    "$ROOT/bin/fm-place.sh" --registry "$TMP_ROOT/registry.md" --self local --class heavy --json >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
    # Validate JSON with jq
    jq -e '.' "$TMP_ROOT/out" >"$TMP_ROOT/empty" 2>"$TMP_ROOT/jq_err"
    assert_equals 0 "$?" "JSON is valid"
    jq -e '.class == "heavy"' "$TMP_ROOT/out" >/dev/null || fail "JSON class must be heavy"
    jq -e '.place.machine == "local" and .place.verdict == "ok"' "$TMP_ROOT/out" >/dev/null \
        || fail "JSON place must name the local machine with verdict ok"
    jq -e '(.machines | length) == 3' "$TMP_ROOT/out" >/dev/null || fail "JSON must list all three machines"
    jq -e '.machines[0] | has("machine") and has("verdict") and has("reason") and has("load_per_core") and has("slots_free")' \
        "$TMP_ROOT/out" >/dev/null || fail "JSON machine entries must carry the documented fields"
    pass "JSON output"
}

# Test 8: placement log format
test_placement_log() {
    TMP_ROOT=$(fm_test_tmproot test_placement_log)
    cat >"$TMP_ROOT/registry.md" <<'EOF'
- hostA - Host A (host: hostA; root: /hostA/root; home: /hostA/home)
EOF
    create_fakessh "$TMP_ROOT"
    write_probe "$TMP_ROOT" hostA <<'EOF'
cores=4
load1=2.0
capacity=1
base=1
temp=60
tier=cool
held=0
free=1
avail_mb=3000
EOF
    write_probe "$TMP_ROOT" local <<'EOF'
cores=8
load1=0.5
capacity=1
base=1
temp=55
tier=cool
held=0
free=1
avail_mb=3100
EOF
    export FM_PLACE_SSH="$TMP_ROOT/fakessh"
    export FM_SUITE_STATE_DIR="$TMP_ROOT/state"
    mkdir -p "$FM_SUITE_STATE_DIR"
    export FM_PLACE_LOCAL_OUTPUT="$TMP_ROOT/probe-local.txt"
    # Run script
    "$ROOT/bin/fm-place.sh" --registry "$TMP_ROOT/registry.md" --self local --class heavy >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
    # Check placement log file exists and contains a JSON line
    assert_file_contains "$FM_SUITE_STATE_DIR/placements.jsonl" "\"ts\"" "placement log created"
    # Validate each line is valid JSON
    while IFS= read -r line; do
        jq -e '.' <<<"$line" >"$TMP_ROOT/empty" 2>"$TMP_ROOT/jq_err"
        assert_equals 0 "$?" "placement log line is valid JSON"
    done <"$FM_SUITE_STATE_DIR/placements.jsonl"
    pass "placement log format"
}

# Test 9: ranking and tie-breaking
test_ranking_tie() {
    TMP_ROOT=$(fm_test_tmproot test_ranking_tie)
    cat >"$TMP_ROOT/registry.md" <<'EOF'
- hostA - Host A (host: hostA; root: /hostA/root; home: /hostA/home)
- hostB - Host B (host: hostB; root: /hostB/root; home: /hostB/home)
- hostC - Host C (host: hostC; root: /hostC/root; home: /hostC/home)
EOF
    create_fakessh "$TMP_ROOT"
    # All three have same verdict ok, same load per core, but different order
    write_probe "$TMP_ROOT" hostA <<'EOF'
cores=4
load1=2.0
capacity=1
base=1
temp=60
tier=cool
held=0
free=1
avail_mb=3000
EOF
    write_probe "$TMP_ROOT" hostB <<'EOF'
cores=4
load1=2.0
capacity=1
base=1
temp=60
tier=cool
held=0
free=1
avail_mb=3000
EOF
    write_probe "$TMP_ROOT" hostC <<'EOF'
cores=4
load1=2.0
capacity=1
base=1
temp=60
tier=cool
held=0
free=1
avail_mb=3000
EOF
    write_probe "$TMP_ROOT" local <<'EOF'
cores=4
load1=2.0
capacity=1
base=1
temp=60
tier=cool
held=0
free=1
avail_mb=3000
EOF
    export FM_PLACE_SSH="$TMP_ROOT/fakessh"
    export FM_SUITE_STATE_DIR="$TMP_ROOT/state"
    mkdir -p "$FM_SUITE_STATE_DIR"
    export FM_PLACE_LOCAL_OUTPUT="$TMP_ROOT/probe-local.txt"
    # Run heavy class
    "$ROOT/bin/fm-place.sh" --registry "$TMP_ROOT/registry.md" --self local --class heavy >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
    # Expect order: hostA, hostB, hostC, local (registry order then local)
    # Since all have same load per core, ties keep list order.
    # We'll check that the output lines appear in that order.
    local output
    output=$(cat "$TMP_ROOT/out")
    # Extract machine names in order
    local machines
    machines=$(echo "$output" | grep -o 'machine=[^ ]*' | cut -d= -f2)
    # Build array
    local arr=()
    while IFS= read -r m; do
        arr+=("$m")
    done <<< "$machines"
    # Check order
    assert_equals "hostA" "${arr[0]}" "first machine is hostA"
    assert_equals "hostB" "${arr[1]}" "second machine is hostB"
    assert_equals "hostC" "${arr[2]}" "third machine is hostC"
    assert_equals "local" "${arr[3]}" "fourth machine is local"
    # PLACE line should be hostA (first ok)
    assert_contains "$(cat "$TMP_ROOT/out")" "PLACE hostA mate=hostA verdict=ok class=heavy" "PLACE line chooses hostA"
    pass "ranking tie-breaking"
}

# Test 10: PLACE none when nothing qualifies
test_place_none() {
    TMP_ROOT=$(fm_test_tmproot test_place_none)
    cat >"$TMP_ROOT/registry.md" <<'EOF'
- hostA - Host A (host: hostA; root: /hostA/root; home: /hostA/home)
EOF
    create_fakessh "$TMP_ROOT"
    # Create a machine that is no (tier hold)
    write_probe "$TMP_ROOT" hostA <<'EOF'
cores=4
load1=1.0
capacity=1
base=1
temp=60
tier=hold
held=0
free=1
avail_mb=3000
EOF
    # Local machine also no (tier hold)
    write_probe "$TMP_ROOT" local <<'EOF'
cores=4
load1=1.0
capacity=1
base=1
temp=60
tier=hold
held=0
free=1
avail_mb=3000
EOF
    export FM_PLACE_SSH="$TMP_ROOT/fakessh"
    export FM_SUITE_STATE_DIR="$TMP_ROOT/state"
    mkdir -p "$FM_SUITE_STATE_DIR"
    export FM_PLACE_LOCAL_OUTPUT="$TMP_ROOT/probe-local.txt"
    # Run heavy class
    "$ROOT/bin/fm-place.sh" --registry "$TMP_ROOT/registry.md" --self local --class heavy >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
    # Expect exit code 1 (PLACE none)
    assert_equals 1 "$?" "exit code for PLACE none"
    # Expect PLACE none line with reason containing heat-hold (both machines)
    assert_contains "$(cat "$TMP_ROOT/out")" "PLACE none class=heavy reason=heat-hold,heat-hold" "PLACE none line with reasons"
    pass "PLACE none when nothing qualifies"
}

# Run all tests
test_help
test_unknown_option
test_class_validation
test_registry_parsing
test_heavy_verdict_rules
test_light_verdict_rules
test_json_output
test_placement_log
test_ranking_tie
test_place_none
