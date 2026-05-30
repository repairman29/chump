# Queue-Tender Doctrine

Operator directive: 2026-05-30. Gap: META-243.

## Why this exists

On 2026-05-30 an Opus orchestrator ran a session-bound CronCreate loop (5-min
cadence) that:

1. Snapshotted open PR count.
2. Fired `gh pr update-branch` in parallel on every DIRTY PR.
3. Verified liveness of four fleet daemons.
4. Checked trunk CI conclusion.
5. Emitted `kind=queue_tend_tick` to `ambient.jsonl`.

Result: the queue stabilized at 34 open PRs with 11 ships/hr sustained over
the session. When Claude exited, the cron died and the DIRTY backlog began
accumulating again.

This daemon makes that behavior a permanent fleet capability. The operator
authorized productization on 2026-05-30.

## What the daemon does

One tick every 300 seconds (launchd `StartInterval`):

| Phase | Action | Constraint |
|---|---|---|
| Snapshot | `gh pr list --state open --limit 200` | Read-only |
| Drain check | Emit `queue_tender_queue_drained` + exit 1 if open=0 | No side effects |
| Hysteresis filter | Skip PRs rebased within last 300s | Per-PR timestamp in state file |
| Parallel rebase | `gh pr update-branch <N> --rebase` on eligible DIRTY PRs | Cap 20 parallel jobs |
| Liveness check | `launchctl list` for 4 expected daemon labels | Observation only |
| Trunk read | `gh run list --branch main --workflow ci.yml --limit 1` | Read-only |
| Emit | `kind=queue_tend_tick` with payload | Appends to ambient.jsonl |

State is persisted across ticks in `.chump-locks/queue-tender-state.json` (tick
count, last-rebase timestamps per PR, baseline open count).

## What the daemon deliberately does NOT do

The lane boundary is hard-coded in `scripts/coord/queue-tender-loop.sh` and
verified by `scripts/ci/test-queue-tender.sh` test 5. Any change that adds a
banned operation to the source will fail CI.

| Action | Why not | Who does it |
|---|---|---|
| `gh pr merge --admin` | Operator authority; T1 gate | Operator explicitly |
| Dispatch Agent() subagents | Out-of-lane; metric pollution | curator-opus-handoff |
| `gh pr close` | PRs may be intentionally parked | curator-opus-shepherd |
| `chump gap reserve` | Queue-tender is read-mostly fleet infra | target curator, operator |
| Diagnose CI failures | ci-audit owns that surface | curator-opus-ci-audit |
| Edit ci.yml or source code | Read-only on repo | gap implementors |
| Restart dead daemons | May mask root cause | operator, fleet-bootstrap |
| Re-arm auto-merge | Separate daemon (INFRA-2309) | auto-merge-rearm-daemon |

When trunk is RED the daemon emits `kind=trunk_red_observed_by_queue_tender`
and continues rebasing. Rebasing keeps PRs current regardless of trunk color
and ci-audit owns the diagnosis.

## How to install

The operator runs this once after the PR merges:

```bash
# Install and load the launchd agent:
bash scripts/setup/install-queue-tender.sh install

# Verify it loaded:
bash scripts/setup/install-queue-tender.sh check

# Watch first tick:
tail -f ~/.chump/logs/queue-tender.out.log
```

The installer resolves the daemon script path from its own location
(`dirname` of `realpath $0`) rather than from `$CARGO_BIN` or env vars —
this survives worktree reaping cycles (INFRA-2302 lesson).

Environment knobs available at install time:

| Knob | Default | Effect |
|---|---|---|
| `CHUMP_QUEUE_TENDER_CADENCE_SEC` | 300 | `StartInterval` in the generated plist |
| `CHUMP_QUEUE_TENDER_PARALLEL_REBASE` | 20 | Max parallel `gh pr update-branch` jobs |
| `CHUMP_QUEUE_TENDER_REBASE_HYSTERESIS_SEC` | 300 | Seconds before re-rebasing same PR |
| `CHUMP_SKIP_QUEUE_TENDER` | (unset) | Set to 1 to install in kill-switch mode |

