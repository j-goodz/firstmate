#!/usr/bin/env bash
# fm-backlog-overdue.sh - backlog overdue scanner and wake enqueuer
#
# Usage:
#   fm-backlog-overdue.sh [report]     Print overdue items (default)
#   fm-backlog-overdue.sh wake         Enqueue wake checks for newly overdue items
#   fm-backlog-overdue.sh arm          Register periodic wake check with fm-check-register.sh
#   fm-backlog-overdue.sh --help       Show this help
#
# What counts as overdue (see fm-backlog-overdue-lib.sh for the scan implementation):
#   Rows in ## In flight and ## Queued sections are checked. A row is overdue if:
#   1) it has (hold-until: D) and now >= D; 2) it has (due: D) and now >= D;
#   3) it is in ## Queued, has (since D), has no (hold and no blocked-by:, and age > QUEUED_HOURS;
#   4) it has a pacing hold (hold text contains "pacing" case-insensitive) with no hold-until.
#   The rule with the largest overdue_secs wins. Rows under ## Done are ignored.
#
# Once-per-item-per-day rule: wake enqueues at most one check per item per UTC day.
# A marker file $STATE/.backlog-overdue-woken tracks <id><TAB><YYYY-MM-DD>.
#
# Environment:
#   FM_HOME (default: repo root), FM_DATA_OVERRIDE, FM_STATE_OVERRIDE
#   FM_OVERDUE_NOW_EPOCH (default: date +%s), FM_OVERDUE_LIMIT (default: 10)
#   FM_OVERDUE_QUEUED_HOURS (default: 48), FM_OVERDUE_LOG (default: $STATE/backlog-overdue.jsonl)
#
# Exit codes: 0 success, 1 error (state dir, register, wake append), 2 bad usage/env.
# To retire the periodic check: bin/fm-check-unregister.sh backlog-overdue

set -u
export LC_ALL=C

# shellcheck source=bin/fm-backlog-overdue-lib.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backlog-overdue-lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

BACKLOG_FILE="$DATA/backlog.md"
NOW="${FM_OVERDUE_NOW_EPOCH:-$(date +%s)}"
LIMIT="${FM_OVERDUE_LIMIT:-10}"
QUEUED_HOURS="${FM_OVERDUE_QUEUED_HOURS:-48}"
LOG_FILE="${FM_OVERDUE_LOG:-$STATE/backlog-overdue.jsonl}"
MARKER_FILE="$STATE/.backlog-overdue-woken"

# Validate environment variables
validate_positive_int() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
        echo "fm-backlog-overdue: $name must be a positive integer" >&2
        exit 2
    fi
}

validate_nonneg_int() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "fm-backlog-overdue: $name must be a non-negative integer" >&2
        exit 2
    fi
}

validate_nonneg_int "FM_OVERDUE_NOW_EPOCH" "$NOW"
validate_positive_int "FM_OVERDUE_LIMIT" "$LIMIT"
validate_positive_int "FM_OVERDUE_QUEUED_HOURS" "$QUEUED_HOURS"

# Help handler
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    awk 'NR==1{next} /^#/ {sub(/^# ?/, "", $0); print} /^[^#]/ {exit}' "$0"
    exit 0
fi

SUBCMD="${1:-report}"

# Compute today's UTC date from epoch
TODAY="$(date -u -r "$NOW" +%F 2>/dev/null || date -u -d "@$NOW" +%F)"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Atomic marker file update
update_marker() {
    local id="$1" day="$2"
    local tmp
    tmp="$(mktemp "$STATE/.backlog-overdue-woken.XXXXXX")" || return 1
    # Filter out old entries for this id, then add new one
    if [[ -f "$MARKER_FILE" ]]; then
        awk -v id="$id" -F'\t' '$1 != id' "$MARKER_FILE" >"$tmp" 2>/dev/null || true
    fi
    printf '%s\t%s\n' "$id" "$day" >>"$tmp"
    mv -f "$tmp" "$MARKER_FILE"
}

