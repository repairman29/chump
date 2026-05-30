# Mission Types — public surface (INFRA-2247, META-164 foundation)

This document is the type catalog for the public mission-orchestration
surface added to `chump-coord` under [`crates/chump-coord/src/mission/`](../../crates/chump-coord/src/mission/).
It is the **keystone** for META-164 (the Mission orchestrator / Rainbow-6
squad system). Once these shapes are stable, the orchestrator daemon,
mission-aware picker, CLI surface, and PWA visualization plug into them
as incremental wiring slices.

The types are derived from established Rust mission-execution prior art
and adapted for agent-fleet semantics. Physical-only fields (geo,
bounding boxes, obstacle catalogs) are deliberately omitted — those
remain in a private extension and never need to leak into the public
crate.

## Adaptation summary

| Original concept (physical fleet) | Public surface here (agent fleet) |
|---|---|
| `energy_cost` — battery / fuel | `resource_cost` — token-budget estimate (aligns with INFRA-2090) |
| `target` — geo coordinates + ROE | `target: Option<String>` — HITL approval gate reference (aligns with INFRA-1813) |
| `bounding_box`, `MissionObstacle`, `GeoLocation` | dropped from public surface; live in a private extension |
| `FallbackMode` semantics | preserved verbatim; map to curator behaviors |

## Module layout

```
crates/chump-coord/src/mission/
├── mod.rs            // public re-exports + doc
├── persistence.rs    // data types + store trait + FileBackedMissionStore
└── replanning.rs     // MissionReplanner trait + AbortOnFailureReplanner
```

The split keeps the data layer stable as the policy layer evolves; a
new replanner impl never forces a schema change.

## Type catalog

### `Mission`

The top-level plan handed to an orchestrator.

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | Stable identifier; doubles as the on-disk file stem |
| `name` | `String` | Human-readable label |
| `objectives` | `Vec<Objective>` | Ordered by `sequence` then by `id` |
| `fallback_behavior` | `FallbackMode` | What to do when nothing is runnable |
| `timestamp_issued` | `String` | RFC3339 of plan issue |
| `ttl_seconds` | `u32` | Soft deadline from issue time |
| `version` | `u32` | Bumped on in-place replan |

### `Objective`

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | Unique inside the mission |
| `description` | `String` | One-line intent |
| `resource_cost` | `u32` | Token-budget estimate (INFRA-2090) |
| `duration_secs` | `u32` | Soft time bound; WARN past this |
| `target` | `Option<String>` | HITL approval gate ref (INFRA-1813); `None` skips approval |
| `sequence` | `u32` | Ordering hint; ties broken by `id` |

### `ObjectiveState`

State machine — checkpoint history is append-only; *current* state is
the latest checkpoint for an `objective_id`.

```text
Pending      → InProgress | Skipped | Failed
InProgress   → Completed  | Failed  | Skipped
Completed    → (terminal)
Failed       → (terminal; replan re-arm to Pending allowed)
Skipped      → (terminal)
```

### `MissionCheckpoint`

| Field | Type |
|---|---|
| `mission_id` | `String` |
| `objective_id` | `String` |
| `state` | `ObjectiveState` |
| `ts` | `String` (RFC3339) |

### `ObjectiveDependency` / `DependencyCondition`

DAG edge between two objectives. The edge is **satisfied** when the
condition holds for `from`:

| Condition | Edge satisfied when `from` is in |
|---|---|
| `Completed` | `Completed` |
| `Started` | `InProgress` or beyond |
| `Skipped` | `Skipped` |

### `PersistentMission`

The persistence envelope — a `Mission` plus its append-only
`Vec<MissionCheckpoint>`. Construct with `::new(mission)` and append
state transitions via `checkpoint(obj_id, state, ts)` (which validates
the transition first).

### `MissionStore` trait

```rust
pub trait MissionStore {
    fn save(&self, m: &PersistentMission) -> Result<()>;
    fn load(&self, id: &str) -> Result<PersistentMission>;
    fn list(&self) -> Result<Vec<String>>;
}
```

### `FileBackedMissionStore`

Default impl — one JSON file per mission at `~/.chump/missions/<id>.json`.
`::default_root()` selects the conventional path; `::new(root)` lets tests
point at a `tempfile::TempDir`. `list()` returns sorted file stems and
treats a missing root as empty.

### `MissionReplanner` trait + `ReplanStrategy`

```rust
pub enum ReplanStrategy {
    Abort,
    RetryWithBackoff { max_attempts: u32 },
    DegradeToSimpler,
    HumanEscalate,
}

pub trait MissionReplanner {
    fn replan_on_denial(&self, mission: &Mission, denied: &Objective) -> ReplanStrategy;
    fn replan_on_failure(&self, mission: &Mission, failed: &Objective) -> ReplanStrategy;
}
```

Pure policy interface — replanners return a strategy; the orchestrator
applies it.

### `AbortOnFailureReplanner`

Conservative default — every denial and every failure returns
`ReplanStrategy::Abort`. Safe to plug in when no opinion exists yet
about retry vs escalation. Richer impls are opt-in.

### `FallbackMode`

What the orchestrator does when no objective is runnable.

| Variant | Behavior |
|---|---|
| `SafeShutdown` | Stop cleanly, release leases, exit zero |
| `ReturnToBase` | Roll back in-flight work; surface mission as resumable |
| `QueryAuthority` | Pause; wait for an operator decision via inbox |
| `ContinueLastTask` | Keep doing whatever the last running objective was doing |
| `SkipAndContinue` | Mark current objective skipped; try next |

## Example mission JSON

```json
{
  "mission": {
    "id": "demo-001",
    "name": "warm caches then run audit",
    "objectives": [
      {
        "id": "warm-cache",
        "description": "prime github_cache.db for the open PR set",
        "resource_cost": 200,
        "duration_secs": 60,
        "target": null,
        "sequence": 0
      },
      {
        "id": "run-audit",
        "description": "produce gap-audit report; needs operator sign-off",
        "resource_cost": 1500,
        "duration_secs": 600,
        "target": "hitl-gate-audit-2026-05-30",
        "sequence": 1
      }
    ],
    "fallback_behavior": "safe_shutdown",
    "timestamp_issued": "2026-05-30T06:30:00Z",
    "ttl_seconds": 7200,
    "version": 1
  },
  "checkpoints": [
    {
      "mission_id": "demo-001",
      "objective_id": "warm-cache",
      "state": "in_progress",
      "ts": "2026-05-30T06:31:00Z"
    },
    {
      "mission_id": "demo-001",
      "objective_id": "warm-cache",
      "state": "completed",
      "ts": "2026-05-30T06:32:30Z"
    }
  ]
}
```

## What ships next (incremental wiring slices, separate gaps)

Once these shapes are stable, follow-on slices become incremental:

- Mission orchestrator daemon (consumes `PersistentMission`, drives the state machine).
- Mission-aware picker (reads `Objective::target` for HITL gate routing).
- CLI surface (`chump mission show / list / advance`).
- PWA viz (render the DAG + checkpoint history live).
- Rich replanner impls (retry-with-backoff, human-escalate via inbox).

This gap (INFRA-2247) ships only the **shapes**; the wiring lands later.
