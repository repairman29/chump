//! Integration tests for the RESILIENT-1088 cockpit read endpoints:
//! `GET /api/gap-pulse`, `GET /api/vital-signs`, and `GET /api/mission`
//! (the unauthed persons-served read). Uses `axum::Router::oneshot` — no
//! socket — with an on-disk fixture repo root, mirroring `dashboard_summary.rs`.

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use rusqlite::Connection;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tower::ServiceExt;

use chump_fleet_server::{db::FleetStore, routes};

fn tempdir(suffix: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("chump-test-cockpit-{}", suffix));
    let _ = fs::remove_dir_all(&p);
    fs::create_dir_all(&p).unwrap();
    p
}

fn build_app(repo_root: PathBuf) -> axum::Router {
    let db_path = repo_root.join("fleet_events_test.db");
    let store = Arc::new(FleetStore::open(&db_path).unwrap());
    routes::build_router(store, repo_root)
}

async fn get_json(app: axum::Router, uri: &str) -> (StatusCode, Value) {
    let resp = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).expect("valid JSON");
    (status, v)
}

/// Write a minimal canonical `state.db` with the `gaps` + `leases` columns the
/// gap-pulse query reads.
fn write_state_db(chump_dir: &Path) {
    fs::create_dir_all(chump_dir).unwrap();
    let conn = Connection::open(chump_dir.join("state.db")).unwrap();
    conn.execute_batch(
        "CREATE TABLE gaps (
            id TEXT PRIMARY KEY, status TEXT, depends_on TEXT DEFAULT '',
            created_at INTEGER DEFAULT 0, closed_at INTEGER
        );
        CREATE TABLE leases (
            gap_id TEXT, session_id TEXT, expires_at INTEGER
        );",
    )
    .unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    // 4 open gaps:
    //   INFRA-1 open, no deps                 -> pickable
    //   INFRA-2 open, depends_on INFRA-1(open)-> deps-blocked (not pickable)
    //   INFRA-3 open, leased                  -> not pickable (leased)
    //   INFRA-4 open, no deps                 -> pickable
    // plus 1 blocked, 1 in_progress, and a done gap created+closed in-window.
    let rows = [
        ("INFRA-1", "open", "", now, None),
        ("INFRA-2", "open", "INFRA-1", now, None),
        ("INFRA-3", "open", "", now, None),
        ("INFRA-4", "open", "", now, None),
        ("INFRA-5", "blocked", "", now, None),
        ("INFRA-6", "in_progress", "", now, None),
        ("INFRA-7", "done", "", now, Some(now)),
    ];
    for (id, status, deps, created, closed) in rows {
        conn.execute(
            "INSERT INTO gaps (id,status,depends_on,created_at,closed_at) VALUES (?1,?2,?3,?4,?5)",
            rusqlite::params![id, status, deps, created, closed],
        )
        .unwrap();
    }
    // Active lease on INFRA-3 (expires in 1h).
    conn.execute(
        "INSERT INTO leases (gap_id,session_id,expires_at) VALUES ('INFRA-3','sess',?1)",
        rusqlite::params![now + 3600],
    )
    .unwrap();
}

#[tokio::test]
async fn gap_pulse_counts_from_state_db() {
    let root = tempdir("gap-pulse");
    write_state_db(&root.join(".chump"));

    let (status, v) = get_json(build_app(root.clone()), "/api/gap-pulse").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(v["available"], true);
    assert_eq!(v["open"], 4);
    assert_eq!(v["blocked"], 1);
    assert_eq!(v["in_flight"], 1);
    // INFRA-1 + INFRA-4 pickable; INFRA-2 dep-blocked; INFRA-3 leased.
    assert_eq!(v["pickable"], 2);
    assert_eq!(v["leased_open"], 1);
    assert_eq!(v["deps_blocked_open"], 1);
    assert_eq!(v["created_24h"], 7);
    assert_eq!(v["closed_24h"], 1);
    assert_eq!(v["delta_24h"], 6);
}

#[tokio::test]
async fn gap_pulse_missing_db_is_available_false() {
    let root = tempdir("gap-pulse-empty");
    let (status, v) = get_json(build_app(root.clone()), "/api/gap-pulse").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(v["available"], false);
    assert!(v["open"].is_null());
}

#[tokio::test]
async fn vital_signs_serves_contract_and_continuous_autonomy() {
    let root = tempdir("vitals");
    let chump = root.join(".chump");
    fs::create_dir_all(chump.join("metrics")).unwrap();
    // vital-signs.json contract with an outcomes_delivered sign (value null).
    fs::write(
        chump.join("vital-signs.json"),
        serde_json::json!({
            "generated_at": "2026-09-10T00:00:00Z",
            "p_full_trek": 0.42,
            "signs": [
                {"key": "outcomes_delivered", "value": Value::Null, "basis": "uninstrumented"}
            ]
        })
        .to_string(),
    )
    .unwrap();
    // continuous autonomous-ship-rate ledger — newest row wins.
    fs::write(
        chump.join("metrics").join("autonomous-ship-rate.jsonl"),
        "{\"date\":\"2026-09-09\",\"total_prs\":50,\"fleet_filed\":40,\"fleet_filed_autonomous\":10,\"autonomous_rate\":0.250}\n{\"date\":\"2026-09-10\",\"total_prs\":55,\"fleet_filed\":48,\"fleet_filed_autonomous\":24,\"autonomous_rate\":0.500}\n",
    )
    .unwrap();

    let (status, v) = get_json(build_app(root.clone()), "/api/vital-signs").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(v["available"], true);
    assert_eq!(v["vital_signs"]["p_full_trek"], 0.42);
    assert_eq!(v["autonomy"]["available"], true);
    assert_eq!(v["autonomy"]["rate_pct"], 50.0);
    assert_eq!(v["autonomy"]["fleet_filed_autonomous"], 24);
    assert_eq!(v["autonomy"]["baseline_pct"], 12.5);
}

#[tokio::test]
async fn mission_get_returns_persons_served_from_outcomes_sign() {
    let root = tempdir("mission-get");
    let chump = root.join(".chump");
    fs::create_dir_all(&chump).unwrap();
    fs::write(
        chump.join("vital-signs.json"),
        serde_json::json!({
            "signs": [
                {"key": "outcomes_delivered", "value": 3, "basis": "3 delivery events"}
            ]
        })
        .to_string(),
    )
    .unwrap();

    let (status, v) = get_json(build_app(root.clone()), "/api/mission").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(v["persons_served"], 3.0);
    assert!(v["basis"].as_str().unwrap().contains("delivery"));
}
