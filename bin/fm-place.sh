#!/usr/bin/env bash
#
# fm-place.sh - choose the machine for new work from live load per core and temperature
#
# Purpose: before routing a lane, firstmate asks which machine should take it. The script probes this machine and every machine that hosts a registered secondmate, computes load per logical CPU, reads temperature and suite-slot headroom, and prints a ranked verdict. It only reports: it never starts, moves or stops anything.
#
# Command line
#
#     fm-place.sh [--class heavy|light] [--json] [--registry FILE] [--self NAME] [--probe-timeout SECS]
#     fm-place.sh --help | -h
#
# Options
#
#   --class heavy|light
#       heavy (default) = work that runs a full test suite or a build; light = investigation, docs, small direct-PR work. Anything else: exit 2.
#   --registry FILE
#       secondmate registry. Default ${FM_HOME:-<parent directory of this script's bin dir>}/data/secondmates.md. A missing file is not an error (only the local machine is considered).
#   --self NAME
#       name of the local machine. Default hostname -s.
#   --probe-timeout SECS
#       per-machine probe limit, default 8 (wrap the probe in timeout).
#   --json
#       output JSON instead of text lines.
#   --help, -h
#       print this help and exit 0.
#
# Environment
#
#   FM_HOME
#       default: parent directory of this script's bin dir.
#   FM_SUITE_STATE_DIR
#       default: ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/suite, used for the placement log and scratch.
#   FM_PLACE_SSH
#       default: ssh.
#   FM_PLACE_LOCAL_OUTPUT
#       test seam: path to a file holding the local machine's probe output; when set, the local probe is read from that file instead of being executed.
#   FM_PLACE_MAX_LOAD_PER_CORE
#       default 1.0.
#   FM_PLACE_BUSY_LOAD_PER_CORE
#       default 0.75.
#   FM_PLACE_MIN_AVAILABLE_MB
#       default 600.
#
# Machines
#
#   The registry is a markdown list. A registered secondmate is a line that starts with "- <name> - " (the name is the text between "- " and the next " - ") and carries a parenthesised group containing host: <host>; root: <path>; home: <path>; fields separated by semicolons (extra fields such as scope: and projects: may follow, in any order, so extract each field independently with the pattern <field>: ([^;)]*)). Lines without a host: field are ignored. When two lines name the same host the first one wins.
#   Machine list, in this order: the registered hosts in registry order, then the local machine. A registered host equal to the local machine name (--self) is the local machine: it is probed locally and appears once, in its registry position, carrying that mate name. The local machine, when it has no registry line, has mate name self, root = the parent directory of this script's bin dir, home = ${FM_HOME:-root}.
#
# Probe
#
#   For each machine run this POSIX sh probe script (give it on stdin; pass the machine's root and home as the two positional arguments) and collect name=value lines. Remote machines: timeout SECS $FM_PLACE_SSH -o BatchMode=yes -o ConnectTimeout=5 <host> sh -s -- <root> <home>. The local machine: timeout SECS sh -s -- <root> <home> (or the FM_PLACE_LOCAL_OUTPUT file). All probes run concurrently (background jobs, one temp file per machine inside a mktemp -d directory under the state dir, removed on exit) and are then read.
#
#   The probe script prints: cores=<logical cpu count from nproc, falling back to getconf _NPROCESSORS_ONLN>, load1=<first field of /proc/loadavg>, and, when <root>/bin/fm-suite-slot.sh is executable, the key=value fields of the first line of FM_HOME=<home> <root>/bin/fm-suite-slot.sh status (that line has the form capacity=2 base=2 temp=55 tier=cool held=0 free=2 avail_mb=3100; print each field on its own line). When the slot script is absent it prints temp=<output of <root>/bin/fm-host-temp.sh> if that script is executable and succeeds.
#   A machine is unreachable when its probe command fails (non-zero exit, timeout) or its output has no cores= line.
#
# Verdict per machine
#
#   Let LPC = load1 / cores (floating point, awk). Limits: MAX = FM_PLACE_MAX_LOAD_PER_CORE, BUSY = FM_PLACE_BUSY_LOAD_PER_CORE. A machine whose probed base is 0 is a light-work-only machine: for it MAX and BUSY are halved.
#   Fields from the probe: avail_mb (blank or unknown = unknown; memory floor MINMEM = FM_PLACE_MIN_AVAILABLE_MB, default 600), base (blank when the slot script was absent: "slots unknown"), capacity, held, free, tier (cool|hot|hold|unknown, treat missing as unknown), temp (blank = unknown).
#   Class heavy, first matching rule wins:
#   1. unreachable -> verdict no, reason unreachable
#   2. tier hold -> no, heat-hold
#   3. base blank -> no, slots-unknown
#   4. base 0 -> no, no-suite-slots
#   5. tier hot -> no, heat-hot
#   6. LPC >= MAX -> no, load-limit
#   6b. avail_mb known and below MINMEM -> no, memory-pressure
#   7. free is 0 (or capacity is 0) -> busy, no-free-slot
#   8. LPC >= BUSY -> busy, load-busy
#   9. otherwise ok, reason ok
#   Class light, first matching rule wins: unreachable -> no/unreachable; tier hold -> no/heat-hold; LPC >= MAX -> no/load-limit; avail_mb known and below MINMEM -> no/memory-pressure; LPC >= BUSY -> busy/load-busy; otherwise ok/ok. (Slots and a hot tier do not matter for light work.)
#
# Choice and ranking
#
#   Rank machines: verdict ok first, then busy, then no; inside a verdict by LPC rounded down to one decimal ascending (compare as integers floor(LPC*10)); ties keep list order (registered hosts first in registry order, local machine last). The chosen machine is the first ranked machine with verdict ok; if none is ok, the first with verdict busy; if none, no placement.
#
# Output (stdout)
#
#   First line: PLACE <machine> mate=<name> verdict=<ok|busy> class=<class> or, when nothing qualifies, PLACE none class=<class> reason=<comma separated reasons of the machines>.
#   Then one line per machine in ranked order:
#
#       machine=<m> mate=<name> verdict=<v> reason=<r> load_per_core=<x.xx> cores=<n> load1=<x> temp=<t or unknown> tier=<tier> slots_free=<n or unknown> slots_cap=<n or unknown> avail_mb=<n or unknown> home=<path> root=<path>
#
#   For an unreachable machine the numeric fields print unknown. load_per_core has two decimals.
#   Exit 0 when a machine was chosen (including a busy one), exit 1 when PLACE none.
#
# --json prints one JSON object (build with jq -n) instead of the text lines: {"class":"heavy","place":{"machine":"swift","mate":"swiftmate","verdict":"ok","home":"/path"} or null,"machines":[{"machine":..,"mate":..,"verdict":..,"reason":..,"load_per_core":0.31,"cores":8,"load1":2.5,"temp":61 or null,"tier":"cool","slots_free":1 or null,"slots_cap":1 or null,"avail_mb":3100 or null,"home":"..","root":".."}]}.
#
# Placement log
#
#   Best effort (never changes output or exit code): append one JSON line to $FM_SUITE_STATE_DIR/placements.jsonl with ts (UTC ISO-8601), host (hostname -s), class, chosen (machine name or null), verdict, and machines (array of {machine, verdict, reason, load_per_core}).
#
# Exit codes
#
#   0: a machine was chosen (ok or busy)
#   1: no machine chosen
#   2: invalid option or class
#
# Diagnostics
#
#   All diagnostics go to stderr, prefixed with the script name and a colon, e.g. fm-place: ...
#
# Usage helper
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

