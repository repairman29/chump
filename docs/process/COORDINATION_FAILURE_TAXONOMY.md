# Coordination Failure Taxonomy

> META-083 (META-073 child slice). Reference taxonomy for fleet coordination
> failures: how the system classifies, retries, and alerts on errors that
> arise from agent-to-agent communication, gap claiming, RPC, broadcast,
> webhook ingestion, and related runtime events.
>
> This taxonomy is foundational for the other META-073 children:
> META-075 (collision schema), META-077 (skill routing schema),
> META-079 (lesson propagation format), META-082 (cost tracking),
> META-084 (observability smoke).

## Why a taxonomy

Before this doc, every coordination error looked the same to retry logic:
either it stalled, or it surfaced an ALERT, or it silently dropped.
Whether a failure was "the network blinked, retry in 200 ms" or
"the auth config is wrong, stop retrying" required an operator to read
the log. As the fleet scales, operator-in-the-loop on every failure is
not workable.

Classifying every failure into one of four classes lets the system pick
the right retry policy and the right alert level **mechanically**.

## The four classes

| Class | Behavior              | Retry policy           | Alert level |
|-------|-----------------------|------------------------|-------------|
| `TRANSIENT_NET`    | Network blip, broker hiccup, brief throttle | retry up to 3× with exponential back-off (250 ms / 1 s / 4 s) | none until threshold breach |
| `TRANSIENT_RATELIMIT` | Upstream rate-gate (GraphQL bucket low, NATS slow consumer)| pause for advertised reset window, then 1 retry | WARN if breached 3× in 30 min |
| `PERMANENT_CONFIG` | Auth fail, missing env, wrong endpoint, bad credentials | NO retry — alert immediately | ALERT (operator-actionable) |
| `PERMANENT_LOGIC`  | Schema mismatch, unsupported method, contract violation | NO retry — alert immediately | ALERT (programmer-actionable) |

### `TRANSIENT_NET`

**Examples**
- `gh api ...` returns HTTP 5xx
- `nats publish` returns `ErrConnectionClosed` once
- `broadcast.sh` write to inbox file fails with `EBUSY`
- DNS timeout on GitHub API

**Behavior**
- Caller retries up to 3× with exponential back-off.
- Each retry emits `kind=coord_transient_retry` to ambient with `{class:"TRANSIENT_NET", attempt, reason}`.
- After 3 failed retries: emit `kind=coord_transient_exhausted` + WARN broadcast.
- Repeated exhaustion (3× in 30 min) gets escalated to ALERT.

### `TRANSIENT_RATELIMIT`

**Examples**
- GitHub GraphQL bucket below 100 remaining → `kind=graphql_exhausted` already emitted
- `gh self-throttle` fires
- NATS publish slow-consumer message

**Behavior**
- Caller MUST honor the upstream's advertised reset window (e.g. `X-RateLimit-Reset` header).
- After the wait, ONE retry is allowed.
- Subsequent failure → degrade-mode for the caller (e.g. fall through to REST cache instead of fresh GraphQL).
- Emit `kind=coord_ratelimit_paused` + the resume time.
- Threshold: 3 ratelimit pauses in 30 min → WARN; 6× → ALERT.

### `PERMANENT_CONFIG`

**Examples**
- `gh api ...` returns HTTP 401 / 403
- `ANTHROPIC_API_KEY` missing AND `CLAUDE_CODE_OAUTH_TOKEN` missing
- `~/.chump/oauth-token.json` malformed
- NATS connection refused, broker unreachable for > 5 min
- Webhook receiver: `X-Hub-Signature-256` mismatch

**Behavior**
- NO retry. The retry would loop until the operator intervenes.
- Emit `kind=coord_permanent_config_fail` with `{component, what_failed}`.
- ALERT broadcast to `operator-*` immediately.
- Caller falls back to its degraded path if one exists (e.g. cache-only read), else exits non-zero.

### `PERMANENT_LOGIC`

**Examples**
- RPC handler returns "method not supported"
- A2A schema version mismatch (peer is on `chump-capability-v0`, we send `v2`)
- ScratchpadConflictPolicy::CASRequired returns `CASConflict` (semantic, not retryable)
- Gap state machine: `claim` on an already-shipped gap
- Webhook payload fails JSON-schema validation

