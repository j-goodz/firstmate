#!/usr/bin/env bash
set -u
export LC_ALL=C

# fm-refill.sh — refill free worker slots from the nexus ready list
# Usage:
#   fm-refill.sh [run] [--slots N] [--projects a,b,c] [--limit N] [--ready-file FILE] [--dry-run]
#   fm-refill.sh select [--projects a,b,c] [--ready-file FILE]
#   fm-refill.sh count  [--projects a,b,c] [--ready-file FILE]
#   fm-refill.sh --help|-h
#
# Environment (all optional):
#   FM_REFILL_READY_CMD        default: nexus task list --status open --ready --mode auto --json
#   FM_REFILL_READY_TIMEOUT    default: 25
#   FM_REFILL_LOG              default: $HOME/.nexus/refill.jsonl
#   FM_REFILL_NEXUS_BIN        default: nexus
#   FM_REFILL_TASKS_BIN        default: $SCRIPT_DIR/fm-tasks-axi.sh
#   FM_REFILL_BRIEF_BIN        default: $SCRIPT_DIR/fm-brief.sh
#   FM_REFILL_SPAWN_BIN        default: $SCRIPT_DIR/fm-spawn.sh
#   FM_REFILL_RESOLVE_BIN      default: $SCRIPT_DIR/fm-dispatch-resolve.sh
#   FM_REFILL_PROJECTS_FILE    default: $FM_HOME/data/projects.md
#   FM_REFILL_DEFAULT_CAP      default: 3
#   FM_REFILL_HARNESS          default: claude
#   FM_REFILL_MODEL            default: sonnet
#   FM_REFILL_EFFORT           default: medium

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-timeout-lib.sh
source "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-thermal-lib.sh
source "$SCRIPT_DIR/fm-thermal-lib.sh"
# shellcheck source=bin/fm-refill-lib.sh
source "$SCRIPT_DIR/fm-refill-lib.sh"
# shellcheck source=bin/fm-refill-dispatch-lib.sh
source "$SCRIPT_DIR/fm-refill-dispatch-lib.sh"

usage() {
    cat <<'EOF'
fm-refill.sh — refill free worker slots from the nexus ready list

Usage:
  fm-refill.sh [run] [--slots N] [--projects a,b,c] [--limit N] [--ready-file FILE] [--dry-run]
  fm-refill.sh select [--projects a,b,c] [--ready-file FILE]
  fm-refill.sh count  [--projects a,b,c] [--ready-file FILE]
  fm-refill.sh --help|-h

Commands:
  run      (default) pull ready tasks into free slots
  select   print kept task ids, one per line
  count    print count and up to three ids

Options:
  --slots N          number of free slots (run only; default: thermal cap - busy)
  --projects a,b,c   comma-separated project names (default: from registry)
  --limit N          max tasks to dispatch (run only)
  --ready-file FILE  read ready list from file instead of running command
  --dry-run          print what would be dispatched without doing it (run only)
  -h, --help         show this help
EOF
}

# Globals set before calling any lib function
REFILL_LOG="${FM_REFILL_LOG:-$HOME/.nexus/refill.jsonl}"
PROJECTS_FILE="${FM_REFILL_PROJECTS_FILE:-$FM_HOME/data/projects.md}"
READY_CMD="${FM_REFILL_READY_CMD:-nexus task list --status open --ready --mode auto --json}"
READY_TIMEOUT="${FM_REFILL_READY_TIMEOUT:-25}"
NEXUS_BIN="${FM_REFILL_NEXUS_BIN:-nexus}"
TASKS_BIN="${FM_REFILL_TASKS_BIN:-$SCRIPT_DIR/fm-tasks-axi.sh}"
BRIEF_BIN="${FM_REFILL_BRIEF_BIN:-$SCRIPT_DIR/fm-brief.sh}"
SPAWN_BIN="${FM_REFILL_SPAWN_BIN:-$SCRIPT_DIR/fm-spawn.sh}"
RESOLVE_BIN="${FM_REFILL_RESOLVE_BIN:-$SCRIPT_DIR/fm-dispatch-resolve.sh}"
HARNESS="${FM_REFILL_HARNESS:-claude}"
MODEL="${FM_REFILL_MODEL:-sonnet}"
EFFORT="${FM_REFILL_EFFORT:-medium}"
DEFAULT_CAP="${FM_REFILL_DEFAULT_CAP:-3}"

DRY_RUN=0
SLOTS_N=0
READY_N=0

# Parse arguments
ACTION="run"
PROJECTS_SCOPE=""
LIMIT_N=""
READY_FILE=""
SLOTS_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        run|select|count)
            ACTION="$1"
            shift
            ;;
        --slots)
            [[ $# -ge 2 ]] || { echo "fm-refill: --slots requires a value" >&2; usage >&2; exit 2; }
            SLOTS_ARG="$2"
            shift 2
            ;;
        --projects)
            [[ $# -ge 2 ]] || { echo "fm-refill: --projects requires a value" >&2; usage >&2; exit 2; }
            PROJECTS_SCOPE="$2"
            shift 2
            ;;
        --limit)
            [[ $# -ge 2 ]] || { echo "fm-refill: --limit requires a value" >&2; usage >&2; exit 2; }
            LIMIT_N="$2"
            shift 2
            ;;
        --ready-file)
            [[ $# -ge 2 ]] || { echo "fm-refill: --ready-file requires a value" >&2; usage >&2; exit 2; }
            READY_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "fm-refill: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            echo "fm-refill: unknown action: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Resolve project scope
if [[ -n "$PROJECTS_SCOPE" ]]; then
    SCOPE_CSV="$PROJECTS_SCOPE"
else
    SCOPE_CSV="$(refill_registry_scope)"
fi

if [[ -z "$SCOPE_CSV" ]]; then
    case "$ACTION" in
        select)
            exit 0
            ;;
        count)
            echo 0
            exit 0
            ;;
        run)
            echo "fm-refill: no project scope (pass --projects or register projects in data/projects.md)" >&2
            exit 2
            ;;
    esac
fi

# Load ready list
READY_JSON=""
if [[ -n "$READY_FILE" ]]; then
    if ! READY_JSON="$(refill_load_ready "$READY_FILE")"; then
        case "$ACTION" in
            select) exit 0 ;;
            count) echo 0; exit 0 ;;
            run)
                refill_log "fill" "" "" "" "" "ready list unavailable"
                echo "fm-refill: ready list unavailable" >&2
                exit 1
                ;;
        esac
    fi
