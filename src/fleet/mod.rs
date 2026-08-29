//! INFRA-724: fleet module group — peer registry (`fleet`), capability
//! discovery (`fleet_capability`), sqlite-backed peer store (`fleet_db`),
//! health/SLO scoring (`fleet_health`), status snapshots (`fleet_status`),
//! the `chump fleet` CLI (`fleet_tool`), velocity metrics (`fleet_velocity`),
//! and cross-repo peer mesh probing (`cluster_mesh`).
//!
//! `fleet.rs` keeps the `fleet` module name (colliding with this directory),
//! so it's aliased in as `core` and re-exported at `crate::fleet::*` to
//! preserve every existing `crate::fleet::X` call site unchanged.

#[path = "fleet.rs"]
mod core;
pub use core::*;

pub mod cluster_mesh;
pub mod fleet_capability;
pub mod fleet_db;
pub mod fleet_health;
pub mod fleet_status;
pub mod fleet_tool;
pub mod fleet_velocity;
