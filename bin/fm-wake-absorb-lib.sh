#!/usr/bin/env bash
# fm-wake-absorb-lib.sh — bash library for wake absorb logic
# Contracts:
# - Sourced only, never executed; no side effects beyond sourcing fm-wake-lib.sh and fm-classify-lib.sh.
# - Requires bash 3.2+; no associative arrays, no mapfile, no ${var,,}.
# - All functions documented with a one-line comment.
# - shellcheck -x clean.
# - Tabs emitted via $(printf '\t').

_FM_WAKE_ABSORB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A caller that already sourced either library keeps its own state: sourcing again
# would re-run their top-level initialisation.
if ! command -v fm_wake_append >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$_FM_WAKE_ABSORB_LIB_DIR/fm-wake-lib.sh"
fi
if ! command -v status_line_verb >/dev/null 2>&1; then
    # shellcheck source=bin/fm-classify-lib.sh
    . "$_FM_WAKE_ABSORB_LIB_DIR/fm-classify-lib.sh"
fi

# fm_wake_row_needs_brain <kind> <key> <payload>
# Return 0 when row needs brain (wake), 1 when record-only (safe to ack in bash).
fm_wake_row_needs_brain() {
    local kind="$1" key="$2" payload="$3"
    local tab
    tab="$(printf '\t')"

    if [ "$kind" = "signal" ]; then
        case "$payload" in
            needs-decision:*)
                return 0
                ;;
        esac
        case "$key" in
            *.turn-ended)
                return 0
                ;;
        esac
        if ! fm_wake_status_key_map "$key"; then
            return 0
        fi
        if [ "$FM_WAKE_STATUS_HISTORICAL" = "true" ]; then
            return 0
        fi
        local status_path="$STATE/$FM_WAKE_STATUS_KEY"
        if [ ! -f "$status_path" ] || [ -L "$status_path" ]; then
            return 0
        fi
        local offset
        if ! offset="$(fm_wake_status_cursor_offset "$status_path")"; then
            return 0
        fi
        if ! fm_wake_unread_events "$status_path" 0 "$offset"; then
            return 0
        fi
        local line verb
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            verb="$(status_line_verb "$line")"
            case "$verb" in
                working|resolved|captain-held)
                    ;;
                *)
                    return 0
                    ;;
            esac
        done <<EOF
$FM_WAKE_UNREAD_LINES
EOF
        return 1
    fi

    if [ "$kind" = "check" ]; then
        case "$payload" in
            "check: merge landed: "*)
                local rest="${payload#check: merge landed: }"
                local task_id="${rest%% *}"
                case "$task_id" in
                    ''|*[!A-Za-z0-9._-]*)
                        return 0
                        ;;
                esac
                if [ -f "$STATE/$task_id.meta" ]; then
                    return 0
                fi
                return 1
                ;;
        esac
    fi

    return 0
}

# fm_wake_rows_all_record_only <rows-file>
# Return 0 only when file has >=1 valid row and every valid row is record-only.
fm_wake_rows_all_record_only() {
    local rows_file="$1"
    local tab
    tab="$(printf '\t')"
    local line epoch seq kind key payload
    local has_valid=0

    [ -r "$rows_file" ] || return 1

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        epoch="${line%%"$tab"*}"
        line="${line#*"$tab"}"
        seq="${line%%"$tab"*}"
        line="${line#*"$tab"}"
        kind="${line%%"$tab"*}"
        line="${line#*"$tab"}"
        key="${line%%"$tab"*}"
        payload="${line#*"$tab"}"
        case "$line" in
            *"$tab"*)
                ;;
            *)
                continue
                ;;
        esac
        has_valid=1
        if ! fm_wake_row_needs_brain "$kind" "$key" "$payload"; then
            :
        else
            return 1
        fi
    done <"$rows_file"

    [ "$has_valid" -eq 1 ] || return 1
    return 0
}

# fm_wake_delivered_write <ack-through> <generation>
# Atomically write $STATE/.drain-delivered with ack-through, generation, epoch.
fm_wake_delivered_write() {
    local ack_through="$1" generation="$2"
    local tab
    tab="$(printf '\t')"
    local epoch now tmp

    case "$ack_through" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    case "$generation" in
        ''|*[!A-Za-z0-9._-]*)
            return 1
            ;;
    esac

    now="$(date -u +%s 2>/dev/null || printf '%s\n' 0)"
    tmp="$STATE/.drain-delivered.tmp.$$"
    printf '%s%s%s%s%s\n' "$ack_through" "$tab" "$generation" "$tab" "$now" >"$tmp" || return 1
    chmod 0600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$STATE/.drain-delivered" || { rm -f "$tmp"; return 1; }
    return 0
}