**Behavior**
- NO retry. The error is a contract violation; retrying doesn't fix the contract.
- Emit `kind=coord_permanent_logic_fail` with `{component, contract_violated}`.
- ALERT broadcast to `operator-*`.
- For dev/PR-builds: surface the contract violation in the failing CI log so the PR author sees it.

## Class assignment cheat-sheet

| Symptom                                                   | Class                    |
|-----------------------------------------------------------|--------------------------|
| HTTP 5xx, retry succeeds                                  | TRANSIENT_NET            |
| HTTP 5xx, 3 retries fail                                  | TRANSIENT_NET → escalate |
| `X-RateLimit-Remaining: 0`                                | TRANSIENT_RATELIMIT      |
| HTTP 401, 403, 407                                        | PERMANENT_CONFIG         |
| `ENOENT` on a path that *must* exist (Anthropic token)    | PERMANENT_CONFIG         |
| schema version mismatch                                   | PERMANENT_LOGIC          |
| CAS conflict (expected != current)                        | PERMANENT_LOGIC          |
| "method not supported"                                    | PERMANENT_LOGIC          |
| gap state machine illegal transition                      | PERMANENT_LOGIC          |
| broker disconnect, reconnect within 30 s                  | TRANSIENT_NET            |
| broker unreachable > 5 min                                | PERMANENT_CONFIG         |
| timeout on RPC, peer is alive (capability publish fresh)  | TRANSIENT_NET            |
| timeout on RPC, peer is silent (no capability heartbeat)  | PERMANENT_CONFIG → assume peer is dead, redispatch |

## Wire format (event schema)

All coordination-failure ambient events share these required fields:

```json
{
  "ts": "<ISO-8601 UTC>",
  "kind": "coord_<class>_<verb>",
  "class": "TRANSIENT_NET | TRANSIENT_RATELIMIT | PERMANENT_CONFIG | PERMANENT_LOGIC",
  "component": "<broadcast.sh | _rpc_lib | scratchpad | webhook | ...>",
  "reason": "<one-sentence string>",
  "session": "<emitter session id>"
}
```

`component` lets the dashboard slice by surface; `class` lets it slice by
severity. Together they answer "which surface is unhealthy and how" in
one query.

## Registered event kinds

The taxonomy maps to these ambient `kind` values, which MUST be registered
in `docs/observability/EVENT_REGISTRY.yaml`:

- `coord_transient_retry`
- `coord_transient_exhausted`
- `coord_ratelimit_paused`
- `coord_ratelimit_exhausted`
- `coord_permanent_config_fail`
- `coord_permanent_logic_fail`

These are the canonical kinds for any new coordination call site to emit.

## Implementation pointers

When adding a new coordination call site:

1. Catch each known failure mode and classify it via this taxonomy.
2. Use the matching retry policy (see table above).
3. Emit the matching `kind=coord_<class>_<verb>` to ambient on each event.
4. For ALERT-class events, broadcast `--to operator-*` via `scripts/coord/broadcast.sh`.
5. Add the new call site's component name to the per-component dashboard
   in `scripts/dev/coord-health-leaderboard.sh` (filed as follow-up).

Test discipline: every new coordination call site MUST have a smoke test
that exercises at least one failure of each applicable class (transient
retry, config-fail alert, logic-fail alert). The smoke goes under
`scripts/ci/test-<component>-failures.sh`.

## Versioning

This doc is the v1 taxonomy. Changes that add a new class or rename a
class require:

1. A new entry in `docs/syntheses/coord-taxonomy-change-log.md`
2. Mechanical migration of all `kind=coord_*` emit sites
3. EVENT_REGISTRY.yaml updates for any renamed kinds

Bumps to retry policies (numbers, back-off curves) are NOT breaking and
can land as PR-sized changes with an audit-log entry in the change log.

## Cross-references

- META-073 — parent epic
- META-075 — collision schema (will reference this taxonomy for its alert classes)
- META-077 — skill-routing schema
- META-079 — lesson propagation
- META-081 — collision↔routing integration
- META-082 — cost tracking (per-class budgets)
- META-084 — observability smoke (must cover each class)
- INFRA-1828 — A2A RPC bash wrappers (uses TRANSIENT_NET on `a2a_rpc_timeout`)
- INFRA-1825 — CapabilityManifest publish loop (uses PERMANENT_CONFIG → assume-dead heuristic in cheat-sheet)
- INFRA-1040 / INFRA-1079 — GraphQL exhaustion handling (canonical TRANSIENT_RATELIMIT example)
