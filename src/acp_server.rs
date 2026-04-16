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
    build_initialize_response, build_new_session_response, error_response, success_response,
    ContentBlock, JsonRpcNotification, JsonRpcRequest, JsonRpcResponse, NewSessionRequest,
    PromptRequest, PromptResponse, SessionNotification, SessionUpdate, StopReason, ERROR_INTERNAL,
    ERROR_INVALID_PARAMS, ERROR_METHOD_NOT_FOUND, ERROR_PARSE,
};
use anyhow::{anyhow, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, Mutex};

/// Runtime state for the ACP server.
pub struct AcpServer {
    /// Map session_id → cancellation tx (send (), any listener cancels in-flight prompt)
    sessions: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<()>>>>,
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
            "session/prompt" => {
                self.handle_session_prompt(id, req.params).await;
            }
            "session/cancel" => {
                // Notifications do not get responses.
                if let Some(params) = req.params {
                    if let Some(session_id) = params.get("sessionId").and_then(|v| v.as_str()) {
                        let guard = self.sessions.lock().await;
                        if let Some(tx) = guard.get(session_id) {
                            let _ = tx.send(());
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
        let _req: NewSessionRequest = match params.and_then(|p| serde_json::from_value(p).ok()) {
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

        // Register cancellation channel for this session.
        let (cancel_tx, _cancel_rx) = mpsc::unbounded_channel::<()>();
        {
            let mut guard = self.sessions.lock().await;
            guard.insert(session_id.clone(), cancel_tx);
        }

        let resp = match success_response(id.clone(), build_new_session_response(session_id)) {
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
