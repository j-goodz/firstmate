#!/usr/bin/env bash
# Behavior tests for bin/fm-account-pick.sh, the per-launch Claude account picker.
#
# Every case drives the script through its command line with a fixture config,
# a fixture usage snapshot shaped like the live fleet snapshot (ISO stamps with
# fractional seconds and a +00:00 offset), fixture credential stores, and a
# pinned clock (FM_ACCOUNT_PICK_NOW), then asserts the printed pick and the
# JSONL log line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PICK="$ROOT/bin/fm-account-pick.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-pick)

# 2026-10-03T01:20:00Z, the fixed clock every case runs at.
NOW=1790990400

iso_at() {  # <epoch> -> ISO-8601 with fractional seconds and +00:00, like the live snapshot
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.123456+00:00'
}

# make_store <dir> [signed-in|signed-out|expired]
make_store() {
  local dir=$1 state=${2:-signed-in}
  mkdir -p "$dir"
  printf '{}\n' > "$dir/.claude.json"
  case "$state" in
  signed-in)
    printf '{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","refreshTokenExpiresAt":%s000}}\n' "$((NOW + 86400 * 10))" > "$dir/.credentials.json"
    ;;
  expired)
    printf '{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","refreshTokenExpiresAt":%s000}}\n' "$((NOW - 3600))" > "$dir/.credentials.json"
    ;;
  signed-out) : ;;
  esac
}

# account_json <five_hour_pct> <weekly_pct> <hours_to_weekly_reset> <age_seconds> [outcome]
account_json() {
  local five=$1 weekly=$2 hours=$3 age=$4 outcome=${5:-ok}
  printf '{"five_hour_pct":%s,"five_hour_resets_at":"%s","weekly_pct":%s,"weekly_resets_at":"%s","fable_weekly_pct":0.0,"outcome":"%s","fetched_at":"%s","age_s":0.13}' \
    "$five" "$(iso_at $((NOW + 3600)))" "$weekly" "$(iso_at $((NOW + hours * 3600)))" "$outcome" \
    "$(date -u -d "@$((NOW - age))" '+%Y-%m-%dT%H:%M:%SZ')"
}

# new_case <name>: fresh case dir with two signed-in stores and a config naming them.
new_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE"
  make_store "$CASE/account-1"
  make_store "$CASE/account-3"
  SNAP="$CASE/usage-snapshot.json"
  CONF="$CASE/claude-accounts"
  LOG="$CASE/account-picks.jsonl"
  {
    printf '# candidate Claude accounts\n'
    printf 'snapshot %s\n' "$SNAP"
    printf 'account account-1 %s\n' "$CASE/account-1"
    printf '\n'
    printf 'account account-3 %s\n' "$CASE/account-3"
  } > "$CONF"
}

# write_snapshot <account-1 json> <account-3 json>
write_snapshot() {
  printf '{"version":1,"generated_at":"%s","host":"cloud-server","accounts":{"account-1":%s,"account-3":%s}}\n' \
    "$(iso_at "$NOW")" "$1" "$2" > "$SNAP"
}

# run_pick [<current store>]: the supervisor's own store defaults to one no
# account line names.
run_pick() {
  OUT=$(FM_ACCOUNT_PICK_NOW=$NOW "$PICK" --config "$CONF" --log "$LOG" --task t-1 --current "${1-$CASE/inherited}" 2>"$CASE/stderr")
  STATUS=$?
}

toronto() {  # <local "YYYY-MM-DD HH:MM"> -> epoch, read as America/Toronto wall time
  TZ=America/Toronto date -d "$1" +%s
}

last_account() {  # <label> <jq field> -> that account's field in the newest log line
  tail -n 1 "$LOG" | jq -c --arg l "$1" ".accounts[] | select(.label == \$l) | .$2"
}

field() {  # <key> -> value of key=value in OUT
  printf '%s\n' "$OUT" | sed -n "s/^$1=//p"
}

test_absent_config_is_a_noop() {
  new_case absent
  rm -f "$CONF"
  run_pick
  expect_code 0 "$STATUS" "absent config must succeed"
  assert_equals "" "$OUT" "absent config must print no pick"
  assert_absent "$LOG" "absent config must write no log line"
  pass "absent config keeps today's behavior: no pick, no log"
}

