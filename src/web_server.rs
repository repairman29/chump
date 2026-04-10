//! axum HTTP server for Chump Web: health check, chat API (SSE), static PWA files.
//! Run with `chump --web`. Sprint 2: POST /api/chat returns SSE stream.

use anyhow::Result;
use axum::{
    extract::{Multipart, Path, Query},
    http::{HeaderMap, StatusCode},
    response::{
        sse::{Event, Sse},
        Redirect,
    },
    routing::{delete, get, post, put},
    Json, Router,
};
use std::path::PathBuf;
use std::time::Duration;
use tokio_stream::wrappers::UnboundedReceiverStream;
use tokio_stream::StreamExt;
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::services::ServeDir;

use crate::agent_loop::ChumpAgent;
use crate::approval_resolver;
use crate::autopilot;
use crate::db_pool;
use crate::discord;
use crate::episode_db;
use crate::limits;
use crate::local_openai;
use crate::provider_cascade;
use crate::repo_path;
use crate::stream_events::{self, AgentEvent};
use crate::streaming_provider::StreamingProvider;
use crate::task_db;
use crate::web_brain;
use crate::web_sessions_db;
use crate::web_uploads;

#[derive(serde::Deserialize)]
struct SessionCreateBody {
    #[serde(default)]
    bot: Option<String>,
}

#[derive(serde::Deserialize)]
struct ChatRequest {
    message: String,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    attachments: Option<Vec<AttachmentRef>>,
    /// "chump" | "mabel" — selects which agent to use. Default chump.
    #[serde(default)]
    bot: Option<String>,
}

#[derive(serde::Deserialize, serde::Serialize)]
struct AttachmentRef {
    file_id: String,
    filename: String,
    #[serde(default)]
    mime_type: Option<String>,
}

#[derive(serde::Serialize)]
#[allow(dead_code)] // reserved for non-streaming response shape
struct ChatResponse {
    reply: String,
}

/// Map agent events to SSE events. Used for both slash-command quick replies and full agent stream.
fn agent_event_stream(
    rx: stream_events::EventReceiver,
) -> impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>> {
    UnboundedReceiverStream::new(rx).map(|ev: AgentEvent| {
        let event_type = ev.event_type().to_string();
        let data = serde_json::to_string(&ev).unwrap_or_else(|_| "{}".to_string());
        Ok(Event::default().event(event_type).data(data))
    })
}

fn check_auth(headers: &HeaderMap) -> bool {
    let required = match std::env::var("CHUMP_WEB_TOKEN") {
        Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => return true,
    };
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| t.trim() == required)
        .unwrap_or(false)
}

fn pwa_static_dir() -> PathBuf {
    std::env::var("CHUMP_WEB_STATIC_DIR")
        .ok()
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| repo_path::runtime_base().join("web"))
}

async fn handle_health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "service": "chump-web"
    }))
}

/// Redirect /favicon.ico to the PWA icon so browsers stop 404ing.
async fn handle_favicon() -> Redirect {
    Redirect::to("/icon.svg")
}

/// GET /api/cascade-status — per-slot stats for the provider cascade (name, calls_today, rpd_limit, calls_this_minute, rpm_limit, circuit_state).
async fn handle_cascade_status() -> Result<Json<serde_json::Value>, StatusCode> {
    let cascade = match provider_cascade::cascade_for_status() {
        Some(c) => c,
        None => {
            // No cascade built yet in this process; build from env for config-only response (counters 0).
            let c = provider_cascade::ProviderCascade::from_env();
            if c.slots.is_empty() {
                return Ok(Json(serde_json::json!({ "slots": [], "enabled": false })));
            }
            let budget = provider_cascade::cascade_budget_remaining();
            let remaining_map_none: std::collections::HashMap<String, u32> = budget
                .as_ref()
                .map(|(_, per)| per.iter().cloned().collect())
                .unwrap_or_default();
            let total_remaining_rpd_none = budget.map(|(t, _)| t).unwrap_or(0);
            let slots: Vec<serde_json::Value> = c
                .slots
                .iter()
                .map(|s| {
                    let quality_full = crate::provider_quality::get_quality_full(&s.name);
                    let remaining_rpd = remaining_map_none.get(&s.name).copied();
                    serde_json::json!({
                        "name": s.name,
                        "calls_today": s.calls_today.load(std::sync::atomic::Ordering::Relaxed),
                        "rpd_limit": s.rpd_limit,
                        "remaining_rpd": remaining_rpd,
                        "calls_this_minute": s.calls_this_minute.load(std::sync::atomic::Ordering::Relaxed),
                        "rpm_limit": s.rpm_limit,
                        "circuit_state": local_openai::model_circuit_state(&s.base_url),
                        "success_count": quality_full.map(|q| q.0).unwrap_or(0),
                        "sanity_fail_count": quality_full.map(|q| q.1).unwrap_or(0),
                        "latency_ms_p50": quality_full.and_then(|q| q.2),
                        "latency_ms_p95": quality_full.and_then(|q| q.3),
                        "tool_call_accuracy": quality_full.and_then(|q| q.4),
                    })
                })
                .collect();
            let provider_summary = crate::cost_tracker::provider_daily_summary();
            return Ok(Json(serde_json::json!({
                "slots": slots,
                "enabled": true,
                "provider_summary": provider_summary,
                "total_remaining_rpd": total_remaining_rpd_none
            })));
        }
    };
    let budget = provider_cascade::cascade_budget_remaining();
    let remaining_map: std::collections::HashMap<String, u32> = budget
        .as_ref()
        .map(|(_, per)| per.iter().cloned().collect())
        .unwrap_or_default();
    let total_remaining_rpd = budget.map(|(t, _)| t).unwrap_or(0);

    let slots: Vec<serde_json::Value> = cascade
        .slots
        .iter()
        .map(|s| {
            let quality_full = crate::provider_quality::get_quality_full(&s.name);
            let remaining_rpd = remaining_map.get(&s.name).copied();
            serde_json::json!({
                "name": s.name,
                "calls_today": s.calls_today.load(std::sync::atomic::Ordering::Relaxed),
                "rpd_limit": s.rpd_limit,
                "remaining_rpd": remaining_rpd,
                "calls_this_minute": s.calls_this_minute.load(std::sync::atomic::Ordering::Relaxed),
                "rpm_limit": s.rpm_limit,
                "circuit_state": local_openai::model_circuit_state(&s.base_url),
                "success_count": quality_full.map(|q| q.0).unwrap_or(0),
                "sanity_fail_count": quality_full.map(|q| q.1).unwrap_or(0),
                "latency_ms_p50": quality_full.and_then(|q| q.2),
                "latency_ms_p95": quality_full.and_then(|q| q.3),
                "tool_call_accuracy": quality_full.and_then(|q| q.4),
            })
        })
        .collect();
    let provider_summary = crate::cost_tracker::provider_daily_summary();
    Ok(Json(serde_json::json!({
        "slots": slots,
        "enabled": true,
        "provider_summary": provider_summary,
        "total_remaining_rpd": total_remaining_rpd
    })))
}

