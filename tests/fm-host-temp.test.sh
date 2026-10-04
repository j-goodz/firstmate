#!/usr/bin/env bash
# tests/fm-host-temp.test.sh - bin/fm-host-temp.sh reads the host CPU
# temperature for the optional thermal gate (config/thermal-gate).
#
# The assertions drive the real script against fixture sysfs trees rather than
# reading its source: the x86_pkg_temp zone is preferred over a hotter sibling,
# the hottest readable zone is the fallback, and an absent or unreadable sensor
# prints nothing and exits 3 so a caller can tell "no sensor" from "0 C".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-host-temp.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-temp)

# make_zone <root> <index> <type> <temp|none>
# A "none" temp leaves the zone without its temp file, modelling an unreadable
# sensor while keeping the type readable.
make_zone() {
  local root=$1 index=$2 type=$3 temp=$4
  mkdir -p "$root/thermal_zone$index"
  printf '%s\n' "$type" > "$root/thermal_zone$index/type"
  if [ "$temp" != none ]; then
    printf '%s\n' "$temp" > "$root/thermal_zone$index/temp"
  fi
}

# run_temp <root>: prints the script's stdout; caller reads $? for the code.
run_temp() {
  FM_THERMAL_SYSFS="$1" "$BIN"
}

test_prefers_x86_pkg_temp_over_a_hotter_sibling() {
  local root out status
  root="$TMP_ROOT/prefer"
  make_zone "$root" 0 acpitz 71000
  make_zone "$root" 1 x86_pkg_temp 58000
  out=$(run_temp "$root")
  status=$?
  expect_code 0 "$status" "a readable sensor should exit 0"
  assert_equals 58 "$out" "the x86_pkg_temp zone must win over a hotter sibling"
  pass "x86_pkg_temp is preferred and reported in whole degrees Celsius"
}

test_falls_back_to_the_hottest_readable_zone() {
  local root out status
  root="$TMP_ROOT/max"
  make_zone "$root" 0 pch_skylake 61000
  make_zone "$root" 1 acpitz 77000
  out=$(run_temp "$root")
  status=$?
  expect_code 0 "$status" "a readable non-x86 sensor should exit 0"
  assert_equals 77 "$out" "with no x86 zone the hottest readable zone must be used"
  pass "without an x86 zone the hottest readable zone is reported"
}

test_ignores_an_unreadable_preferred_zone_and_uses_the_max() {
  local root out status
  root="$TMP_ROOT/unreadable-preferred"
  make_zone "$root" 0 x86_pkg_temp none
  make_zone "$root" 1 acpitz 64000
  out=$(run_temp "$root")
  status=$?
  expect_code 0 "$status" "an unreadable x86 zone must not mask a readable sibling"
  assert_equals 64 "$out" "the readable maximum must be used when x86 is unreadable"
  pass "an unreadable x86_pkg_temp zone falls back to the readable maximum"
}

test_no_readable_sensor_prints_nothing_and_exits_3() {
  local root out status
  root="$TMP_ROOT/none"
  mkdir -p "$root/thermal_zone0"
  printf '%s\n' acpitz > "$root/thermal_zone0/type"
  out=$(run_temp "$root")
  status=$?
  expect_code 3 "$status" "a host with no readable sensor must exit 3"
  assert_equals "" "$out" "a host with no readable sensor must print nothing"
  pass "no readable sensor prints nothing and exits 3"
}

test_non_numeric_temp_is_not_a_readable_sensor() {
  local root out status
  root="$TMP_ROOT/non-numeric"
  mkdir -p "$root/thermal_zone0"
  printf '%s\n' acpitz > "$root/thermal_zone0/type"
  printf '%s\n' disabled > "$root/thermal_zone0/temp"
  out=$(run_temp "$root")
  status=$?
  expect_code 3 "$status" "a non-numeric temp must be treated as unreadable"
  assert_equals "" "$out" "a non-numeric temp must print nothing"
  pass "a non-numeric sensor value is treated as unreadable"
}

test_help() {
  local out status
  out=$("$BIN" --help)
  status=$?
  expect_code 0 "$status" "--help should exit 0"
  assert_contains "$out" "FM_THERMAL_SYSFS" "--help should document the override"
  pass "--help documents the sensor override"
}

test_prefers_x86_pkg_temp_over_a_hotter_sibling
test_falls_back_to_the_hottest_readable_zone
test_ignores_an_unreadable_preferred_zone_and_uses_the_max
test_no_readable_sensor_prints_nothing_and_exits_3
test_non_numeric_temp_is_not_a_readable_sensor
test_help
