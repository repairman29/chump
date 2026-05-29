//! Integration test harness for chump-integrator.
//!
//! Each submodule tests a distinct aspect of the end-to-end cycle behaviour
//! against real state.db fixtures and tempdir git repos (no live NATS required).

mod test_cycle_dry_run;
mod test_cycle_policy;
mod test_cycle_select_integration;
mod test_manifest;
