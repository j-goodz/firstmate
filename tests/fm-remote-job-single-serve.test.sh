#!/usr/bin/env bash
# Test for fm-remote-job-worker.sh single-serve contract.
# Verifies that at most one --serve loop runs per queue directory.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-single-serve)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

REMOTE_ROOT="$TMP_ROOT/remote-root"
ACCOUNT_HOME="$TMP_ROOT/account"
REMOTE_HOME="$TMP_ROOT/remote-home"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT_HOME" "$REMOTE_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$REMOTE_ROOT/bin/"
cp "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'EOF'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
EOF
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm fixture

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=30
export FM_REMOTE_JOB_TIMEOUT=30
export FM_REMOTE_JOB_SERVE_GUARD_WAIT_SECONDS=2
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

WORKER_A_PID=
WORKER_B_PID=
SERVE_PID=

start_serve() {
    HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve >> "$1" 2>&1 &
    SERVE_PID=$!
}

wait_exit() {
    local pid=$1
    local max_tenths=$2
    local i=0
    while (( i < max_tenths )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        ((i++))
    done
    return 1
}

cleanup_fixture() {
    if [[ -n "${WORKER_A_PID:-}" ]]; then
        kill -CONT "$WORKER_A_PID" 2>/dev/null || true
        kill -KILL "$WORKER_A_PID" 2>/dev/null || true
    fi
    if [[ -n "${WORKER_B_PID:-}" ]]; then
        kill -CONT "$WORKER_B_PID" 2>/dev/null || true
        kill -KILL "$WORKER_B_PID" 2>/dev/null || true
    fi
    fm_test_cleanup
}
trap cleanup_fixture EXIT

# Case 1 - a second serving loop exits and leaves a running job alone
start_serve "$TMP_ROOT/a.log"
WORKER_A_PID=$SERVE_PID
i=0
while (( i < 100 )); do
    if [[ -e "$STATE_ROOT/worker.ready" ]]; then
        break
    fi
    sleep 0.1
    ((i++))
done
if (( i >= 100 )); then
    fail "worker.ready never appeared"
fi
A_LOCK_PID=$(cat "$STATE_ROOT/worker.lock/pid")
assert_equals "$WORKER_A_PID" "$A_LOCK_PID" "lock pid matches worker A"

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-delay-job.sh 4 "$TMP_ROOT/job-ran" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
i=0
while (( i < 100 )); do
    if [[ "$(fm_remote_job_read_state "$JOB_DIR")" = "running" ]]; then
        break
    fi
    sleep 0.1
    ((i++))
done
if (( i >= 100 )); then
    fail "job did not reach running state"
fi

start_serve "$TMP_ROOT/b.log"
WORKER_B_PID=$SERVE_PID
assert_equals 0 "$(wait_exit "$WORKER_B_PID" 300; echo $?)" "second worker exits within 30s"
set +e
wait "$WORKER_B_PID"
B_RC=$?
set -e
assert_equals 0 "$B_RC" "second worker exit code is 0"

kill -0 "$WORKER_A_PID" || fail "worker A died"
assert_equals "$WORKER_A_PID" "$(cat "$STATE_ROOT/worker.lock/pid")" "lock pid unchanged"
assert_equals "$WORKER_A_PID" "$(cat "$STATE_ROOT/worker.pid")" "worker.pid unchanged"

fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
assert_equals 0 "$FM_REMOTE_JOB_EXIT" "job exit code is 0"
assert_present "$TMP_ROOT/job-ran" "job output file exists"
if grep -F -q "stopped before this job completed" "$FM_REMOTE_JOB_STDERR"; then
    fail "stderr contains 'stopped before this job completed'"
fi
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID"

pass "a second serving loop exits and leaves a running job and the ownership lock alone"

# Case 2 - a stale heartbeat and an unverifiable lock record do not let a second serving loop take over
kill -STOP "$WORKER_A_PID"
touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
rm -f "$STATE_ROOT/worker.lock/start" "$STATE_ROOT/worker.lock/command"

start_serve "$TMP_ROOT/c.log"
WORKER_B_PID=$SERVE_PID
assert_equals 0 "$(wait_exit "$WORKER_B_PID" 400; echo $?)" "contender gives up within 40s"
set +e
wait "$WORKER_B_PID"
B_RC=$?
set -e

assert_equals "$WORKER_A_PID" "$(cat "$STATE_ROOT/worker.lock/pid")" "stalled owner kept lock"
assert_equals "$WORKER_A_PID" "$(cat "$STATE_ROOT/worker.pid")" "worker.pid unchanged"

kill -CONT "$WORKER_A_PID"
pass "a stale heartbeat and an unverifiable lock record do not let a second serving loop take over"

echo "ALL TESTS PASSED"