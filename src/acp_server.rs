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
//!   - Implements: initialize, session/new, session/load, session/list,
//!     session/prompt, session/cancel, session/set_mode, session/set_config_option
//!   - Streams: AgentMessageDelta, AgentMessageComplete, ToolCallStart,
//!     ToolCallResult, Thinking, ModeChanged
//!   - Bidirectional: agent → client RPCs via send_rpc_request:
//!     session/request_permission (user-consent for tool calls), fs/read_text_file,
//!     fs/write_text_file, terminal/{create, output, wait_for_exit, kill, release}
//!   - Deferred for V2.1: wiring the agent → client callbacks (request_permission,
//!     fs/*, terminal/*) into the actual tool middleware. The protocol pieces are
//!     all done; what remains is the integration call sites.
//!
//! Launch: `chump --acp` (configured in main.rs)

use crate::acp::{
    build_initialize_response, build_load_session_response, build_new_session_response,
    default_permission_options, error_response, success_response, ContentBlock,
    CreateTerminalParams, CreateTerminalResponse, EnvVar, JsonRpcError, JsonRpcNotification,
    JsonRpcRequest, JsonRpcResponse, KillTerminalParams, ListSessionsRequest,
    ListSessionsResponse, LoadSessionRequest, NewSessionRequest, PermissionOutcome,
    PermissionToolCall, PromptRequest, PromptResponse, ReadTextFileParams, ReadTextFileResponse,
    ReleaseTerminalParams, RequestPermissionParams, RequestPermissionResponse, SessionInfo,
    SessionNotification, SessionUpdate, SetConfigOptionRequest, SetModeRequest, StopReason,
    TerminalExitStatus, TerminalOutputParams, TerminalOutputResponse, WaitForTerminalExitParams,
    WaitForTerminalExitResponse, WriteTextFileParams, ERROR_INTERNAL, ERROR_INVALID_PARAMS,
    ERROR_METHOD_NOT_FOUND, ERROR_PARSE, KNOWN_CONFIG_OPTION_IDS, KNOWN_MODE_IDS,
};
use anyhow::{anyhow, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot, Mutex};

/// Per-session in-memory state. The cancel channel is used by `session/cancel`;
/// the metadata is surfaced by `session/list`; `current_mode` and
/// `config_values` are set via `session/set_mode` and `session/set_config_option`.
pub(crate) struct SessionEntry {
    pub cancel_tx: mpsc::UnboundedSender<()>,
    pub cwd: String,
    pub created_at: String,
    pub last_accessed_at: String,
    pub message_count: u32,
    /// Currently-selected mode id (one of `KNOWN_MODE_IDS`). Defaults to "work".
    pub current_mode: String,
    /// Overrides for advertised config options. Keys are `KNOWN_CONFIG_OPTION_IDS`
    /// entries. Values are JSON (schema is option-specific).
    pub config_values: HashMap<String, Value>,
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

/// Outcome of an outbound JSON-RPC request — either a `result` payload from the
/// peer or a structured `error`.
type RpcResult = Result<Value, JsonRpcError>;

/// Runtime state for the ACP server.
pub struct AcpServer {
    /// Map session_id → SessionEntry (cancellation + metadata).
    sessions: Arc<Mutex<HashMap<String, SessionEntry>>>,
    /// Shared writer channel so notification emitters and response writers don't interleave.
    writer_tx: mpsc::UnboundedSender<String>,
    /// Outbound requests awaiting a response from the client. Keyed by the request id
    /// the agent assigned (we use a u64 counter encoded as JSON number on the wire).
    pending_requests: Arc<Mutex<HashMap<u64, oneshot::Sender<RpcResult>>>>,
    /// Monotonic counter for outbound request ids. Starts at 1 so we can use 0 as a
    /// sentinel "never assigned" if needed elsewhere.
    request_id_counter: Arc<AtomicU64>,
}

impl AcpServer {
    pub fn new(writer_tx: mpsc::UnboundedSender<String>) -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            writer_tx,
            pending_requests: Arc::new(Mutex::new(HashMap::new())),
            request_id_counter: Arc::new(AtomicU64::new(1)),
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

    /// Send an outbound JSON-RPC request to the client and await the response.
    ///
    /// Returns:
    ///   - `Ok(Value)` if the client replied with a `result` payload
    ///   - `Err(JsonRpcError)` if the client replied with an `error` or the
    ///     request timed out (mapped to a synthetic INTERNAL error)
    ///
    /// The timeout defaults to 10 minutes which is generous — permission
    /// prompts are human-in-the-loop and users can be slow.
    pub async fn send_rpc_request(&self, method: &str, params: Value) -> RpcResult {
        self.send_rpc_request_with_timeout(method, params, Duration::from_secs(600))
            .await
    }

