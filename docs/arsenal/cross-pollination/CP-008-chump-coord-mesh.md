# CP-008: Extract chump-coord-mesh crate from chump-proprietary

**Target:** public Chump's coord layer (INFRA-1118/1119/1120/1121 A2A layers + INFRA-1758/1759/1761/1802/1803 active work + INFRA-1804 BandwidthBudget port)
**Arsenal match:** `chump-proprietary/crates/coord/` (locally cloned at `/Users/jeffadkins/Projects/chump-proprietary/crates/coord/`)
**Recommended route:** **Dependency** (extract shared subset to new `chump-coord-mesh` crate inside chump-proprietary; both repos depend on it)
**Status:** proposed (Harvester, 2026-05-23, INFRA-1815)

> **Big finding:** chump-proprietary/crates/coord/Cargo.toml line 5 declares `license = "MIT"`. The substrate is already open-source-compatible. The risk we feared (proprietary→public leak) is not a licensing risk; it is a **duplication risk** — INFRA-1802/1803/1804 currently propose verbatim ports into public Chump, which would create two copies of the same MIT code that must drift in lockstep. CP-008 replaces "copy in" with "depend on a shared crate."

---

## The Target

Public Chump's `crates/chump-coord/` is becoming a NATS-backed A2A substrate (META-061; A2A_ROADMAP.md layers 1a/2b/2c/3d/4):

| Layer | Slice gap | Status | Surface being built |
|---|---|---|---|
| 1a pub/sub events | INFRA-1758 | open | `subscribe_events(EventFilter) -> Stream<CoordEvent>` (events.rs L20-60) |
| 2b RPC | INFRA-1759 | **done** (PR 2379) | `call_rpc/serve_rpc` with `RpcRequest{request_id,method,args,sent_at}` |
| 2c capability manifest | INFRA-1760 | open | `CapabilityManifest{schema_version, session_id, harness, skills, …}` |
| 3d scratchpad | INFRA-1761 | open | NATS KV `chump_scratch` + 5 seed keys + `ConflictPolicy` enum (scratchpad.rs L37-60) |
| Mesh transport | INFRA-1802 | open | `MeshTransport` trait + `Channel/Message/AckMessage` (proposed verbatim port) |
| Consensus voting | INFRA-1803 | open | `Vote/VoteProof/ConsensusDecision` (proposed verbatim port) |
| Bandwidth/queue | INFRA-1804 | open | `BandwidthBudget/MessageQueue` (proposed verbatim port; depends_on 1802) |

**INFRA-1802, INFRA-1803, INFRA-1804 each cite chump-proprietary as the source and propose "port verbatim under MIT."** CP-008's value-add is making those three ports share a crate so the substrate has one canonical home, not two copies.

---

## The Arsenal Match — chump-proprietary/crates/coord

Surveyed at `/Users/jeffadkins/Projects/chump-proprietary/crates/coord/src/` (4,672 LOC across 16 .rs files). Top-level module surface from `lib.rs` L10-16:

```rust
pub mod audit;       // 562 LOC — ThermalDetection, MissionObstacle, SurveillanceDevice
pub mod consensus;   // 435 LOC — Vote, VoteProof, ConsensusCoordinator (domain-agnostic)
pub mod executor;    // 329 LOC — MissionExecutor (binds mission+safety, robot-specific)
pub mod integration; // 291 LOC — gap→mission translation (robot-specific)
pub mod mesh;        // 784 LOC across mod.rs/abstract_impl.rs/simulator.rs/test_simulator.rs
pub mod mission;     // 1,260 LOC across mod.rs/execution/persistence/replanning
pub mod safety;      // 359 LOC — RulesOfEngagement, GeoFence, prohibited_targets
```

### Shareable subset (domain-agnostic — extract into chump-coord-mesh)

