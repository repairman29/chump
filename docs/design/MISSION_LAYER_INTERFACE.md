---
doc_tag: design-architecture
audience: operator, fleet engineers, external collaborators (Marcus, Anthropic, partners)
purpose: Public interface design for the mission/intent layer. Defines trait surfaces, serde shapes, and channel namespacing that the public chump repo exposes. The reference implementation for robotics lives in the internal sibling repo ; this doc only describes the public-facing API contracts.
status: v1 (2026-05-29) — proposed; pairs with docs/strategy/OFFLINE_ROADMAP_2026Q2.md (INFRA-2246), implementation gaps INFRA-2247 + INFRA-2248
---

# Mission Layer Interface (Public API Surface)

> **Source attribution.** The trait shapes, type structures, and channel namespacing in this document are derived from the architecture of the mission layer in [the internal sibling repo](<internal>) — specifically `crates/coord/src/mission/` and `crates/coord/src/mesh/`. That repo is private (robotics + reconnaissance work that isn't ready for public release). This doc describes only the **public-facing API contracts** that the public `chump-coord` crate exposes; the reference implementation and the IP-bearing algorithms (multi-robot consensus, LoRa transport, threat-classification replanners) remain in internal sibling repo. The goal is to share enough interface design that public users can build alternative implementations (or no implementation at all — defaulting to single-node in-process operation) without exposing the bits that aren't ready for public review.

## Why this layer exists

The public chump repo today is GitHub-coupled: PR creation, auto-merge, branch-protection rulesets, GitHub Actions CI, GitHub Actions secrets. When a remote dependency hiccups (today's incident: sccache R2 secret pair mismatch wedged 40 PRs for 90+ minutes), the whole fleet stalls.

The internal mission layer was built for robotics, where "phone home for permission" isn't an option — the robot has to hold durable intent, make local decisions, and reconcile when comms return. That same pattern is exactly what an offline-first developer fleet needs.

This doc defines the **bridge**: how to lift the public-relevant parts of the internal mission layer into the public chump-coord crate as **traits and serde shapes**, so:

- Public users (no internal-repo access) get a working single-node default and a clean abstraction to plug their own implementations into
- Internal-repo users (robotics deployments) keep using the robot-grade implementations transparently
- External collaborators (Marcus, Anthropic, design partners) can reason about offline-first design without seeing internal-only IP
- The public-side offline-first work (INFRA-2251 / INFRA-2252 / INFRA-1322 / INFRA-1323 / INFRA-1325) has stable interfaces to gate against

## Scope boundary — what's public vs private

| Layer | Public chump-coord | internal sibling repo |
|---|---|---|
| `Mission` / `PersistentMission` serde shapes | trait + struct definitions, default impl | unchanged (current implementation) |
| `MissionRuntime` trait | trait + `LocalProcessRuntime` default | `RobotMissionRuntime` |
| `MissionReplanner` trait | trait + `AbortOnFailure` default | `MissionReplanner` with full strategy table |
| `MeshTransport` trait | trait + `LocalProcessTransport` default | `LoRaMeshTransport`, `NatsMeshTransport` |
| `Channel` + named channel helpers | struct + chump-coord channels | mission/robot/swarm channels |
| `BandwidthBudget` / `MessageQueue` | structs (filed as INFRA-1804) | unchanged |
| Behavior trees (composites/decorators/leaves) | **not lifted** — out of scope for offline-first roadmap | internal sibling owns the BT runtime |
| Consensus (multi-node agreement) | **not lifted** — out of scope until concrete need | internal sibling owns the consensus impl |

## Trait surfaces

### `Mission` (shape, not the type itself — public users define their own concrete missions)

```rust
/// Durable intent — survives node restarts, transports across nodes,
/// has replay-attack protection via version.
///
/// Concrete missions for code-work-tracking (gap shipping) will look
/// different from robotics missions (target acquisition, sensor
/// deployment). Both share this trait surface.
pub trait Mission: Clone + Send + Sync + serde::Serialize + serde::de::DeserializeOwned {
    /// Globally unique mission identifier.
    fn id(&self) -> &str;

    /// Human-readable label.
    fn name(&self) -> &str;

    /// Ordered list of objectives — each is a discrete unit of work.
    /// Concrete implementations parameterize `Objective`.
    type Objective: serde::Serialize + serde::de::DeserializeOwned;
    fn objectives(&self) -> &[Self::Objective];

    /// ISO-8601 timestamp of issuance.
    fn timestamp_issued(&self) -> &str;

    /// How long this mission stays valid (seconds since `timestamp_issued`).
    fn ttl_seconds(&self) -> u32;

    /// Version number — increments on each amend; used to reject stale
    /// missions reissued on a slow comms channel.
    fn version(&self) -> u32;

    /// What to do when an objective can't be fulfilled as issued.
    fn fallback_behavior(&self) -> FallbackMode;
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub enum FallbackMode {
    /// Best-effort — skip failed objectives, continue with what's possible.
    Resilient,
    /// Strict — first failure aborts the whole mission.
    Strict,
    /// Operator-decides — pause and emit `kind=mission_needs_operator`.
    EscalateToOperator,
}
```

### `PersistentMission` (checkpoint-based execution graph)

```rust
/// Mission with checkpoint state attached. Survives process restarts
/// because checkpoint state is serialized to durable storage (default
/// `~/.chump/missions/<id>.json`; internal sibling uses sled / NATS KV).
pub struct PersistentMission<M: Mission> {
    pub mission: M,
    pub checkpoint: MissionCheckpoint<M>,
}

pub struct MissionCheckpoint<M: Mission> {
    /// State per objective — what's started, completed, failed, denied.
    pub objective_states: std::collections::HashMap<String, ObjectiveState>,
    /// Dependency graph — which objectives depend on which.
    pub dependencies: Vec<ObjectiveDependency>,
    /// Last-update timestamp (ISO-8601).
    pub last_update: String,
    /// Replan attempt count — for circuit-breaking.
    pub replan_count: u32,
    #[serde(skip)]
    _marker: std::marker::PhantomData<M>,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub enum ObjectiveState {
    Pending,
    InProgress { started_at: String },
    Completed { completed_at: String },
    Failed { reason: String, at: String },
    Denied { denial: Denial, at: String },
    Replanned { strategy: ReplanStrategy, at: String },
}
```

### `MissionReplanner` (autonomous decision logic)

```rust
/// Choose what to do when an objective is denied. The default impl
/// in chump-coord always returns `Abort` — for any real autonomy
/// (skipping, fallback-target retry, location-agnostic completion),
/// applications plug in their own `MissionReplanner`.
pub trait MissionReplanner: Send + Sync {
    fn choose_strategy(
        &self,
        objective: &dyn ObjectiveQuery,
        denial: &Denial,
        fallback_targets: &[Target],
    ) -> ReplanStrategy;
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub enum ReplanStrategy {
    Skip,
    RetryWithFallback,
    RemoveTarget,
    Abort,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub enum Denial {
    OutOfBounds,
    Prohibited,
    NotAuthorized,
    InsufficientResources, // generalization of the internal sibling's `InsufficientBattery`
    Expired,
    Other(String),
}
```

### `MeshTransport` (pub-sub over arbitrary networks)

```rust
/// Pub-sub abstraction. Default `LocalProcessTransport` provides
/// in-process channels; internal sibling implementations provide LoRa
/// (no-internet radios), NATS (local network), and clustered
/// implementations.
#[async_trait::async_trait]
pub trait MeshTransport: Send + Sync {
    async fn publish(&self, channel: &Channel, message: &Message) -> Result<(), MeshError>;

    async fn subscribe(&self, channel: &Channel)
        -> Result<tokio::sync::broadcast::Receiver<Message>, MeshError>;

    async fn await_ack(&self, message_id: &str, timeout_ms: u32) -> Result<AckMessage, MeshError>;
}

pub struct Channel { pub name: String }
pub struct Message { pub id: String, pub payload: serde_json::Value, pub ack_required: bool }
pub struct AckMessage { pub message_id: String, pub from: String, pub timestamp: String }
```

### Named channel helpers

The internal repo defines channels like `mission/issued/<id>`, `mission/status/<id>`, `robot/heartbeat/<id>`, `swarm/consensus/<topic>`. Public chump-coord defines analogous channels for code work:

```rust
pub mod channels {
    use super::Channel;
    pub fn gap_issued(gap_id: &str)    -> Channel { Channel::new(&format!("gap/issued/{gap_id}")) }
    pub fn gap_claimed(gap_id: &str)   -> Channel { Channel::new(&format!("gap/claimed/{gap_id}")) }
    pub fn gap_shipped(gap_id: &str)   -> Channel { Channel::new(&format!("gap/shipped/{gap_id}")) }
    pub fn pr_state(pr_num: u32)       -> Channel { Channel::new(&format!("pr/state/{pr_num}")) }
    pub fn curator_heartbeat(role: &str) -> Channel { Channel::new(&format!("curator/heartbeat/{role}")) }
    pub fn fleet_consensus(topic: &str) -> Channel { Channel::new(&format!("fleet/consensus/{topic}")) }
}
```

Internal stays the canonical channel-namespace owner for `mission/*`, `robot/*`, `swarm/*`. Public chump-coord owns `gap/*`, `pr/*`, `curator/*`, `fleet/*`. The two namespaces coexist on the same transport without collision.

## `BandwidthBudget` + `MessageQueue` (INFRA-1804)

Already filed as INFRA-1804 — "import BandwidthBudget + MessageQueue offline-fallback patterns from internal sibling repo; wire into INFRA-1758 file-fallback + chump_gh throttle layer."

These are pure data structures with serde — easiest to lift. Tracking them under INFRA-1804 (not duplicating here).

## Default implementations (what ships in public chump-coord)

The public crate provides minimal-functional defaults so users without internal still get a working system:

- **`LocalProcessTransport`** — in-memory `tokio::sync::broadcast` channels. Single-node only. No durability. Useful for tests and single-machine fleets.
- **`AbortOnFailureReplanner`** — returns `ReplanStrategy::Abort` for every denial. Conservative. Users plug in their own for any real autonomy.
- **`FileBackedMissionStore`** — persists `PersistentMission<M>` to JSON files under `~/.chump/missions/`. Single-node, append-only.
- **`InMemoryMissionRuntime`** — drives a `PersistentMission<M>` forward, calls the `MissionReplanner` on denials, writes checkpoints via `FileBackedMissionStore`. No network coordination.

This is enough for the "airplane mode" scenario in `OFFLINE_FIRST.md`. The "Pi mesh" scenario needs the internal sibling's LoRa transport or a NATS-backed transport (filed as `INFRA-1118` slice 2-4).

## Out of scope (this doc, this roadmap)

- **Behavior tree runtime.** Internal has a full BT crate (`crates/behavior/`). Whether curator loops benefit from BT-style execution is an open question — filed as a follow-up gap rather than baked into the offline-first roadmap.
- **Distributed consensus.** Internal has multi-robot consensus. Public chump-coord uses NATS KV CAS for atomic gap claims (`try_claim_gap` per FLEET-034), which covers the current fleet-coord need. Lift the internal consensus only when a concrete public use case demands it.
- **Robot hardware abstraction.** `crates/hal/` and `crates/chassis-*/` stay internal. No public-side equivalent.

## Implementation gaps

- `INFRA-2247` — Lift `Mission` / `PersistentMission` / `ObjectiveState` / `Denial` / `ReplanStrategy` / `FallbackMode` type shapes into `crates/chump-coord`. Pure serde + trait definitions. No runtime logic.
- `INFRA-2248` — Lift `MeshTransport` trait + `Channel` + `Message` + `AckMessage` + named-channel helpers + `LocalProcessTransport` default impl. Extends INFRA-1758 (already shipped — `subscribe_events` stub) with the full pub-sub trait.
- `INFRA-1804` (already filed) — Lift `BandwidthBudget` + `MessageQueue`. Wire into INFRA-1758 file-fallback path.

## Cross-references

- `docs/design/OFFLINE_FIRST.md` — overall offline-first architecture (Pi Mesh vs Airplane Mode scenarios)
- `docs/strategy/OFFLINE_ROADMAP_2026Q2.md` — consolidated roadmap (INFRA-2246, this PR)
- `docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md` — gap-filing rubric + INFRA-1418 linter
- `docs/design/A2A_ROADMAP.md` (META-061) — agent-to-agent comms roadmap; `MeshTransport` is the load-bearing primitive for Layer 1a (INFRA-1118)

## FAQ

**Q. Doesn't lifting these traits into public reveal internal-only IP?**
A. No — the trait *shapes* (function signatures + serde field structure) are commodity software-engineering patterns. The private value is in the *implementations*: which targets to assign to which robot under what conditions, multi-robot consensus algorithms tuned to specific datasets, LoRa-link reliability layers under specific RF conditions. Those don't move. The interface is just enough to let public-side offline-first work proceed.

**Q. Why now?**
A. Today's sccache R2 incident wedged 40 PRs for 90+ min on a remote service hiccup. Pattern 14 verified the queue was healthy modulo the remote dependency. Offline-first eliminates this entire failure class — and internal already solved the hardest parts (durable intent, autonomous decision-making) for robotics. Lifting the interfaces is a 2-PR ship that unlocks the public-side roadmap.

**Q. Who owns this?**
A. Public-side trait/serde definitions: chump (this repo), via `crates/chump-coord`. Reference implementation + IP-bearing logic: internal sibling repo, unchanged. Bridge / integration: tracked under INFRA-2246.
