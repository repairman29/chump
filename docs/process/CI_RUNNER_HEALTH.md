# CI runner health — operator decision tree (META-101)

Precedent: 2026-05-24 16:32Z — a self-hosted-runner wizard found the actual
root cause of a PR-stuck cluster only after hours of debugging the wrong
tree. Symptom looked like "runners are ghost-online" (4 self-hosted runners
`status=online,busy=false` with 30 queued jobs, `runner_name=null`), but the
real cause that day was GitHub-hosted runner concurrency quota exhaustion —
a different failure class with a different fix.

`scripts/dispatch/operator-recall.sh`'s `_detect_runner_ghost_online()`
detector (guard: `CHUMP_RUNNER_GHOST_ONLINE_DETECT`) now tells the two apart
automatically and emits a distinct `kind=operator_recall` subclass for each.

## The two subclasses

| Subclass | What it means | Signal | Remediation |
|---|---|---|---|
| `RUNNERS_GHOSTED` | Self-hosted runner(s) are online+idle but a queued job that *targets their labels* isn't being picked up — the runner process is wedged, not just idle. | Sampled queued run's job labels include `"self-hosted"`. | Restart the runner service: `launchctl kickstart -k gui/$(id -u)/<runner-plist-label>` (see `docs/process/SELF_HOSTED_RUNNER_DO.md`). |
| `QUEUE_SATURATED_GH_HOSTED` | Queued jobs target GitHub-hosted labels (`ubuntu-latest`, `macos-*`, `windows-*`). Idle self-hosted runners are a red herring — they were never going to pick these jobs up. GH-hosted runner concurrency quota is exhausted. | Sampled queued run's job labels are GH-hosted (no `"self-hosted"`). | **No-restart-fix.** Reduce concurrent workflow triggers (batch/queue pushes), OR raise the GH-hosted concurrency quota, OR migrate the affected workflow to `runs-on: self-hosted`. |

## Decision tree

1. See a `pr_stuck` cluster or a `kind=operator_recall` alert mentioning
   queued workflow runs?
2. Check `.chump-locks/ambient.jsonl` for the most recent
   `kind=runner_ghost_online_detected` event — read its `"subclass"` field.
3. `subclass=RUNNERS_GHOSTED` → restart the self-hosted runner. Verify with
   `gh api repos/OWNER/REPO/actions/runners` that `busy` flips to `true`
   within a few minutes of the restart.
4. `subclass=QUEUE_SATURATED_GH_HOSTED` → do **not** restart anything.
   Check `gh api repos/OWNER/REPO/actions/runs --status=queued` for the
   volume of queued GH-hosted runs. If it's driven by a burst of force-pushes
   (see below), throttle the pusher; otherwise file a GH quota increase
   request or migrate the workflow to self-hosted.
5. Unsure which fired? Run `scripts/dispatch/operator-recall.sh --check-only`
   — it prints `HALT condition=<subclass>: <reason>` with the affected
   `workflow_run_id`s and `runs_on` labels inline.

## INFRA-1907 interaction (pr-auto-rearm)

The pr-auto-rearm daemon (INFRA-1907) force-pushes rebased branches to keep
stale PRs mergeable. Each force-push re-triggers the full CI workflow set,
which is exactly the kind of burst that can exhaust GH-hosted runner
concurrency quota. If `QUEUE_SATURATED_GH_HOSTED` fires repeatedly and
correlates with rearm activity (`grep pr_auto_rearm .chump-locks/ambient.jsonl`),
consider having the rearm daemon self-throttle (skip a cycle) while that
subclass is active, rather than continuing to add to the queue it's
saturating. Not yet implemented — file a follow-up INFRA gap if this
correlation is observed in practice.