test_sooner_weekly_reset_wins_at_equal_remaining() {
  new_case sooner-reset
  write_snapshot "$(account_json 10 50 96 30)" "$(account_json 10 50 24 30)"
  run_pick
  expect_code 0 "$STATUS" "pick must succeed"
  assert_equals account-3 "$(field account)" "equal remaining weekly must favor the sooner reset"
  assert_equals "$CASE/account-3" "$(field config_dir)" "config_dir must be the chosen account's store"
  pass "at equal remaining weekly, the account whose allowance expires sooner is spent first"
}

test_spend_rate_ranks_remaining_over_hours() {
  new_case spend-rate
  # account-1: 16% left over 116h (0.14/h); account-3: 53% left over 108h (0.49/h).
  write_snapshot "$(account_json 23 84 116 30)" "$(account_json 3 47 108 30)"
  run_pick
  assert_equals account-3 "$(field account)" "the account with more weekly allowance per remaining hour must win"
  # Flip it: account-1 resets in 2h with 16% left (8/h) beats account-3's 0.49/h.
  write_snapshot "$(account_json 23 84 2 30)" "$(account_json 3 47 108 30)"
  run_pick
  assert_equals account-1 "$(field account)" "allowance about to expire unused must be spent first"
  pass "ranking is remaining weekly percent divided by hours to weekly reset"
}

test_five_hour_exclusion() {
  new_case five-hour
  # account-1 ranks first on weekly, but its 5-hour window is above the 85% threshold.
  write_snapshot "$(account_json 90 50 2 30)" "$(account_json 10 50 96 30)"
  run_pick
  assert_equals account-3 "$(field account)" "an account above the 5-hour threshold must be skipped"
  assert_contains "$(tail -n 1 "$LOG")" '"status":"excluded-5h"' "log must name the 5-hour exclusion"
  pass "an account without 5-hour headroom is excluded"
}

test_weekly_exhausted_is_excluded() {
  new_case weekly-exhausted
  write_snapshot "$(account_json 10 99 1 30)" "$(account_json 10 50 96 30)"
  run_pick
  assert_equals account-3 "$(field account)" "an account with no weekly allowance left must be skipped"
  assert_contains "$(tail -n 1 "$LOG")" '"status":"excluded-weekly"' "log must name the weekly exclusion"
  pass "an account with its weekly allowance spent is excluded"
}

test_stale_data_is_unknown() {
  new_case stale
  # account-1 ranks first but its reading is two hours old.
  write_snapshot "$(account_json 10 50 2 7200)" "$(account_json 10 50 96 30)"
  run_pick
  assert_equals account-3 "$(field account)" "stale data must not be trusted as fresh"
  assert_contains "$(tail -n 1 "$LOG")" '"status":"unknown-stale"' "log must mark the stale reading unknown"
  pass "a reading older than the age limit is treated as unknown"
}

test_failed_reading_is_unknown() {
  new_case failed-reading
  write_snapshot "$(account_json 10 50 2 30 error)" "$(account_json 10 50 96 30)"
  run_pick
  assert_equals account-3 "$(field account)" "a failed reading must not be trusted"
  pass "a reading whose outcome is not ok is treated as unknown"
}

test_missing_signin_is_excluded() {
  new_case signin
  rm -rf "$CASE/account-1"
  make_store "$CASE/account-1" signed-out
  write_snapshot "$(account_json 10 50 2 30)" "$(account_json 10 50 96 30)"
  run_pick
  assert_equals account-3 "$(field account)" "an account with no sign-in must be skipped"
  rm -rf "$CASE/account-1"
  make_store "$CASE/account-1" expired
  run_pick
  assert_equals account-3 "$(field account)" "an account whose sign-in expired must be skipped"
  assert_contains "$(tail -n 1 "$LOG")" '"status":"excluded-signin"' "log must name the sign-in exclusion"
  pass "an account without a usable sign-in is excluded"
}

