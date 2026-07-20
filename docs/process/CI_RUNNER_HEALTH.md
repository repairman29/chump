# CI runner health — restart vs reduce-load vs GH-quota-increase (META-101)

> Precedent: 2026-05-24 16:32Z — a wizard session burned hours diagnosing a
> PR-stuck cluster as a self-hosted runner problem (4 runners `status=online,
> busy=false` with 30 queued jobs). Root cause, found at 16:38Z: the queued
> jobs targeted `ubuntu-latest` (GitHub-hosted), not the self-hosted labels —
> restarting the runner would have done nothing. The queue was saturated on
> GitHub's own concurrency quota, driven by INFRA-1907's force-push storms.

## The two failure modes look identical from the outside

Both present as: "jobs are queued, self-hosted runners show
`status=online,busy=false`." An operator's first instinct is to restart the
runner. That instinct is right for one subclass and a waste of time for the
other.

`scripts/dispatch/operator-recall.sh` distinguishes them automatically (the
`QUEUE_SATURATED` detector, condition e) by sampling the **runs-on labels**
of the actually-queued jobs, not just the runner's online/busy status:

| Subclass | What's actually true | Fix |
|---|---|---|
| `RUNNERS_GHOSTED` | Sampled queued jobs target `self-hosted` labels, AND a self-hosted runner matching those labels is online+idle | `launchctl restart` the runner (registration lost the job, wedged listener, etc.) |
| `QUEUE_SATURATED_GH_HOSTED` | Sampled queued jobs target GitHub-hosted labels (`ubuntu-latest`, `macos-*`, `windows-*`) | **No restart fixes this.** Reduce concurrent workflow triggers, increase the GH-hosted concurrency quota, or migrate the workflow to self-hosted |

## Decision tree for the operator

1. Is `operator_recall` firing with `condition=RUNNERS_GHOSTED` or
   `condition=QUEUE_SATURATED_GH_HOSTED`? Check `.chump-locks/ambient.jsonl`
   or the `runner_ghost_online_detected` / `queue_saturated_detected`
   pre-recall events for the classification and the sampled `runs_on_labels`.
2. **`RUNNERS_GHOSTED`** → restart is safe and likely to help:
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.chump.actions-runner
   scripts/setup/install-self-hosted-runner.sh --check
   ```
3. **`QUEUE_SATURATED_GH_HOSTED`** → do NOT restart anything. Instead:
   - Check whether a rearm/retry daemon (e.g. INFRA-1907 pr-auto-rearm) is
     force-pushing repeatedly and re-triggering the same workflows — that's
     the most common self-inflicted cause. Throttle it.
   - If load is legitimately high, either wait for GH's queue to drain or
     migrate the affected workflow to self-hosted labels (see
     [`SELF_HOSTED_RUNNERS.md`](./SELF_HOSTED_RUNNERS.md)).
   - GH quota increases require a support/plan-tier conversation — file an
     operator action, don't loop on retries.
4. If neither subclass fires but jobs still look stuck, the queue may not be
   old enough to trip `CHUMP_RUNNER_QUEUE_THRESHOLD_S` (default 300s) or deep
   enough to trip `CHUMP_QUEUE_SATURATED_MIN_RUNS` (default 3) yet — check
   again in a few minutes before assuming the detector missed it.

## Tuning

| Env var | Default | Meaning |
|---|---|---|
| `CHUMP_RUNNER_QUEUE_THRESHOLD_S` | 300 | Seconds a run must sit `queued` before it counts as stale |
| `CHUMP_QUEUE_SATURATED_MIN_RUNS` | 3 | Minimum stale queued runs required before the detector fires at all |
| `CHUMP_QUEUE_SATURATED_SAMPLE` | 3 | Max stale queued runs whose jobs get fetched + classified per cycle |
| `CHUMP_RUNNER_GHOST_ONLINE_DETECT` | 1 | Set to `0` to disable the whole detector |

## Pairs with

- INFRA-1907 (pr-auto-rearm) — its force-push storms are a known trigger for
  `QUEUE_SATURATED_GH_HOSTED`. When that condition fires, consider whether
  the rearm daemon should self-throttle rather than keep retrying into an
  already-saturated queue.
- [`SELF_HOSTED_RUNNERS.md`](./SELF_HOSTED_RUNNERS.md) — background on why
  self-hosted runners exist and how to install/verify one.
