#!/usr/bin/env bash
# fm-vps-guard-lib.sh
#
# Light‑work‑only machines such as the VPS cloud‑server (8 GB RAM) must not run
# build or test work.  The host identity seam is FM_SELF_HOST; the list of
# light‑only hosts is FM_LIGHT_ONLY_HOSTS; the override token is
# FM_VPS_HEAVY_OK.  This library is sourced by other scripts and does not
# execute any code at source time.  All diagnostics are written to stderr.

# Print the current host name.  If FM_SELF_HOST is set and non‑empty, use that;
# otherwise fall back to the system hostname.
fm_vps_self_host() {
    local host
    if [[ -n "${FM_SELF_HOST:-}" ]]; then
        host="${FM_SELF_HOST}"
    else
        host="$(hostname -s 2>/dev/null || hostname)"
    fi
    printf '%s' "$host"
}

# Return 0 if the current host is one of the light‑only hosts.
# FM_LIGHT_ONLY_HOSTS is a space‑separated list; defaults to "cloud-server".
fm_vps_is_light_only_host() {
    local host
    host="$(fm_vps_self_host)"
    local light_hosts
    light_hosts="${FM_LIGHT_ONLY_HOSTS:-cloud-server}"
    for h in $light_hosts; do
        if [[ "$host" == "$h" ]]; then
            return 0
        fi
    done
    return 1
}

# Return 0 (allowed) unless the kind is exactly "ship", the host is light‑only,
# and FM_VPS_HEAVY_OK is not exactly "OPERATOR_APPROVED".
# In the refused case, print diagnostics to stderr and return 1.
fm_vps_heavy_refusal() {
    local kind="$1"
    local host
    host="$(fm_vps_self_host)"
    if [[ "$kind" != "ship" ]]; then
        return 0
    fi
    if ! fm_vps_is_light_only_host; then
        return 0
    fi
    if [[ "${FM_VPS_HEAVY_OK:-}" == "OPERATOR_APPROVED" ]]; then
        return 0
    fi

    printf 'error: spawn refused - %s is a light-work-only machine (8 GB RAM, live services), and ship (build or test) work belongs on swift.\n' "$host" >&2
    # shellcheck disable=SC2016 # the backticks are literal text in the message
    printf 'Place it on swift: run `bin/fm-place.sh --class heavy` (it names the machine and the second mate home), then route the lane there.\n' >&2
    printf 'Only the operator may override on this machine: FM_VPS_HEAVY_OK=OPERATOR_APPROVED bin/fm-spawn.sh ...\n' >&2
    return 1
}

# Print the fan‑out workers cap for light‑only hosts.
# If the host is light‑only, print "2"; otherwise print nothing.
# Always return 0.
fm_vps_fanout_workers_cap() {
    if fm_vps_is_light_only_host; then
        printf '2'
    fi
    return 0
}