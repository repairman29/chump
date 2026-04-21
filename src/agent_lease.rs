//! Path-lease system for multi-agent coordination.
//!
//! The implementation now lives in the standalone crate
//! [`chump-agent-lease`](https://crates.io/crates/chump-agent-lease) under
//! `crates/chump-agent-lease/`. This module is a thin re-export shim so
//! existing `crate::agent_lease::*` callsites inside the `chump` binary crate keep
//! working. New consumers (inside or outside this repo) should depend on
//! `chump-agent-lease` directly rather than routing through here.
//!
//! Pattern established by this file: extract focused, reusable primitives
//! into their own crates; leave a re-export shim at the old path so the
//! monolith doesn't have to migrate in one shot. See
//! `docs/RUST_AGENT_STANDARD_PLAN.md` for the full strategy.

pub use chump_agent_lease::*;