else
    if ! READY_JSON="$(refill_load_ready "")"; then
        case "$ACTION" in
            select) exit 0 ;;
            count) echo 0; exit 0 ;;
            run)
                refill_log "fill" "" "" "" "" "ready list unavailable"
                echo "fm-refill: ready list unavailable" >&2
                exit 1
                ;;
        esac
    fi
fi

# Filter the ready list
FILTERED_JSONL=""
if [[ -n "$READY_JSON" ]]; then
    FILTERED_JSONL="$(printf '%s' "$READY_JSON" | refill_filter "$SCOPE_CSV")"
fi

# Count kept tasks
KEPT_COUNT=0
KEPT_IDS=()
if [[ -n "$FILTERED_JSONL" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        KEPT_COUNT=$((KEPT_COUNT + 1))
        id="$(printf '%s' "$line" | jq -r '.id // empty')"
        [[ -n "$id" ]] && KEPT_IDS+=("$id")
    done <<< "$FILTERED_JSONL"
fi
READY_N=$KEPT_COUNT

case "$ACTION" in
    select)
        for id in "${KEPT_IDS[@]}"; do
            printf '%s\n' "$id"
        done
        exit 0
        ;;
    count)
        if [[ $KEPT_COUNT -eq 0 ]]; then
            echo 0
        else
            first_three=("${KEPT_IDS[@]:0:3}")
            joined="$(IFS=,; echo "${first_three[*]}")"
            echo "$KEPT_COUNT $joined"
        fi
        exit 0
        ;;
esac

# ACTION == run

# Validate --slots if given
if [[ -n "$SLOTS_ARG" ]]; then
    if [[ ! "$SLOTS_ARG" =~ ^[0-9]+$ ]]; then
        echo "fm-refill: --slots must be a whole number" >&2
        exit 2
    fi
    SLOTS_N="$SLOTS_ARG"
else
    # Compute free slots from thermal gate
    live="$(fm_thermal_gate_busy_count "$STATE" 2>/dev/null || echo 0)"
    [[ "$live" =~ ^[0-9]+$ ]] || live=0
    fm_thermal_gate_limit "$CONFIG/thermal-gate" "$SCRIPT_DIR/fm-host-temp.sh" >/dev/null 2>&1 || true
    cap="${FM_THERMAL_LIMIT:-$DEFAULT_CAP}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap="$DEFAULT_CAP"
    free=$((cap - live))
    [[ $free -lt 0 ]] && free=0
    SLOTS_N=$free
fi

# Determine target
target=$SLOTS_N
if [[ -n "$LIMIT_N" ]]; then
    if [[ ! "$LIMIT_N" =~ ^[0-9]+$ ]]; then
        echo "fm-refill: --limit must be a whole number" >&2
        exit 2
    fi
    [[ $LIMIT_N -lt $target ]] && target=$LIMIT_N
fi
[[ $KEPT_COUNT -lt $target ]] && target=$KEPT_COUNT

if [[ $target -eq 0 ]]; then
    reason="no free slots"
    [[ $SLOTS_N -gt 0 ]] && reason="no ready work"
    refill_log "fill" "" "" "" "0" "$reason"
    echo "fm-refill: nothing to fill ($reason)"
    exit 0
fi

# Dispatch tasks
filled=0
idx=0
while [[ $filled -lt $target && $idx -lt $KEPT_COUNT ]]; do
    line="$(printf '%s' "$FILTERED_JSONL" | sed -n "$((idx + 1))p")"
    idx=$((idx + 1))
    [[ -n "$line" ]] || continue

    id="$(printf '%s' "$line" | jq -r '.id // empty')"
    title="$(printf '%s' "$line" | jq -r '.title // empty')"
    project="$(printf '%s' "$line" | jq -r '.project // empty')"
    body="$(printf '%s' "$line" | jq -r '.body // empty')"

    if [[ $DRY_RUN -eq 1 ]]; then
        printf 'would dispatch %s %s %s\n' "$id" "$project" "$title"
        refill_log "would_dispatch" "$id" "$project" "" "" "dry run"
        filled=$((filled + 1))
        continue
    fi

    if refill_dispatch_one "$line"; then
        filled=$((filled + 1))
    fi
done

# Final fill log
reason="ok"
[[ $filled -lt $target ]] && reason="partial"
refill_log "fill" "" "" "" "$filled" "$reason"
echo "fm-refill: filled $filled of $SLOTS_N free slots ($KEPT_COUNT ready)"
exit 0