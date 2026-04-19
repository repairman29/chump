//! Re-export shim for the [`chump_cancel_registry`] crate (extracted 2026-04-18).
//!
//! Pre-extraction this module owned the implementation directly. To keep all
//! existing `crate::cancel_registry::*` call sites working without churn, we
//! now just re-export the standalone crate's public API. Callers can migrate
//! to `chump_cancel_registry::*` over time, or stay on `crate::cancel_registry::*`
//! indefinitely — both resolve to the same symbols.
//!
//! See `crates/chump-cancel-registry/` for the actual implementation +
//! documentation. Original AGT-002 design notes preserved there.
pub use chump_cancel_registry::*;
