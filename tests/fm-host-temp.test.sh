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
  local hwmon=${2:-$TMP_ROOT/empty-hwmon}
  mkdir -p "$hwmon"
  FM_THERMAL_SYSFS="$1" FM_HWMON_SYSFS="$hwmon" "$BIN"
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

make_hwmon() {
  local root=$1 index=$2 name=$3
  mkdir -p "$root/hwmon$index"
  printf '%s\n' "$name" > "$root/hwmon$index/name"
  shift 3
  while [ $# -ge 3 ]; do
    local n=$1 label=$2 millideg=$3
    printf '%s\n' "$millideg" > "$root/hwmon$index/temp${n}_input"
    if [ "$label" != "-" ]; then
      printf '%s\n' "$label" > "$root/hwmon$index/temp${n}_label"
    fi
    shift 3
  done
}

test_thermal_zone_wins_over_hwmon() {
  local root out status
  root="$TMP_ROOT/thermal-wins"
  make_zone "$root" 0 x86_pkg_temp 58000
  make_hwmon "$root" 0 k10temp 1 Tctl 90000
  out=$(run_temp "$root")
  status=$?
  expect_code 0 "$status" "thermal zone should win over hwmon"
  assert_equals 58 "$out" "thermal zone should win over hwmon"
  pass "thermal zone wins over hwmon when both are readable"
}

test_k10temp_prefers_tctl() {
  local root out status
  root="$TMP_ROOT/k10temp-tctl"
  mkdir -p "$root/thermal_zone0"  # empty thermal root
  make_hwmon "$root" 0 k10temp 1 Tctl 82000 3 Tccd1 91000
  out=$(run_temp "$root" "$root")
  status=$?
  expect_code 0 "$status" "k10temp should prefer Tctl"
  assert_equals 82 "$out" "k10temp should prefer Tctl"
  pass "k10temp prefers Tctl over other temps"
}

test_coretemp_prefers_package_id() {
  local root out status
  root="$TMP_ROOT/coretemp-package"
  make_hwmon "$root" 0 coretemp 1 "Package id 0" 67000 2 "Core 0" 70000
  out=$(run_temp "$root" "$root")
  status=$?
  expect_code 0 "$status" "coretemp should prefer Package id"
  assert_equals 67 "$out" "coretemp should prefer Package id"
  pass "coretemp prefers Package id over other temps"
}

test_only_non_cpu_hwmon_exits_3() {
  local root out status
  root="$TMP_ROOT/non-cpu-hwmon"
  make_hwmon "$root" 0 nvme 1 Composite 45000
  make_hwmon "$root" 1 amdgpu 1 edge 50000
  out=$(run_temp "$root" "$root")
  status=$?
  expect_code 3 "$status" "non-CPU hwmon should exit 3"
  assert_equals "" "$out" "non-CPU hwmon should print nothing"
  pass "non-CPU hwmon prints nothing and exits 3"
}

test_hwmon_non_numeric_input_is_skipped() {
  local root out status
  root="$TMP_ROOT/hwmon-non-numeric"
  make_hwmon "$root" 0 k10temp 1 Tctl "n/a" 2 Tdie 61000
  out=$(run_temp "$root" "$root")
  status=$?
  expect_code 0 "$status" "numeric input should be used"
  assert_equals 61 "$out" "numeric input should be used"
  pass "non-numeric hwmon inputs are skipped"

  root="$TMP_ROOT/hwmon-only-non-numeric"
  make_hwmon "$root" 0 k10temp 1 Tctl "n/a"
  out=$(run_temp "$root" "$root")
  status=$?
  expect_code 3 "$status" "only non-numeric input should exit 3"
  assert_equals "" "$out" "only non-numeric input should print nothing"
  pass "only non-numeric hwmon inputs print nothing and exit 3"
}

test_k10temp_falls_back_to_hottest_without_tctl_or_tdie() {
  local root out status
  root="$TMP_ROOT/k10temp-hottest"
  make_hwmon "$root" 0 k10temp 1 Tccd1 70000 2 Tccd2 74000
  out=$(run_temp "$root" "$root")
  status=$?
  expect_code 0 "$status" "k10temp should fall back to hottest"
  assert_equals 74 "$out" "k10temp should fall back to hottest"
  pass "k10temp falls back to hottest without Tctl or Tdie"
}

test_k10temp_tctl_beats_tdie_regardless_of_order() {
  local root out status
  root="$TMP_ROOT/k10temp-order"
  make_hwmon "$root" 0 k10temp 1 Tdie 60000 2 Tctl 82000 3 Tccd1 91000
  out=$(run_temp "$TMP_ROOT/nonexistent" "$root")
  status=$?
  expect_code 0 "$status" "k10temp with Tdie and Tctl should exit 0"
  assert_equals 82 "$out" "Tctl must win over Tdie and a hotter Tccd1 regardless of order"
  pass "k10temp prefers Tctl over Tdie regardless of file order"
}

test_help() {
  local out status
  out=$("$BIN" --help)
  status=$?
  expect_code 0 "$status" "--help should exit 0"
  assert_contains "$out" "FM_THERMAL_SYSFS" "--help should document the override"
  assert_contains "$out" "FM_HWMON_SYSFS" "--help should document hwmon override"
  pass "--help documents the sensor overrides"
}

test_prefers_x86_pkg_temp_over_a_hotter_sibling
test_falls_back_to_the_hottest_readable_zone
test_ignores_an_unreadable_preferred_zone_and_uses_the_max
test_no_readable_sensor_prints_nothing_and_exits_3
test_non_numeric_temp_is_not_a_readable_sensor
test_thermal_zone_wins_over_hwmon
test_k10temp_prefers_tctl
test_coretemp_prefers_package_id
test_only_non_cpu_hwmon_exits_3
test_hwmon_non_numeric_input_is_skipped
test_k10temp_falls_back_to_hottest_without_tctl_or_tdie
test_k10temp_tctl_beats_tdie_regardless_of_order
test_help
