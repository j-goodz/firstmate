#!/usr/bin/env bash
# bin/fm-fanout-check.sh (adoption check for the FreeLLMAPI fan-out build method)
#
# Usage: bin/fm-fanout-check.sh <task-id> [--pr-url <url>] [--body-file <path>]
#        bin/fm-fanout-check.sh --help      (prints usage, exit 0)
#
# Purpose: after a build lane lands, report whether its code was written by free models through
# scripts/free_direct_fanout.py. A recorded check, never a gate: it exits 0 for any valid
# invocation, whatever the verdict. Exit 2 only for bad usage (no task id, unknown option,
# option missing its value).
#
# Paths (same convention as the other bin scripts):
#   FM_HOME            default: the repository root that contains this script's bin/ directory
#   STATE              ${FM_STATE_OVERRIDE:-$FM_HOME/state}
#   DATA               ${FM_DATA_OVERRIDE:-$FM_HOME/data}
#   units ledger       ${FM_FANOUT_LEDGER:-$HOME/.nexus/fanout-units.jsonl}   (read only)
#   adoption ledger    $DATA/fanout-adoption.jsonl                            (append one line per run)
#
# Run ids: strings matching the extended regex  fr-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}
# Collect them, distinct, in first-seen order, from these sources:
#   1. $STATE/<task-id>.status, if the file exists
#   2. --body-file <path>, if given and readable
#   3. when --pr-url is given and --body-file is not: the PR body from
#      `gh pr view <url> --json body --jq .body` (wrap in `timeout 20` when timeout exists;
#      any failure, including gh missing, is silently ignored and yields no ids)
#
# Units ledger rows are JSON lines with at least: run_id, label, outcome. Outcome values that
# matter: "check_passed" and "free_exhausted". Blank or malformed lines are ignored.
# A unit is a distinct (run_id, label) pair. Only rows whose run_id is one of the collected
# run ids count.
#
# Verdict, decided in this order:
#   no-runs         no run id was found anywhere
#   missing-ledger  run ids were found but the units ledger file does not exist or is unreadable
#   yes             at least one unit has a check_passed row
#   no              run ids found, ledger readable, but zero units have a check_passed row
# units = number of distinct (run_id,label) pairs with outcome check_passed (0 for no-runs and missing-ledger)
# paid_step_ups = number of distinct (run_id,label) pairs with outcome free_exhausted
#                 (0 for no-runs and missing-ledger)
#
# Output:
#   stdout, exactly one line:
#     fanout-check: <task-id> free_written=<yes|no> verdict=<verdict> units=<n> paid_step_ups=<m> runs=<comma-separated run ids, or - when none>
#   free_written is "yes" only when verdict is "yes", otherwise "no".
#   stderr, only when verdict is not "yes", exactly one line starting with
#     WARNING: fanout-check: 
#   followed by a short human reason (for no-runs: that the lane recorded no fan-out run ids,
#   so the standard build method was not evidenced).
#   Appends one compact JSON object per invocation to $DATA/fanout-adoption.jsonl (create DATA if
#   missing) with keys: ts (integer epoch seconds), at (UTC ISO-8601 with trailing Z), task,
#   free_written (JSON boolean), verdict, units (number), paid_step_ups (number),
#   runs (JSON array of strings), pr (the --pr-url value or ""). Build the JSON with jq -n.
#   If the adoption ledger cannot be written, print a WARNING line to stderr and still exit 0.
#
# The script never modifies the units ledger or the status file. Plain bash, set -eu, uses jq,
# passes shellcheck. Starts with a header comment block that doubles as --help text (lines
# starting with # after the shebang, printed by --help the way bin/fm-brief.sh's usage() does).

set -eu

# Determine FM_HOME: the repository root that contains this script's bin/ directory
FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
UNITS_LEDGER="${FM_FANOUT_LEDGER:-$HOME/.nexus/fanout-units.jsonl}"

# Parse arguments
TASK_ID=""
PR_URL=""
BODY_FILE=""

while (( "$#" )); do
  case "$1" in
    --help)
      # Print the header comment block (lines starting with # after the shebang)
      awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
      exit 0
      ;;
    --pr-url)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --pr-url requires an argument" >&2
        exit 2
      fi
      PR_URL="$2"
      shift 2
      ;;
    --body-file)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --body-file requires an argument" >&2
        exit 2
      fi
      BODY_FILE="$2"
      shift 2
      ;;
    --*)
      echo "ERROR: unknown option $1" >&2
      exit 2
      ;;
    *)
      if [[ -z "$TASK_ID" ]]; then
        TASK_ID="$1"
        shift
      else
        echo "ERROR: unexpected argument $1" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: missing required task-id" >&2
  exit 2
fi

# Collect run ids
run_ids=()
seen=()

# 1. $STATE/<task-id>.status
status_file="$STATE/$TASK_ID.status"
if [[ -f "$status_file" ]]; then
  while IFS= read -r id; do
    if ! [[ " ${seen[*]} " == *" $id "* ]]; then
      seen+=("$id")
      run_ids+=("$id")
    fi
  done < <(grep -oE 'fr-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}' "$status_file" || true)
