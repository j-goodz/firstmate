#!/usr/bin/env bash
# bin/fm-fanout-check.sh (adoption check for the FreeLLMAPI fan-out build method)
#
# Usage: bin/fm-fanout-check.sh <task-id> [--pr-url <url>]
#        bin/fm-fanout-check.sh <task-id> [--pr-url <url>] --gate
#        bin/fm-fanout-check.sh --help      (prints usage, exit 0)
#
# Purpose: after a build lane lands, report whether its code was written by free models through
# scripts/free_direct_fanout.py. A recorded check by default, a gate only with --gate: without
# --gate it exits 0 for any valid invocation, whatever the verdict. With --gate the script
# becomes a refusal check: it exits 1 and prints `REFUSED: fanout-gate: ...` lines on stderr
# when the lane has no run ids, an unreadable units ledger, a unit whose last terminal outcome
# is free_exhausted (unless a later free check_passed unit labelled
# "<parent label>--<suffix>" in the lane split it, or a LATER collected run, later by the row's
# `at` timestamp, has a check_passed unit with the same label on a free model; a retry that
# passed on a paid model or was exhausted again does not clear it), or a check_passed unit whose producing model (served_model, else
# requested_model) is not free; it appends nothing to the adoption ledger and prints no
# WARNING. Exit 2 only for bad usage (no task id, unknown option, option missing its value).
#
# Paths (same convention as the other bin scripts):
#   FM_HOME            default: the repository root that contains this script's bin/ directory
#   STATE              ${FM_STATE_OVERRIDE:-$FM_HOME/state}
#   DATA               ${FM_DATA_OVERRIDE:-$FM_HOME/data}
#   units ledger       ${FM_FANOUT_LEDGER:-$HOME/.nexus/fanout-units.jsonl}   (read only)
#   ranked free models ${FM_FANOUT_MODELS:-$HOME/.nexus/free-coding-models.json} (read only)
#   adoption ledger    $DATA/fanout-adoption.jsonl                            (append one line per run)
#
# Run ids: strings matching the extended regex  fr-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}
# Collect them, distinct, in first-seen order, from these sources:
#   1. $STATE/<task-id>.status, if the file exists
#   2. when --pr-url is given: the PR body from
#      `gh pr view <url> --json body --jq .body`, hard-bounded by fm_run_timed
#      (bin/fm-timeout-lib.sh); any failure, including gh missing or the bound
#      expiring, is silently ignored and yields no ids.
#      From the PR body, only the line starting `Fan-out runs:` is scanned.
#
# Units ledger rows are JSON lines with at least: run_id, label, outcome, requested_model.
# Outcome values that matter: "check_passed" and "free_exhausted". Blank or malformed lines
# are ignored. A unit is a distinct (run_id, label) pair. Only rows whose run_id is one of the
# collected run ids count.
#
# Free vs paid test (shared by report mode and gate mode): a model name is free when it ends in
# ":free", is in the ranked list in $FM_FANOUT_MODELS (plus the engine's seed fallback and
# "auto"), or becomes so after its first path segment is removed (a router prefix such as kilo/
# or openrouter/). Report mode and gate mode share one test: a check_passed row is free when
# served_model passes, or when requested_model passes and served_model is the same model
# once a router prefix is stripped, or once both names have their first path segment
# stripped and are compared case-insensitively (requested openai/gpt-oss-20b served
# ovh/gpt-oss-20b, requested qwen/qwen3.8-27b served ovh/Qwen3.8-27B); a different served
# model, or a requested model that is not free, is paid. A requested "auto" counts as free
# because "auto" is in the seed list: free-direct only reaches the free chain. A split unit
# that resolves a free_exhausted parent uses the same test.
#
# Verdict, decided in this order:
#   no-runs         no run id was found anywhere
#   missing-ledger  run ids were found but the units ledger file does not exist or is unreadable
#   yes             at least one unit is free-written (see units) and zero paid step-ups
#   mixed           at least one unit is free-written and some paid step-ups were needed
#   no              run ids found, ledger readable, but zero units are free-written
# units = number of distinct (run_id,label) pairs whose final terminal row is a check_passed row
#         that passes the free test above (0 for no-runs and missing-ledger)
# paid_step_ups = number of distinct (run_id,label) pairs whose final terminal outcome is
#                 free_exhausted and that no later free check_passed unit cleared (a later run's
#                 unit with the same label, or a unit labelled "<label>--<suffix>"): exactly the
#                 units gate mode reports as unresolved (0 for no-runs and missing-ledger)
# A unit written by a paid model also turns a would-be yes into mixed.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# Determine FM_HOME: the repository root that contains this script's bin/ directory
FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
UNITS_LEDGER="${FM_FANOUT_LEDGER:-$HOME/.nexus/fanout-units.jsonl}"
FREE_MODELS_FILE="${FM_FANOUT_MODELS:-$HOME/.nexus/free-coding-models.json}"