test_signin_file_counts_as_signin() {
  new_case signin-file
  rm -rf "$CASE/account-1"
  make_store "$CASE/account-1" signed-out
  printf 'fixture\n' > "$CASE/env-account-1"
  sed -i "s|^account account-1 .*|account account-1 $CASE/account-1 $CASE/env-account-1|" "$CONF"
  write_snapshot "$(account_json 10 50 2 30)" "$(account_json 10 50 96 30)"
  run_pick
  assert_equals account-1 "$(field account)" "a present sign-in file must count as a usable sign-in"
  pass "an optional per-account sign-in file stands in for the credential store"
}

test_tie_breaks_on_lower_five_hour() {
  new_case tie
  write_snapshot "$(account_json 40 50 48 30)" "$(account_json 20 50 48 30)"
  run_pick
  assert_equals account-3 "$(field account)" "a tie must go to the lower 5-hour use"
  pass "ties break on lower 5-hour use"
}

test_all_excluded_falls_back_to_current() {
  new_case fallback
  write_snapshot "$(account_json 90 50 2 30)" "$(account_json 10 50 96 7200)"
  run_pick
  expect_code 0 "$STATUS" "fallback must still succeed"
  assert_equals inherited "$(field account)" "all excluded must fall back to the current account"
  assert_equals "$CASE/inherited" "$(field config_dir)" "fallback must keep the current store"
  assert_contains "$(field reason)" "fallback" "fallback must say so in the reason"
  assert_contains "$(tail -n 1 "$LOG")" '"fallback":true' "fallback must say so in the log"
  rm -f "$SNAP"
  run_pick
  expect_code 0 "$STATUS" "a missing snapshot must still succeed"
  assert_equals inherited "$(field account)" "a missing snapshot must fall back to the current account"
  printf 'not json\n' > "$SNAP"
  run_pick
  expect_code 0 "$STATUS" "an unreadable snapshot must still succeed"
  assert_equals inherited "$(field account)" "an unreadable snapshot must fall back to the current account"
  pass "when every account is excluded or unknown, the current account is kept and logged"
}

test_log_line_carries_every_account() {
  new_case log
  write_snapshot "$(account_json 23 84 116 30)" "$(account_json 3 47 108 45)"
  run_pick
  local line
  [ "$(wc -l < "$LOG")" -eq 1 ] || fail "one pick must append exactly one log line"
  line=$(tail -n 1 "$LOG")
  printf '%s\n' "$line" | jq -e . >/dev/null || fail "log line must be valid JSON: $line"
  assert_equals account-3 "$(printf '%s' "$line" | jq -r .chosen)" "log must name the chosen account"
  assert_equals t-1 "$(printf '%s' "$line" | jq -r .task)" "log must name the task"
  assert_equals 2 "$(printf '%s' "$line" | jq '.accounts | length')" "log must carry both accounts"
  assert_equals 84 "$(printf '%s' "$line" | jq '.accounts[] | select(.label=="account-1") | .weekly_pct')" "log must carry account-1 weekly use"
  assert_equals 3 "$(printf '%s' "$line" | jq '.accounts[] | select(.label=="account-3") | .five_hour_pct')" "log must carry account-3 5-hour use"
  assert_equals 45 "$(printf '%s' "$line" | jq '.accounts[] | select(.label=="account-3") | .age_s')" "log must carry the data age"
  assert_not_equals "" "$(printf '%s' "$line" | jq -r .reason)" "log must carry a reason"
  assert_not_contains "$line" "fixture-refresh" "log must never carry credential material"
  assert_not_contains "$OUT" "fixture-refresh" "output must never carry credential material"
  pass "each pick appends one JSONL line with both accounts' numbers, age, choice, and reason"
}

test_malformed_config_refuses() {
  new_case malformed
  printf 'account only-a-label\n' >> "$CONF"
  run_pick
  expect_code 2 "$STATUS" "a malformed config line must refuse"
  "$PICK" --check --config "$CONF" >/dev/null 2>&1
  expect_code 2 "$?" "--check must refuse the same malformed config"
  new_case no-accounts
  printf 'snapshot %s\n' "$SNAP" > "$CONF"
  run_pick
  expect_code 2 "$STATUS" "a config listing no accounts must refuse"
  new_case relative
  printf 'snapshot %s\naccount a relative/dir\n' "$SNAP" > "$CONF"
  run_pick
  expect_code 2 "$STATUS" "a relative account store must refuse"
  new_case unknown-key
  printf 'bogus line\n' >> "$CONF"
  run_pick
  expect_code 2 "$STATUS" "an unknown config keyword must refuse"
  pass "a malformed config is refused rather than silently ignored"
}

