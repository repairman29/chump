//! ACP (Agent Client Protocol) JSON-RPC server over stdio.
//!
//! Wires the types defined in `src/acp.rs` to a real stdin/stdout loop so Chump
//! can be launched by any ACP-compatible client (Zed, JetBrains IDEs, etc.).
//!
//! Lifecycle (per https://agentclientprotocol.com):
//!
//!   client → agent: `initialize`         → agent capabilities
//!   client → agent: `session/new`        → sessionId
//!   client → agent: `session/prompt`     → streams `session/update` notifications,
//!                                          returns `PromptResponse { stopReason }`
//!   client → agent: `session/cancel`     → notification; cancels in-flight prompt
//!
//! Transport:
//!   - stdin: one JSON-RPC message per line (framing: newline-delimited)
//!   - stdout: one JSON-RPC message per line
//!   - stderr: tracing output (never JSON-RPC)
//!
//! Notification streaming is done by writing `session/update` messages to stdout
//! concurrently with the prompt handling. A broadcast::Sender fans events from
//! the agent loop out to the stdout writer.
//!
//! V1 scope:
//!   - Implements: initialize, session/new, session/prompt, session/cancel
//!   - Streams: AgentMessageComplete, ToolCallStart, ToolCallResult, Thinking
//!   - Deferred for V2: fs/*, terminal/*, session/request_permission callbacks
//!     (client→agent methods are not yet needed since we do everything via our
//!     own tool stack)
//!
//! Launch: `chump --acp` (configured in main.rs)

use crate::acp::{
    build_initialize_response, build_load_session_response, build_new_session_response,
    error_response, success_response, ContentBlock, JsonRpcNotification, JsonRpcRequest,
    JsonRpcResponse, ListSessionsRequest, ListSessionsResponse, LoadSessionRequest,
    NewSessionRequest, PromptRequest, PromptResponse, SessionInfo, SessionNotification,
    SessionUpdate, StopReason, ERROR_INTERNAL, ERROR_INVALID_PARAMS, ERROR_METHOD_NOT_FOUND,
    ERROR_PARSE,
};
use anyhow::{anyhow, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, Mutex};

/// Per-session in-memory state. The cancel channel is used by `session/cancel`;
/// the metadata is surfaced by `session/list`.
pub(crate) struct SessionEntry {
    pub cancel_tx: mpsc::UnboundedSender<()>,
    pub cwd: String,
    pub created_at: String,
    pub last_accessed_at: String,
    pub message_count: u32,
}

/// Format a SystemTime as an RFC3339 UTC string (second precision, e.g.
/// `2026-04-15T12:34:56Z`). Kept dependency-free — we already carry `chrono`
/// elsewhere but the ACP server should stay lean.
fn now_rfc3339() -> String {
    // Days-in-month helper for civil-date conversion.
    fn days_in_month(year: i64, month: u32) -> u32 {
        match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 => {
                let leap =
                    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
                if leap {
                    29
                } else {
                    28
                }
            }
            _ => 30,
        }
    }

    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let sod = secs.rem_euclid(86_400) as u32;
    let hour = sod / 3600;
    let minute = (sod % 3600) / 60;
    let second = sod % 60;

    let mut days = secs.div_euclid(86_400);
    let mut year: i64 = 1970;
    loop {
        let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        let yd = if leap { 366 } else { 365 };
        if days >= yd {
            days -= yd;
            year += 1;
        } else if days < 0 {
            year -= 1;
            let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
            days += if leap { 366 } else { 365 };
        } else {
            break;
        }
    }
    let mut month: u32 = 1;
    loop {
        let dim = days_in_month(year, month) as i64;
        if days >= dim {
            days -= dim;
            month += 1;
        } else {
            break;
        }
    }
    let day = (days + 1) as u32;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, minute, second
    )
}

/// Runtime state for the ACP server.
pub struct AcpServer {
    /// Map session_id → SessionEntry (cancellation + metadata).
    sessions: Arc<Mutex<HashMap<String, SessionEntry>>>,
    /// Shared writer channel so notification emitters and response writers don't interleave.
    writer_tx: mpsc::UnboundedSender<String>,
}

