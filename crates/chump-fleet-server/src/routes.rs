//! Axum router: REST endpoints + WebSocket live-tail.

use std::path::PathBuf;
use std::sync::Arc;

use axum::{
    extract::{Path, Query, State, WebSocketUpgrade},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tokio::time::{interval, Duration};

use crate::dashboard;
use crate::db::{now_ms, FleetStore};
use crate::gap_write::{self, GapWriteRequest};
use crate::mission::{self, MissionRequest};

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
        .route("/api/mission", post(post_mission))
        .route("/api/gap", post(post_gap))
        .route("/api/gaps", get(get_gaps))
        .route("/api/sentinel-heartbeat", post(post_sentinel_heartbeat))
        .route("/api/fleet/nodes", get(get_fleet_nodes))
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

/// Shared fail-closed bearer-auth check for the bat-phone routes
/// (`/api/mission`, `/api/gap`, `/api/gaps`). Returns `Some(response)` when
/// the request must be rejected (503 unconfigured / 401 wrong token), or
/// `None` when the caller is authorized to proceed.
fn check_bearer_auth(headers: &axum::http::HeaderMap) -> Option<Response> {
    let Some(expected) = mission::configured_token() else {
        return Some(
            (
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({
                    "error": "bat-phone disabled: CHUMP_BATPHONE_TOKEN not set"
                })),
            )
                .into_response(),
        );
    };
    let presented = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.strip_prefix("Bearer ").unwrap_or(v).trim().to_string())
        .unwrap_or_default();
    if !mission::constant_time_eq(&presented, &expected) {
        return Some(
            (
                axum::http::StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({"error": "unauthorized"})),
            )
                .into_response(),
        );
    }
    None
}

/// GET /api/gaps (RESILIENT-1030) — authed read of the open-gap queue state.
///
/// Same fail-closed bearer auth as `/api/mission` and `/api/gap`. Lets the
/// operator see what's pickable over the tailnet API instead of
/// SSH+sqlite+`chump gap list`.
async fn get_gaps(State(s): State<AppState>, headers: axum::http::HeaderMap) -> Response {
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    let repo_root = s.repo_root.clone();
    let result = tokio::task::spawn_blocking(move || gap_write::list_open_gaps(&repo_root)).await;

    match result {
        Ok(Ok(gaps)) => Json(gaps).into_response(),
        Ok(Err(e)) => {
            tracing::error!("GET /api/gaps failed: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("GET /api/gaps task join error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            )
                .into_response()
        }
    }
}

/// POST /api/mission — bat-phone external mission intake (EFFECTIVE-513).
///
/// Fail-closed bearer auth via `CHUMP_BATPHONE_TOKEN`. On success it reserves a
/// gap, seeds description + AC, and spawns a detached `chump gap decompose`
/// (never awaited — it runs ~1-2 min under a free-tier LLM and must not block
/// the response or halt the fleet). Returns 202 with the created gap id; the
/// fleet queue picks up the slices on its own cadence.
async fn post_mission(
    State(s): State<AppState>,
    headers: axum::http::HeaderMap,
    payload: Result<Json<MissionRequest>, axum::extract::rejection::JsonRejection>,
) -> Response {
    // 1. Auth — fail-closed. No token configured => route refuses entirely.
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    // 2. Body.
    let req = match payload {
        Ok(Json(r)) => r,
        Err(e) => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("invalid JSON body: {e}")})),
            )
                .into_response();
        }
    };
    if req.title.trim().is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "title is required"})),
        )
            .into_response();
    }

    // 3. Reserve + set + spawn decompose off the async runtime (it shells out).
    let repo_root = s.repo_root.clone();
    let result =
        tokio::task::spawn_blocking(move || mission::create_mission_gap(&repo_root, req)).await;

    match result {
        Ok(Ok(outcome)) => (axum::http::StatusCode::ACCEPTED, Json(outcome)).into_response(),
        Ok(Err(e)) => {
            tracing::error!("POST /api/mission failed: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("POST /api/mission task join error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            )
                .into_response()
        }
    }
}

