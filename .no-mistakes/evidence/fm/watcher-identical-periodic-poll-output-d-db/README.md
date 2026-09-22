# Live validation - false wedge escalation on a byte-identical periodic poller

Every result below came from running the real `bin/fm-watch.sh` against a real
tmux pane, on an isolated tmux server (`TMUX_TMPDIR` private socket), with real
`state/` records, the real `bin/fm-busy-event.sh` marker writer, the real wake
queue and its drain/acknowledge handshake, and the real supervision loop -
watcher runs, exits on an actionable wake, queue is drained and acknowledged,
watcher is re-armed - exactly as firstmate re-arms after each printed reason.
The operator's own tmux sessions were never touched.

Driver: `live-wedge-lab.sh` (usage in its header).
Knobs used: `FM_STALE_ESCALATE_SECS=20`, `FM_PAUSE_RESURFACE_SECS=25`,
`FM_POLL=1` - the production thresholds compressed so a 150s run covers the
same number of escalation windows a ~40-minute production run would.

## What the pane actually does

`06-live-pane-capture.txt` is a raw tmux capture of the worker pane: the same
three-line `no-mistakes axi status` block, over and over. Its capture hash is
byte-identical across consecutive poll cycles, which is the signal the watcher
treats as a frozen pane.

## Scenarios

| # | File | Scenario | Result |
|---|------|----------|--------|
| 1 | `01-pi-poller-before-after.txt` | Pi-backed worker polling on a fixed cadence, `state/<id>.progress` refreshed each cycle through the real busy-event writer | base commit: 5 false wedge escalations reaching demand-deep-inspection. Target commit: 0 |
| 2 | `02-claude-poller-before-after.txt` | claude-backed provably-working validation worker (the 2026-09-22 incident's own shape), `state/<id>.turn-ended` touched at each turn boundary | base commit: 5 false wedge escalations. Target commit: 0, watcher never exited once in 150s |
| 3 | `03-frozen-still-escalates.txt` | genuinely frozen pane, cursor backend, no harness marker; and a frozen pane carrying a progress marker from an earlier turn | both still escalate: 5 wedge escalations each, with the demand-deep-inspection marker |
| 4 | `04-declared-wait-still-resurfaces.txt` | `paused:` declared wait whose pane keeps polling and keeps refreshing its progress marker | the declared-wait recheck fires three times on its bounded cadence; zero progress-deferral entries in the triage log, so the deferral never pre-empts it |
| 5 | `05-write-chain-survives-progress-deferral.txt` | worktree written during the first quiet window, harness progress advancing afterwards | on the target commit `.writing-since-<key>` survives six consecutive progress deferrals and keeps accruing (153s); on the previous commit it is erased |

Scenario 3 is the adversarial half of the intent: a pane that is genuinely
wedged must still escalate. Scenarios 4 and 5 are the adversarial halves of the
two bounded re-surfaces the recorded review decisions required to stay reachable.