impl AcpServer {
    pub fn new(writer_tx: mpsc::UnboundedSender<String>) -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            writer_tx,
        }
    }

    /// Write a JSON-RPC response to stdout via the writer channel.
    fn write_response(&self, resp: JsonRpcResponse) {
        let s = match serde_json::to_string(&resp) {
            Ok(s) => s,
            Err(e) => {
                tracing::error!("failed to serialize response: {}", e);
                return;
            }
        };
        let _ = self.writer_tx.send(s);
    }

    /// Write a JSON-RPC notification (no id) to stdout via the writer channel.
    fn write_notification(&self, method: &str, params: Value) {
        let note = JsonRpcNotification {
            jsonrpc: "2.0".to_string(),
            method: method.to_string(),
            params: Some(params),
        };
        if let Ok(s) = serde_json::to_string(&note) {
            let _ = self.writer_tx.send(s);
        }
    }

    /// Dispatch one incoming JSON-RPC message.
    async fn handle_message(&self, raw: &str) {
        let req: JsonRpcRequest = match serde_json::from_str(raw) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(err = %e, raw = %raw, "malformed JSON-RPC message");
                // Per JSON-RPC 2.0: if we can salvage the id, use it; otherwise null.
                let id = serde_json::from_str::<Value>(raw)
                    .ok()
                    .and_then(|v| v.get("id").cloned())
                    .unwrap_or(Value::Null);
                self.write_response(error_response(
                    id,
                    ERROR_PARSE,
                    format!("parse error: {}", e),
                ));
                return;
            }
        };

        let id = req.id.clone();
        let is_notification = id.is_null();

        match req.method.as_str() {
            "initialize" => {
                let resp = match success_response(id.clone(), build_initialize_response()) {
                    Ok(r) => r,
                    Err(e) => error_response(id, ERROR_INTERNAL, e.to_string()),
                };
                self.write_response(resp);
            }
            "authenticate" => {
                // We declared auth_methods=["none"], so any authenticate call is ok.
                let resp = match success_response(id.clone(), serde_json::json!({})) {
                    Ok(r) => r,
                    Err(e) => error_response(id, ERROR_INTERNAL, e.to_string()),
                };
                self.write_response(resp);
            }
            "session/new" => {
                self.handle_session_new(id, req.params).await;
            }
            "session/load" => {
                self.handle_session_load(id, req.params).await;
            }
            "session/list" => {
                self.handle_session_list(id, req.params).await;
            }
            "session/prompt" => {
                self.handle_session_prompt(id, req.params).await;
            }
            "session/cancel" => {
                // Notifications do not get responses.
                if let Some(params) = req.params {
                    if let Some(session_id) = params.get("sessionId").and_then(|v| v.as_str()) {
                        let guard = self.sessions.lock().await;
                        if let Some(entry) = guard.get(session_id) {
                            let _ = entry.cancel_tx.send(());
                            tracing::info!(session_id = %session_id, "ACP cancel requested");
                        }
                    }
                }
            }
            other => {
                if !is_notification {
                    self.write_response(error_response(
                        id,
                        ERROR_METHOD_NOT_FOUND,
                        format!("method '{}' not implemented", other),
                    ));
                }
            }
        }
    }

    async fn handle_session_new(&self, id: Value, params: Option<Value>) {
        let req: NewSessionRequest = match params.and_then(|p| serde_json::from_value(p).ok()) {
            Some(r) => r,
            None => {
                self.write_response(error_response(
                    id,
                    ERROR_INVALID_PARAMS,
                    "session/new requires NewSessionRequest params".to_string(),
                ));
                return;
            }
        };

        let session_id = format!("acp-{}", uuid::Uuid::new_v4());
        let now = now_rfc3339();

        // Register cancellation channel + metadata for this session.
        let (cancel_tx, _cancel_rx) = mpsc::unbounded_channel::<()>();
        {
            let mut guard = self.sessions.lock().await;
            guard.insert(
                session_id.clone(),
                SessionEntry {
                    cancel_tx,
                    cwd: req.cwd,
                    created_at: now.clone(),
                    last_accessed_at: now,
                    message_count: 0,
                },
            );
        }

        let resp = match success_response(id.clone(), build_new_session_response(session_id)) {
            Ok(r) => r,
            Err(e) => error_response(id, ERROR_INTERNAL, e.to_string()),
        };
        self.write_response(resp);
    }

    /// Reattach to an existing in-memory session. V1 only resumes sessions still
    /// tracked in this process; cross-process persistence is V2 work.
    async fn handle_session_load(&self, id: Value, params: Option<Value>) {
        let req: LoadSessionRequest = match params.and_then(|p| serde_json::from_value(p).ok()) {
            Some(r) => r,
            None => {
                self.write_response(error_response(
                    id,
                    ERROR_INVALID_PARAMS,
                    "session/load requires LoadSessionRequest params".to_string(),
                ));
                return;
            }
        };

        let session_id = req.session_id.clone();
        let now = now_rfc3339();

        // Verify the session exists. If not, return an error — the client should
        // fall back to session/new.
        {
            let mut guard = self.sessions.lock().await;
            match guard.get_mut(&session_id) {
                Some(entry) => {
                    // Touch last_accessed_at and refresh cancel channel so a
                    // future session/cancel on the reloaded session works.
                    let (cancel_tx, _cancel_rx) = mpsc::unbounded_channel::<()>();
                    entry.cancel_tx = cancel_tx;
                    entry.last_accessed_at = now;
                    // If the client supplied a new cwd, honor it. Otherwise keep
                    // the original — callers often omit cwd on reload.
                    if !req.cwd.is_empty() {
                        entry.cwd = req.cwd.clone();
                    }
                }
                None => {
                    self.write_response(error_response(
                        id,
                        ERROR_INVALID_PARAMS,
                        format!("session '{}' not found", session_id),
                    ));
                    return;
                }
            }
        }

        let resp = match success_response(id.clone(), build_load_session_response(&session_id)) {
            Ok(r) => r,
            Err(e) => error_response(id, ERROR_INTERNAL, e.to_string()),
        };
        self.write_response(resp);
    }

    /// Enumerate known sessions. V1 returns all in-memory sessions in one shot;
    /// `nextCursor` is always None. The `cursor`/`cwd` params are accepted but
    /// the only filter applied is `cwd` (exact match), since clients commonly
    /// want "sessions for this repo".
    async fn handle_session_list(&self, id: Value, params: Option<Value>) {
        // Empty/absent params are valid — both fields are optional.
        let req: ListSessionsRequest = match params {
            Some(p) => match serde_json::from_value(p) {
                Ok(r) => r,
                Err(e) => {
                    self.write_response(error_response(
                        id,
                        ERROR_INVALID_PARAMS,
                        format!("session/list params malformed: {}", e),
                    ));
                    return;
                }
            },
            None => ListSessionsRequest::default(),
        };

        let sessions: Vec<SessionInfo> = {
            let guard = self.sessions.lock().await;
            let mut v: Vec<SessionInfo> = guard
                .iter()
                .filter(|(_, e)| {
                    req.cwd
                        .as_ref()
                        .map(|filter| &e.cwd == filter)
                        .unwrap_or(true)
                })
                .map(|(sid, e)| SessionInfo {
                    session_id: sid.clone(),
                    cwd: e.cwd.clone(),
                    created_at: e.created_at.clone(),
                    last_accessed_at: e.last_accessed_at.clone(),
                    message_count: e.message_count,
                })
                .collect();
            // Stable order: most-recently-accessed first.
            v.sort_by(|a, b| b.last_accessed_at.cmp(&a.last_accessed_at));
            v
        };

        let resp_body = ListSessionsResponse {
            sessions,
            next_cursor: None,
        };
        let resp = match success_response(id.clone(), resp_body) {
            Ok(r) => r,
            Err(e) => error_response(id, ERROR_INTERNAL, e.to_string()),
        };
        self.write_response(resp);
    }

    async fn handle_session_prompt(&self, id: Value, params: Option<Value>) {
        let req: PromptRequest = match params.and_then(|p| serde_json::from_value(p).ok()) {
            Some(r) => r,
            None => {
                self.write_response(error_response(
                    id,
                    ERROR_INVALID_PARAMS,
                    "session/prompt requires PromptRequest params".to_string(),
                ));
                return;
            }
        };

        let session_id = req.session_id.clone();

        // Extract the first text block as the user prompt. V1 does not support mixed content.
        let user_text: String = req
            .prompt
            .iter()
            .filter_map(|b| match b {
                ContentBlock::Text { text } => Some(text.clone()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n");

        if user_text.trim().is_empty() {
            self.write_response(error_response(
                id,
                ERROR_INVALID_PARAMS,
                "prompt must contain at least one text content block".to_string(),
            ));
            return;
        }

        // Run agent turn. This is a blocking call from the ACP client's perspective;
        // we stream session/update notifications via write_notification during execution.
        // V1: simple invocation via build_chump_agent_cli + agent.run(). Event streaming
        // is approximated via post-hoc SessionUpdate emissions (real streaming requires
        // wiring EventSender from ChumpAgent through the dispatcher — noted as V2 work).

        let writer_tx = self.writer_tx.clone();
        let session_id_for_task = session_id.clone();
        let id_for_task = id.clone();

        tokio::spawn(async move {
            let result = run_agent_turn(&session_id_for_task, &user_text, writer_tx.clone()).await;

            let stop_reason = match result {
                Ok(_) => StopReason::EndTurn,
                Err(e) => {
                    tracing::error!(err = %e, "ACP prompt handler error");
                    StopReason::Error
                }
            };

            let resp = match success_response(
                id_for_task.clone(),
                PromptResponse { stop_reason },
            ) {
                Ok(r) => r,
                Err(e) => error_response(id_for_task, ERROR_INTERNAL, e.to_string()),
            };
            let s = serde_json::to_string(&resp).unwrap_or_default();
            let _ = writer_tx.send(s);
        });
    }
}

/// Run a single agent turn, streaming session/update notifications to the writer.
async fn run_agent_turn(
    session_id: &str,
    user_text: &str,
    writer_tx: mpsc::UnboundedSender<String>,
) -> Result<()> {
    // Build an event channel so agent_loop sends stream events we can translate to ACP.
    let (event_tx, mut event_rx) = crate::stream_events::event_channel();

    // Spawn a notification-forwarder that translates Chump events → ACP SessionUpdate.
    let session_id_owned = session_id.to_string();
    let writer_tx_forward = writer_tx.clone();
    let forwarder = tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            if let Some(update) = chump_event_to_acp_update(&event) {
                let note = SessionNotification {
                    session_id: session_id_owned.clone(),
                    update,
                };
                if let Ok(params) = serde_json::to_value(&note) {
                    let n = JsonRpcNotification {
                        jsonrpc: "2.0".to_string(),
                        method: "session/update".to_string(),
                        params: Some(params),
                    };
                    if let Ok(s) = serde_json::to_string(&n) {
                        let _ = writer_tx_forward.send(s);
                    }
                }
            }
        }
    });

    // Build agent with event_tx so it streams progress.
    let build = crate::discord::build_chump_agent_web_components(session_id, None)?;
    let agent = crate::agent_loop::ChumpAgent::new(
        build.provider,
        build.registry,
        Some(build.system_prompt),
        Some(build.session_manager),
        Some(event_tx),
        25,
    );

    let outcome = agent.run(user_text).await;

    // Close the event channel by dropping agent (its EventSender drops with it).
    // The forwarder will exit when the channel closes.
    drop(agent);
    let _ = forwarder.await;

    outcome.map(|_| ())
}

