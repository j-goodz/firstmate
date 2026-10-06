#!/usr/bin/env bash
set -u

usage() {
    cat <<'EOF'
Usage: fm-wake-absorb-report.sh [--state <dir>] [--since-hours <N>] [--json] [--help]
  --state <dir>       State directory (default: ${FM_STATE_OVERRIDE:-${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/state})
  --since-hours <N>   Only count lines from the last N hours (default: 24, positive integer)
  --json              Output as a single JSON object
  --help              Show this help and exit
EOF
}

STATE_DIR=""
SINCE_HOURS=24
JSON_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            STATE_DIR="$2"
            shift 2
            ;;
        --since-hours)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            if [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "usage: --since-hours requires a positive integer" >&2
                exit 2
            fi
            SINCE_HOURS="$2"
            shift 2
            ;;
        --json)
            JSON_MODE=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "usage: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$STATE_DIR" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    STATE_DIR="${FM_STATE_OVERRIDE:-${FM_HOME:-$(cd "${SCRIPT_DIR}/.." && pwd)}/state}"
fi

LOG_FILE="${STATE_DIR}/wake-absorb.jsonl"

python3 -c "
import sys, json, time, os

log_file = sys.argv[1]
since_hours = int(sys.argv[2])
json_mode = int(sys.argv[3])

cutoff = time.time() - since_hours * 3600

absorbed_events = 0
absorbed_rows = 0
autoack = 0
autoack_failed = 0
autoack_skipped = 0
skipped = {'interrupted': 0, 'no-transcript': 0, 'stale-record': 0, 'bad-record': 0}

if not os.path.exists(log_file) or os.path.getsize(log_file) == 0:
    pass
else:
    with open(log_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = obj.get('ts')
            if not isinstance(ts, (int, float)):
                continue
            if ts < cutoff:
                continue
            event = obj.get('event')
            if event == 'absorbed':
                absorbed_events += 1
                rows = obj.get('rows')
                if isinstance(rows, str) and rows.isdigit():
                    absorbed_rows += int(rows)
                elif isinstance(rows, int):
                    absorbed_rows += rows
            elif event == 'autoack':
                autoack += 1
            elif event == 'autoack-failed':
                autoack_failed += 1
            elif event == 'autoack-skipped':
                autoack_skipped += 1
                reason = obj.get('reason')
                if reason in skipped:
                    skipped[reason] += 1

if json_mode:
    out = {
        'window_hours': since_hours,
        'absorbed_events': absorbed_events,
        'absorbed_rows': absorbed_rows,
        'autoack': autoack,
        'autoack_failed': autoack_failed,
        'autoack_skipped': autoack_skipped,
        'skipped_by_reason': skipped
    }
    print(json.dumps(out))
else:
    print('window_hours: {}'.format(since_hours))
    print('absorbed_events: {}'.format(absorbed_events))
    print('absorbed_rows: {}'.format(absorbed_rows))
    print('autoack: {}'.format(autoack))
    print('autoack_failed: {}'.format(autoack_failed))
    print('autoack_skipped: {}'.format(autoack_skipped))
    print('  interrupted: {}'.format(skipped['interrupted']))
    print('  no-transcript: {}'.format(skipped['no-transcript']))
    print('  stale-record: {}'.format(skipped['stale-record']))
    print('  bad-record: {}'.format(skipped['bad-record']))
" "$LOG_FILE" "$SINCE_HOURS" "$JSON_MODE"