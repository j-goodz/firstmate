#!/usr/bin/env bash
# tests/fm-wake-absorb-lib.test.sh - behavior tests for bin/fm-wake-absorb-lib.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-absorb-lib-tests)
LIB="$ROOT/bin/fm-wake-absorb-lib.sh"

run_lib() {  # <state> <function> [args...]
  local state=$1; shift
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"
}

# ============================================================
# Classification: fm_wake_row_needs_brain
# ============================================================

test_classification_working_only_record_only() {
  local case_dir
  case_dir=$(make_case "working-only")
  local state="$case_dir/state"
  local status="$state/task.status"
  printf '%s\n' "working [corr=abc] [at=1791061356]: coding" >> "$state/task.status"
  printf '%s\n' "working [corr=def] [at=1791061357]: more work" >> "$state/task.status"
  run_lib "$state" fm_wake_row_needs_brain signal task.status "signal: $status"
  expect_code 1 $? "working-only should be record-only (exit 1)"
}

test_classification_working_then_done_needs_brain() {
  local case_dir
  case_dir=$(make_case "working-done")
  local state="$case_dir/state"
  local status="$state/task.status"
  printf '%s\n' "working [corr=abc] [at=1791061356]: coding" >> "$state/task.status"
  printf '%s\n' "done [corr=def] [at=1791061357]: finished" >> "$state/task.status"
  run_lib "$state" fm_wake_row_needs_brain signal task.status "signal: $status"
  expect_code 0 $? "working then done should need brain (exit 0)"
}

test_classification_wake_verbs_alone() {
  local verbs=("needs-decision" "blocked" "failed" "paused" "note" "ack" "done")
  for verb in "${verbs[@]}"; do
    local case_dir
    case_dir=$(make_case "verb-$verb")
    local state="$case_dir/state"
    local status="$state/task.status"
    if [[ "$verb" == "needs-decision" ]]; then
      printf '%s\n' "$verb [key=brain-lane-stop] [at=1791066804]: account-3 has reached 75% weekly" >> "$state/task.status"
    elif [[ "$verb" == "note" ]]; then
      printf '%s\n' "$verb [at=1791067165]: an answer the captain gave" >> "$state/task.status"
    elif [[ "$verb" == "captain-held" ]]; then
      printf '%s\n' "$verb [key=x] [at=1791067165]: held for the captain" >> "$state/task.status"
    else
      printf '%s\n' "$verb [corr=abc] [at=1791061356]: something happened" >> "$state/task.status"
    fi
    run_lib "$state" fm_wake_row_needs_brain signal task.status "signal: $status"
    expect_code 0 $? "verb $verb alone should need brain (exit 0)"
  done
}

test_classification_working_then_resolved_or_captain_held_needs_brain() {
  # working then resolved
  local case_dir
  case_dir=$(make_case "working-resolved")
  local state="$case_dir/state"
  local status="$state/task.status"
  printf '%s\n' "working [corr=abc] [at=1791061356]: coding" >> "$state/task.status"
  printf '%s\n' "resolved [key=brain-lane-stop] [at=1791067165]: settled: lane parked" >> "$state/task.status"
  run_lib "$state" fm_wake_row_needs_brain signal task.status "signal: $status"
  expect_code 0 $? "working then resolved should need brain (exit 0)"

  # working then captain-held
  case_dir=$(make_case "working-captain-held")
  state="$case_dir/state"
  status="$state/task.status"
  printf '%s\n' "working [corr=abc] [at=1791061356]: coding" >> "$state/task.status"
  printf '%s\n' "captain-held [key=x] [at=1791067165]: held for the captain" >> "$state/task.status"
  run_lib "$state" fm_wake_row_needs_brain signal task.status "signal: $status"
  expect_code 0 $? "working then captain-held should need brain (exit 0)"
}

test_classification_payload_needs_decision_over_working() {
  local case_dir
  case_dir=$(make_case "payload-needs-decision")
  local state="$case_dir/state"
  local status="$state/task.status"
  printf '%s\n' "working [corr=abc] [at=1791061356]: coding" >> "$state/task.status"
  run_lib "$state" fm_wake_row_needs_brain signal task.status "needs-decision: something important"
  expect_code 0 $? "payload starting with needs-decision: should need brain (exit 0)"
}

