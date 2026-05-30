// crates/chump-coord/src/mesh_bridge.rs — INFRA-1815
//
// Feature-gated re-export facade for the coord-mesh substrate.
//
// ## Why this module exists
//
// INFRA-1802/1803/1804 ported mesh + consensus types verbatim into this
// crate. CP-008 (docs/arsenal/cross-pollination/CP-008-chump-coord-mesh.md)
// establishes that those types should ultimately live in a shared `coord-mesh`
// crate (extracted from the internal sibling repo) so both repos consume one
// canonical copy instead of two that drift.
//
// This module is the **migration shim**: when the `mesh-bridge` feature flag
// is active it exposes `chump_coord::mesh_bridge::*` which today re-exports
// from the local hand-rolled modules (mesh.rs, consensus.rs). Once Side A
// lands (INFRA-1815-sideA — create `crates/coord-mesh` in the internal
// sibling repo and uncomment the git dep in Cargo.toml), the `pub use`
// lines below switch from `crate::mesh::*` to `coord_mesh::mesh::*` with
// no change to call sites.
//
// ## Consumption (INFRA-1758 / INFRA-1763 / INFRA-1804)
//
// ```rust
// // Build with: cargo build --features mesh-bridge
// use chump_coord::mesh_bridge::{Channel, Message, MeshTransport, StubMesh};
// use chump_coord::mesh_bridge::consensus::ConsensusCoordinator;
// ```
//
// ## Activation checklist (after INFRA-1815-sideA ships)
//
// 1. Get the HEAD SHA from the internal sibling repo after `crates/coord-mesh/` lands.
// 2. In `crates/chump-coord/Cargo.toml`, uncomment the `[dependencies.coord-mesh]`
//    block and fill in the SHA.
// 3. Change the re-exports below from `crate::mesh::*` → `coord_mesh::mesh::*`
//    and `crate::consensus::*` → `coord_mesh::consensus::*`.
// 4. Change the feature line in Cargo.toml from `mesh-bridge = []` to
//    `mesh-bridge = ["dep:coord-mesh"]`.
// 5. Run: `cargo build --features mesh-bridge && cargo test -p chump-coord --lib`

// ── Mesh transport substrate ──────────────────────────────────────────────────

// Post-Side-A: replace the three lines below with:
//   pub use coord_mesh::mesh::{
//       AckMessage, BandwidthBudget, Channel, MeshError, MeshTransport, Message,
//       MessageQueue, StubMesh,
//   };
//   pub use coord_mesh::mesh::channels;
pub use crate::mesh::channels;
pub use crate::mesh::{AckMessage, Channel, MeshError, MeshTransport, Message, StubMesh};

// ── Consensus substrate ───────────────────────────────────────────────────────

// Post-Side-A: replace with:
//   pub use coord_mesh::consensus::{
//       ConsensusCoordinator, ConsensusDecision, ConsensusRecord, DecisionType,
//       Vote, VoteProof, VoteRequest,
//   };
pub mod consensus {
    pub use crate::consensus::{
        ConsensusCoordinator, ConsensusDecision, ConsensusRecord, DecisionType, Vote, VoteProof,
        VoteRequest,
    };
}
