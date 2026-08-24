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
pub use chump_cost_tracker::*;

/// Re-export `add_session_cost_usd` explicitly so callers in the crate can
/// increment the session spend ledger without importing `chump_cost_tracker`.
/// COMP-014: this was missing from the re-export — add_session_cost_usd is the
/// function every provider (Together, OpenAI, Anthropic, Gemini, DeepSeek) calls
/// to record cost. If it isn't exported through this shim, callers who only
/// import `crate::cost_tracker` see a $0.00 ledger.
pub use chump_cost_tracker::add_session_cost_usd;
