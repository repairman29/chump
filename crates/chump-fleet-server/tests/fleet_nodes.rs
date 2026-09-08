//! Integration tests for the fleet-health telemetry routes (RESILIENT-1055):
//! POST /api/sentinel-heartbeat (ingest) + GET /api/fleet/nodes (aggregate).
//!
//! Uses `axum::Router::oneshot` (no network socket). Auth is the same
//! fail-closed bat-phone bearer check as /api/gap, so the security assertions
//! mirror mission_intake.rs. The round-trip test proves the whole point of the
//! stream: a node's per-organ health (which units are failed) becomes an
//! authenticated API READ instead of an SSH crawl.
//!
//! All assertions live in ONE test so the shared-process `CHUMP_BATPHONE_TOKEN`
//! env var is mutated sequentially, never racing a parallel test.

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt; // for `.oneshot()`

use chump_fleet_server::mission::BATPHONE_TOKEN_ENV;
use chump_fleet_server::{db::FleetStore, routes};

fn build_app() -> axum::Router {
    let dir = std::env::temp_dir().join(format!(
        "chump-test-fleetnodes-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let store = Arc::new(FleetStore::open(&dir.join("fleet_events_test.db")).unwrap());
    routes::build_router(store, dir)
}

async fn post_heartbeat(app: &axum::Router, auth: Option<&str>, body: Value) -> StatusCode {
    let mut builder = Request::builder()
        .method("POST")
        .uri("/api/sentinel-heartbeat")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        builder = builder.header("authorization", a);
    }
    let req = builder.body(Body::from(body.to_string())).unwrap();
    app.clone().oneshot(req).await.unwrap().status()
}

async fn get_nodes(app: &axum::Router, auth: Option<&str>) -> (StatusCode, Value) {
    let mut builder = Request::builder().method("GET").uri("/api/fleet/nodes");
    if let Some(a) = auth {
        builder = builder.header("authorization", a);
    }
    let resp = app
        .clone()
        .oneshot(builder.body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), 1 << 20)
        .await
        .unwrap();
    let val: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, val)
}

#[tokio::test]
async fn sentinel_heartbeat_and_fleet_nodes_roundtrip() {
    let token = "s3cret-fleet-token";
    let app = build_app();

    // (a) Fail-closed: no token configured -> 503 on both routes.
    std::env::remove_var(BATPHONE_TOKEN_ENV);
    assert_eq!(
        post_heartbeat(&app, Some(&format!("Bearer {token}")), json!({"node": "x"})).await,
        StatusCode::SERVICE_UNAVAILABLE,
        "ingest must fail closed when token unset"
    );
    assert_eq!(
        get_nodes(&app, Some(&format!("Bearer {token}"))).await.0,
        StatusCode::SERVICE_UNAVAILABLE,
        "aggregate read must fail closed when token unset"
    );

    // (b) Wrong / missing bearer -> 401.
    std::env::set_var(BATPHONE_TOKEN_ENV, token);
    assert_eq!(
        post_heartbeat(&app, Some("Bearer nope"), json!({"node": "x"})).await,
        StatusCode::UNAUTHORIZED,
        "wrong token -> 401"
    );
    assert_eq!(
        get_nodes(&app, None).await.0,
        StatusCode::UNAUTHORIZED,
        "missing bearer -> 401"
    );

    // (c) Missing `node` -> 400 (the aggregation key is required).
    assert_eq!(
        post_heartbeat(&app, Some(&format!("Bearer {token}")), json!({"epoch": 1})).await,
        StatusCode::BAD_REQUEST,
        "heartbeat without node -> 400"
    );

    // (d) Ingest two nodes' real-shaped heartbeats, one carrying a failed organ.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let cuphead = json!({
        "node": "cuphead", "epoch": now,
        "failed": 1, "healed": 0, "unhealed": 1, "healers_down": 0, "healers_fixed": 0,
        "failed_units": ["chump-board-cycle.service"],
        "healers": [{"unit": "chump-organ-reconcile.timer", "required": true, "active": true}]
    });
    let mugman = json!({
        "node": "mugman", "epoch": now - 10_000, // deliberately stale
        "failed": 0, "healed": 0, "unhealed": 0, "healers_down": 0, "healers_fixed": 0,
        "failed_units": [], "healers": []
    });
    assert_eq!(
        post_heartbeat(&app, Some(&format!("Bearer {token}")), cuphead).await,
        StatusCode::ACCEPTED
    );
    assert_eq!(
        post_heartbeat(&app, Some(&format!("Bearer {token}")), mugman).await,
        StatusCode::ACCEPTED
    );

    // (e) Aggregate read returns BOTH nodes with the organ detail + staleness.
    let (status, body) = get_nodes(&app, Some(&format!("Bearer {token}"))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["node_count"], json!(2));
    assert_eq!(
        body["failed_units_total"],
        json!(1),
        "summed failed count across nodes"
    );
    assert_eq!(
        body["stale_count"],
        json!(1),
        "mugman's 10000s-old heartbeat is stale"
    );

    let nodes = body["nodes"].as_array().unwrap();
    let cup = nodes.iter().find(|n| n["node"] == "cuphead").unwrap();
    assert_eq!(cup["stale"], json!(false), "fresh heartbeat not stale");
    assert_eq!(
        cup["health"]["failed_units"][0],
        json!("chump-board-cycle.service"),
        "the failed organ name flows through to the API read"
    );
    let mug = nodes.iter().find(|n| n["node"] == "mugman").unwrap();
    assert_eq!(
        mug["stale"],
        json!(true),
        "stale sentinel shows as a stale row, not silence"
    );

    // (f) Latest-wins: re-ingest cuphead with the organ recovered.
    let cuphead2 = json!({
        "node": "cuphead", "epoch": now,
        "failed": 0, "failed_units": [], "healers": []
    });
    assert_eq!(
        post_heartbeat(&app, Some(&format!("Bearer {token}")), cuphead2).await,
        StatusCode::ACCEPTED
    );
    let (_, body2) = get_nodes(&app, Some(&format!("Bearer {token}"))).await;
    assert_eq!(
        body2["node_count"],
        json!(2),
        "upsert keyed by node — no dup row"
    );
    assert_eq!(
        body2["failed_units_total"],
        json!(0),
        "recovered organ reflected"
    );

    std::env::remove_var(BATPHONE_TOKEN_ENV);
}