# fm_wake_delivered_drop_through <ack-through>
# Remove the delivery record when an acknowledgement at or above its cutoff covers it.
fm_wake_delivered_drop_through() {
    local ack_through="$1" tab line seq
    tab="$(printf '\t')"
    [ -r "$STATE/.drain-delivered" ] || return 0
    line="$(head -n1 "$STATE/.drain-delivered" 2>/dev/null)"
    seq="${line%%"$tab"*}"
    case "$seq" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$ack_through" -ge "$seq" ] || return 0
    rm -f "$STATE/.drain-delivered"
    return 0
}

# fm_wake_delivered_claim
# Atomically claim delivery record; set FM_DELIVERED_SEQ, FM_DELIVERED_GENERATION, FM_DELIVERED_EPOCH.
fm_wake_delivered_claim() {
    local tab
    tab="$(printf '\t')"
    local claimed="$STATE/.drain-delivered.claimed.$$.$RANDOM"
    local line seq gen epoch

    if ! mv -f "$STATE/.drain-delivered" "$claimed" 2>/dev/null; then
        return 1
    fi

    if [ ! -r "$claimed" ]; then
        rm -f "$claimed"
        return 2
    fi

    line="$(head -n1 "$claimed" 2>/dev/null)"
    rm -f "$claimed"

    if [ -z "$line" ]; then
        return 2
    fi

    seq="${line%%"$tab"*}"
    line="${line#*"$tab"}"
    gen="${line%%"$tab"*}"
    epoch="${line#*"$tab"}"

    case "$seq" in
        ''|*[!0-9]*)
            return 2
            ;;
    esac
    case "$gen" in
        ''|*[!A-Za-z0-9._-]*)
            return 2
            ;;
    esac
    case "$epoch" in
        ''|*[!0-9]*)
            return 2
            ;;
    esac

    # shellcheck disable=SC2034 # Outputs read by the sourcing caller.
    FM_DELIVERED_SEQ="$seq"
    # shellcheck disable=SC2034
    FM_DELIVERED_GENERATION="$gen"
    # shellcheck disable=SC2034
    FM_DELIVERED_EPOCH="$epoch"
    return 0
}

# fm_stop_turn_interrupted <transcript-path> <since-epoch>
# Return 0 if interrupted since epoch, 1 if not, 2 if path invalid.
fm_stop_turn_interrupted() {
    local transcript_path="$1" since_epoch="$2"
    local tab
    tab="$(printf '\t')"
    local chunk line ts epoch

    [ -n "$transcript_path" ] || return 2
    [ -f "$transcript_path" ] || return 2
    [ -r "$transcript_path" ] || return 2

    chunk="$(tail -c 400000 "$transcript_path" 2>/dev/null)"
    [ -n "$chunk" ] || return 1

    while IFS= read -r line; do
        case "$line" in
            *'[Request interrupted by user'*)
                ts="${line##*\"timestamp\":\"}"
                ts="${ts%%\"*}"
                case "$ts" in
                    *.*Z)
                        ts="${ts%.*}Z"
                        ;;
                esac
                if ! epoch="$(fm_utc_iso_to_epoch "$ts" 2>/dev/null)"; then
                    return 0
                fi
                if [ "$epoch" -ge "$since_epoch" ] 2>/dev/null; then
                    return 0
                fi
                ;;
        esac
    done <<EOF
$chunk
EOF
    return 1
}

# fm_wake_section_hash <text>
# Print stable hash as <cksum-crc>-<cksum-bytes>.
fm_wake_section_hash() {
    local text="$1"
    local cksum_out crc bytes
    cksum_out="$(printf '%s' "$text" | cksum 2>/dev/null)"
    crc="${cksum_out%% *}"
    bytes="${cksum_out#* }"
    bytes="${bytes%% *}"
    printf '%s-%s\n' "$crc" "$bytes"
}