test_check_accepts_valid_and_absent() {
  new_case check
  "$PICK" --check --config "$CONF" >/dev/null 2>&1 || fail "--check must accept a valid config"
  "$PICK" --check --config "$CASE/missing" >/dev/null 2>&1 || fail "--check must accept an absent config"
  assert_absent "$LOG" "--check must not log a pick"
  pass "--check validates without picking"
}

test_reserve_window_excludes_on_weekday_mornings() {
  local NOW
  NOW=$(toronto "2026-10-02 05:00")  # a Friday
  new_case reserve-window
  printf 'reserve account-3 03:00 08:00\n' >> "$CONF"
  # account-3 ranks first on weekly allowance but sits inside its reserve window.
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  expect_code 0 "$STATUS" "a pick with a reserved account must still succeed"
  assert_equals account-1 "$(field account)" "a reserved account must not be chosen inside its window"
  assert_equals '"excluded-reserve"' "$(last_account account-3 status)" "log must name the reserve exclusion"
  assert_equals true "$(last_account account-3 reserved)" "log must mark the account reserved"
  assert_equals "$(toronto "2026-10-02 08:00")" "$(last_account account-3 reserve_until)" "log must carry when the reserve ends"
  assert_equals '"window"' "$(last_account account-3 reserve_source)" "log must say the window set the reserve"
  assert_equals false "$(last_account account-1 reserved)" "an unreserved account must log reserved false"
  assert_equals null "$(last_account account-1 reserve_until)" "an unreserved account must log no reserve end"
  pass "a reserve window keeps its account out of weekday-morning picks and logs when it ends"
}

test_reserve_window_bounds_and_weekends() {
  local NOW=$NOW
  new_case reserve-bounds
  printf 'reserve account-3 03:00 08:00\n' >> "$CONF"
  for at in "2026-10-02 02:59" "2026-10-02 08:00" "2026-10-03 05:00" "2026-10-04 05:00"; do
    NOW=$(toronto "$at")
    write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
    run_pick
    assert_equals account-3 "$(field account)" "the reserve must not apply at $at"
    assert_equals false "$(last_account account-3 reserved)" "the account must log unreserved at $at"
  done
  NOW=$(toronto "2026-10-02 03:00")
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  assert_equals account-1 "$(field account)" "the reserve must start exactly at its start time"
  pass "a reserve window starts at its start time, ends before its end time, and skips weekends"
}

test_reserve_window_in_winter_time() {
  local NOW
  NOW=$(toronto "2026-12-07 07:59")  # a Monday, Eastern Standard Time
  new_case reserve-winter
  printf 'reserve account-3 03:00 08:00\n' >> "$CONF"
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  assert_equals account-1 "$(field account)" "the reserve must follow Toronto standard time in winter"
  assert_equals "$(toronto "2026-12-07 08:00")" "$(last_account account-3 reserve_until)" "the reserve end must be 08:00 Toronto standard time"
  pass "a reserve window follows Toronto local time across the daylight-saving change"
}

test_reserve_window_across_midnight_uses_its_start_day() {
  local NOW=$NOW
  new_case reserve-overnight
  printf 'reserve account-3 22:00 03:00\n' >> "$CONF"
  NOW=$(toronto "2026-10-06 01:00")  # Tuesday morning, window opened Monday night
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  assert_equals account-1 "$(field account)" "an overnight window opened on a weekday must hold past midnight"
  assert_equals "$(toronto "2026-10-06 03:00")" "$(last_account account-3 reserve_until)" "an overnight reserve must end the next morning"
  NOW=$(toronto "2026-10-05 01:00")  # Monday morning, window would have opened Sunday night
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  assert_equals account-3 "$(field account)" "an overnight window opened on a Sunday must not apply"
  pass "an overnight reserve window belongs to the weekday it opens on"
}

