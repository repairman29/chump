//! Integration tests for POST /api/gap — the canonical gap-write bat-phone
//! surface (INFRA-3689).
//!
//! Mirrors `tests/mission_intake.rs`'s pattern: `axum::Router::oneshot` (no
//! network socket), one combined test so the shared-process
//! `CHUMP_BATPHONE_TOKEN` / `CHUMP_BIN` env vars are mutated sequentially,
//! never racing a parallel test. `CHUMP_BIN` points at a fake `chump`
//! script (deterministic, no real network / no real state.db) so the
//! reserve+outcome path exercises the full `gap_write::execute_gap_write`
//! shell-out sequence — including the INFRA-3686 outcome-forwarding
//! follow-up `gap set` call — without depending on a built release binary.

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tower::ServiceExt; // for `.oneshot()`

use chump_fleet_server::mission::BATPHONE_TOKEN_ENV;
use chump_fleet_server::{db::FleetStore, routes};

fn test_dir() -> PathBuf {
    std::env::temp_dir().join(format!("chump-test-gap-write-{}", std::process::id()))
}

fn build_app(repo_root: &Path) -> axum::Router {
    let store = Arc::new(FleetStore::open(&repo_root.join("fleet_events_test.db")).unwrap());
    routes::build_router(store, repo_root.to_path_buf())
}

/// Fake `chump` binary: understands `gap reserve --domain D --title T
/// --priority P --effort E` (echoes a deterministic gap id to stdout) and
/// `gap set <id> ...` (records the call to a log file so the test can
/// assert the outcome/AC follow-up actually ran, per INFRA-3686). Any other
/// invocation exits 0 with empty stdout — good enough for `ship`/plain
/// `set` calls in this suite.
fn write_fake_chump_bin(dir: &Path, gap_id: &str) -> PathBuf {
    let script_path = dir.join("fake-chump-gap-write");
    let log_path = dir.join("fake-chump.log");
    let body = format!(
        r#"#!/bin/sh
echo "$@" >> "{log}"
case "$1 $2" in
  "gap reserve")
    echo "{id}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"#,
        log = log_path.display(),
        id = gap_id,
    );
    std::fs::write(&script_path, body).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&script_path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&script_path, perms).unwrap();
    }
    script_path
}

async fn post_gap(app: axum::Router, auth: Option<&str>, body: Value) -> (StatusCode, Value) {
    let mut builder = Request::builder()
        .method("POST")
        .uri("/api/gap")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        builder = builder.header("authorization", a);
    }
    let req = builder.body(Body::from(body.to_string())).unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let val: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, val)
}

#[tokio::test]
async fn gap_write_auth_op_validation_and_reserve_with_outcome() {
    let dir = test_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let fake_bin = write_fake_chump_bin(&dir, "INFRA-8471");

    // (a) No token configured -> fail-closed 503.
    std::env::remove_var(BATPHONE_TOKEN_ENV);
    std::env::remove_var("CHUMP_BIN");
    let (status, _) = post_gap(
        build_app(&dir),
        Some("Bearer anything"),
        json!({"op": "reserve", "domain": "INFRA", "title": "x"}),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::SERVICE_UNAVAILABLE,
        "unset token must fail closed"
    );

    // (b) Token configured, missing bearer -> 401.
    std::env::set_var(BATPHONE_TOKEN_ENV, "s3cret-token");
    let (status, _) = post_gap(
        build_app(&dir),
        None,
        json!({"op": "reserve", "domain": "INFRA", "title": "x"}),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "missing bearer -> 401");

    // (c) Token configured, wrong bearer -> 401.
    let (status, _) = post_gap(
        build_app(&dir),
        Some("Bearer wrong-token"),
        json!({"op": "reserve", "domain": "INFRA", "title": "x"}),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "wrong token -> 401");

    // (d) Valid auth, bad op -> 400 (before any shell-out — CHUMP_BIN still
    //     unset here, so a 400 proves the allow-list check runs first).
    let (status, body) = post_gap(
        build_app(&dir),
        Some("Bearer s3cret-token"),
        json!({"op": "delete", "gap_id": "INFRA-1"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "unsupported op -> 400");
    assert!(
        body.get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("")
            .contains("unsupported op"),
        "400 body should name the bad op: {body:?}"
    );

    // (e) Valid auth, op=reserve + outcome -> 202, no 500, outcome forwarded
    //     via a follow-up `gap set` (INFRA-3686 fix under test).
    std::env::set_var("CHUMP_BIN", &fake_bin);
    let (status, body) = post_gap(
        build_app(&dir),
        Some("Bearer s3cret-token"),
        json!({
            "op": "reserve",
            "domain": "INFRA",
            "title": "route mutations through the fleet-server",
            "priority": "P0",
            "outcome": "MISSION-010",
            "effort": "m"
        }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "reserve+outcome must not 500: {body:?}"
    );
    assert_eq!(
        body.get("gap_id").and_then(|v| v.as_str()),
        Some("INFRA-8471")
    );
    assert_eq!(body.get("op").and_then(|v| v.as_str()), Some("reserve"));

    // The fake binary logs every invocation; assert BOTH `gap reserve` and a
    // follow-up `gap set ... --outcome MISSION-010` ran — proving the
    // outcome field was forwarded, not silently dropped (INFRA-3686).
    let log = std::fs::read_to_string(dir.join("fake-chump.log")).unwrap_or_default();
    assert!(
        log.contains("gap reserve"),
        "expected a `gap reserve` call, log:\n{log}"
    );
    assert!(
        log.contains("gap set INFRA-8471") && log.contains("--outcome MISSION-010"),
        "expected outcome forwarded via follow-up `gap set`, log:\n{log}"
    );

    std::env::remove_var(BATPHONE_TOKEN_ENV);
    std::env::remove_var("CHUMP_BIN");
    let _ = std::fs::remove_dir_all(&dir);
}