fi

# 2. --body-file
if [[ -n "$BODY_FILE" && -r "$BODY_FILE" ]]; then
  while IFS= read -r id; do
    if ! [[ " ${seen[*]} " == *" $id "* ]]; then
      seen+=("$id")
      run_ids+=("$id")
    fi
  done < <(grep -oE 'fr-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}' "$BODY_FILE" || true)
fi

# 3. --pr-url (only if --body-file not given)
if [[ -n "$PR_URL" && -z "$BODY_FILE" ]]; then
  pr_body=""
  if command -v timeout >/dev/null 2>&1; then
    pr_body=$(timeout 20 gh pr view "$PR_URL" --json body --jq .body 2>/dev/null || true)
  else
    pr_body=$(gh pr view "$PR_URL" --json body --jq .body 2>/dev/null || true)
  fi
  if [[ -n "$pr_body" ]]; then
    while IFS= read -r id; do
      if ! [[ " ${seen[*]} " == *" $id "* ]]; then
        seen+=("$id")
        run_ids+=("$id")
      fi
    done < <(echo "$pr_body" | grep -oE 'fr-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}' || true)
  fi
fi

# Build JSON array of run_ids (used later for ledger and verdict logic)
if [[ ${#run_ids[@]} -eq 0 ]]; then
  run_ids_json='[]'
else
  run_ids_json=$(printf '%s\n' "${run_ids[@]}" | jq -R . | jq -s .)
fi

# Determine verdict and counts
verdict="no-runs"
units=0
paid_step_ups=0

if [[ ${#run_ids[@]} -eq 0 ]]; then
  verdict="no-runs"
else
  if [[ ! -r "$UNITS_LEDGER" ]]; then
    verdict="missing-ledger"
  else
    # Process ledger with jq to count distinct (run_id, label) pairs per outcome
    counts=$(jq -R 'fromjson? | select(type=="object")' "$UNITS_LEDGER" \
      | jq --argjson ids "$run_ids_json" '
          select(.run_id as $rid | ($ids | index($rid)) != null)
          | {run_id, label, outcome}
        ' \
      | jq -s '
          group_by(.run_id, .label)
          | map({
              run_id: .[0].run_id,
              label: .[0].label,
              has_check_passed: any(.outcome == "check_passed"),
              has_free_exhausted: any(.outcome == "free_exhausted")
            })
          | {
              units: (map(select(.has_check_passed)) | length),
              paid_step_ups: (map(select(.has_free_exhausted)) | length)
            }
        ')
    units=$(echo "$counts" | jq -r '.units')
    paid_step_ups=$(echo "$counts" | jq -r '.paid_step_ups')

    if [[ $units -gt 0 ]]; then
      verdict="yes"
    else
      verdict="no"
    fi
  fi
fi

# Determine free_written
if [[ "$verdict" == "yes" ]]; then
  free_written="yes"
  free_written_json=true
else
  free_written="no"
  free_written_json=false
fi

# Build runs string for stdout
if [[ ${#run_ids[@]} -eq 0 ]]; then
  runs_display="-"
else
  runs_display=$(IFS=','; echo "${run_ids[*]}")
fi

# Output to stdout
echo "fanout-check: $TASK_ID free_written=$free_written verdict=$verdict units=$units paid_step_ups=$paid_step_ups runs=$runs_display"

# Output warning to stderr if verdict is not yes
if [[ "$verdict" != "yes" ]]; then
  case "$verdict" in
    no-runs)
      reason="the lane recorded no fan-out run ids, so the standard build method was not evidenced"
      ;;
    missing-ledger)
      reason="the units ledger file is missing or unreadable"
      ;;
    no)
      reason="run ids found but zero units have a check_passed row"
      ;;
    *)
      reason="unknown verdict"
      ;;
  esac
  echo "WARNING: fanout-check: $reason" >&2
fi

# Append to adoption ledger
mkdir -p "$DATA"

ts=$(date +%s)
at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
pr_value="${PR_URL:-""}"

# Build JSON with jq -n -c (compact)
json=$(jq -nc \
  --argjson ts "$ts" \
  --arg at "$at" \
  --arg task "$TASK_ID" \
  --argjson free_written "$free_written_json" \
  --arg verdict "$verdict" \
  --argjson units "$units" \
  --argjson paid_step_ups "$paid_step_ups" \
  --argjson runs "$run_ids_json" \
  --arg pr "$pr_value" \
  '{ts: $ts, at: $at, task: $task, free_written: $free_written, verdict: $verdict, units: $units, paid_step_ups: $paid_step_ups, runs: $runs, pr: $pr}')

if ! echo "$json" >> "$DATA/fanout-adoption.jsonl"; then
  echo "WARNING: fanout-check: failed to write adoption ledger" >&2
fi

exit 0
