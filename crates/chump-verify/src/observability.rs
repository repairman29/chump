//! INFRA-1649 (re-do of INFRA-1598): shared structured-event primitive for
//! commands that want a uniform success/failure/timeout observability line
//! with a cost estimate — used by `chump verify-claim-branch` (src/verify_claim_branch.rs)
//! and exercised directly by this crate's `smoke_observability` integration test.

/// Default cost-per-second used when `CHUMP_COST_PER_SECOND` is unset or
/// unparsable. Deliberately small — this is a rough estimate, not a billed
/// figure.
pub const DEFAULT_COST_PER_SECOND: f64 = 0.0005;

/// Reads `CHUMP_COST_PER_SECOND` (falls back to [`DEFAULT_COST_PER_SECOND`]).
pub fn cost_per_second() -> f64 {
    std::env::var("CHUMP_COST_PER_SECOND")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(DEFAULT_COST_PER_SECOND)
}

/// One structured observability event: status/duration/cost/failure-class.
pub struct ObservabilityEvent {
    pub status: &'static str,
    pub duration_ms: u128,
    pub cost_estimate: f64,
    pub failure_class: &'static str,
}

/// Builds an event for a completed run. `status` must be one of
/// success/failure/timeout; `failure_class` one of transient/permanent/none.
/// `cost_estimate` is `duration_seconds * cost_per_second()`.
pub fn build_event(
    status: &'static str,
    duration_ms: u128,
    failure_class: &'static str,
) -> ObservabilityEvent {
    let seconds = duration_ms as f64 / 1000.0;
    ObservabilityEvent {
        status,
        duration_ms,
        cost_estimate: seconds * cost_per_second(),
        failure_class,
    }
}

impl ObservabilityEvent {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "status": self.status,
            "duration_ms": self.duration_ms,
            "cost_estimate": self.cost_estimate,
            "failure_class": self.failure_class,
        })
    }
}

/// Prints the event as a single JSON line to stdout, and a
/// `cost reported: $X` line to stderr (AC#4).
pub fn emit(event: &ObservabilityEvent) {
    println!("{}", event.to_json());
    eprintln!("cost reported: ${:.6}", event.cost_estimate);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cost_estimate_uses_default_rate() {
        std::env::remove_var("CHUMP_COST_PER_SECOND");
        let ev = build_event("success", 2000, "none");
        assert!((ev.cost_estimate - (2.0 * DEFAULT_COST_PER_SECOND)).abs() < 1e-9);
    }

    #[test]
    fn json_shape_has_required_keys() {
        let ev = build_event("timeout", 5000, "transient");
        let json = ev.to_json();
        assert_eq!(json["status"], "timeout");
        assert_eq!(json["duration_ms"], 5000);
        assert_eq!(json["failure_class"], "transient");
        assert!(json["cost_estimate"].is_number());
    }
}