# fm_wake_section_unchanged <name> <hash>
# Return 0 only when section exists with matching hash and age < TTL.
fm_wake_section_unchanged() {
    local name="$1" hash="$2"
    local tab
    tab="$(printf '\t')"
    local ttl line file_hash file_epoch now age

    ttl="${FM_DRAIN_SECTION_TTL_SECS:-14400}"
    case "$ttl" in
        ''|*[!0-9]*)
            ttl=14400
            ;;
    esac
    [ "$ttl" -gt 0 ] 2>/dev/null || ttl=14400

    [ -r "$STATE/.drain-sections" ] || return 1

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            "$name"$tab*)
                file_hash="${line#*"$tab"}"
                file_hash="${file_hash%%"$tab"*}"
                file_epoch="${line##*"$tab"}"
                [ "$file_hash" = "$hash" ] || return 1
                now="$(date -u +%s 2>/dev/null || printf '%s\n' 0)"
                age=$((now - file_epoch))
                [ "$age" -lt "$ttl" ] 2>/dev/null || return 1
                return 0
                ;;
        esac
    done <"$STATE/.drain-sections"

    return 1
}

# fm_wake_section_record <name> <hash>
# Atomically rewrite $STATE/.drain-sections keeping other names, updating this one.
fm_wake_section_record() {
    local name="$1" hash="$2"
    local tab
    tab="$(printf '\t')"
    local now tmp line kept

    now="$(date -u +%s 2>/dev/null || printf '%s\n' 0)"
    tmp="$STATE/.drain-sections.tmp.$$"
    kept=""

    if [ -r "$STATE/.drain-sections" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in
                "$name"$tab*)
                    continue
                    ;;
            esac
            kept="${kept}${line}\n"
        done <"$STATE/.drain-sections"
    fi

    printf '%s%s%s%s%s\n' "$name" "$tab" "$hash" "$tab" "$now" >"$tmp" || { rm -f "$tmp"; return 1; }
    if [ -n "$kept" ]; then
        printf '%b' "$kept" >>"$tmp" || { rm -f "$tmp"; return 1; }
    fi
    chmod 0600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$STATE/.drain-sections" || { rm -f "$tmp"; return 1; }
    return 0
}

# fm_wake_section_forget <name>
# Atomically rewrite $STATE/.drain-sections without name; remove file if empty.
fm_wake_section_forget() {
    local name="$1"
    local tab
    tab="$(printf '\t')"
    local tmp line kept

    [ -f "$STATE/.drain-sections" ] || return 0

    tmp="$STATE/.drain-sections.tmp.$$"
    kept=""

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            "$name"$tab*)
                continue
                ;;
        esac
        kept="${kept}${line}\n"
    done <"$STATE/.drain-sections"

    if [ -z "$kept" ]; then
        rm -f "$STATE/.drain-sections"
        rm -f "$tmp"
        return 0
    fi

    printf '%b' "$kept" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$STATE/.drain-sections" || { rm -f "$tmp"; return 1; }
    return 0
}

# fm_wake_absorb_log <event> [key=value ...]
# Append JSON line to $STATE/wake-absorb.jsonl; rotate at 1MB to last 2000 lines.
fm_wake_absorb_log() {
    local event="$1"
    shift
    local tab
    tab="$(printf '\t')"
    local epoch now json key value pair esc_key esc_val tmp lines

    epoch="$(date -u +%s 2>/dev/null || printf '%s\n' 0)"
    json="{\"ts\":$epoch,\"event\":\"$event\""

    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        case "$key" in
            ''|*[!A-Za-z0-9_]*)
                continue
                ;;
        esac
        esc_key="$(printf '%s' "$key" | sed 's/[\\"]/ /g' | tr -cd '[:print:]')"
        esc_val="$(printf '%s' "$value" | tr '[:cntrl:]' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')"
        json="${json},\"${esc_key}\":\"${esc_val}\""
    done

    json="${json}}"

    printf '%s\n' "$json" >>"$STATE/wake-absorb.jsonl" 2>/dev/null || return 0

    if [ -f "$STATE/wake-absorb.jsonl" ]; then
        local size
        size="$(wc -c <"$STATE/wake-absorb.jsonl" 2>/dev/null || printf '%s\n' 0)"
        if [ "$size" -gt 1000000 ] 2>/dev/null; then
            tmp="$STATE/wake-absorb.jsonl.tmp.$$"
            if tail -n 2000 "$STATE/wake-absorb.jsonl" >"$tmp" 2>/dev/null; then
                mv -f "$tmp" "$STATE/wake-absorb.jsonl" 2>/dev/null || rm -f "$tmp"
            else
                rm -f "$tmp"
            fi
        fi
    fi
    return 0
}