//! Smoke test for INFRA-1649: the structured observability event emitted by
//! verify-gauntlet commands (`chump verify-claim-branch` today). Named
//! `external_verify_merge` per the gap's target file list — the observability
//! module (`chump_verify::observability`) is shared plumbing meant to serve
//! both `verify-claim-branch` and `external verify-merge`.

use chump_verify::observability::{build_event, to_json_line, FailureClass, Status};

#[test]
fn smoke_observability() {
    // Simulate a timeout: a verify command that hit its deadline before
    // reaching a verdict — this is always a transient failure class (the
    // underlying condition being waited on may resolve on retry).
    let ev = build_event(Status::Timeout, 1_500, FailureClass::Transient);

    assert_eq!(ev.status, Status::Timeout);
    assert_eq!(ev.failure_class, FailureClass::Transient);
    assert_eq!(ev.duration_ms, 1_500);

    let line = to_json_line(&ev);
    assert!(
        line.contains("\"status\":\"timeout\""),
        "expected status=timeout in {line}"
    );
    assert!(
        line.contains("\"failure_class\":\"transient\""),
        "expected failure_class=transient in {line}"
    );
    assert!(
        line.contains("\"duration_ms\":1500"),
        "expected duration_ms=1500 in {line}"
    );
    assert!(
        line.contains("\"cost_estimate\":"),
        "expected cost_estimate key in {line}"
    );
}