#[derive(serde::Deserialize)]
struct ApproveRequest {
    request_id: String,
    allowed: bool,
}

/// Resolve a pending tool approval. Called by the web client when the user clicks Allow/Deny on a tool_approval_request event.
async fn handle_approve(
    headers: HeaderMap,
    Json(body): Json<ApproveRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    approval_resolver::resolve_approval(body.request_id.trim(), body.allowed);
    Ok(Json(serde_json::json!({ "ok": true })))
}

#[derive(serde::Deserialize)]
struct SessionsListQuery {
    #[serde(default)]
    bot: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    offset: Option<u32>,
}

async fn handle_sessions_create(
    headers: HeaderMap,
    body: Option<Json<SessionCreateBody>>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let bot = body
        .as_ref()
        .and_then(|b| b.bot.as_deref())
        .unwrap_or("chump");
    let session_id =
        web_sessions_db::session_create(bot).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(serde_json::json!({ "session_id": session_id })))
}

async fn handle_sessions_list(
    headers: HeaderMap,
    Query(q): Query<SessionsListQuery>,
) -> Result<Json<Vec<web_sessions_db::WebSessionSummary>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let bot = q.bot.as_deref().unwrap_or("chump");
    let limit = q.limit.unwrap_or(50);
    let offset = q.offset.unwrap_or(0);
    let list = web_sessions_db::session_list(bot, limit, offset)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(list))
}

async fn handle_sessions_messages(
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Query(q): Query<SessionsListQuery>,
) -> Result<Json<Vec<web_sessions_db::WebMessage>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let limit = q.limit.unwrap_or(200);
    let offset = q.offset.unwrap_or(0);
    let list = web_sessions_db::session_get_messages(session_id.trim(), limit, offset)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(list))
}

async fn handle_sessions_delete(
    headers: HeaderMap,
    Path(session_id): Path<String>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let _ = web_sessions_db::session_delete(session_id.trim())
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let _ = web_uploads::delete_uploads_for_session(session_id.trim());
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
struct SessionRenameBody {
    title: String,
}

async fn handle_sessions_rename(
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Json(body): Json<SessionRenameBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let _ = web_sessions_db::session_rename(session_id.trim(), body.title.trim())
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

/// POST /api/upload — multipart: session_id (field), file (field, one or more). Max 10MB per file.
async fn handle_upload(
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let mut session_id: Option<String> = None;
    let mut uploaded: Vec<serde_json::Value> = Vec::new();
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|_| StatusCode::BAD_REQUEST)?
    {
        let name = field.name().unwrap_or_default().to_string();
        if name == "session_id" {
            if let Ok(s) = field.text().await {
                session_id = Some(s.trim().to_string());
            }
            continue;
        }
        if name != "file" {
            continue;
        }
        let filename = field.file_name().unwrap_or("file").to_string();
        let content_type = field.content_type().map(|c| c.to_string());
        let data = field.bytes().await.map_err(|_| StatusCode::BAD_REQUEST)?;
        let session_id_str = session_id.as_deref().unwrap_or("default");
        let sid = web_sessions_db::session_ensure(session_id_str, "chump")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        match web_uploads::save_upload(&sid, &filename, content_type.as_deref(), &data) {
            Ok((file_id, size_bytes)) => {
                uploaded.push(serde_json::json!({
                    "file_id": file_id,
                    "filename": filename,
                    "mime_type": content_type,
                    "size_bytes": size_bytes,
                    "url": "/api/files/".to_string() + &file_id
                }));
            }
            Err(e) if e.to_string().contains("too large") => {
                return Err(StatusCode::PAYLOAD_TOO_LARGE)
            }
            Err(_) => return Err(StatusCode::INTERNAL_SERVER_ERROR),
        }
    }
    if uploaded.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    Ok(Json(if uploaded.len() == 1 {
        uploaded.into_iter().next().unwrap()
    } else {
        serde_json::json!({ "uploads": uploaded })
    }))
}

/// GET /api/files/:file_id — serve uploaded file.
async fn handle_file_serve(
    headers: HeaderMap,
    Path(file_id): Path<String>,
) -> Result<axum::response::Response, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let (path, filename, mime_type) =
        web_uploads::get_upload(file_id.trim()).map_err(|_| StatusCode::NOT_FOUND)?;
    let contents = tokio::fs::read(&path)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let mime = mime_type.as_deref().unwrap_or("application/octet-stream");
    let disposition = format!("inline; filename=\"{}\"", filename.replace('"', "%22"));
    Ok(axum::response::Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", mime)
        .header("Content-Disposition", disposition)
        .body(axum::body::Body::from(contents))
        .unwrap())
}

#[derive(serde::Deserialize)]
struct TasksListQuery {
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    assignee: Option<String>,
}

async fn handle_tasks_list(
    headers: HeaderMap,
    Query(q): Query<TasksListQuery>,
) -> Result<Json<Vec<task_db::TaskRow>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let status = q.status.as_deref().filter(|s| !s.is_empty());
    let mut tasks = task_db::task_list(status).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    if let Some(ref a) = q.assignee {
        let a = a.trim().to_lowercase();
        if !a.is_empty() && a != "any" {
            tasks.retain(|t| {
                t.assignee
                    .as_ref()
                    .map(|s| s.to_lowercase())
                    .unwrap_or_else(|| "chump".into())
                    == a
            });
        }
    }
    Ok(Json(tasks))
}

