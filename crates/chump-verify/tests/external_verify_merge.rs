//! Integration smoke test for INFRA-1649 observability output
//! (`crates/chump-verify/src/observability.rs`), shared by
//! `chump verify-claim-branch` and `chump external verify-merge`.
//!
//! Run: `cargo test --test external_verify_merge smoke_observability`

use chump_verify::observability::{emit_event, FailureClass, Status};
use std::time::Duration;

#[test]
fn smoke_observability() {
    // Simulated timeout: caller waited past its bound and gave up. Timeouts
    // are always retry-worthy, so the failure class must be transient.
    let event = emit_event(
        Status::Timeout,
        Duration::from_millis(1500),
        FailureClass::Transient,
    );

    assert_eq!(event["status"], "timeout");
    assert_eq!(event["failure_class"], "transient");
    assert_eq!(event["duration_ms"], 1500);
    assert!(event["cost_estimate"].as_f64().unwrap() >= 0.0);
}
