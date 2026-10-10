#!/usr/bin/env bash
set -u

# Source the test library
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Set up temporary root
TMP_ROOT=$(fm_test_tmproot fm-watch-fast-lib)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

# Source the libraries in order
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-classify-lib.sh"
. "$ROOT/bin/fm-watch-fast-lib.sh"

# Helper function
expect_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        fail "$label: expected '$expected' got '$actual'"
    fi
}

###############################################################
# Group 1: fm_meta_get_into
###############################################################

# Write the meta file
cat > "$TMP_ROOT/a.meta" <<'EOF'
window=s:fm-a
backend=herdr
dup=first
dup=second
empty=
url=a=b=c
EOF

# Test fm_meta_get_into
v=
fm_meta_get_into v "$TMP_ROOT/a.meta" backend
expect_eq "fm_meta_get_into backend" "herdr" "$v"

v=
fm_meta_get_into v "$TMP_ROOT/a.meta" dup
expect_eq "fm_meta_get_into dup (last wins)" "second" "$v"

v=
fm_meta_get_into v "$TMP_ROOT/a.meta" empty
expect_eq "fm_meta_get_into empty" "" "$v"

v=
fm_meta_get_into v "$TMP_ROOT/a.meta" missing
expect_eq "fm_meta_get_into missing key" "" "$v"

v=
fm_meta_get_into v "/nonexistent/meta" backend
expect_eq "fm_meta_get_into missing file" "" "$v"
# Check return code for missing file
fm_meta_get_into v "/nonexistent/meta" backend
ret=$?
expect_eq "fm_meta_get_into missing file return code" "0" "$ret"

v=
fm_meta_get_into v "$TMP_ROOT/a.meta" url
expect_eq "fm_meta_get_into url with equals" "a=b=c" "$v"

# Oracle agreement with fm_meta_get
for key in window backend dup empty url missing; do
    v1=
    fm_meta_get_into v1 "$TMP_ROOT/a.meta" "$key"
    v2=$(fm_meta_get "$TMP_ROOT/a.meta" "$key")
    expect_eq "fm_meta_get_into vs fm_meta_get for key '$key'" "$v2" "$v1"
done

# Fork nothing: check BASHPID unchanged
before=$BASHPID
v=
fm_meta_get_into v "$TMP_ROOT/a.meta" window
after=$BASHPID
expect_eq "fm_meta_get_into does not fork (BASHPID)" "$before" "$after"

# Check function body contains no command substitution
if declare -f fm_meta_get_into | grep -F '$('; then
    fail "fm_meta_get_into contains command substitution"
fi

pass "Group 1: fm_meta_get_into contracts satisfied"

###############################################################
# Group 2: fmw_info and the lookups
###############################################################

# Create metas
cat > "$STATE/alpha.meta" <<'EOF'
window=sess:fm-alpha
kind=ship
backend=herdr
harness=claude
EOF

cat > "$STATE/beta.meta" <<'EOF'
window=sess:fm-beta
terminal=term-7
kind=secondmate
EOF

cat > "$STATE/gamma.meta" <<'EOF'
window=sess:fm-gamma
EOF

# Reset cache
fmw_cache_reset

# Test fmw_info for alpha
fmw_info "sess:fm-alpha"
expect_eq "fmw_info alpha FMW_META" "$STATE/alpha.meta" "$FMW_META"
expect_eq "fmw_info alpha FMW_TASK" "alpha" "$FMW_TASK"
expect_eq "fmw_info alpha FMW_KIND" "ship" "$FMW_KIND"
expect_eq "fmw_info alpha FMW_BACKEND" "herdr" "$FMW_BACKEND"
expect_eq "fmw_info alpha FMW_HARNESS" "claude" "$FMW_HARNESS"
expect_eq "fmw_info alpha FMW_LABEL" "fm-alpha" "$FMW_LABEL"
expect_eq "fmw_info alpha FMW_KEY" "sess_fm-alpha" "$FMW_KEY"

# Test fmw_info for beta (matched through terminal=)
fmw_info "term-7"
expect_eq "fmw_info beta FMW_TASK" "beta" "$FMW_TASK"
expect_eq "fmw_info beta FMW_KIND" "secondmate" "$FMW_KIND"
expect_eq "fmw_info beta FMW_BACKEND" "tmux" "$FMW_BACKEND"
expect_eq "fmw_info beta FMW_HARNESS" "" "$FMW_HARNESS"