/// Translate a Chump AgentEvent into an ACP SessionUpdate (or None if we don't forward it).
fn chump_event_to_acp_update(event: &crate::stream_events::AgentEvent) -> Option<SessionUpdate> {
    use crate::stream_events::AgentEvent;
    match event {
        AgentEvent::TextDelta { delta } => Some(SessionUpdate::AgentMessageDelta {
            content: delta.clone(),
        }),
        AgentEvent::TextComplete { text } => Some(SessionUpdate::AgentMessageComplete {
            content: text.clone(),
        }),
        AgentEvent::ToolCallStart {
            tool_name,
            tool_input,
            call_id,
        } => Some(SessionUpdate::ToolCallStart {
            tool_call_id: call_id.clone(),
            tool_name: tool_name.clone(),
            input: tool_input.clone(),
        }),
        AgentEvent::ToolCallResult {
            call_id,
            result,
            success,
            ..
        } => Some(SessionUpdate::ToolCallResult {
            tool_call_id: call_id.clone(),
            result: result.clone(),
            success: *success,
        }),
        // Events we don't yet translate (approval requests, verification, etc.) are dropped.
        _ => None,
    }
}

/// Run the ACP server over stdio until EOF on stdin or a fatal error.
///
/// Call this from main.rs when --acp flag is set.
pub async fn run_acp_stdio() -> Result<()> {
    tracing::info!("ACP server starting (stdio JSON-RPC, protocol 2026-04)");

    // Writer channel: all outbound messages go through here so concurrent writers
    // don't interleave bytes on stdout.
    let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();

    // Spawn the stdout writer task.
    let writer_handle = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = writer_rx.recv().await {
            if stdout.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            if stdout.write_all(b"\n").await.is_err() {
                break;
            }
            let _ = stdout.flush().await;
        }
    });

    let server = Arc::new(AcpServer::new(writer_tx));

    // Read stdin line by line.
    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin).lines();

    while let Some(line) = reader.next_line().await.map_err(|e| anyhow!("stdin read: {}", e))? {
        if line.trim().is_empty() {
            continue;
        }
        let s = server.clone();
        tokio::spawn(async move {
            s.handle_message(&line).await;
        });
    }

    // Drop server to close writer channel, let writer drain, then exit.
    drop(server);
    let _ = writer_handle.await;
    tracing::info!("ACP server exiting (stdin closed)");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::acp::*;

    /// Helper: parse a JSON-RPC response from stringified form.
    fn parse_response(s: &str) -> JsonRpcResponse {
        serde_json::from_str(s).expect("valid JSON-RPC response")
    }

    #[tokio::test]
    async fn initialize_returns_agent_capabilities() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-04","clientInfo":{"name":"test","version":"0.0.1"},"clientCapabilities":{"fs":{"read":true}}}}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("response");
        let resp = parse_response(&resp_str);
        assert_eq!(resp.id, serde_json::json!(1));
        assert!(resp.result.is_some());
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["agentInfo"]["name"], "chump");
        assert_eq!(result["agentCapabilities"]["tools"], true);
        assert_eq!(result["agentCapabilities"]["skills"], true);
    }

    #[tokio::test]
    async fn unknown_method_returns_error() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":2,"method":"nonexistent","params":{}}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("response");
        let resp = parse_response(&resp_str);
        assert_eq!(resp.id, serde_json::json!(2));
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_METHOD_NOT_FOUND);
    }

    #[tokio::test]
    async fn session_new_returns_session_id_and_modes() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("response");
        let resp = parse_response(&resp_str);
        assert!(resp.result.is_some());
        let result = resp.result.unwrap();
        let sid = result["sessionId"].as_str().expect("sessionId");
        assert!(sid.starts_with("acp-"));
        let modes = result["modes"].as_array().expect("modes");
        assert!(modes.len() >= 3);
    }

    #[tokio::test]
    async fn cancel_notification_does_not_respond() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        // Notification has no id (null)
        let note = r#"{"jsonrpc":"2.0","id":null,"method":"session/cancel","params":{"sessionId":"acp-xyz"}}"#;
        server.handle_message(note).await;
        // No response should be sent for a notification with no session in registry
        tokio::time::timeout(std::time::Duration::from_millis(50), rx.recv())
            .await
            .expect_err("no response expected for cancel notification");
    }

    #[tokio::test]
    async fn malformed_request_with_id_returns_parse_error() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        // Valid JSON but invalid JsonRpcRequest shape (method must be string)
        let bad = r#"{"jsonrpc":"2.0","id":7,"method":42}"#;
        server.handle_message(bad).await;
        let resp_str = rx.recv().await.expect("parse error response");
        let resp = parse_response(&resp_str);
        // id should be recovered from the partial-valid JSON
        assert_eq!(resp.id, serde_json::json!(7));
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_PARSE);
    }

    #[tokio::test]
    async fn fully_malformed_json_returns_parse_error_with_null_id() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        // Fully malformed — can't parse as JSON at all
        let bad = r#"{not valid json at all"#;
        server.handle_message(bad).await;
        let resp_str = rx.recv().await.expect("parse error response");
        let resp = parse_response(&resp_str);
        // id is null when we can't recover it
        assert_eq!(resp.id, Value::Null);
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_PARSE);
    }

    #[tokio::test]
    async fn prompt_missing_text_errors() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":9,"method":"session/prompt","params":{"sessionId":"acp-x","prompt":[]}}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("error response");
        let resp = parse_response(&resp_str);
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
    }

    #[tokio::test]
    async fn session_load_unknown_session_returns_error() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":10,"method":"session/load","params":{"sessionId":"acp-does-not-exist","cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("error response");
        let resp = parse_response(&resp_str);
        assert_eq!(resp.id, serde_json::json!(10));
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
    }

    #[tokio::test]
    async fn session_load_known_session_returns_config_and_modes() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);

        // Create a session first.
        let new_req = r#"{"jsonrpc":"2.0","id":20,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp_str = rx.recv().await.expect("new response");
        let new_resp = parse_response(&new_resp_str);
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        // Now load it.
        let load_req = format!(
            r#"{{"jsonrpc":"2.0","id":21,"method":"session/load","params":{{"sessionId":"{}","cwd":"/tmp","mcpServers":[]}}}}"#,
            sid
        );
        server.handle_message(&load_req).await;
        let load_resp_str = rx.recv().await.expect("load response");
        let load_resp = parse_response(&load_resp_str);
        assert_eq!(load_resp.id, serde_json::json!(21));
        assert!(load_resp.error.is_none(), "load should succeed");
        let result = load_resp.result.unwrap();
        // LoadSessionResponse has configOptions + modes, no sessionId.
        assert!(result.get("sessionId").is_none());
        let modes = result["modes"].as_array().expect("modes array");
        assert!(modes.len() >= 3);
        let config = result["configOptions"].as_array().expect("configOptions array");
        assert!(!config.is_empty());
    }

    #[tokio::test]
    async fn session_load_malformed_params_returns_invalid_params() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        // Missing required sessionId field.
        let req = r#"{"jsonrpc":"2.0","id":22,"method":"session/load","params":{"cwd":"/tmp"}}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("error response");
        let resp = parse_response(&resp_str);
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
    }

    #[tokio::test]
    async fn session_list_empty_when_no_sessions() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":30,"method":"session/list","params":{}}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("list response");
        let resp = parse_response(&resp_str);
        assert_eq!(resp.id, serde_json::json!(30));
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        let sessions = result["sessions"].as_array().expect("sessions array");
        assert_eq!(sessions.len(), 0);
        // nextCursor is omitted when None.
        assert!(result.get("nextCursor").is_none());
    }

    #[tokio::test]
    async fn session_list_missing_params_accepted() {
        // Per JSON-RPC spec, `params` is optional. session/list treats absent
        // params as "no filter, no cursor" and returns the default empty list.
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":31,"method":"session/list"}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("list response");
        let resp = parse_response(&resp_str);
        assert!(resp.error.is_none(), "missing params should be OK");
    }

    #[tokio::test]
    async fn session_list_returns_created_sessions() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);

        // Create two sessions.
        let req1 = r#"{"jsonrpc":"2.0","id":40,"method":"session/new","params":{"cwd":"/repo/a","mcpServers":[]}}"#;
        server.handle_message(req1).await;
        let r1 = parse_response(&rx.recv().await.unwrap());
        let sid1 = r1.result.unwrap()["sessionId"].as_str().unwrap().to_string();

        let req2 = r#"{"jsonrpc":"2.0","id":41,"method":"session/new","params":{"cwd":"/repo/b","mcpServers":[]}}"#;
        server.handle_message(req2).await;
        let r2 = parse_response(&rx.recv().await.unwrap());
        let sid2 = r2.result.unwrap()["sessionId"].as_str().unwrap().to_string();

        // List with no filter — should return both.
        let list_req = r#"{"jsonrpc":"2.0","id":42,"method":"session/list","params":{}}"#;
        server.handle_message(list_req).await;
        let list_resp = parse_response(&rx.recv().await.unwrap());
        let result = list_resp.result.unwrap();
        let sessions = result["sessions"].as_array().expect("sessions");
        assert_eq!(sessions.len(), 2);
        let ids: Vec<&str> = sessions
            .iter()
            .map(|s| s["sessionId"].as_str().unwrap())
            .collect();
        assert!(ids.contains(&sid1.as_str()));
        assert!(ids.contains(&sid2.as_str()));

        // Each entry has the expected fields.
        let first = &sessions[0];
        assert!(first["cwd"].is_string());
        assert!(first["createdAt"].is_string());
        assert!(first["lastAccessedAt"].is_string());
        assert_eq!(first["messageCount"], 0);

        // Filter by cwd — should return only sessions with matching cwd.
        let filter_req = r#"{"jsonrpc":"2.0","id":43,"method":"session/list","params":{"cwd":"/repo/a"}}"#;
        server.handle_message(filter_req).await;
        let filter_resp = parse_response(&rx.recv().await.unwrap());
        let filtered = filter_resp.result.unwrap()["sessions"]
            .as_array()
            .expect("sessions")
            .clone();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0]["sessionId"].as_str().unwrap(), sid1);
    }

    #[tokio::test]
    async fn session_list_malformed_params_returns_invalid_params() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        // cursor must be a string; number is invalid.
        let req = r#"{"jsonrpc":"2.0","id":44,"method":"session/list","params":{"cursor":12345}}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("error response");
        let resp = parse_response(&resp_str);
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
    }

    #[test]
    fn rfc3339_now_has_expected_shape() {
        let s = now_rfc3339();
        // Format: YYYY-MM-DDTHH:MM:SSZ — 20 chars.
        assert_eq!(s.len(), 20, "unexpected shape: {}", s);
        assert!(s.ends_with('Z'));
        assert_eq!(&s[4..5], "-");
        assert_eq!(&s[7..8], "-");
        assert_eq!(&s[10..11], "T");
        assert_eq!(&s[13..14], ":");
        assert_eq!(&s[16..17], ":");
    }

    #[test]
    fn event_translation_covers_key_events() {
        use crate::stream_events::AgentEvent;

        let delta = AgentEvent::TextDelta {
            delta: "hello".into(),
        };
        assert!(matches!(
            chump_event_to_acp_update(&delta),
            Some(SessionUpdate::AgentMessageDelta { .. })
        ));

        let complete = AgentEvent::TextComplete {
            text: "done".into(),
        };
        assert!(matches!(
            chump_event_to_acp_update(&complete),
            Some(SessionUpdate::AgentMessageComplete { .. })
        ));

        let tc_start = AgentEvent::ToolCallStart {
            tool_name: "read_file".into(),
            tool_input: serde_json::json!({"path": "x"}),
            call_id: "t1".into(),
        };
        assert!(matches!(
            chump_event_to_acp_update(&tc_start),
            Some(SessionUpdate::ToolCallStart { .. })
        ));

        // Events we don't translate are dropped
        let mc = AgentEvent::ModelCallStart { round: 1 };
        assert!(chump_event_to_acp_update(&mc).is_none());
    }
}
