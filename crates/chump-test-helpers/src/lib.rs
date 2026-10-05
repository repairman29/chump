//! INFRA-2088: canonical test-sandbox primitive for Rust tests.
//!
//! Sibling of `scripts/coord/lib/test-sandbox.sh` — same isolation-var list,
//! same purpose: kill the class of bug where a test mutates the real
//! `.chump/state.db` because one of CHUMP_HOME / CHUMP_REPO /
//! CHUMP_REPO_ROOT / CHUMP_STATE_DB / CHUMP_LOCK_DIR was missed when
//! isolating env vars by hand (INFRA-2080).

mod sandbox;

pub use sandbox::TestSandbox;