set -u

# Default values
class="heavy"
json=0
registry_file=""
self_name=""
probe_timeout=8

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --class)
            shift
            if [[ $# -eq 0 ]]; then
                echo "fm-place: missing argument for --class" >&2
                exit 2
            fi
            class="$1"
            ;;
        --json)
            json=1
            ;;
        --registry)
            shift
            if [[ $# -eq 0 ]]; then
                echo "fm-place: missing argument for --registry" >&2
                exit 2
            fi
            registry_file="$1"
            ;;
        --self)
            shift
            if [[ $# -eq 0 ]]; then
                echo "fm-place: missing argument for --self" >&2
                exit 2
            fi
            self_name="$1"
            ;;
        --probe-timeout)
            shift
            if [[ $# -eq 0 ]]; then
                echo "fm-place: missing argument for --probe-timeout" >&2
                exit 2
            fi
            probe_timeout="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "fm-place: unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

# Validate class
if [[ "$class" != heavy && "$class" != light ]]; then
    echo "fm-place: invalid class: $class" >&2
    exit 2
fi

# Resolve defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FM_HOME="${FM_HOME:-$ROOT_DIR}"
FM_SUITE_STATE_DIR="${FM_SUITE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/suite}"
FM_PLACE_SSH="${FM_PLACE_SSH:-ssh}"
FM_PLACE_MAX_LOAD_PER_CORE="${FM_PLACE_MAX_LOAD_PER_CORE:-1.0}"
FM_PLACE_BUSY_LOAD_PER_CORE="${FM_PLACE_BUSY_LOAD_PER_CORE:-0.75}"
FM_PLACE_MIN_AVAILABLE_MB="${FM_PLACE_MIN_AVAILABLE_MB:-600}"
if [[ -z "$self_name" ]]; then
    self_name="$(hostname -s)"
fi
if [[ -z "$registry_file" ]]; then
    registry_file="$FM_HOME/data/secondmates.md"
fi


mkdir -p "$FM_SUITE_STATE_DIR" 2>/dev/null
work=$(mktemp -d "$FM_SUITE_STATE_DIR/place.XXXXXX") || {
    echo "fm-place: cannot create a scratch directory under $FM_SUITE_STATE_DIR" >&2
    exit 2
}
trap 'rm -rf "$work"' EXIT

# Machine list, parallel indexed arrays: registered hosts in registry order,
# then the local machine.
m_name=()
m_mate=()
m_root=()
m_home=()
m_local=()

registry_field() {  # <line> <field>
    printf '%s\n' "$1" | sed -nE "s/.*[(;] *$2: *([^;)]*).*/\\1/p" | head -n1 | sed 's/[[:space:]]*$//'
}

have_host() {  # <host>
    local h
    for h in "${m_name[@]+"${m_name[@]}"}"; do
        [[ "$h" == "$1" ]] && return 0
    done
    return 1
}

if [[ -f "$registry_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "- "* ]] || continue
        mate_name="${line#- }"
        mate_name="${mate_name%% - *}"
        host="$(registry_field "$line" host)"
        [[ -n "$host" ]] || continue
        have_host "$host" && continue
        m_name+=("$host")
        m_mate+=("$mate_name")
        m_root+=("$(registry_field "$line" root)")
        m_home+=("$(registry_field "$line" home)")
        if [[ "$host" == "$self_name" ]]; then m_local+=(1); else m_local+=(0); fi
    done < "$registry_file"
fi

if ! have_host "$self_name"; then
    m_name+=("$self_name")
    m_mate+=("self")
    m_root+=("$ROOT_DIR")
    m_home+=("$FM_HOME")
    m_local+=(1)
fi

# The probe is POSIX sh: it runs under dash on remote hosts.
cat > "$work/probe.sh" <<'PROBE'
root="$1"
home="$2"
if command -v nproc >/dev/null 2>&1; then
    cores=$(nproc)
else
    cores=$(getconf _NPROCESSORS_ONLN)
fi
echo "cores=$cores"
echo "load1=$(cut -d' ' -f1 /proc/loadavg)"
if [ -x "$root/bin/fm-suite-slot.sh" ]; then
    FM_HOME="$home" "$root/bin/fm-suite-slot.sh" status 2>/dev/null | head -n1 | tr ' ' '\n'
elif [ -x "$root/bin/fm-host-temp.sh" ]; then
    temp_out=$("$root/bin/fm-host-temp.sh" 2>/dev/null) && [ -n "$temp_out" ] && echo "temp=$temp_out"
fi
exit 0
PROBE

for i in "${!m_name[@]}"; do
    out="$work/probe.$i"
    if [[ "${m_local[$i]}" == 1 && -n "${FM_PLACE_LOCAL_OUTPUT:-}" ]]; then
        ( cat "$FM_PLACE_LOCAL_OUTPUT" > "$out" 2>/dev/null; echo $? > "$out.rc" ) &
    elif [[ "${m_local[$i]}" == 1 ]]; then
        ( timeout "$probe_timeout" sh -s -- "${m_root[$i]}" "${m_home[$i]}" < "$work/probe.sh" > "$out" 2>/dev/null; echo $? > "$out.rc" ) &
    else
        ( timeout "$probe_timeout" "$FM_PLACE_SSH" -o BatchMode=yes -o ConnectTimeout=5 "${m_name[$i]}" sh -s -- "${m_root[$i]}" "${m_home[$i]}" < "$work/probe.sh" > "$out" 2>/dev/null; echo $? > "$out.rc" ) &
    fi
done
wait

ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }

# Per machine results, parallel to the machine arrays.
r_verdict=()
r_reason=()
r_lpc=()
r_cores=()
r_load1=()
r_temp=()
r_tier=()
r_free=()
r_cap=()
r_avail=()
rank_lines=()

for i in "${!m_name[@]}"; do
    cores="" load1="" temp="" capacity="" base="" tier="" free="" avail_mb=""
    rc=1
    [[ -f "$work/probe.$i.rc" ]] && rc="$(cat "$work/probe.$i.rc")"
    if [[ "$rc" == 0 ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            case "$key" in
                cores) cores="$val" ;;
                load1) load1="$val" ;;
                temp) temp="$val" ;;
                capacity) capacity="$val" ;;
                base) base="$val" ;;
                tier) tier="$val" ;;
                free) free="$val" ;;
                avail_mb) avail_mb="$val" ;;
            esac
        done < "$work/probe.$i"
    fi
    [[ "$temp" == unknown ]] && temp=""
    [[ "$avail_mb" == unknown ]] && avail_mb=""
    [[ -n "$tier" ]] || tier="unknown"

    verdict="" reason="" lpc="" max_load="$FM_PLACE_MAX_LOAD_PER_CORE" busy_load="$FM_PLACE_BUSY_LOAD_PER_CORE"
    if [[ "$rc" != 0 || -z "$cores" ]]; then
        verdict="no"
        reason="unreachable"
    else
        lpc="$(awk -v l="${load1:-0}" -v c="$cores" 'BEGIN { if (c > 0) printf "%.4f", l / c; else print "0" }')"
        if [[ "$base" == 0 ]]; then
            max_load="$(awk -v m="$max_load" 'BEGIN { print m / 2 }')"
            busy_load="$(awk -v m="$busy_load" 'BEGIN { print m / 2 }')"
        fi
        mem_short=0
        if [[ -n "$avail_mb" ]] && lt "$avail_mb" "$FM_PLACE_MIN_AVAILABLE_MB"; then mem_short=1; fi
        if [[ "$tier" == hold ]]; then
            verdict="no"; reason="heat-hold"
        elif [[ "$class" == heavy && -z "$base" ]]; then
            verdict="no"; reason="slots-unknown"
        elif [[ "$class" == heavy && "$base" == 0 ]]; then
            verdict="no"; reason="no-suite-slots"
        elif [[ "$class" == heavy && "$tier" == hot ]]; then
            verdict="no"; reason="heat-hot"
        elif ge "$lpc" "$max_load"; then
            verdict="no"; reason="load-limit"
        elif [[ "$mem_short" == 1 ]]; then
            verdict="no"; reason="memory-pressure"
        elif [[ "$class" == heavy && ( "$free" == 0 || "$capacity" == 0 ) ]]; then
            verdict="busy"; reason="no-free-slot"
        elif ge "$lpc" "$busy_load"; then
            verdict="busy"; reason="load-busy"
        else
            verdict="ok"; reason="ok"
        fi
    fi

    r_verdict+=("$verdict")
    r_reason+=("$reason")
    r_lpc+=("$lpc")
    r_cores+=("$cores")
    r_load1+=("$load1")
    r_temp+=("$temp")
    r_tier+=("$tier")
    r_free+=("$free")
    r_cap+=("$capacity")
    r_avail+=("$avail_mb")

    case "$verdict" in ok) rank=0 ;; busy) rank=1 ;; *) rank=2 ;; esac
    if [[ -n "$lpc" ]]; then
        lpc10="$(awk -v l="$lpc" 'BEGIN { printf "%d", l * 10 }')"
    else
        lpc10=9999
    fi
    rank_lines+=("$rank $lpc10 $i")