# Test fmw_info for gamma (no kind, no backend)
fmw_info "sess:fm-gamma"
expect_eq "fmw_info gamma FMW_KIND" "ship" "$FMW_KIND"
expect_eq "fmw_info gamma FMW_BACKEND" "tmux" "$FMW_BACKEND"

# Test fmw_info for missing
fmw_info "nosuch:fm-zed"
expect_eq "fmw_info missing FMW_META" "" "$FMW_META"
expect_eq "fmw_info missing FMW_KIND" "unknown" "$FMW_KIND"
expect_eq "fmw_info missing FMW_BACKEND" "tmux" "$FMW_BACKEND"
expect_eq "fmw_info missing FMW_TASK" "zed" "$FMW_TASK"
expect_eq "fmw_info missing FMW_LABEL" "fm-zed" "$FMW_LABEL"
expect_eq "fmw_info missing FMW_KEY" "nosuch_fm-zed" "$FMW_KEY"

# Test fmw_key_into
k=
fmw_key_into k 'a:b/c.d'
expect_eq "fmw_key_into" "a_b_c_d" "$k"

# Cache behaviour
fmw_info "sess:fm-alpha"
# Rewrite alpha.meta with backend=zellij
cat > "$STATE/alpha.meta" <<'EOF'
window=sess:fm-alpha
kind=ship
backend=zellij
harness=claude
EOF
# Second read should still report herdr (cached)
fmw_info "sess:fm-alpha"
expect_eq "cache behaviour after rewrite" "herdr" "$FMW_BACKEND"
# After reset, should report zellij
fmw_cache_reset
fmw_info "sess:fm-alpha"
expect_eq "cache behaviour after reset" "zellij" "$FMW_BACKEND"

# Oracle agreement for alpha, beta, gamma
for w in "sess:fm-alpha" "sess:fm-beta" "sess:fm-gamma"; do
    fmw_info "$w"
    # FMW_TASK equals window_to_task
    expected_task=$(window_to_task "$w" "$STATE")
    expect_eq "oracle task for $w" "$expected_task" "$FMW_TASK"
    # FMW_KIND equals fm_meta_get kind (or ship default)
    meta_kind=$(fm_meta_get "$FMW_META" "kind")
    expected_kind=${meta_kind:-ship}
    expect_eq "oracle kind for $w" "$expected_kind" "$FMW_KIND"
    # FMW_BACKEND equals fm_backend_of_meta
    expected_backend=$(fm_backend_of_meta "$FMW_META")
    expect_eq "oracle backend for $w" "$expected_backend" "$FMW_BACKEND"
done

pass "Group 2: fmw_info and lookups contracts satisfied"

###############################################################
# Group 3: fmw_read_into, fmw_now_into, fmw_hash_into,
#          fmw_rm_existing, fmw_stamp
###############################################################

# fmw_read_into
mkdir -p "$TMP_ROOT/readtest"
# File with first\nsecond\n
printf 'first\nsecond\n' > "$TMP_ROOT/readtest/two"
v=
fmw_read_into v "$TMP_ROOT/readtest/two" "default"
expect_eq "fmw_read_into two lines" "first" "$v"

# File without trailing newline
printf 'solo' > "$TMP_ROOT/readtest/solo"
v=
fmw_read_into v "$TMP_ROOT/readtest/solo" "default"
expect_eq "fmw_read_into solo" "solo" "$v"

# Empty file
: > "$TMP_ROOT/readtest/empty"
v=
fmw_read_into v "$TMP_ROOT/readtest/empty" "default"
expect_eq "fmw_read_into empty" "default" "$v"

# Missing file
v=
fmw_read_into v "$TMP_ROOT/readtest/missing" "default"
expect_eq "fmw_read_into missing" "default" "$v"

# First line empty, second is x
printf '\nx\n' > "$TMP_ROOT/readtest/empty_first"
v=
fmw_read_into v "$TMP_ROOT/readtest/empty_first" "default"
expect_eq "fmw_read_into empty first line" "default" "$v"

