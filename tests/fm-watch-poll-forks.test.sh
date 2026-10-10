#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-poll-forks)
cd -P "$TMP_ROOT"

cleanup() {
    fm_test_cleanup
}
trap cleanup EXIT

# Probe strace availability
PROBE_LOG="$TMP_ROOT/probe.log"
if ! strace -f -qq -e trace=clone,clone3,fork,vfork -o "$PROBE_LOG" bash -c '(:)' 2>/dev/null; then
    echo "# SKIP: strace unusable here, fork budget not measured"
    exit 0
fi
if ! grep -q 'clone' "$PROBE_LOG" 2>/dev/null; then
    echo "# SKIP: strace unusable here, fork budget not measured"
    exit 0
fi

LOG="$TMP_ROOT/forks.log"

count_forks() {
    local log="$1"
    local from="$2"
    local to="$3"
    awk -v from="$from" -v to="$to" '
        /<unfinished/ { next }
        /CLONE_THREAD/ { next }
        {
            # Field 2 is the timestamp with -ttt
            ts = $2
            if (ts >= from && ts < to) {
                # Match completed fork/clone/vfork calls: = <positive integer>
                if (($0 ~ /(clone3?|fork|vfork)\(/) || ($0 ~ /<\.\.\. (clone3?|fork|vfork) resumed>/)) {
                    if ($0 ~ /= [0-9]+$/) {
                        count++
                    }
                }
            }
        }
        END { print count+0 }
    ' "$log"
}

make_home() {
    local home="$1"
    mkdir -p "$home/state" "$home/config" "$home/fakebin" "$home/cap" "$home/claims"
    local now
    now=$(date +%s)
    for i in {1..10}; do
        local wt="$home/wt$i"
        mkdir -p "$wt"
        cat > "$home/state/t$i.meta" <<EOF
window=test:fm-t$i
kind=ship
backend=tmux
harness=claude
worktree=$wt
EOF
        if (( i <= 5 )); then
            cat > "$home/state/t$i.status" <<EOF
working [at=$((now - 5000))]: started
paused [at=$((now - 4000))]: waiting on upstream release
EOF
        else
            cat > "$home/state/t$i.status" <<EOF
working [at=$((now - 5000))]: started
EOF
        fi
        local key="test_fm-t$i"
        cat > "$home/cap/$key.txt" <<EOF
pane $i idle content
> 
EOF
        local hash
        hash=$(printf '%s' "$(cat "$home/cap/$key.txt")" | md5sum | cut -d' ' -f1)
        echo "$hash" > "$home/state/.hash-$key"
        echo "5" > "$home/state/.count-$key"
        echo "$hash" > "$home/state/.stale-$key"
        echo "$now" > "$home/state/.stale-since-$key"
    done

    cat > "$home/fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    list-windows)
        for i in {1..10}; do echo "fm-t$i"; done
        ;;
    capture-pane)
        prev=""
        target=""
        for arg in "$@"; do
            if [[ "$prev" == "-t" ]]; then
                target="$arg"
                break
            fi
            prev="$arg"
        done
        if [[ -n "$target" ]]; then
            key=${target//:/_}
            key=${key//./_}
            if [[ -f "$FM_FAKE_CAP_DIR/$key.txt" ]]; then
                cat "$FM_FAKE_CAP_DIR/$key.txt"
            fi
        fi
        exit 0
        ;;
    display-message)
        if [[ "$*" == *"pane_current_command"* ]]; then
            echo "claude"
        fi
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$home/fakebin/tmux"

    cat > "$home/fakebin/fm-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
echo "state: unknown · source: none · fake"
exit 0
EOF
    chmod +x "$home/fakebin/fm-crew-state.sh"
}

run_watcher() {
    local home="$1"
    local seconds="$2"
    local log="$3"
    local env_args=(
        PATH="$home/fakebin:$PATH"
        FM_FAKE_CAP_DIR="$home/cap"
        FM_STATE_OVERRIDE="$home/state"
        FM_HOME="$home"
        FM_CONFIG_OVERRIDE="$home/config"
        FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh"
        FM_ROOT_OVERRIDE="$ROOT"
        FM_POLL=3
        FM_SIGNAL_GRACE=1
        FM_STALE_ESCALATE_SECS=99999999
        FM_PAUSE_RESURFACE_SECS=99999999
        FM_CHECK_INTERVAL=999999
        FM_HEARTBEAT=999999
        FM_PROCEVENT_CLAIM_ROOT="$home/claims"
        FM_WATCH_HANDLING_SUCCESSOR=1
    )
    if [[ "$log" == "-" ]]; then
        timeout "$seconds" env "${env_args[@]}" bash "$ROOT/bin/fm-watch.sh" >"$home/out.txt" 2>&1
    else
        timeout "$seconds" strace -f -qq -ttt -e trace=clone,clone3,fork,vfork -o "$log" \
            env "${env_args[@]}" bash "$ROOT/bin/fm-watch.sh" >"$home/out.txt" 2>&1
    fi
    return $?
}

HOME_DIR="$TMP_ROOT/home"
make_home "$HOME_DIR"

# Settle the home
for attempt in {1..4}; do
    : > "$HOME_DIR/out.txt"
    run_watcher "$HOME_DIR" 20 -
    status=$?
    if [[ $status -eq 124 ]]; then
        break
    fi
    : > "$HOME_DIR/state/.wake-queue"
    if [[ $attempt -eq 4 ]]; then
        fail "home never settled; out.txt: $(head -c 500 "$HOME_DIR/out.txt")"
    fi
done

# Measurement run
: > "$HOME_DIR/out.txt"
run_watcher "$HOME_DIR" 26 "$LOG"
status=$?

# Get start timestamp from first line of log
start_ts=$(awk 'NR==1 {print $2}' "$LOG")
if [[ -z "$start_ts" ]]; then
    fail "strace log empty or malformed"
fi

window_from=$(awk -v s="$start_ts" 'BEGIN {printf "%.6f", s + 8}')
window_to=$(awk -v s="$start_ts" 'BEGIN {printf "%.6f", s + 26}')

forks=$(count_forks "$LOG" "$window_from" "$window_to")
passes=6
per_pass=$(( (forks + passes - 1) / passes ))

# Calculate per-second at default 15s cadence
per_sec=$(awk -v pp="$per_pass" 'BEGIN {printf "%.1f", pp / 15}')

echo "# forks: $forks in 18s (6 polls) = $per_pass per poll, $per_sec per second at the default 15s cadence"

if [[ -n "$(grep -v 'Terminated' "$HOME_DIR/out.txt")" ]]; then
    fail "watcher produced output during idle measurement (fixture not steady): $(head -c 500 "$HOME_DIR/out.txt")"
fi

budget="${FM_WATCH_FORK_BUDGET_PER_POLL:-75}"
if [[ "$per_pass" -gt "$budget" ]]; then
    fail "fm-watch.sh forked $per_pass processes per poll with 10 tasks (budget $budget = 5 forks/second at the 15s default cadence)"
else
    pass "an idle watcher with 10 tasks stays under 75 forks per poll"
fi
