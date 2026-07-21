//! Axum router: receive + store per-lane CI status updates.
//!
//! META-135 (non-gating slice): no aggregation/decision endpoint exists yet.
//! That's tracked separately per `docs/design/CI_VERIFIED_AGGREGATOR.md`
//! (META-134).

use std::sync::Arc;

use axum::{
    extract::{Query, State},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

use crate::db::{now_ms, AggregatorStore, LaneStatusUpdate};

pub type SharedStore = Arc<AggregatorStore>;

#[derive(Clone)]
pub struct AppState {
    pub store: SharedStore,
}

pub fn build_router(store: SharedStore) -> Router {
    let state = AppState { store };
    Router::new()
        .route(
            "/api/lane-status",
            post(post_lane_status).get(get_lane_status),
        )
        .route("/healthz", get(healthz))
        .with_state(state)
}

#[derive(Debug, Deserialize)]
pub struct LaneStatusQuery {
    pub pr: i64,
    pub sha: String,
}

#[derive(Serialize)]
struct AcceptedResponse {
    accepted: bool,
    id: i64,
}

/// POST /api/lane-status
///
/// Body: `{"pr": <n>, "sha": "<sha>", "lane": "<name>", "result": "<result>"}`
///
/// Stores the update. Does not aggregate, classify, or gate — that logic is
/// out of scope for this slice (AC #3).
async fn post_lane_status(
    State(s): State<AppState>,
    Json(update): Json<LaneStatusUpdate>,
) -> Response {
    match s.store.insert_lane_status(&update, now_ms()) {
        Ok(id) => Json(AcceptedResponse { accepted: true, id }).into_response(),
        Err(e) => {
            tracing::error!("POST /api/lane-status error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/lane-status?pr=<n>&sha=<sha>
///
/// Returns the raw stored status updates for a (pr, sha) pair, oldest first.
async fn get_lane_status(State(s): State<AppState>, Query(q): Query<LaneStatusQuery>) -> Response {
    match s.store.query_lane_status(q.pr, &q.sha) {
        Ok(rows) => Json(rows).into_response(),
        Err(e) => {
            tracing::error!("GET /api/lane-status error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

async fn healthz() -> &'static str {
    "ok"
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use std::path::Path;
    use tower::ServiceExt;

    fn test_router() -> Router {
        let store = Arc::new(AggregatorStore::open(Path::new(":memory:")).unwrap());
        build_router(store)
    }

    #[tokio::test]
    async fn healthz_returns_ok() {
        let app = test_router();
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/healthz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn post_then_get_round_trips() {
        let app = test_router();
        let body = serde_json::json!({
            "pr": 7,
            "sha": "deadbeef",
            "lane": "audit",
            "result": "success"
        });
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/lane-status")
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/lane-status?pr=7&sha=deadbeef")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let rows: Vec<serde_json::Value> = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["lane"], "audit");
        assert_eq!(rows[0]["result"], "success");
    }

    #[tokio::test]
    async fn get_unknown_pr_sha_returns_empty_array() {
        let app = test_router();
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/lane-status?pr=999&sha=nope")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let rows: Vec<serde_json::Value> = serde_json::from_slice(&bytes).unwrap();
        assert!(rows.is_empty());
    }
}
