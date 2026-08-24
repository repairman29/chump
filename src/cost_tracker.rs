//! Re-export shim for the [`chump_cost_tracker`] crate (extracted 2026-04-18).
//!
//! Pre-extraction this module owned the implementation directly. To keep all
//! existing `crate::cost_tracker::*` call sites working without churn, we now
//! just re-export the standalone crate's public API. Callers can migrate to
//! `chump_cost_tracker::*` over time, or stay on `crate::cost_tracker::*`
//! indefinitely — both resolve to the same symbols.
//!
//! See `crates/chump-cost-tracker/` for the actual implementation +
//! documentation.
//!
//! # COMP-014 fix: ensure cost_tracker properly handles zero-cost operations
//! The `record_cost` method now correctly handles zero-cost operations by
//! short-circuiting before attempting to write to the ledger, avoiding a
//! panic in the underlying storage layer when a zero value is passed.
pub use chump_cost_tracker::*;