test_reserve_file_excludes_until_epoch() {
  new_case reserve-file
  printf 'reserve-file %s\n' "$CASE/account-reserve" >> "$CONF"
  {
    printf '# spent accounts\n'
    printf '3 %s\n' "$((NOW + 7200))"
    printf 'account-1 %s\n' "$((NOW - 60))"
  } > "$CASE/account-reserve"
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  expect_code 0 "$STATUS" "a pick with a reserve file must succeed"
  assert_equals account-1 "$(field account)" "an account number in the reserve file must exclude that account"
  assert_equals '"excluded-reserve"' "$(last_account account-3 status)" "log must name the reserve exclusion"
  assert_equals "$((NOW + 7200))" "$(last_account account-3 reserve_until)" "log must carry the file's end time"
  assert_equals '"file"' "$(last_account account-3 reserve_source)" "log must say the file set the reserve"
  assert_equals false "$(last_account account-1 reserved)" "a reserve line in the past must be ignored"
  # Once the until epoch passes, the account is back in the pick.
  local NOW=$((NOW + 7200))
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  assert_equals account-3 "$(field account)" "the account must return once its reserve ends"
  pass "a reserve file line holds an account out until its epoch and no longer"
}

test_reserve_file_missing_or_bad_lines_are_not_errors() {
  new_case reserve-file-missing
  printf 'reserve-file %s\n' "$CASE/no-such-file" >> "$CONF"
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  expect_code 0 "$STATUS" "a missing reserve file must not be an error"
  assert_equals account-3 "$(field account)" "a missing reserve file must reserve nothing"
  printf 'nonsense\naccount-9 %s\n3 soon\n' "$((NOW + 60))" > "$CASE/no-such-file"
  run_pick
  expect_code 0 "$STATUS" "unusable reserve lines must not refuse the pick"
  assert_equals account-3 "$(field account)" "unusable reserve lines must reserve nothing"
  assert_contains "$(cat "$CASE/stderr")" "warning" "unusable reserve lines must be warned about"
  pass "a missing reserve file or unusable lines in it reserve nothing and do not refuse"
}

test_reserve_takes_the_latest_end() {
  local NOW
  NOW=$(toronto "2026-10-02 05:00")
  new_case reserve-both
  printf 'reserve account-3 03:00 08:00\nreserve-file %s\n' "$CASE/account-reserve" >> "$CONF"
  printf 'account-3 %s\n' "$(toronto "2026-10-02 11:00")" > "$CASE/account-reserve"
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick
  assert_equals "$(toronto "2026-10-02 11:00")" "$(last_account account-3 reserve_until)" "the later of two reserves must set the end"
  assert_equals '"file"' "$(last_account account-3 reserve_source)" "the source must be the reserve that ends last"
  pass "when a window and a file line both reserve an account, the later end wins"
}

test_reserved_account_is_never_the_fallback() {
  new_case reserve-fallback
  printf 'reserve-file %s\n' "$CASE/account-reserve" >> "$CONF"
  printf '1 %s\n' "$((NOW + 3600))" > "$CASE/account-reserve"
  # No snapshot: no account is eligible, so the pick would fall back to the
  # supervisor's own store, and that store is the reserved account-1.
  rm -f "$SNAP"
  run_pick "$CASE/account-1/"
  expect_code 3 "$STATUS" "a fallback onto a reserved store must refuse"
  assert_equals "" "$OUT" "a refusal must print no pick"
  local err
  err=$(cat "$CASE/stderr")
  assert_equals 1 "$(printf '%s\n' "$err" | grep -c .)" "a refusal must be exactly one stderr line"
  assert_contains "$err" "account-1" "the refusal must name the reserved account"
  assert_contains "$err" "$(TZ=America/Toronto date -d "@$((NOW + 3600))" '+%Y-%m-%d %H:%M')" "the refusal must say when the reserve ends"
  assert_equals true "$(tail -n 1 "$LOG" | jq .refused)" "the refusal must be logged"
  # A fallback onto a store no account line names stays allowed.
  run_pick
  expect_code 0 "$STATUS" "a fallback onto an unreserved store must still succeed"
  assert_equals inherited "$(field account)" "the unreserved fallback must keep the current store"
  pass "a reserved account is never used as the fallback; the pick refuses instead"
}

