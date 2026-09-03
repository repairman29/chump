# halt-class-emit observability (CREDIBLE-108, builds on CREDIBLE-365/CREDIBLE-622)

`scripts/lib/halt-class-emit.sh` is the shared wrapper any script emits
halt-class events through instead of hand-rolling JSON against
`.chump-locks/ambient.jsonl`. This doc is the audit reference: what events
it emits, how cost is tracked, the failure-class taxonomy, and how to
smoke-test it.

## Events

All events land in `.chump-locks/ambient.jsonl` (registered in
`docs/observability/EVENT_REGISTRY.yaml`, `effect_metric: self`).

### `kind=halt_class_emit`

Emitted by `halt_class_emit NAME STATUS [REASON] [DETAIL_JSON]` — one event
per call, on **success**, **failure**, or **timeout** alike (status is
carried as a field, not split across kinds).

```json
{"event":"halt_class_emit","kind":"halt_class_emit","name":"bot-merge",
 "status":"timeout","reason":"step=init exceeded 900s",
 "failure_class":"transient","ts":"...","detail":{}}
```

Source: `scripts/lib/halt-class-emit.sh` (`halt_class_emit`).

### `kind=halt_predicate_success` / `halt_predicate_failure` / `halt_predicate_timeout`

Emitted by `halt_predicate_emit PREDICATE STATUS DURATION_MS [DETAIL_JSON]`
(directly, or indirectly via `halt_predicate_run PREDICATE TIMEOUT_S -- CMD...`,
which measures wall-clock and calls `halt_predicate_emit` for you). Three
distinct kinds — one per outcome — rather than one kind plus a status field,
so consumers can filter/aggregate per-outcome without parsing JSON first.

```json
{"kind":"halt_predicate_timeout","predicate":"auth-validity","ts":"...",
 "duration_ms":30000,"detail":{"exit_code":124}}
```

Source: `scripts/lib/halt-class-emit.sh` (`halt_predicate_emit`,
`halt_predicate_run`). CREDIBLE-622 slice.

## Cost tracking

Zero direct cost. Both emit paths are local — `date`, `mkdir -p`, and either
`python3 -c` (when available) or a hand-rolled `sed`-escaped fallback for
JSON construction, writing one line to a local file. No LLM tokens, no
network I/O, no billed API call on the emit path itself.

The value tracked downstream is **signal quality**, not $-cost avoidance:
`halt_predicate_run` reports the wall-clock `duration_ms` of whatever
command it wraps, so a caller that would otherwise silently retry a slow
probe gets a `halt_predicate_timeout` event with the exact duration instead
of a bare non-zero exit code. `fleet-brief` / `waste-tally` (future
consumers, per the `EVENT_REGISTRY.yaml` `consumers` field) roll these up
to show which predicates are trending toward their timeout budget before
they start timing out in practice.

## Failure-class taxonomy

`halt_class_categorize REASON` classifies free-text failure reasons into
exactly two buckets, keyword-matched case-insensitively against `REASON`:

| Class | Keywords (non-exhaustive) | Rationale |
|---|---|---|
| `transient` | rate limit, 429, timeout, timed out, connection reset/refused, econnreset, temporarily unavailable, lock contention, lease held, 503, 502, could not resolve host, network, retry | Worth retrying — the failure is a blip in a dependency, not a structural break. |
| `permanent` | auth...dead, authentication failed, 401, 403, credential...missing, no valid auth, permission denied, not found, 404, invalid config, missing required, compile error, syntax error, fatal | Retrying burns cycles without changing the outcome — needs a human or a config fix. |

**Default: `transient`.** An unrecognized failure reason falls through to
`transient` rather than `permanent` — a wrong `transient` guess costs one
wasted retry; a wrong `permanent` guess can suppress a retry that would
have succeeded. `halt_class_emit` attaches this as `failure_class` for
`status=failure`/`status=timeout`; for `status=success` it's hard-coded to
`"none"` (categorization only applies to failures).

`halt_predicate_emit`/`halt_predicate_run` do **not** run
`halt_class_categorize` — the predicate kind itself (`success`/`failure`/
`timeout`) already encodes the outcome as three distinct event kinds, and
`detail.exit_code` carries the raw signal for any caller that wants finer
classification.

## Smoke test

`bash scripts/ci/test-halt-predicate-events.sh` — sources the wrapper into
an isolated throwaway git repo (so `_halt_class_lock_dir` resolves to a
scratch `.chump-locks/ambient.jsonl`, not the real fleet stream) and
asserts:

1. `halt_predicate_emit` writes `halt_predicate_success` /
   `halt_predicate_failure` / `halt_predicate_timeout` under their matching
   simulated condition.
2. Each event carries `predicate`, `ts`, and `duration_ms`.
3. `halt_predicate_run` measures wall-clock duration and returns the
   wrapped command's exit code unchanged (`124` on timeout, per the
   `timeout` binary's own convention).

For a quick manual check of `halt_class_emit` itself (not covered by the
predicate-focused test above):

```bash
source scripts/lib/halt-class-emit.sh
halt_class_emit "smoke-test" failure "connection refused"
tail -1 .chump-locks/ambient.jsonl   # {"kind":"halt_class_emit",...,"failure_class":"transient",...}
```
