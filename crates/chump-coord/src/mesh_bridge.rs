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
// is active, `chump_coord::mesh_bridge::*` re-exports from the `coord-mesh`
// crate (INFRA-1815-sideA, shipped as repairman29/chump-proprietary#1) —
// the canonical shared home for these types per CP-008. The local
// hand-rolled modules (mesh.rs, consensus.rs) remain the fallback when the
// feature is off, so crates that don't need the mesh substrate don't incur
// the git dep.
//
// ## Consumption (INFRA-1758 / INFRA-1763 / INFRA-1804)
//
// ```rust
// // Build with: cargo build --features mesh-bridge
// use chump_coord::mesh_bridge::{Channel, Message, MeshTransport, StubMesh};
// use chump_coord::mesh_bridge::consensus::ConsensusCoordinator;
// ```

// ── Mesh transport substrate ──────────────────────────────────────────────────

pub use coord_mesh::mesh::channels;
pub use coord_mesh::mesh::{
    AckMessage, BandwidthBudget, Channel, GhThrottleGate, LocalProcessTransport, MeshError,
    MeshTransport, Message, MessageQueue, StubMesh,
};

// ── Consensus substrate ───────────────────────────────────────────────────────

pub mod consensus {
    pub use coord_mesh::consensus::{
        ConsensusCoordinator, ConsensusDecision, ConsensusRecord, DecisionType, Vote, VoteProof,
        VoteRequest,
    };
}
