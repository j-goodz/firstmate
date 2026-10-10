#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-spawn-rate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-rate-helpers.sh"

sr_init fm-spawn-rate-snapshot

# Case 1: status snapshot over 20 tasks
for n in {1..20}; do
    printf 'working [at=1]: x\n' > "${FM_STATE_OVERRIDE}/task${n}.status"
done

sr_reset

# Capture output of status_presentation_snapshot
output=$(sr_run $'
    source "$1/bin/fm-classify-lib.sh"
    : > "$FM_FORK_LOG"
    status_presentation_snapshot "$FM_STATE_OVERRIDE"
' "$SR_ROOT")

line_count=0
task1_ident=""

while IFS=$'\t' read -r task size ident; do
    ((line_count++))
    if [[ ! $task =~ ^task[0-9]+$ ]]; then
        echo "Unexpected task field: $task" >&2
        exit 1
    fi
    num=${task#task}
    if [[ $size -ne 18 ]]; then
        echo "Size mismatch for $task: expected 18, got $size" >&2
        exit 1
    fi
    file="${FM_STATE_OVERRIDE}/${task}.status"
    dev_inode=$(stat -c '%d:%i' "$file")
    if [[ $ident == "weak:$dev_inode" ]] || [[ $ident == strong:"$dev_inode":* ]]; then
        :
    else
        echo "Ident mismatch for $task: expected weak:$dev_inode or strong:$dev_inode:*, got $ident" >&2
        exit 1
    fi
    if [[ $num -eq 1 ]]; then
        task1_ident=$ident
    fi
done <<< "$output"

if [[ $line_count -ne 20 ]]; then
    echo "Expected 20 lines, got $line_count" >&2
    exit 1
fi

sr_assert_budget "status snapshot of 20 tasks" "$(sr_count)" 42

# Case 2: identity string unchanged
ident2=$(sr_run $'
    source "$1/bin/fm-classify-lib.sh"
    _fm_open_decisions_file_ident "$2"
' "$SR_ROOT" "${FM_STATE_OVERRIDE}/task1.status")

if [[ $ident2 != "$task1_ident" ]]; then
    echo "Identity string changed: expected $task1_ident, got $ident2" >&2
    exit 1
fi

printf '# fm-spawn-rate-snapshot: done\n'