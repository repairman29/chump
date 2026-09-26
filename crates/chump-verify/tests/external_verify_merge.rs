//! external_verify_merge.rs — INFRA-1649 (re-do of INFRA-1598) smoke test.
//!
//! Validates the observability event builder in `chump_verify::observability`
//! that backs `chump verify-claim-branch`'s structured success/failure/
//! timeout event (AC1) and cost-tracking (AC4).
//!
//! Run: `cargo test --test external_verify_merge smoke_observability`

use chump_verify::observability::{build_event, Status};
use std::time::Duration;

#[test]
fn smoke_observability() {
    let event = build_event(Status::Timeout, Duration::from_millis(1500));

    assert_eq!(event["status"], "timeout");
    assert_eq!(event["failure_class"], "transient");
    assert_eq!(event["duration_ms"], 1500);
    assert!(
        event["cost_estimate"].as_f64().unwrap() > 0.0,
        "cost_estimate must be positive for a non-zero duration: {event}"
    );
}