done

mapfile -t ranked < <(printf '%s\n' "${rank_lines[@]}" | LC_ALL=C sort -k1,1n -k2,2n -k3,3n | awk '{ print $3 }')

chosen=-1
for want in ok busy; do
    for i in "${ranked[@]}"; do
        if [[ "${r_verdict[$i]}" == "$want" ]]; then
            chosen="$i"
            break 2
        fi
    done
done

unk() { [[ -n "$1" ]] && printf '%s' "$1" || printf 'unknown'; }
lpc_text() { [[ -n "$1" ]] && printf '%.2f' "$1" || printf 'unknown'; }

# JSON object for one machine; every number is null when unknown.
machine_json() {  # <index>
    local i=$1
    jq -n \
        --arg machine "${m_name[$i]}" --arg mate "${m_mate[$i]}" \
        --arg verdict "${r_verdict[$i]}" --arg reason "${r_reason[$i]}" \
        --arg lpc "${r_lpc[$i]}" --arg cores "${r_cores[$i]}" --arg load1 "${r_load1[$i]}" \
        --arg temp "${r_temp[$i]}" --arg tier "${r_tier[$i]}" \
        --arg free "${r_free[$i]}" --arg cap "${r_cap[$i]}" --arg avail "${r_avail[$i]}" \
        --arg home "${m_home[$i]}" --arg root "${m_root[$i]}" \
        'def num: if . == "" then null else tonumber end;
         {machine: $machine, mate: $mate, verdict: $verdict, reason: $reason,
          load_per_core: ($lpc | num | if . == null then null else (. * 100 | round / 100) end),
          cores: ($cores | num), load1: ($load1 | num), temp: ($temp | num), tier: $tier,
          slots_free: ($free | num), slots_cap: ($cap | num), avail_mb: ($avail | num), home: $home, root: $root}'
}

