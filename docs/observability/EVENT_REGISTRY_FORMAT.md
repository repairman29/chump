# EVENT_REGISTRY.yaml — Schema Reference (INFRA-1371)

> **Canonical source:** `docs/observability/EVENT_REGISTRY.yaml`
> **Current schema_version:** 2 (bumped by INFRA-1371, 2026-05-15)

## Purpose

`EVENT_REGISTRY.yaml` is the ground-truth contract for every `kind=X` value
that may appear in `.chump-locks/ambient.jsonl`. The drift gate (INFRA-1237)
enforces bidirectional consistency:

- **emit-without-register** → CI fails (strict-emit mode, default)
- **register-without-emit** → CI fails (strict mode, opt-in)

## Fields

| Field | Required? | Description |
|---|---|---|
| `kind` | **Yes** | Literal string emitted in `"kind":"..."` JSON. Must be `snake_case`. |
| `emitter` | **Yes** | Source file or component that emits this event. |
| `trigger` | **Yes** | One-line description of when this event fires. |
| `effect_metric` | **Yes** (since v2) | Name of the metric that proves this event is doing its job. Use `self` when the emission count itself is the proof (most observability events). Use a specific metric name (e.g. `ships_per_hour`, `waste_rate_pct`) for events whose value is measured indirectly. |
| `consumers` | Recommended | List of downstream scripts or tools that read this event kind. |
| `fields_required` | Recommended | List of JSON fields the consumer expects in each emitted event. |
| `expected_min_per_day` | Optional | Integer. If set, the drift gate flags this kind as **silent** when fewer than this many events appear in a 24-hour window. Only set for events that must fire regularly to be useful. |
| `docs` | Optional | Link to a longer explanation (GitHub issue, ADR, or doc section). |
| `status` | Optional | `stable` (default) or `deprecated`. Deprecated events should include a `docs:` link explaining migration. |

## The `effect_metric` field

Added in schema version 2 (INFRA-1371). It answers: *"If this event is
working, what number goes up?"*

### When to use `self`

Use `effect_metric: self` when the event's value is measured by whether it
fires at all — i.e., the emission count in ambient.jsonl is the metric. This
applies to nearly all observability events: `session_start`, `pr_stuck`,
`fleet_wedge`, `graphql_exhausted`, etc.

```yaml
- kind: fleet_wedge
  effect_metric: self
  emitter: scripts/dispatch/worker.sh
  trigger: claude -p produced 0 stdout for full timeout window
```

### When to use a specific metric name

Use a specific metric name when the event feeds a derived KPI and the count
alone doesn't prove correctness. For example, a `ship_merged` event's effect
is `ships_per_hour` — if ships/hr is zero but ship_merged count is nonzero,
something is wrong downstream.

```yaml
- kind: ship_merged
  effect_metric: ships_per_hour
  emitter: scripts/coord/bot-merge.sh
  trigger: PR auto-merged by bot-merge
```

### Validation

CI gate: `scripts/ci/test-event-registry-effect-metric.sh` — runs on every PR
that touches `docs/observability/EVENT_REGISTRY.yaml`. Checks:
1. `schema_version >= 2`
2. Every `kind` entry has `effect_metric` immediately after it
3. No empty `effect_metric` values
4. Count parity: `kind` entries == `effect_metric` entries

## Adding a new event

1. Add an entry in `EVENT_REGISTRY.yaml` with all required fields including `effect_metric`.
2. Update the emitter code to emit the event.
3. Stage your changes — the pre-commit guard verifies the registry entry exists.
4. Run `scripts/ci/test-event-registry-effect-metric.sh` locally before pushing.

Example:
```yaml
  - kind: my_new_event
    effect_metric: self
    emitter: scripts/coord/my-script.sh
    trigger: fires when X happens
    consumers: [fleet-brief]
    fields_required: [ts, gap_id, reason]
```

## Bypass

If you need to emit a new kind before the registry entry is merged (e.g.,
in a fast-follow PR), use the bypass trailer in the commit message:

```
Event-Registry-Bypass: emitter merged in #N, registry entry follow-up in #M
```

And set `CHUMP_EVENT_REGISTRY_CHECK=0` in your commit environment. Document
the bypass in the follow-up PR.

## Schema evolution

Schema changes (adding new required or optional fields) must:
1. Bump `schema_version` in `EVENT_REGISTRY.yaml`
2. Update this document
3. Update `scripts/ci/test-event-registry-effect-metric.sh` if the new field needs validation
4. File a gap for backfilling the field on all existing entries (or use a bulk script)

Current schema version history:
- **v1** (INFRA-754): Initial registry — `kind`, `emitter`, `trigger`, `consumers`, `fields_required`
- **v2** (INFRA-1371, 2026-05-15): Added `effect_metric` (required), `expected_min_per_day` (optional)
