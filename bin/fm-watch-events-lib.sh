# shellcheck shell=bash
# Firstmate watch-events library: inotify-backed directory monitor with safe fallback.
# Sourced by bin/fm-watch.sh; never executed directly.

# Globals (set by fm_wev_init)
FM_WEV_STATE=""
FM_WEV_KIND="none"
# The FIFO read-write descriptor. Allocated by bash (`exec {FM_WEV_FD}<>`) so it never
# collides with the fixed small descriptors other libraries open in the same shell.
FM_WEV_FD=""
FM_WEV_STARTS=0
FM_WEV_MON_PID=""
FM_WEV_STARTED_AT=0
FM_WEV_DIRS_KEY=""
FM_WEV_EXTRA_DIRS=""

# Dirty flags (0/1) - set by library, read by caller (fm-watch.sh)
# shellcheck disable=SC2034
FM_WEV_SIG=0
# shellcheck disable=SC2034
FM_WEV_RECOV=0
# shellcheck disable=SC2034
FM_WEV_PR=0
# shellcheck disable=SC2034
FM_WEV_META=0
# shellcheck disable=SC2034
FM_WEV_PROC=0
# shellcheck disable=SC2034
FM_WEV_OUT=0
# shellcheck disable=SC2034
FM_WEV_STALL=0
# shellcheck disable=SC2034
FM_WEV_GEN=0
# FM_WEV_FULL is 1 after fm_wev_all (first pass, restart, safety net): scan everything.
# Otherwise FM_WEV_SIG_FILES lists the status and turn-end files that changed.
# shellcheck disable=SC2034
FM_WEV_FULL=0
# shellcheck disable=SC2034
FM_WEV_SIG_FILES=""

# Embedded Python inotify monitor (single-quoted to avoid expansion)
FM_WEV_PY='
import os, sys, select, ctypes, ctypes.util, struct, errno
libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
IN_CLOSE_WRITE = 0x8
IN_MOVED_TO = 0x80
IN_MOVED_FROM = 0x40
IN_CREATE = 0x100
IN_DELETE = 0x200
IN_ATTRIB = 0x4
MASK = IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE | IN_ATTRIB
fd = libc.inotify_init()
if fd < 0:
    sys.exit(1)
wd_map = {}
for path in sys.argv[1:]:
    wd = libc.inotify_add_watch(fd, path.encode(), MASK)
    if wd < 0:
        sys.exit(1)
    wd_map[wd] = path
parent_pid = os.getppid()
event_fmt = "iIII"
event_size = struct.calcsize(event_fmt)
while True:
    r, _, _ = select.select([fd], [], [], 5)
    if os.getppid() != parent_pid:
        break
    if not r:
        continue
    buf = os.read(fd, 65536)
    n = len(buf)
    if n <= 0:
        continue
    i = 0
    while i + event_size <= n:
        wd, mask, cookie, length = struct.unpack_from(event_fmt, buf, i)
        i += event_size
        name = buf[i:i+length].rstrip(b"\x00").decode(errors="ignore")
        i += length
        if name:
            dir_path = wd_map.get(wd, "")
            if dir_path:
                os.write(1, (dir_path + "/" + name + "\n").encode())
'

# Log a fallback reason once to the state dir fallback log.
_fm_wev_fallback_log() {
    local reason="$1"
    local log_file="${FM_WEV_STATE}/.watch-events.fallback"
    # Only log if file is empty or absent (first fallback)
    if [[ ! -s "$log_file" ]]; then
        printf '%(%s)T fm-watch: %s; polling every FM_POLL seconds\n' -1 "$reason" >>"$log_file" 2>/dev/null || true
    fi
}

# Close the event descriptor if one is open.
_fm_wev_close_fd() {
    if [[ -n "$FM_WEV_FD" ]]; then
        exec {FM_WEV_FD}<&-
        FM_WEV_FD=""
    fi
}

# Initialize library with state directory.
fm_wev_init() {
    FM_WEV_STATE="$1"
    FM_WEV_KIND="none"
    FM_WEV_STARTS=0
    FM_WEV_MON_PID=""
    FM_WEV_STARTED_AT=0
    FM_WEV_DIRS_KEY=""
    fm_wev_clear
}

# Zero all dirty flags.
fm_wev_clear() {
    FM_WEV_SIG=0
    FM_WEV_RECOV=0
    FM_WEV_PR=0
    FM_WEV_META=0
    FM_WEV_PROC=0
    FM_WEV_OUT=0
    FM_WEV_STALL=0
    FM_WEV_GEN=0
    FM_WEV_FULL=0
    FM_WEV_SIG_FILES=""
}