# fmw_now_into
n=
fmw_now_into n
now=$(date +%s)
diff=$(( n - now ))
if (( diff < -2 || diff > 2 )); then
    fail "fmw_now_into: $n not within 2 seconds of $now"
fi

# fmw_hash_into
h=
fmw_hash_into h "key1" "pane text"
expected=$(printf '%s' 'pane text' | md5sum | cut -d' ' -f1)
expect_eq "fmw_hash_into first call" "$expected" "$h"

# Same key, same text -> same hash
h2=
fmw_hash_into h2 "key1" "pane text"
expect_eq "fmw_hash_into memo same" "$expected" "$h2"

# Same key, different text -> different hash (md5 of new text)
h3=
fmw_hash_into h3 "key1" "different text"
expected3=$(printf '%s' 'different text' | md5sum | cut -d' ' -f1)
expect_eq "fmw_hash_into memo different" "$expected3" "$h3"

# Different key, first text -> first text's md5
h4=
fmw_hash_into h4 "key2" "pane text"
expect_eq "fmw_hash_into different key" "$expected" "$h4"

# fmw_rm_existing
mkdir -p "$TMP_ROOT/rmtest"
touch "$TMP_ROOT/rmtest/r1"
touch "$TMP_ROOT/rmtest/r 2"
# r3 missing
fmw_rm_existing "$TMP_ROOT/rmtest/r1" "$TMP_ROOT/rmtest/r 2" "$TMP_ROOT/rmtest/r3"
if [[ -e "$TMP_ROOT/rmtest/r1" ]]; then
    fail "fmw_rm_existing: r1 not removed"
fi
if [[ -e "$TMP_ROOT/rmtest/r 2" ]]; then
    fail "fmw_rm_existing: 'r 2' not removed"
fi
ret=$?
expect_eq "fmw_rm_existing return code" "0" "$ret"

# Only missing paths -> returns 0, creates nothing
fmw_rm_existing "$TMP_ROOT/rmtest/r3" "$TMP_ROOT/rmtest/r4"
ret=$?
expect_eq "fmw_rm_existing only missing return" "0" "$ret"
if [[ -e "$TMP_ROOT/rmtest/r3" ]]; then
    fail "fmw_rm_existing: r3 should not exist"
fi
if [[ -e "$TMP_ROOT/rmtest/r4" ]]; then
    fail "fmw_rm_existing: r4 should not exist"
fi

# Dangling symlink
ln -sfn "/nonexistent/target" "$TMP_ROOT/rmtest/dangling"
fmw_rm_existing "$TMP_ROOT/rmtest/dangling"
if [[ -e "$TMP_ROOT/rmtest/dangling" ]]; then
    fail "fmw_rm_existing: dangling symlink not removed"
fi

# fmw_stamp
fmw_stamp "$TMP_ROOT/rmtest/stamp"
if [[ ! -f "$TMP_ROOT/rmtest/stamp" ]]; then
    fail "fmw_stamp: file not created"
fi
stamp_val=$(cat "$TMP_ROOT/rmtest/stamp")
now=$(date +%s)
diff=$(( stamp_val - now ))
if (( diff < -2 || diff > 2 )); then
    fail "fmw_stamp: $stamp_val not within 2 seconds of $now"
fi

pass "Group 3: fmw_read_into, fmw_now_into, fmw_hash_into, fmw_rm_existing, fmw_stamp contracts satisfied"

###############################################################
# Group 4: fmw_status_last_into
###############################################################

# Helper to create fixture (f)
make_fixture_f() {
    yes 'working [at=1]: filler line to make the file big' | head -c 153600 > "$1"
    echo "done [at=5]: end" >> "$1"
}

# (a) three lines
cat > "$TMP_ROOT/a.status" <<'EOF'
working [at=1]: a
done [at=2]: shipped
some continuation prose
EOF

# (b) 300 lines of working then blocked
{
    for i in $(seq 1 300); do
        echo "working [at=$i]: step $i"
    done
    echo "blocked [at=999]: stuck"
} > "$TMP_ROOT/b.status"

# (c) 250 lines of unrecognised prose
{
    for i in $(seq 1 250); do
        echo "prose line $i without status verb"
    done
} > "$TMP_ROOT/c.status"

# (d) empty file
: > "$TMP_ROOT/d.status"

