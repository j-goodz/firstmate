#!/usr/bin/env bash
# helper-process budget helpers for the fm-spawn-rate tests

[ -z "${FM_SPAWN_RATE_LIB_SOURCED:-}" ] || return 0
FM_SPAWN_RATE_LIB_SOURCED=1

sr_init() {
    local name="$1"
    SR_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
    TMP_ROOT=$(fm_test_tmproot "$name")
    mkdir -p "$TMP_ROOT"
    TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
    SR_SHIM_BIN="$TMP_ROOT/shim-bin"
    SR_FORK_LOG="$TMP_ROOT/fork.log"
    : > "$SR_FORK_LOG"
    export FM_FORK_LOG="$SR_FORK_LOG"
    # Record original PATH before we modify it
    SR_ORIG_PATH=$PATH
    # Real counting tools
    SR_REAL_WC=$(command -v wc)
    SR_REAL_TR=$(command -v tr)
    # Create shim bin directory
    mkdir -p "$SR_SHIM_BIN"
    # List of tools to shim
    local tool
    for tool in cat dirname basename tr jq uname stat readlink rm rmdir mktemp ln date sed awk head tail cut grep wc od mv chmod mkdir sort sleep id git; do
        local real
        real=$(command -v "$tool" 2>/dev/null) || continue
        # Skip if not an absolute path (should be)
        [[ "$real" = /* ]] || continue
        local shim_path="$SR_SHIM_BIN/$tool"
        cat > "$shim_path" <<EOF
#!/bin/bash
printf '%s\n' "$tool" >> "\$FM_FORK_LOG"
exec "$real" "\$@"
EOF
        chmod +x "$shim_path"
    done
    # Create home/state directory with mode 700
    mkdir -p "$TMP_ROOT/home/state"
    chmod 700 "$TMP_ROOT/home/state"
    # Export overrides
    export FM_ROOT_OVERRIDE="$SR_ROOT"
    export FM_HOME="$TMP_ROOT/home"
    export FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
    export CLAUDE_PROJECT_DIR="$SR_ROOT"
    # Trap cleanup on exit
    trap fm_test_cleanup EXIT
}

sr_reset() {
    : > "$SR_FORK_LOG"
}

sr_count() {
    "$SR_REAL_WC" -l < "$SR_FORK_LOG" | "$SR_REAL_TR" -d ' '
}

sr_run() {
    local body="$1"
    shift
    env PATH="$SR_SHIM_BIN:$PATH" bash -c "$body" _ "$@"
}

sr_assert_budget() {
    local label="$1"
    local used="$2"
    local budget="$3"
    if (( used > budget )); then
        # Print tally of the log to stderr using original PATH to avoid shims
        {
            env PATH="$SR_ORIG_PATH" sort "$SR_FORK_LOG" |
            env PATH="$SR_ORIG_PATH" uniq -c |
            env PATH="$SR_ORIG_PATH" sort -rn
        } >&2
        fail "$label spawned $used helper processes (budget $budget)"
    else
        pass "$label: $used helpers (budget $budget)"
    fi
}