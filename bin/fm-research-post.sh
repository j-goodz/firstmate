#!/usr/bin/env bash
# shellcheck source=bin/fm-timeout-lib.sh

# fm-research-post.sh - Post a finished scout/secondmate report to #research channel exactly once.
#
# Purpose:
#   This script posts a finished report to the #research channel by calling the helper
#   `nexus research-post submit` (or a custom command). It ensures each task id is posted
#   only once, logs outcomes to a JSONL file, and never builds the card text itself.
#
# Paths:
#   SCRIPT_DIR   Directory of this script (derived from BASH_SOURCE).
#   FM_HOME      Parent of SCRIPT_DIR (default; can be overridden with FM_HOME env var).
#   STATE        $FM_STATE_OVERRIDE or $FM_HOME/state.
#   DATA         $FM_DATA_OVERRIDE or $FM_HOME/data.
#   Report       Default: $DATA/<task-id>/report.md.
#   Posted-ids   $STATE/research-post.posted (one id per line).
#   Log          $STATE/research-post.jsonl (one JSON object per line).
#
# Environment variables:
#   FM_STATE_OVERRIDE    Override state directory.
#   FM_DATA_OVERRIDE     Override data directory.
#   FM_RESEARCH_POST_CMD Helper command (default: "nexus research-post submit").
#   FM_RESEARCH_POST_TIMEOUT Timeout in seconds (default: 60).
#
# Log format:
#   Each line is a JSON object with keys: ts, task, source, outcome, rc, latency_ms, error.
#   No spaces after colons or commas. Example:
#   {"ts":"2026-10-09T15:00:00Z","task":"t1","source":"scout","outcome":"ok","rc":0,"latency_ms":12,"error":""}
#
# Exit codes:
#   0  Success or non-fatal condition (no report, duplicate, dry-run).
#   1  Helper command failed (non-zero exit code).
#   2  Usage error (missing task id, unknown option, invalid task id).
#
# Callers such as bin/fm-teardown.sh must treat any failure as non-fatal.

set -u
set -o pipefail

# Determine paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(dirname "$SCRIPT_DIR")}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
POSTED_FILE="$STATE/research-post.posted"
LOG_FILE="$STATE/research-post.jsonl"

# Ensure state directory exists
mkdir -p "$STATE"

# Source fm_run_timed
# shellcheck source=bin/fm-timeout-lib.sh
source "$SCRIPT_DIR/fm-timeout-lib.sh"

# Default values
SOURCE="scout"
REPORT=""
TITLE=""
DRY_RUN=0
TIMEOUT="${FM_RESEARCH_POST_TIMEOUT:-60}"
HELPER_CMD="${FM_RESEARCH_POST_CMD:-nexus research-post submit}"

# Usage function
usage() {
    cat <<EOF
Usage: fm-research-post.sh <task-id> [--source scout] [--report PATH] [--title TITLE] [--dry-run]
       fm-research-post.sh --help
EOF
}

# JSON escape function
json_escape() {
    local s
    # Escape backslash and double quote using sed
    s=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    # Remove control characters except tab, newline, carriage return
    s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
    # Replace tab, newline, carriage return with escaped versions
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    printf '%s' "$s"
}

# Log function
log_entry() {
    local outcome="$1"
    local rc="$2"
    local latency_ms="$3"
    local error="$4"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local escaped_error
    escaped_error=$(json_escape "$error")
    printf '{"ts":"%s","task":"%s","source":"%s","outcome":"%s","rc":%s,"latency_ms":%s,"error":"%s"}\n' \
        "$ts" "$TASK_ID" "$SOURCE" "$outcome" "$rc" "$latency_ms" "$escaped_error" >> "$LOG_FILE" || true
}

# Parse arguments
TASK_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            usage
            exit 0
            ;;
        --source)
            if [[ $# -lt 2 ]]; then
                echo "Error: --source requires a value" >&2
                usage >&2
                exit 2
            fi
            SOURCE="$2"
            shift 2
            ;;
        --report)
            if [[ $# -lt 2 ]]; then
                echo "Error: --report requires a value" >&2
                usage >&2
                exit 2
            fi
            REPORT="$2"
            shift 2
            ;;
        --title)
            if [[ $# -lt 2 ]]; then
                echo "Error: --title requires a value" >&2
                usage >&2
                exit 2
            fi
            TITLE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -*)
            echo "Error: unknown option $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -z "$TASK_ID" ]]; then
                TASK_ID="$1"
            else
                echo "Error: unexpected argument $1" >&2
                usage >&2
                exit 2
            fi
            shift
            ;;
    esac
done

# Check task id provided
if [[ -z "$TASK_ID" ]]; then
    echo "Error: missing task id" >&2
    usage >&2
    exit 2
fi

# Validate task id
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$TASK_ID" == .* ]]; then
    echo "Error: invalid task id" >&2
    usage >&2
    exit 2
fi

# Set default report path
if [[ -z "$REPORT" ]]; then
    REPORT="$DATA/$TASK_ID/report.md"
fi

# Step 1: Check report file exists
if [[ ! -f "$REPORT" ]]; then
    log_entry "no-report" 0 0 ""
    echo "No report file at $REPORT" >&2
    exit 0
fi

# Step 2: Check duplicate
if [[ -f "$POSTED_FILE" ]] && grep -Fxq "$TASK_ID" "$POSTED_FILE"; then
    log_entry "duplicate" 0 0 ""
    exit 0
fi

# Step 3: Determine title
if [[ -z "$TITLE" ]]; then
    # Extract first line starting with "# "
    TITLE=$(grep -m1 '^# ' "$REPORT" | sed 's/^# //')
    if [[ -z "$TITLE" ]]; then
        TITLE="$TASK_ID"
    fi
fi

# Step 4: Dry-run
if [[ $DRY_RUN -eq 1 ]]; then
    log_entry "dry-run" 0 0 ""
    exit 0
fi

# Step 5: Run helper
# Split helper command into array
read -r -a CMD_ARRAY <<< "$HELPER_CMD"

# Create temp file for stderr
stderr_file=$(mktemp)

# Record start time
start=$(date +%s%N)

# Run helper with timeout
fm_run_timed "$TIMEOUT" "${CMD_ARRAY[@]}" --source "$SOURCE" --path "$REPORT" --title "$TITLE" --json > /dev/null 2> "$stderr_file"
rc=$?

# Record end time
end=$(date +%s%N)
latency_ms=$(( (end - start) / 1000000 ))

# Read stderr (first 200 chars)
stderr_output=$(head -c 200 "$stderr_file" 2>/dev/null || true)
# Clean up temp file
rm -f "$stderr_file"

# Step 6: Handle result
if [[ $rc -eq 0 ]]; then
    # Append id to posted file
    echo "$TASK_ID" >> "$POSTED_FILE"
    log_entry "ok" "$rc" "$latency_ms" ""
    exit 0
else
    # Failure
    log_entry "error" "$rc" "$latency_ms" "$stderr_output"
    # Print warning to stderr (first 200 chars of helper stderr)
    if [[ -n "$stderr_output" ]]; then
        echo "Warning: helper command failed (rc=$rc): $stderr_output" >&2
    else
        echo "Warning: helper command failed (rc=$rc)" >&2
    fi
    exit 1
fi