    /// Variant of `send_rpc_request` that lets the caller pick a timeout.
    /// Useful for tests (short timeouts) and for quick agent-initiated RPCs
    /// where waiting 10 minutes is excessive.
    pub async fn send_rpc_request_with_timeout(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> RpcResult {
        let id = self.request_id_counter.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        {
            let mut guard = self.pending_requests.lock().await;
            guard.insert(id, tx);
        }

        // Serialize as a proper JSON-RPC request.
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Value::from(id),
            method: method.to_string(),
            params: Some(params),
        };
        match serde_json::to_string(&req) {
            Ok(s) => {
                let _ = self.writer_tx.send(s);
            }
            Err(e) => {
                // Clean up the pending entry if we can't even send.
                let mut guard = self.pending_requests.lock().await;
                guard.remove(&id);
                return Err(JsonRpcError {
                    code: ERROR_INTERNAL,
                    message: format!("serialize outbound request: {}", e),
                    data: None,
                });
            }
        }

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => {
                // Sender dropped without delivering — shouldn't happen under normal flow.
                Err(JsonRpcError {
                    code: ERROR_INTERNAL,
                    message: "pending request channel closed without response".to_string(),
                    data: None,
                })
            }
            Err(_) => {
                // Timeout — drop the pending entry so late responses don't leak memory.
                let mut guard = self.pending_requests.lock().await;
                guard.remove(&id);
                Err(JsonRpcError {
                    code: ERROR_INTERNAL,
                    message: format!("request '{}' timed out after {:?}", method, timeout),
                    data: None,
                })
            }
        }
    }

    /// Route a client-sent response back to whoever is awaiting it. `msg` is the
    /// raw JSON value with `id` + either `result` or `error`. Called from
    /// `handle_message` when it detects a response-shape message.
    async fn deliver_response(&self, id: u64, msg: &Value) {
        let tx = {
            let mut guard = self.pending_requests.lock().await;
            guard.remove(&id)
        };
        let Some(tx) = tx else {
            tracing::warn!(
                id = id,
                "received response for unknown request id; ignored"
            );
            return;
        };
        let outcome: RpcResult = if let Some(err) = msg.get("error") {
            let code = err.get("code").and_then(|v| v.as_i64()).unwrap_or(ERROR_INTERNAL as i64)
                as i32;
            let message = err
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("unspecified error")
                .to_string();
            let data = err.get("data").cloned();
            Err(JsonRpcError {
                code,
                message,
                data,
            })
        } else {
            Ok(msg.get("result").cloned().unwrap_or(Value::Null))
        };
        let _ = tx.send(outcome);
    }

