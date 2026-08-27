//! chump-verify — the COTG verify gauntlet, extracted from the bin crate for
//! build speed (EFFECTIVE-394). Kept as sibling modules so intra-cluster
//! `crate::pr_ac_coverage` / `crate::confidence` paths stay valid unchanged.
pub mod confidence;
pub mod external_verify_merge;
pub mod observability;
pub mod pr_ac_coverage;
