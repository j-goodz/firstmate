# Live spawn matrix: what the agent process actually started with

Every row was driven through the real `bin/fm-spawn.sh` (and, for the relaunch rows,
`bin/fm-control.sh <id> relaunch`) against a **real tmux server** on an isolated socket
(`tmux -L fm-cachemode-lab`), in a throwaway Firstmate home under `/tmp`. The recorded value is
what the launched agent process itself printed from its own environment at start, not a reading of
the launch text.

Every lab tmux session carried a contrary ambient `NEXUS_CACHE_MODE=auto` in its session
environment, so a worker that simply inherited the machine default would have shown `auto`.

| Case | Spawn | Allowlist | Agent env at start | Expected |
|---|---|---|---|---|
| ship-absent | crewmate, `--mode no-mistakes --yolo off` | absent | `NEXUS_CACHE_MODE=off` | off |
| scout-absent | `--scout` | absent | `NEXUS_CACHE_MODE=off` | off |
| ship-enabled | crewmate | enabled (`/usr/bin/env -i`) | `NEXUS_CACHE_MODE=off` | off |
| ship-raw | crewmate, raw `cd <dir> && ./probe` | absent | `NEXUS_CACHE_MODE=off` | off |
| ship-relaunch2 | crewmate, then `fm-control.sh <id> relaunch` | absent | `off` on both incarnations | off |
| secondmate-absent | `--secondmate` | absent | `NEXUS_CACHE_MODE=auto` | ambient kept |
| secondmate-enabled | `--secondmate` | enabled | `NEXUS_CACHE_MODE=<unset>` | not `off` |
| sm-relaunch2 | `--secondmate`, then relaunch | absent | `auto` on both incarnations | ambient kept |

Captain (brain) session, read in the same tmux session that spawned the ship-absent worker:

```
captain session NEXUS_CACHE_MODE=auto
```

The brain keeps its cycling value while its workers are excluded, which is the split the change
exists to create.

## How the exclusion is delivered under an enabled allowlist

`delivered-launch-allowlist-enabled.txt` is the exact staged launch file the worker pane sourced
for `ship-enabled`. `NEXUS_CACHE_MODE` does not appear anywhere in the `/usr/bin/env -i` floor
list, and the exclusion arrives through the launch command's own export inside the cleared
environment:

```
/usr/bin/env -i ${HOME+"HOME=$HOME"} ... COMPACT_ADVISER_DISABLE=1 /bin/sh -c 'export COMPACT_ADVISER_DISABLE=1; export NEXUS_CACHE_MODE=off; env -u CURSOR_AGENT ... codex ...'
```

## Lab substitutions (what was faked, and what was not)

Faked: the `treehouse` worktree allocator (a shim that puts the pane in a real git worktree of a
throwaway `/tmp` project, so the operator's real treehouse pool is never touched) and the `codex`
binary (a bash copy named `codex-agent`, which the real classifier in
`bin/fm-agent-process-lib.sh` reads as a live codex agent, prints the environment it was started
with, renders an empty codex composer row, and exits on the real `/quit` exit command).

Not faked: `bin/fm-spawn.sh`, `bin/fm-control.sh`, the tmux backend, the tmux server, the pane,
the launch staging and delivery, the allowlist filtering, and the agent process's own environment.
