# CI runner health — decision tree (META-101)

Operator-facing guide for reacting to `operator_recall` events with
`condition` in `{RUNNERS_GHOSTED, QUEUE_SATURATED_GH_HOSTED}`, emitted by
`scripts/dispatch/operator-recall.sh`'s `_detect_queue_saturation()`.

## Background

META-100 shipped a single-case detector: queued workflow runs + an
online-but-idle self-hosted runner meant "the runner is ghost-online, restart
it." On 2026-05-24 that assumption cost hours of wrong-tree debugging: the
runners *were* healthy — the queued jobs targeted GitHub-hosted labels
(`ubuntu-latest`), and GH-hosted concurrency quota was exhausted. Restarting
a runner does nothing for that case.

META-101 corrects the framing: the detector class is **QUEUE_SATURATED**. It
fires one of two subclasses depending on what the queued jobs' `runs-on`
labels actually target — not just on whether a self-hosted runner happens to
be idle at the same time.

## Trigger conditions

Both subclasses share the same first gate:

- `>= CHUMP_RUNNER_GHOST_MIN_QUEUED` (default **3**) workflow runs are queued
  and have been queued for `>= CHUMP_RUNNER_QUEUE_THRESHOLD_S` (default
  **300s / 5min**).

If that gate trips, `operator-recall.sh` samples up to
`CHUMP_RUNNER_GHOST_SAMPLE_LIMIT` (default 10) of those queued runs, fetches
each run's jobs (`gh api repos/OWNER/REPO/actions/runs/RUN_ID/jobs`), and
classifies by the jobs' `labels` field (the `runs-on` targets):

| Sampled jobs target | + condition | → subclass |
|---|---|---|
| `self-hosted` label | AND >=1 self-hosted runner is `status=online, busy=false` | **RUNNERS_GHOSTED** |
| GH-hosted label (`ubuntu-*` / `macos-*` / `windows-*`) | (no self-hosted match required) | **QUEUE_SATURATED_GH_HOSTED** |

RUNNERS_GHOSTED is checked first — a self-hosted-targeted queue with an idle
matching runner always means restart, even if other sampled runs also target
GH-hosted labels.

## Decision tree for the operator

```
operator_recall condition=?
│
├── RUNNERS_GHOSTED
│   │  Self-hosted runner(s) report online+idle but matching queued jobs
│   │  aren't being picked up. The runner process is wedged, not actually
│   │  serving jobs.
│   └── FIX: restart the runner daemon.
│         launchctl kickstart -k gui/$(id -u)/<runner-plist-label>
│         (or the platform-specific self-hosted runner service restart)
│       Verify: queued count for self-hosted-targeted runs drops within
│       one polling interval after restart.
│
└── QUEUE_SATURATED_GH_HOSTED
    │  Queued jobs target GitHub-hosted runners (ubuntu-latest, etc.) and
    │  GH's own concurrency quota is exhausted. There is no local process
    │  to restart — restarting a self-hosted runner does NOT help here.
    └── FIX (no-restart-fix — pick one):
          1. Reduce concurrent workflow triggers — the biggest lever is
             usually a force-push storm (see INFRA-1907 pr-auto-rearm
             below) queuing many redundant runs at once.
          2. Increase the GitHub Actions concurrency quota for the org/repo
             (billing/plan change — operator action, not agent-actionable).
          3. Migrate the affected workflow(s) to self-hosted runners so
             they're no longer bound by GH's shared quota.
```

## Remediation field

Every `operator_recall` event this detector emits carries a `remediation`
field with the applicable guidance verbatim, so a consumer doesn't need to
re-derive it from the condition name:

- `RUNNERS_GHOSTED` → `"restart the runner daemon (launchctl restart)"`
- `QUEUE_SATURATED_GH_HOSTED` → `"no-restart-fix; reduce concurrent workflow
  triggers OR increase GH quota OR migrate to self-hosted"`

## Interaction with INFRA-1907 (pr-auto-rearm)

INFRA-1907's rearm daemon force-pushes stale branches to keep them mergeable,
and each force-push re-triggers CI — a burst of rearms can itself produce
the queued-run pile-up that trips `QUEUE_SATURATED_GH_HOSTED`. If this
condition fires repeatedly while pr-auto-rearm is active, treat it as a
signal that the rearm daemon should self-throttle (skip/delay rearms) rather
than firing back-to-back force-pushes during an active
`QUEUE_SATURATED_GH_HOSTED` window. This is not implemented as an automatic
throttle today — file a follow-up gap against INFRA-1907 if the correlation
is observed in practice.

## Env vars

| Var | Default | Meaning |
|---|---|---|
| `CHUMP_RUNNER_QUEUE_THRESHOLD_S` | 300 | seconds a run must stay queued before it counts as stale |
| `CHUMP_RUNNER_GHOST_MIN_QUEUED` | 3 | min stale-queued runs (M) required before sampling jobs |
| `CHUMP_RUNNER_GHOST_SAMPLE_LIMIT` | 10 | max queued runs to fetch jobs for per detection cycle |
| `CHUMP_RUNNER_GHOST_ONLINE_DETECT` | 1 | set to 0 to disable this detector entirely |

## Smoke test

`scripts/ci/test-operator-recall-queue-saturated.sh` — two stubbed
scenarios (self-hosted-idle-matching vs. GH-hosted-over-quota) asserting the
correct subclass and remediation text fire for each.