    /// Ask the client's user for permission to execute a tool call. Sent via
    /// `session/request_permission`. Blocks until the client responds or the
    /// default timeout (10 minutes) elapses. Returns the outcome wrapped in a
    /// typed enum so callers can use `.is_allowed()` / `.is_sticky()`.
    ///
    /// On RPC failure (client disconnect, malformed response, timeout) returns
    /// `PermissionOutcome::Cancelled` so the caller's default posture is
    /// deny-on-error (fail-closed).
    pub async fn request_permission(
        &self,
        session_id: &str,
        tool_call_id: &str,
        tool_name: &str,
        input: Value,
    ) -> PermissionOutcome {
        let params = RequestPermissionParams {
            session_id: session_id.to_string(),
            tool_call: PermissionToolCall {
                tool_call_id: tool_call_id.to_string(),
                tool_name: tool_name.to_string(),
                input,
            },
            options: default_permission_options(),
        };
        let params_value = match serde_json::to_value(&params) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(err = %e, "request_permission: failed to serialize params");
                return PermissionOutcome::Cancelled;
            }
        };
        match self
            .send_rpc_request("session/request_permission", params_value)
            .await
        {
            Ok(v) => match serde_json::from_value::<RequestPermissionResponse>(v) {
                Ok(resp) => resp.outcome,
                Err(e) => {
                    tracing::warn!(err = %e, "request_permission: unexpected response shape");
                    PermissionOutcome::Cancelled
                }
            },
            Err(err) => {
                tracing::warn!(
                    code = err.code,
                    msg = %err.message,
                    "request_permission: RPC failed; treating as cancel"
                );
                PermissionOutcome::Cancelled
            }
        }
    }

    /// Ask the client to read a text file from its filesystem. Returns the
    /// content as a UTF-8 string. Use this when Chump runs on a different host
    /// than the editor (e.g. SSH remote, devcontainer) — the client owns the
    /// authoritative file view and the agent shouldn't touch the local disk.
    ///
    /// Errors:
    ///   - Returns `Err(JsonRpcError)` if the client reports a problem (file
    ///     not found, encoding error, etc.) or the RPC fails (timeout,
    ///     malformed response, no fs capability).
    pub async fn fs_read_text_file(
        &self,
        session_id: &str,
        path: &str,
        line: Option<u32>,
        limit: Option<u32>,
    ) -> Result<String, JsonRpcError> {
        let params = ReadTextFileParams {
            session_id: session_id.to_string(),
            path: path.to_string(),
            line,
            limit,
        };
        let params_value = serde_json::to_value(&params).map_err(|e| JsonRpcError {
            code: ERROR_INTERNAL,
            message: format!("serialize fs/read_text_file params: {}", e),
            data: None,
        })?;
        let result = self
            .send_rpc_request("fs/read_text_file", params_value)
            .await?;
        let resp: ReadTextFileResponse =
            serde_json::from_value(result).map_err(|e| JsonRpcError {
                code: ERROR_INTERNAL,
                message: format!("malformed fs/read_text_file response: {}", e),
                data: None,
            })?;
        Ok(resp.content)
    }

    /// Ask the client to write `content` to `path` in its filesystem. Parent
    /// directories should be created by the client as needed. The client owns
    /// encoding and line-ending conventions; agent provides UTF-8 text.
    ///
    /// Returns `Ok(())` on success. Errors mirror `fs_read_text_file`.
    pub async fn fs_write_text_file(
        &self,
        session_id: &str,
        path: &str,
        content: &str,
    ) -> Result<(), JsonRpcError> {
        let params = WriteTextFileParams {
            session_id: session_id.to_string(),
            path: path.to_string(),
            content: content.to_string(),
        };
        let params_value = serde_json::to_value(&params).map_err(|e| JsonRpcError {
            code: ERROR_INTERNAL,
            message: format!("serialize fs/write_text_file params: {}", e),
            data: None,
        })?;
        // Result body for write is empty per spec; we just need a non-error response.
        let _ = self
            .send_rpc_request("fs/write_text_file", params_value)
            .await?;
        Ok(())
    }

    /// Ask the client to spawn a terminal/shell process. Returns the
    /// `terminal_id` the client assigned. Use it for subsequent
    /// `terminal_output` / `terminal_wait_for_exit` / `terminal_kill` /
    /// `terminal_release` calls.
    ///
    /// Why agent → client: when Chump runs on a different host than the editor
    /// (SSH remote, devcontainer, container-in-container), commands must run
    /// in the editor's environment so cwd, $PATH, secrets and network all
    /// match user expectations.
    pub async fn terminal_create(
        &self,
        session_id: &str,
        command: &str,
        args: Vec<String>,
        cwd: Option<String>,
        env: Option<Vec<EnvVar>>,
        output_byte_limit: Option<u32>,
    ) -> Result<String, JsonRpcError> {
        let params = CreateTerminalParams {
            session_id: session_id.to_string(),
            command: command.to_string(),
            args,
            cwd,
            env,
            output_byte_limit,
        };
        let v = serde_json::to_value(&params).map_err(|e| JsonRpcError {
            code: ERROR_INTERNAL,
            message: format!("serialize terminal/create params: {}", e),
            data: None,
        })?;
        let result = self.send_rpc_request("terminal/create", v).await?;
        let resp: CreateTerminalResponse =
            serde_json::from_value(result).map_err(|e| JsonRpcError {
                code: ERROR_INTERNAL,
                message: format!("malformed terminal/create response: {}", e),
                data: None,
            })?;
        Ok(resp.terminal_id)
    }

    /// Poll the client for accumulated output of a running terminal. Returns
    /// the current buffer (possibly empty) and a `truncated` flag when the
    /// client dropped older bytes to stay under the byte limit. `exit_status`
    /// is set if the process has finished — caller can use that to short-
    /// circuit instead of also calling `terminal_wait_for_exit`.
    pub async fn terminal_output(
        &self,
        session_id: &str,
        terminal_id: &str,
    ) -> Result<TerminalOutputResponse, JsonRpcError> {
        let params = TerminalOutputParams {
            session_id: session_id.to_string(),
            terminal_id: terminal_id.to_string(),
        };
        let v = serde_json::to_value(&params).map_err(|e| JsonRpcError {
            code: ERROR_INTERNAL,
            message: format!("serialize terminal/output params: {}", e),
            data: None,
        })?;
        let result = self.send_rpc_request("terminal/output", v).await?;
        serde_json::from_value(result).map_err(|e| JsonRpcError {
            code: ERROR_INTERNAL,
            message: format!("malformed terminal/output response: {}", e),
            data: None,
        })
    }

    /// Block until the terminal's process exits, then return its exit status.
    /// Uses a longer default timeout (1 hour) than `send_rpc_request` because
    /// long-running commands are the usual reason to call this.
    pub async fn terminal_wait_for_exit(
        &self,
        session_id: &str,
        terminal_id: &str,
    ) -> Result<TerminalExitStatus, JsonRpcError> {
        let params = WaitForTerminalExitParams {
            session_id: session_id.to_string(),
            terminal_id: terminal_id.to_string(),
        };
        let v = serde_json::to_value(&params).map_err(|e| JsonRpcError {
            code: ERROR_INTERNAL,
            message: format!("serialize terminal/wait_for_exit params: {}", e),
            data: None,
        })?;
        let result = self
            .send_rpc_request_with_timeout(
                "terminal/wait_for_exit",
                v,
                Duration::from_secs(3600),
            )
            .await?;
        let resp: WaitForTerminalExitResponse =
            serde_json::from_value(result).map_err(|e| JsonRpcError {
                code: ERROR_INTERNAL,
                message: format!("malformed terminal/wait_for_exit response: {}", e),
                data: None,
            })?;
        Ok(resp.exit_status)
    }

    /// Kill the terminal's process (platform equivalent of SIGKILL).
    /// Idempotent — safe to call after the process has already exited.
    pub async fn terminal_kill(
        &self,
        session_id: &str,
        terminal_id: &str,
    ) -> Result<(), JsonRpcError> {
        let params = KillTerminalParams {
            session_id: session_id.to_string(),
            terminal_id: terminal_id.to_string(),
        };
        let v = serde_json::to_value(&params).map_err(|e| JsonRpcError {
            code: ERROR_INTERNAL,
            message: format!("serialize terminal/kill params: {}", e),
            data: None,
        })?;
        let _ = self.send_rpc_request("terminal/kill", v).await?;
        Ok(())
    }

    /// Tell the client we're done with the terminal so it can free its buffer
    /// and OS handles. ALWAYS call this when finished — even after the process
    /// has exited and even if you killed it. The client may keep the process
    /// alive otherwise so output remains pollable.
    pub async fn terminal_release(
        &self,
        session_id: &str,
        terminal_id: &str,
    ) -> Result<(), JsonRpcError> {
        let params = ReleaseTerminalParams {
            session_id: session_id.to_string(),
            terminal_id: terminal_id.to_string(),
        };
        let v = serde_json::to_value(&params).map_err(|e| JsonRpcError {
            code: ERROR_INTERNAL,
            message: format!("serialize terminal/release params: {}", e),
            data: None,
        })?;
        let _ = self.send_rpc_request("terminal/release", v).await?;
        Ok(())
    }

    /// Dispatch one incoming JSON-RPC message.
    async fn handle_message(&self, raw: &str) {
        // ACP is bidirectional: the client sends us requests, AND we can send it
        // requests (e.g. session/request_permission). Responses the client sends
        // back for those outbound requests don't have a `method` field — they
        // carry `result` or `error`. Detect those first and route to the
        // pending-request map; fall through to request-parsing otherwise.
        if let Ok(peek) = serde_json::from_str::<Value>(raw) {
            let has_method = peek.get("method").is_some();
            let has_result = peek.get("result").is_some();
            let has_error = peek.get("error").is_some();
            if !has_method && (has_result || has_error) {
                if let Some(id_u64) = peek.get("id").and_then(|v| v.as_u64()) {
                    self.deliver_response(id_u64, &peek).await;
                } else {
                    tracing::warn!(
                        raw = %raw,
                        "incoming response missing or non-numeric id; discarded"
                    );
                }
                return;
            }
        }

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
            "session/set_mode" => {
                self.handle_session_set_mode(id, req.params).await;
            }
            "session/set_config_option" => {
                self.handle_session_set_config_option(id, req.params).await;
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
                    current_mode: "work".to_string(),
                    config_values: HashMap::new(),
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

    /// Switch an existing session's active mode. Validates the mode id against
    /// `KNOWN_MODE_IDS`, updates `SessionEntry::current_mode`, and emits a
    /// `ModeChanged` notification so any observing UI can update immediately.
    /// Unknown session → ERROR_INVALID_PARAMS; unknown mode → ERROR_INVALID_PARAMS.
    async fn handle_session_set_mode(&self, id: Value, params: Option<Value>) {
        let req: SetModeRequest = match params.and_then(|p| serde_json::from_value(p).ok()) {
            Some(r) => r,
            None => {
                self.write_response(error_response(
                    id,
                    ERROR_INVALID_PARAMS,
                    "session/set_mode requires SetModeRequest params".to_string(),
                ));
                return;
            }
        };

        if !KNOWN_MODE_IDS.contains(&req.mode_id.as_str()) {
            self.write_response(error_response(
                id,
                ERROR_INVALID_PARAMS,
                format!(
                    "unknown modeId '{}'; valid: {}",
                    req.mode_id,
                    KNOWN_MODE_IDS.join(", ")
                ),
            ));
            return;
        }

        {
            let mut guard = self.sessions.lock().await;
            match guard.get_mut(&req.session_id) {
                Some(entry) => {
                    entry.current_mode = req.mode_id.clone();
                    entry.last_accessed_at = now_rfc3339();
                }
                None => {
                    self.write_response(error_response(
                        id,
                        ERROR_INVALID_PARAMS,
                        format!("session '{}' not found", req.session_id),
                    ));
                    return;
                }
            }
        }

        // Emit ModeChanged so attached clients see the switch.
        let note = SessionNotification {
            session_id: req.session_id.clone(),
            update: SessionUpdate::ModeChanged {
                mode_id: req.mode_id.clone(),
            },
        };
        if let Ok(v) = serde_json::to_value(&note) {
            self.write_notification("session/update", v);
        }

        // Empty success body — the acknowledgement is in the JSON-RPC result field.
        let resp = match success_response(id.clone(), serde_json::json!({})) {
            Ok(r) => r,
            Err(e) => error_response(id, ERROR_INTERNAL, e.to_string()),
        };
        self.write_response(resp);
    }

    /// Set a runtime-configurable option on an existing session. Validates the
    /// option id against `KNOWN_CONFIG_OPTION_IDS`; accepts any JSON value
    /// (option-specific validation is V2 work). Unknown session → INVALID_PARAMS;
    /// unknown option id → INVALID_PARAMS.
    async fn handle_session_set_config_option(&self, id: Value, params: Option<Value>) {
        let req: SetConfigOptionRequest = match params.and_then(|p| serde_json::from_value(p).ok())
        {
            Some(r) => r,
            None => {
                self.write_response(error_response(
                    id,
                    ERROR_INVALID_PARAMS,
                    "session/set_config_option requires SetConfigOptionRequest params".to_string(),
                ));
                return;
            }
        };

        if !KNOWN_CONFIG_OPTION_IDS.contains(&req.option_id.as_str()) {
            self.write_response(error_response(
                id,
                ERROR_INVALID_PARAMS,
                format!(
                    "unknown optionId '{}'; valid: {}",
                    req.option_id,
                    KNOWN_CONFIG_OPTION_IDS.join(", ")
                ),
            ));
            return;
        }

        {
            let mut guard = self.sessions.lock().await;
            match guard.get_mut(&req.session_id) {
                Some(entry) => {
                    entry
                        .config_values
                        .insert(req.option_id.clone(), req.value.clone());
                    entry.last_accessed_at = now_rfc3339();
                }
                None => {
                    self.write_response(error_response(
                        id,
                        ERROR_INVALID_PARAMS,
                        format!("session '{}' not found", req.session_id),
                    ));
                    return;
                }
            }
        }

        let resp = match success_response(id.clone(), serde_json::json!({})) {
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

    // ── set_mode tests ────────────────────────────────────────────────

    #[tokio::test]
    async fn session_set_mode_happy_path_emits_notification() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);

        // Create session.
        let new_req = r#"{"jsonrpc":"2.0","id":50,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        // Switch to research mode.
        let set_req = format!(
            r#"{{"jsonrpc":"2.0","id":51,"method":"session/set_mode","params":{{"sessionId":"{}","modeId":"research"}}}}"#,
            sid
        );
        server.handle_message(&set_req).await;

        // First message off the channel should be the ModeChanged notification
        // (writes happen in handler order).
        let msg1 = rx.recv().await.expect("notification first");
        let v1: serde_json::Value = serde_json::from_str(&msg1).unwrap();
        assert_eq!(v1["method"], "session/update", "first emit is the notification");
        assert_eq!(v1["params"]["update"]["type"], "mode_changed");
        assert_eq!(v1["params"]["update"]["modeId"], "research");
        assert_eq!(v1["params"]["sessionId"], sid);

        // Then the JSON-RPC success response.
        let msg2 = rx.recv().await.expect("ack second");
        let resp = parse_response(&msg2);
        assert_eq!(resp.id, serde_json::json!(51));
        assert!(resp.error.is_none());

        // Verify state was actually updated.
        let guard = server.sessions.lock().await;
        let entry = guard.get(&sid).expect("entry");
        assert_eq!(entry.current_mode, "research");
    }

    #[tokio::test]
    async fn session_set_mode_unknown_mode_returns_invalid_params() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);

        // Create session.
        let new_req = r#"{"jsonrpc":"2.0","id":52,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let set_req = format!(
            r#"{{"jsonrpc":"2.0","id":53,"method":"session/set_mode","params":{{"sessionId":"{}","modeId":"hyperdrive"}}}}"#,
            sid
        );
        server.handle_message(&set_req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_some());
        let err = resp.error.unwrap();
        assert_eq!(err.code, ERROR_INVALID_PARAMS);
        assert!(err.message.contains("hyperdrive"), "message: {}", err.message);
    }

    #[tokio::test]
    async fn session_set_mode_unknown_session_returns_invalid_params() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":54,"method":"session/set_mode","params":{"sessionId":"acp-nope","modeId":"work"}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
    }

    // ── set_config_option tests ───────────────────────────────────────

    #[tokio::test]
    async fn session_set_config_option_happy_path() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);

        let new_req = r#"{"jsonrpc":"2.0","id":60,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let set_req = format!(
            r#"{{"jsonrpc":"2.0","id":61,"method":"session/set_config_option","params":{{"sessionId":"{}","optionId":"context_engine","value":"light"}}}}"#,
            sid
        );
        server.handle_message(&set_req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert_eq!(resp.id, serde_json::json!(61));
        assert!(resp.error.is_none());

        let guard = server.sessions.lock().await;
        let entry = guard.get(&sid).expect("entry");
        assert_eq!(
            entry.config_values.get("context_engine"),
            Some(&serde_json::json!("light"))
        );
    }

    #[tokio::test]
    async fn session_set_config_option_unknown_option_returns_invalid_params() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let new_req = r#"{"jsonrpc":"2.0","id":62,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let set_req = format!(
            r#"{{"jsonrpc":"2.0","id":63,"method":"session/set_config_option","params":{{"sessionId":"{}","optionId":"warp_factor","value":9}}}}"#,
            sid
        );
        server.handle_message(&set_req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_some());
        let err = resp.error.unwrap();
        assert_eq!(err.code, ERROR_INVALID_PARAMS);
        assert!(err.message.contains("warp_factor"));
    }

    #[tokio::test]
    async fn session_set_config_option_unknown_session_returns_invalid_params() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":64,"method":"session/set_config_option","params":{"sessionId":"acp-nope","optionId":"context_engine","value":"default"}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
    }

    // ── Bidirectional RPC tests (agent → client → agent) ──────────────

    /// Outbound request → simulated client response → caller receives the result.
    /// Verifies the round-trip plumbing: send_rpc_request writes a request to
    /// the writer channel, deliver_response routes the reply to the awaiting
    /// oneshot.
    #[tokio::test]
    async fn outbound_request_round_trip() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        // Spawn a task that simulates the client: read the outbound request,
        // extract its id, send back a result message.
        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.expect("outbound request");
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"echo":"hi"}}}}"#,
                id
            );
            // Feed the response back through the same dispatcher path.
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .send_rpc_request_with_timeout(
                "test/echo",
                serde_json::json!({"x": 1}),
                Duration::from_secs(2),
            )
            .await;
        client.await.unwrap();
        let v = result.expect("ok result");
        assert_eq!(v["echo"], "hi");
    }

    /// Outbound request → client returns an error → caller gets Err with the
    /// code + message preserved.
    #[tokio::test]
    async fn outbound_request_error_response_propagates() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.expect("outbound request");
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32000,"message":"client refused"}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .send_rpc_request_with_timeout(
                "test/refused",
                serde_json::json!({}),
                Duration::from_secs(2),
            )
            .await;
        client.await.unwrap();
        let err = result.expect_err("should be error");
        assert_eq!(err.code, -32000);
        assert!(err.message.contains("client refused"));
    }

    /// Outbound request with no client response → caller times out and the
    /// pending entry is reaped (no memory leak).
    #[tokio::test]
    async fn outbound_request_timeout() {
        let (tx, _rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        // 50ms timeout — plenty for tokio scheduler, never satisfied.
        let result = server
            .send_rpc_request_with_timeout(
                "test/blackhole",
                serde_json::json!({}),
                Duration::from_millis(50),
            )
            .await;
        let err = result.expect_err("should time out");
        assert_eq!(err.code, ERROR_INTERNAL);
        assert!(err.message.contains("timed out"), "msg: {}", err.message);
        // Pending map should be empty after reap.
        let guard = server.pending_requests.lock().await;
        assert!(guard.is_empty(), "pending map should be reaped on timeout");
    }

    /// A response carrying an unknown id should not crash; it's logged and dropped.
    #[tokio::test]
    async fn unknown_response_id_is_ignored() {
        let (tx, _rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        // Direct delivery for a never-registered id; should not panic.
        server
            .handle_message(r#"{"jsonrpc":"2.0","id":99999,"result":{"orphan":true}}"#)
            .await;
        // No assertion needed — surviving the call is the test.
    }

    // ── request_permission tests ──────────────────────────────────────

    /// Happy path: agent calls request_permission, simulated client picks
    /// "allow_once", outcome reflects that and is_allowed() returns true.
    #[tokio::test]
    async fn request_permission_allow_once() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.expect("permission request");
            let v: Value = serde_json::from_str(&raw).unwrap();
            // Verify the outbound request shape.
            assert_eq!(v["method"], "session/request_permission");
            assert_eq!(v["params"]["sessionId"], "acp-test");
            assert_eq!(v["params"]["toolCall"]["toolName"], "read_file");
            assert!(v["params"]["options"].as_array().unwrap().len() >= 3);
            let id = v["id"].as_u64().unwrap();

            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"outcome":{{"type":"selected","optionId":"allow_once"}}}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let outcome = server
            .request_permission(
                "acp-test",
                "tc-1",
                "read_file",
                serde_json::json!({"path": "README.md"}),
            )
            .await;
        client.await.unwrap();
        match outcome {
            PermissionOutcome::Selected { ref option_id } => {
                assert_eq!(option_id, "allow_once");
            }
            other => panic!("expected Selected, got {:?}", other),
        }
        assert!(outcome.is_allowed());
        assert!(!outcome.is_sticky());
    }

    /// Client picks "allow_always" — outcome should be sticky.
    #[tokio::test]
    async fn request_permission_allow_always_is_sticky() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"outcome":{{"type":"selected","optionId":"allow_always"}}}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let outcome = server
            .request_permission("acp-test", "tc-2", "shell_exec", serde_json::json!({}))
            .await;
        client.await.unwrap();
        assert!(outcome.is_allowed());
        assert!(outcome.is_sticky());
    }

    /// Client cancels — outcome is Cancelled and not allowed.
    #[tokio::test]
    async fn request_permission_cancelled() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"outcome":{{"type":"cancelled"}}}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let outcome = server
            .request_permission("acp-test", "tc-3", "read_file", serde_json::json!({}))
            .await;
        client.await.unwrap();
        assert!(matches!(outcome, PermissionOutcome::Cancelled));
        assert!(!outcome.is_allowed());
    }

    /// Client returns an error response — agent treats as Cancelled (fail-closed).
    #[tokio::test]
    async fn request_permission_rpc_error_treated_as_cancel() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32603,"message":"client crashed"}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let outcome = server
            .request_permission("acp-test", "tc-4", "read_file", serde_json::json!({}))
            .await;
        client.await.unwrap();
        assert!(matches!(outcome, PermissionOutcome::Cancelled));
        assert!(!outcome.is_allowed());
    }

    /// Selected with an unknown optionId is preserved verbatim, but is_allowed()
    /// returns false. Lets clients invent their own options without breaking
    /// fail-closed safety.
    #[tokio::test]
    async fn request_permission_unknown_option_id_not_allowed() {
        let outcome = PermissionOutcome::Selected {
            option_id: "deny_with_reason".to_string(),
        };
        assert!(!outcome.is_allowed());
        assert!(!outcome.is_sticky());
    }

    // ── fs/* tests (agent → client filesystem delegation) ─────────────

    /// fs/read_text_file happy path: agent calls; simulated client returns
    /// content; agent receives a String.
    #[tokio::test]
    async fn fs_read_text_file_round_trip() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.expect("read request");
            let v: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(v["method"], "fs/read_text_file");
            assert_eq!(v["params"]["path"], "/tmp/notes.md");
            assert_eq!(v["params"]["sessionId"], "acp-fs");
            // line + limit are optional; omitted in this call.
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"content":"hello\nworld\n"}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .fs_read_text_file("acp-fs", "/tmp/notes.md", None, None)
            .await;
        client.await.unwrap();
        let content = result.expect("ok");
        assert_eq!(content, "hello\nworld\n");
    }

    /// fs/read_text_file with line/limit: params are forwarded; client can
    /// honor them. We just verify the wire shape — actual slicing is the
    /// client's responsibility.
    #[tokio::test]
    async fn fs_read_text_file_line_limit_passed() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(v["params"]["line"], 5);
            assert_eq!(v["params"]["limit"], 10);
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"content":"slice\n"}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .fs_read_text_file("acp-fs", "/tmp/big.txt", Some(5), Some(10))
            .await;
        client.await.unwrap();
        assert_eq!(result.unwrap(), "slice\n");
    }

    /// Client returns an error (file not found) — propagated to caller.
    #[tokio::test]
    async fn fs_read_text_file_client_error_propagates() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32001,"message":"ENOENT: no such file"}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .fs_read_text_file("acp-fs", "/tmp/nope.txt", None, None)
            .await;
        client.await.unwrap();
        let err = result.expect_err("should be err");
        assert_eq!(err.code, -32001);
        assert!(err.message.contains("ENOENT"));
    }

    /// fs/write_text_file happy path: agent sends content, client acks
    /// (empty result body), agent gets Ok(()).
    #[tokio::test]
    async fn fs_write_text_file_round_trip() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(v["method"], "fs/write_text_file");
            assert_eq!(v["params"]["path"], "/tmp/output.md");
            assert_eq!(v["params"]["content"], "wrote it\n");
            let id = v["id"].as_u64().unwrap();
            // Empty result body is the spec's success signal.
            let response = format!(r#"{{"jsonrpc":"2.0","id":{},"result":{{}}}}"#, id);
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .fs_write_text_file("acp-fs", "/tmp/output.md", "wrote it\n")
            .await;
        client.await.unwrap();
        result.expect("ok");
    }

    /// fs/write_text_file: client error (e.g. EACCES) propagates.
    #[tokio::test]
    async fn fs_write_text_file_client_error_propagates() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32002,"message":"EACCES: permission denied"}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .fs_write_text_file("acp-fs", "/etc/passwd", "muahaha")
            .await;
        client.await.unwrap();
        let err = result.expect_err("should fail");
        assert_eq!(err.code, -32002);
    }

    // ── terminal/* tests (agent → client shell delegation) ────────────

    /// terminal/create happy path: agent sends command + args + env; client
    /// returns a terminalId; agent receives it as a String.
    #[tokio::test]
    async fn terminal_create_round_trip() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.expect("create request");
            let v: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(v["method"], "terminal/create");
            assert_eq!(v["params"]["sessionId"], "acp-term");
            assert_eq!(v["params"]["command"], "cargo");
            assert_eq!(v["params"]["args"], serde_json::json!(["test", "--quiet"]));
            assert_eq!(v["params"]["cwd"], "/repo");
            // env should serialize as Vec<EnvVar> for deterministic ordering.
            let env = v["params"]["env"].as_array().expect("env array");
            assert_eq!(env.len(), 1);
            assert_eq!(env[0]["name"], "RUST_LOG");
            assert_eq!(env[0]["value"], "debug");
            assert_eq!(v["params"]["outputByteLimit"], 1_048_576);

            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"terminalId":"term-abc"}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .terminal_create(
                "acp-term",
                "cargo",
                vec!["test".into(), "--quiet".into()],
                Some("/repo".into()),
                Some(vec![EnvVar {
                    name: "RUST_LOG".into(),
                    value: "debug".into(),
                }]),
                Some(1_048_576),
            )
            .await;
        client.await.unwrap();
        let terminal_id = result.expect("ok");
        assert_eq!(terminal_id, "term-abc");
    }

    /// terminal/create with optional fields omitted: cwd/env/limit absent on the wire.
    #[tokio::test]
    async fn terminal_create_omits_optional_fields() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            // Optional fields skipped via skip_serializing_if when None.
            assert!(v["params"].get("cwd").is_none(), "cwd omitted");
            assert!(v["params"].get("env").is_none(), "env omitted");
            assert!(
                v["params"].get("outputByteLimit").is_none(),
                "outputByteLimit omitted"
            );
            let id = v["id"].as_u64().unwrap();
            let response =
                format!(r#"{{"jsonrpc":"2.0","id":{},"result":{{"terminalId":"t1"}}}}"#, id);
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .terminal_create("acp-term", "ls", vec![], None, None, None)
            .await;
        client.await.unwrap();
        assert_eq!(result.unwrap(), "t1");
    }

    /// terminal/output returns running process: output present, exit_status None.
    #[tokio::test]
    async fn terminal_output_running_process() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(v["method"], "terminal/output");
            assert_eq!(v["params"]["terminalId"], "term-abc");
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"output":"running...\n","truncated":false}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server.terminal_output("acp-term", "term-abc").await;
        client.await.unwrap();
        let resp = result.unwrap();
        assert_eq!(resp.output, "running...\n");
        assert!(!resp.truncated);
        assert!(resp.exit_status.is_none(), "still running");
    }

    /// terminal/output for an exited process carries exit_status alongside the buffered output.
    #[tokio::test]
    async fn terminal_output_exited_process_has_status() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"output":"done\n","truncated":true,"exitStatus":{{"exitCode":0}}}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server.terminal_output("acp-term", "term-abc").await;
        client.await.unwrap();
        let resp = result.unwrap();
        assert!(resp.truncated);
        let exit = resp.exit_status.expect("exited");
        assert_eq!(exit.exit_code, Some(0));
        assert!(exit.signal.is_none());
    }

    /// terminal/wait_for_exit returns the exit status when the process finishes.
    #[tokio::test]
    async fn terminal_wait_for_exit_returns_status() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(v["method"], "terminal/wait_for_exit");
            let id = v["id"].as_u64().unwrap();
            // Process killed by SIGTERM.
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"exitStatus":{{"signal":"SIGTERM"}}}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server.terminal_wait_for_exit("acp-term", "term-abc").await;
        client.await.unwrap();
        let exit = result.unwrap();
        assert!(exit.exit_code.is_none());
        assert_eq!(exit.signal, Some("SIGTERM".to_string()));
    }

    /// terminal/kill: agent fires the kill, client acks empty body, agent gets Ok(()).
    #[tokio::test]
    async fn terminal_kill_round_trip() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(v["method"], "terminal/kill");
            let id = v["id"].as_u64().unwrap();
            let response = format!(r#"{{"jsonrpc":"2.0","id":{},"result":{{}}}}"#, id);
            server_for_client.handle_message(&response).await;
        });

        let result = server.terminal_kill("acp-term", "term-abc").await;
        client.await.unwrap();
        result.expect("ok");
    }

    /// terminal/release: must always be called when done; ack is empty.
    #[tokio::test]
    async fn terminal_release_round_trip() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(v["method"], "terminal/release");
            let id = v["id"].as_u64().unwrap();
            let response = format!(r#"{{"jsonrpc":"2.0","id":{},"result":{{}}}}"#, id);
            server_for_client.handle_message(&response).await;
        });

        let result = server.terminal_release("acp-term", "term-abc").await;
        client.await.unwrap();
        result.expect("ok");
    }

    /// Client-side error on terminal/create propagates as Err with code preserved
    /// (e.g. -32004 for "command not found" or platform-specific spawn errors).
    #[tokio::test]
    async fn terminal_create_client_error_propagates() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));

        let server_for_client = server.clone();
        let client = tokio::spawn(async move {
            let raw = rx.recv().await.unwrap();
            let v: Value = serde_json::from_str(&raw).unwrap();
            let id = v["id"].as_u64().unwrap();
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32004,"message":"command not found: nopebot"}}}}"#,
                id
            );
            server_for_client.handle_message(&response).await;
        });

        let result = server
            .terminal_create("acp-term", "nopebot", vec![], None, None, None)
            .await;
        client.await.unwrap();
        let err = result.expect_err("should fail");
        assert_eq!(err.code, -32004);
        assert!(err.message.contains("nopebot"));
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