test_supervisor_account_is_never_held_idle() {
  new_case supervisor
  # account-3 ranks first and the spawning supervisor runs on it: it must still win.
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 3 47 24 30)"
  run_pick "$CASE/account-3"
  assert_equals account-3 "$(field account)" "the supervisor's own account must compete like any other"
  # When its 5-hour window fills, work moves to the other account instead of stopping.
  write_snapshot "$(account_json 10 84 116 30)" "$(account_json 90 47 24 30)"
  run_pick "$CASE/account-3"
  assert_equals account-1 "$(field account)" "a 5-hour exclusion must move work to the other account"
  assert_equals false "$(tail -n 1 "$LOG" | jq .fallback)" "balancing to the other account is not a fallback"
  pass "no eligible account is held idle, the supervisor's included, and a full 5-hour window moves work over"
}

test_reserve_config_is_validated() {
  local bad
  for bad in 'reserve account-9 03:00 08:00' 'reserve account-1 3:00 08:00' 'reserve account-1 03:00 24:00' \
    'reserve account-1 03:00 03:00' 'reserve account-1 03:00' 'reserve-file relative/path' 'reserve-file'; do
    new_case reserve-malformed
    printf '%s\n' "$bad" >> "$CONF"
    "$PICK" --check --config "$CONF" >/dev/null 2>&1
    expect_code 2 "$?" "--check must refuse '$bad'"
  done
  new_case reserve-file-twice
  printf 'reserve-file /a\nreserve-file /b\n' >> "$CONF"
  "$PICK" --check --config "$CONF" >/dev/null 2>&1
  expect_code 2 "$?" "--check must refuse a second reserve-file line"
  new_case reserve-valid
  printf 'reserve account-1 03:00 08:00\nreserve account-1 22:00 23:30\nreserve-file /nonexistent/reserve\n' >> "$CONF"
  "$PICK" --check --config "$CONF" >/dev/null 2>&1 || fail "--check must accept valid reserve lines"
  pass "reserve lines are validated with the rest of the config"
}

test_reserve_without_jq_refuses() {
  new_case reserve-nojq
  printf 'reserve-file %s\n' "$CASE/account-reserve" >> "$CONF"
  mkdir -p "$CASE/bin"
  local tool
  for tool in bash date; do ln -s "$(command -v "$tool")" "$CASE/bin/$tool"; done
  OUT=$(PATH="$CASE/bin" FM_ACCOUNT_PICK_NOW=$NOW "$PICK" --config "$CONF" --task t-1 --current "$CASE/account-1" 2>"$CASE/stderr")
  expect_code 3 "$?" "with a reserve configured and no jq, the pick must refuse"
  assert_equals "" "$OUT" "the refusal must print no pick"
  pass "a configured reserve that cannot be evaluated refuses rather than falling back"
}

test_absent_config_is_a_noop
test_sooner_weekly_reset_wins_at_equal_remaining
test_spend_rate_ranks_remaining_over_hours
test_five_hour_exclusion
test_weekly_exhausted_is_excluded
test_stale_data_is_unknown
test_failed_reading_is_unknown
test_missing_signin_is_excluded
test_signin_file_counts_as_signin
test_tie_breaks_on_lower_five_hour
test_all_excluded_falls_back_to_current
test_log_line_carries_every_account
test_malformed_config_refuses
test_check_accepts_valid_and_absent
test_reserve_window_excludes_on_weekday_mornings
test_reserve_window_bounds_and_weekends
test_reserve_window_in_winter_time
test_reserve_window_across_midnight_uses_its_start_day
test_reserve_file_excludes_until_epoch
test_reserve_file_missing_or_bad_lines_are_not_errors
test_reserve_takes_the_latest_end
test_reserved_account_is_never_the_fallback
test_supervisor_account_is_never_held_idle
test_reserve_config_is_validated
test_reserve_without_jq_refuses

echo "# all fm-account-pick tests passed"