/// POST /api/gap — bat-phone canonical gap-write (INFRA-3689).
///
/// Second dispatch surface alongside `POST /api/mission`: exposes the raw
/// `chump gap reserve|set|ship` primitive over HTTP so a non-canonical/stale
/// client (the operator's Mac) can mutate canonical gap state WITHOUT
/// holding a writable local canonical replica — it delegates the write to
/// this server, which runs on owned iron (CJ) against the real checkout.
///
/// Auth is the EXACT same fail-closed bearer check as `post_mission` — same
/// `CHUMP_BATPHONE_TOKEN` env, same constant-time comparison, same
/// 503-when-unconfigured / 401-when-wrong semantics. `op` is validated
/// against the `reserve|set|ship` allow-list before any shell-out; an
/// unknown op is a 400, never reaches `gap_write::execute_gap_write`.
async fn post_gap(
    State(s): State<AppState>,
    headers: axum::http::HeaderMap,
    payload: Result<Json<GapWriteRequest>, axum::extract::rejection::JsonRejection>,
) -> Response {
    // 1. Auth — fail-closed, identical to post_mission.
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    // 2. Body.
    let req = match payload {
        Ok(Json(r)) => r,
        Err(e) => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("invalid JSON body: {e}")})),
            )
                .into_response();
        }
    };

    // 3. op allow-list — 400 before any shell-out.
    if !gap_write::is_valid_op(&req.op) {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "error": format!(
                    "unsupported op {:?} (allowed: {:?})",
                    req.op,
                    gap_write::ALLOWED_OPS
                )
            })),
        )
            .into_response();
    }

    // 4. Execute off the async runtime (it shells out).
    let repo_root = s.repo_root.clone();
    let result =
        tokio::task::spawn_blocking(move || gap_write::execute_gap_write(&repo_root, req)).await;

    match result {
        Ok(Ok(outcome)) => (axum::http::StatusCode::ACCEPTED, Json(outcome)).into_response(),
        Ok(Err(e)) => {
            tracing::error!("POST /api/gap failed: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("POST /api/gap task join error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            )
                .into_response()
        }
    }
}

// ── fleet-health heartbeats (RESILIENT-1055) ──────────────────────────────────

/// Default staleness threshold (seconds): sentinel cadence 5m × stale-mult 3.
/// Overridable via `CHUMP_SENTINEL_STALE_SECS` to stay coherent with the
/// sentinel's own `CHUMP_SENTINEL_CADENCE_MIN` / `CHUMP_SENTINEL_STALE_MULT`.
const DEFAULT_STALE_SECS: i64 = 900;

