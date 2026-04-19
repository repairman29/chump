//! Re-export shim for the [`chump_belief_state`] crate (extracted 2026-04-18).
//!
//! Pre-extraction this module owned the implementation directly. To keep all
//! existing `crate::belief_state::*` call sites working without churn, we now
//! just re-export the standalone crate's public API.
//!
//! See `crates/chump-belief-state/` for the actual implementation +
//! Active Inference / Synthetic Consciousness Framework design notes.
pub use chump_belief_state::*;
