//! Integration test for the fleet-scrubber static mount (INFRA-2176).
//!
//! Regression guard: the scrubber README + `scripts/dev/chump-fleet-view.sh`
//! have always documented the forensic timeline as reachable at
//! `http://localhost:7070/scrubber`, but the server only ever mounted the
//! cockpit fallback (`web/cockpit-live` at `/`) — so live mode 404'd and the
//! page only worked in `?fixtures=1` demo mode. This test builds the real
//! router against the repo working tree and proves `/scrubber` now serves the
//! SPA and its nested fixture assets.
//!
//! Uses `axum::Router::oneshot` (no network socket).
//!
//! Test depth: happy-path integration. Covers that the route is mounted and
//! serves index.html + a nested static asset. Does NOT cover the /api/* data
//! path the page consumes at runtime (covered by dashboard_summary.rs et al),
//! the WebSocket live-tail, or browser rendering.

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use std::path::PathBuf;
use std::sync::Arc;
use tower::ServiceExt; // for `.oneshot()`

use chump_fleet_server::{db::FleetStore, routes};

/// repo_root = two levels up from this crate's manifest dir
/// (crates/chump-fleet-server -> repo root), so `web/fleet-scrubber/` exists.
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("crate manifest dir has a two-level parent (repo root)")
        .to_path_buf()
}

fn build_app() -> axum::Router {
    let root = repo_root();
    // A throwaway DB in a temp dir — this test only exercises static serving,
    // not the event store.
    let dbdir = std::env::temp_dir().join(format!(
        "chump-test-scrubber-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dbdir).unwrap();
    let store = Arc::new(FleetStore::open(&dbdir.join("fleet_events_test.db")).unwrap());
    routes::build_router(store, root)
}

async fn get(app: &axum::Router, uri: &str) -> (StatusCode, String) {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(uri)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), 4 << 20)
        .await
        .unwrap();
    (status, String::from_utf8_lossy(&bytes).to_string())
}

#[tokio::test]
async fn scrubber_static_mount_serves_spa_and_fixtures() {
    let app = build_app();

    // (a) /scrubber/ serves the SPA index.html (append_index_html).
    let (status, body) = get(&app, "/scrubber/").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "GET /scrubber/ must serve web/fleet-scrubber/index.html, not 404"
    );
    assert!(
        body.contains("Fleet Scrubber"),
        "served body should be the scrubber SPA (contains its <h1>)"
    );

    // (b) Nested static assets resolve — the ?fixtures=1 demo path depends on
    // /scrubber/fixtures/segments.json being reachable through the same mount.
    let (fx_status, fx_body) = get(&app, "/scrubber/fixtures/segments.json").await;
    assert_eq!(
        fx_status,
        StatusCode::OK,
        "nested fixture asset must resolve through the /scrubber mount"
    );
    assert!(
        fx_body.trim_start().starts_with('['),
        "segments.json is a JSON array of segments"
    );

    // (c) The cockpit fallback still owns `/` — the new mount must not shadow it.
    let (root_status, _) = get(&app, "/").await;
    assert_eq!(
        root_status,
        StatusCode::OK,
        "cockpit fallback at / is unaffected by the /scrubber nest"
    );
}
