#!/usr/bin/env bash
# fm-thermal-lib.sh – Thermal‑gate helper functions
# This library is sourced by other scripts; it defines functions that
# extract configuration values, count busy workers, and compute the
# thermal‑gate limit.  No code is executed at source time.

# --------------------------------------------------------------------
# fm_thermal_gate_value <file> <key>
#   Return the trimmed value of the last “key = value” line in <file>.
#   If the file or key does not exist, the function prints nothing.
# --------------------------------------------------------------------
fm_thermal_gate_value() {
    local file=$1 key=$2 line
    [ -f "$file" ] || return 0
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | tail -n1) || return 0
    [ -n "$line" ] || return 0
    line=${line#*=}
    printf '%s' "$line" | tr -d '[:space:]'
}

# --------------------------------------------------------------------
# fm_thermal_gate_int <file> <key>
#   Return a non‑negative integer value for the given key, or nothing.
# --------------------------------------------------------------------
fm_thermal_gate_int() {
    local value
    value=$(fm_thermal_gate_value "$1" "$2")
    case "$value" in
        ''|*[!0-9]*) return 0 ;;
    esac
    printf '%s' "$value"
}

# --------------------------------------------------------------------
# fm_thermal_gate_busy_count <state-dir>
#   Count the number of non‑secondmate workers whose classification
#   verdict starts with “busy”.  The function sources fm-busy-lib.sh
#   if fm_busy_classify_meta is not already defined.
# --------------------------------------------------------------------
fm_thermal_gate_busy_count() {
    local state_dir=$1 busy=0 meta id kind verdict

    # Load the backend helper if needed.
    if ! declare -F fm_backend_of_meta >/dev/null; then
        # shellcheck source=./fm-backend.sh
        . "$(dirname "${BASH_SOURCE[0]}")/fm-backend.sh"
    fi

    # Load the busy‑classification helper if needed.
    if ! declare -F fm_busy_classify_meta >/dev/null; then
        # shellcheck source=./fm-busy-lib.sh
        . "$(dirname "${BASH_SOURCE[0]}")/fm-busy-lib.sh"
    fi

    for meta in "$state_dir"/*.meta; do
        [ -f "$meta" ] || continue
        kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
        [ "$kind" != secondmate ] || continue
        id=$(basename "$meta" .meta)

        # Classification may fail; ignore errors.
        verdict=$(fm_busy_classify_meta "$meta" "$id" "$state_dir" 2>/dev/null || true)
        [ "${verdict%% *}" = busy ] || continue
        busy=$((busy + 1))
    done

    printf '%s' "$busy"
}

# --------------------------------------------------------------------
# fm_thermal_gate_limit <gate-file> <host-temp-bin>
#   Compute the thermal‑gate limit and expose the following globals:
#     FM_THERMAL_LIMIT      – integer limit or empty
#     FM_THERMAL_TIER       – hold | hot | cool | fallback | none
#     FM_THERMAL_TEMP_DESC  – “<temp>C”, “unreadable”, or empty
#     FM_THERMAL_TEMP       – integer temperature or empty
#   The function never exits the shell; it only returns 0.
# --------------------------------------------------------------------
# shellcheck disable=SC2034  # FM_THERMAL_LIMIT, FM_THERMAL_TIER, FM_THERMAL_TEMP_DESC and FM_THERMAL_TEMP are outputs read by the sourcing script
fm_thermal_gate_limit() {
    local gate_file=$1 host_temp_bin=$2
    local max_workers hot_c hold_c temp temp_rc limit tier temp_desc

    # Initialise globals to empty values.
    FM_THERMAL_LIMIT=
    FM_THERMAL_TIER=none
    FM_THERMAL_TEMP_DESC=
    FM_THERMAL_TEMP=

    # Missing gate file → tier none, nothing else to do.
    [ -f "$gate_file" ] || return 0

    max_workers=$(fm_thermal_gate_int "$gate_file" max_workers)
    hot_c=$(fm_thermal_gate_int "$gate_file" hot_c)
    hold_c=$(fm_thermal_gate_int "$gate_file" hold_c)

    # Obtain host temperature.
    temp_rc=0
    temp=$("$host_temp_bin" 2>/dev/null) || temp_rc=$?
    if [ "$temp_rc" -eq 0 ] && [ -n "$temp" ]; then
        FM_THERMAL_TEMP=$temp
        temp_desc="${temp}C"

        if [ -n "$hold_c" ] && [ "$temp" -ge "$hold_c" ]; then
            limit=0
            tier=hold
        elif [ -n "$hot_c" ] && [ "$temp" -ge "$hot_c" ]; then
            limit=1
            tier=hot
        elif [ -n "$max_workers" ]; then
            limit=$max_workers
            tier=cool
        else
            limit=
            tier=none
        fi
    else
        # Unreadable temperature.
        if [ -z "$max_workers" ]; then
            limit=
            tier=none
        else
            limit=$max_workers
            tier=fallback
        fi
        temp_desc=unreadable
    fi

    FM_THERMAL_LIMIT=$limit
    FM_THERMAL_TIER=$tier
    FM_THERMAL_TEMP_DESC=$temp_desc
    return 0
}
