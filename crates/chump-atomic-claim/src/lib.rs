//! chump-atomic-claim — the atomic gap-claim engine, extracted from the bin crate
//! for build speed (EFFECTIVE-399). Kept as sibling modules so intra-crate
//! `crate::autonomy_level` paths stay valid unchanged. `autonomy_level` (the
//! fleet kill switch, RESILIENT-073) is a pure-leaf dependency of the claim
//! path, so it moves along with it.
pub mod atomic_claim;
pub mod autonomy_level;