machines_json="$(for i in "${ranked[@]}"; do machine_json "$i"; done | jq -s '.')"
if [[ "$chosen" -ge 0 ]]; then
    place_json="$(jq -n --arg machine "${m_name[$chosen]}" --arg mate "${m_mate[$chosen]}" \
        --arg verdict "${r_verdict[$chosen]}" --arg home "${m_home[$chosen]}" \
        '{machine: $machine, mate: $mate, verdict: $verdict, home: $home}')"
else
    place_json="null"
fi

if [[ "$json" -eq 1 ]]; then
    jq -n --arg class "$class" --argjson place "$place_json" --argjson machines "$machines_json" \
        '{class: $class, place: $place, machines: $machines}'
else
    if [[ "$chosen" -ge 0 ]]; then
        echo "PLACE ${m_name[$chosen]} mate=${m_mate[$chosen]} verdict=${r_verdict[$chosen]} class=$class"
    else
        reasons=""
        for i in "${ranked[@]}"; do
            reasons="${reasons:+$reasons,}${r_reason[$i]}"
        done
        echo "PLACE none class=$class reason=$reasons"
    fi
    for i in "${ranked[@]}"; do
        printf 'machine=%s mate=%s verdict=%s reason=%s load_per_core=%s cores=%s load1=%s temp=%s tier=%s slots_free=%s slots_cap=%s avail_mb=%s home=%s root=%s\n' \
            "${m_name[$i]}" "${m_mate[$i]}" "${r_verdict[$i]}" "${r_reason[$i]}" "$(lpc_text "${r_lpc[$i]}")" \
            "$(unk "${r_cores[$i]}")" "$(unk "${r_load1[$i]}")" "$(unk "${r_temp[$i]}")" "${r_tier[$i]}" \
            "$(unk "${r_free[$i]}")" "$(unk "${r_cap[$i]}")" "$(unk "${r_avail[$i]}")" "${m_home[$i]}" "${m_root[$i]}"
    done
fi

# Placement log, best effort: it never changes the output or the exit code.
{
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(hostname -s)" --arg class "$class" \
        --argjson place "$place_json" --argjson machines "$machines_json" \
        '{ts: $ts, host: $host, class: $class, chosen: ($place.machine? // null), verdict: ($place.verdict? // null),
          machines: [$machines[] | {machine, verdict, reason, load_per_core}]}' \
        >> "$FM_SUITE_STATE_DIR/placements.jsonl"
} 2>/dev/null || true

[[ "$chosen" -ge 0 ]] && exit 0
exit 1