test_classification_turn_ended_key_needs_brain() {
  local case_dir
  case_dir=$(make_case "turn-ended")
  local state="$case_dir/state"
  local status="$state/task.status"
  printf '%s\n' "working [corr=abc] [at=1791061356]: coding" >> "$state/task.status"
  run_lib "$state" fm_wake_row_needs_brain signal task.turn-ended "signal: $state/task.turn-ended"
  expect_code 0 $? "key ending in .turn-ended should need brain (exit 0)"
}

test_classification_missing_status_invalid_key_symlink_needs_brain() {
  # Missing status file
  local case_dir
  case_dir=$(make_case "missing-status")
  local state="$case_dir/state"
  run_lib "$state" fm_wake_row_needs_brain signal task.status "signal: $state/task.status"
  expect_code 0 $? "missing status file should need brain (exit 0)"

  # Invalid key (not a valid signal key)
  case_dir=$(make_case "bad-key")
  state="$case_dir/state"
  run_lib "$state" fm_wake_row_needs_brain signal "bad key" "signal: bad key"
  expect_code 0 $? "invalid key should need brain (exit 0)"

  # Symlinked status file
  case_dir=$(make_case "symlink-status")
  state="$case_dir/state"
  local real_status="$state/real.status"
  local link_status="$state/task.status"
  printf '%s\n' "working [corr=abc] [at=1791061356]: coding" >> "$state/real.status"
  ln -s "$real_status" "$link_status"
  run_lib "$state" fm_wake_row_needs_brain signal task.status "signal: $link_status"
  expect_code 0 $? "symlinked status file should need brain (exit 0)"
}

test_classification_no_unread_lines_needs_brain() {
  local case_dir
  case_dir=$(make_case "no-unread")
  local state="$case_dir/state"
  local status="$state/task.status"
  printf '%s\n' "working [corr=abc] [at=1791061356]: coding" >> "$state/task.status"
  
  # A signal drain presents the line and moves the presentation cursor past it
  append_wake "$state" signal task.status "signal: $status"
  if FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1; then
    # Now the working line should be "read", so no unread lines
    run_lib "$state" fm_wake_row_needs_brain signal task.status "signal: $status"
    expect_code 0 $? "no unread lines should need brain (exit 0)"
  else
    echo "skip: could not create cursor via fm-wake-drain.sh"
  fi
}

test_classification_check_and_other_kinds_needs_brain() {
  local case_dir
  case_dir=$(make_case "check-kinds")
  local state="$case_dir/state"

  # check with inbox key
  run_lib "$state" fm_wake_row_needs_brain check "inbox:1791219350-9NXeeO" "check: captain inbox note 1791219350-9NXeeO - buzz #brain event abc (top-level) from x"
  expect_code 0 $? "check inbox should need brain (exit 0)"

  # check with procevent key
  run_lib "$state" fm_wake_row_needs_brain check "procevent-x" "check: process-event result captured: procevent:x"
  expect_code 0 $? "check procevent should need brain (exit 0)"

  # stale
  run_lib "$state" fm_wake_row_needs_brain stale "some-key" "stale: something"
  expect_code 0 $? "stale should need brain (exit 0)"

  # heartbeat
  run_lib "$state" fm_wake_row_needs_brain heartbeat "some-key" "heartbeat: alive"
  expect_code 0 $? "heartbeat should need brain (exit 0)"

  # check with inactive-outcome key
  run_lib "$state" fm_wake_row_needs_brain check "inactive-outcome:abc" "check: inactive outcome"
  expect_code 0 $? "check inactive-outcome should need brain (exit 0)"

  # check with unknown payload
  run_lib "$state" fm_wake_row_needs_brain check "some-key" "check: unknown payload type"
  expect_code 0 $? "check unknown payload should need brain (exit 0)"

  # unknown kind
  run_lib "$state" fm_wake_row_needs_brain bogus "some-key" "bogus: something"
  expect_code 0 $? "unknown kind should need brain (exit 0)"
}

