#!/usr/bin/env bash
# Blocking, non-destructive delta read for a remote secondmate append-only log.
#
# Usage:
#   fm-remote-delta-read.sh <relative-log> <offset> <prefix-sha256> [wait-seconds]
#
# The reader validates continuity by hashing the exact prefix represented by the
# caller's cursor. It then blocks until at least one complete appended line is
# available, returns at most 65536 payload bytes, and never truncates or consumes
# the source. A shortened or changed prefix returns a structured continuity-break
# result instead of silently rebasing the cursor.
#
# The wait is event-driven. Where inotifywait exists, one monitor process feeds
# a FIFO and the reader blocks in the read builtin until the log changes, so an
# idle long-poll spawns nothing. Without inotifywait it falls back to a once per
# second wake that compares the log's mtime with a reference file using shell
# builtins, which also spawns nothing, and records the fallback in
# FM_REMOTE_DELTA_FALLBACK_LOG. Either way the capture and hashing pipeline runs
# only after the log's mtime has moved.
#
# Exit 75 means the wait window closed with no complete line. SIGTERM exits the
# same way after cleanup. The remote job worker preempts this read-only poll to
# unblock any queued command other than another reply long-poll, then publishes
# that preemption as distinct exit 76. The bin/fm-remote-job-lib.sh header owns
# that contract.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_BYTES=${FM_REMOTE_DELTA_MAX_BYTES:-65536}
FALLBACK_LOG=${FM_REMOTE_DELTA_FALLBACK_LOG:-$FM_HOME/state/event-wait-fallback.log}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool is available"
  fi
}

copy_prefix() { # <file> <bytes> <destination>
  if [ "$2" -eq 0 ]; then
    : > "$3"
  else
    head -c "$2" "$1" > "$3"
  fi
}