**`mesh::abstract_impl`** (`mesh/abstract_impl.rs` L1-265):
- `Channel{name}` (L135-148) — namespace identifier; `Channel::new(&str)`
- `Message{id, timestamp, channel, payload, source, signature}` (L11-25) — wire envelope, opaque payload
- `AckMessage{message_id, timestamp, source}` (L28-36) — ack envelope
- `BandwidthBudget{remaining, total, window_seconds, window_start}` (L40-84) with `can_send(usize) -> bool`, `deduct(usize)`, `reset()`, `is_expired()`
- `MessageQueue{pending, max_size}` (L88-132) with `enqueue/dequeue/len/is_empty`
- `trait MeshTransport: Send + Sync` (L151-168) with `publish/subscribe/await_ack` (async via `async-trait`)
- `mod channels` (L171-197) — namespace helper fns (currently `mission_issued`, `robot_heartbeat`, `swarm_consensus`; public Chump renames per INFRA-1802 to `gap_claimed`, `session_heartbeat`, `fleet_consensus`)

**`consensus`** (`consensus/mod.rs` L1-435):
- `DecisionType` enum (L11-21) — `EscalationRequired`, `ThreatAssessment`, `ResourceCritical`, `NetworkPartitionRecovery` (per INFRA-1803, drop `ThreatAssessment` as robot-specific OR keep it generic as "anomaly" — see Migration sequence below)
- `Vote{Approve, Abort, Timeout}` enum + `is_committed()` (L25-39)
- `ConsensusDecision{Proceed, Abort, Inconclusive}` enum (L42-50)
- `VoteRequest{vote_id, initiator, decision_type, reason, context, quorum, timeout_secs}` (L52-69)
- `VoteProof{signature_tag, timestamp, vote}` (L72-80) — SHA256 of (vote_id + voter_id + vote + timestamp)
- `ConsensusRecord` with `finalize(req, votes) -> ConsensusRecord` and `summary() -> String` (L83-157)
- `ConsensusCoordinator` with `initiate_vote/cast_vote/finalize_vote/records/should_proceed` (L160-235)

**`mesh::simulator`** (`mesh/simulator.rs` L1-300) — `SimulatorMesh` + `NetworkConditions{latency_ms, packet_loss_rate, partition}`. Useful for integration tests in *both* repos; ship as a `simulator` feature flag.

### Proprietary-only subset (stays in chump-proprietary, NOT extracted)

- `audit::*` — `ThermalSourceType` (Human/Equipment), `ThermalDetection`, `MissionObstacle`, `SurveillanceDevice`. Tightly coupled to robot/swarm domain.
- `mission::*` — `Mission{objectives, fallback_behavior, ttl_seconds, bounding_box, obstacles}`, `Objective{energy_cost (battery), duration_secs, target, kind}`, `GeoLocation{latitude, longitude, altitude_m}`, `Target`, `FallbackMode{SafeShutdown, ReturnToBase, QueryAuthority, ContinueLastTask, SkipAndContinue, Resilient}`. Battery + GPS are physical-world, not agent-world.
- `safety::*` — `RulesOfEngagement{authorized_targets, prohibited_targets, geographic_boundary, min_battery_to_continue}`, `GeoFence`, `Zone`, `EscalationRule`, `Denial`, `TargetSpec`. Lethal-targeting semantics — public Chump does not need this.
- `executor::MissionExecutor` (executor.rs L23-230) — uses `battery: u32`, `home_location: GeoLocation`, `ObjectiveResult::Denied(safety::Denial)`. Wired to mission+safety, cannot decouple cleanly.
- `integration::*` — gap→mission translation in the robot direction. Stays proprietary; the reverse direction (mission outcome → gap close) lives in public Chump anyway.

---

## Extraction plan

### New crate layout — `chump-proprietary/crates/coord-mesh/`