test_classification_check_merge_landed_meta_dependent() {
  local case_dir
  case_dir=$(make_case "merge-landed")
  local state="$case_dir/state"

  # No meta file - record-only
  run_lib "$state" fm_wake_row_needs_brain check "some-key" "check: merge landed: fix-thing https://github.com/example/repo/pull/9"
  expect_code 1 $? "merge landed without meta should be record-only (exit 1)"

  # Meta file exists - needs brain
  touch "$state/fix-thing.meta"
  run_lib "$state" fm_wake_row_needs_brain check "some-key" "check: merge landed: fix-thing https://github.com/example/repo/pull/9"
  expect_code 0 $? "merge landed with meta should need brain (exit 0)"

  # Invalid id with special char - needs brain
  run_lib "$state" fm_wake_row_needs_brain check "some-key" "check: merge landed: bad/id https://github.com/example/repo/pull/9"
  expect_code 0 $? "merge landed with invalid id should need brain (exit 0)"
}

# ============================================================
# fm_wake_rows_all_record_only
# ============================================================

test_rows_all_record_only() {
  local case_dir
  case_dir=$(make_case "rows-all-record-only")
  local state="$case_dir/state"
  local rows_file="$state/rows.tsv"

  # Two working-only signal rows -> exit 0
  printf 'working [at=1791061356]: coding\n' > "$state/task.status"
  printf "1791061356\t1\tsignal\ttask.status\tsignal: working [corr=abc] [at=1791061356]: coding\n" > "$rows_file"
  printf "1791061357\t2\tsignal\ttask.status\tsignal: working [corr=def] [at=1791061357]: more\n" >> "$rows_file"
  run_lib "$state" fm_wake_rows_all_record_only "$rows_file"
  expect_code 0 $? "two working-only signals should be all record-only (exit 0)"

  # Add an inbox check row -> exit 1
  printf "1791061358\t3\tcheck\tinbox:123\tcheck: captain inbox note\n" >> "$rows_file"
  run_lib "$state" fm_wake_rows_all_record_only "$rows_file"
  expect_code 1 $? "with check row should not be all record-only (exit 1)"

  # Empty file -> exit 1
  : > "$rows_file"
  run_lib "$state" fm_wake_rows_all_record_only "$rows_file"
  expect_code 1 $? "empty file should not be all record-only (exit 1)"

  # Missing file -> exit 1
  rm -f "$rows_file"
  run_lib "$state" fm_wake_rows_all_record_only "$rows_file"
  expect_code 1 $? "missing file should not be all record-only (exit 1)"

  # Malformed line (two fields) -> exit 1
  printf "field1\tfield2\n" > "$rows_file"
  run_lib "$state" fm_wake_rows_all_record_only "$rows_file"
  expect_code 1 $? "malformed line should not be all record-only (exit 1)"
}

# ============================================================
# Delivery record
# ============================================================

