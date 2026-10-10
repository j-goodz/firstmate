# shellcheck shell=bash
# This file is sourced by bin/fm-watch.sh and never executed directly.
# It provides zero-fork fast paths for the watcher's per-window poll loop.
# RULE: In fast paths (FMW_FAST=1) no command substitution, no pipeline,
# no external command may be used. The single allowed exception is
# fmw_md5_into which computes a NEW hash via md5sum/md5 pipeline.

# Bash capability gate
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    FMW_FAST=1
    # declare -A at file scope of a sourced file creates globals; -g not available in 4.2
    declare -A FMW_META_OF=()
    declare -A FMW_TASK_OF=()
    declare -A FMW_HASH_TEXT=()
    declare -A FMW_HASH_VAL=()
    declare -A FMW_STATUS_OF=()
    declare -A FMW_PCLASS_KEY=()
    declare -A FMW_PCLASS_VAL=()
    declare -A FMW_PCLASS_AT=()
    declare -A FMW_MTIME_BUF=()
    declare -A FMW_MTIME_VAL=()
    declare -A FMW_SIG_BUF=()
    declare -A FMW_SIG_VAL=()
    declare -A FMW_UNTIL_RC=()
    declare -A FMW_UNTIL_VAL=()
    declare -A FMW_STATUS_BUF=()
    declare -A FMW_STATUS_RES=()
    declare -A FMW_BUSY_KEY=()
    declare -A FMW_BUSY_VAL=()
else
    FMW_FAST=0
fi

# Global initialised at load
FMW_INDEXED=0
_FMW_US=$'\037'

# fmw_cache_reset
# Clears FMW_META_OF, FMW_TASK_OF, FMW_STATUS_OF and sets FMW_INDEXED=0.
# Hash memo (FMW_HASH_*) is NOT cleared. No-op when FMW_FAST=0.
fmw_cache_reset() {
    if [ "$FMW_FAST" = 1 ]; then
        FMW_META_OF=()
        FMW_TASK_OF=()
        FMW_STATUS_OF=()
        FMW_INDEXED=0
    fi
    return 0
}

