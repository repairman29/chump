//! Monotonic turn counter for `ChumpAgent::run` — used by blackboard eviction and brain autoload gating.

use std::sync::atomic::{AtomicU64, Ordering};

static AGENT_RUN_TURN: AtomicU64 = AtomicU64::new(0);

/// Increment at the start of each `ChumpAgent::run`. Returns the new turn id (starts at 1).
pub fn begin_turn() -> u64 {
    AGENT_RUN_TURN.fetch_add(1, Ordering::Relaxed) + 1
}

/// Last turn id from `begin_turn()`, or 1 before the first run.
pub fn current() -> u64 {
    AGENT_RUN_TURN.load(Ordering::Relaxed).max(1)
}
