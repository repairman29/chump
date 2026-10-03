//! claim_branch_observability — INFRA-1649 (re-do of INFRA-1598)
//!
//! Pure, dependency-free helpers for the structured observability event
//! emitted by `chump verify-claim-branch` (src/verify_claim_branch.rs in the
//! root bin crate). Split out here so the event shape + cost math is
//! unit-testable without a `git` subprocess or `.chump-locks/` fixture.

/// Default cost-per-second used when `CHUMP_COST_PER_SECOND` is unset.
/// Rough approximation of a single CLI invocation's compute cost; tune via
/// the env var rather than editing this constant.
pub const DEFAULT_COST_PER_SECOND: f64 = 0.0008;

/// Terminal status of a `verify-claim-branch` run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunStatus {
    Success,
    Failure,
    Timeout,
}

impl RunStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            RunStatus::Success => "success",
            RunStatus::Failure => "failure",
            RunStatus::Timeout => "timeout",
        }
    }
}

/// Failure classification for a `verify-claim-branch` run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// No failure occurred.
    None,
    /// Likely to succeed on retry (e.g. a hung subprocess / timeout).
    Transient,
    /// Durable mismatch — retrying without fixing the underlying branch
    /// will fail again.
    Permanent,
}

impl FailureClass {
    pub fn as_str(self) -> &'static str {
        match self {
            FailureClass::None => "none",
            FailureClass::Transient => "transient",
            FailureClass::Permanent => "permanent",
        }
    }
}

/// `CHUMP_COST_PER_SECOND` lookup with a sane default and no panics on a
/// malformed value.
pub fn cost_per_second_from_env() -> f64 {
    std::env::var("CHUMP_COST_PER_SECOND")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|v| v.is_finite() && *v >= 0.0)
        .unwrap_or(DEFAULT_COST_PER_SECOND)
}

/// cost_estimate = duration_seconds * cost_per_second (AC 4).
pub fn cost_estimate(duration_ms: u64, cost_per_second: f64) -> f64 {
    (duration_ms as f64 / 1000.0) * cost_per_second
}

/// Builds the single JSON observability event line (AC 1) printed by
/// `chump verify-claim-branch` when it finishes.
pub fn build_event(
    status: RunStatus,
    duration_ms: u64,
    failure_class: FailureClass,
    cost_per_second: f64,
) -> serde_json::Value {
    serde_json::json!({
        "status": status.as_str(),
        "duration_ms": duration_ms,
        "cost_estimate": cost_estimate(duration_ms, cost_per_second),
        "failure_class": failure_class.as_str(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cost_estimate_scales_with_duration_and_rate() {
        assert_eq!(cost_estimate(1000, 0.001), 0.001);
        assert_eq!(cost_estimate(2000, 0.001), 0.002);
        assert_eq!(cost_estimate(0, 0.001), 0.0);
    }

    #[test]
    fn cost_per_second_from_env_falls_back_on_garbage() {
        // SAFETY: test-only env mutation, single-threaded within this test.
        unsafe {
            std::env::set_var("CHUMP_COST_PER_SECOND", "not-a-number");
        }
        assert_eq!(cost_per_second_from_env(), DEFAULT_COST_PER_SECOND);
        unsafe {
            std::env::remove_var("CHUMP_COST_PER_SECOND");
        }
    }

    #[test]
    fn build_event_timeout_is_transient() {
        let ev = build_event(RunStatus::Timeout, 5000, FailureClass::Transient, 0.0008);
        assert_eq!(ev["status"], "timeout");
        assert_eq!(ev["failure_class"], "transient");
        assert_eq!(ev["duration_ms"], 5000);
        assert!(ev["cost_estimate"].as_f64().unwrap() > 0.0);
    }
}
