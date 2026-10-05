# chump-agent-events-v1

**Status:** Draft / v1.0.0
**Scope:** A public, framework-agnostic JSON-lines event schema for observing
multi-agent coordination — which agents exist, what work they claimed, what
they did, and how that work concluded. Designed to be emitted by any
multi-agent framework (Chump, LangGraph, CrewAI, AutoGen, custom orchestrators),
not just Chump's own fleet.

**Why this exists:** every multi-agent framework today invents its own ad-hoc
event log. There is no shared vocabulary for "agent claimed a unit of work,"
"agent handed off to another agent," or "a coordination conflict occurred" —
the primitives every multi-agent system needs regardless of implementation.
This is the OpenTelemetry-shaped gap for multi-agent coordination: a common
wire format lets dashboards, alerting, and postmortem tooling be built once
and pointed at any compliant emitter. (Bet 3, `MARKET_POSITIONING_2026-05-27.md`.)

This spec is deliberately narrower than a full tracing standard (no span
trees, no distributed-context propagation). It targets the coordination
layer specifically: claims, leases, handoffs, conflicts, and outcomes.
Frameworks that already emit OpenTelemetry spans can project those into
`chump-agent-events-v1` records for cross-framework dashboards; this spec
does not require replacing an existing tracing pipeline.

## 1. Transport

- **Format:** newline-delimited JSON (JSONL). One event per line, no
  trailing commas, UTF-8.
- **Ordering:** append-only. Consumers must not assume global ordering across
  concurrent emitters — use `ts` for temporal ordering and `corr_id` /
  `agent_id` for causal grouping, not line position.
- **Transport-agnostic:** the same JSON object may be written to a local file
  (e.g. `.chump-locks/ambient.jsonl`), streamed over a message bus (NATS,
  Kafka), or POSTed to a webhook. This spec defines the record shape only.

## 2. Envelope

Every event is a single JSON object with these top-level fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `schema` | string | **Yes** | Literal `"chump-agent-events-v1"`. Lets consumers reject unknown-shape records instead of guessing. |
| `kind` | string | **Yes** | `snake_case` discriminator naming the event type (§3). Framework-specific extensions should be namespaced, e.g. `langgraph.node_entered`. |
| `ts` | string | **Yes** | ISO-8601 UTC timestamp, e.g. `2026-08-16T14:08:00Z`. |
| `agent_id` | string | **Yes** | Stable identifier for the emitting agent/session (framework's own ID scheme — session UUID, worker name, etc). |
| `corr_id` | string | No | Correlation ID tying together all events for one unit of work (a task/gap/ticket ID, a trace ID). Absent for fleet-wide events with no single owning task. |
| `framework` | string | No | Name of the emitting framework, e.g. `"chump"`, `"langgraph"`, `"crewai"`. Omit when self-evident from the deployment context. |
| `data` | object | No | Kind-specific payload. Shape is defined per `kind` (§3); consumers must tolerate unknown keys within `data`. |

Unknown top-level fields and unknown `data` keys must be ignored by
compliant consumers (forward compatibility). Unknown `kind` values must be
passed through or safely dropped, never treated as a parse error.

### Minimal example

```json
{"schema":"chump-agent-events-v1","kind":"work_claimed","ts":"2026-08-16T14:08:00Z","agent_id":"worker-3","corr_id":"TASK-4711","data":{"lease_ttl_s":900}}
```

## 3. Core event kinds (v1)

These are the minimum kinds a compliant emitter should support to make a
multi-agent system's coordination layer observable. Frameworks may emit
additional namespaced kinds; consumers of this spec only need to understand
the ones below to render a useful coordination dashboard.

| `kind` | Fires when | `data` fields |
|---|---|---|
| `agent_started` | An agent/worker session begins. | `role` (string, optional — e.g. `"implementer"`, `"reviewer"`) |
| `agent_stopped` | An agent/worker session ends (clean or crashed). | `reason` (string — `"completed"`, `"error"`, `"timeout"`, `"killed"`) |
| `work_claimed` | An agent atomically claims a unit of work (task, gap, ticket). | `lease_ttl_s` (number, optional) |
| `work_released` | A claimed unit of work is released without completion (abandon, lease expiry, handoff). | `reason` (string) |
| `work_completed` | A unit of work reaches a terminal success state. | `outcome` (string, optional — free-form summary) |
| `work_failed` | A unit of work reaches a terminal failure state. | `error_class` (string, optional) |
| `handoff` | Work or context passes from one agent to another. | `from_agent` (string), `to_agent` (string) |
| `conflict_detected` | Two or more agents contend for the same resource (double-claim, overlapping file edit, lease collision). | `resource` (string), `agents` (array of agent_id) |
| `consensus_proposed` | An agent proposes a decision requiring multi-agent agreement (vote, review, approval). | `proposal` (string, optional) |
| `consensus_resolved` | A proposal reaches a verdict. | `verdict` (string — e.g. `"passed"`, `"failed"`, `"no_quorum"`) |

Every row is a **minimum contract**: `data` may carry additional
framework-specific fields beyond the ones listed, but a compliant emitter
must include the listed fields when the information is available, and a
compliant consumer must not fail when it is absent.

## 4. Extension kinds

Frameworks needing kinds beyond §3 should namespace them with a
framework prefix (`<framework>.<kind>`, e.g. `chump.fleet_wedge`,
`langgraph.node_entered`) to avoid colliding with future core kinds or with
other frameworks' extensions. Un-namespaced `kind` values outside §3 are
reserved for future core-schema growth and should not be used by extensions.

## 5. Versioning

- The `schema` field pins the major version (`chump-agent-events-v1`).
  Backward-incompatible changes (removing a required field, changing a
  field's type, removing a core `kind`) require a new `schemaN` value
  (`chump-agent-events-v2`) rather than mutating v1 in place.
- Additive changes (new optional field, new core `kind`, new extension
  namespace) do not require a version bump — consumers must already
  tolerate unknown fields and kinds per §2.

## 6. Reference implementation

Chump's own `.chump-locks/ambient.jsonl` stream is the reference emitter for
this spec. Its native events use the fields `kind` and `ts` already (see
`docs/observability/EVENT_REGISTRY.yaml`); a `schema: "chump-agent-events-v1"`
field and an `agent_id`/`corr_id` projection are the delta needed to make
Chump's own stream spec-compliant. That projection is tracked as a
follow-up implementation gap — this document specifies the target shape,
not the migration.

## 7. Non-goals (v1)

- **Not a tracing/span standard.** No parent-span trees, no distributed
  context propagation headers. Use OpenTelemetry alongside this spec if you
  need that.
- **Not a task-queue protocol.** This spec describes observability events
  *about* claims and handoffs, not the wire protocol used to perform them.
- **Not prescriptive about storage.** SQLite, a flat file, Kafka, or a
  webhook receiver are all valid backends for the same JSONL records.

## Related docs

- [`docs/strategy/MARKET_POSITIONING_2026-05-27.md`](../strategy/MARKET_POSITIONING_2026-05-27.md) — Bet 3, the moat rationale for publishing this spec.
- [`docs/observability/EVENT_REGISTRY.yaml`](../observability/EVENT_REGISTRY.yaml) — Chump's internal event kind registry (the reference emitter, pre-projection).
- [`docs/observability/EVENT_REGISTRY_FORMAT.md`](../observability/EVENT_REGISTRY_FORMAT.md) — format contract for Chump's internal registry.