snapshot_log() { # <file> <destination> <size-file>
  local file=$1 destination=$2 size_file=$3 parent base actual_parent
  parent=$(dirname "$file")
  base=$(basename "$file")
  (
    CDPATH='' cd -- "$parent" 2>/dev/null || exit 1
    actual_parent=$(pwd -P) || exit 1
    [ "$actual_parent" = "$parent" ] || exit 1
    perl -MFcntl=:DEFAULT -e '
      my ($path, $destination, $size_file, $offset, $max_bytes) = @ARGV;
      sysopen(my $source, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
      my @stat = stat $source or exit 1;
      exit 1 unless -f _;
      my $size = $stat[7];
      exit 1 unless $size =~ /\A\d+\z/;
      my $limit = $size;
      my $bound = $offset + $max_bytes;
      $limit = $bound if $limit > $bound;
      open(my $output, ">", $destination) or exit 1;
      binmode $source;
      binmode $output;
      my $remaining = $limit;
      while ($remaining > 0) {
        my $wanted = $remaining > 65536 ? 65536 : $remaining;
        my $read = read($source, my $buffer, $wanted);
        exit 1 unless defined $read && $read > 0;
        print {$output} $buffer or exit 1;
        $remaining -= $read;
      }
      close $output or exit 1;
      open(my $size_output, ">", $size_file) or exit 1;
      print {$size_output} "$size\n" or exit 1;
      close $size_output or exit 1;
    ' "$base" "$destination" "$size_file" "$OFFSET" "$MAX_BYTES"
  )
}

resolve_log() { # <relative-path>
  local rel=$1 home_real parent_real parent base path
  case "$rel" in ''|/*|*'//'*) die "log must be a nonempty relative path" ;; esac
  case "/$rel/" in */../*|*/./*) die "log traversal is not allowed: $rel" ;; esac
  case "$rel" in *$'\n'*|*$'\r'*|*$'\t'*) die "log path contains control characters" ;; esac
  home_real=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
  parent=$(dirname "$rel")
  base=$(basename "$rel")
  parent_real=$(CDPATH='' cd -- "$FM_HOME/$parent" 2>/dev/null && pwd -P) || die "log parent is unavailable: $rel"
  case "$parent_real" in "$home_real"|"$home_real"/*) ;; *) die "log escapes FM_HOME: $rel" ;; esac
  path="$parent_real/$base"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || die "log is not a non-symlink regular file: $rel"
  fi
  printf '%s\n' "$path"
}

emit_break() { # <reason> <size> <actual-prefix>
  printf 'schema=fm-remote-delta.v1\n'
  printf 'status=continuity-broken\n'
  printf 'path=%s\n' "$REL"
  printf 'from_offset=%s\n' "$OFFSET"
  printf 'to_offset=%s\n' "$2"
  printf 'from_prefix_sha256=%s\n' "$PREFIX"
  printf 'to_prefix_sha256=%s\n' "$3"
  printf 'payload_sha256=%s\n' "$EMPTY_HASH"
  printf 'payload_bytes=0\n'
  printf 'reason=%s\n\n' "$1"
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
REL=$1
OFFSET=$2
PREFIX=$3
WAIT=${4:-55}
case "$OFFSET" in ''|*[!0-9]*) die "offset must be a nonnegative integer" ;; esac
case "$PREFIX" in *[!A-Fa-f0-9]*|'') die "prefix-sha256 must be hexadecimal" ;; esac
[ "${#PREFIX}" -eq 64 ] || die "prefix-sha256 must be 64 hexadecimal characters"
PREFIX=$(printf '%s' "$PREFIX" | tr 'A-F' 'a-f')
case "$WAIT" in ''|*[!0-9]*) die "wait-seconds must be a nonnegative integer" ;; esac
[ "$WAIT" -le 300 ] || die "wait-seconds exceeds the 300-second safety bound"
case "$MAX_BYTES" in ''|*[!0-9]*|0) die "FM_REMOTE_DELTA_MAX_BYTES must be a positive integer" ;; esac
[ "$MAX_BYTES" -le 1048576 ] || die "FM_REMOTE_DELTA_MAX_BYTES exceeds the safety bound"

LOG=$(resolve_log "$REL")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-delta.XXXXXX") || die "cannot create delta staging directory"
MON_PID=
trap 'if [ -n "$MON_PID" ]; then kill "$MON_PID" 2>/dev/null || true; fi; rm -rf -- "$TMP"' EXIT
trap 'exit 75' TERM
: > "$TMP/empty"
EMPTY_HASH=$(sha256_file "$TMP/empty")
START=$SECONDS

# The anonymous FIFO the waiter blocks on; unlinked at once so nothing is left behind.
EVENT_FD=
if mkfifo "$TMP/events" 2>/dev/null && { exec 9<>"$TMP/events"; } 2>/dev/null; then
  EVENT_FD=9
fi
rm -f -- "$TMP/events"
IDLE_WAKES=0
COARSE_MTIME=1
[ "$(uname -s 2>/dev/null || true)" != Linux ] || COARSE_MTIME=0

# The log watch is a single long-lived process that writes one line to the FIFO
# per change. inotifywait is used where it exists. Where it does not (swift and
# zentop), python3 calls the kernel's inotify through ctypes. Anything else falls
# back to the builtin mtime check.
INOTIFY_PY='
import ctypes, ctypes.util, os, select, sys
libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
fd = libc.inotify_init()
mask = 0x2 | 0x4 | 0x8 | 0x400 | 0x800  # modify attrib close_write delete_self move_self
if fd < 0 or libc.inotify_add_watch(fd, os.fsencode(sys.argv[1]), mask) < 0:
    sys.exit(1)
parent = os.getppid()
while True:
    ready, _, _ = select.select([fd], [], [], 5)
    if ready:
        os.read(fd, 65536)
        os.write(1, b".\n")
        # delete_self and move_self end the watch: exit so the reader re-arms.
        if not os.path.exists(sys.argv[1]):
            sys.exit(0)
    if os.getppid() != parent:
        sys.exit(0)
'
MONITOR_KIND=
MONITOR_STARTS=0
if [ -n "$EVENT_FD" ] && [ -z "${FM_REMOTE_DELTA_NO_INOTIFY:-}" ] && [ "$COARSE_MTIME" -eq 0 ]; then
  if [ -z "${FM_REMOTE_DELTA_NO_INOTIFYWAIT:-}" ] && command -v inotifywait >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    MONITOR_KIND=inotifywait
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import ctypes, ctypes.util' >/dev/null 2>&1; then
    MONITOR_KIND=python
  fi
fi
if [ -z "$MONITOR_KIND" ]; then
  [ ! -d "${FALLBACK_LOG%/*}" ] || [ -s "$FALLBACK_LOG" ] \
    || printf 'fm-remote-delta-read: no inotifywait, python3 inotify or FIFO; waiting with a once-per-second builtin mtime check\n' >> "$FALLBACK_LOG" 2>/dev/null || true
fi

# One watch process on the log. It is restarted when the log is replaced and
# the old watch ends, at most five times; after that the reader degrades to the
# builtin mtime check so a watch that cannot start never becomes a respawn loop.
start_monitor() {
  [ -n "$MONITOR_KIND" ] || return 0
  [ -f "$LOG" ] && [ ! -L "$LOG" ] || return 0
  if [ -n "$MON_PID" ] && kill -0 "$MON_PID" 2>/dev/null; then return 0; fi
  if [ "$MONITOR_STARTS" -ge 5 ]; then
    MONITOR_KIND=
    printf 'fm-remote-delta-read: the log watch kept ending; waiting with a once-per-second builtin mtime check\n' >> "$FALLBACK_LOG" 2>/dev/null || true
    return 0
  fi
  MONITOR_STARTS=$((MONITOR_STARTS + 1))
  if [ "$MONITOR_KIND" = inotifywait ]; then
    timeout "$((WAIT + 5))" inotifywait -m -q -e modify,close_write,attrib,move_self,delete_self \
      --format . "$LOG" >&9 2>/dev/null < /dev/null &
  else
    python3 -c "$INOTIFY_PY" "$LOG" >&9 2>/dev/null < /dev/null &
  fi
  MON_PID=$!
}

# True when the log's mtime still equals the reference taken before the last
# capture, so nothing can have been appended since. A filesystem with coarse
# timestamps gets a full recheck every 30 idle wakes.
log_unchanged() {
  [ -f "$TMP/ref" ] && [ ! "$LOG" -nt "$TMP/ref" ] && [ ! "$LOG" -ot "$TMP/ref" ] || return 1
  if [ "$COARSE_MTIME" -eq 1 ] && [ "$IDLE_WAKES" -ge 30 ]; then
    IDLE_WAKES=0
    return 1
  fi
  return 0
}

wait_for_event() {
  start_monitor
  if [ -z "$EVENT_FD" ]; then
    sleep 1
  else
    read -r -t 1 -u 9 _ || true
  fi
  IDLE_WAKES=$((IDLE_WAKES + 1))
}

while :; do
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then
    [ -f "$LOG" ] && [ ! -L "$LOG" ] || die "log changed into an unsafe file: $REL"
    if log_unchanged; then
      [ $((SECONDS - START)) -lt "$WAIT" ] || exit 75
      wait_for_event
      continue
    fi
    # The reference is taken before the capture, so an append that lands during
    # or after it makes the log newer than the reference and is seen next pass.
    touch -r "$LOG" "$TMP/ref" 2>/dev/null || rm -f -- "$TMP/ref"
    start_monitor
    snapshot_log "$LOG" "$TMP/source" "$TMP/size" \
      || die "log could not be captured safely: $REL"
    SIZE=$(tr -d ' ' < "$TMP/size")
    if [ "$SIZE" -lt "$OFFSET" ]; then
      copy_prefix "$TMP/source" "$SIZE" "$TMP/prefix"
      ACTUAL=$(sha256_file "$TMP/prefix")
      emit_break truncated "$SIZE" "$ACTUAL"
      exit 0
    fi
    copy_prefix "$TMP/source" "$OFFSET" "$TMP/prefix"
    ACTUAL=$(sha256_file "$TMP/prefix")
    if [ "$ACTUAL" != "$PREFIX" ]; then
      emit_break prefix-changed "$SIZE" "$ACTUAL"
      exit 0
    fi
    if [ "$SIZE" -gt "$OFFSET" ]; then
      tail -c "+$((OFFSET + 1))" "$TMP/source" | head -c "$MAX_BYTES" > "$TMP/chunk" || true
      COMPLETE_BYTES=$(LC_ALL=C od -An -v -tu1 "$TMP/chunk" | awk '
        { for (i = 1; i <= NF; i++) { bytes++; if ($i == 10) complete=bytes } }
        END { print complete + 0 }
      ')
      if [ "$COMPLETE_BYTES" -eq 0 ]; then : > "$TMP/payload"; else head -c "$COMPLETE_BYTES" "$TMP/chunk" > "$TMP/payload"; fi
      BYTES=$(LC_ALL=C wc -c < "$TMP/payload" | tr -d ' ')
      if [ "$BYTES" -gt 0 ]; then
        TO=$((OFFSET + BYTES))
        copy_prefix "$TMP/source" "$TO" "$TMP/to-prefix"
        TO_HASH=$(sha256_file "$TMP/to-prefix")
        PAYLOAD_HASH=$(sha256_file "$TMP/payload")
        printf 'schema=fm-remote-delta.v1\n'
        printf 'status=delta\n'
        printf 'path=%s\n' "$REL"
        printf 'from_offset=%s\n' "$OFFSET"
        printf 'to_offset=%s\n' "$TO"
        printf 'from_prefix_sha256=%s\n' "$PREFIX"
        printf 'to_prefix_sha256=%s\n' "$TO_HASH"
        printf 'payload_sha256=%s\n' "$PAYLOAD_HASH"
        printf 'payload_bytes=%s\n' "$BYTES"
        printf 'reason=\n\n'
        cat "$TMP/payload"
        exit 0
      fi
      if [ $((SIZE - OFFSET)) -ge "$MAX_BYTES" ]; then
        emit_break line-exceeds-bound "$SIZE" "$ACTUAL"
        exit 0
      fi
    fi
  elif [ "$OFFSET" -ne 0 ] || [ "$PREFIX" != "$EMPTY_HASH" ]; then
    emit_break missing 0 "$EMPTY_HASH"
    exit 0
  fi
  [ $((SECONDS - START)) -lt "$WAIT" ] || exit 75
  wait_for_event
done