```
chump-proprietary/
└── crates/
    ├── coord-mesh/          # NEW — extracted shared substrate (MIT)
    │   ├── Cargo.toml       # deps: tokio, serde, chrono, sha2, async-trait
    │   ├── src/
    │   │   ├── lib.rs       # re-exports
    │   │   ├── mesh.rs      # ← moved from coord/src/mesh/abstract_impl.rs
    │   │   ├── consensus.rs # ← moved from coord/src/consensus/mod.rs
    │   │   └── simulator.rs # ← moved from coord/src/mesh/simulator.rs (feature-gated)
    │   └── tests/
    │       ├── mesh_trait.rs
    │       └── consensus.rs
    └── coord/               # existing proprietary crate — slimmed
        └── src/
            ├── lib.rs       # re-exports from coord-mesh for backward compat
            ├── audit/       # unchanged
            ├── executor.rs  # unchanged
            ├── integration.rs # unchanged
            ├── mission/     # unchanged
            └── safety/      # unchanged
```

Naming choice: **`coord-mesh`** inside chump-proprietary (matches the existing `coord/` naming, easy diff). When public Chump declares the dep, the package name `coord-mesh` is descriptive enough; no rename needed.

### `crates/coord/` re-exports for backward compat

Inside chump-proprietary, `crates/coord/src/lib.rs` becomes:

```rust
//! Coordination substrate. Shareable primitives now live in `coord-mesh`;
//! this crate retains the robot-swarm-specific layer (mission, safety, executor, audit, integration).

pub use coord_mesh::{mesh, consensus};      // re-export the moved modules
pub use coord_mesh::mesh::{Channel, Message, AckMessage, BandwidthBudget, MessageQueue, MeshTransport};
pub use coord_mesh::consensus::{Vote, VoteProof, ConsensusDecision, ConsensusCoordinator, DecisionType, VoteRequest, ConsensusRecord};

pub mod audit;
pub mod executor;
pub mod integration;
pub mod mission;
pub mod safety;
```

Plus add `coord-mesh = { path = "../coord-mesh" }` to `crates/coord/Cargo.toml`. Internal call sites (`executor.rs` imports `use crate::mission::…`) keep working because `mission`/`safety`/`executor` did not move. Mesh consumers inside chump-proprietary (e.g. `mesh/test_simulator.rs`) get rewritten to `use coord_mesh::mesh::*` or use the re-export chain via `use coord::mesh::*`.

### Public Chump `crates/chump-coord/Cargo.toml` addition

Add (under the chosen consumption mechanism — see next section):

```toml
[dependencies]
coord-mesh = { git = "https://github.com/repairman29/chump-proprietary", rev = "<pinned-sha>", optional = true }

[features]
default = []
mesh = ["dep:coord-mesh"]
```

Then `crates/chump-coord/src/lib.rs` adds:

```rust
#[cfg(feature = "mesh")]
pub use coord_mesh::mesh;
#[cfg(feature = "mesh")]
pub use coord_mesh::consensus;
```

The feature flag means crates that don't need mesh (e.g. plain CLI helpers) don't pull the dep — important if/when chump-coord becomes a crates.io publication and we don't want to advertise a private git URL by default.

---

## Consumption mechanism — pick **(c) git submodule / git dep**, with a clear migration path to (b)

Three options were on the table:

**(a) path dependency** — `coord-mesh = { path = "../../../chump-proprietary/crates/coord-mesh" }`
- Pros: zero setup, instant compile cycle, works for Jeff's local dev today
- Cons: breaks every CI invocation that doesn't have chump-proprietary checked out at exactly that relative path; blocks `cargo publish` entirely; fragile

**(b) private cargo registry** — host `coord-mesh` on a private Kellnr/Shipyard/cargo-registry-binstall registry
- Pros: clean `cargo` semantics; publishable to crates.io later by flipping registry to default
- Cons: requires registry infra (token mgmt, ops burden); overkill for a single shared crate; chump-proprietary is a sibling repo Jeff already controls

