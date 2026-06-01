//! `chump-fleet-server` library interface.
//!
//! Re-exports the internal modules so integration tests under `tests/` can
//! access `routes::build_router`, `db::FleetStore`, and `dashboard::build_summary`
//! without duplicating the implementations.

pub mod dashboard;
pub mod db;
pub mod routes;
pub mod segmenter;