# Parse arguments
TASK_ID=""
PR_URL=""
GATE=0

while (( "$#" )); do
  case "$1" in
    --gate)
      GATE=1
      shift
      ;;
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
    -*)
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
    if ! [[ " ${seen[*]:-} " == *" $id "* ]]; then
      seen+=("$id")
      run_ids+=("$id")
    fi
  done < <(grep -oE 'fr-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}' "$status_file" || true)
fi

# 2. --pr-url
if [[ -n "$PR_URL" ]]; then
  pr_body=$(fm_run_timed 20 gh pr view "$PR_URL" --json body --jq .body 2>/dev/null || true)
  if [[ -n "$pr_body" ]]; then
    while IFS= read -r id; do
      if ! [[ " ${seen[*]:-} " == *" $id "* ]]; then
        seen+=("$id")
        run_ids+=("$id")
      fi
    done < <(echo "$pr_body" | grep -E '^[[:space:]]*Fan-out runs:' | grep -oE 'fr-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}' || true)
  fi
fi

# Build JSON array of run_ids (used later for ledger and verdict logic)
if [[ ${#run_ids[@]} -eq 0 ]]; then
  run_ids_json='[]'
else
  run_ids_json=$(printf '%s\n' "${run_ids[@]}" | jq -R . | jq -s .)
fi

gate_exhausted=""
gate_paid=""
# Determine verdict and counts
verdict="no-runs"
units=0
paid_step_ups=0
paid_written=0

if [[ ${#run_ids[@]} -eq 0 ]]; then
  verdict="no-runs"
else
  if [[ ! -r "$UNITS_LEDGER" ]]; then
    verdict="missing-ledger"
  else
    # The engine's own free-model universe: the ranked list, its seed fallback, and "auto".
    if [[ -r "$FREE_MODELS_FILE" ]]; then
      ranked_models=$(jq -r '
        if type == "object" and has("models") then .models else . end
        | if type == "array" then .[] else empty end
        | if type == "string" then . elif type == "object" then .model else empty end
        | select(type == "string" and length > 0)
      ' "$FREE_MODELS_FILE" 2>/dev/null || true)
    else
      ranked_models=""
    fi
    free_models_json=$(
      {
        printf '%s\n' "$ranked_models"
        printf '%s\n' \
          "openai/gpt-oss-120b" \
          "nvidia/nemotron-3-ultra-550b-a55b:free" \
          "dots-studio/dots-3-note-preview:free" \
          "cohere/north-mini-code:free" \
          "codestral-2508" \
          "auto"
      } | jq -R 'select(length > 0)' | jq -s 'unique'
    )

    # Process ledger with jq to count distinct (run_id, label) pairs per outcome. A
    # check_passed unit counts as free-written only when its producing model is free.
    # shellcheck disable=SC2016 # single quotes are intentional: this is jq source
    FREE_JQ_DEF='def isfree($free): if . == null or . == "" then false else . as $m | ($m | endswith(":free")) or (($free | index($m)) != null) or (($m | sub("^[^/]*/"; "")) as $s | $s != $m and ($free | index($s)) != null) end;'
    # One pass decides both report and gate mode, so the two modes cannot disagree on what is free or
    # on which free_exhausted units a later free retry cleared.
    gate_data=$(jq -R 'fromjson? | select(type=="object")' "$UNITS_LEDGER" \
      | jq --argjson ids "$run_ids_json" '
          select(.run_id as $rid | ($ids | index($rid)) != null)
          | {run_id, label, outcome, requested_model, served_model, at}
        ' \
      | jq -s --argjson free "$free_models_json" "$FREE_JQ_DEF"'
          def model: if .served_model != "" and .served_model != null then .served_model else .requested_model end;
          def rowfree: ((.served_model // "") as $sv | (.requested_model // "") as $rq | if $sv == "" then ($rq | isfree($free)) else ($sv | isfree($free)) or (($rq | isfree($free)) and (($rq | sub(":free$"; "")) as $r | ($sv | sub(":free$"; "")) as $s | $s == $r or ($s | endswith("/" + $r)) or (($rq | sub("^[^/]*/"; "") | ascii_downcase) == ($sv | sub("^[^/]*/"; "") | ascii_downcase)))) end);
          . as $rows
          | (reduce range(0; $rows | length) as $i ({};
              $rows[$i] as $row |
              ($row.run_id + "/" + $row.label) as $key |
              if $row.outcome == "check_passed" or $row.outcome == "free_exhausted" then
                .[$key] = ($row + {idx: $i})
              else . end
            ) | to_entries | map(.value)) as $units
          | $units
          | {
              exhausted: (map(select(.outcome == "free_exhausted"))
                | map(select(. as $p | any($units[];
                    .outcome == "check_passed"
                    and rowfree
                    and (
                      (.idx > $p.idx and (.label | startswith($p.label + "--")))
                      or
                      (.label == $p.label
                       and ((.at // "") | type == "string") and (.at // "") != ""
                       and ((($p.at // "")) != "")
                       and .at > $p.at)
                    )) | not))
                | map(.run_id + "/" + .label)),
              paid: (map(select(.outcome == "check_passed"
                  and (rowfree | not)))
                | map(.run_id + "/" + .label + " (" + (if .served_model != "" and .served_model != null then .served_model else .requested_model end) + ")")
                | join(", ")),
              units: (map(select(.outcome == "check_passed" and rowfree)) | length),
              paid_written: (map(select(.outcome == "check_passed" and (rowfree | not))) | length)
            }
        ')
    gate_exhausted=$(echo "$gate_data" | jq -r '.exhausted | join(", ")')
    gate_paid=$(echo "$gate_data" | jq -r '.paid')
    units=$(echo "$gate_data" | jq -r '.units')
    paid_step_ups=$(echo "$gate_data" | jq -r '.exhausted | length')
    paid_written=$(echo "$gate_data" | jq -r '.paid_written')

    if [[ $units -gt 0 ]]; then
      if [[ $paid_step_ups -eq 0 && $paid_written -eq 0 ]]; then
        verdict="yes"
      else
        verdict="mixed"
      fi
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

if [[ $GATE -eq 1 ]]; then
  # Refusal check
  refused=0
  # (a) no run ids
  if [[ ${#run_ids[@]} -eq 0 ]]; then
    echo "REFUSED: fanout-gate: the lane recorded no fan-out run ids" >&2
    refused=1
  fi
  # (a2) run ids exist but ledger missing/unreadable
  if [[ ${#run_ids[@]} -gt 0 && ! -r "$UNITS_LEDGER" ]]; then
    echo "REFUSED: fanout-gate: the units ledger is unreadable" >&2
    refused=1
  fi
  # (b) free_exhausted units
  if [[ -n "$gate_exhausted" ]]; then
    echo "REFUSED: fanout-gate: unit(s) ended free_exhausted: $gate_exhausted" >&2
    refused=1
  fi
  # (c) paid model units
  if [[ -n "$gate_paid" ]]; then
    echo "REFUSED: fanout-gate: unit(s) written by a paid model: $gate_paid" >&2
    refused=1
  fi
  exit $refused
fi

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
      reason="run ids found but zero units are free-written"
      ;;
    mixed)
      reason="free models wrote some units but paid step-ups were needed for others"
      ;;
    *)
      reason="unknown verdict"
      ;;
  esac
  echo "WARNING: fanout-check: $reason" >&2
fi

# Append to adoption ledger
mkdir -p "$DATA" 2>/dev/null || true

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