# Set all dirty flags to 1.
# shellcheck disable=SC2034  # flags are read by caller (fm-watch.sh)
fm_wev_all() {
    FM_WEV_SIG=1
    FM_WEV_RECOV=1
    FM_WEV_PR=1
    FM_WEV_META=1
    FM_WEV_PROC=1
    FM_WEV_OUT=1
    FM_WEV_STALL=1
    FM_WEV_GEN=1
    FM_WEV_FULL=1
}

# Print directories to watch (one per line).
fm_wev_dirs() {
    local S="$FM_WEV_STATE"
    printf '%s\n' "$S"
    local sub
    for sub in pending-replies procevent-inbox terminal-outcomes; do
        [[ -d "$S/$sub" && ! -L "$S/$sub" ]] && printf '%s\n' "$S/$sub"
    done
    local extra
    for extra in $FM_WEV_EXTRA_DIRS; do
        [[ -d "$extra" ]] && printf '%s\n' "$extra"
    done
}

# Classify a single event path into dirty flags.
# shellcheck disable=SC2034  # flags are read by caller (fm-watch.sh)
fm_wev_classify() {
    local path="$1"
    local S="$FM_WEV_STATE"
    local base="${path##*/}"
    local dir="${path%/*}"

    # Direct matches in state dir
    case "$path" in
        "$S"/*.status|"$S"/*.turn-ended)
            FM_WEV_SIG=1
            case " $FM_WEV_SIG_FILES " in
                *" $path "*) ;;
                *) FM_WEV_SIG_FILES="$FM_WEV_SIG_FILES $path" ;;
            esac
            return ;;
        "$S"/.wake-queue|"$S"/.watcher-down)
            FM_WEV_RECOV=1; return ;;
        "$S"/*.meta)
            FM_WEV_META=1; return ;;
        "$S"/pending-replies/*)
            FM_WEV_PR=1; return ;;
        "$S"/procevent-inbox/*)
            FM_WEV_PROC=1; return ;;
        "$S"/terminal-outcomes/*)
            FM_WEV_OUT=1; return ;;
        "$S"/reconcile-notify/*|"$S"/procevent/*|"$S"/when/*)
            return ;; # ignored: the watcher globs reconcile-notify itself; procevent leases are noisy
        "$S"/home-summary.json|"$S"/*.progress|"$S"/*.busy-state|"$S"/*.busy-gen)
            return ;; # ignored
        "$S"/.afk*)
            FM_WEV_GEN=1; return ;;
        "$S"/.*)
            return ;; # ignored (the watcher's own markers, locks and temp files)
    esac

    # Extra dirs (foreign secondmate state dirs)
    local extra
    for extra in $FM_WEV_EXTRA_DIRS; do
        if [[ "$dir" == "$extra" ]]; then
            case "$base" in
                .wake-queue*)
                    FM_WEV_STALL=1; return ;;
                *)
                    return ;; # ignored
            esac
        fi
    done

    # Anything else under state dir (including deeper subdirs not listed above)
    if [[ "$path" == "$S"/* ]]; then
        FM_WEV_GEN=1
    fi
}

# Start the monitor. Returns 0 on success, 1 on fallback.
fm_wev_start() {
    # Preconditions
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
        _fm_wev_fallback_log "bash older than 4.2"
        return 1
    fi
    if [[ -n "${FM_WATCH_EVENTS_NO_INOTIFY:-}" || "${FM_WATCH_EVENTS:-}" == "off" || "${FM_WATCH_EVENTS:-}" == "0" ]]; then
        _fm_wev_fallback_log "event wait disabled"
        return 1
    fi

    local fifo="${FM_WEV_STATE}/.watch-events.$$"
    if ! mkfifo "$fifo" 2>/dev/null; then
        _fm_wev_fallback_log "no FIFO"
        return 1
    fi
    # Open the FIFO read-write on a bash-allocated descriptor, then unlink it immediately.
    { exec {FM_WEV_FD}<>"$fifo"; } 2>/dev/null || { rm -f "$fifo"; _fm_wev_fallback_log "no FIFO"; return 1; }
    rm -f "$fifo"

    # Choose event source
    local kind=""
    if [[ -z "${FM_WATCH_EVENTS_NO_INOTIFYWAIT:-}" ]] && command -v inotifywait >/dev/null 2>&1; then
        kind="inotifywait"
    elif python3 -c "import ctypes, ctypes.util" >/dev/null 2>&1; then
        kind="python"
    else
        _fm_wev_fallback_log "no inotifywait or python3 inotify"
        _fm_wev_close_fd
        return 1
    fi

    # Read directories into array
    local dirs=()
    local line
    while IFS= read -r line; do
        dirs+=("$line")
    done < <(fm_wev_dirs)

    # Remember joined list for change detection
    FM_WEV_DIRS_KEY="${dirs[*]}"

    # Start monitor
    if [[ "$kind" == "inotifywait" ]]; then
        timeout 3600 inotifywait -m -q -e close_write,moved_to,moved_from,create,delete,attrib --format '%w%f' "${dirs[@]}" 1>&"$FM_WEV_FD" 2>/dev/null < /dev/null &
    else
        python3 -c "$FM_WEV_PY" "${dirs[@]}" 1>&"$FM_WEV_FD" 2>/dev/null < /dev/null &
    fi
    FM_WEV_MON_PID=$!
    FM_WEV_KIND="$kind"
    printf -v FM_WEV_STARTED_AT '%(%s)T' -1
    FM_WEV_STARTS=$((FM_WEV_STARTS + 1))
    return 0
}

# Ensure monitor is alive; restart if dead or too old.
fm_wev_alive() {
    [[ "$FM_WEV_KIND" == "none" ]] && return 1
    local now
    printf -v now '%(%s)T' -1
    if ! kill -0 "$FM_WEV_MON_PID" 2>/dev/null || (( now - FM_WEV_STARTED_AT >= 3000 )); then
        # Monitor dead or too old; only a monitor that ended early counts toward the restart limit
        if kill -0 "$FM_WEV_MON_PID" 2>/dev/null; then
            FM_WEV_STARTS=$((FM_WEV_STARTS - 1))
        fi
        kill "$FM_WEV_MON_PID" 2>/dev/null || true
        # Close the descriptor before restart
        _fm_wev_close_fd
        if (( FM_WEV_STARTS >= 12 )); then
            FM_WEV_KIND="none"
            _fm_wev_fallback_log "the event monitor kept ending; polling instead"
            return 1
        fi
        fm_wev_start || return 1
        fm_wev_all
    fi
    return 0
}

# Refresh watched directories if the set changed.
fm_wev_refresh_dirs() {
    local new_key
    [[ "$FM_WEV_KIND" == "none" ]] && return 0
    new_key="$(fm_wev_dirs | tr '\n' ' ')"
    new_key="${new_key% }"
    if [[ "$new_key" != "$FM_WEV_DIRS_KEY" ]]; then
        # a deliberate restart of a healthy monitor does not count toward the restart limit
        FM_WEV_STARTS=$((FM_WEV_STARTS - 1))
        kill "$FM_WEV_MON_PID" 2>/dev/null || true
        _fm_wev_close_fd
        if (( FM_WEV_STARTS >= 12 )); then
            FM_WEV_KIND="none"
            _fm_wev_fallback_log "the event monitor kept ending; polling instead"
            return 1
        fi
        fm_wev_start || return 1
        fm_wev_all
    fi
    return 0
}

# Drain all available events non-blocking.
fm_wev_drain() {
    [[ "$FM_WEV_KIND" == "none" ]] && return
    local line
    while read -t 0 -u "$FM_WEV_FD" 2>/dev/null; do
        IFS= read -r -t 1 -u "$FM_WEV_FD" line || break
        fm_wev_classify "$line"
    done
}

# Wait for an event that sets a dirty flag, up to $1 seconds. Events classified as
# ignored (the watcher's own beacon and markers) do not end the wait.
# Returns 0 if a flag was set, 1 on timeout/fallback.
_fm_wev_flags() {
    printf -v _FM_WEV_SNAP '%s' "$FM_WEV_SIG$FM_WEV_RECOV$FM_WEV_PR$FM_WEV_META$FM_WEV_PROC$FM_WEV_OUT$FM_WEV_STALL$FM_WEV_GEN$FM_WEV_FULL$FM_WEV_SIG_FILES"
}

fm_wev_wait() {
    local seconds="${1:-1}"
    (( seconds < 1 )) && seconds=1
    if [[ "$FM_WEV_KIND" == "none" ]]; then
        sleep "$seconds"
        return 1
    fi
    local line status before left deadline
    deadline=$(( ${EPOCHREALTIME/./} + seconds * 1000000 ))
    _fm_wev_flags; before=$_FM_WEV_SNAP
    while :; do
        left=$(( deadline - ${EPOCHREALTIME/./} ))
        (( left < 1000 )) && return 1
        printf -v left '%d.%06d' $((left / 1000000)) $((left % 1000000))
        status=0
        IFS= read -r -t "$left" -u "$FM_WEV_FD" line || status=$?
        if (( status == 0 )); then
            fm_wev_classify "$line"
            fm_wev_drain
            _fm_wev_flags
            [[ "$_FM_WEV_SNAP" != "$before" ]] && return 0
            continue
        fi
        if (( status > 128 )); then
            # timeout (142) or interrupt
            return 1
        fi
        # Descriptor closed or error -> fallback
        FM_WEV_KIND="none"
        sleep "$left"
        return 1
    done
}

# Stop monitor and clean up.
fm_wev_stop() {
    if [[ -n "$FM_WEV_MON_PID" ]]; then
        kill "$FM_WEV_MON_PID" 2>/dev/null || true
        FM_WEV_MON_PID=""
    fi
    _fm_wev_close_fd
    FM_WEV_KIND="none"
}