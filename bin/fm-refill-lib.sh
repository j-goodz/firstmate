# shellcheck shell=bash

# refill_log <decision> <task> <project> <backlog_id> <filled> <reason>
refill_log() {
    local decision="$1" task="$2" project="$3" backlog_id="$4" filled="$5" reason="$6"
    local ts host slots ready dry_run
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    host=$(hostname -s)
    slots=${SLOTS_N:-0}
    ready=${READY_N:-0}
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        dry_run=true
    else
        dry_run=false
    fi
    local jq_args=(--arg ts "$ts" --arg host "$host" --arg decision "$decision" --arg slots "$slots" --arg ready "$ready" --argjson dry_run "$dry_run" --arg task "$task" --arg project "$project" --arg backlog_id "$backlog_id" --arg filled "$filled" --arg reason "$reason")
    local json
    json=$(jq -nc "${jq_args[@]}" '
        {ts: $ts, host: $host, decision: $decision, slots: ($slots|tonumber), ready: ($ready|tonumber), dry_run: $dry_run}
        + (if $task != "" then {task: $task} else {} end)
        + (if $project != "" then {project: $project} else {} end)
        + (if $backlog_id != "" then {backlog_id: $backlog_id} else {} end)
        + (if $filled != "" then {filled: ($filled|tonumber)} else {} end)
        + {reason: $reason}
    ')
    if [[ -n "${REFILL_LOG:-}" ]]; then
        mkdir -p "$(dirname "$REFILL_LOG")" 2>/dev/null || true
        printf '%s\n' "$json" >> "$REFILL_LOG" 2>/dev/null || true
    fi
}

# refill_registry_scope
refill_registry_scope() {
    if [[ -f "${PROJECTS_FILE:-}" ]]; then
        grep -E '^- [^ ]+ \[' "$PROJECTS_FILE" 2>/dev/null | sed -E 's/^- ([^ ]+) \[.*/\1/'
    fi
}

# refill_project_flags <project>
refill_project_flags() {
    local project="$1"
    if [[ -f "${PROJECTS_FILE:-}" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "- $project ["* ]]; then
                local flags
                flags=${line#*[}
                flags=${flags%%]*}
                echo "$flags"
                break
            fi
        done < "$PROJECTS_FILE"
    fi
}

# refill_project_mode <project>
refill_project_mode() {
    local flags
    flags=$(refill_project_flags "$1")
    if [[ "$flags" == *"direct-PR"* ]]; then
        echo "direct-PR"
    elif [[ "$flags" == *"local-only"* ]]; then
        echo "local-only"
    else
        echo "no-mistakes"
    fi
}

# refill_project_yolo <project>
refill_project_yolo() {
    local flags
    flags=$(refill_project_flags "$1")
    for flag in $flags; do
        if [[ "$flag" == "+yolo" ]]; then
            echo "on"
            return
        fi
    done
    echo "off"
}

# refill_load_ready <ready-file-or-empty>
refill_load_ready() {
    local source="$1"
    local output
    if [[ -n "$source" ]]; then
        if [[ ! -r "$source" ]]; then
            return 1
        fi
        output=$(cat "$source")
    else
        if ! output=$(fm_run_timed "${READY_TIMEOUT:-25}" bash -c "${READY_CMD:-nexus task list --status open --ready --mode auto --json}" 2>/dev/null); then
            return 1
        fi
    fi
    local ready_array
    ready_array=$(echo "$output" | jq -c 'if type == "object" and has("ready") and (.ready|type=="array") then .ready elif type == "array" then . else error("invalid") end' 2>/dev/null) || return 1
    echo "$ready_array"
}

# refill_filter <scope-csv>
refill_filter() {
    local scope="$1"
    local jq_program
    jq_program=$(cat <<'EOF'
def scope: ($scope | split(",") | map(select(length > 0)));
def not_to_build: "do not build (this|it|yet|until|before|anything)|don'?t build (this|it|yet|until|before)|(^|\\n)\\s*spec[- ]first\\b|spec[- ]first (then|before|and then)\\b|needs? (a )?spec first|spec before (the )?build|(build|do|dispatch|start) (it |this )?later\\b|not ready to build|(^|\\n)\\s*later\\s*:";
.[] | select(
  .mode == "auto" and
  (.type == "bug" or .type == "chore" or .type == "feature") and
  (.tier == null or .tier == "" or .tier == "sonnet" or .tier == "free-direct" or .tier == "swarm") and
  .status == "open" and
  (.claimed_by == null or .claimed_by == "") and
  (.project as $p | scope | index($p) != null) and
  ((.body // "") | test(not_to_build; "i") | not)
)
EOF
)
    jq -c --arg scope "$scope" "$jq_program"
}