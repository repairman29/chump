//! Axum router — non-gating slice (META-135).
//!
//! Endpoints:
//! - `POST /api/lane-status` — receive + store one lane status update.
//! - `GET  /api/lane-status?pr=<N>&sha=<SHA>` — read back raw stored updates
//!   for a PR/sha (no aggregation/decision).
//! - `GET  /healthz`

use std::sync::Arc;

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

use crate::db::{now_ms, AggregatorStore, LaneStatusUpdate};

pub type SharedStore = Arc<AggregatorStore>;

pub fn build_router(store: SharedStore) -> Router {
    Router::new()
        .route(
            "/api/lane-status",
            post(post_lane_status).get(get_lane_status),
        )
        .route("/healthz", get(healthz))
        .with_state(store)
}

async fn healthz() -> &'static str {
    "ok"
}

#[derive(Debug, Serialize)]
struct PostLaneStatusResponse {
    stored: bool,
    id: i64,
}

async fn post_lane_status(
    State(store): State<SharedStore>,
    Json(update): Json<LaneStatusUpdate>,
) -> Response {
    match store.record(&update, now_ms()) {
        Ok(row) => (
            StatusCode::CREATED,
            Json(PostLaneStatusResponse {
                stored: true,
                id: row.id,
            }),
        )
            .into_response(),
        Err(err) => {
            tracing::error!(error = %err, "failed to record lane status");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            )
                .into_response()
        }
    }
}

#[derive(Debug, Deserialize)]
struct LaneStatusQuery {
    pr: i64,
    sha: String,
}

async fn get_lane_status(
    State(store): State<SharedStore>,
    Query(q): Query<LaneStatusQuery>,
) -> Response {
    match store.lanes_for(q.pr, &q.sha) {
        Ok(lanes) => Json(lanes).into_response(),
        Err(err) => {
            tracing::error!(error = %err, "failed to read lane status");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            )
                .into_response()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    fn test_store() -> SharedStore {
        Arc::new(AggregatorStore::open_in_memory().unwrap())
    }

    #[tokio::test]
    async fn healthz_returns_ok() {
        let app = build_router(test_store());
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
    async fn post_then_get_round_trips_lane_status() {
        let app = build_router(test_store());

        let body = serde_json::json!({
            "pr": 7,
            "sha": "deadbeef",
            "lane": "cargo-test",
            "conclusion": "success"
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
        assert_eq!(resp.status(), StatusCode::CREATED);

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
        let lanes: Vec<serde_json::Value> = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(lanes.len(), 1);
        assert_eq!(lanes[0]["lane"], "cargo-test");
        assert_eq!(lanes[0]["conclusion"], "success");
    }
}