test_delivered_write() {
  local case_dir
  case_dir=$(make_case "delivered-write")
  local state="$case_dir/state"
  local delivered="$state/.drain-delivered"

  # Valid write
  run_lib "$state" fm_wake_delivered_write 42 "abc.1.xyz"
  expect_code 0 $? "valid write should succeed"
  [[ -f "$delivered" ]] || fail "delivered file should exist"
  local line
  line=$(cat "$delivered")
  local fields
  read -ra fields <<< "$line"
  [[ ${#fields[@]} -eq 3 ]] || fail "record should have three fields, got ${#fields[@]}"
  [[ "${fields[0]}" == "42" ]] || fail "first field should be 42, got ${fields[0]}"
  [[ "${fields[1]}" == "abc.1.xyz" ]] || fail "second field should be abc.1.xyz, got ${fields[1]}"
  local now
  now=$(date +%s)
  local diff
  diff=$((now - fields[2]))
  (( diff >= -5 && diff <= 5 )) || fail "timestamp should be within 5 seconds of now, diff=$diff"
  local mode
  mode=$(stat -c %a "$delivered" 2>/dev/null || stat -f %A "$delivered")
  [[ "$mode" == "600" ]] || fail "file mode should be 600, got $mode"

  # Invalid generation (non-numeric)
  rm -f "$delivered"
  run_lib "$state" fm_wake_delivered_write x "abc.1.xyz"
  expect_code 1 $? "non-numeric generation should fail"
  [[ ! -f "$delivered" ]] || fail "delivered file should not exist on failure"

  # Empty generation
  run_lib "$state" fm_wake_delivered_write "" "abc.1.xyz"
  expect_code 1 $? "empty generation should fail"
  [[ ! -f "$delivered" ]] || fail "delivered file should not exist on failure"

  # Generation with space
  run_lib "$state" fm_wake_delivered_write "a b" "abc.1.xyz"
  expect_code 1 $? "generation with space should fail"
  [[ ! -f "$delivered" ]] || fail "delivered file should not exist on failure"
}

# Claim in one bash process and print "<rc> <seq> <generation> <epoch>" (the claim reports through globals).
claim_lib() {  # <state>
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_wake_delivered_claim; rc=$?; echo "$rc ${FM_DELIVERED_SEQ:-} ${FM_DELIVERED_GENERATION:-} ${FM_DELIVERED_EPOCH:-}"' _ "$LIB"
}

test_delivered_claim() {
  local case_dir
  case_dir=$(make_case "delivered-claim")
  local state="$case_dir/state"
  local delivered="$state/.drain-delivered"
  local out fields

  # Write then claim
  run_lib "$state" fm_wake_delivered_write 42 "abc.1.xyz"
  out=$(claim_lib "$state")
  read -ra fields <<< "$out"
  [[ "${fields[0]}" == "0" ]] || fail "claim should succeed, got: $out"
  [[ "${fields[1]}" == "42" ]] || fail "claimed sequence should be 42, got: $out"
  [[ "${fields[2]}" == "abc.1.xyz" ]] || fail "claimed generation should be abc.1.xyz, got: $out"
  [[ -n "${fields[3]:-}" ]] || fail "claimed epoch should be present, got: $out"
  [[ ! -f "$delivered" ]] || fail "delivered file should be removed after claim"

  # Second claim fails
  out=$(claim_lib "$state")
  read -ra fields <<< "$out"
  [[ "${fields[0]}" == "1" ]] || fail "second claim should fail with 1, got: $out"

  # Malformed record: returns 2 and is still removed
  echo "garbage" > "$delivered"
  out=$(claim_lib "$state")
  read -ra fields <<< "$out"
  [[ "${fields[0]}" == "2" ]] || fail "malformed record should return 2, got: $out"
  [[ ! -f "$delivered" ]] || fail "malformed record should be removed"

  # Race: two claims on one record, exactly one wins
  run_lib "$state" fm_wake_delivered_write 99 "race.id"
  local pids=()
  local i
  for i in 1 2; do
    (claim_lib "$state" > "$state/result.$i") &
    pids+=($!)
  done
  wait "${pids[@]}"
  local wins=0 r
  for i in 1 2; do
    r=$(cut -d' ' -f1 "$state/result.$i")
    [[ "$r" == "0" ]] && wins=$((wins + 1))
  done
  [[ $wins -eq 1 ]] || fail "exactly one claim should succeed, got $wins"
}

# ============================================================
# Interruption check
# ============================================================

test_interruption_real_marker() {
  local case_dir
  case_dir=$(make_case "interruption-real")
  local state="$case_dir/state"
  local transcript="$state/transcript.jsonl"

  # Real interruption line
  cat > "$transcript" <<'EOF'
{"parentUuid":"5c3430d9-832d-450c-89cc-b472db895c59","isSidechain":false,"promptId":"ecfef989-3c3e-4f7e-ad5b-a8657e96583f","type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"3c3eac00-f5c6-497e-a198-8c686051a8fe","timestamp":"2026-09-22T13:43:17.214Z","session_id":"1d64f431-567f-42d1-a9c3-bff7e8aa9624","userType":"external","entrypoint":"cli","cwd":"/home/justin/nexus-brain","sessionId":"1d64f431-567f-42d1-a9c3-bff7e8aa9624","version":"2.1.252","gitBranch":"main"}
EOF

  local marker_epoch
  marker_epoch=$(date -u -d "2026-09-22T13:43:17Z" +%s)

  # Since earlier than marker -> interrupted (0)
  run_lib "$state" fm_stop_turn_interrupted "$transcript" 1790000000
  expect_code 0 $? "since before marker should be interrupted (exit 0)"

  # Since equal to marker -> interrupted (0)
  run_lib "$state" fm_stop_turn_interrupted "$transcript" "$marker_epoch"
  expect_code 0 $? "since equal to marker should be interrupted (exit 0)"

  # Since one second after marker -> not interrupted (1)
  run_lib "$state" fm_stop_turn_interrupted "$transcript" $((marker_epoch + 1))
  expect_code 1 $? "since after marker should not be interrupted (exit 1)"

  # Since much later -> not interrupted (1)
  run_lib "$state" fm_stop_turn_interrupted "$transcript" 1800000000
  expect_code 1 $? "since much later should not be interrupted (exit 1)"
}

test_interruption_variants() {
  local case_dir
  case_dir=$(make_case "interruption-variants")
  local state="$case_dir/state"
  local transcript="$state/transcript.jsonl"
  local marker_epoch
  marker_epoch=$(date -u -d "2026-09-22T13:43:17Z" +%s)

  # For tool use variant
  cat > "$transcript" <<'EOF'
{"parentUuid":"5c3430d9-832d-450c-89cc-b472db895c59","isSidechain":false,"promptId":"ecfef989-3c3e-4f7e-ad5b-a8657e96583f","type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"uuid":"3c3eac00-f5c6-497e-a198-8c686051a8fe","timestamp":"2026-09-22T13:43:17.214Z","session_id":"1d64f431-567f-42d1-a9c3-bff7e8aa9624","userType":"external","entrypoint":"cli","cwd":"/home/justin/nexus-brain","sessionId":"1d64f431-567f-42d1-a9c3-bff7e8aa9624","version":"2.1.252","gitBranch":"main"}
EOF
  run_lib "$state" fm_stop_turn_interrupted "$transcript" 1790000000
  expect_code 0 $? "for tool use variant should be interrupted (exit 0)"
  run_lib "$state" fm_stop_turn_interrupted "$transcript" $((marker_epoch + 1))
  expect_code 1 $? "for tool use variant after marker should not be interrupted (exit 1)"

  # Ordinary lines only
  cat > "$transcript" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll help with that"}]},"timestamp":"2026-09-22T13:43:17.214Z"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"continue"}]},"timestamp":"2026-09-22T13:43:18.214Z"}
EOF
  run_lib "$state" fm_stop_turn_interrupted "$transcript" 1790000000
  expect_code 1 $? "ordinary lines should not be interrupted (exit 1)"

  # Interruption marker with no timestamp
  cat > "$transcript" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"3c3eac00-f5c6-497e-a198-8c686051a8fe"}
EOF
  run_lib "$state" fm_stop_turn_interrupted "$transcript" 1790000000
  expect_code 0 $? "marker without timestamp should be interrupted (exit 0)"

  # Missing path
  run_lib "$state" fm_stop_turn_interrupted "$state/missing.jsonl" 1790000000
  expect_code 2 $? "missing path should return 2"

  # Empty path
  run_lib "$state" fm_stop_turn_interrupted "" 1790000000
  expect_code 2 $? "empty path should return 2"

  # Directory
  run_lib "$state" fm_stop_turn_interrupted "$state" 1790000000
  expect_code 2 $? "directory should return 2"
}

test_interruption_marker_old_ignored() {
  local case_dir
  case_dir=$(make_case "interruption-old")
  local state="$case_dir/state"
  local transcript="$state/transcript.jsonl"

  # Build transcript: marker first, then ~450KB of ordinary lines
  {
    echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}],"timestamp":"2026-09-22T13:43:17.214Z"}'
    # Generate ~450KB of ordinary lines
    for i in {1..4000}; do
      echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Line $i with some content to make it longer\"}]},\"timestamp\":\"2026-09-22T13:43:$(printf %02d $((17 + i % 60))).214Z\"}"
    done
  } > "$transcript"

  # File should be > 400KB
  local size
  size=$(stat -c %s "$transcript" 2>/dev/null || stat -f %z "$transcript")
  (( size > 400000 )) || fail "transcript should be > 400KB, got $size bytes"

  # Since before marker but marker is old -> not interrupted (1)
  run_lib "$state" fm_stop_turn_interrupted "$transcript" 1790000000
  expect_code 1 $? "old marker beyond 400KB should be ignored (exit 1)"
}

# ============================================================
# Section gate
# ============================================================

test_section_hash_stable() {
  local case_dir
  case_dir=$(make_case "section-hash")
  local state="$case_dir/state"

  local h1
  h1=$(run_lib "$state" fm_wake_section_hash "abc")
  local h2
  h2=$(run_lib "$state" fm_wake_section_hash "abc")
  [[ "$h1" == "$h2" ]] || fail "hash should be stable across calls: $h1 vs $h2"

  local h3
  h3=$(run_lib "$state" fm_wake_section_hash "abd")
  [[ "$h1" != "$h3" ]] || fail "hash should differ for different input: $h1 vs $h3"
}

test_section_unchanged_record_forget() {
  local case_dir
  case_dir=$(make_case "section-unchanged")
  local state="$case_dir/state"

  # Before any record -> unchanged returns 1
  run_lib "$state" fm_wake_section_unchanged "open-decisions" "H1"
  expect_code 1 $? "unchanged before record should return 1"

  # Record then unchanged -> 0
  run_lib "$state" fm_wake_section_record "open-decisions" "H1"
  run_lib "$state" fm_wake_section_unchanged "open-decisions" "H1"
  expect_code 0 $? "unchanged after record with same hash should return 0"

  # Different hash -> 1
  run_lib "$state" fm_wake_section_unchanged "open-decisions" "H2"
  expect_code 1 $? "unchanged with different hash should return 1"

  # Different name -> 1
  run_lib "$state" fm_wake_section_unchanged "other-name" "H1"
  expect_code 1 $? "unchanged with different name should return 1"

  # Record second name keeps first
  run_lib "$state" fm_wake_section_record "other-name" "H2"
  run_lib "$state" fm_wake_section_unchanged "open-decisions" "H1"
  expect_code 0 $? "first name should still be unchanged after recording second"

  # Forget removes only its name
  run_lib "$state" fm_wake_section_forget "other-name"
  run_lib "$state" fm_wake_section_unchanged "open-decisions" "H1"
  expect_code 0 $? "first name should still be unchanged after forgetting second"
  run_lib "$state" fm_wake_section_unchanged "other-name" "H2"
  expect_code 1 $? "forgotten name should return 1"

  # Forget last entry removes file
  run_lib "$state" fm_wake_section_forget "open-decisions"
  run_lib "$state" fm_wake_section_unchanged "open-decisions" "H1"
  expect_code 1 $? "forgotten last name should return 1"

  # Forget on missing file succeeds
  run_lib "$state" fm_wake_section_forget "nonexistent"
  expect_code 0 $? "forget on missing file should succeed"
}

test_section_ttl() {
  local case_dir
  case_dir=$(make_case "section-ttl")
  local state="$case_dir/state"

  # A short TTL: each bash start costs seconds on a loaded machine, so the window
  # is wide enough to read back inside and the sleep clears it
  FM_DRAIN_SECTION_TTL_SECS=10 run_lib "$state" fm_wake_section_record "test" "H1"
  FM_DRAIN_SECTION_TTL_SECS=10 run_lib "$state" fm_wake_section_unchanged "test" "H1"
  expect_code 0 $? "inside the TTL should be unchanged"

  sleep 11
  FM_DRAIN_SECTION_TTL_SECS=10 run_lib "$state" fm_wake_section_unchanged "test" "H1"
  expect_code 1 $? "past the TTL should not be unchanged"

  # Bad overrides fall back to default (14400)
  local case_dir2
  case_dir2=$(make_case "section-ttl-bad")
  local state2="$case_dir2/state"
  for bad in "abc" "0" "-5"; do
    FM_DRAIN_SECTION_TTL_SECS="$bad" run_lib "$state2" fm_wake_section_record "test" "H1"
    FM_DRAIN_SECTION_TTL_SECS="$bad" run_lib "$state2" fm_wake_section_unchanged "test" "H1"
    expect_code 0 $? "bad TTL '$bad' should fall back to default, record should be unchanged"
  done
}

# ============================================================
# Log
# ============================================================

test_absorb_log() {
  local case_dir
  case_dir=$(make_case "absorb-log")
  local state="$case_dir/state"
  local log="$state/wake-absorb.jsonl"

  # Normal log
  run_lib "$state" fm_wake_absorb_log absorbed seq=7 note='a "quoted" value'
  expect_code 0 $? "log should return 0"
  [[ -f "$log" ]] || fail "log file should exist"
  local line
  line=$(cat "$log")
  python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin]' <<< "$line" || fail "log line should be valid JSON"
  assert_contains "$line" '"event":"absorbed"' "log should have event=absorbed"
  assert_contains "$line" '"seq":"7"' "log should have seq=7"
  assert_contains "$line" 'a \"quoted\" value' "log should have escaped quoted value"
  # Check ts is numeric
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert isinstance(d.get("ts"), (int, float))' <<< "$line" || fail "ts should be numeric"

  # Bad key name skipped
  run_lib "$state" fm_wake_absorb_log absorbed bad-key=1 seq=8
  expect_code 0 $? "bad key should be skipped but return 0"
  local lines
  lines=$(wc -l < "$log")
  [[ "$lines" -eq 2 ]] || fail "should have 2 lines, got $lines"

  # Returns 0 and prints nothing even when state not writable
  mkdir -p "$state/wake-absorb.jsonl"  # Make it a directory to force failure
  local out
  out=$(run_lib "$state" fm_wake_absorb_log absorbed seq=9 2>&1)
  expect_code 0 $? "should return 0 even when not writable"
  [[ -z "$out" ]] || fail "should print nothing, got: $out"
}

