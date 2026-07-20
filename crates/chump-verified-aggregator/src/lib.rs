//! `chump-verified-aggregator` library interface.
//!
//! Non-gating slice (META-135) of the `verified` aggregator design
//! (`docs/design/CI_VERIFIED_AGGREGATOR.md`, META-134). This crate only
//! receives and stores per-lane CI status updates; it performs no
//! aggregation or pass/fail decision logic yet.

pub mod db;
pub mod routes;
