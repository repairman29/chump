# CI runner health — decision tree (META-101)

`scripts/dispatch/operator-recall.sh` fires condition `RUNNER_GHOST_ONLINE` when
workflow runs sit `queued` past `CHUMP_RUNNER_QUEUE_THRESHOLD_S` (default 300s).
That single condition covers two root causes with **opposite** fixes — restarting
the wrong thing wastes the same hours the 2026-05-24 16:32Z incident lost
(wizard found the real root cause only after hours debugging the wrong tree).

## Two subclasses, one condition

| `class` field | Meaning | Detected by |
|---|---|---|
| `RUNNERS_GHOSTED` | A self-hosted runner reports `status=online, busy=false`, and the queued job(s) actually target that runner's labels — the runner process is wedged/stuck and isn't picking up matching work. | queued job's `runs-on` labels include `self-hosted` AND match an idle runner's label set |
| `QUEUE_SATURATED_GH_HOSTED` | Queued jobs target **GitHub-hosted** labels (`ubuntu-*`, `macos-*`, `windows-*`). The self-hosted runner being idle is a red herring — it was never going to pick up this job. GH-hosted runner concurrency quota is exhausted. | queued job's `runs-on` labels match `^(ubuntu\|macos\|windows)(-\|$)` |

Both can fire in the same detection pass (mixed queue) — they are independent
`operator_recall` emissions, each cooldown-gated separately by
`condition+class`.

## Operator decision tree

1. Read the `class` field on the `operator_recall` ambient event (or the
   `--check-only` stdout line).
2. **`class=RUNNERS_GHOSTED`** → the runner process itself is the problem.
   - Remediation: `launchctl restart` the affected self-hosted runner
     service (see `docs/process/CLAUDE_GOTCHAS.md` for the binary-wedge
     pattern this often correlates with).
   - Do NOT touch workflow trigger volume — that's not the cause here.
3. **`class=QUEUE_SATURATED_GH_HOSTED`** → restarting anything is a
   no-op (**no-restart-fix**). The reason field lists the affected
   `workflow_run_ids` and `runs_on_labels` so you can see which
   workflows are backing up. Options, in order of effort:
   - Reduce concurrent workflow triggers (e.g. INFRA-1907's rearm daemon
     force-push storms are a known generator of this — see below).
   - Increase the GitHub-hosted runner concurrency quota (org/plan
     setting).
   - Migrate the affected workflow(s) to self-hosted runners so they
     stop competing for the shared GH-hosted quota.
4. If unsure which subclass fired, or both fired together, treat it as
   `QUEUE_SATURATED_GH_HOSTED` first (a restart cannot make a GH-hosted
   quota exhaustion worse, but assuming `RUNNERS_GHOSTED` and restarting
   when the real cause is quota exhaustion burns the same
   wrong-tree-debugging hours as the 2026-05-24 incident).

## INFRA-1907 interaction

`pr-auto-rearm`'s force-push storms are a plausible generator of queued
workflow runs that exceed GH-hosted quota. When `QUEUE_SATURATED_GH_HOSTED`
fires repeatedly and correlates with rearm activity in `ambient.jsonl`
(`kind=pr_auto_rearm` or similar), consider whether INFRA-1907 should
self-throttle its trigger rate rather than relying on quota headroom.
This is a candidate follow-up, not yet implemented — file a gap if the
correlation is confirmed in practice.

## Tuning

Same env vars as the base `RUNNER_GHOST_ONLINE` detector — see the header
comment in `scripts/dispatch/operator-recall.sh`:

- `CHUMP_RUNNER_QUEUE_THRESHOLD_S` (default 300)
- `CHUMP_RUNNER_GHOST_ONLINE_DETECT` (default 1, set 0 to disable)

Smoke test: `scripts/ci/test-operator-recall-queue-saturated.sh`.
