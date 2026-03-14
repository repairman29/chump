//! axum HTTP server for Chump Web: health check, chat API (SSE), static PWA files.
//! Run with `chump --web`. Sprint 2: POST /api/chat returns SSE stream.

use anyhow::Result;
use axum::{
    http::{HeaderMap, StatusCode},
    response::sse::{Event, Sse},
    routing::{get, post},
    Json, Router,
};
use std::path::PathBuf;
use tokio_stream::wrappers::UnboundedReceiverStream;
use tokio_stream::StreamExt;
use tower_http::services::ServeDir;

use crate::agent_loop::ChumpAgent;
use crate::discord;
use crate::limits;
use crate::repo_path;
use crate::stream_events::{self, AgentEvent};
use crate::streaming_provider::StreamingProvider;

#[derive(serde::Deserialize)]
struct ChatRequest {
    message: String,
    #[serde(default)]
    session_id: Option<String>,
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
    let session_id = body
        .session_id
        .as_deref()
        .unwrap_or("default")
        .trim()
        .to_string();

    let (event_tx, event_rx) = stream_events::event_channel();
    let (provider, registry, session_manager, system_prompt) =
        discord::build_chump_agent_web_components(&session_id).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let streaming_provider = StreamingProvider::new(provider, event_tx.clone());
    let agent = ChumpAgent::new(
        Box::new(streaming_provider),
        registry,
        Some(system_prompt),
        Some(session_manager),
        Some(event_tx),
        10,
    );

    tokio::spawn(async move {
        let _ = agent.run(&message).await;
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
    let _ = std::fs::create_dir_all(&static_dir);

    let api = Router::new()
        .route("/api/health", get(handle_health))
        .route("/api/chat", post(handle_chat));
    let app = Router::new()
        .merge(api)
        .fallback_service(ServeDir::new(static_dir).append_index_html_on_directories(true));

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    eprintln!("[web] Chump Web listening on http://{}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