# (e) missing file
# (will use non-existent path)

# (f) 150 KiB file
make_fixture_f "$TMP_ROOT/f.status"

# Test each fixture
for name in a b c d e f; do
    case "$name" in
        a) file="$TMP_ROOT/a.status" ;;
        b) file="$TMP_ROOT/b.status" ;;
        c) file="$TMP_ROOT/c.status" ;;
        d) file="$TMP_ROOT/d.status" ;;
        e) file="$TMP_ROOT/e.status" ;;  # missing
        f) file="$TMP_ROOT/f.status" ;;
    esac
    fmw_cache_reset
    got=
    fmw_status_last_into got "$file"
    expected=$(last_status_line "$file")
    expect_eq "fmw_status_last_into fixture $name" "$expected" "$got"
done

# Memo test: after reading (a), append a line, second read without reset returns first result
fmw_cache_reset
got1=
fmw_status_last_into got1 "$TMP_ROOT/a.status"
echo "blocked [at=3]: later" >> "$TMP_ROOT/a.status"
got2=
fmw_status_last_into got2 "$TMP_ROOT/a.status"
expect_eq "memo test without reset" "$got1" "$got2"
# After reset, should return the blocked line
fmw_cache_reset
got3=
fmw_status_last_into got3 "$TMP_ROOT/a.status"
expected3=$(last_status_line "$TMP_ROOT/a.status")
expect_eq "memo test after reset" "$expected3" "$got3"

pass "Group 4: fmw_status_last_into contracts satisfied"

###############################################################
# Group 5: slow path parity
###############################################################

# Check if library defines FMW_FAST
if ! grep -q 'FMW_FAST' "$ROOT/bin/fm-watch-fast-lib.sh"; then
    echo "# SKIP slow-path parity"
else
    # Save original state of variables/functions? We'll just re-run groups 2-4 with FMW_FAST=0.
    # Note: We must reset the state and cache, and re-initialize.
    FMW_FAST=0

    # Clear and recreate state metas
    rm -f "$STATE"/*.meta
    cat > "$STATE/alpha.meta" <<'EOF'
window=sess:fm-alpha
kind=ship
backend=herdr
harness=claude
EOF
    cat > "$STATE/beta.meta" <<'EOF'
window=sess:fm-beta
terminal=term-7
kind=secondmate
EOF
    cat > "$STATE/gamma.meta" <<'EOF'
window=sess:fm-gamma
EOF

    # Group 2 re-run
    fmw_cache_reset
    fmw_info "sess:fm-alpha"
    expect_eq "slow alpha FMW_BACKEND" "herdr" "$FMW_BACKEND"
    fmw_info "term-7"
    expect_eq "slow beta FMW_BACKEND" "tmux" "$FMW_BACKEND"
    fmw_info "sess:fm-gamma"
    expect_eq "slow gamma FMW_KIND" "ship" "$FMW_KIND"
    fmw_info "nosuch:fm-zed"
    expect_eq "slow missing FMW_KIND" "unknown" "$FMW_KIND"
    k=
    fmw_key_into k 'a:b/c.d'
    expect_eq "slow fmw_key_into" "a_b_c_d" "$k"

    # Group 3 re-run (simplified, just a few checks)
    v=
    fmw_read_into v "$TMP_ROOT/readtest/two" "default"
    expect_eq "slow fmw_read_into" "first" "$v"
    n=
    fmw_now_into n
    now=$(date +%s)
    diff=$(( n - now ))
    if (( diff < -2 || diff > 2 )); then
        fail "slow fmw_now_into: $n not within 2 seconds of $now"
    fi
    h=
    fmw_hash_into h "key1" "pane text"
    expected=$(printf '%s' 'pane text' | md5sum | cut -d' ' -f1)
    expect_eq "slow fmw_hash_into" "$expected" "$h"

    # Group 4 re-run (just fixture a for brevity)
    fmw_cache_reset
    got=
    fmw_status_last_into got "$TMP_ROOT/a.status"
    expected=$(last_status_line "$TMP_ROOT/a.status")
    expect_eq "slow fmw_status_last_into a" "$expected" "$got"

    pass "Group 5: slow path parity satisfied"
fi

pass "fm-watch-fast-lib helpers satisfy their contracts"