fn stale_threshold_secs() -> i64 {
    std::env::var("CHUMP_SENTINEL_STALE_SECS")
        .ok()
        .and_then(|v| v.trim().parse::<i64>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(DEFAULT_STALE_SECS)
}

/// One node's health as reported by its last heartbeat, with server-computed
/// freshness. `health` is the raw heartbeat body re-parsed, so per-organ detail
/// (`failed_units`, `healers`) flows through untouched.
#[derive(Serialize)]
struct FleetNodeHealth {
    node: String,
    epoch: i64,
    received_ms: i64,
    age_secs: i64,
    stale: bool,
    health: serde_json::Value,
}

#[derive(Serialize)]
struct FleetNodesResponse {
    generated_ms: i64,
    stale_threshold_secs: i64,
    node_count: usize,
    stale_count: usize,
    /// Total `failed` chump units summed across all reporting nodes — the
    /// single number that would have caught the 33-failed-organ incident.
    failed_units_total: i64,
    nodes: Vec<FleetNodeHealth>,
}

/// POST /api/sentinel-heartbeat (RESILIENT-1055) — ingest sink for the
/// per-node fleet-health-sentinel heartbeat.
///
/// The sentinel (`scripts/ops/fleet-health-sentinel.sh`) already POSTs its
/// heartbeat file here every pass; before this route it hit a 404 void. Body is
/// the heartbeat JSON: it MUST carry a non-empty `node`; `epoch` (seconds) is
/// used for staleness and falls back to server receive-time when absent. The
/// full body is stored verbatim (keyed by node, latest wins).
///
/// Auth is the EXACT same fail-closed bearer check as the other write routes
/// (`CHUMP_BATPHONE_TOKEN`), so a node pushing over the tailnet authenticates
/// identically to `/api/gap`.
async fn post_sentinel_heartbeat(
    State(s): State<AppState>,
    headers: axum::http::HeaderMap,
    body: String,
) -> Response {
    // 1. Auth — fail-closed, identical to post_gap / post_mission.
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    // 2. Parse body as JSON object.
    let value: serde_json::Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("invalid JSON body: {e}")})),
            )
                .into_response();
        }
    };

    // 3. node is required (the aggregation key).
    let node = value
        .get("node")
        .and_then(|v| v.as_str())
        .map(|s| s.trim())
        .unwrap_or_default();
    if node.is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "heartbeat body must include a non-empty \"node\""})),
        )
            .into_response();
    }

    let received_ms = now_ms();
    // epoch (seconds) is the node's own stamp; fall back to receive time.
    let epoch = value
        .get("epoch")
        .and_then(|v| v.as_i64())
        .unwrap_or(received_ms / 1000);

    match s
        .store
        .upsert_node_heartbeat(node, epoch, received_ms, &body)
    {
        Ok(()) => (
            axum::http::StatusCode::ACCEPTED,
            Json(serde_json::json!({"ok": true, "node": node, "epoch": epoch})),
        )
            .into_response(),
        Err(e) => {
            tracing::error!("POST /api/sentinel-heartbeat store error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/fleet/nodes (RESILIENT-1055) — cross-node organ health, aggregated
/// server-side from the pushed heartbeats.
///
/// Replaces the SSH crawl the sentinel's `--fleet` grade did (the covenant
/// break): the operator reads one authenticated route instead of `ssh`-ing each
/// node. Each node reports its `failed` count plus `failed_units` / `healers`
/// detail; the server stamps `age_secs` + `stale` per node so a dead sentinel
/// shows as a stale row rather than silence. Same fail-closed bearer auth as
/// `/api/gaps`.
async fn get_fleet_nodes(State(s): State<AppState>, headers: axum::http::HeaderMap) -> Response {
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    let rows = match s.store.list_node_heartbeats() {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("GET /api/fleet/nodes error: {e}");
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response();
        }
    };

    let now = now_ms();
    let now_secs = now / 1000;
    let threshold = stale_threshold_secs();
    let mut stale_count = 0usize;
    let mut failed_units_total = 0i64;

    let nodes: Vec<FleetNodeHealth> = rows
        .into_iter()
        .map(|hb| {
            let age_secs = (now_secs - hb.epoch).max(0);
            let stale = age_secs > threshold;
            if stale {
                stale_count += 1;
            }
            // Re-parse the stored body so per-organ detail passes through; on a
            // malformed row fall back to the raw string rather than dropping it.
            let health: serde_json::Value = serde_json::from_str(&hb.payload)
                .unwrap_or_else(|_| serde_json::json!({"raw": hb.payload}));
            failed_units_total += health.get("failed").and_then(|v| v.as_i64()).unwrap_or(0);
            FleetNodeHealth {
                node: hb.node,
                epoch: hb.epoch,
                received_ms: hb.received_ms,
                age_secs,
                stale,
                health,
            }
        })
        .collect();

    Json(FleetNodesResponse {
        generated_ms: now,
        stale_threshold_secs: threshold,
        node_count: nodes.len(),
        stale_count,
        failed_units_total,
        nodes,
    })
    .into_response()
}

/// GET /healthz — liveness probe.
async fn healthz() -> &'static str {
    "ok"
}
