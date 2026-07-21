//! `chump-verified-aggregator` library interface.
//!
//! Re-exports the internal modules so integration tests can access
//! `routes::build_router` and `db::AggregatorStore` without duplicating the
//! implementations.

pub mod db;
pub mod routes;
