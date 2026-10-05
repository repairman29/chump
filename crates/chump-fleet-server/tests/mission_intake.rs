//! Integration tests for POST /api/mission — the bat-phone (EFFECTIVE-513).
//!
//! Exercises the security-critical auth surface with `axum::Router::oneshot`
//! (no network socket): fail-closed when no token is configured, and 401 on a
//! wrong / missing bearer. The full gap-creation path is verified live on CJ
//! against the running organ (it shells out to the `chump` binary + a free-tier
//! LLM, which are not present in the unit-test sandbox).
//!
//! All assertions live in ONE test so the shared-process `CHUMP_BATPHONE_TOKEN`
//! env var is mutated sequentially, never racing a parallel test.

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt; // for `.oneshot()`

use chump_fleet_server::mission::BATPHONE_TOKEN_ENV;
use chump_fleet_server::{db::FleetStore, routes};

fn build_app() -> axum::Router {
    let dir = std::env::temp_dir().join(format!("chump-test-mission-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let store = Arc::new(FleetStore::open(&dir.join("fleet_events_test.db")).unwrap());
    routes::build_router(store, dir)
}

/// POST /api/mission with an optional bearer header, returning the status code.
async fn post_status(auth: Option<&str>) -> StatusCode {
    let mut builder = Request::builder()
        .method("POST")
        .uri("/api/mission")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        builder = builder.header("authorization", a);
    }
    let req = builder
        .body(Body::from(json!({"title": "test mission"}).to_string()))
        .unwrap();
    build_app().oneshot(req).await.unwrap().status()
}

#[tokio::test]
async fn mission_auth_is_fail_closed_and_rejects_bad_tokens() {
    // (a) No token configured -> fail-closed 503, even with a bearer present.
    std::env::remove_var(BATPHONE_TOKEN_ENV);
    assert_eq!(
        post_status(Some("Bearer anything")).await,
        StatusCode::SERVICE_UNAVAILABLE,
        "unset token must fail closed"
    );

    // (b) Token configured, wrong bearer -> 401.
    std::env::set_var(BATPHONE_TOKEN_ENV, "s3cret-token");
    assert_eq!(
        post_status(Some("Bearer wrong-token")).await,
        StatusCode::UNAUTHORIZED,
        "wrong token -> 401"
    );

    // (c) Token configured, no bearer at all -> 401.
    assert_eq!(
        post_status(None).await,
        StatusCode::UNAUTHORIZED,
        "missing bearer -> 401"
    );

    std::env::remove_var(BATPHONE_TOKEN_ENV);
}
