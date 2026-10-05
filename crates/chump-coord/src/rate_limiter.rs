//! INFRA-4246 (INFRA-1319 slice): central token-bucket rate limiter.
//!
//! `GhThrottleGate` in [`crate::mesh`] is a per-process gate that only defers
//! `criticality: background` calls. This module is the piece INFRA-1319
//! (GitHub Liaison Phase 3) needs on top of it: a single shared bucket a
//! central arbiter (one process, e.g. the future `chump-github-liaison`
//! daemon) can hold so that `CHUMP_GH_MAX_CALLS_PER_MIN` is enforced across
//! the *entire fleet* rather than per-script — every caller asks the same
//! bucket, so there is exactly one source of truth for "how many calls are
//! left this minute."
//!
//! Unlike the bash `_chump_gh_throttle_wait` (scripts/coord/lib/github.sh),
//! which blocks the caller in a sleep/retry loop, [`TokenBucketLimiter::check`]
//! never sleeps — it returns a [`RateLimitDecision`] immediately so the
//! caller (or the NATS request/reply layer in a later INFRA-1319 slice) can
//! decide what to do with a denied request (queue it, return `429_queued`
//! with `retry_after_ms`, etc).

use std::time::{Duration, Instant};

/// Env var controlling the fleet-wide call budget. Mirrors the bash
/// self-throttle (`scripts/coord/lib/github.sh`) and `GhThrottleGate`
/// (`crate::mesh`) so all three enforcement points agree on the knob.
pub const MAX_CALLS_PER_MIN_ENV: &str = "CHUMP_GH_MAX_CALLS_PER_MIN";

/// Fleet default when the env var is unset or unparseable.
pub const DEFAULT_MAX_CALLS_PER_MIN: u32 = 60;

/// Outcome of a [`TokenBucketLimiter::check`] call.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RateLimitDecision {
    /// A token was available and has been consumed — proceed with the call.
    Allow,
    /// No token available. `retry_after_ms` is how long until the next
    /// token refills, rounded up so a caller that waits exactly that long
    /// is guaranteed a token on retry.
    Deny { retry_after_ms: u64 },
}

impl RateLimitDecision {
    /// True for [`RateLimitDecision::Allow`].
    pub fn is_allowed(&self) -> bool {
        matches!(self, RateLimitDecision::Allow)
    }

    /// `Some(ms)` for [`RateLimitDecision::Deny`], `None` for `Allow`.
    pub fn retry_after_ms(&self) -> Option<u64> {
        match self {
            RateLimitDecision::Allow => None,
            RateLimitDecision::Deny { retry_after_ms } => Some(*retry_after_ms),
        }
    }
}

/// A single token bucket shared by every caller that holds a reference to
/// it. One call = one token. Tokens refill continuously (not in a fixed
/// window) at `capacity / 60s`, so a caller that has been idle for a while
/// can burst up to the full per-minute capacity immediately.
#[derive(Debug)]
pub struct TokenBucketLimiter {
    capacity: f64,
    tokens: f64,
    refill_per_sec: f64,
    last_refill: Instant,
}

impl TokenBucketLimiter {
    /// Build a limiter with an explicit per-minute capacity.
    pub fn new(max_calls_per_min: u32) -> Self {
        let capacity = f64::from(max_calls_per_min.max(1));
        Self {
            capacity,
            tokens: capacity,
            refill_per_sec: capacity / 60.0,
            last_refill: Instant::now(),
        }
    }

