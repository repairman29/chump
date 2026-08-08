//! chump-waste-tally — fleet waste-tally reports, extracted from the bin crate
//! for build speed (EFFECTIVE-411). Kept as a sibling module so intra-crate
//! `crate::` paths stay valid unchanged.
//!
//! The one outbound coupling in the original module was the per-model pricing
//! function (`session_ledger::cost_usd_from_tokens`, still inline in the bin).
//! Rather than promote that foundation module to a crate (out of scope), the
//! pricing function is *injected* by the bin at startup via
//! [`waste_tally::set_cost_fn`]. This keeps the crate a true clean leaf — it
//! depends on nothing else in the workspace.
pub mod waste_tally;