#[derive(serde::Deserialize)]
struct TaskCreateBody {
    title: String,
    #[serde(default)]
    repo: Option<String>,
    #[serde(default)]
    issue_number: Option<i64>,
    #[serde(default)]
    priority: Option<i64>,
    #[serde(default)]
    assignee: Option<String>,
    #[serde(default)]
    notes: Option<String>,
}

async fn handle_tasks_create(
    headers: HeaderMap,
    Json(body): Json<TaskCreateBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let title = body.title.trim();
    if title.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let id = task_db::task_create(
        title,
        body.repo.as_deref(),
        body.issue_number,
        body.priority,
        body.assignee.as_deref(),
        body.notes.as_deref(),
    )
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(serde_json::json!({ "id": id, "title": title })))
}

#[derive(serde::Deserialize)]
struct TaskUpdateBody {
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    priority: Option<i64>,
    #[serde(default)]
    notes: Option<String>,
    #[serde(default)]
    assignee: Option<String>,
}

async fn handle_tasks_update(
    headers: HeaderMap,
    Path(id): Path<i64>,
    Json(body): Json<TaskUpdateBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if let Some(ref s) = body.status {
        let _ = task_db::task_update_status(id, s.trim(), body.notes.as_deref());
    }
    if body.notes.is_some() && body.status.is_none() {
        let _ = task_db::task_update_notes(id, body.notes.as_deref());
    }
    if let Some(p) = body.priority {
        let _ = task_db::task_update_priority(id, p);
    }
    if let Some(ref a) = body.assignee {
        let _ = task_db::task_update_assignee(id, a.trim());
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn handle_tasks_delete(
    headers: HeaderMap,
    Path(id): Path<i64>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let _ = task_db::task_abandon(id, None).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

/// Unix days (since 1970-01-01) to (year, month, day) UTC. Approximate for 1970–2100.
fn unix_days_to_ymd(days: i32) -> (i32, u32, u32) {
    let (y, m, d) = (
        days / 365,
        ((days % 365) / 31).min(11) as u32 + 1,
        ((days % 365) % 31).max(1) as u32,
    );
    (y + 1970, m, d)
}

/// GET /api/briefing — today's briefing: open tasks (by assignee), recent episodes. No cache yet.
async fn handle_briefing(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let date = {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let days = (t.as_secs() / 86400) as i32;
        let (y, m, d) = unix_days_to_ymd(days);
        format!("{:04}-{:02}-{:02}", y, m, d)
    };
    let mut sections: Vec<serde_json::Value> = Vec::new();

    if let Ok(tasks) = task_db::task_list(None) {
        let open: Vec<_> = tasks
            .into_iter()
            .filter(|t| !["done", "abandoned"].contains(&t.status.as_str()))
            .collect();
        if !open.is_empty() {
            let by_assignee: std::collections::HashMap<String, Vec<_>> = open.into_iter().fold(
                std::collections::HashMap::new(),
                |mut m, t| {
                    let a = t.assignee.clone().unwrap_or_else(|| "chump".into());
                    m.entry(a).or_default().push(serde_json::json!({ "id": t.id, "title": t.title, "status": t.status, "priority": t.priority }));
                    m
                },
            );
            let items: Vec<_> = by_assignee
                .into_iter()
                .map(|(assignee, list)| serde_json::json!({ "assignee": assignee, "tasks": list }))
                .collect();
            sections.push(serde_json::json!({ "title": "Tasks", "content": "Open tasks by assignee.", "items": items }));
        }
    }

    if episode_db::episode_available() {
        if let Ok(episodes) = episode_db::episode_recent(None, 15) {
            if !episodes.is_empty() {
                let items: Vec<_> = episodes
                    .into_iter()
                    .map(|e| serde_json::json!({ "id": e.id, "summary": e.summary, "happened_at": e.happened_at, "sentiment": e.sentiment }))
                    .collect();
                sections.push(serde_json::json!({ "title": "Recent episodes", "content": "Last 15 episodes.", "items": items }));
            }
        }
    }

    if let Ok(watch_counts) = web_brain::watch_list() {
        if !watch_counts.is_empty() {
            let items: Vec<_> = watch_counts
                .into_iter()
                .map(|(name, count)| serde_json::json!({ "list": name, "count": count }))
                .collect();
            sections.push(serde_json::json!({
                "title": "Watchlists",
                "content": "Item counts under brain/watch/*.md (see /api/watch/alerts for flagged lines).",
                "items": items
            }));
        }
    }

    if let Ok(flagged) = web_brain::watch_flagged_items() {
        if !flagged.is_empty() {
            let items: Vec<_> = flagged
                .into_iter()
                .map(|i| serde_json::json!({ "list": i.list, "line": i.line }))
                .collect();
            sections.push(serde_json::json!({
                "title": "Watch alerts",
                "content": "Lines matching urgent / deadline / [!] / asap / alert: (see docs/WEB_API_REFERENCE.md).",
                "items": items
            }));
        }
    }

    Ok(Json(
        serde_json::json!({ "date": date, "sections": sections }),
    ))
}

// --- Dashboard (ship status, log tail, chassis progress) ---
async fn handle_dashboard(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let base = repo_path::runtime_base();
    let ship_log_path = base.join("logs/heartbeat-ship.log");

    let ship_running = std::process::Command::new("pgrep")
        .args(["-f", "heartbeat-ship"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    let ship_log_content = std::fs::read_to_string(&ship_log_path).unwrap_or_default();
    let ship_lines: Vec<&str> = ship_log_content.lines().collect();
    let start = ship_lines.len().saturating_sub(40);
    let ship_log_tail = ship_lines[start..].join("\n");

    // Parse last round from log: "[timestamp] Round N (type) starting" or "Round N (type) status"
    let mut ship_summary: Option<serde_json::Value> = None;
    for line in ship_lines.iter().rev() {
        let line = line.trim();
        let round_pos = match line.find("Round ") {
            Some(p) => p,
            None => continue,
        };
        let rest = line[round_pos + 6..].trim_start(); // after "Round "
        let num_end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(0);
        if num_end == 0 {
            continue;
        }
        let num_str = rest[..num_end].trim();
        let rest = rest[num_end..].trim_start();
        if !rest.starts_with('(') {
            continue;
        }
        let paren_idx = match rest.find(')') {
            Some(i) => i,
            None => continue,
        };
        let round_type = rest[1..paren_idx].trim();
        let after_paren = rest[paren_idx + 1..].trim();
        let status = if after_paren == "starting" {
            "in progress"
        } else if after_paren.starts_with("done") || after_paren.starts_with("completed") {
            "done"
        } else if after_paren.starts_with("failed") {
            "failed"
        } else if after_paren.starts_with("retry") {
            "retry"
        } else {
            after_paren
        };
        ship_summary = Some(serde_json::json!({
            "round": num_str,
            "round_type": round_type,
            "status": status,
            "description": format!("Round {} ({}) — {}", num_str, round_type, status)
        }));
        break;
    }

    let brain_root =
        std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let brain_root_path = if std::path::Path::new(&brain_root).is_absolute() {
        PathBuf::from(brain_root)
    } else {
        base.join(brain_root)
    };
    // Active portfolio: read portfolio.md, extract all active projects (name/repo/phase/blocked).
    let portfolio_path = brain_root_path.join("portfolio.md");
    let portfolio_projects: Vec<serde_json::Value> = {
        let text = std::fs::read_to_string(&portfolio_path).unwrap_or_default();
        let mut projects: Vec<serde_json::Value> = Vec::new();
        let mut cur_name: Option<String> = None;
        let mut cur_repo: Option<String> = None;
        let mut cur_phase: Option<String> = None;
        let mut cur_blocked = false;
        let mut cur_priority: u32 = 99;
        let flush = |projects: &mut Vec<serde_json::Value>,
                     name: Option<String>,
                     repo: Option<String>,
                     phase: Option<String>,
                     blocked: bool,
                     priority: u32| {
            if let Some(n) = name {
                projects.push(serde_json::json!({ "name": n, "repo": repo, "phase": phase, "blocked": blocked, "priority": priority }));
            }
        };
        for line in text.lines() {
            let t = line.trim();
            if t.starts_with("## ")
                && !t.contains("Active Portfolio")
                && !t.contains("Parked")
                && !t.contains("Killed")
            {
                flush(
                    &mut projects,
                    cur_name.take(),
                    cur_repo.take(),
                    cur_phase.take(),
                    cur_blocked,
                    cur_priority,
                );
                cur_blocked = false;
                cur_priority = t
                    .trim_start_matches('#')
                    .trim()
                    .splitn(2, '.')
                    .next()
                    .and_then(|n| n.trim().parse::<u32>().ok())
                    .unwrap_or(99);
                cur_name = t
                    .trim_start_matches('#')
                    .trim()
                    .splitn(2, '.')
                    .nth(1)
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty() && cur_priority < 90);
            }
            if cur_name.is_some() {
                if t.starts_with("- **Repo:**") {
                    let r = t.split("**Repo:**").nth(1).unwrap_or("").trim();
                    if !r.is_empty() && !r.starts_with('(') {
                        cur_repo = Some(r.to_string());
                    }
                }
                if t.starts_with("- **Phase:**") {
                    cur_phase = t.split("**Phase:**").nth(1).map(|s| s.trim().to_string());
                }
                if t.contains("**Blocked:** Yes") {
                    cur_blocked = true;
                }
            }
        }
        flush(
            &mut projects,
            cur_name,
            cur_repo,
            cur_phase,
            cur_blocked,
            cur_priority,
        );
        projects
    };

    // The active target = highest-priority non-blocked project (what ship rounds are pointed at).
    let active_portfolio: Option<&serde_json::Value> = portfolio_projects
        .iter()
        .filter(|p| !p.get("blocked").and_then(|v| v.as_bool()).unwrap_or(false))
        .min_by_key(|p| p.get("priority").and_then(|v| v.as_u64()).unwrap_or(99));

    // Last active repo from chump.log: only count if touched within 1 hour.
    let chump_log_path = base.join("logs/chump.log");
    let now_secs_for_repo = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let one_hour_ago = now_secs_for_repo.saturating_sub(3600);
    let last_active_repo: Option<String> =
        std::fs::read_to_string(&chump_log_path).ok().and_then(|s| {
            let lines: Vec<&str> = s.lines().collect();
            let start = lines.len().saturating_sub(500);
            lines[start..].iter().rev().find_map(|line| {
                // Only consider write_file/edit_file/cli lines.
                if !line.contains("write_file")
                    && !line.contains("edit_file")
                    && !line.contains("| cli |")
                {
                    return None;
                }
                // Check timestamp (first field before first |).
                let ts: u64 = line
                    .splitn(2, '|')
                    .next()?
                    .trim()
                    .split('.')
                    .next()?
                    .parse()
                    .ok()?;
                if ts < one_hour_ago {
                    return None;
                }
                // Extract repos/ path.
                let repos_pos = line.find("/repos/")?;
                let after = &line[repos_pos + 7..];
                let parts: Vec<&str> = after.splitn(4, '/').collect();
                if parts.is_empty() || parts[0].is_empty() {
                    return None;
                }
                let name = if parts.len() >= 2 && !parts[1].is_empty() && !parts[1].contains('.') {
                    format!("{}/{}", parts[0], parts[1])
                } else {
                    parts[0].to_string()
                };
                Some(name)
            })
        });

    let current_repo: Option<String> = active_portfolio
        .and_then(|p| p.get("repo")?.as_str().map(|s| s.to_string()))
        .or(last_active_repo.clone());

    let current_step: Option<String> = current_repo.clone();

    // Last 5 episodes (summary, detail, happened_at) so the UI can show "what Chump just did".
    // If episodes are absent or all older than 24h, synthesize from the ship log so "Recent" always shows activity.
    let db_episodes: Vec<serde_json::Value> = episode_db::episode_recent(None, 5)
        .unwrap_or_default()
        .into_iter()
        .map(|e| {
            serde_json::json!({
                "summary": e.summary,
                "detail": e.detail,
                "happened_at": e.happened_at,
                "repo": e.repo
            })
        })
        .collect();

    let cutoff_secs: u64 = 86_400; // 24h
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let episodes_are_fresh = db_episodes
        .first()
        .and_then(|e| {
            e.get("happened_at")?
                .as_str()
                .and_then(|ts| ts.split('.').next()?.parse::<u64>().ok())
        })
        .map(|ts| now_secs.saturating_sub(ts) < cutoff_secs)
        .unwrap_or(false);

    // Parse recent completed rounds from ship log as fallback.
    let log_episodes: Vec<serde_json::Value> = if !episodes_are_fresh {
        let round_labels = std::collections::HashMap::from([
            ("ship", "Shipped — portfolio step"),
            ("review", "Review — CI, tasks, playbook"),
            ("research", "Research — market/tech"),
            ("maintain", "Maintain — battle QA, Chump"),
        ]);
        ship_lines
            .iter()
            .rev()
            .filter(|l| {
                let t = l.trim();
                t.contains("Round") && (t.ends_with(") ok") || t.contains(") ok"))
            })
            .take(5)
            .map(|l| {
                // "[timestamp] Round N (type) ok" → extract type
                let round_type = l
                    .find('(')
                    .and_then(|s| l[s + 1..].find(')').map(|e| l[s + 1..s + 1 + e].trim()))
                    .unwrap_or("round");
                let label = round_labels.get(round_type).copied().unwrap_or(round_type);
                let ts_str = l
                    .trim_start_matches('[')
                    .split(']')
                    .next()
                    .unwrap_or("")
                    .trim();
                serde_json::json!({
                    "summary": label,
                    "happened_at": ts_str,
                    "repo": null
                })
            })
            .collect()
    } else {
        vec![]
    };

    let last_episodes: Vec<serde_json::Value> = if episodes_are_fresh {
        db_episodes
    } else if !log_episodes.is_empty() {
        log_episodes
    } else {
        db_episodes
    };

    let timestamp_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    Ok(Json(serde_json::json!({
        "ship_running": ship_running,
        "ship_summary": ship_summary,
        "ship_log_tail": ship_log_tail,
        "current_repo": current_repo,
        "last_active_repo": last_active_repo,
        "active_portfolio": active_portfolio,
        "portfolio_projects": portfolio_projects,
        "current_step": current_step,
        "last_episodes": last_episodes,
        "timestamp_secs": timestamp_secs
    })))
}

// --- Autopilot control API ---
async fn handle_autopilot_status(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    autopilot::status_autopilot()
        .map(Json)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

async fn handle_autopilot_start(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    match autopilot::start_autopilot() {
        Ok(state) => Ok(Json(serde_json::json!({
            "ok": true,
            "state": state,
            "message": "Autopilot started"
        }))),
        Err(e) => Ok(Json(serde_json::json!({
            "ok": false,
            "error": e.to_string()
        }))),
    }
}

async fn handle_autopilot_stop(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    match autopilot::stop_autopilot() {
        Ok(state) => Ok(Json(serde_json::json!({
            "ok": true,
            "state": state,
            "message": "Autopilot stopped"
        }))),
        Err(e) => Ok(Json(serde_json::json!({
            "ok": false,
            "error": e.to_string()
        }))),
    }
}

// --- Ingest (Phase 2.2) ---
#[derive(serde::Deserialize)]
struct IngestBody {
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    url: Option<String>,
    /// Optional label (e.g. `ios_shortcut`, `pwa`) stored as `<!-- capture_source: … -->` in the file.
    #[serde(default)]
    source: Option<String>,
}

async fn handle_ingest_json(
    headers: HeaderMap,
    Json(b): Json<IngestBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let src = b.source.as_deref().map(str::trim).filter(|s| !s.is_empty());
    if let Some(ref text) = b.text {
        let content = text.trim();
        if !content.is_empty() {
            let (rel, summary) =
                web_brain::ingest_write_stamped(content.as_bytes(), "md", "Note", src).map_err(
                    |e| {
                        if e.to_string().contains("exceeds") {
                            StatusCode::PAYLOAD_TOO_LARGE
                        } else {
                            StatusCode::INTERNAL_SERVER_ERROR
                        }
                    },
                )?;
            let capture_id = rel
                .trim_end_matches(".md")
                .rsplit('/')
                .next()
                .unwrap_or(&rel)
                .to_string();
            return Ok(Json(serde_json::json!({
                "capture_id": capture_id,
                "filename": rel.rsplit('/').next().unwrap_or("capture.md"),
                "summary": summary,
                "brain_path": rel
            })));
        }
    }
    if let Some(ref url) = b.url {
        let u = url.trim();
        if !u.is_empty() {
            let content = format!("URL: {}\n\n", u);
            let (rel, summary) =
                web_brain::ingest_write_stamped(content.as_bytes(), "md", "URL", src).map_err(
                    |e| {
                        if e.to_string().contains("exceeds") {
                            StatusCode::PAYLOAD_TOO_LARGE
                        } else {
                            StatusCode::INTERNAL_SERVER_ERROR
                        }
                    },
                )?;
            let capture_id = rel
                .trim_end_matches(".md")
                .rsplit('/')
                .next()
                .unwrap_or(&rel)
                .to_string();
            return Ok(Json(serde_json::json!({
                "capture_id": capture_id,
                "filename": rel.rsplit('/').next().unwrap_or("capture.md"),
                "summary": summary,
                "brain_path": rel
            })));
        }
    }
    Err(StatusCode::BAD_REQUEST)
}

async fn handle_ingest_upload(
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|_| StatusCode::BAD_REQUEST)?
    {
        let name = field.name().unwrap_or_default().to_string();
        if name != "file" && name != "text" {
            continue;
        }
        let filename = field.file_name().unwrap_or("paste").to_string();
        let data = field.bytes().await.map_err(|_| StatusCode::BAD_REQUEST)?;
        if data.len() > web_brain::MAX_INGEST_BYTES {
            return Err(StatusCode::PAYLOAD_TOO_LARGE);
        }
        let ext = if filename.ends_with(".md") {
            "md"
        } else if filename.contains('.') {
            filename.rsplit('.').next().unwrap_or("md")
        } else {
            "md"
        };
        let (rel, summary) = web_brain::ingest_write(&data, ext, "File")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let capture_id = rel
            .trim_end_matches(".md")
            .rsplit('/')
            .next()
            .unwrap_or(&rel)
            .to_string();
        return Ok(Json(serde_json::json!({
            "capture_id": capture_id,
            "filename": filename,
            "summary": summary,
            "brain_path": rel
        })));
    }
    Err(StatusCode::BAD_REQUEST)
}

// --- Research (Phase 2.4) ---
#[derive(serde::Deserialize)]
struct ResearchCreateBody {
    topic: String,
    #[serde(default)]
    content: Option<String>,
}

async fn handle_research_list(
    headers: HeaderMap,
) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let list = web_brain::research_list().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let out: Vec<_> = list
        .into_iter()
        .map(|(id, topic, path)| serde_json::json!({ "id": id, "topic": topic, "path": path }))
        .collect();
    Ok(Json(out))
}

async fn handle_research_create(
    headers: HeaderMap,
    Json(body): Json<ResearchCreateBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let topic = body.topic.trim();
    if topic.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let content = body.content.as_deref().unwrap_or("");
    let path = web_brain::research_create(topic, content)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let id = path
        .trim_end_matches(".md")
        .rsplit('/')
        .next()
        .unwrap_or("brief")
        .to_string();
    Ok(Json(
        serde_json::json!({ "id": id, "topic": topic, "path": path }),
    ))
}

async fn handle_research_get(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let content = web_brain::research_get(id.trim()).map_err(|_| StatusCode::NOT_FOUND)?;
    Ok(Json(serde_json::json!({ "content": content })))
}

// --- Watch (Phase 2.5) ---
async fn handle_watch_list(headers: HeaderMap) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let list = web_brain::watch_list().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let out: Vec<_> = list
        .into_iter()
        .map(|(name, count)| serde_json::json!({ "list": name, "count": count }))
        .collect();
    Ok(Json(out))
}

#[derive(serde::Deserialize)]
struct WatchAddBody {
    list: String,
    item: String,
}

async fn handle_watch_add(
    headers: HeaderMap,
    Json(body): Json<WatchAddBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let list = body.list.trim();
    if list.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    web_brain::watch_add(list, body.item.trim()).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn handle_watch_delete(
    headers: HeaderMap,
    Path((list, item_id)): Path<(String, String)>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let index: usize = item_id.parse().map_err(|_| StatusCode::BAD_REQUEST)?;
    web_brain::watch_remove(list.trim(), index).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn handle_watch_alerts(
    headers: HeaderMap,
) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let items = web_brain::watch_flagged_items().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let out: Vec<_> = items
        .into_iter()
        .map(|i| serde_json::json!({ "list": i.list, "line": i.line }))
        .collect();
    Ok(Json(out))
}

// --- Projects (Phase 2.6) ---
async fn handle_projects_list(
    headers: HeaderMap,
) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let list = web_brain::projects_list().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let out: Vec<_> = list
        .into_iter()
        .map(|(id, name, path)| serde_json::json!({ "id": id, "name": name, "path": path }))
        .collect();
    Ok(Json(out))
}

#[derive(serde::Deserialize)]
struct ProjectAddBody {
    name: String,
    #[serde(default)]
    repo_path: Option<String>,
    #[serde(default)]
    description: Option<String>,
}

async fn handle_projects_create(
    headers: HeaderMap,
    Json(body): Json<ProjectAddBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let name = body.name.trim();
    if name.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let path = web_brain::project_add(
        name,
        body.repo_path.as_deref().unwrap_or(""),
        body.description.as_deref().unwrap_or(""),
    )
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let id = path
        .trim_end_matches(".md")
        .rsplit('/')
        .next()
        .unwrap_or("project")
        .to_string();
    Ok(Json(
        serde_json::json!({ "id": id, "name": name, "path": path }),
    ))
}

async fn handle_projects_activate(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    web_brain::project_activate(id.trim()).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

// --- Push (Phase 3.1, minimal: store subscriptions, no send yet) ---
async fn handle_push_vapid_public_key(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let key = std::env::var("CHUMP_VAPID_PUBLIC_KEY")
        .unwrap_or_else(|_| "BEl62iUYgUivxIkv69yViEuiBIa-Ib27-SVMrSGYoiU".to_string());
    Ok(Json(serde_json::json!({ "vapid_public_key": key })))
}

#[derive(serde::Deserialize)]
struct PushSubscribeBody {
    endpoint: String,
    #[serde(default)]
    keys: Option<PushKeys>,
}

#[derive(serde::Deserialize)]
struct PushKeys {
    p256dh: Option<String>,
    auth: Option<String>,
}

async fn handle_push_subscribe(
    headers: HeaderMap,
    Json(body): Json<PushSubscribeBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let endpoint = body.endpoint.trim();
    if endpoint.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let (p256dh, auth) = body
        .keys
        .as_ref()
        .map(|k| {
            (
                k.p256dh.as_deref().unwrap_or(""),
                k.auth.as_deref().unwrap_or(""),
            )
        })
        .unwrap_or(("", ""));
    let conn = db_pool::get().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    conn.execute(
        "INSERT OR REPLACE INTO chump_push_subscriptions (endpoint, p256dh, auth) VALUES (?1, ?2, ?3)",
        rusqlite::params![endpoint, p256dh, auth],
    )
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
struct PushUnsubscribeBody {
    endpoint: String,
}

async fn handle_push_unsubscribe(
    headers: HeaderMap,
    Json(body): Json<PushUnsubscribeBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let endpoint = body.endpoint.trim();
    let conn = db_pool::get().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let _ = conn.execute(
        "DELETE FROM chump_push_subscriptions WHERE endpoint = ?1",
        rusqlite::params![endpoint],
    );
    Ok(StatusCode::NO_CONTENT)
}

// --- iOS Shortcuts (Phase 5) ---
#[derive(serde::Deserialize)]
struct ShortcutTaskBody {
    title: String,
}

async fn handle_shortcut_task(
    headers: HeaderMap,
    Json(body): Json<ShortcutTaskBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let title = body.title.trim();
    if title.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let id = task_db::task_create(title, None, None, None, None, None)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(serde_json::json!({ "id": id, "title": title })))
}

#[derive(serde::Deserialize)]
struct ShortcutCaptureBody {
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    source: Option<String>,
}

async fn handle_shortcut_capture(
    headers: HeaderMap,
    Json(body): Json<ShortcutCaptureBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let text = body.text.as_deref().unwrap_or("").trim();
    if text.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let src = body
        .source
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .or(Some("ios_shortcut"));
    let (_, summary) = web_brain::ingest_write_stamped(text.as_bytes(), "md", "Shortcut", src)
        .map_err(|e| {
            if e.to_string().contains("exceeds") {
                StatusCode::PAYLOAD_TOO_LARGE
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            }
        })?;
    Ok(Json(serde_json::json!({ "summary": summary })))
}

async fn handle_shortcut_status(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let open_count = task_db::task_list(Some("open"))
        .map(|v| v.len())
        .unwrap_or(0);
    let in_progress = task_db::task_list(Some("in_progress"))
        .map(|v| v.len())
        .unwrap_or(0);
    let line = format!(
        "Chump online. {} open, {} in progress.",
        open_count, in_progress
    );
    Ok(Json(serde_json::json!({ "status": line })))
}

#[derive(serde::Deserialize)]
struct ShortcutCommandBody {
    command: String,
}

async fn handle_shortcut_command(
    headers: HeaderMap,
    Json(body): Json<ShortcutCommandBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let cmd = body.command.trim().to_lowercase();
    let result = match cmd.as_str() {
        "status" => {
            let open_count = task_db::task_list(Some("open"))
                .map(|v| v.len())
                .unwrap_or(0);
            format!("{} open tasks.", open_count)
        }
        "deploy" | "test" | "reboot" => format!(
            "Command \"{}\" acknowledged. Run via chat for full execution.",
            cmd
        ),
        _ => format!(
            "Unknown command: \"{}\". Use status, deploy, test, or reboot.",
            cmd
        ),
    };
    Ok(Json(serde_json::json!({ "result": result })))
}

async fn handle_chat(
    headers: HeaderMap,
    Json(body): Json<ChatRequest>,
) -> Result<
    Sse<impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>>>,
    StatusCode,
> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let message = body.message.trim().to_string();
    if message.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    if limits::check_message_len(&message).is_err() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let raw_session_id = body.session_id.as_deref().unwrap_or("default").trim();
    let session_id = web_sessions_db::session_ensure(raw_session_id, "chump")
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let attachments_json = body
        .attachments
        .as_ref()
        .and_then(|a| serde_json::to_string(a).ok());
    let mut message_for_agent = message.clone();
    if let Some(ref atts) = body.attachments {
        if !atts.is_empty() {
            let mut parts = Vec::<String>::new();
            for a in atts {
                match web_uploads::read_upload_as_text(a.file_id.trim()) {
                    Ok(Some(text)) => parts.push(format!("[Attachment: {}]\n{}", a.filename, text)),
                    _ => parts.push(format!("[User attached file: {}]", a.filename)),
                }
            }
            message_for_agent = format!("{}\n\n{}", parts.join("\n\n"), message_for_agent);
        }
    }
    if let Err(e) =
        web_sessions_db::message_append_user(&session_id, &message, attachments_json.as_deref())
    {
        eprintln!("[web] failed to persist user message: {}", e);
    }

    // Belt-and-suspenders: if user typed /task, /research, or /watch raw, handle server-side and return quick reply (no agent).
    if body.attachments.is_none()
        || body
            .attachments
            .as_ref()
            .map(|a| a.is_empty())
            .unwrap_or(true)
    {
        let quick_reply = if let Some(title) = message.strip_prefix("/task ").map(|s| s.trim()) {
            if title.is_empty() {
                None
            } else {
                task_db::task_create(title, None, None, None, None, None)
                    .ok()
                    .map(|id| format!("Created task #{}: {}", id, title))
            }
        } else if let Some(topic) = message.strip_prefix("/research ").map(|s| s.trim()) {
            if topic.is_empty() {
                None
            } else {
                web_brain::research_create(topic, "")
                    .ok()
                    .map(|_| format!("Research brief queued: {}", topic))
            }
        } else if let Some(rest) = message.strip_prefix("/watch ").map(|s| s.trim()) {
            if rest.is_empty() {
                None
            } else {
                let (list, item) = if let Some((first, tail)) = rest.split_once(char::is_whitespace)
                {
                    (first.trim(), tail.trim())
                } else {
                    ("default", rest)
                };
                if item.is_empty() {
                    None
                } else {
                    web_brain::watch_add(list, item)
                        .ok()
                        .map(|_| format!("Added to watchlist \"{}\": {}", list, item))
                }
            }
        } else {
            None
        };
        if let Some(reply) = quick_reply {
            let _ = web_sessions_db::message_append_assistant(&session_id, &reply, None);
            let (event_tx, event_rx) = stream_events::event_channel();
            let _ = event_tx.send(stream_events::AgentEvent::WebSessionReady {
                session_id: session_id.clone(),
            });
            let _ = event_tx.send(stream_events::AgentEvent::TextComplete {
                text: reply.clone(),
            });
            let _ = event_tx.send(stream_events::AgentEvent::TurnComplete {
                request_id: uuid::Uuid::new_v4().to_string(),
                full_text: reply,
                duration_ms: 0,
                tool_calls_count: 0,
                model_calls_count: 0,
            });
            drop(event_tx);
            return Ok(Sse::new(agent_event_stream(event_rx)));
        }
    }

    let (event_tx, event_rx) = stream_events::event_channel();
    let _ = event_tx.send(stream_events::AgentEvent::WebSessionReady {
        session_id: session_id.clone(),
    });
    let bot = body.bot.as_deref();
    let (provider, registry, session_manager, system_prompt) =
        discord::build_chump_agent_web_components(&session_id, bot)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let streaming_provider = StreamingProvider::new(provider, event_tx.clone());
    let event_tx_err = event_tx.clone(); // retained for error reporting after agent consumes event_tx
    let max_iterations: usize = std::env::var("CHUMP_MAX_ITERATIONS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(25)
        .clamp(1, 50);
    let agent = ChumpAgent::new(
        Box::new(streaming_provider),
        registry,
        Some(system_prompt),
        Some(session_manager),
        Some(event_tx),
        max_iterations,
    );

    let message_clone = message_for_agent;
    let session_id_clone = session_id.clone();
    tokio::spawn(async move {
        match agent.run(&message_clone).await {
            Ok(full_reply) => {
                let stripped = crate::discord::strip_thinking(&full_reply);
                crate::context_assembly::record_last_reply(&stripped);
                if let Err(e) =
                    web_sessions_db::message_append_assistant(&session_id_clone, &full_reply, None)
                {
                    eprintln!("[web] failed to persist assistant message: {}", e);
                }
            }
            Err(e) => {
                eprintln!("[web] chat run failed: {}", e);
                // Send turn_error so the PWA shows the error instead of "(No response)".
                let mut msg = format!("Agent error: {}", e);
                if msg.contains("401") || msg.to_lowercase().contains("models permission") {
                    msg.push_str(" Check your API key has the required scope (e.g. models). Run ./scripts/check-providers.sh from the Chump repo to see which provider returns 401.");
                }
                let _ = event_tx_err.send(stream_events::AgentEvent::TurnError {
                    request_id: String::new(),
                    error: msg,
                });
            }
        }
    });

    Ok(Sse::new(agent_event_stream(event_rx)))
}

/// Start the web server. Binds to 0.0.0.0:port. Serves GET /api/health and static files from web/.
pub async fn start_web_server(port: u16) -> Result<()> {
    let static_dir = pwa_static_dir();
    if let Err(e) = std::fs::create_dir_all(&static_dir) {
        eprintln!(
            "[web] warning: could not create static dir {:?}: {}",
            static_dir, e
        );
    }

    let api = Router::new()
        .route("/favicon.ico", get(handle_favicon))
        .route("/api/health", get(handle_health))
        .route("/api/cascade-status", get(handle_cascade_status))
        .route("/api/chat", post(handle_chat))
        .route("/api/approve", post(handle_approve))
        .route(
            "/api/sessions",
            get(handle_sessions_list).post(handle_sessions_create),
        )
        .route("/api/sessions/{id}/messages", get(handle_sessions_messages))
        .route(
            "/api/sessions/{id}",
            put(handle_sessions_rename).delete(handle_sessions_delete),
        )
        .route(
            "/api/upload",
            post(handle_upload).layer(RequestBodyLimitLayer::new(11 * 1024 * 1024)),
        )
        .route("/api/files/{file_id}", get(handle_file_serve))
        .route(
            "/api/tasks",
            get(handle_tasks_list).post(handle_tasks_create),
        )
        .route(
            "/api/tasks/{id}",
            put(handle_tasks_update).delete(handle_tasks_delete),
        )
        .route("/api/briefing", get(handle_briefing))
        .route("/api/dashboard", get(handle_dashboard))
        .route("/api/autopilot/status", get(handle_autopilot_status))
        .route("/api/autopilot/start", post(handle_autopilot_start))
        .route("/api/autopilot/stop", post(handle_autopilot_stop))
        .route(
            "/api/ingest",
            post(handle_ingest_json).layer(RequestBodyLimitLayer::new(
                web_brain::MAX_INGEST_BYTES + 65536,
            )),
        )
        .route(
            "/api/ingest/upload",
            post(handle_ingest_upload).layer(RequestBodyLimitLayer::new(11 * 1024 * 1024)),
        )
        .route(
            "/api/research",
            get(handle_research_list).post(handle_research_create),
        )
        .route("/api/research/{id}", get(handle_research_get))
        .route("/api/watch", get(handle_watch_list).post(handle_watch_add))
        .route("/api/watch/alerts", get(handle_watch_alerts))
        .route("/api/watch/{list}/{item_id}", delete(handle_watch_delete))
        .route(
            "/api/projects",
            get(handle_projects_list).post(handle_projects_create),
        )
        .route(
            "/api/projects/{id}/activate",
            post(handle_projects_activate),
        )
        .route(
            "/api/push/vapid-public-key",
            get(handle_push_vapid_public_key),
        )
        .route("/api/push/subscribe", post(handle_push_subscribe))
        .route("/api/push/unsubscribe", post(handle_push_unsubscribe))
        .route("/api/shortcut/task", post(handle_shortcut_task))
        .route(
            "/api/shortcut/capture",
            post(handle_shortcut_capture).layer(RequestBodyLimitLayer::new(
                web_brain::MAX_INGEST_BYTES + 65536,
            )),
        )
        .route("/api/shortcut/status", get(handle_shortcut_status))
        .route("/api/shortcut/command", post(handle_shortcut_command));
    let app = Router::new()
        .merge(api)
        .fallback_service(ServeDir::new(&static_dir).append_index_html_on_directories(true));

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    eprintln!("[web] Chump Web listening on http://{}", addr);
    eprintln!("[web] serving Chump PWA from {:?}", &static_dir);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    eprintln!("[web] autopilot: scheduling boot + periodic reconcile (3m interval)");

    tokio::spawn(async move {
        let res =
            tokio::task::spawn_blocking(|| autopilot::reconcile_autopilot_maybe_start()).await;
        match res {
            Ok(Ok(Some(_))) => eprintln!("[web] autopilot reconcile (boot): started ship"),
            Ok(Ok(None)) => {}
            Ok(Err(e)) => eprintln!("[web] autopilot reconcile (boot): {}", e),
            Err(e) => eprintln!("[web] autopilot reconcile (boot): join error: {}", e),
        }
    });

    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(180));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let res =
                tokio::task::spawn_blocking(|| autopilot::reconcile_autopilot_maybe_start()).await;
            match res {
                Ok(Ok(Some(_))) => eprintln!("[web] autopilot reconcile (periodic): started ship"),
                Ok(Ok(None)) => {}
                Ok(Err(e)) => eprintln!("[web] autopilot reconcile (periodic): {}", e),
                Err(e) => eprintln!("[web] autopilot reconcile (periodic): join error: {}", e),
            }
        }
    });

    axum::serve(listener, app).await?;
    Ok(())
}