# fmw_index_metas
# Builds window -> meta map from metas in $STATE.
# For each "$STATE"/*.meta: read window= and terminal= via fm_meta_get_into,
# set FMW_META_OF[$value]=$meta for first meta (glob order) that provides each.
# Sets FMW_INDEXED=1. Only runs when FMW_FAST=1.
fmw_index_metas() {
    if [ "$FMW_FAST" != 1 ]; then
        return 0
    fi
    local _fmw_meta _fmw_window _fmw_terminal _fmw_file
    for _fmw_file in "$STATE"/*.meta; do
        [ -e "$_fmw_file" ] || continue
        fm_meta_get_into _fmw_window "$_fmw_file" window
        fm_meta_get_into _fmw_terminal "$_fmw_file" terminal
        if [ -n "$_fmw_window" ] && [ -z "${FMW_META_OF[$_fmw_window]-}" ]; then
            FMW_META_OF[$_fmw_window]=$_fmw_file
        fi
        if [ -n "$_fmw_terminal" ] && [ -z "${FMW_META_OF[$_fmw_terminal]-}" ]; then
            FMW_META_OF[$_fmw_terminal]=$_fmw_file
        fi
    done
    FMW_INDEXED=1
    return 0
}

# fmw_info <window>
# Sets globals for the window with no fork:
# FMW_META, FMW_KIND, FMW_BACKEND, FMW_HARNESS, FMW_TASK, FMW_LABEL, FMW_KEY
fmw_info() {
    local _fmw_window=$1
    local _fmw_meta _fmw_kind _fmw_backend _fmw_harness _fmw_task _fmw_key _fmw_cached
    local _fmw_kind_val _fmw_backend_val _fmw_harness_val _fmw_task_val

    # FMW_KEY: window with :, /, . replaced by _
    _fmw_key=${_fmw_window//:/_}
    _fmw_key=${_fmw_key//\//_}
    _fmw_key=${_fmw_key//./_}
    FMW_KEY=$_fmw_key

    if [ "$FMW_FAST" = 1 ]; then
        # Ensure index built
        if [ "$FMW_INDEXED" != 1 ]; then
            fmw_index_metas
        fi
        _fmw_meta=${FMW_META_OF[$_fmw_window]-}
        FMW_META=$_fmw_meta

        if [ -n "$_fmw_meta" ]; then
            # Check cached task info
            _fmw_cached=${FMW_TASK_OF[$_fmw_window]-}
            if [ -n "$_fmw_cached" ]; then
                # Split on unit separator
                IFS=$_FMW_US read -r _fmw_kind_val _fmw_backend_val _fmw_harness_val _fmw_task_val <<<"$_fmw_cached"
                FMW_KIND=$_fmw_kind_val
                FMW_BACKEND=$_fmw_backend_val
                FMW_HARNESS=$_fmw_harness_val
                FMW_TASK=$_fmw_task_val
            else
                # Read from meta file
                fm_meta_get_into _fmw_kind_val "$_fmw_meta" kind
                fm_meta_get_into _fmw_backend_val "$_fmw_meta" backend
                fm_meta_get_into _fmw_harness_val "$_fmw_meta" harness
                # task = basename without .meta
                _fmw_task_val=${_fmw_meta##*/}
                _fmw_task_val=${_fmw_task_val%.meta}

                FMW_KIND=${_fmw_kind_val:-ship}
                FMW_BACKEND=${_fmw_backend_val:-tmux}
                FMW_HARNESS=$_fmw_harness_val
                FMW_TASK=$_fmw_task_val

                # Cache it
                FMW_TASK_OF[$_fmw_window]="${FMW_KIND}${_FMW_US}${FMW_BACKEND}${_FMW_US}${FMW_HARNESS}${_FMW_US}${FMW_TASK}"
            fi
        else
            FMW_KIND=unknown
            FMW_BACKEND=tmux
            FMW_HARNESS=
            # task = window with everything up to and including last : removed, then leading fm- removed
            _fmw_task_val=${_fmw_window##*:}
            _fmw_task_val=${_fmw_task_val#fm-}
            FMW_TASK=$_fmw_task_val
        fi
    else
        # SLOW path
        _fmw_meta=$(fm_backend_meta_for_window "$_fmw_window" "$STATE" 2>/dev/null || true)
        FMW_META=$_fmw_meta

        if [ -n "$_fmw_meta" ]; then
            fm_meta_get_into _fmw_kind_val "$_fmw_meta" kind
            fm_meta_get_into _fmw_backend_val "$_fmw_meta" backend
            fm_meta_get_into _fmw_harness_val "$_fmw_meta" harness
            _fmw_task_val=${_fmw_meta##*/}
            _fmw_task_val=${_fmw_task_val%.meta}

            FMW_KIND=${_fmw_kind_val:-ship}
            FMW_BACKEND=${_fmw_backend_val:-tmux}
            FMW_HARNESS=$_fmw_harness_val
            FMW_TASK=$_fmw_task_val
        else
            FMW_KIND=unknown
            FMW_BACKEND=tmux
            FMW_HARNESS=
            _fmw_task_val=${_fmw_window##*:}
            _fmw_task_val=${_fmw_task_val#fm-}
            FMW_TASK=$_fmw_task_val
        fi
    fi

    if [ -n "$FMW_TASK" ]; then
        FMW_LABEL="fm-$FMW_TASK"
    else
        FMW_LABEL=
    fi

    return 0
}

# fmw_key_into <var> <window>
# Sets <var> to window key (:, /, . -> _) without touching other globals.
fmw_key_into() {
    local _fmw_var=$1
    local _fmw_window=$2
    local _fmw_key
    _fmw_key=${_fmw_window//:/_}
    _fmw_key=${_fmw_key//\//_}
    _fmw_key=${_fmw_key//./_}
    printf -v "$_fmw_var" '%s' "$_fmw_key"
    return 0
}

# fmw_read_into <var> <file> <default>
# Sets <var> to first line of <file> when regular file with non-empty first line;
# otherwise to <default>. Builtin read only; works on every bash version.
fmw_read_into() {
    local _fmw_var=$1
    local _fmw_file=$2
    local _fmw_default=$3
    local _fmw_line=''
    if [ -f "$_fmw_file" ] && { IFS= read -r _fmw_line || [ -n "$_fmw_line" ]; } < "$_fmw_file" 2>/dev/null && [ -n "$_fmw_line" ]; then
        printf -v "$_fmw_var" '%s' "$_fmw_line"
    else
        printf -v "$_fmw_var" '%s' "$_fmw_default"
    fi
    return 0
}

# fmw_now_into <var>
# Sets <var> to current epoch seconds.
fmw_now_into() {
    local _fmw_var=$1
    if [ "$FMW_FAST" = 1 ]; then
        printf -v "$_fmw_var" '%(%s)T' -1
    else
        printf -v "$_fmw_var" '%s' "$(date +%s)"
    fi
    return 0
}

# fmw_rm_existing <path>...
# Removes each given path that exists ([ -e ] || [ -L ]), with ONE rm -f call
# only when at least one exists; with none existing runs no command. Returns 0.
fmw_rm_existing() {
    local _fmw_paths=()
    local _fmw_p
    for _fmw_p in "$@"; do
        if [ -e "$_fmw_p" ] || [ -L "$_fmw_p" ]; then
            _fmw_paths+=("$_fmw_p")
        fi
    done
    if [ ${#_fmw_paths[@]} -gt 0 ]; then
        rm -f -- "${_fmw_paths[@]}"
    fi
    return 0
}

# fmw_stamp <file>
# Writes current epoch seconds plus newline into <file> (truncating).
fmw_stamp() {
    local _fmw_file=$1
    if [ "$FMW_FAST" = 1 ]; then
        printf '%(%s)T\n' -1 > "$_fmw_file"
    else
        date +%s > "$_fmw_file"
    fi
    return $?
}

# fmw_md5_into <var> <text>
# Internal: computes md5 hex digest of <text> via pipeline (only forking path).
# Uses md5sum | cut -d' ' -f1, or md5 -q when md5 exists.
# locals use the _fmw_m5_ prefix because the caller passes the name of one of its own variables
fmw_md5_into() {
    local _fmw_m5_out=$1
    local _fmw_m5_text=$2
    local _fmw_m5_hash
    if command -v md5 >/dev/null 2>&1; then
        _fmw_m5_hash=$(printf '%s' "$_fmw_m5_text" | md5 -q)
    else
        _fmw_m5_hash=$(printf '%s' "$_fmw_m5_text" | md5sum | cut -d' ' -f1)
    fi
    printf -v "$_fmw_m5_out" '%s' "$_fmw_m5_hash"
    return 0
}

# fmw_hash_into <var> <key> <text>
# Sets <var> to lowercase md5 hex digest of <text> (same as pane hash).
# FAST: memoised per key in FMW_HASH_TEXT/FMW_HASH_VAL.
# SLOW: always compute via fmw_md5_into.
fmw_hash_into() {
    local _fmw_var=$1
    local _fmw_key=$2
    local _fmw_text=$3
    local _fmw_hash

    if [ "$FMW_FAST" = 1 ]; then
        if [ -n "${FMW_HASH_VAL[$_fmw_key]-}" ] && [ "${FMW_HASH_TEXT[$_fmw_key]-}" = "$_fmw_text" ]; then
            _fmw_hash=${FMW_HASH_VAL[$_fmw_key]}
            printf -v "$_fmw_var" '%s' "$_fmw_hash"
            return 0
        fi
        fmw_md5_into _fmw_hash "$_fmw_text"
        FMW_HASH_TEXT[$_fmw_key]=$_fmw_text
        FMW_HASH_VAL[$_fmw_key]=$_fmw_hash
        printf -v "$_fmw_var" '%s' "$_fmw_hash"
    else
        fmw_md5_into _fmw_hash "$_fmw_text"
        printf -v "$_fmw_var" '%s' "$_fmw_hash"
    fi
    return 0
}

# fmw_status_last_into <var> <status-file>
# Sets <var> to what last_status_line <status-file> prints (trailing newline removed),
# without forking for files < 128 KiB.
fmw_status_last_into() {
    local _fmw_var=$1
    local _fmw_file=$2
    local _fmw_buf _fmw_scan _fmw_tail
    local -a _fmw_lines

    if [ ! -f "$_fmw_file" ] || [ ! -r "$_fmw_file" ]; then
        printf -v "$_fmw_var" ''
        return 0
    fi

    if [ "$FMW_FAST" = 1 ]; then
        # Check cache first
        if [ -n "${FMW_STATUS_OF[$_fmw_file]-}" ]; then
            printf -v "$_fmw_var" '%s' "${FMW_STATUS_OF[$_fmw_file]}"
            return 0
        fi

        # Read up to 128 KiB
        IFS= read -r -d '' -N 131072 _fmw_buf < "$_fmw_file" || true

        if [ ${#_fmw_buf} -eq 131072 ]; then
            # File may be larger - use SLOW path
            printf -v "$_fmw_var" '%s' "$(last_status_line "$_fmw_file")"
            FMW_STATUS_OF[$_fmw_file]=${!_fmw_var}
            return 0
        fi

        # Cross-poll memo: an unchanged file content gives the same answer without running the scan.
        if [ "${FMW_STATUS_BUF[$_fmw_file]+x}" = x ] && [ "${FMW_STATUS_BUF[$_fmw_file]}" = "$_fmw_buf" ]; then
            printf -v "$_fmw_var" '%s' "${FMW_STATUS_RES[$_fmw_file]}"
            FMW_STATUS_OF[$_fmw_file]=${FMW_STATUS_RES[$_fmw_file]}
            return 0
        fi

        # Process buffer: last 200 lines
        mapfile -t _fmw_lines <<<"$_fmw_buf"
        if [ ${#_fmw_lines[@]} -gt 200 ]; then
            _fmw_lines=("${_fmw_lines[@]: -200}")
        fi
        printf -v _fmw_tail '%s\n' "${_fmw_lines[@]}"

        # Run classifier on tail (single allowed fork on cache miss)
        _fmw_scan=$(_fm_status_event_scan <<<"$_fmw_tail") || _fmw_scan=$(_fm_status_event_scan <<<"$_fmw_buf" || :)

        # Result is last line of scan output
        _fmw_scan=${_fmw_scan##*$'\n'}
        printf -v "$_fmw_var" '%s' "$_fmw_scan"
        FMW_STATUS_OF[$_fmw_file]=$_fmw_scan
        FMW_STATUS_BUF[$_fmw_file]=$_fmw_buf
        FMW_STATUS_RES[$_fmw_file]=$_fmw_scan
    else
        # SLOW path
        printf -v "$_fmw_var" '%s' "$(last_status_line "$_fmw_file")"
    fi
    return 0
}
 
# fmw_busy_now_into <var> <window> <tail40> <pane-hash> <task> <backend> <harness>
# Sets <var> to 0 when window_is_busy "<window>" "<tail40>" would return 0 (busy) and to 1 otherwise,
# but memoises the verdict across polls when it is a pure function of files already read here:
# the task's busy-state record, its armed gen, the pane hash, backend and harness.
# Memoised only for the record-based harnesses (claude*, opencode*, pi, pi-signed, omp, gemini*) and
# never for a herdr task that has no record, whose verdict comes from live herdr state.
# Any other case, and FMW_FAST=0, calls window_is_busy every time. Needs window_is_busy from fm-watch.sh.
fmw_busy_now_into() {
    local _fmw_var=$1 _fmw_w=$2 _fmw_tail=$3 _fmw_h=$4 _fmw_task=$5 _fmw_backend=$6 _fmw_harness=$7
    local _fmw_rec _fmw_gen _fmw_present=0 _fmw_key _fmw_val
    if [ "$FMW_FAST" = 1 ] && [ -n "$_fmw_task" ]; then
        case "$_fmw_harness" in
            claude*|opencode*|pi|pi-signed|omp|gemini*)
                [ -f "$STATE/$_fmw_task.busy-state" ] && _fmw_present=1
                if [ "$_fmw_present" = 1 ] || [ "$_fmw_backend" != herdr ]; then
                    fmw_read_into _fmw_rec "$STATE/$_fmw_task.busy-state" "-"
                    fmw_read_into _fmw_gen "$STATE/$_fmw_task.busy-gen" "-"
                    _fmw_key="$_fmw_h|$_fmw_present|$_fmw_rec|$_fmw_gen|$_fmw_backend|$_fmw_harness|$_fmw_task"
                    if [ "${FMW_BUSY_KEY[$_fmw_w]-}" = "$_fmw_key" ] && [ -n "${FMW_BUSY_VAL[$_fmw_w]-}" ]; then
                        printf -v "$_fmw_var" '%s' "${FMW_BUSY_VAL[$_fmw_w]}"
                        return 0
                    fi
                    if window_is_busy "$_fmw_w" "$_fmw_tail"; then _fmw_val=0; else _fmw_val=1; fi
                    FMW_BUSY_KEY[$_fmw_w]=$_fmw_key
                    FMW_BUSY_VAL[$_fmw_w]=$_fmw_val
                    printf -v "$_fmw_var" '%s' "$_fmw_val"
                    return 0
                fi
                ;;
        esac
    fi
    if window_is_busy "$_fmw_w" "$_fmw_tail"; then _fmw_val=0; else _fmw_val=1; fi
    printf -v "$_fmw_var" '%s' "$_fmw_val"
    return 0
}
 
# fmw_pause_class_into <var> <window> <task> <pane-hash> <last-status-line>
# Sets <var> to what `$(pause_state_class "<window>" "<task>")` prints. With FMW_FAST=1 the answer is
# memoised per window for FM_PAUSE_CLASS_MEMO_SECS seconds (default 60) while the pane hash and last
# status line are unchanged, so a parked pane does not re-probe the agent every poll. Needs pause_state_class.
fmw_pause_class_into() {
    local _fmw_var=$1 _fmw_w=$2 _fmw_task=$3 _fmw_h=$4 _fmw_last=$5
    local _fmw_ttl=${FM_PAUSE_CLASS_MEMO_SECS:-60} _fmw_now _fmw_key _fmw_val
    case "$_fmw_ttl" in ''|*[!0-9]*) _fmw_ttl=60 ;; esac
    _fmw_key="$_fmw_h|$_fmw_last|$_fmw_task"
    if [ "$FMW_FAST" = 1 ] && [ "$_fmw_ttl" -gt 0 ]; then
        fmw_now_into _fmw_now
        if [ "${FMW_PCLASS_KEY[$_fmw_w]-}" = "$_fmw_key" ] \
            && [ $(( _fmw_now - ${FMW_PCLASS_AT[$_fmw_w]:-0} )) -lt "$_fmw_ttl" ]; then
            printf -v "$_fmw_var" '%s' "${FMW_PCLASS_VAL[$_fmw_w]}"
            return 0
        fi
        _fmw_val=$(pause_state_class "$_fmw_w" "$_fmw_task")
        FMW_PCLASS_KEY[$_fmw_w]=$_fmw_key
        FMW_PCLASS_VAL[$_fmw_w]=$_fmw_val
        FMW_PCLASS_AT[$_fmw_w]=$_fmw_now
        printf -v "$_fmw_var" '%s' "$_fmw_val"
        return 0
    fi
    _fmw_val=$(pause_state_class "$_fmw_w" "$_fmw_task")
    printf -v "$_fmw_var" '%s' "$_fmw_val"
    return 0
}

# fmw_status_mtime_into <var> <status-file>
# Sets <var> to what `$(stat_mtime "<status-file>")` prints. With FMW_FAST=1 the value is memoised while the
# file content (as read by fmw_status_last_into into FMW_STATUS_BUF) is unchanged; call fmw_status_last_into first.
fmw_status_mtime_into() {
    local _fmw_var=$1 _fmw_file=$2 _fmw_val
    if [ "$FMW_FAST" = 1 ] && [ "${FMW_STATUS_BUF[$_fmw_file]+x}" = x ] \
        && [ "${FMW_MTIME_BUF[$_fmw_file]+x}" = x ] && [ "${FMW_MTIME_BUF[$_fmw_file]}" = "${FMW_STATUS_BUF[$_fmw_file]}" ]; then
        printf -v "$_fmw_var" '%s' "${FMW_MTIME_VAL[$_fmw_file]}"
        return 0
    fi
    _fmw_val=$(stat_mtime "$_fmw_file")
    if [ "$FMW_FAST" = 1 ] && [ "${FMW_STATUS_BUF[$_fmw_file]+x}" = x ]; then
        FMW_MTIME_BUF[$_fmw_file]=${FMW_STATUS_BUF[$_fmw_file]}
        FMW_MTIME_VAL[$_fmw_file]=$_fmw_val
    fi
    printf -v "$_fmw_var" '%s' "$_fmw_val"
    return 0
}

# fmw_declared_sig_into <var> <status-file>
# Sets <var> to what `$(fm_wake_signal_sig "<status-file>" || true)` prints, memoised like fmw_status_mtime_into.
fmw_declared_sig_into() {
    local _fmw_var=$1 _fmw_file=$2 _fmw_val
    if [ "$FMW_FAST" = 1 ] && [ "${FMW_STATUS_BUF[$_fmw_file]+x}" = x ] \
        && [ "${FMW_SIG_BUF[$_fmw_file]+x}" = x ] && [ "${FMW_SIG_BUF[$_fmw_file]}" = "${FMW_STATUS_BUF[$_fmw_file]}" ]; then
        printf -v "$_fmw_var" '%s' "${FMW_SIG_VAL[$_fmw_file]}"
        return 0
    fi
    _fmw_val=$(fm_wake_signal_sig "$_fmw_file" || true)
    if [ "$FMW_FAST" = 1 ] && [ "${FMW_STATUS_BUF[$_fmw_file]+x}" = x ]; then
        FMW_SIG_BUF[$_fmw_file]=${FMW_STATUS_BUF[$_fmw_file]}
        FMW_SIG_VAL[$_fmw_file]=$_fmw_val
    fi
    printf -v "$_fmw_var" '%s' "$_fmw_val"
    return 0
}

# fmw_paused_until_into <var> <status-line>
# Like `<var>=$(status_paused_until "<status-line>")`: sets <var> to the epoch and returns 0, or returns 1 with
# <var> empty. With FMW_FAST=1 memoised per distinct status line (the answer is a pure function of the line);
# the memo is cleared once it holds more than 256 lines.
fmw_paused_until_into() {
    local _fmw_var=$1 _fmw_line=$2 _fmw_val _fmw_rc
    if [ "$FMW_FAST" = 1 ] && [ "${FMW_UNTIL_RC[$_fmw_line]+x}" = x ]; then
        printf -v "$_fmw_var" '%s' "${FMW_UNTIL_VAL[$_fmw_line]}"
        return "${FMW_UNTIL_RC[$_fmw_line]}"
    fi
    _fmw_val=$(status_paused_until "$_fmw_line") && _fmw_rc=0 || _fmw_rc=$?
    if [ "$FMW_FAST" = 1 ]; then
        if [ "${#FMW_UNTIL_RC[@]}" -gt 256 ]; then FMW_UNTIL_RC=(); FMW_UNTIL_VAL=(); fi
        FMW_UNTIL_RC[$_fmw_line]=$_fmw_rc
        FMW_UNTIL_VAL[$_fmw_line]=$_fmw_val
    fi
    printf -v "$_fmw_var" '%s' "$_fmw_val"
    return "$_fmw_rc"
}
return 0