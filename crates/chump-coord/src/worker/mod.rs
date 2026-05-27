//! Worker module — Rust port of `scripts/dispatch/worker.sh` (INFRA-2002).
//!
//! META-107 sub-gap #6 of 6 (the final one). Backward-compat via the
//! `CHUMP_WORKER_RUST=1` feature flag in the bash shim — the legacy
//! 1807-LOC `worker.sh` body stays in place for a 1-week parallel-run
//! validation window.
//!
//! ## Module map
//!
//! - [`capability`] — `WorkerCapability` struct + env builder + picker filter.
//! - [`loop_body`] — one-cycle entrypoint, `CycleOutcome` enum, `pick_eligible_gap`.
//! - [`worktree`] — `git worktree add/remove` via tokio subprocess.
//!
//! ## Phase 1 NON-goals (deferred)
//!
//! - NATS PUSH (FLEET-034) — env `CHUMP_NATS_URL` is read but consumption stubbed.
//! - KV capability publish (INFRA-1760 follow-up).
//! - Speculative `replicas: N` (INFRA-311).
//! - New ambient event kinds.

pub mod capability;
pub mod loop_body;
pub mod worktree;

pub use capability::WorkerCapability;
pub use loop_body::{run_one_cycle, CycleEnv, CycleOutcome, DEFAULT_EXEC_TIMEOUT_S};
pub use worktree::{create_worktree, remove_worktree, worktree_dir_for};
