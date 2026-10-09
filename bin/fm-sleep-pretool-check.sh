#!/usr/bin/env bash
set -u

# fm-sleep-pretool-check.sh
#
# This script guards crew workers from using sleep-poll waits.
# It is wired by bin/fm-spawn.sh into the per-task .claude/settings.local.json of Claude crew workers only (never the primary).
#
# Usage: fm-sleep-pretool-check.sh [--claude] [--task <id>] [--count] [--help]
#   --claude          indicate that the caller is Claude (suppress stdout output)
#   --task <id>       specify the task ID (optional)
#   --count           print the number of denials logged and exit
#   -h, --help        display this help message
#
# Exit codes:
#   0 - ALLOW (no output)
#   2 - DENY (output as described)
#   0 - FAIL OPEN (no output)
#
# Claude requires stdout to remain empty on deny.

usage() {
  cat <<'EOF'
Usage: fm-sleep-pretool-check.sh [--claude] [--task <id>] [--count] [--help]
  --claude          indicate that the caller is Claude (suppress stdout output)
  --task <id>       specify the task ID (optional)
  --count           print the number of denials logged and exit
  -h, --help        display this help message
Denies a sleep longer than 30 s and any until/while sleep poll loop; run long waits with run_in_background and end your turn.
EOF
}

# Default log path
LOG=${FM_SLEEP_GUARD_LOG:-${HOME:-/tmp}/.nexus/sleep-guard-denials.jsonl}

# Argument parsing
CLAUDE=0
TASK=""
COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude)
      CLAUDE=1
      shift
      ;;
    --task)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "error: --task requires a value" >&2
        exit 2
      fi
      TASK="$2"
      shift 2
      ;;
    --task=*)
      TASK="${1#--task=}"
      shift
      ;;
    --count)
      COUNT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Handle --count
if [[ $COUNT -eq 1 ]]; then
  if [[ -f "$LOG" ]]; then
    COUNT_LINES=$(wc -l < "$LOG")
  else
    COUNT_LINES=0
  fi
  echo "$COUNT_LINES"
  exit 0
fi

# Read stdin payload
PAYLOAD=$(cat 2>/dev/null || true)
if [[ -z "$PAYLOAD" ]]; then
  exit 0
fi

# Ensure jq is available
command -v jq >/dev/null 2>&1 || exit 0

# Extract tool name and command
TOOL_NAME=$(echo "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null || true)
CMD=$(echo "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

if [[ -z "$TOOL_NAME" || -z "$CMD" ]]; then
  exit 0
fi

if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

# Source classification library
LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/fm-sleep-classify-lib.sh"
if [[ ! -f "$LIB_PATH" ]]; then
  exit 0
fi
# shellcheck source=bin/fm-sleep-classify-lib.sh
. "$LIB_PATH"

# Classify the command
fm_sleep_classify "$CMD"

# If no classification, allow
if [[ -z "$CODE" ]]; then
  exit 0
fi

# Build reason string
if [[ "$CODE" == "sleep-poll-loop" ]]; then
  DURATION="a sleep inside an until/while polling loop"
elif [[ -z "$SLEEP_SECONDS" || "$SLEEP_SECONDS" == "null" ]]; then
  DURATION="an unbounded sleep"
else
  DURATION="sleep ${SLEEP_SECONDS}s"
fi

REASON="[sleep-poll] $CODE: $DURATION. Sleep-poll waits are banned for crew workers, because the turn is blocked and the worker's context burns while it waits. Run the long command with run_in_background (or with a bounded timeout) and then end your turn."

# Log denial
log_denial() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  if [[ -z "$SLEEP_SECONDS" || "$SLEEP_SECONDS" == "null" ]]; then
    SECONDS_JSON="null"
  else
    SECONDS_JSON="$SLEEP_SECONDS"
  fi
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg task "$TASK" \
        --arg code "$CODE" \
        --argjson seconds "$SECONDS_JSON" \
        --arg command "${CMD:0:200}" \
        '{ts:$ts,task:$task,code:$code,seconds:$seconds,command:$command}' \
    >> "$LOG" 2>/dev/null || true
}
log_denial

# JSON escape helper
json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(printf '%s' "$REASON" | json_escape)

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2

if [[ $CLAUDE -eq 0 ]]; then
  printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
fi

exit 2