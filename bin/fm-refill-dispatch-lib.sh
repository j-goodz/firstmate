# shellcheck shell=bash
# fm-refill-dispatch-lib.sh - dispatch one refill task
# Provides refill_dispatch_one

refill_dispatch_one() {
  local row="$1"
  local id title project body
  id=$(jq -r '.id' <<<"$row") || return 1
  title=$(jq -r '.title' <<<"$row") || return 1
  project=$(jq -r '.project' <<<"$row") || return 1
  body=$(jq -r '.body // ""' <<<"$row") || return 1

  local bid="nx-${id:0:8}"
  local mode yolo
  mode=$(refill_project_mode "$project") || return 1
  yolo=$(refill_project_yolo "$project") || return 1

  # Step 1: Claim in nexus
  if ! fm_run_timed 30 "$NEXUS_BIN" task claim "$id" >/dev/null 2>&1; then
    refill_log "claim_failed" "$id" "$project" "$bid" "" "claim failed"
    return 1
  fi

  # Step 2: tasks add
  if ! fm_run_timed 30 "$TASKS_BIN" add "$bid" "$title (nexus $id)" --kind ship --repo "$project" --body "Nexus task $id. mode=$mode yolo=$yolo." >/dev/null 2>&1; then
    refill_log "prepare_failed" "$id" "$project" "$bid" "" "tasks add failed"
    return 1
  fi

  # Step 3: brief
  if ! fm_run_timed 30 "$BRIEF_BIN" "$bid" "$project" --mode "$mode" >/dev/null 2>&1; then
    refill_log "prepare_failed" "$id" "$project" "$bid" "" "brief failed"
    return 1
  fi

  # Step 4: Fill brief file
  local brief_file="$FM_HOME/data/$bid/brief.md"
  local intent spec
  intent=$(printf "Build nexus task %s (project %s) as written in its record:\n\n%s\n\n%s\n" "$id" "$project" "$title" "$body")
  spec=$(printf "Nexus task %s is reserved for you by firstmate. Your first action after creating your branch: run nexus task claim %s --steal from inside your worktree so the claim binds to your worktree. Close it with the landed commit and tests when merged. Test first from the task text: write the tests before the code and cover the failure paths. Run only the tests your change affects, never a whole suite. Surgical diffs: do not rewrite files or remove existing functionality. Stay inside the project named above." "$id" "$id")

  local tmpfile="${brief_file}.tmp"
  export INTENT="$intent"
  export SPEC="$spec"

  # Exists receipt
  local exists_out
  if ! exists_out=$(fm_run_timed 180 "$NEXUS_BIN" exists "$title" 2>/dev/null); then
    refill_log "prepare_failed" "$id" "$project" "$bid" "" "exists command failed"
    return 1
  fi
  local receipt_line
  receipt_line=$(echo "$exists_out" | grep '^EXISTS-RECEIPT' | tail -n1)
  if [[ -z "$receipt_line" ]]; then
    refill_log "prepare_failed" "$id" "$project" "$bid" "" "no exists receipt"
    return 1
  fi
  export RECEIPT="$receipt_line"

  # Replace placeholders and insert receipt with awk
  if ! awk '
    { gsub(/\{TASK\}/, ENVIRON["INTENT"]); gsub(/\{FIRSTMATE_SPEC\}/, ENVIRON["SPEC"]); print }
    /spawn verifies it against the nexus ledger\.$/ && !done {
      print ENVIRON["RECEIPT"]
      done=1
    }
  ' "$brief_file" >"$tmpfile"; then
    refill_log "prepare_failed" "$id" "$project" "$bid" "" "brief fill failed"
    return 1
  fi

  if ! mv "$tmpfile" "$brief_file"; then
    refill_log "prepare_failed" "$id" "$project" "$bid" "" "brief move failed"
    return 1
  fi

  # Step 5: Profile
  local profile_args=()
  if [[ -x "$RESOLVE_BIN" ]]; then
    local resolve_out
    if resolve_out=$(fm_run_timed 30 "$RESOLVE_BIN" "$brief_file" --project "$project" 2>/dev/null); then
      local profile_line
      profile_line=$(echo "$resolve_out" | grep '^profile: ' | tail -n1)
      if [[ -n "$profile_line" ]]; then
        local args_str="${profile_line#profile: }"
        read -ra profile_args <<<"$args_str"
      fi
    fi
  fi
  if [[ ${#profile_args[@]} -eq 0 ]]; then
    profile_args=(--harness "$HARNESS" --model "$MODEL" --effort "$EFFORT")
  fi

  # Step 6: Spawn
  local projdir
  if [[ "$project" == "firstmate" ]]; then
    projdir="$FM_HOME"
  else
    projdir="$FM_HOME/projects/$project"
  fi

  if ! fm_run_timed 240 "$SPAWN_BIN" "$bid" "$projdir" --mode "$mode" --yolo "$yolo" "${profile_args[@]}" >/dev/null 2>&1; then
    refill_log "spawn_failed" "$id" "$project" "$bid" "" "spawn failed"
    return 1
  fi

  # Success
  refill_log "dispatched" "$id" "$project" "$bid" "" ""
  echo "dispatched $id $project as $bid"
  return 0
}