# Collision Prediction Event Schema

> META-075 (META-073 child slice, Track 1 of 3). Defines the on-wire event
> shape for the *predictive* collision-detection layer. Pairs with META-083
> (failure-class taxonomy) which classifies the *reactive* side; this doc
> is the warning system that fires BEFORE the collision.

## Why a predictive layer

Today's fleet detects collisions *after* they happen: two agents hold
overlapping leases, the second one's commit conflicts, a curator rescues.
That works but burns minutes per occurrence and stresses CI.

A predictive layer watches the lease graph + the open-PR graph + the
gap-decompose graph in real time, looks for *futures* where two agents
will collide, and emits a warning event so one of them can stand down
before either has typed code.

## Wire format (v1)

```json
{
  "ts": "<ISO-8601 UTC>",
  "kind": "collision_predicted",
  "schema_version": "collision-prediction-v1",
  "agents": [
    {"session": "<id-A>", "current_gap": "<gap-id|null>", "manifest_skills": ["..."]},
    {"session": "<id-B>", "current_gap": "<gap-id|null>", "manifest_skills": ["..."]}
  ],
  "predicted_collision_ts": "<ISO-8601 UTC>",
  "confidence": 0.0,
  "evidence": {
    "source": "lease_overlap | path_pattern_match | gap_dependency_chain | skill_starvation",
    "details": "<one-sentence explanation>",
    "shared_paths": ["<path-1>", "<path-2>"],
    "lookahead_window_s": 0
  },
  "recommended_action": "stand_down_A | stand_down_B | dispatch_handoff | redispatch_gap | ignore",
  "session": "<predictor session id>"
}
```

### Required fields

| Field                    | Type             | Meaning                                        |
|--------------------------|------------------|------------------------------------------------|
| `ts`                     | ISO-8601 UTC     | When the prediction was emitted                |
| `kind`                   | `collision_predicted` | Constant; registered in EVENT_REGISTRY.yaml |
| `schema_version`         | `collision-prediction-v1` | Schema versioning string             |
| `agents`                 | array of 2 objects | The two agents predicted to collide          |
| `predicted_collision_ts` | ISO-8601 UTC     | Best-estimate timestamp the conflict materializes |
| `confidence`             | float 0.0..1.0   | Predictor's certainty (see scoring below)      |
| `evidence`               | object           | What triggered the prediction (4 sub-fields)   |
| `recommended_action`     | enum (5 values)  | Predictor's recommended mitigation             |
| `session`                | session id       | Emitter (the predictor itself)                 |

### Optional fields

| Field                | Type              | Meaning                                       |
|----------------------|-------------------|-----------------------------------------------|
| `corr_id`            | string            | Correlation id; reused if the same prediction re-fires |
| `superseded_by`      | event UUID        | If a later prediction supersedes this one     |

## Confidence scoring

The predictor MUST emit a confidence in `[0.0, 1.0]`. Scale:

| Range       | Meaning                                                   |
|-------------|-----------------------------------------------------------|
| `0.0 – 0.4` | Speculative — based on weak signal (e.g. skill overlap only) |
| `0.4 – 0.7` | Likely — multiple signals align (lease + dependency)      |
| `0.7 – 0.9` | Strong — direct path overlap with active claim            |
| `0.9 – 1.0` | Certain — already-conflicting CAS or guaranteed-overlap   |

Predictor implementations MUST document how they compute the score (e.g. weighted sum of signal sources). The score is the operator's filter — below `0.4` is dashboard-only, above `0.7` is broadcast WARN, above `0.9` is broadcast ALERT.

## Evidence-source taxonomy

The `evidence.source` field is one of:

- **`lease_overlap`** — Two active leases share at least one path. Already a hard collision; confidence ~0.95+.
- **`path_pattern_match`** — Agent A's claim paths and Agent B's *predicted* paths (from gap description / AC) share a directory or glob pattern. Confidence 0.5–0.8.
- **`gap_dependency_chain`** — Agent A holds gap X, Agent B holds gap Y, and X depends on Y (or Y on X). The slower one will block the other. Confidence 0.4–0.7.
- **`skill_starvation`** — Both agents have the same `manifest_skills`, only one gap in the pickable pool matches that skill — they're about to race. Confidence 0.3–0.5.

## Recommended-action taxonomy

The `recommended_action` field is one of:

- **`stand_down_A`** — Agent A should release lease (typically because A's gap is lower-priority).
- **`stand_down_B`** — Mirror.
- **`dispatch_handoff`** — One agent should send `ask-handoff` (INFRA-1828 / INFRA-1119) to the other.
- **`redispatch_gap`** — Re-route one agent's gap to a different worker via skill-routing (META-077).
- **`ignore`** — Prediction filed for dashboard, no operator action required (low confidence).

## Lifecycle

1. **Emit** — predictor publishes `kind=collision_predicted` to ambient.jsonl AND to a `collision-radar` NATS subject for real-time consumers.
2. **Visibility** — PWA dashboard (INFRA-1883) surfaces predictions above the confidence cutoff.
3. **Action** — orchestrator OR operator chooses the recommended action.
4. **Resolution** — when the prediction is acted on (or expires past `predicted_collision_ts`), predictor emits `kind=collision_resolved` referencing the original event's `corr_id`.

## Companion event: `collision_resolved`

```json
{
  "ts": "<ISO-8601 UTC>",
  "kind": "collision_resolved",
  "corr_id": "<the predicted event's corr_id>",
  "resolution": "stood_down | handoff_accepted | redispatched | self_avoided | materialized",
  "actual_collision": true | false,
  "predicted_ts_drift_s": <int>,
  "session": "<predictor session id>"
}
```

`actual_collision: true` + `materialized` is a false-negative on prevention. False-positive rate = `actual_collision: false` count divided by total predictions; this is the predictor's accuracy signal.

## Registry note

Both kinds (`collision_predicted` and `collision_resolved`) MUST be registered in `docs/observability/EVENT_REGISTRY.yaml` before the first emitter ships. Registration is the responsibility of META-076 (the first implementation) — this doc is the schema spec only.

## Cross-references

- META-073 — parent epic (forward-looking coordination)
- META-076 — first implementation (mock inputs, validates this schema)
- META-077 — skill-aware routing schema (uses `manifest_skills` from this schema's `agents` field)
- META-081 — collision↔routing integration (consumes both schemas)
- META-083 — failure-class taxonomy (reactive companion)
- INFRA-1825 — CapabilityManifest publish loop (source of `manifest_skills`)
- INFRA-1828 — A2A RPC bash wrappers (ask-overlap, ask-handoff implement the recommended actions)
