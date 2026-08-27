//! INFRA-1649 (re-do of INFRA-1598): smoke test for the shared verify
//! observability event emitted by `chump verify-claim-branch` and friends.

use chump_verify::external_verify_merge::observability_event;

#[test]
fn smoke_observability() {
    // Simulated timeout: a verify command that didn't finish in time reports
    // status=timeout with failure_class=transient (retry is expected to help).
    let event = observability_event("timeout", 1_500, "transient", 0.0006);

    assert_eq!(event["status"], "timeout");
    assert_eq!(event["duration_ms"], 1_500);
    assert_eq!(event["failure_class"], "transient");

    let cost_estimate = event["cost_estimate"]
        .as_f64()
        .expect("cost_estimate must be a number");
    assert!(
        (cost_estimate - 0.0009).abs() < 1e-9,
        "expected cost_estimate ~0.0009, got {cost_estimate}"
    );
}
