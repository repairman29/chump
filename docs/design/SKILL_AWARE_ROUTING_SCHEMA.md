# Skill-Aware Routing Event Schema

> META-077 (META-073 child slice, Track 2 of 3). Defines the on-wire event
> shape for skill-aware gap-to-agent routing. The picker uses this to decide
> *which* agent should claim *which* gap when multiple candidates exist.
>
> Pairs with META-075 (collision prediction — uses the same `manifest_skills`
> source) and INFRA-1825 #2428 CapabilityManifest publish loop (provides the
> backing data per agent).

## Why a routing event layer

Today's picker (`scripts/dispatch/_pick_and_claim_gap.py`) routes by
round-robin + lease-collision-avoidance — no concept of *skill match*. A
Rust-specialist agent and a docs-specialist agent are equally likely to
claim a Rust gap; the docs specialist then struggles, and we eat the
re-route latency.

A skill-aware layer reads each pickable gap's `skills_required` field, each
active agent's `CapabilityManifest.skills` (INFRA-1825), and emits a
**routing decision event** with a score. The picker honors the highest
score with a freshness tie-breaker.

## Wire format (v1)

```json
{
  "ts": "<ISO-8601 UTC>",
  "kind": "routing_decision",
  "schema_version": "skill-routing-v1",
  "gap_id": "INFRA-NNNN",
  "task_type": "rust_impl | docs_only | shell_only | ci_only | mixed | unknown",
  "required_skills": ["rust", "tokio", "sqlite"],
  "candidates": [
    {
      "session": "<session-id>",
      "skills": ["rust", "tokio", "sqlite", "macos"],
      "match_score": 1.0,
      "freshness_age_s": 12,
      "current_load_gaps": 1
    }
  ],
  "selected_session": "<session-id>",
  "selection_reason": "skill_superset | best_partial_match | fallback_round_robin | no_match",
  "session": "<router session id>"
}
```

### Required fields

| Field                | Type                | Meaning                                       |
|----------------------|---------------------|-----------------------------------------------|
| `ts`                 | ISO-8601 UTC        | When the routing decision was made            |
| `kind`               | `routing_decision`  | Constant; registered in EVENT_REGISTRY.yaml   |
| `schema_version`     | `skill-routing-v1`  | Schema version                                |
| `gap_id`             | string              | Gap being routed (INFRA-N / META-N / etc.)    |
| `task_type`          | enum (6 values)     | Derived from gap's title + file-path heuristics |
| `required_skills`    | array of strings    | From gap's `skills_required` (may be empty)   |
| `candidates`         | array of objects    | All eligible agents (post lease-collision filter) |
| `selected_session`   | session id OR null  | Winning candidate; null if `no_match`         |
| `selection_reason`   | enum (4 values)     | Why this candidate won                        |
| `session`            | session id          | Emitter (the router)                          |

### Candidate sub-schema

| Field                 | Type                | Meaning                                       |
|-----------------------|---------------------|-----------------------------------------------|
| `session`             | session id          | Candidate's session                           |
| `skills`              | array of strings    | From their CapabilityManifest                 |
| `match_score`         | float 0.0..1.0      | See scoring formula below                     |
| `freshness_age_s`     | int                 | Seconds since candidate's last heartbeat      |
| `current_load_gaps`   | int                 | How many gaps they hold leases on right now   |

## Match-score formula

Given `required = gap.skills_required` and `have = candidate.skills`:

```
match_score = |required ∩ have| / |required ∪ have|     (Jaccard)
```

Edge cases:
- `required = []` (no skills required) → score = 1.0 for ALL candidates (any can do it)
- `required != [] AND |required ∩ have| = 0` → score = 0.0 (no match)
- `required ⊆ have` (have is superset) → score in [|required|/|have|, 1.0]
- `required = have` exactly → score = 1.0

The Jaccard variant punishes over-broad candidates: a generalist with 20
skills loses to a specialist with the exact 3 required, because the
specialist's Jaccard is higher.

## Selection-reason taxonomy

The `selection_reason` field is one of:

- **`skill_superset`** — Selected candidate's skills ⊇ required AND tied with others on score → freshness tiebreaker won.
- **`best_partial_match`** — No candidate had full coverage; selected the highest match_score.
- **`fallback_round_robin`** — All candidates scored 0.0 OR `required = []`; fell back to load-balancing round-robin.
- **`no_match`** — Required skills present but no candidate has ANY of them → `selected_session: null`, gap stays in queue. Emits sibling event `kind=skill_routing_no_match` for operator visibility.

## Tie-breaker order

When multiple candidates have the same `match_score`:

1. Highest freshness (lowest `freshness_age_s`) — fresher agents are more likely to respond
2. Lowest `current_load_gaps` — least busy gets the work
3. Lexicographic by `session` — deterministic fallback so two routers reach the same answer

## Lifecycle

1. **Trigger** — picker runs (every claim attempt) OR push-route assigner (FLEET-034) emits one.
2. **Compute** — router reads all active CapabilityManifests (INFRA-1825) + the gap's `skills_required`.
3. **Emit** — `kind=routing_decision` written to ambient AND published on `chump.routing.<priority>.<class>.<machine>` subject for real-time consumers.
4. **Act** — picker claims the gap on behalf of `selected_session` (or skips if null).
5. **Audit** — `chump fleet routing-audit` (filed as follow-up) walks ambient looking for patterns: top-K skill misses, over-served vs under-served agents, drift in match_score over time.

## Companion event: `skill_routing_no_match`

```json
{
  "ts": "<ISO-8601 UTC>",
  "kind": "skill_routing_no_match",
  "gap_id": "INFRA-NNNN",
  "required_skills": ["rare_skill_x"],
  "available_skill_sets": [["rust", "docs"], ["python", "ci"]],
  "session": "<router session id>"
}
```

Operator visibility: if this event fires often, it's signal that the
fleet has a skill-gap an operator should fill (either by upgrading an
existing agent's manifest or by spinning up a specialist).

## Registry note

Both kinds (`routing_decision`, `skill_routing_no_match`) MUST be
registered in `docs/observability/EVENT_REGISTRY.yaml` before the
first emitter ships. Registration is the responsibility of META-078
(the first implementation) — this doc is schema spec only.

## Cross-references

- META-073 — parent epic (forward-looking coordination)
- META-075 — collision prediction schema (uses same `manifest_skills` source)
- META-078 — first implementation (stub skills DB)
- META-081 — collision↔routing integration (consumes both schemas)
- META-083 — failure-class taxonomy (reactive companion)
- INFRA-1825 #2428 — CapabilityManifest publish loop (source of `skills`)
- INFRA-1828 — A2A RPC bash wrappers (`ask-capability` queries this layer)
- FLEET-034 — push routing (consumes routing_decision for assignment)
