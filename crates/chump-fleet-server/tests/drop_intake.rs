//! Integration tests for POST /api/drop — the cheap idea-drop endpoint
//! (EFFECTIVE-679).
//!
//! Exercises the full HTTP surface via `axum::Router::oneshot` (no network
//! socket): create returns 201 + a durable id, a duplicate submission
//! returns 200 with the same id (idempotency, AC4), and the row survives
//! across a fresh router built over the same repo_root (durability, AC3).

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tower::ServiceExt; // for `.oneshot()`

use chump_fleet_server::{db::FleetStore, routes};

fn test_dir() -> PathBuf {
    std::env::temp_dir().join(format!("chump-test-drop-intake-{}", std::process::id()))
}

fn build_app(repo_root: &Path) -> axum::Router {
    let store = Arc::new(FleetStore::open(&repo_root.join("fleet_events_test.db")).unwrap());
    routes::build_router(store, repo_root.to_path_buf())
}

async fn post_drop(repo_root: &Path, body: Value) -> (StatusCode, Value) {
    let req = Request::builder()
        .method("POST")
        .uri("/api/drop")
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = build_app(repo_root).oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}

#[tokio::test]
async fn drop_create_then_duplicate_is_idempotent_and_durable() {
    let dir = test_dir();
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    // (a) First submission -> 201 Created with a drop id, status "new".
    let (status, body) = post_drop(
        &dir,
        json!({"sentence": "try synthetic-load harness", "citation": "CP-008"}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let id = body["id"].as_str().unwrap().to_string();
    assert!(!id.is_empty());
    assert_eq!(body["status"], "new");
    assert_eq!(body["sentence"], "try synthetic-load harness");
    assert_eq!(body["citation"], "CP-008");

    // (b) Durable to disk: file exists and holds exactly one row (AC2/AC3).
    let drops_path = dir.join(".chump").join("idea_drops.jsonl");
    assert!(drops_path.exists(), "drop queue file must be created");
    let contents = std::fs::read_to_string(&drops_path).unwrap();
    assert_eq!(contents.lines().count(), 1);

    // (c) Exact duplicate submission (fresh router, same repo_root, so this
    // also proves the queue survives a "session exit") -> 200 with the SAME
    // id, no new row appended (AC4).
    let (status2, body2) = post_drop(
        &dir,
        json!({"sentence": "try synthetic-load harness", "citation": "CP-008"}),
    )
    .await;
    assert_eq!(status2, StatusCode::OK);
    assert_eq!(
        body2["id"], id,
        "duplicate submission must return existing id"
    );

    let contents_after = std::fs::read_to_string(&drops_path).unwrap();
    assert_eq!(
        contents_after.lines().count(),
        1,
        "duplicate must not append a new row"
    );

    // (d) A different sentence/citation gets a different id.
    let (status3, body3) = post_drop(
        &dir,
        json!({"sentence": "try a different idea", "citation": "CP-008"}),
    )
    .await;
    assert_eq!(status3, StatusCode::CREATED);
    assert_ne!(body3["id"], id);
}

#[tokio::test]
async fn drop_rejects_missing_or_blank_sentence() {
    let dir = test_dir().join("blank");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let (status, body) = post_drop(&dir, json!({"citation": "no sentence field"})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("sentence"));

    let (status2, _) = post_drop(&dir, json!({"sentence": "   "})).await;
    assert_eq!(status2, StatusCode::BAD_REQUEST);
}
