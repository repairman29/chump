//! Integration test for INFRA-1720 AC #6.
//!
//! AC #6 calls for `scripts/ci/test-handoff-contract.sh` but scripts/ci is
//! contested by an active sibling lease (INFRA-1756) at the moment we ship
//! v1, so we satisfy the intent here: a Rust integration test that simulates
//! a malformed subagent output, asserts the parent rejects it, asserts a
//! `handoff_contract_violation` ambient event is emitted, and asserts the
//! caller does NOT receive the parsed payload (because there is none).
//!
//! A shell wrapper that just runs `cargo test --package chump-handoff
//! --test contract_violation` can be added in a follow-up gap once the
//! scripts/ci lease clears — the substantive check lives here so it stays
//! Rust-first per META-064.

use chump_handoff::contracts::{GapReviewContract, GapReviewInput};
use chump_handoff::transport::StubTransport;
use chump_handoff::{dispatch, HandoffError};

/// Read every `handoff_contract_violation` event from the ambient log written
/// during this test (we set CHUMP_AMBIENT_LOG to a per-test tempfile so
/// concurrent tests don't see each other).
fn read_violations(path: &std::path::Path) -> Vec<serde_json::Value> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return vec![],
    };
    text.lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|v| v["kind"].as_str() == Some("handoff_contract_violation"))
        .collect()
}

#[tokio::test]
#[serial_test::serial]
async fn malformed_output_rejected_and_logged() {
    // Per-test ambient file so we can assert deterministically.
    let dir = tempfile::tempdir().expect("tempdir");
    let ambient = dir.path().join("ambient.jsonl");
    std::env::set_var("CHUMP_AMBIENT_LOG", &ambient);

    // Subagent reply is valid JSON but missing required `reasoning` field.
    // (Per GapReviewOutput schema: verdict + reasoning + blocking_concerns.)
    let stub = StubTransport::new(
        r#"```json
{"verdict": "approve"}
```"#,
    );

    let input = GapReviewInput {
        gap_id: "INFRA-1720".into(),
        context: "smoke".into(),
    };
    let result = dispatch::<GapReviewContract>(&stub, "test-agent", input).await;

    // Caller must NOT receive a parsed payload — schema mismatch is fatal.
    assert!(result.is_err(), "expected schema mismatch, got {result:?}");
    match result {
        Err(HandoffError::SchemaMismatch {
            contract,
            raw_output_first_100,
            ..
        }) => {
            assert_eq!(contract, "GapReviewContract");
            assert!(raw_output_first_100.contains("approve"));
        }
        other => panic!("expected SchemaMismatch, got {other:?}"),
    }

    // Ambient event was written with the right kind + contract_name.
    let events = read_violations(&ambient);
    assert_eq!(
        events.len(),
        1,
        "expected exactly one handoff_contract_violation event, got {}: {events:?}",
        events.len()
    );
    assert_eq!(
        events[0]["contract_name"].as_str(),
        Some("GapReviewContract")
    );
    // First-100 field non-empty so dashboards have something to render.
    assert!(events[0]["raw_output_first_100"]
        .as_str()
        .map(|s| !s.is_empty())
        .unwrap_or(false));
}

#[tokio::test]
#[serial_test::serial]
async fn validation_failure_logged_separately_from_schema_mismatch() {
    // Per-test ambient file.
    let dir = tempfile::tempdir().expect("tempdir");
    let ambient = dir.path().join("ambient.jsonl");
    std::env::set_var("CHUMP_AMBIENT_LOG", &ambient);

    // JSON shape is fine — every field present — but `verdict` is not one of
    // approve|revise|block, so validate() rejects. Confirms the *semantic*
    // boundary is distinct from the *schema* boundary in the dispatch
    // pipeline.
    let stub = StubTransport::new(
        r#"```json
{"verdict":"maybe","reasoning":"x","blocking_concerns":[]}
```"#,
    );
    let input = GapReviewInput {
        gap_id: "INFRA-1720".into(),
        context: "semantic".into(),
    };
    let result = dispatch::<GapReviewContract>(&stub, "test-agent", input).await;
    match result {
        Err(HandoffError::ValidationFailed { contract, error }) => {
            assert_eq!(contract, "GapReviewContract");
            assert!(error.contains("approve|revise|block"));
        }
        other => panic!("expected ValidationFailed, got {other:?}"),
    }

    let events = read_violations(&ambient);
    assert_eq!(events.len(), 1, "expected one violation event");
    assert_eq!(
        events[0]["contract_name"].as_str(),
        Some("GapReviewContract")
    );
}

#[tokio::test]
#[serial_test::serial]
async fn happy_path_returns_typed_output() {
    // Per-test ambient file (we expect no violations).
    let dir = tempfile::tempdir().expect("tempdir");
    let ambient = dir.path().join("ambient.jsonl");
    std::env::set_var("CHUMP_AMBIENT_LOG", &ambient);

    let stub = StubTransport::new(
        r#"Some preamble the subagent might add.
```json
{
  "verdict": "approve",
  "reasoning": "scope is tight, AC concrete, no cross-file collisions",
  "blocking_concerns": []
}
```
And some trailing commentary that should be ignored."#,
    );
    let input = GapReviewInput {
        gap_id: "INFRA-1720".into(),
        context: "happy".into(),
    };
    let out = dispatch::<GapReviewContract>(&stub, "test-agent", input)
        .await
        .expect("happy path");
    assert_eq!(out.verdict, "approve");
    assert!(out.reasoning.contains("scope"));
    assert!(out.blocking_concerns.is_empty());

    // No violations.
    assert!(read_violations(&ambient).is_empty());
}

#[tokio::test]
#[serial_test::serial]
async fn transport_error_routed_to_dispatch_error() {
    let dir = tempfile::tempdir().expect("tempdir");
    let ambient = dir.path().join("ambient.jsonl");
    std::env::set_var("CHUMP_AMBIENT_LOG", &ambient);

    let stub = StubTransport::err("runner not on PATH");
    let result = dispatch::<GapReviewContract>(
        &stub,
        "test-agent",
        GapReviewInput {
            gap_id: "INFRA-1720".into(),
            context: "transport".into(),
        },
    )
    .await;
    match result {
        Err(HandoffError::DispatchError { contract, source }) => {
            assert_eq!(contract, "GapReviewContract");
            assert!(source.to_string().contains("runner not on PATH"));
        }
        other => panic!("expected DispatchError, got {other:?}"),
    }
    // Transport errors are still observability-worthy — we expect a
    // violation event so dashboards see the contract attempted + failed.
    let events = read_violations(&ambient);
    assert_eq!(
        events.len(),
        1,
        "expected one violation event for dispatch error"
    );
}