# Remove marker for ids no longer overdue
prune_markers() {
    local overdue_ids="$1"
    local tmp
    tmp="$(mktemp "$STATE/.backlog-overdue-woken.XXXXXX")" || return 1
    if [[ -f "$MARKER_FILE" ]]; then
        awk -v ids="$overdue_ids" '
            BEGIN { split(ids, a, " "); for (i in a) keep[a[i]]=1 }
            $1 in keep
        ' "$MARKER_FILE" >"$tmp" 2>/dev/null || true
    fi
    mv -f "$tmp" "$MARKER_FILE"
}

# Get overdue list from library
get_overdue_list() {
    fm_overdue_scan "$BACKLOG_FILE" "$NOW" "$QUEUED_HOURS"
}

case "$SUBCMD" in
    report)
        # Get overdue items
        mapfile -t OVERDUE_LINES < <(get_overdue_list)
        TOTAL="${#OVERDUE_LINES[@]}"
        if [[ "$TOTAL" -eq 0 ]]; then
            exit 0
        fi

        # Print header
        printf 'OVERDUE (%d item(s) past a hold date, due date or the %dh queue limit, oldest first):\n' "$TOTAL" "$QUEUED_HOURS"

        # Print up to LIMIT items
        COUNT=0
        for line in "${OVERDUE_LINES[@]}"; do
            if [[ "$COUNT" -ge "$LIMIT" ]]; then
                break
            fi
            IFS=$'\t' read -r overdue_secs id dur reason title <<<"$line"
            fm_overdue_item_line "$id" "$title" "$dur" "$reason"
            ((COUNT++))
        done

        # Print +more if needed
        if [[ "$TOTAL" -gt "$LIMIT" ]]; then
            MORE=$((TOTAL - LIMIT))
            printf 'OVERDUE: +%d more\n' "$MORE"
        fi

        # Print action hint
        printf 'OVERDUE: act on each one: dispatch it, re-hold it with a new date (fm-captain-hold.sh hold <id> --reason <why> --until YYYY-MM-DD, or fm-tasks-axi.sh hold <id> --reason <why> --until YYYY-MM-DD), or close it with a reason.\n'
        ;;

    wake)
        # Source wake lib after exporting FM_STATE_OVERRIDE
        export FM_STATE_OVERRIDE="$STATE"
        # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
        source "$SCRIPT_DIR/fm-wake-lib.sh"

        # Get overdue items
        mapfile -t OVERDUE_LINES < <(get_overdue_list)
        TOTAL="${#OVERDUE_LINES[@]}"
        if [[ "$TOTAL" -eq 0 ]]; then
            exit 0
        fi

        # Build set of currently overdue ids for pruning
        OVERDUE_IDS=()
        for line in "${OVERDUE_LINES[@]}"; do
            IFS=$'\t' read -r _ id _ _ _ <<<"$line"
            OVERDUE_IDS+=("$id")
        done
        OVERDUE_IDS_STR="${OVERDUE_IDS[*]}"

        # Read marker file to find already woken today
        declare -A WOKE_TODAY
        if [[ -f "$MARKER_FILE" ]]; then
            while IFS=$'\t' read -r id day; do
                if [[ "$day" == "$TODAY" ]]; then
                    WOKE_TODAY["$id"]=1
                fi
            done <"$MARKER_FILE"
        fi

        # Filter out already woken, take first LIMIT
        WOKEN=0
        for line in "${OVERDUE_LINES[@]}"; do
            if [[ "$WOKEN" -ge "$LIMIT" ]]; then
                break
            fi
            IFS=$'\t' read -r overdue_secs id dur reason title <<<"$line"
            if [[ -n "${WOKE_TODAY[$id]:-}" ]]; then
                continue
            fi

            # Build item line for payload
            ITEM_LINE="$(fm_overdue_item_line "$id" "$title" "$dur" "$reason")"
            PAYLOAD="backlog-overdue: $ITEM_LINE; dispatch it, re-hold it with a new date, or close it with a reason"

            # Enqueue wake
            if ! fm_wake_append check "backlog-overdue:$id" "$PAYLOAD"; then
                echo "fm-backlog-overdue: failed to enqueue wake for $id" >&2
                exit 1
            fi

            # Mark as woken today
            update_marker "$id" "$TODAY"

            # Log JSON
            jq -n -c \
                --argjson ts "$NOW" \
                --arg day "$TODAY" \
                --arg id "$id" \
                --arg title "$title" \
                --arg reason "$reason" \
                --argjson overdue_secs "$overdue_secs" \
                --argjson woken true \
                '{ts:$ts, day:$day, id:$id, title:$title, reason:$reason, overdue_secs:$overdue_secs, woken:$woken}' \
                >>"$LOG_FILE"

            ((WOKEN++))
        done

        # Prune markers for ids no longer overdue
        prune_markers "$OVERDUE_IDS_STR"

        if [[ "$WOKEN" -gt 0 ]]; then
            printf 'backlog-overdue: %d item(s) overdue, woken\n' "$WOKEN"
        fi
        ;;

    arm)
        # Validate state directory
        if [[ ! -d "$STATE" ]] || [[ -L "$STATE" ]]; then
            echo "fm-backlog-overdue: state directory is unavailable" >&2
            exit 1
        fi

        SHIM_FILE="$STATE/backlog-overdue.check.sh"
        TRUST_FILE="$STATE/backlog-overdue.check-trust"

        # Build shim content
        SHIM_CONTENT="#!/usr/bin/env bash