## How to observe

```bash
# Ambient stream — recent queue_tend_tick events:
tail -50 .chump-locks/ambient.jsonl | grep queue_tend_tick | tail -5

# Live log:
tail -f ~/.chump/logs/queue-tender.out.log

# Status snapshot:
bash scripts/setup/install-queue-tender.sh status

# State file (tick count, rebase timestamps):
cat .chump-locks/queue-tender-state.json 2>/dev/null || echo "(no state yet)"
```

The `queue_tend_tick` payload fields:

| Field | Type | Meaning |
|---|---|---|
| `open` | int | Total open PRs at snapshot time |
| `blocked` | int | PRs with mergeStateStatus=BLOCKED |
| `dirty` | int | PRs with mergeStateStatus=DIRTY |
| `behind` | int | PRs with mergeStateStatus=BEHIND |
| `ships_since_baseline` | int | Decrease in open count since daemon started |
| `action_taken` | string | "rebase:N skip_hysteresis:N fail:N" |
| `daemons_alive` | string | "N/4" (alive count out of 4 expected) |
| `trunk_conclusion` | string | Latest ci.yml run conclusion on main |
| `tick_count` | int | Cumulative tick number since state file created |

## When to disable

Disable the daemon (not just kill-switch) if:

- The rebase volume is causing GitHub secondary rate-limit exhaustion (watch
  for `gh_self_throttled` events in ambient.jsonl).
- The fleet is in a planned maintenance window where PR state should be frozen.
- The shepherd daemon is being replaced by a new implementation that subsumes
  rebase responsibility.

Kill-switch (daemon keeps running but tick is a no-op):

```bash
# Edit the plist to add CHUMP_SKIP_QUEUE_TENDER=1, then reload:
CHUMP_SKIP_QUEUE_TENDER=1 bash scripts/setup/install-queue-tender.sh install
bash scripts/setup/install-queue-tender.sh check
```

Full disable:

```bash
bash scripts/setup/install-queue-tender.sh uninstall
```

## Coordination with other daemons

| Daemon | Relationship |
|---|---|
| `stale-pr-rebase-bot` | Complementary: rebase-bot handles stale PRs on a different trigger surface; queue-tender handles DIRTY (merge-conflict) state. Both can coexist. |
| `chump-integrator-daemon` | Downstream: integrator picks up MERGEABLE PRs after queue-tender clears DIRTY state. Queue-tender creates work for integrator. |
| `trunk-red-detector` | Upstream signal: trunk-red-detector sets the green/red state that ci-audit reads. Queue-tender observes trunk conclusion passively; it does not read trunk-red-detector's state file directly. |
| `flake-detector` | Parallel: flake-detector classifies test failures; queue-tender ignores test results and only acts on mergeStateStatus. |
| `auto-merge-rearm-daemon` (INFRA-2309) | Complementary: auto-merge-rearm re-arms the GitHub auto-merge flag after a rebase clears it. Queue-tender fires the rebase; auto-merge-rearm-daemon re-arms the flag. Run both for full automation. |

## Rate-limit hygiene

Each tick fires at most `CHUMP_QUEUE_TENDER_PARALLEL_REBASE` (default 20)
concurrent `gh pr update-branch` calls. At 5-min cadence with a typical DIRTY
backlog of 5-15 PRs this is well within GitHub's REST core bucket.

If `graphql_exhausted` events appear in ambient.jsonl within minutes of a
queue-tender tick, reduce `CHUMP_QUEUE_TENDER_PARALLEL_REBASE` or increase
`CHUMP_QUEUE_TENDER_CADENCE_SEC`. The hysteresis window (default 300s) already
prevents a PR from being targeted more than once per cadence cycle.

Tag queue-tender gh calls as background criticality if rate pressure increases:
set `CHUMP_GH_CALL_CRITICALITY=background` in the plist EnvironmentVariables.
See `CLAUDE.md §Call criticality` for the full criticality model.