**(c) git dependency with SHA pin** — `coord-mesh = { git = "https://github.com/repairman29/chump-proprietary", rev = "<sha>" }`
- Pros: no infra; reproducible (SHA-pinned); cargo handles cache; works on plane-mode after first fetch
- Cons: bumping the SHA is a manual sync step (mitigated by a periodic chore gap); requires `chump-proprietary` to be a github-private but cargo-accessible repo (it already is — Jeff's GH credentials are in keychain per CLAUDE.md INFRA-AGENT-CREDS)

**Decision: (c) git dep with SHA pin.** Matches Chump's offline-first ethos (no registry hosting), keeps cost at zero, and SHA pinning means a chump-proprietary refactor cannot silently break public Chump. When (and only when) public Chump prepares to publish to crates.io, swap (c) → (b) by publishing `coord-mesh` to a private registry — the import path stays identical.

**Rejected (a)** because it would break the GH Actions runners that don't have chump-proprietary on disk. **Rejected (b) for now** because the registry-ops burden is real and we have zero crates.io publications today.

Submodule alternative: a true `git submodule` for chump-proprietary would also work, but `cargo`'s native git-dep with `rev = "<sha>"` is the more idiomatic Rust path — submodule adds shell ceremony without value here.

---

## Migration sequence — per-gap conversion notes

Current state: INFRA-1758/1759/1761 are "build the foundation in public Chump"; INFRA-1802/1803/1804 are "copy verbatim from chump-proprietary." CP-008 reframes 1802/1803/1804 as **"consume from `coord-mesh`"** while 1758/1759/1761 stay as-is (they're net-new in public Chump — there's no proprietary equivalent of `EventFilter` or `CapabilityManifest`).

| Gap | Pre-CP-008 plan | Post-CP-008 plan | Effect on gap shape |
|---|---|---|---|
| **INFRA-1758** (events.rs `subscribe_events`) | Build stub in public Chump | Unchanged — `CoordEvent`/`EventFilter` are public-Chump-specific (ambient.jsonl shape) | No change |
| **INFRA-1759** (rpc.rs) — **already done (PR 2379)** | Built in public Chump | Already done; no proprietary equivalent existed | No change |
| **INFRA-1760** (capability.rs `CapabilityManifest`) | Build in public Chump | Unchanged — manifest is chump-skills-specific (model_tier, harness) | No change |
| **INFRA-1761** (scratchpad.rs seed keys + `ConflictPolicy`) | Build in public Chump | Unchanged — `chump_scratch` NATS bucket + seed keys are chump-specific | No change |
| **INFRA-1802** (mesh.rs port) | Copy `mesh/abstract_impl.rs` into `crates/chump-coord/src/mesh.rs` (~265 LOC port) | **Reduced to `pub use coord_mesh::mesh::*;` in `crates/chump-coord/src/lib.rs` + the channel-helper rename (gap_claimed/session_heartbeat/fleet_consensus) as a thin chump-specific wrapper** | Effort drops from `s` → `xs`. Acceptance criterion changes: instead of "port verbatim," now "add git dep + feature flag + chump channel helpers" |
| **INFRA-1803** (consensus.rs port) | Copy `consensus/mod.rs` into public Chump (~435 LOC port) | **Reduced to `pub use coord_mesh::consensus::*;`**. Keep the `DecisionType::ThreatAssessment` variant in `coord-mesh` (it's no longer "robot-specific" — rename to `Anomaly` in coord-mesh or leave as-is and let public Chump just not emit it). | Effort drops from `m` → `xs`. AC changes: no port, just re-export + chump-specific channel binding |
| **INFRA-1804** (BandwidthBudget + MessageQueue) | Port into `crates/chump-coord/src/mesh.rs`, then wire into chump_gh throttle layer | **Half-removed**: BandwidthBudget + MessageQueue ship via `coord-mesh::mesh::*`. The interesting half — "wire into chump_gh self-throttle, adapt bytes→tokens for LLM-agent calls" — stays as a gap because it's chump-specific glue. | Effort drops from `s` → `xs`. Renamed scope: "wire coord-mesh BandwidthBudget into chump_gh throttle" |
| **(new) INFRA-1815-A** | — | **Extract coord-mesh from chump-proprietary** (the actual physical move described in this brief, done in chump-proprietary repo, not public Chump). Lives as a chump-proprietary gap. | New gap (chump-proprietary side), `s` effort |
| **(new) INFRA-1815-B** | — | **Add coord-mesh git dep + feature flag in public Chump** with smoke test confirming `cargo build --features mesh` succeeds and re-exports compile. | New gap (public Chump), `xs` effort |

**Sequencing rule:** 1815-A lands first (chump-proprietary refactor + re-exports preserve backward compat). 1815-B lands next (public Chump adds the dep + flag). Then 1802/1803/1804 ship as thin re-exports + chump-specific glue. INFRA-1758/1760/1761 are independent and can ship in any order — they don't touch the mesh substrate.

---

## Lineage / Risk

**Risk 1 — chump-proprietary git dep is private; CI tokens must be in scope.**
Per CLAUDE.md "GitHub credentials for agents" section, fleet workers already inherit a GH token via keyring/explicit env. Cargo's git resolver uses the same git credential helper, so `cargo fetch` of `repairman29/chump-proprietary` works in worker context. Risk realized only if a CI runner runs as a different user with no token — mitigation: add `GH_TOKEN` to the `Cargo.toml` workflow envs, document in `docs/process/HARNESS_CONTRACT.md`.

**Risk 2 — SHA-pin drift.**
If public Chump pins `coord-mesh@sha:abc` and chump-proprietary's `coord-mesh` evolves, public Chump sees stale types. Mitigation: filed-on-extraction follow-up gap `INFRA-CHUMP-COORD-MESH-CADENCE` to bump the SHA monthly via a `dependabot.yml` or a scripted `cargo update -p coord-mesh` in `scripts/coord/refresh-mesh-dep.sh`.

**Risk 3 — ABI drift in shared types.**
`Message{payload: Vec<u8>}` is intentionally opaque, so a chump-proprietary that adds richer fields to `Vote` would still serde-round-trip from public Chump. But adding a non-`#[serde(default)]` field to `Channel` would break public Chump's JSON. Mitigation: documented contract in `coord-mesh/src/lib.rs` doc header: "additive-only changes to public structs; new fields require `#[serde(default)]`."

**Risk 4 — duplication of `simulator.rs` test infra across both repos.**
The `SimulatorMesh` was originally written for chump-proprietary's mission-replay tests. Public Chump's A2A integration tests (INFRA-1758 slice 2/4 "chaos test") will want the same thing. Ship `simulator` as a feature flag in `coord-mesh`: `[features] simulator = ["dep:rand"]`, off by default so the production builds don't pull `rand`.

**Risk 5 — the "extract" looks like it competes with INFRA-1822 (ACP alignment).**
Direction 1 of HARVEST_GROWTH_DIRECTIONS_2026-05-23.md proposes aligning chump-coord with ACP. CP-008 explicitly does *not* preempt that — `coord-mesh` is the mesh+consensus *substrate*, ACP is the *protocol shape that chump-coord exposes*. The two stack: ACP becomes the outer API contract, `coord-mesh` becomes the in-process building blocks. Post-CP-007 note: "ACP is NOT a sequencing constraint" confirms this.

**Risk 6 — proprietary→public leak via accidental import.**
The shared crate only contains MIT-licensed mesh + consensus code (no thermal detection, no rules of engagement, no GeoLocation, no Target). The proprietary content stays in `crates/coord/`. The lint we want: `cargo deny check sources` to assert public Chump only depends on `coord-mesh` and never on `coord` (the parent). Filed as INFRA-CHUMP-DENY-PROPRIETARY-DEP follow-up.

---

## What this brief does *not* do

It does not move any Rust code, does not edit any Cargo.toml, does not commit. It (a) confirms the shared subset, (b) chooses git-dep + SHA-pin as the consumption mechanism, and (c) restructures INFRA-1802/1803/1804 from "verbatim port" → "thin re-export + chump-specific glue." Execution lives in INFRA-1815-A (chump-proprietary refactor) and INFRA-1815-B (public Chump dep wiring), each filed as a follow-up to this brief.
