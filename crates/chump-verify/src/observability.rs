//! observability.rs — INFRA-1649 (re-do of INFRA-1598): shared
//! status/duration/cost/failure-class event builder for
//! `chump verify-claim-branch`.
//!
//! Lives in `chump-verify` (rather than the bin crate) so it's exercised by
//! `cargo test --test external_verify_merge` without linking the 190k-line
//! bin crate for a pure-function smoke test.

use std::time::Duration;

/// Default cost-per-second used when `CHUMP_COST_PER_SECOND` is unset or
/// unparseable. A nominal placeholder — the point is that the knob exists
/// and is env-configurable, not that this number is precise.
pub const DEFAULT_COST_PER_SECOND: f64 = 0.0002;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Success,
    Failure,
    Timeout,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Success => "success",
            Status::Failure => "failure",
            Status::Timeout => "timeout",
        }
    }

    /// A timeout is always retryable (transient). A hard failure (e.g. a
    /// claim-branch mismatch) needs a person to fix the underlying
    /// off-rails condition — permanent until then. Success carries no
    /// failure class.
    pub fn failure_class(self) -> &'static str {
        match self {
            Status::Success => "none",
            Status::Timeout => "transient",
            Status::Failure => "permanent",
        }
    }
}

fn cost_per_second() -> f64 {
    std::env::var("CHUMP_COST_PER_SECOND")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(DEFAULT_COST_PER_SECOND)
}

pub fn cost_estimate(duration: Duration) -> f64 {
    duration.as_secs_f64() * cost_per_second()
}

/// Builds the structured observability event (INFRA-1649 AC1):
/// `{"status":..,"duration_ms":..,"cost_estimate":..,"failure_class":..}`.
pub fn build_event(status: Status, duration: Duration) -> serde_json::Value {
    serde_json::json!({
        "status": status.as_str(),
        "duration_ms": duration.as_millis() as u64,
        "cost_estimate": cost_estimate(duration),
        "failure_class": status.failure_class(),
    })
}

/// Prints the event as a single JSON line to stdout and logs the cost
/// estimate to stderr (INFRA-1649 AC4: `cost reported: $X`).
pub fn emit(status: Status, duration: Duration) -> serde_json::Value {
    let event = build_event(status, duration);
    println!("{event}");
    eprintln!("cost reported: ${:.6}", cost_estimate(duration));
    event
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn success_has_no_failure_class() {
        let event = build_event(Status::Success, Duration::from_millis(10));
        assert_eq!(event["status"], "success");
        assert_eq!(event["failure_class"], "none");
    }

    #[test]
    fn timeout_is_transient() {
        let event = build_event(Status::Timeout, Duration::from_millis(500));
        assert_eq!(event["status"], "timeout");
        assert_eq!(event["failure_class"], "transient");
        assert_eq!(event["duration_ms"], 500);
    }

    #[test]
    fn failure_is_permanent() {
        let event = build_event(Status::Failure, Duration::from_millis(1));
        assert_eq!(event["status"], "failure");
        assert_eq!(event["failure_class"], "permanent");
    }

    #[test]
    fn cost_estimate_respects_env_override() {
        std::env::set_var("CHUMP_COST_PER_SECOND", "1.0");
        let cost = cost_estimate(Duration::from_secs(2));
        std::env::remove_var("CHUMP_COST_PER_SECOND");
        assert!((cost - 2.0).abs() < 1e-9);
    }
}
