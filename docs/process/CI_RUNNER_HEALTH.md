# CI runner health — QUEUE_SATURATED decision tree (META-101)

## Background

2026-05-24 16:32Z: an operator spent hours debugging a "PR-stuck cluster" as
if it were a dead/ghosted self-hosted runner. The actual root cause (found
16:38Z) was GitHub-hosted runner concurrency quota exhaustion — a completely
different failure mode that a restart cannot fix. `scripts/dispatch/operator-recall.sh`
previously had one undifferentiated `RUNNER_GHOST_ONLINE` condition; it now
classifies the queued-run pattern into two distinct subclasses so the
operator (or an automated remediation) picks the right fix on the first try.

## The two subclasses

Both subclasses share the same trigger precondition: `>= CHUMP_RUNNER_QUEUE_MIN_COUNT`
(default 3) queued workflow runs older than `CHUMP_RUNNER_QUEUE_THRESHOLD_S`
(default 300s / 5min). The detector then samples jobs on a handful of those
queued runs (`gh api repos/OWNER/REPO/actions/runs/<id>/jobs`) and classifies
each queued job by its `runs-on` label:

| Subclass | Condition | What it means | Remediation |
|---|---|---|---|
| `RUNNERS_GHOSTED` | Queued jobs target `self-hosted` labels AND >=1 self-hosted runner reports `status=online,busy=false` | The runner process is alive per the GitHub API but isn't actually picking up matching work — a ghost | Restart the runner service (`launchctl restart` on macOS, `systemctl restart` on Linux) |
| `QUEUE_SATURATED_GH_HOSTED` | Queued jobs target GitHub-hosted labels (`ubuntu-*`, `macos*`, `windows-*`) | GitHub's own hosted-runner concurrency quota for the account/org is exhausted — nothing on our side is broken | **Do NOT restart anything.** Reduce concurrent workflow triggers (e.g. throttle force-push storms — see INFRA-1907 below), request a GitHub concurrency quota increase, or migrate the affected workflow to self-hosted runners |

## Decision tree

```
Queued workflow runs stale (>= M runs, > T minutes)?
 │
 ├─ No  → not QUEUE_SATURATED; look elsewhere (CI_BROKEN, AUTH_DEAD, etc.)
 │
 └─ Yes → sample jobs on a few queued runs, look at runs-on labels
          │
          ├─ Jobs target self-hosted labels AND a matching self-hosted
          │  runner is online+idle
          │      → RUNNERS_GHOSTED
          │      → restart the runner service; if it recurs, check for a
          │        split-brain runner registration or a stuck listener process
          │
          ├─ Jobs target GitHub-hosted labels (ubuntu-latest, macos-latest, ...)
          │      → QUEUE_SATURATED_GH_HOSTED
          │      → do NOT restart anything locally — this is a GitHub-side
          │        quota condition. Check whether a force-push/rearm storm
          │        (INFRA-1907 pr-auto-rearm) recently spiked concurrent
          │        triggered runs; throttle it, or raise the GH concurrency
          │        quota, or move the workflow to self-hosted
          │
          └─ Neither classifies (API miss / mixed) AND a self-hosted runner
             is online+idle
                 → fall back to RUNNERS_GHOSTED (conservative: restart is
                   the cheaper of the two possible fixes when unsure)
```

## Pairing with INFRA-1907 (pr-auto-rearm)

`scripts/coord/pr-auto-rearm.sh` force-pushes to re-arm BLOCKED PRs, and
each force-push triggers a fresh workflow run. A rearm storm (many PRs
re-armed in a short window) is a plausible driver of `QUEUE_SATURATED_GH_HOSTED`
on GitHub-hosted CI. If `QUEUE_SATURATED_GH_HOSTED` fires repeatedly and
correlates with `pr_auto_rearmed` events in the same window, consider having
pr-auto-rearm self-throttle (skip or delay rearms) while the condition is
active, rather than continuing to add to a saturated queue. This is a
follow-up, not yet implemented — file a gap referencing this doc if the
correlation is confirmed in practice.

## Tuning

| Env var | Default | Meaning |
|---|---|---|
| `CHUMP_RUNNER_QUEUE_THRESHOLD_S` | 300 | Seconds a run must sit `queued` before it counts as stale |
| `CHUMP_RUNNER_QUEUE_MIN_COUNT` | 3 | Minimum number of stale queued runs required before classifying |
| `CHUMP_RUNNER_GHOST_ONLINE_DETECT` | 1 | Set to 0 to disable QUEUE_SATURATED detection entirely |

See `scripts/dispatch/operator-recall.sh` header comment for the full
condition list (AUTH_DEAD, COST_CAP, CI_BROKEN, QUEUE_STARVE, QUEUE_SATURATED,
DISK_CRITICAL).
