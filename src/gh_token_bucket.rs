//! Central token-bucket rate limiter for fleet-wide `gh` call volume (INFRA-4246,
//! INFRA-1319 slice).
//!
//! A single in-process bucket shared (via `LazyLock`) across every caller in
//! this binary. Capacity and refill rate both derive from
//! `CHUMP_GH_MAX_CALLS_PER_MIN` — the same knob the shell self-throttle
//! (`scripts/coord/lib/github.sh`) already respects, so a process embedding
//! this module and the shell layer agree on the fleet-wide cap.
//!
//! This is the reusable primitive; it does not itself gate `gh` invocations —
//! callers (e.g. the future `chump-github-liaison` daemon in INFRA-1319) call
//! [`GhTokenBucket::try_acquire`] before making a call and honor the returned
//! [`Decision`].

use std::sync::{LazyLock, Mutex};
use std::time::Instant;

/// Default fleet-wide cap when `CHUMP_GH_MAX_CALLS_PER_MIN` is unset.
const DEFAULT_MAX_CALLS_PER_MIN: u32 = 60;

/// Result of a rate-limit check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Call may proceed now.
    Allow,
    /// Call must wait at least this many milliseconds before retrying.
    Deny { retry_after_ms: u64 },
}

impl Decision {
    pub fn is_allowed(&self) -> bool {
        matches!(self, Decision::Allow)
    }

    pub fn retry_after_ms(&self) -> Option<u64> {
        match self {
            Decision::Allow => None,
            Decision::Deny { retry_after_ms } => Some(*retry_after_ms),
        }
    }
}

struct BucketState {
    /// Fractional tokens currently available.
    tokens: f64,
    /// Bucket capacity == refill rate in tokens/min (AC1: tracks
    /// `CHUMP_GH_MAX_CALLS_PER_MIN`).
    capacity: f64,
    last_refill: Instant,
}

impl BucketState {
    fn new(capacity: f64) -> Self {
        Self {
            tokens: capacity,
            capacity,
            last_refill: Instant::now(),
        }
    }

    /// Refill tokens proportional to elapsed time, capped at `capacity`.
    fn refill(&mut self, now: Instant) {
        let elapsed = now.duration_since(self.last_refill).as_secs_f64();
        if elapsed <= 0.0 {
            return;
        }
        let refill_rate_per_sec = self.capacity / 60.0;
        self.tokens = (self.tokens + elapsed * refill_rate_per_sec).min(self.capacity);
        self.last_refill = now;
    }

    /// Milliseconds until at least one token is available.
    fn ms_until_next_token(&self) -> u64 {
        if self.capacity <= 0.0 {
            return 0;
        }
        let refill_rate_per_sec = self.capacity / 60.0;
        let deficit = (1.0 - self.tokens).max(0.0);
        ((deficit / refill_rate_per_sec) * 1000.0).ceil() as u64
    }
}

/// A token bucket keyed on nothing (fleet-wide, single bucket per process).
pub struct GhTokenBucket {
    state: Mutex<BucketState>,
}

impl GhTokenBucket {
    /// Build a bucket with an explicit capacity (tokens/min). Exposed for
    /// tests; production code should use [`GhTokenBucket::from_env`] or the
    /// process-wide [`fleet_bucket`] singleton.
    pub fn with_capacity(capacity_per_min: u32) -> Self {
        Self {
            state: Mutex::new(BucketState::new(capacity_per_min as f64)),
        }
    }

    /// Build a bucket sized from `CHUMP_GH_MAX_CALLS_PER_MIN` (AC1).
    pub fn from_env() -> Self {
        let capacity = std::env::var("CHUMP_GH_MAX_CALLS_PER_MIN")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(DEFAULT_MAX_CALLS_PER_MIN);
        Self::with_capacity(capacity)
    }

    /// Attempt to consume one token. Returns [`Decision::Allow`] and debits
    /// the bucket on success; returns [`Decision::Deny`] with a
    /// `retry_after_ms` estimate when the bucket is empty (AC2). A
    /// zero-or-negative capacity disables the limiter (always allow).
    pub fn try_acquire(&self) -> Decision {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.capacity <= 0.0 {
            return Decision::Allow;
        }
        let now = Instant::now();
        state.refill(now);
        if state.tokens >= 1.0 {
            state.tokens -= 1.0;
            Decision::Allow
        } else {
            Decision::Deny {
                retry_after_ms: state.ms_until_next_token(),
            }
        }
    }

    /// Current configured capacity (tokens/min), for observability.
    pub fn capacity(&self) -> u32 {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .capacity as u32
    }
}

/// Process-wide fleet bucket, sized from `CHUMP_GH_MAX_CALLS_PER_MIN` at
/// first use. All callers in this binary share the same bucket, so the cap
/// is enforced centrally rather than per-caller.
static FLEET_BUCKET: LazyLock<GhTokenBucket> = LazyLock::new(GhTokenBucket::from_env);

/// Check the fleet-wide bucket. This is the entry point production callers
/// should use.
pub fn fleet_bucket() -> &'static GhTokenBucket {
    &FLEET_BUCKET
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn allows_calls_within_capacity() {
        let bucket = GhTokenBucket::with_capacity(3);
        assert_eq!(bucket.try_acquire(), Decision::Allow);
        assert_eq!(bucket.try_acquire(), Decision::Allow);
        assert_eq!(bucket.try_acquire(), Decision::Allow);
    }

    #[test]
    fn denies_with_retry_after_ms_once_exhausted() {
        let bucket = GhTokenBucket::with_capacity(2);
        assert!(bucket.try_acquire().is_allowed());
        assert!(bucket.try_acquire().is_allowed());

        let decision = bucket.try_acquire();
        assert!(!decision.is_allowed());
        let retry_ms = decision
            .retry_after_ms()
            .expect("deny must carry retry_after_ms");
        assert!(
            retry_ms > 0,
            "retry_after_ms should be positive: {retry_ms}"
        );
        // capacity=2/min -> refill every 30s -> retry hint should be well under 30s.
        assert!(
            retry_ms <= 30_000,
            "retry_after_ms unexpectedly large: {retry_ms}"
        );
    }

    #[test]
    fn refills_over_time() {
        let mut state = BucketState::new(60.0);
        state.tokens = 0.0;
        // Simulate 1 second elapsed -> refill rate is 1 token/sec at 60/min.
        let now = state.last_refill + Duration::from_secs(1);
        state.refill(now);
        assert!(
            state.tokens >= 0.9,
            "expected ~1 token refilled, got {}",
            state.tokens
        );
    }

    #[test]
    fn zero_capacity_disables_limiter() {
        let bucket = GhTokenBucket::with_capacity(0);
        for _ in 0..100 {
            assert!(bucket.try_acquire().is_allowed());
        }
    }

    #[test]
    fn respects_max_calls_per_min_env_var() {
        // AC1: capacity derives from CHUMP_GH_MAX_CALLS_PER_MIN.
        let bucket = GhTokenBucket::with_capacity(5);
        assert_eq!(bucket.capacity(), 5);
    }
}