test_absorb_log_trim() {
  local case_dir
  case_dir=$(make_case "absorb-log-trim")
  local state="$case_dir/state"
  local log="$state/wake-absorb.jsonl"

  # Write 1000100 bytes of lines
  local pad
  pad=$(printf 'x%.0s' {1..180})
  {
    for i in {1..5200}; do
      echo '{"event":"absorbed","seq":"'"$i"'","ts":1234567890,"note":"line '"$i"' '"$pad"'"}'
    done
  } > "$log"
  local size
  size=$(stat -c %s "$log" 2>/dev/null || stat -f %z "$log")
  (( size > 1000000 )) || fail "log should be > 1MB, got $size bytes"

  # Call function once - should trim
  run_lib "$state" fm_wake_absorb_log absorbed seq=9999 note="new event"
  expect_code 0 $? "trim call should succeed"

  # Check line count <= 2001
  local lines
  lines=$(wc -l < "$log")
  (( lines <= 2001 )) || fail "log should have at most 2001 lines after trim, got $lines"

  # Last line should be the new event
  local last
  last=$(tail -1 "$log")
  assert_contains "$last" '"seq":"9999"' "last line should be the new event"
  assert_contains "$last" '"note":"new event"' "last line should have new event note"
}

# ============================================================
# Run all tests
# ============================================================

test_classification_working_only_record_only
test_classification_working_then_done_needs_brain
test_classification_wake_verbs_alone
test_classification_working_then_resolved_or_captain_held_needs_brain
test_classification_payload_needs_decision_over_working
test_classification_turn_ended_key_needs_brain
test_classification_missing_status_invalid_key_symlink_needs_brain
test_classification_no_unread_lines_needs_brain
test_classification_check_and_other_kinds_needs_brain
test_classification_check_merge_landed_meta_dependent
test_rows_all_record_only
test_delivered_write
test_delivered_claim
test_interruption_real_marker
test_interruption_variants
test_interruption_marker_old_ignored
test_section_hash_stable
test_section_unchanged_record_forget
test_section_ttl
test_absorb_log
test_absorb_log_trim

echo "ok: fm-wake-absorb-lib tests"
