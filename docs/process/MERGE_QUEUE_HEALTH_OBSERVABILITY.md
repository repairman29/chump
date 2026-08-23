# merge-queue-health stream observability (CREDIBLE-073, re-do of CREDIBLE-068)

`scripts/coord/monitor-merge-queue.sh` is a daemon that polls GitHub merge
queue depth (queued Actions runs + open auto-merge PRs) on a fixed interval
and streams the result to `.chump-locks/ambient.jsonl`. This doc is the audit
reference CREDIBLE-068 shipped without: what events it emits on
success/failure/timeout, how cost is tracked, the failure-class taxonomy, and
how to smoke-test it.

## Events

Both kinds are registered in `docs/observability/EVENT_REGISTRY.yaml`
(`effect_metric: queue_saturation_pct` / `self`).

### `kind=merge_queue_health` — success

Emitted once per poll (`MONITOR_INTERVAL_S`, default 60s) whenever both `gh`
calls succeed.

```json
{"ts":"...", "kind":"merge_queue_health", "queued_workflows":12,
 "auto_merge_prs":4, "queue_saturation_pct":24, "backpressure_recommended":false}
```

`queue_saturation_pct` is `(queued_workflows / QUEUE_ALERT_THRESHOLD) * 100`,
clamped to 100 for display. `backpressure_recommended` flips `true` once the
unclamped saturation exceeds 70%. Consumers: `fleet_health`,
`agent_backpressure` (`scripts/ops/node-orchestrator.sh` reads the latest
line and throttles dispatch when `backpressure_recommended=true`).

### `kind=queue_health_check_failed` — failure

Emitted instead of `merge_queue_health` (not in addition to it) when either
`gh` query returns `ERROR` — i.e. the repo slug can't be resolved, or the
underlying `gh_query_queued_workflows` / `gh_query_auto_merge_prs` call
fails or is killed by the 8s `_timeout_cmd` wrapper.

```json
{"ts":"...", "kind":"queue_health_check_failed",
 "note":"gh api call failed or timed out; fleet assumes queue healthy"}
```

Advisory only — the daemon does not exit or retry immediately; it sleeps
`MONITOR_INTERVAL_S` and tries again next tick.

### No separate timeout event — by design

A timeout is not distinguished from any other `gh` failure. Both
`gh_query_queued_workflows` and `gh_query_auto_merge_prs` wrap their call in
`_timeout_cmd 8 ...` and fold a timed-out call into the same `"ERROR"`
sentinel a rate-limit or auth failure would produce. There is nothing a
consumer could do differently for "timed out" vs. "errored" — both mean
"treat the queue as unknown this tick" — so splitting them into a third
event kind would add a distinction with no consumer behind it.

**CREDIBLE-073 fix:** `_timeout_cmd` previously shelled out to GNU
`timeout $secs chump_gh ...` — but `chump_gh` is a bash *function* sourced
from `lib/github.sh`, not a binary on `PATH`. `timeout(1)` execs a new
process image and cannot resolve a function name, so on any host where GNU
`timeout` is actually installed (most Linux fleet hosts), every call
failed immediately with rc=127, and every tick emitted
`queue_health_check_failed` regardless of the real queue state — the
stream was silently dead in exactly the environment it was meant to run in.
`_timeout_cmd` now backgrounds the target and races a sleep-then-kill
watcher against it via `wait`, which works for both shell functions and
external binaries since it never execs a new process image.

## Cost tracking

No LLM tokens; cost here means GitHub API budget, not `$`. Each tick issues
two calls:

- `gh_query_queued_workflows` — REST (`repos/$repo/actions/runs?status=queued`),
  not GraphQL, so it draws from the REST rate-limit bucket, which stays
  healthy during `graphql_exhausted` windows (INFRA-2464).
- `gh_query_auto_merge_prs` — reads `cache_query_pr_queue` first (the
  webhook-fed `.chump/github_cache.db`, effectively free); only falls back
  to a live `gh pr list --json autoMergeRequest` REST call on a cache miss.

Both calls are tagged `CHUMP_GH_CALL_CRITICALITY=background`, so `chump_gh`'s
shared throttle delays them (rather than a ship-blocking caller) whenever the
GraphQL bucket is tight. At the default 60s interval and REST-first design,
steady-state cost is at most 1 REST call/tick plus 0-1 cache-miss REST calls
— no GraphQL calls at all on the steady-state path.

## Failure-class taxonomy

| Class | Trigger | Transient or permanent | Observed as |
|---|---|---|---|
| Success | both `gh` queries return a value | n/a | `merge_queue_health` |
| API failure | `gh api` / `gh pr list` returns non-zero, empty, or unparseable output | transient — expected to clear on the next tick (rate limit reset, transient network blip) | `queue_health_check_failed` |
| Timeout | either call exceeds the 8s `_timeout_cmd` budget | transient — folded into the same `ERROR` path as API failure | `queue_health_check_failed` |
| Repo unresolved | `_cache_repo_nwo` returns empty (no repo context, e.g. run outside a chump checkout) | permanent for that invocation — will not self-heal on its own retry, but the daemon does not distinguish it from a transient `ERROR` | `queue_health_check_failed` |

There is no permanent-failure escalation path: `queue_health_check_failed`
never trips backpressure and never halts the loop, since the fallback
behavior ("assume queue healthy") is explicitly the safe default documented
in the script's own comment header.

## Smoke test

`bash scripts/ci/test-merge-queue-monitor.sh` — asserts, using
`MONITOR_ONCE=1` one-shot runs against a mocked `gh`/cache layer:

1. `merge_queue_health` + `queue_health_check_failed` are both registered in
   `docs/observability/EVENT_REGISTRY.yaml`
2. an empty queue produces `merge_queue_health` with `queue_saturation_pct=0`
   and `backpressure_recommended=false`
3. a 50%+ saturated queue produces `backpressure_recommended=true`
4. a fully saturated (100%+) queue clamps `queue_saturation_pct` to 100
   while `backpressure_recommended` stays `true`

Run it directly to verify observability end-to-end:

```bash
bash scripts/ci/test-merge-queue-monitor.sh
```
