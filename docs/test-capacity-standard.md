# Test capacity standard

This is the standard method for running tests and choosing which machine takes a lane.
A task may name a per-task exception in its Firstmate spec, and nothing else overrides it.
It exists because six lanes each ran a whole suite at once on one 12-CPU machine and its load reached 31.

## Tests

1. A lane runs only the tests its change affects.
   The firstmate repo uses `bin/fm-test-run.sh --changed`, nexus uses `NEXUS_GATE_SCOPE=1 ./run-tests.sh`, and a repo with no picker uses the test files that name the changed modules.
2. A failure that looks unrelated is checked by running that one test file on main in a detached checkout under the lane's scratch directory.
   A lane never runs a whole suite on main and never compares a whole-suite result with main.
3. The broader run happens once per change, in the validation step of the delivery mode (the no-mistakes test step).
   Only a change to shared test or library code widens the selection.
4. Every whole-suite run goes through `bin/fm-suite-slot.sh run`, and `bin/fm-test-run.sh --all` does so itself.

`bin/fm-brief.sh` puts these rules in the "Test method (the standard method)" section of every ship and scout brief.

## Suite slots

A suite slot is one permitted whole-suite run on a machine.
All homes and worktrees on a machine share the same slots, so runs queue instead of stacking.
`bin/fm-suite-slot.sh` is the gate, and its header owns the mechanics.

| Machine | Logical CPUs | Slots | Why |
|---|---:|---:|---|
| homelab | 12 | 2 | one slot per six CPUs |
| swift | 8 | 1 | one slot per six CPUs, and its heat gate stays in force |
| VPS (cloud-server) | 4 | 0 | it runs live services and takes light work only |

The default is one slot per six logical CPUs, rounded down, so a machine under six CPUs gets none.
Temperature lowers it: at or above `hot_c` one slot, at or above `hold_c` none, read through `bin/fm-host-temp.sh`.
Available memory below 600 MB admits no new run, the same floor nexus's gate admission uses.
A caller waits for a slot up to three hours, then gets exit code 75, and a machine with zero slots refuses at once.
The machine file `~/.config/firstmate/suite-slots` overrides the defaults, and [configuration.md](configuration.md#suite-slots-configfirstmatesuite-slots) owns its keys.
nexus keeps its own memory admission in `run-tests.sh`, and the slot gate is the layer across repos.

## Placement

Before routing a heavy lane, run `bin/fm-place.sh`.
It probes this machine and every machine that hosts a registered second mate, then ranks them by load per logical CPU, temperature, memory, and free suite slots.
Heavy work (a build or a whole-suite run) needs a machine with slots, no heat hold or hot tier, enough free memory, and load per CPU under 1.0.
Light work (investigation, docs, small pull requests) only needs load per CPU under 1.0, or under 0.5 on a machine with no suite slots.
Ties go to the first registered machine, then to the local one.
The script only reports, and firstmate routes the lane to the machine it names.

`bin/fm-spawn.sh` enforces this on the VPS (cloud-server, 8 GB RAM, hosts named by `FM_LIGHT_ONLY_HOSTS`, detected with `hostname -s` or the `FM_SELF_HOST` test seam).
A fresh ship spawn there is refused with a message naming swift and `bin/fm-place.sh --class heavy`, so the lane must be routed to a machine with slots.
Scouts, secondmates and relaunches stay allowed, and the only override is `FM_VPS_HEAVY_OK=OPERATOR_APPROVED` in the environment of that one spawn.
`bin/fm-brief.sh` also adds `--workers 2` to the fan-out step of a ship brief written on such a machine.
`bin/fm-vps-guard-lib.sh` owns the rules.

## Daily full run

Each configured repo gets one whole-suite run a day in the quiet hours, so lanes never need one.
`bin/fm-suite-daily.sh dispatch` fires from a timer on homelab at 03:30 ET (up to 15 minutes later) and asks `bin/fm-place.sh` for the machine.
That machine runs the repo's configured command on a detached checkout of origin/main, inside a suite slot, niced, with a two-hour limit.
A machine with no suite slots, such as the VPS, takes the run only when its load is under 0.25 per CPU, and any machine skips and logs when it is hot, short of memory, busy, or already running that repo's suite.
Runs of one repo are serialised by a per-key lock, and a checkout left by a killed run is swept before the next one starts.
Each run appends a line to `~/.nexus/suite-daily.jsonl` on the machine that ran it, and the dispatcher logs which machine took it.
A failure is posted once to #issues, keyed on the commit and the failing set.
Each machine lists the repos it can run in `~/.config/firstmate/suite-daily`, and [configuration.md](configuration.md#daily-suite-run-configfirstmatesuite-daily) owns the format.

## Not set up yet

- zentop (Linux ultrabook, 24 logical CPUs, 30 GB): needs a firstmate checkout, a registered second mate home, a `config/thermal-gate` of one worker with `hot_c` near 70 and `hold_c` near 80, and a machine file with `slots=1` and the same limits, set before its default of four slots could apply. Its fan reached full speed on 2026-10-02, so run a 30-minute heat test first and start with light work only.
- legion (the captain's Windows working machine): runs no second mate, windows, or builds. The only fit is free-model calls over HTTP, which need no local CPU, so there is nothing to install.
- Project gates: each repo's pre-push or test step should call `bin/fm-suite-slot.sh run` for its whole-suite path. `bin/fm-test-run.sh --all` already does.