    /// Build a limiter reading `CHUMP_GH_MAX_CALLS_PER_MIN` from the
    /// environment, falling back to [`DEFAULT_MAX_CALLS_PER_MIN`] when the
    /// var is unset or not a valid positive integer.
    pub fn from_env() -> Self {
        let max = std::env::var(MAX_CALLS_PER_MIN_ENV)
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|v| *v > 0)
            .unwrap_or(DEFAULT_MAX_CALLS_PER_MIN);
        Self::new(max)
    }

    /// Per-minute capacity this limiter was constructed with.
    pub fn capacity(&self) -> u32 {
        self.capacity as u32
    }

    fn refill(&mut self, now: Instant) {
        let elapsed = now.saturating_duration_since(self.last_refill);
        if elapsed > Duration::ZERO {
            let refilled = elapsed.as_secs_f64() * self.refill_per_sec;
            self.tokens = (self.tokens + refilled).min(self.capacity);
            self.last_refill = now;
        }
    }

    /// Ask for one token at `now`. Exposed separately from [`check`] so
    /// tests can advance a synthetic clock deterministically.
    pub fn check_at(&mut self, now: Instant) -> RateLimitDecision {
        self.refill(now);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            RateLimitDecision::Allow
        } else {
            let deficit = 1.0 - self.tokens;
            let wait_secs = deficit / self.refill_per_sec;
            RateLimitDecision::Deny {
                retry_after_ms: (wait_secs * 1000.0).ceil() as u64,
            }
        }
    }

    /// Ask for one token right now.
    pub fn check(&mut self) -> RateLimitDecision {
        self.check_at(Instant::now())
    }

    /// Tokens currently available (fractional — callers only need this for
    /// observability/metrics, not for the allow/deny decision itself).
    pub fn available(&self) -> f64 {
        self.tokens
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_up_to_capacity_then_denies() {
        let mut limiter = TokenBucketLimiter::new(3);
        let now = Instant::now();
        assert_eq!(limiter.check_at(now), RateLimitDecision::Allow);
        assert_eq!(limiter.check_at(now), RateLimitDecision::Allow);
        assert_eq!(limiter.check_at(now), RateLimitDecision::Allow);

        let decision = limiter.check_at(now);
        assert!(!decision.is_allowed());
        let retry_after_ms = decision
            .retry_after_ms()
            .expect("deny carries retry_after_ms");
        // capacity=3/min -> refill_per_sec=0.05 -> ~20000ms for one token.
        assert!(
            (19_000..=20_001).contains(&retry_after_ms),
            "unexpected retry_after_ms: {retry_after_ms}"
        );
    }

    #[test]
    fn refills_over_time() {
        let mut limiter = TokenBucketLimiter::new(60); // 1 token/sec
        let t0 = Instant::now();
        for _ in 0..60 {
            assert!(limiter.check_at(t0).is_allowed());
        }
        assert!(!limiter.check_at(t0).is_allowed());

        // One second later, exactly one token should have refilled.
        let t1 = t0 + Duration::from_secs(1);
        assert!(limiter.check_at(t1).is_allowed());
        assert!(!limiter.check_at(t1).is_allowed());
    }

    #[test]
    fn full_minute_restores_full_capacity() {
        let mut limiter = TokenBucketLimiter::new(10);
        let t0 = Instant::now();
        for _ in 0..10 {
            assert!(limiter.check_at(t0).is_allowed());
        }
        assert!(!limiter.check_at(t0).is_allowed());

        let t1 = t0 + Duration::from_secs(60);
        for _ in 0..10 {
            assert!(limiter.check_at(t1).is_allowed());
        }
        assert!(!limiter.check_at(t1).is_allowed());
    }

    // Single test for all CHUMP_GH_MAX_CALLS_PER_MIN parsing cases — env
    // vars are process-global, so running these as separate #[test] fns
    // risks a race under cargo's parallel test runner.
    #[test]
    fn from_env_parses_override_and_falls_back_on_garbage() {
        std::env::set_var(MAX_CALLS_PER_MIN_ENV, "5");
        assert_eq!(TokenBucketLimiter::from_env().capacity(), 5);

        std::env::set_var(MAX_CALLS_PER_MIN_ENV, "not-a-number");
        assert_eq!(
            TokenBucketLimiter::from_env().capacity(),
            DEFAULT_MAX_CALLS_PER_MIN
        );

        std::env::set_var(MAX_CALLS_PER_MIN_ENV, "0");
        assert_eq!(
            TokenBucketLimiter::from_env().capacity(),
            DEFAULT_MAX_CALLS_PER_MIN
        );

        std::env::remove_var(MAX_CALLS_PER_MIN_ENV);
        assert_eq!(
            TokenBucketLimiter::from_env().capacity(),
            DEFAULT_MAX_CALLS_PER_MIN
        );
    }
}
