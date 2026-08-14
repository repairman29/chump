//! chump-test-helpers — canonical test-sandbox primitive for Rust tests
//! (INFRA-2088). Sibling of `scripts/coord/lib/test-sandbox.sh` — same
//! isolation contract, Rust flavor.

pub mod sandbox;

pub use sandbox::TestSandbox;