# Auto-generated by fm-backlog-overdue.sh arm - overdue backlog poll shim.
export FM_HOME=$(printf '%q' "$FM_HOME")
export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")
export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")
exec $(printf '%q' "$SCRIPT_DIR/fm-backlog-overdue.sh") wake
"

        # Check if shim already exists and is identical with trust file
        if [[ -f "$SHIM_FILE" ]] && [[ -f "$TRUST_FILE" ]]; then
            if [[ "$(stat -c %a "$SHIM_FILE" 2>/dev/null || stat -f %A "$SHIM_FILE")" == "700" ]]; then
                if diff -q <(printf '%s' "$SHIM_CONTENT") "$SHIM_FILE" >/dev/null 2>&1; then
                    # Already up to date
                    :
                else
                    # Different content, need to update
                    UPDATE_SHIM=1
                fi
            else
                UPDATE_SHIM=1
            fi
        else
            UPDATE_SHIM=1
        fi

        if [[ -n "${UPDATE_SHIM:-}" ]]; then
            # Refuse if destination exists and is symlink or not regular file
            if [[ -e "$SHIM_FILE" ]] && [[ ! -f "$SHIM_FILE" ]]; then
                echo "fm-backlog-overdue: $SHIM_FILE exists and is not a regular file" >&2
                exit 1
            fi
            if [[ -L "$SHIM_FILE" ]]; then
                echo "fm-backlog-overdue: $SHIM_FILE is a symlink" >&2
                exit 1
            fi

            # Write atomically
            TMP_SHIM="$(mktemp "$STATE/backlog-overdue.check.sh.XXXXXX")" || exit 1
            printf '%s' "$SHIM_CONTENT" >"$TMP_SHIM"
            chmod 0700 "$TMP_SHIM"
            mv -f "$TMP_SHIM" "$SHIM_FILE"
            # Create trust file
            : >"$TRUST_FILE"
        fi

        # Register the check
        if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" backlog-overdue >/dev/null; then
            echo "fm-backlog-overdue: failed to register check" >&2
            exit 1
        fi
        ;;

    *)
        echo "fm-backlog-overdue: unknown subcommand: $SUBCMD" >&2
        awk 'NR==1{next} /^#/ {sub(/^# ?/, "", $0); print} /^[^#]/ {exit}' "$0" >&2
        exit 2
        ;;
esac

exit 0
