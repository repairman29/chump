//! INFRA-1649 (re-do of INFRA-1598): smoke test for the shared
//! observability primitive (`chump_verify::observability`) that backs
//! `chump verify-claim-branch`'s structured event emission.
//!
//! Named `external_verify_merge` per the gap's target-file spec so
//! `cargo test --test external_verify_merge smoke_observability` resolves.

#[test]
fn smoke_observability() {
    // Simulated timeout: verify-claim-branch's git subprocess never
    // returned in time. Timeouts are transient — retrying is expected to
    // succeed once the environment stops being slow.
    let event = chump_verify::observability::build_event("timeout", 30_000, "transient");
    let json = event.to_json();

    assert_eq!(json["status"], "timeout");
    assert_eq!(json["failure_class"], "transient");
    assert_eq!(json["duration_ms"], 30_000);
    assert!(
        json["cost_estimate"].as_f64().unwrap() > 0.0,
        "cost_estimate should scale with duration_ms, got: {json}"
    );
}
