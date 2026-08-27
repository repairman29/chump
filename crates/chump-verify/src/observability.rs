//! observability.rs — INFRA-1649: shared structured event emission for
//! verify-* commands.
//!
//! `chump verify-claim-branch` and `chump external verify-merge` both run a
//! bounded, cost-relevant operation and want the same observability shape:
//! a single JSON line on stdout describing what happened (status, how long
//! it took, what it cost, and — on failure — whether retrying is worth it).
//! Centralizing here means both callers (and their tests) share one
//! definition of "transient" vs "permanent" instead of drifting.

use std::time::Duration;

/// Outcome of the operation being observed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Success,
    Failure,
    Timeout,
}

impl Status {
    pub fn as_str(&self) -> &'static str {
        match self {
            Status::Success => "success",
            Status::Failure => "failure",
            Status::Timeout => "timeout",
        }
    }
}

/// Whether a failure is worth retrying (transient) or not (permanent).
/// `None` applies to non-failure outcomes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    None,
    Transient,
    Permanent,
}

impl FailureClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            FailureClass::None => "none",
            FailureClass::Transient => "transient",
            FailureClass::Permanent => "permanent",
        }
    }
}

/// `$/second` used to turn wall-clock duration into a rough cost estimate.
/// Overridable via `CHUMP_COST_PER_SECOND` (e.g. for a pricier verify path).
pub fn cost_per_second() -> f64 {
    std::env::var("CHUMP_COST_PER_SECOND")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|v| v.is_finite() && *v >= 0.0)
        .unwrap_or(0.0006)
}

/// Builds + prints the structured event line to stdout, logs the cost line
/// to stderr, and returns the JSON value (callers that also want to fold it
/// into a larger `--json` payload can inspect the returned fields).
pub fn emit_event(
    status: Status,
    duration: Duration,
    failure_class: FailureClass,
) -> serde_json::Value {
    let duration_ms = duration.as_millis() as u64;
    let cost_estimate = duration.as_secs_f64() * cost_per_second();

    eprintln!("cost reported: ${cost_estimate:.6}");

    let event = serde_json::json!({
        "status": status.as_str(),
        "duration_ms": duration_ms,
        "cost_estimate": cost_estimate,
        "failure_class": failure_class.as_str(),
    });

    println!("{event}");
    event
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cost_estimate_scales_with_duration() {
        std::env::set_var("CHUMP_COST_PER_SECOND", "1.0");
        let event = emit_event(Status::Success, Duration::from_secs(2), FailureClass::None);
        std::env::remove_var("CHUMP_COST_PER_SECOND");
        assert_eq!(event["status"], "success");
        assert_eq!(event["failure_class"], "none");
        assert!((event["cost_estimate"].as_f64().unwrap() - 2.0).abs() < 1e-9);
    }

    #[test]
    fn timeout_is_transient() {
        let event = emit_event(
            Status::Timeout,
            Duration::from_millis(500),
            FailureClass::Transient,
        );
        assert_eq!(event["status"], "timeout");
        assert_eq!(event["failure_class"], "transient");
    }
}
