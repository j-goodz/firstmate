# Live validation — shared `fm_test_fake_tmux_relaunch` fixture

Change: `887c07e..66a23da` — extract the duplicated fake-tmux relaunch stub out of
`tests/fm-spawn-cache-mode-excl.test.sh` and `tests/fm-spawn-compact-adviser-disable.test.sh`
into one `fm_test_fake_tmux_relaunch` helper in `tests/fixtures.sh`.

Both suites drive the real product: `bin/fm-control.sh relaunch`, which stops the agent and
rebuilds the launch through `bin/fm-spawn.sh --relaunch` against a real isolated git worktree,
then executes the launch command the pane actually received. The fixture is the fake tmux pane
that transaction runs against.

## S1/S2 — both relaunch suites green on the shared fixture

`after-shared-fixture-66a23da.txt`

```
ok - relaunch rebuilds the cache-cycle exclusion for workers and withholds it from a secondmate, kind restored from the task record
ok - relaunch rebuilds the compact-adviser switch for the replacement agent in both allowlist postures
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=63626
```

## S3 — behaviour preserved vs the inline stubs

`before-base-887c07e.txt` — the same two suites restored to their base-commit form (inline
`make_relaunch_stub` in each, no shared helper) produce the identical set of 11 `ok -` lines and
exit 0. Same observable outcomes before and after the extraction.

## S4 — adversarial: the shared fixture is load-bearing, not decoration

`mutation-shared-fixture-broken.txt` — one line removed from the shared helper
(`*'encode launch-brief'*) printf 'codex' > "$D/command"`, the transition that brings the pane
back as the harness after the launch literal). Both relaunch tests then fail with real
`bin/fm-control.sh` output, which is what proves the real product is being driven:

```
not ok - ship relaunch should succeed: ...
error: the replacement agent for relaunch-ship-a1 did not come up within 0.05s (endpoint reads 'dead')
error: relaunch-ship-a1 was relaunched on codex but no running agent could be confirmed
FM_TEST_SUMMARY total=2 failed=2
```

The mutation was reverted and the worktree returned to a clean `66a23da` before the S1/S2 run
above.

## S5 — no regression for the other `tests/fixtures.sh` consumers

`fixtures-self-test.txt` — `tests/fm-test-fixtures.test.sh`, the suite that pins every shared
fixture builder, is green after the addition. The sibling fake-tmux builders
(`fm_test_fake_tmux_spawn`, `fm_test_fake_tmux_send`) and `fm_test_fake_sleep_noop` all still
behave, so the new function neither shadows a name nor breaks sourcing for the suites that
share the file.

## Gap noted, not closed

`tests/fm-test-fixtures.test.sh` gives every other shared builder a direct behaviour case.
`fm_test_fake_tmux_relaunch` was added without one; it is covered only indirectly, through the
two spawn suites. A machine policy hook on this host refuses non-doc edits from a session with
no claimed nexus task, so that case could not be added in this run.
