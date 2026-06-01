//! Axum router: REST endpoints + WebSocket live-tail.

use std::path::PathBuf;
use std::sync::Arc;

use axum::{
    extract::{Path, Query, State, WebSocketUpgrade},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tokio::time::{interval, Duration};

use crate::dashboard;
use crate::db::{now_ms, FleetStore};

// ── shared state ──────────────────────────────────────────────────────────────

pub type SharedStore = Arc<FleetStore>;

/// Combined application state: the fleet events store plus the repo root path
/// used by the dashboard-summary handler for reading ambient.jsonl, github
/// cache, and claim lease files.
#[derive(Clone)]
pub struct AppState {
    pub store: SharedStore,
    pub repo_root: PathBuf,
}

pub fn build_router(store: SharedStore, repo_root: PathBuf) -> Router {
    let state = AppState { store, repo_root };
    Router::new()
        .route("/api/events", get(get_events))
        .route("/api/segments", get(get_segments))
        .route("/api/sessions/active", get(get_active_sessions))
        .route("/api/trace/pr/{n}", get(get_trace_pr))
        .route("/api/dashboard-summary", get(get_dashboard_summary))
        .route("/api/live", get(ws_live))
        .route("/healthz", get(healthz))
        .with_state(state)
}

// ── query params ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct EventsQuery {
    pub from: Option<i64>,
    pub to: Option<i64>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct SegmentsQuery {
    pub from: Option<i64>,
    pub to: Option<i64>,
}

// ── response envelopes ────────────────────────────────────────────────────────

#[derive(Serialize)]
struct ActiveSessionsResponse {
    session_ids: Vec<String>,
    count: usize,
}

// ── handlers ──────────────────────────────────────────────────────────────────

/// GET /api/events?from=<ts_ms>&to=<ts_ms>&limit=<N>&offset=<N>
///
/// Returns events in [from, to] ordered by ts_ms ASC.
/// Defaults: from = now-1h, to = now, limit = 10000, offset = 0.
/// Hard cap: limit = 50 000.
async fn get_events(State(s): State<AppState>, Query(q): Query<EventsQuery>) -> Response {
    let now = now_ms();
    let from = q.from.unwrap_or(now - 3_600_000); // last 1h
    let to = q.to.unwrap_or(now);
    let limit = q.limit.unwrap_or(10_000);
    let offset = q.offset.unwrap_or(0);

    match s.store.query_events(from, to, limit, offset) {
        Ok(rows) => Json(rows).into_response(),
        Err(e) => {
            tracing::error!("GET /api/events error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/segments?from=<ts_ms>&to=<ts_ms>
///
/// Returns agent_segments rows in window. Defaults: last 1h.
async fn get_segments(State(s): State<AppState>, Query(q): Query<SegmentsQuery>) -> Response {
    let now = now_ms();
    let from = q.from.unwrap_or(now - 3_600_000);
    let to = q.to.unwrap_or(now);

    match s.store.query_segments(from, to) {
        Ok(rows) => Json(rows).into_response(),
        Err(e) => {
            tracing::error!("GET /api/segments error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/sessions/active
///
/// Returns distinct session_ids that have at least one event in the last 5 min.
async fn get_active_sessions(State(s): State<AppState>) -> Response {
    match s.store.active_sessions() {
        Ok(ids) => {
            let count = ids.len();
            Json(ActiveSessionsResponse {
                session_ids: ids,
                count,
            })
            .into_response()
        }
        Err(e) => {
            tracing::error!("GET /api/sessions/active error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/trace/pr/:n
///
/// Best-effort causal chain for PR number n.
/// Queries events whose payload matches "pr <N>" or "#<N>", plus bash_call
/// events referencing "gh pr ..." with the PR number.
async fn get_trace_pr(State(s): State<AppState>, Path(n): Path<i64>) -> Response {
    match s.store.trace_pr(n) {
        Ok(rows) => Json(rows).into_response(),
        Err(e) => {
            tracing::error!("GET /api/trace/pr/{n} error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/dashboard-summary (INFRA-1883)
///
/// Returns today's ship count, latest CI QA score, and active leases in one JSON.
/// All fields are populated synchronously in a `spawn_blocking` task to avoid
/// blocking the async runtime while doing file I/O.
async fn get_dashboard_summary(State(s): State<AppState>) -> Response {
    let repo_root = s.repo_root.clone();
    let result = tokio::task::spawn_blocking(move || dashboard::build_summary(&repo_root)).await;

    match result {
        Ok(summary) => Json(summary).into_response(),
        Err(e) => {
            tracing::error!("GET /api/dashboard-summary task error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error building dashboard summary"})),
            )
                .into_response()
        }
    }
}

/// WS /api/live
///
/// On connect: server polls events table every 1s, pushes new rows (since
/// last-sent id) to the WS client as a JSON array per message.
async fn ws_live(State(s): State<AppState>, ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(move |socket| handle_ws(socket, s.store))
}

async fn handle_ws(mut socket: axum::extract::ws::WebSocket, store: SharedStore) {
    // Start from the current max id so we only send events that arrive after
    // the client connects.
    let mut last_id = match store.max_event_id() {
        Ok(id) => id,
        Err(e) => {
            tracing::error!("ws: failed to get max event id: {e}");
            return;
        }
    };

    let mut ticker = interval(Duration::from_secs(1));

    loop {
        ticker.tick().await;

        let new_events = match store.events_since(last_id) {
            Ok(rows) => rows,
            Err(e) => {
                tracing::warn!("ws: events_since error: {e}");
                continue;
            }
        };

        if new_events.is_empty() {
            continue;
        }

        // Advance the cursor.
        if let Some(last) = new_events.last() {
            last_id = last.id;
        }

        let payload = match serde_json::to_string(&new_events) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("ws: serialization error: {e}");
                continue;
            }
        };

        let msg = axum::extract::ws::Message::Text(payload.into());
        if socket.send(msg).await.is_err() {
            // Client disconnected.
            tracing::debug!("ws: client disconnected");
            break;
        }
    }
}

/// GET /healthz — liveness probe.
async fn healthz() -> &'static str {
    "ok"
}
