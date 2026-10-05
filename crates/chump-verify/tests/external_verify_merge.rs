//! INFRA-1649 (re-do of INFRA-1598): smoke test for the structured
//! observability event emitted by `chump verify-claim-branch`.
//!
//! Run via: `cargo test --test external_verify_merge smoke_observability`

use chump_verify::claim_branch_observability::{build_event, FailureClass, RunStatus};

#[test]
fn smoke_observability() {
    // Simulated timeout: a hung `git` subprocess should surface as
    // status=timeout, failure_class=transient — retrying is expected to
    // succeed once the subprocess stops hanging.
    let event = build_event(RunStatus::Timeout, 5_000, FailureClass::Transient, 0.0008);

    assert_eq!(event["status"], "timeout");
    assert_eq!(event["failure_class"], "transient");
    assert_eq!(event["duration_ms"], 5_000);
    assert_eq!(event["cost_estimate"], 0.0008 * 5.0);
}
