//! axum HTTP server for Chump Web: health check, chat API (SSE), static PWA files.
//! Run with `chump --web`. Sprint 2: POST /api/chat returns SSE stream.

use anyhow::Result;
use axum::{
    extract::{Multipart, Path, Query},
    http::{HeaderMap, StatusCode},
    response::sse::{Event, Sse},
    routing::{get, post, put, delete},
    Json, Router,
};
use std::path::PathBuf;
use tower_http::limit::RequestBodyLimitLayer;
use tokio_stream::wrappers::UnboundedReceiverStream;
use tokio_stream::StreamExt;
use tower_http::services::ServeDir;

use crate::agent_loop::ChumpAgent;
use crate::approval_resolver;
use crate::discord;
use crate::limits;
use crate::repo_path;
use crate::stream_events::{self, AgentEvent};
use crate::streaming_provider::StreamingProvider;
use crate::episode_db;
use crate::task_db;
use crate::web_sessions_db;
use crate::web_uploads;

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
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let bot = "chump";
    let session_id = web_sessions_db::session_create(bot).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
    let list = web_sessions_db::session_list(bot, limit, offset).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
    let _ = web_sessions_db::session_delete(session_id.trim()).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
    while let Some(field) = multipart.next_field().await.map_err(|_| StatusCode::BAD_REQUEST)? {
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
        let sid = web_sessions_db::session_ensure(session_id_str, "chump").map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
            Err(e) if e.to_string().contains("too large") => return Err(StatusCode::PAYLOAD_TOO_LARGE),
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
    let (path, filename, mime_type) = web_uploads::get_upload(file_id.trim()).map_err(|_| StatusCode::NOT_FOUND)?;
    let contents = tokio::fs::read(&path).await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
            tasks.retain(|t| t.assignee.as_ref().map(|s| s.to_lowercase()).unwrap_or_else(|| "chump".into()) == a);
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
    let (y, m, d) = (days / 365, ((days % 365) / 31).min(11) as u32 + 1, ((days % 365) % 31).max(1) as u32);
    (y + 1970, m, d)
}

/// GET /api/briefing — today's briefing: open tasks (by assignee), recent episodes. No cache yet.
async fn handle_briefing(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let date = {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        let days = (t.as_secs() / 86400) as i32;
        let (y, m, d) = unix_days_to_ymd(days);
        format!("{:04}-{:02}-{:02}", y, m, d)
    };
    let mut sections: Vec<serde_json::Value> = Vec::new();

    if let Ok(tasks) = task_db::task_list(None) {
        let open: Vec<_> = tasks.into_iter().filter(|t| !["done", "abandoned"].contains(&t.status.as_str())).collect();
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

    Ok(Json(serde_json::json!({ "date": date, "sections": sections })))
}

async fn handle_chat(
    headers: HeaderMap,
    Json(body): Json<ChatRequest>,
) -> Result<Sse<impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>>>, StatusCode> {
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

    let attachments_json = body.attachments.as_ref().and_then(|a| serde_json::to_string(a).ok());
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
    if let Err(e) = web_sessions_db::message_append_user(&session_id, &message, attachments_json.as_deref()) {
        eprintln!("[web] failed to persist user message: {}", e);
    }

    let (event_tx, event_rx) = stream_events::event_channel();
    let _ = event_tx.send(stream_events::AgentEvent::WebSessionReady {
        session_id: session_id.clone(),
    });
    let bot = body.bot.as_deref();
    let (provider, registry, session_manager, system_prompt) =
        discord::build_chump_agent_web_components(&session_id, bot).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let streaming_provider = StreamingProvider::new(provider, event_tx.clone());
    let agent = ChumpAgent::new(
        Box::new(streaming_provider),
        registry,
        Some(system_prompt),
        Some(session_manager),
        Some(event_tx),
        10,
    );

    let message_clone = message_for_agent;
    let session_id_clone = session_id.clone();
    tokio::spawn(async move {
        match agent.run(&message_clone).await {
            Ok(full_reply) => {
                if let Err(e) = web_sessions_db::message_append_assistant(&session_id_clone, &full_reply, None) {
                    eprintln!("[web] failed to persist assistant message: {}", e);
                }
            }
            Err(e) => eprintln!("[web] chat run failed: {}", e),
        }
    });

    let stream = UnboundedReceiverStream::new(event_rx).map(|ev: AgentEvent| {
        let event_type = ev.event_type().to_string();
        let data = serde_json::to_string(&ev).unwrap_or_else(|_| "{}".to_string());
        Ok(Event::default().event(event_type).data(data))
    });

    Ok(Sse::new(stream))
}

/// Start the web server. Binds to 0.0.0.0:port. Serves GET /api/health and static files from web/.
pub async fn start_web_server(port: u16) -> Result<()> {
    let static_dir = pwa_static_dir();
    if let Err(e) = std::fs::create_dir_all(&static_dir) {
        eprintln!("[web] warning: could not create static dir {:?}: {}", static_dir, e);
    }

    let api = Router::new()
        .route("/api/health", get(handle_health))
        .route("/api/chat", post(handle_chat))
        .route("/api/approve", post(handle_approve))
        .route("/api/sessions", get(handle_sessions_list).post(handle_sessions_create))
        .route("/api/sessions/:id/messages", get(handle_sessions_messages))
        .route("/api/sessions/:id", put(handle_sessions_rename).delete(handle_sessions_delete))
        .route("/api/upload", post(handle_upload).layer(RequestBodyLimitLayer::new(11 * 1024 * 1024)))
        .route("/api/files/:file_id", get(handle_file_serve))
        .route("/api/tasks", get(handle_tasks_list).post(handle_tasks_create))
        .route("/api/tasks/:id", put(handle_tasks_update).delete(handle_tasks_delete))
        .route("/api/briefing", get(handle_briefing));
    let app = Router::new()
        .merge(api)
        .fallback_service(ServeDir::new(static_dir).append_index_html_on_directories(true));

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    eprintln!("[web] Chump Web listening on http://{}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
