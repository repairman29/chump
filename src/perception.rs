//! Re-export shim for the [`chump_perception`] crate (extracted 2026-04-18).
//!
//! Pre-extraction this module owned the implementation directly. To keep all
//! existing `crate::perception::*` call sites working without churn, we now
//! just re-export the standalone crate's public API. Callers can migrate to
//! `chump_perception::*` over time, or stay on `crate::perception::*`
//! indefinitely — both resolve to the same symbols.
//!
//! See `crates/chump-perception/` for the actual implementation +
//! documentation. Reference architecture / pre-reasoning structured
//! perception design notes preserved there.
pub use chump_perception::*;
