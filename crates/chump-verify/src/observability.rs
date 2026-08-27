//! observability.rs — INFRA-1649 (re-do of INFRA-1598)
//!
//! Shared structured-event primitive for CLI commands that want a single
//! JSON line on stdout describing how the run went: `status`
//! (success/failure/timeout), `duration_ms`, `cost_estimate`, and
//! `failure_class` (transient/permanent/none). First consumer is
//! `chump verify-claim-branch` (src/verify_claim_branch.rs); lives in this
//! crate (not the bin crate) so it's testable without linking the 190k-line
//! binary (EFFECTIVE-394 build-speed precedent).

/// Cost per second of wall-clock command duration, in USD. Overridable via
/// `CHUMP_COST_PER_SECOND` for environments with different compute pricing.
const DEFAULT_COST_PER_SECOND: f64 = 0.0005;

fn cost_per_second() -> f64 {
    std::env::var("CHUMP_COST_PER_SECOND")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(DEFAULT_COST_PER_SECOND)
}

/// Builds the observability JSON event for a finished command run and logs
/// `cost reported: $X` to stderr. Does not print the event itself — callers
/// decide whether/when to print (e.g. after their own verdict output).
pub fn build_event(status: &str, duration_ms: u128, failure_class: &str) -> serde_json::Value {
    let duration_seconds = duration_ms as f64 / 1000.0;
    let cost_estimate = duration_seconds * cost_per_second();
    eprintln!("cost reported: ${cost_estimate:.6}");
    serde_json::json!({
        "status": status,
        "duration_ms": duration_ms,
        "cost_estimate": cost_estimate,
        "failure_class": failure_class,
    })
}

/// Prints the event as a single JSON line to stdout.
pub fn emit_event(status: &str, duration_ms: u128, failure_class: &str) {
    let event = build_event(status, duration_ms, failure_class);
    println!("{event}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn success_event_has_none_failure_class() {
        let event = build_event("success", 42, "none");
        assert_eq!(event["status"], "success");
        assert_eq!(event["duration_ms"], 42);
        assert_eq!(event["failure_class"], "none");
        assert!(event["cost_estimate"].as_f64().unwrap() >= 0.0);
    }

    #[test]
    fn timeout_event_has_transient_failure_class() {
        let event = build_event("timeout", 5000, "transient");
        assert_eq!(event["status"], "timeout");
        assert_eq!(event["failure_class"], "transient");
    }

    #[test]
    fn cost_estimate_scales_with_duration() {
        let short = build_event("success", 1000, "none");
        let long = build_event("success", 2000, "none");
        assert!(long["cost_estimate"].as_f64().unwrap() > short["cost_estimate"].as_f64().unwrap());
    }
}
