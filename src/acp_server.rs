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
//!   - Cross-process persistence: AcpServer.persist_dir persists each
//!     SessionEntry to `{persist_dir}/{session_id}.json` via atomic
//!     temp-file + rename. session/load reconstitutes from disk when the
//!     memory map misses; session/list merges memory + disk without dupes.
//!     Production resolves persist_dir from CHUMP_HOME/CHUMP_REPO; tests
//!     pass an explicit dir via new_with_persist_dir so they're immune to
//!     env var races.
//!   - V2.1 integration (shipped in 0e71d60, 0821f85, 8709c97): write
//!     tools gate through session/request_permission; read/write tools
//!     delegate to fs/*; shell tool delegates to terminal/* when the
//!     client declared the corresponding capability.
//!
//! Launch: `chump --acp` (configured in main.rs)

use crate::acp::{
    build_initialize_response, build_load_session_response, build_new_session_response,
    default_permission_options, error_response, success_response, ClearPermissionRequest,
    ClientCapabilities, ContentBlock, CreateTerminalParams, CreateTerminalResponse, EnvVar,
    InitializeRequest, JsonRpcError, JsonRpcNotification, JsonRpcRequest, JsonRpcResponse,
    KillTerminalParams, ListPermissionsRequest, ListPermissionsResponse, ListSessionsRequest,
    ListSessionsResponse, LoadSessionRequest, NewSessionRequest, PermissionEntry,
    PermissionOutcome, PermissionToolCall, PromptRequest, PromptResponse, ReadTextFileParams,
    ReadTextFileResponse, ReleaseTerminalParams, RequestPermissionParams,
    RequestPermissionResponse, SessionInfo, SessionNotification, SessionUpdate,
    SetConfigOptionRequest, SetModeRequest, StopReason, TerminalExitStatus, TerminalOutputParams,
    TerminalOutputResponse, WaitForTerminalExitParams, WaitForTerminalExitResponse,
    WriteTextFileParams, ERROR_INTERNAL, ERROR_INVALID_PARAMS, ERROR_METHOD_NOT_FOUND, ERROR_PARSE,
    KNOWN_CONFIG_OPTION_IDS, KNOWN_MODE_IDS, SESSION_LIST_DEFAULT_PAGE_SIZE,
    SESSION_LIST_MAX_PAGE_SIZE,
};
use anyhow::{anyhow, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot, Mutex};

// ── Session persistence (disk-backed store for session/load + session/list) ──
//
// We persist SessionEntry metadata as JSON files under
// `{CHUMP_HOME}/acp_sessions/{session_id}.json` so `session/load` works
// across process restarts. V1 scope: persist + restore the metadata the
// editor cares about for resumption. Full conversation history is handled
// separately by `SessionManager` (not in scope here).

/// On-disk serialization of a session. `cancel_tx` is NOT persisted — it's
/// recreated fresh on reload so a subsequent `session/cancel` still works.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct PersistedSession {
    pub session_id: String,
    pub cwd: String,
    pub created_at: String,
    pub last_accessed_at: String,
    pub message_count: u32,
    pub current_mode: String,
    pub config_values: HashMap<String, Value>,
    pub permission_decisions: HashMap<String, StickyDecision>,
    /// MCP servers the client originally requested. Persisted so a future
    /// process can know what to spawn on session/load. Default-empty for
    /// backward compat with files written before this field existed.
    #[serde(default)]
    pub requested_mcp_servers: Vec<(String, String, Vec<String>)>,
}

impl PersistedSession {
    fn from_entry(session_id: &str, entry: &SessionEntry) -> Self {
        Self {
            session_id: session_id.to_string(),
            cwd: entry.cwd.clone(),
            created_at: entry.created_at.clone(),
            last_accessed_at: entry.last_accessed_at.clone(),
            message_count: entry.message_count,
            current_mode: entry.current_mode.clone(),
            config_values: entry.config_values.clone(),
            permission_decisions: entry.permission_decisions.clone(),
            requested_mcp_servers: entry.requested_mcp_servers.clone(),
        }
    }

    fn into_entry(self, cancel_tx: mpsc::UnboundedSender<()>) -> (String, SessionEntry) {
        (
            self.session_id,
            SessionEntry {
                cancel_tx,
                cwd: self.cwd,
                created_at: self.created_at,
                last_accessed_at: self.last_accessed_at,
                message_count: self.message_count,
                current_mode: self.current_mode,
                config_values: self.config_values,
                permission_decisions: self.permission_decisions,
                requested_mcp_servers: self.requested_mcp_servers,
                // MCP children aren't persisted — session/load caller is
                // responsible for respawning via `SessionMcpPool::spawn_all`
                // and slotting the result into `entry.mcp_pool`.
                mcp_pool: None,
            },
        )
    }
}

// StickyDecision is used in PersistedSession so it needs Serde impls.
// Can't add derive retroactively without touching the declaration, so we
// do it manually as adjacent-tagged strings.
impl serde::Serialize for StickyDecision {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            StickyDecision::AllowAlways => s.serialize_str("allow_always"),
            StickyDecision::DenyAlways => s.serialize_str("deny_always"),
        }
    }
}

impl<'de> serde::Deserialize<'de> for StickyDecision {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        match s.as_str() {
            "allow_always" => Ok(StickyDecision::AllowAlways),
            "deny_always" => Ok(StickyDecision::DenyAlways),
            other => Err(serde::de::Error::custom(format!(
                "unknown StickyDecision: {}",
                other
            ))),
        }
    }
}

/// Resolve the persist directory from env vars. Called once at
/// `AcpServer::new` construction time; None when neither CHUMP_HOME nor
/// CHUMP_REPO is set, which disables persistence for this server instance.
/// Production code uses this; tests pass an explicit dir via
/// `new_with_persist_dir` so they're immune to env var races between
/// parallel tests.
fn resolve_persist_dir_from_env() -> Option<std::path::PathBuf> {
    #[cfg(not(test))]
    {
        let has_home = std::env::var("CHUMP_HOME")
            .map(|v| !v.trim().is_empty())
            .unwrap_or(false);
        let has_repo = std::env::var("CHUMP_REPO")
            .map(|v| !v.trim().is_empty())
            .unwrap_or(false);
        if has_home || has_repo {
            Some(crate::repo_path::runtime_base().join("acp_sessions"))
        } else {
            None
        }
    }
    #[cfg(test)]
    {
        // Tests never auto-enable persistence via env vars; they must
        // construct with new_with_persist_dir so the dir is scoped to the
        // AcpServer instance and can't leak to parallel tests.
        None
    }
}

/// Atomic write: serialize → temp file → rename. Creates the directory if
/// needed. Logged at warn level on failure but doesn't error the caller —
/// a failed persist degrades to "this session won't survive restart" rather
/// than crashing the prompt. Takes an explicit `dir` so the AcpServer
/// controls persistence location (avoids env-var races in parallel tests).
fn persist_session_sync_to(dir: &std::path::Path, session: &PersistedSession) {
    if let Err(e) = std::fs::create_dir_all(dir) {
        tracing::warn!(err = %e, dir = ?dir, "failed to create acp_sessions dir");
        return;
    }
    let final_path = dir.join(format!("{}.json", session.session_id));
    let tmp_path = dir.join(format!(".{}.json.tmp", session.session_id));
    let json = match serde_json::to_vec_pretty(session) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(err = %e, "failed to serialize session for persist");
            return;
        }
    };
    if let Err(e) = std::fs::write(&tmp_path, &json) {
        tracing::warn!(err = %e, path = ?tmp_path, "failed to write tmp session file");
        return;
    }
    if let Err(e) = std::fs::rename(&tmp_path, &final_path) {
        tracing::warn!(err = %e, "failed to rename tmp → final session file");
        let _ = std::fs::remove_file(&tmp_path);
    }
}

/// Read a persisted session by id from `dir`. Returns None when the file
/// doesn't exist or fails to parse (tracing::warn in the malformed case).
fn load_persisted_session_from(
    dir: &std::path::Path,
    session_id: &str,
) -> Option<PersistedSession> {
    let path = dir.join(format!("{}.json", session_id));
    let bytes = std::fs::read(&path).ok()?;
    match serde_json::from_slice::<PersistedSession>(&bytes) {
        Ok(s) => Some(s),
        Err(e) => {
            tracing::warn!(err = %e, path = ?path, "malformed persisted session; ignoring");
            None
        }
    }
}

/// Enumerate all persisted sessions on disk at `dir`. Returns empty on missing
/// directory (first-run case).
fn load_all_persisted_sessions_from(dir: &std::path::Path) -> Vec<PersistedSession> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().map(|s| s == "json").unwrap_or(false)
            && path
                .file_name()
                .and_then(|s| s.to_str())
                .map(|n| !n.starts_with('.'))
                .unwrap_or(false)
        {
            if let Ok(bytes) = std::fs::read(&path) {
                if let Ok(s) = serde_json::from_slice::<PersistedSession>(&bytes) {
                    out.push(s);
                }
            }
        }
    }
    out
}

tokio::task_local! {
    /// Per-task session id for the currently-running agent turn. Set inside
    /// `handle_session_prompt`'s spawn scope; absent outside ACP mode.
    /// Tool middleware reads this via `current_acp_session()` to decide whether
    /// to gate writes through `session/request_permission`.
    static ACP_CURRENT_SESSION: String;
}

/// Global handle to the running AcpServer. Set once on `run_acp_stdio()`
/// startup; None for non-ACP launches (CLI, web, Discord). Tool middleware
/// reads this via `current_acp_server()` to dispatch out-of-band RPCs back
/// to the editor.
static CURRENT_ACP_SERVER: OnceLock<Arc<AcpServer>> = OnceLock::new();

/// Install the ACP server as the current one. Only works once per process —
/// subsequent calls are silently ignored (matches OnceLock semantics).
fn install_current_server(server: Arc<AcpServer>) {
    let _ = CURRENT_ACP_SERVER.set(server);
}

/// Get the currently-running AcpServer if ACP mode is active. Returns None
/// for non-ACP launches.
pub fn current_acp_server() -> Option<Arc<AcpServer>> {
    CURRENT_ACP_SERVER.get().cloned()
}

/// Get the session id of the currently-running agent turn if we're inside an
/// ACP session/prompt call. Returns None outside ACP mode or between prompts.
pub fn current_acp_session() -> Option<String> {
    ACP_CURRENT_SESSION.try_with(|s| s.clone()).ok()
}

/// Result of `acp_permission_gate` — a typed version of "should this tool
/// call proceed" that callers can match on without dragging in JSON-RPC types.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AcpPermissionResult {
    /// No ACP context, or the tool is not gated, or the client approved. Proceed.
    Allow,
    /// User denied (or RPC failed, treated fail-closed). Abort the tool with
    /// the attached reason.
    Deny { reason: String },
}

/// Sticky permission decisions cached on a `SessionEntry` so we don't re-prompt
/// the user every single time the same tool fires. Only `AllowAlways` and
/// `DenyAlways` are cached; `AllowOnce` is per-call by design.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StickyDecision {
    AllowAlways,
    DenyAlways,
}

/// Delegate a file read to the ACP client if we're running under ACP AND the
/// client declared fs.read support. Returns:
///   - `Some(Ok(content))` when the client read the file for us.
///   - `Some(Err(anyhow))` when ACP mode is active but the client failed
///     (file not found, permission denied, etc.). Caller should surface this
///     rather than falling back to local disk, because the editor owns the
///     filesystem truth.
///   - `None` when ACP is not active (or client doesn't support fs.read) and
///     the caller should fall through to local filesystem access.
///
/// `line` is 1-indexed; `limit` is the max lines to return. Both optional.
pub async fn acp_maybe_read_text_file(
    path: &str,
    line: Option<u32>,
    limit: Option<u32>,
) -> Option<Result<String>> {
    let server = current_acp_server()?;
    let session_id = current_acp_session()?;
    if !server.client_fs_read_supported().await {
        return None;
    }
    match server
        .fs_read_text_file(&session_id, path, line, limit)
        .await
    {
        Ok(content) => Some(Ok(content)),
        Err(err) => Some(Err(anyhow!(
            "ACP fs/read_text_file failed ({}): {}",
            err.code,
            err.message
        ))),
    }
}

/// Delegate a file write to the ACP client. Same semantics as
/// `acp_maybe_read_text_file` — returns `None` when we should fall through to
/// local disk, `Some(Ok(()))` on client success, `Some(Err(...))` on client
/// failure (propagated rather than silently falling back to local, because
/// the editor expected the write to land in its filesystem).
pub async fn acp_maybe_write_text_file(path: &str, content: &str) -> Option<Result<()>> {
    let server = current_acp_server()?;
    let session_id = current_acp_session()?;
    if !server.client_fs_write_supported().await {
        return None;
    }
    match server.fs_write_text_file(&session_id, path, content).await {
        Ok(()) => Some(Ok(())),
        Err(err) => Some(Err(anyhow!(
            "ACP fs/write_text_file failed ({}): {}",
            err.code,
            err.message
        ))),
    }
}

/// Result of `acp_maybe_run_shell_cmd` — formatted output already trimmed to
/// `max_output_chars`, plus the process exit code so callers can record it.
#[derive(Debug, Clone)]
pub struct AcpShellResult {
    /// Formatted stdout/stderr (matches local-execution format: combined, with
    /// "stderr:" separator if both present, fallback to "exit code N" when empty).
    pub output: String,
    /// Process exit code; None when killed by signal.
    pub exit_code: Option<i32>,
}

/// Delegate a shell command to the ACP client's terminal infrastructure. Spawn
/// `sh -c <cmd>` (or `cmd /c <cmd>` on Windows) inside the client's
/// environment, poll for output every 100ms until the process exits or the
/// timeout fires, then release the terminal.
///
/// Returns:
///   - `None` when ACP isn't active or the client doesn't support `terminal/*`
///     (caller falls through to local execution).
///   - `Some(Ok(AcpShellResult))` on a clean run.
///   - `Some(Err(_))` when the client errored at any step (create / poll /
///     release). Caller should surface — local fall-back would be misleading.
pub async fn acp_maybe_run_shell_cmd(
    cmd: &str,
    cwd: Option<String>,
    timeout_secs: u64,
    max_output_chars: usize,
) -> Option<Result<AcpShellResult>> {
    let server = current_acp_server()?;
    let session_id = current_acp_session()?;
    if !server.client_terminal_supported().await {
        return None;
    }

    // Estimate bytes ≈ 4 × chars for safety with multibyte content.
    let byte_limit = (max_output_chars as u32).saturating_mul(4).max(8_192);
    let (shell, shell_arg) = if cfg!(target_os = "windows") {
        ("cmd", "/c")
    } else {
        ("sh", "-c")
    };

    // 1) create
    let terminal_id = match server
        .terminal_create(
            &session_id,
            shell,
            vec![shell_arg.to_string(), cmd.to_string()],
            cwd,
            None,
            Some(byte_limit),
        )
        .await
    {
        Ok(id) => id,
        Err(e) => {
            return Some(Err(anyhow!(
                "ACP terminal/create failed ({}): {}",
                e.code,
                e.message
            )));
        }
    };

    // 2) poll output until exit, with overall timeout.
    let poll_interval = Duration::from_millis(100);
    let deadline = std::time::Instant::now() + Duration::from_secs(timeout_secs);
    // Poll the client's terminal buffer until the process exits. The final
    // buffer snapshot + exit status fall out of the loop via `break` so the
    // compiler's unused-assignment analysis doesn't flag the intermediate
    // per-poll writes.
    let (last_output, exit_code, signal): (String, Option<i32>, Option<String>) = loop {
        if std::time::Instant::now() >= deadline {
            // Timed out — try to kill, then release; surface the timeout.
            let _ = server.terminal_kill(&session_id, &terminal_id).await;
            let _ = server.terminal_release(&session_id, &terminal_id).await;
            return Some(Err(anyhow!(
                "ACP terminal command timed out after {}s",
                timeout_secs
            )));
        }
        match server.terminal_output(&session_id, &terminal_id).await {
            Ok(resp) => {
                if let Some(status) = resp.exit_status {
                    break (resp.output, status.exit_code, status.signal);
                }
            }
            Err(e) => {
                let _ = server.terminal_release(&session_id, &terminal_id).await;
                return Some(Err(anyhow!(
                    "ACP terminal/output failed ({}): {}",
                    e.code,
                    e.message
                )));
            }
        }
        tokio::time::sleep(poll_interval).await;
    };

    // 3) release (best-effort; failure here is a leak on the client side but
    //    shouldn't fail the tool call since we already have output).
    let _ = server.terminal_release(&session_id, &terminal_id).await;

    // Format output: empty buffer falls back to "exit code N" (matches local).
    let mut output = last_output;
    if output.is_empty() {
        output = match (exit_code, signal.as_ref()) {
            (Some(code), _) => format!("exit code {}", code),
            (None, Some(sig)) => format!("killed by signal {}", sig),
            (None, None) => "exited (no status)".to_string(),
        };
    }
    if output.chars().count() > max_output_chars {
        const KEEP_FIRST: usize = 1000;
        const KEEP_LAST: usize = 2000;
        let n = output.chars().count();
        if n > KEEP_FIRST + KEEP_LAST {
            let first: String = output.chars().take(KEEP_FIRST).collect();
            let last: String = output.chars().skip(n.saturating_sub(KEEP_LAST)).collect();
            let trimmed = n - KEEP_FIRST - KEEP_LAST;
            output = format!("{}\n[... {} chars trimmed ...]\n{}", first, trimmed, last);
        } else {
            output = output.chars().take(max_output_chars).collect();
        }
    }
    Some(Ok(AcpShellResult { output, exit_code }))
}

/// Ask the client's user for permission to run `tool_name` with `input`. This
/// is the hook point that tool middleware calls before executing any write
/// tool. Behavior depends on the ambient context:
///
/// - Not in ACP mode → `Allow` (non-ACP launches should behave normally).
/// - No current session → `Allow` (between prompts; shouldn't happen in
///   practice but we don't want to brick background housekeeping tools).
/// - Sticky allow cached for this tool → `Allow` (no prompt).
/// - Sticky deny cached for this tool → `Deny` (no prompt; fail-closed).
/// - Otherwise → RPC to the client, cache the outcome if sticky, return it.
///
/// RPC failures (timeout, disconnect, malformed response) map to `Deny` — the
/// default posture is fail-closed so a broken editor connection can't be used
/// to silently approve writes.
pub async fn acp_permission_gate(tool_name: &str, input: &Value) -> AcpPermissionResult {
    let Some(server) = current_acp_server() else {
        return AcpPermissionResult::Allow;
    };
    let Some(session_id) = current_acp_session() else {
        return AcpPermissionResult::Allow;
    };

    // Check sticky cache first.
    {
        let guard = server.sessions.lock().await;
        if let Some(entry) = guard.get(&session_id) {
            if let Some(decision) = entry.permission_decisions.get(tool_name) {
                return match decision {
                    StickyDecision::AllowAlways => AcpPermissionResult::Allow,
                    StickyDecision::DenyAlways => AcpPermissionResult::Deny {
                        reason: format!(
                            "tool '{}' was previously denied by user for this session",
                            tool_name
                        ),
                    },
                };
            }
        }
    }

    // No cached decision — RPC the client. Use a unique tool_call_id for
    // observability; upstream integrations can correlate if they pass one in.
    let tool_call_id = format!("gate-{}", uuid::Uuid::new_v4());
    let outcome = server
        .request_permission(&session_id, &tool_call_id, tool_name, input.clone())
        .await;

    // Record sticky decisions so we don't re-prompt forever.
    let (allow, sticky) = (outcome.is_allowed(), outcome.is_sticky());
    if sticky {
        let mut guard = server.sessions.lock().await;
        if let Some(entry) = guard.get_mut(&session_id) {
            let decision = if allow {
                StickyDecision::AllowAlways
            } else {
                // Note: current is_sticky() only matches "allow_always" so this branch
                // isn't reachable today, but kept for future "deny_always" option ids.
                StickyDecision::DenyAlways
            };
            entry
                .permission_decisions
                .insert(tool_name.to_string(), decision);
        }
    }

    if allow {
        AcpPermissionResult::Allow
    } else {
        AcpPermissionResult::Deny {
            reason: match &outcome {
                PermissionOutcome::Cancelled => {
                    "user cancelled permission prompt (fail-closed)".to_string()
                }
                PermissionOutcome::Selected { option_id } => {
                    format!("user selected '{}' (not an allow option)", option_id)
                }
            },
        }
    }
}

/// Per-session in-memory state. The cancel channel is used by `session/cancel`;
/// the metadata is surfaced by `session/list`; `current_mode` and
/// `config_values` are set via `session/set_mode` and `session/set_config_option`;
/// `permission_decisions` is the sticky-decision cache for
/// `session/request_permission` (tool_name → AllowAlways / DenyAlways).
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
    /// Sticky permission decisions for tools the user pre-approved or pre-denied
    /// for this session. Read by `acp_permission_gate` to skip prompting the
    /// user when a "remember this choice" option was selected.
    pub permission_decisions: HashMap<String, StickyDecision>,
    /// MCP servers the client requested for this session via `session/new` or
    /// `session/load`. Persisted so `session/load` in a fresh process knows
    /// what to re-spawn. Stored as `(name, command, args)`.
    pub requested_mcp_servers: Vec<(String, String, Vec<String>)>,
    /// Live per-session MCP server pool. `None` when the client didn't
    /// request any servers. `Arc` so `handle_session_prompt` can clone a
    /// reference into the agent loop's `AcpMcpProxyTool`s without moving
    /// the pool out of the SessionEntry. Dropped when the SessionEntry is
    /// removed from the sessions map AND every proxy tool from the last
    /// turn has been released — the Drop cascade then SIGKILLs each child.
    /// Not serialized (children can't roundtrip across process restarts;
    /// `session/load` respawns from `requested_mcp_servers`).
    pub mcp_pool: Option<std::sync::Arc<crate::mcp_bridge::SessionMcpPool>>,
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
                let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
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
    /// Client capabilities extracted from the initial `initialize` request.
    /// `None` until initialize has been received; tool middleware falls back
    /// to local execution until capabilities are known.
    client_capabilities: Arc<Mutex<Option<ClientCapabilities>>>,
    /// Directory where session JSON files live. `None` disables persistence.
    /// Per-instance (set at construction) so tests can't race each other on
    /// a process-wide CHUMP_HOME env var.
    persist_dir: Option<std::path::PathBuf>,
}

impl AcpServer {
    /// Production constructor. Reads CHUMP_HOME / CHUMP_REPO to decide whether
    /// to enable persistence. When running as `chump --acp` with a configured
    /// home, sessions survive across process restarts; without, persistence
    /// is disabled and session/load only works within the same process.
    pub fn new(writer_tx: mpsc::UnboundedSender<String>) -> Self {
        Self::new_with_persist_dir(writer_tx, resolve_persist_dir_from_env())
    }

    /// Construct with an explicit persist directory (or None to disable).
    /// Used by tests to scope persistence per-instance instead of relying
    /// on the process-wide CHUMP_HOME env var.
    pub fn new_with_persist_dir(
        writer_tx: mpsc::UnboundedSender<String>,
        persist_dir: Option<std::path::PathBuf>,
    ) -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            writer_tx,
            pending_requests: Arc::new(Mutex::new(HashMap::new())),
            request_id_counter: Arc::new(AtomicU64::new(1)),
            client_capabilities: Arc::new(Mutex::new(None)),
            persist_dir,
        }
    }

    /// Persist helper that uses this server's `persist_dir`. No-op when None.
    fn persist(&self, session: &PersistedSession) {
        if let Some(dir) = &self.persist_dir {
            persist_session_sync_to(dir, session);
        }
    }

    /// Load a single persisted session using this server's `persist_dir`.
    fn load_persisted(&self, session_id: &str) -> Option<PersistedSession> {
        self.persist_dir
            .as_ref()
            .and_then(|dir| load_persisted_session_from(dir, session_id))
    }

    /// Enumerate all persisted sessions using this server's `persist_dir`.
    fn load_all_persisted(&self) -> Vec<PersistedSession> {
        self.persist_dir
            .as_ref()
            .map(|dir| load_all_persisted_sessions_from(dir))
            .unwrap_or_default()
    }

    /// True when the client declared support for `fs/read_text_file`. Until
    /// initialize arrives or if the client set `read: false`, returns false.
    pub async fn client_fs_read_supported(&self) -> bool {
        self.client_capabilities
            .lock()
            .await
            .as_ref()
            .map(|c| c.fs.read)
            .unwrap_or(false)
    }

    /// True when the client declared support for `fs/write_text_file`.
    pub async fn client_fs_write_supported(&self) -> bool {
        self.client_capabilities
            .lock()
            .await
            .as_ref()
            .map(|c| c.fs.write)
            .unwrap_or(false)
    }

    /// True when the client declared support for `terminal/create` (and by
    /// extension the rest of the terminal lifecycle).
    pub async fn client_terminal_supported(&self) -> bool {
        self.client_capabilities
            .lock()
            .await
            .as_ref()
            .map(|c| c.terminal.create)
            .unwrap_or(false)
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
            tracing::warn!(id = id, "received response for unknown request id; ignored");
            return;
        };
        let outcome: RpcResult = if let Some(err) = msg.get("error") {
            let code = err
                .get("code")
                .and_then(|v| v.as_i64())
                .unwrap_or(ERROR_INTERNAL as i64) as i32;
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
            .send_rpc_request_with_timeout("terminal/wait_for_exit", v, Duration::from_secs(3600))
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
                // Extract + store client capabilities so downstream middleware
                // (file tools, shell tool) can check whether to delegate ops
                // through fs/* and terminal/* methods. Missing/partial
                // clientCapabilities is OK — ClientCapabilities::default()
                // gives us all-false fields, which means "do it locally".
                if let Some(params) = req.params.as_ref() {
                    if let Ok(init_req) =
                        serde_json::from_value::<InitializeRequest>(params.clone())
                    {
                        let mut guard = self.client_capabilities.lock().await;
                        *guard = Some(init_req.client_capabilities);
                    } else {
                        tracing::warn!(
                            "initialize: failed to parse clientCapabilities; assuming none"
                        );
                    }
                }
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
            "session/list_permissions" => {
                self.handle_session_list_permissions(id, req.params).await;
            }
            "session/clear_permission" => {
                self.handle_session_clear_permission(id, req.params).await;
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

        // Capture the client-requested MCP servers and spawn them as child
        // processes (ACP-001). Pool lives on SessionEntry; when the entry is
        // removed from the sessions map (session/cancel or AcpServer drop),
        // the pool's PersistentMcpServers' Drop impls reap each child.
        // Spawn failures are best-effort: individual servers that fail to
        // start are logged and skipped, never fatal to the session.
        let requested_mcp_servers: Vec<(String, String, Vec<String>)> = req
            .mcp_servers
            .iter()
            .map(|s| (s.name.clone(), s.command.clone(), s.args.clone()))
            .collect();
        let mcp_pool: Option<std::sync::Arc<crate::mcp_bridge::SessionMcpPool>> =
            if requested_mcp_servers.is_empty() {
                None
            } else {
                match crate::mcp_bridge::SessionMcpPool::spawn_all(&requested_mcp_servers).await {
                    Ok(pool) => {
                        tracing::info!(
                            session_id = %session_id,
                            servers_requested = requested_mcp_servers.len(),
                            servers_alive = pool.server_count(),
                            tool_count = pool.tool_count(),
                            server_names = ?pool.server_names(),
                            "ACP session/new: MCP server pool spawned"
                        );
                        Some(std::sync::Arc::new(pool))
                    }
                    Err(e) => {
                        tracing::warn!(
                            session_id = %session_id,
                            error = %e,
                            "ACP session/new: MCP pool spawn refused (hard cap or invariant); proceeding without MCP tools"
                        );
                        None
                    }
                }
            };

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
                    permission_decisions: HashMap::new(),
                    requested_mcp_servers,
                    mcp_pool,
                },
            );
            // Snapshot to disk so session/load works across process restarts.
            // mcp_pool is NOT persisted — session/load respawns from
            // requested_mcp_servers.
            if let Some(entry) = guard.get(&session_id) {
                self.persist(&PersistedSession::from_entry(&session_id, entry));
            }
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

        // Verify the session exists. If not in memory, try to load from disk —
        // this is the cross-process persistence path that lets clients resume
        // after Chump was restarted. If neither hits, return INVALID_PARAMS so
        // the client falls back to session/new.
        {
            let mut guard = self.sessions.lock().await;
            if guard.contains_key(&session_id) {
                if let Some(entry) = guard.get_mut(&session_id) {
                    // In-memory hit: touch + refresh cancel channel.
                    let (cancel_tx, _cancel_rx) = mpsc::unbounded_channel::<()>();
                    entry.cancel_tx = cancel_tx;
                    entry.last_accessed_at = now.clone();
                    if !req.cwd.is_empty() {
                        entry.cwd = req.cwd.clone();
                    }
                    self.persist(&PersistedSession::from_entry(&session_id, entry));
                }
            } else if let Some(persisted) = self.load_persisted(&session_id) {
                // Disk hit: reconstitute into memory with fresh cancel channel.
                let (cancel_tx, _cancel_rx) = mpsc::unbounded_channel::<()>();
                let (sid, mut entry) = persisted.into_entry(cancel_tx);
                entry.last_accessed_at = now.clone();
                if !req.cwd.is_empty() {
                    entry.cwd = req.cwd.clone();
                }
                // ACP-001: respawn the MCP pool from the persisted config so
                // session/load across processes has the same tool surface as
                // session/new. Failures are logged, not fatal.
                if !entry.requested_mcp_servers.is_empty() {
                    match crate::mcp_bridge::SessionMcpPool::spawn_all(&entry.requested_mcp_servers)
                        .await
                    {
                        Ok(pool) => {
                            tracing::info!(
                                session_id = %sid,
                                servers_alive = pool.server_count(),
                                tool_count = pool.tool_count(),
                                "ACP session/load: MCP server pool respawned"
                            );
                            entry.mcp_pool = Some(std::sync::Arc::new(pool));
                        }
                        Err(e) => {
                            tracing::warn!(
                                session_id = %sid,
                                error = %e,
                                "ACP session/load: MCP pool respawn refused"
                            );
                        }
                    }
                }
                self.persist(&PersistedSession::from_entry(&sid, &entry));
                guard.insert(sid, entry);
            } else {
                self.write_response(error_response(
                    id,
                    ERROR_INVALID_PARAMS,
                    format!("session '{}' not found", session_id),
                ));
                return;
            }
        }

        let resp = match success_response(id.clone(), build_load_session_response(&session_id)) {
            Ok(r) => r,
            Err(e) => error_response(id, ERROR_INTERNAL, e.to_string()),
        };
        self.write_response(resp);
    }

    /// Enumerate known sessions with cursor-based pagination. Sort order is
    /// most-recently-accessed first. Clients paginate by passing the last
    /// page's `nextCursor` (an opaque `sessionId`) back as `cursor` on the
    /// next call. `pageSize` defaults to `SESSION_LIST_DEFAULT_PAGE_SIZE` and
    /// is clamped to `[1, SESSION_LIST_MAX_PAGE_SIZE]`.
    async fn handle_session_list(&self, id: Value, params: Option<Value>) {
        // Empty/absent params are valid — all fields are optional.
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

        // Clamp page size to [1, MAX]. Zero or negative is coerced to default.
        let page_size = req
            .page_size
            .unwrap_or(SESSION_LIST_DEFAULT_PAGE_SIZE)
            .clamp(1, SESSION_LIST_MAX_PAGE_SIZE) as usize;

        // Pull the in-memory view first, then merge in any disk-only sessions
        // (sessions persisted by previous process runs but not yet loaded).
        // Memory wins on duplicates because it has the freshest mutable state.
        // Filters: cwd (exact match) and mode (exact match against current_mode).
        let mut sorted: Vec<SessionInfo> = {
            let guard = self.sessions.lock().await;
            let memory: Vec<SessionInfo> = guard
                .iter()
                .filter(|(_, e)| {
                    let cwd_ok = req.cwd.as_ref().map(|f| &e.cwd == f).unwrap_or(true);
                    let mode_ok = req
                        .mode
                        .as_ref()
                        .map(|m| &e.current_mode == m)
                        .unwrap_or(true);
                    cwd_ok && mode_ok
                })
                .map(|(sid, e)| SessionInfo {
                    session_id: sid.clone(),
                    cwd: e.cwd.clone(),
                    created_at: e.created_at.clone(),
                    last_accessed_at: e.last_accessed_at.clone(),
                    message_count: e.message_count,
                    current_mode: e.current_mode.clone(),
                })
                .collect();
            let memory_ids: std::collections::HashSet<String> =
                memory.iter().map(|s| s.session_id.clone()).collect();
            drop(guard);

            let disk_only: Vec<SessionInfo> = self
                .load_all_persisted()
                .into_iter()
                .filter(|p| !memory_ids.contains(&p.session_id))
                .filter(|p| {
                    let cwd_ok = req.cwd.as_ref().map(|f| &p.cwd == f).unwrap_or(true);
                    let mode_ok = req
                        .mode
                        .as_ref()
                        .map(|m| &p.current_mode == m)
                        .unwrap_or(true);
                    cwd_ok && mode_ok
                })
                .map(|p| SessionInfo {
                    session_id: p.session_id,
                    cwd: p.cwd,
                    created_at: p.created_at,
                    last_accessed_at: p.last_accessed_at,
                    message_count: p.message_count,
                    current_mode: p.current_mode,
                })
                .collect();

            let mut v: Vec<SessionInfo> = memory.into_iter().chain(disk_only).collect();
            // Primary sort: last_accessed_at desc. Tiebreaker: session_id asc
            // so pagination is stable even when timestamps collide (tests!).
            v.sort_by(|a, b| {
                b.last_accessed_at
                    .cmp(&a.last_accessed_at)
                    .then_with(|| a.session_id.cmp(&b.session_id))
            });
            v
        };

        // Apply cursor: skip past the cursor session id, if present. Unknown
        // cursors yield an empty page rather than an error — clients paging
        // over a mutating set shouldn't blow up when a session disappears.
        if let Some(cursor) = req.cursor.as_ref() {
            let pos = sorted.iter().position(|s| s.session_id == *cursor);
            match pos {
                Some(i) => sorted = sorted.split_off(i + 1),
                None => sorted.clear(),
            }
        }

        let has_more = sorted.len() > page_size;
        sorted.truncate(page_size);
        let next_cursor = if has_more {
            sorted.last().map(|s| s.session_id.clone())
        } else {
            None
        };

        let resp_body = ListSessionsResponse {
            sessions: sorted,
            next_cursor,
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
                    self.persist(&PersistedSession::from_entry(&req.session_id, entry));
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
                    self.persist(&PersistedSession::from_entry(&req.session_id, entry));
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

    /// Enumerate sticky permission decisions for a session. Editors can render
    /// these in a "Permissions" UI so users can see what they pre-approved
    /// and reset entries via `session/clear_permission`.
    async fn handle_session_list_permissions(&self, id: Value, params: Option<Value>) {
        let req: ListPermissionsRequest = match params.and_then(|p| serde_json::from_value(p).ok())
        {
            Some(r) => r,
            None => {
                self.write_response(error_response(
                    id,
                    ERROR_INVALID_PARAMS,
                    "session/list_permissions requires ListPermissionsRequest params".to_string(),
                ));
                return;
            }
        };

        let permissions: Vec<PermissionEntry> = {
            let guard = self.sessions.lock().await;
            match guard.get(&req.session_id) {
                Some(entry) => entry
                    .permission_decisions
                    .iter()
                    .map(|(tool, decision)| PermissionEntry {
                        tool_name: tool.clone(),
                        decision: match decision {
                            StickyDecision::AllowAlways => "allow_always".to_string(),
                            StickyDecision::DenyAlways => "deny_always".to_string(),
                        },
                    })
                    .collect(),
                None => {
                    self.write_response(error_response(
                        id,
                        ERROR_INVALID_PARAMS,
                        format!("session '{}' not found", req.session_id),
                    ));
                    return;
                }
            }
        };

        // Stable order: tool name asc so the UI doesn't shuffle on every fetch.
        let mut sorted = permissions;
        sorted.sort_by(|a, b| a.tool_name.cmp(&b.tool_name));
        let resp_body = ListPermissionsResponse {
            permissions: sorted,
        };
        let resp = match success_response(id.clone(), resp_body) {
            Ok(r) => r,
            Err(e) => error_response(id, ERROR_INTERNAL, e.to_string()),
        };
        self.write_response(resp);
    }

    /// Clear a single sticky decision (`tool_name = Some`) or all sticky
    /// decisions for a session (`tool_name = None`). Persists the updated
    /// session state. Useful for editor "Reset permissions" buttons.
    async fn handle_session_clear_permission(&self, id: Value, params: Option<Value>) {
        let req: ClearPermissionRequest = match params.and_then(|p| serde_json::from_value(p).ok())
        {
            Some(r) => r,
            None => {
                self.write_response(error_response(
                    id,
                    ERROR_INVALID_PARAMS,
                    "session/clear_permission requires ClearPermissionRequest params".to_string(),
                ));
                return;
            }
        };

        let cleared_count: usize = {
            let mut guard = self.sessions.lock().await;
            match guard.get_mut(&req.session_id) {
                Some(entry) => {
                    let count = match &req.tool_name {
                        Some(name) => {
                            if entry.permission_decisions.remove(name).is_some() {
                                1
                            } else {
                                0
                            }
                        }
                        None => {
                            let n = entry.permission_decisions.len();
                            entry.permission_decisions.clear();
                            n
                        }
                    };
                    entry.last_accessed_at = now_rfc3339();
                    self.persist(&PersistedSession::from_entry(&req.session_id, entry));
                    count
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
        };

        // Echo the count so editors can show "Cleared N permissions" toasts.
        let resp =
            match success_response(id.clone(), serde_json::json!({ "cleared": cleared_count })) {
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

        // Flatten all content blocks into a single text payload.
        //   - Text blocks are emitted verbatim.
        //   - Image blocks become placeholder notes (size + mime) so a text-only
        //     model knows an attachment exists and can ask about it.
        //   - Resource blocks are dereferenced via the editor's fs/read_text_file
        //     when the URI scheme matches and the client declared fs.read; falls
        //     back to a "Resource: <uri> (not fetched)" placeholder otherwise.
        // Requires at least one non-empty text/resource source so we don't run
        // an agent turn on an image-only prompt that the model can't see.
        let user_text = flatten_prompt_blocks(&session_id, &req.prompt).await;

        if user_text.trim().is_empty() {
            self.write_response(error_response(
                id,
                ERROR_INVALID_PARAMS,
                "prompt must contain at least one non-empty text or resource block".to_string(),
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

        // Snapshot the session's MCP pool (if any) BEFORE the spawn so the
        // agent loop can register session-scoped MCP tools in its per-turn
        // ToolRegistry. Cloning the Arc doesn't move the pool out of the
        // SessionEntry — the entry still owns the original, which keeps the
        // child processes alive for subsequent turns.
        let mcp_pool_for_turn: Option<std::sync::Arc<crate::mcp_bridge::SessionMcpPool>> = {
            let guard = self.sessions.lock().await;
            guard
                .get(&session_id_for_task)
                .and_then(|e| e.mcp_pool.as_ref().map(std::sync::Arc::clone))
        };

        // Scope the task-local ACP_CURRENT_SESSION inside the spawned future
        // so any tool middleware running during this turn can call
        // current_acp_session() to gate writes through request_permission.
        let session_id_local = session_id_for_task.clone();
        tokio::spawn(ACP_CURRENT_SESSION.scope(session_id_local, async move {
            let result = run_agent_turn(
                &session_id_for_task,
                &user_text,
                writer_tx.clone(),
                mcp_pool_for_turn,
            )
            .await;

            let stop_reason = match result {
                Ok(_) => StopReason::EndTurn,
                Err(e) => {
                    tracing::error!(err = %e, "ACP prompt handler error");
                    StopReason::Error
                }
            };

            let resp = match success_response(id_for_task.clone(), PromptResponse { stop_reason }) {
                Ok(r) => r,
                Err(e) => error_response(id_for_task, ERROR_INTERNAL, e.to_string()),
            };
            let s = serde_json::to_string(&resp).unwrap_or_default();
            let _ = writer_tx.send(s);
        }));
    }
}

/// Run a single agent turn, streaming session/update notifications to the writer.
///
/// `mcp_pool` is the per-session MCP server pool (or None). When Some, each
/// tool the pool advertises is wrapped in an `AcpMcpProxyTool` and inserted
/// into the agent loop's `ToolRegistry` for this turn only — so the LLM sees
/// them alongside built-in tools and can call them like any other. Cloning
/// the Arc here just bumps the refcount; the `SessionEntry` continues to own
/// the pool and the child processes.
async fn run_agent_turn(
    session_id: &str,
    user_text: &str,
    writer_tx: mpsc::UnboundedSender<String>,
    mcp_pool: Option<std::sync::Arc<crate::mcp_bridge::SessionMcpPool>>,
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

    // Extend the registry with session-scoped MCP tools (ACP-001 follow-up).
    // Each `AcpMcpProxyTool` holds its own `Arc<SessionMcpPool>`, so the LLM
    // can invoke `pool.call_tool` via the normal tool-execution path without
    // the agent loop knowing about ACP at all.
    let mut registry = build.registry;
    if let Some(ref pool) = mcp_pool {
        let proxies = crate::mcp_bridge::AcpMcpProxyTool::from_pool(std::sync::Arc::clone(pool));
        let proxy_count = proxies.len();
        for proxy in proxies {
            // Wrap in tool_middleware for timeout / circuit breaker / rate
            // limit / lease gate — same surface as all other tools.
            registry.register(crate::tool_middleware::wrap_tool(Box::new(proxy)));
        }
        if proxy_count > 0 {
            tracing::info!(
                session_id = %session_id,
                proxy_count,
                pool_server_count = pool.server_count(),
                "ACP run_agent_turn: session-scoped MCP tools registered in agent ToolRegistry"
            );
        }
    }

    let agent = crate::agent_loop::ChumpAgent::new(
        build.provider,
        registry,
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

/// Max bytes of resource content to inline into a prompt. Anything larger
/// gets a "[truncated; N bytes total]" suffix instead of being dumped into
/// the model's context window.
const RESOURCE_INLINE_LIMIT: usize = 32_768;

/// Flatten a prompt's content blocks into a single user-text payload the agent
/// loop can consume. Mixed-content prompts (text + images + resources) are the
/// norm in modern editors; the previous filter-only-text approach silently
/// dropped attachments.
///
/// Block handling:
///   - `Text { text }` → emit verbatim, then a blank line for separation
///   - `Image { data, mime_type }` → emit a placeholder noting size + mime so
///     a text-only model has *something* to acknowledge. Vision-capable model
///     wiring is V3 work — for now Chump's primary local stack is text-only.
///   - `Resource { uri }` → if the URI looks like a file path (`file://...`,
///     `/abs/path`, or `relative/path`) and we're in ACP mode with
///     `fs.read` declared, dereference via `acp_maybe_read_text_file` so the
///     editor's filesystem is the source of truth. Otherwise emit a
///     "[Resource: <uri> (not fetched)]" placeholder.
///
/// Resource content is capped at `RESOURCE_INLINE_LIMIT` bytes so a `git log`
/// reference or a 1MB log file can't blow out the context window.
async fn flatten_prompt_blocks(session_id: &str, blocks: &[ContentBlock]) -> String {
    let mut parts: Vec<String> = Vec::with_capacity(blocks.len());
    for block in blocks {
        match block {
            ContentBlock::Text { text } => {
                if !text.trim().is_empty() {
                    parts.push(text.clone());
                }
            }
            ContentBlock::Image { data, mime_type } => {
                // Size estimate: base64 expands by ~4/3, so source bytes ≈ data.len() * 3/4.
                let est_bytes = (data.len().saturating_mul(3)) / 4;
                parts.push(format!(
                    "[Image attached: {} (~{} bytes; vision not supported by current local stack)]",
                    mime_type, est_bytes
                ));
            }
            ContentBlock::Resource { uri } => {
                let resolved = resolve_resource_uri(session_id, uri).await;
                parts.push(resolved);
            }
        }
    }
    parts.join("\n\n")
}

/// Resolve a `Resource { uri }` block to inlinable text. See
/// `flatten_prompt_blocks` for the dispatch matrix; this function is the
/// per-URI side. Returns a placeholder string when the URI can't be fetched.
async fn resolve_resource_uri(session_id: &str, uri: &str) -> String {
    // Normalize file URIs to plain paths so the ACP fs/read_text_file delegation
    // can pass them straight through to the editor's resolver.
    let path_for_acp = uri.strip_prefix("file://").unwrap_or(uri);
    // Heuristic for "this looks like a file the editor can find": absolute
    // path, file:// scheme, or schemeless relative path. Don't try fetching
    // arbitrary http(s) here — that's a separate tool (read_url) for safety.
    let looks_like_file = uri.starts_with("file://")
        || path_for_acp.starts_with('/')
        || (!uri.contains("://") && !path_for_acp.is_empty());
    if !looks_like_file {
        return format!(
            "[Resource: {} (scheme not supported; use a tool to fetch)]",
            uri
        );
    }

    if let Some(result) = acp_maybe_read_text_file(path_for_acp, None, None).await {
        match result {
            Ok(content) => {
                let total = content.len();
                let body = if total > RESOURCE_INLINE_LIMIT {
                    let head: String = content.chars().take(RESOURCE_INLINE_LIMIT).collect();
                    format!(
                        "{}\n... [truncated; {} bytes total, {} inlined]",
                        head, total, RESOURCE_INLINE_LIMIT
                    )
                } else {
                    content
                };
                return format!("[Resource: {}]\n{}", uri, body);
            }
            Err(e) => {
                return format!(
                    "[Resource: {} (fetch failed: {}); ask the user to read it manually]",
                    uri, e
                );
            }
        }
    }

    // Not in ACP mode, or client doesn't declare fs.read — surface the URI
    // so the agent can decide whether to call read_file/read_url itself.
    let _ = session_id;
    format!(
        "[Resource: {} (no editor fs delegation; the agent can fetch via read_file or read_url)]",
        uri
    )
}

/// Translate a Chump AgentEvent into an ACP SessionUpdate (or None if we don't forward it).
///
/// Coverage:
///   - TextDelta / TextComplete → AgentMessageDelta / AgentMessageComplete
///   - ToolCallStart / ToolCallResult → matching ACP variants
///   - TurnComplete with `thinking_monologue` → Thinking { content }. The
///     500ms-interval `AgentEvent::Thinking` heartbeats are deliberately
///     dropped — they'd flood the wire without giving the editor anything
///     useful. The substantive chain-of-thought arrives once at end of turn.
///
/// Dropped (no useful editor mapping yet): TurnStart, ModelCallStart,
/// TurnComplete (when no monologue), TurnError (PromptResponse.stop_reason
/// already signals failure), ToolApprovalRequest (we use session/request_permission
/// instead), ToolVerificationResult, WebSessionReady.
fn chump_event_to_acp_update(event: &crate::stream_events::AgentEvent) -> Option<SessionUpdate> {
    use crate::stream_events::AgentEvent;
    match event {
        AgentEvent::TextDelta { delta } => Some(SessionUpdate::AgentMessageDelta {
            content: delta.clone(),
        }),
        // Reasoning tokens from thinking-enabled models (Qwen3 <think>, Claude extended
        // thinking) arrive as ThinkingDelta events and map to Thinking updates so ACP
        // clients can distinguish reasoning traces from final response text.
        AgentEvent::ThinkingDelta { delta } => Some(SessionUpdate::Thinking {
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
        AgentEvent::TurnComplete {
            thinking_monologue: Some(content),
            ..
        } => Some(SessionUpdate::Thinking {
            content: content.clone(),
        }),
        // Heartbeat Thinking, TurnStart/Complete-without-monologue, TurnError,
        // approval/verification events, and web-only session events are dropped.
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

    // Install this server as the current one so tool middleware can reach it
    // through `current_acp_server()` for permission gating + fs/terminal
    // delegation. Only one ACP server per process, so OnceLock is safe.
    install_current_server(server.clone());

    // Read stdin line by line.
    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin).lines();

    while let Some(line) = reader
        .next_line()
        .await
        .map_err(|e| anyhow!("stdin read: {}", e))?
    {
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
        let config = result["configOptions"]
            .as_array()
            .expect("configOptions array");
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
        // No persist_dir → pure in-memory server; session/list sees nothing
        // from disk because disk isn't even consulted.
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
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
        let server = AcpServer::new_with_persist_dir(tx, None);
        let req = r#"{"jsonrpc":"2.0","id":31,"method":"session/list"}"#;
        server.handle_message(req).await;
        let resp_str = rx.recv().await.expect("list response");
        let resp = parse_response(&resp_str);
        assert!(resp.error.is_none(), "missing params should be OK");
    }

    #[tokio::test]
    async fn session_list_returns_created_sessions() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);

        // Create two sessions.
        let req1 = r#"{"jsonrpc":"2.0","id":40,"method":"session/new","params":{"cwd":"/repo/a","mcpServers":[]}}"#;
        server.handle_message(req1).await;
        let r1 = parse_response(&rx.recv().await.unwrap());
        let sid1 = r1.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let req2 = r#"{"jsonrpc":"2.0","id":41,"method":"session/new","params":{"cwd":"/repo/b","mcpServers":[]}}"#;
        server.handle_message(req2).await;
        let r2 = parse_response(&rx.recv().await.unwrap());
        let sid2 = r2.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

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
        let filter_req =
            r#"{"jsonrpc":"2.0","id":43,"method":"session/list","params":{"cwd":"/repo/a"}}"#;
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

    // ── session/list pagination tests ─────────────────────────────────

    /// Page size caps the result set and nextCursor points at the last item
    /// when there are more sessions to come.
    #[tokio::test]
    async fn session_list_paginates_by_page_size() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);

        // Create 5 sessions. Each gets a distinct session_id; last_accessed_at
        // may collide at second precision — the secondary sort by session_id
        // keeps ordering stable.
        let mut expected_ids: Vec<String> = Vec::new();
        for i in 0..5 {
            let req = format!(
                r#"{{"jsonrpc":"2.0","id":{},"method":"session/new","params":{{"cwd":"/r{}","mcpServers":[]}}}}"#,
                100 + i,
                i
            );
            server.handle_message(&req).await;
            let resp = parse_response(&rx.recv().await.unwrap());
            expected_ids.push(
                resp.result.unwrap()["sessionId"]
                    .as_str()
                    .unwrap()
                    .to_string(),
            );
        }

        // Page 1: size=2 → get 2 sessions + nextCursor.
        let req = r#"{"jsonrpc":"2.0","id":200,"method":"session/list","params":{"pageSize":2}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        let result = resp.result.unwrap();
        let sessions = result["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 2);
        let next = result["nextCursor"].as_str().expect("nextCursor present");
        assert_eq!(
            next,
            sessions[1]["sessionId"].as_str().unwrap(),
            "cursor should be last item of page"
        );

        // Page 2: pass cursor, get next 2.
        let req = format!(
            r#"{{"jsonrpc":"2.0","id":201,"method":"session/list","params":{{"pageSize":2,"cursor":"{}"}}}}"#,
            next
        );
        server.handle_message(&req).await;
        let resp2 = parse_response(&rx.recv().await.unwrap());
        let r2 = resp2.result.unwrap();
        assert_eq!(r2["sessions"].as_array().unwrap().len(), 2);
        // nextCursor present because 5th item still remains.
        assert!(r2["nextCursor"].is_string());

        // Page 3: last item, no more pages.
        let cursor_2 = r2["nextCursor"].as_str().unwrap().to_string();
        let req = format!(
            r#"{{"jsonrpc":"2.0","id":202,"method":"session/list","params":{{"pageSize":2,"cursor":"{}"}}}}"#,
            cursor_2
        );
        server.handle_message(&req).await;
        let resp3 = parse_response(&rx.recv().await.unwrap());
        let r3 = resp3.result.unwrap();
        assert_eq!(r3["sessions"].as_array().unwrap().len(), 1);
        assert!(
            r3.get("nextCursor").map(|v| v.is_null()).unwrap_or(true),
            "no cursor on final page: {:?}",
            r3
        );
    }

    /// Oversize pageSize is clamped; massive requests can't DoS the server.
    #[tokio::test]
    async fn session_list_clamps_page_size() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);

        // Create 3 sessions.
        for i in 0..3 {
            let req = format!(
                r#"{{"jsonrpc":"2.0","id":{},"method":"session/new","params":{{"cwd":"/r{}","mcpServers":[]}}}}"#,
                300 + i,
                i
            );
            server.handle_message(&req).await;
            let _ = rx.recv().await.unwrap();
        }

        // pageSize=99999 → clamped to MAX (200), but we only have 3, so all 3 returned.
        let req =
            r#"{"jsonrpc":"2.0","id":310,"method":"session/list","params":{"pageSize":99999}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert_eq!(
            resp.result.unwrap()["sessions"].as_array().unwrap().len(),
            3
        );
    }

    /// Unknown cursor returns empty page (not an error) so iterators don't
    /// blow up when a session is evicted mid-pagination.
    #[tokio::test]
    async fn session_list_unknown_cursor_returns_empty() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);

        let req = r#"{"jsonrpc":"2.0","id":320,"method":"session/new","params":{"cwd":"/r","mcpServers":[]}}"#;
        server.handle_message(req).await;
        let _ = rx.recv().await.unwrap();

        let req = r#"{"jsonrpc":"2.0","id":321,"method":"session/list","params":{"cursor":"acp-ghost","pageSize":10}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_none(), "unknown cursor is not an error");
        let result = resp.result.unwrap();
        assert_eq!(result["sessions"].as_array().unwrap().len(), 0);
        assert!(result
            .get("nextCursor")
            .map(|v| v.is_null())
            .unwrap_or(true));
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
        assert_eq!(
            v1["method"], "session/update",
            "first emit is the notification"
        );
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
        assert!(
            err.message.contains("hyperdrive"),
            "message: {}",
            err.message
        );
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
            let response = format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"terminalId":"t1"}}}}"#,
                id
            );
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

    // ── Permission gate tests (session-scoped sticky cache) ───────────
    //
    // We can't easily install CURRENT_ACP_SERVER in unit tests (OnceLock is
    // process-global and we run many tests per binary). Instead these tests
    // exercise the cache + RPC logic directly against an AcpServer instance
    // by calling the server's sessions map, then calling request_permission
    // through a simulated-client task as before. Full end-to-end gate tests
    // live in the tool_middleware integration-test layer where no real ACP
    // server is installed and the gate returns Allow.

    /// Sticky-allow: if a prior turn cached AllowAlways for a tool, the next
    /// read of `permission_decisions` finds it. This mirrors what
    /// `acp_permission_gate` does on its fast path.
    #[tokio::test]
    async fn sticky_allow_cache_is_read() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = Arc::new(AcpServer::new(tx));
        // Create a session to cache against.
        let new_req = r#"{"jsonrpc":"2.0","id":400,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        // Seed a sticky AllowAlways decision.
        {
            let mut guard = server.sessions.lock().await;
            let entry = guard.get_mut(&sid).expect("entry");
            entry
                .permission_decisions
                .insert("write_file".to_string(), StickyDecision::AllowAlways);
        }

        // Direct cache read — what the gate would check first.
        let guard = server.sessions.lock().await;
        let entry = guard.get(&sid).expect("entry");
        assert_eq!(
            entry.permission_decisions.get("write_file"),
            Some(&StickyDecision::AllowAlways)
        );
    }

    /// is_sticky() + is_allowed() plumbing: when the client returns
    /// allow_always, the gate (if wired to real CURRENT_ACP_SERVER) would
    /// persist AllowAlways. We verify the sticky/allowed flags match what
    /// `acp_permission_gate` uses to decide.
    #[tokio::test]
    async fn allow_always_outcome_is_sticky_and_allowed() {
        let outcome = PermissionOutcome::Selected {
            option_id: "allow_always".to_string(),
        };
        assert!(outcome.is_allowed());
        assert!(outcome.is_sticky());
    }

    /// SessionEntry construction gets a fresh empty cache every new session
    /// (no leaks between sessions).
    #[tokio::test]
    async fn new_session_has_empty_permission_cache() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":410,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        let sid = resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let guard = server.sessions.lock().await;
        let entry = guard.get(&sid).expect("entry");
        assert!(entry.permission_decisions.is_empty());
    }

    // ── Persistence tests (cross-process session/load via disk) ───────
    //
    // Each test uses a unique temp dir for CHUMP_HOME so disk state is
    // isolated. We can't easily restore env vars across parallel-run tests,
    // so we use serial_test or scope CHUMP_HOME per-test via a guard.

    /// Test helper: create a fresh temp dir to use as this test's persist_dir.
    /// Returns the path; the caller passes it to
    /// `AcpServer::new_with_persist_dir(tx, Some(dir))`. No env vars are
    /// touched, so parallel tests can't race.
    /// Caller is responsible for cleanup (`std::fs::remove_dir_all`) when done.
    fn fresh_persist_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-acp-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("acp_sessions")
    }

    /// Round-trip: create a session, observe the JSON file on disk, parse it
    /// back via `load_persisted_session_from`.
    #[tokio::test]
    async fn session_new_persists_to_disk() {
        let dir = fresh_persist_dir();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, Some(dir.clone()));
        let req = r#"{"jsonrpc":"2.0","id":600,"method":"session/new","params":{"cwd":"/repo/x","mcpServers":[]}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        let sid = resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let path = dir.join(format!("{}.json", sid));
        assert!(path.exists(), "session file should exist at {:?}", path);

        let parsed = load_persisted_session_from(&dir, &sid).expect("loadable");
        assert_eq!(parsed.cwd, "/repo/x");
        assert_eq!(parsed.current_mode, "work");
        assert_eq!(parsed.message_count, 0);
        // Cleanup (parent of dir, since dir includes /acp_sessions suffix).
        if let Some(parent) = dir.parent() {
            let _ = std::fs::remove_dir_all(parent);
        }
    }

    /// session/load reconstitutes a session that was persisted by a prior
    /// "process" — simulated here by a second AcpServer instance reading the
    /// same persist_dir after the first one wrote the file.
    #[tokio::test]
    async fn session_load_hits_disk_when_memory_empty() {
        let dir = fresh_persist_dir();

        // First server writes a session to the shared persist dir.
        let (tx1, mut rx1) = mpsc::unbounded_channel::<String>();
        let server1 = AcpServer::new_with_persist_dir(tx1, Some(dir.clone()));
        let req = r#"{"jsonrpc":"2.0","id":700,"method":"session/new","params":{"cwd":"/repo/y","mcpServers":[]}}"#;
        server1.handle_message(req).await;
        let resp = parse_response(&rx1.recv().await.unwrap());
        let sid = resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        // Second server (separate memory map) pointed at the SAME dir.
        let (tx2, mut rx2) = mpsc::unbounded_channel::<String>();
        let server2 = AcpServer::new_with_persist_dir(tx2, Some(dir.clone()));
        let load_req = format!(
            r#"{{"jsonrpc":"2.0","id":701,"method":"session/load","params":{{"sessionId":"{}","cwd":"","mcpServers":[]}}}}"#,
            sid
        );
        server2.handle_message(&load_req).await;
        let load_resp = parse_response(&rx2.recv().await.unwrap());
        assert!(
            load_resp.error.is_none(),
            "load should succeed from disk: {:?}",
            load_resp.error
        );
        // Verify it landed in server2's memory map with the original cwd.
        let guard = server2.sessions.lock().await;
        let entry = guard.get(&sid).expect("session resurrected");
        assert_eq!(entry.cwd, "/repo/y");
        drop(guard);

        if let Some(parent) = dir.parent() {
            let _ = std::fs::remove_dir_all(parent);
        }
    }

    /// session/list merges in-memory + on-disk without dupes. We create one
    /// session via server1, then ask server2 (separate memory) to list — it
    /// should see the disk-only session.
    #[tokio::test]
    async fn session_list_merges_disk_and_memory() {
        let dir = fresh_persist_dir();

        // server1: persist session A to the shared dir.
        let (tx1, mut rx1) = mpsc::unbounded_channel::<String>();
        let server1 = AcpServer::new_with_persist_dir(tx1, Some(dir.clone()));
        server1
            .handle_message(
                r#"{"jsonrpc":"2.0","id":800,"method":"session/new","params":{"cwd":"/disk","mcpServers":[]}}"#,
            )
            .await;
        let r1 = parse_response(&rx1.recv().await.unwrap());
        let sid_a = r1.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        // server2 with separate memory map pointed at the SAME dir. Creates
        // session B (in server2 memory + also persisted to the shared dir).
        let (tx2, mut rx2) = mpsc::unbounded_channel::<String>();
        let server2 = AcpServer::new_with_persist_dir(tx2, Some(dir.clone()));
        server2
            .handle_message(
                r#"{"jsonrpc":"2.0","id":801,"method":"session/new","params":{"cwd":"/mem","mcpServers":[]}}"#,
            )
            .await;
        let r2 = parse_response(&rx2.recv().await.unwrap());
        let sid_b = r2.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        // List from server2: should see both A (disk-only) and B (memory).
        server2
            .handle_message(r#"{"jsonrpc":"2.0","id":802,"method":"session/list","params":{}}"#)
            .await;
        let list_resp = parse_response(&rx2.recv().await.unwrap());
        let sessions = list_resp.result.unwrap()["sessions"]
            .as_array()
            .unwrap()
            .clone();
        let ids: std::collections::HashSet<String> = sessions
            .iter()
            .map(|s| s["sessionId"].as_str().unwrap().to_string())
            .collect();
        assert!(ids.contains(&sid_a), "disk-only session A should appear");
        assert!(ids.contains(&sid_b), "memory session B should appear");
        // No dupes (both servers wrote to disk; server2 should dedupe its own
        // memory entry against the disk scan).
        assert_eq!(sessions.len(), ids.len(), "no duplicate session_ids");

        if let Some(parent) = dir.parent() {
            let _ = std::fs::remove_dir_all(parent);
        }
    }

    /// session/load for an unknown id (not in memory, not on disk) still
    /// returns INVALID_PARAMS — we don't auto-create.
    #[tokio::test]
    async fn session_load_unknown_returns_invalid_params() {
        let dir = fresh_persist_dir();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, Some(dir.clone()));
        let req = r#"{"jsonrpc":"2.0","id":900,"method":"session/load","params":{"sessionId":"acp-doesnt-exist","cwd":"/x","mcpServers":[]}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
        if let Some(parent) = dir.parent() {
            let _ = std::fs::remove_dir_all(parent);
        }
    }

    /// Initialize with clientCapabilities { fs: { read: true, write: false } }
    /// stores the capability so client_fs_read_supported() returns true.
    #[tokio::test]
    async fn initialize_stores_client_capabilities() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        // Default state: no init received, all capabilities false.
        assert!(!server.client_fs_read_supported().await);
        assert!(!server.client_fs_write_supported().await);
        assert!(!server.client_terminal_supported().await);

        let req = r#"{"jsonrpc":"2.0","id":500,"method":"initialize","params":{"protocolVersion":"2026-04","clientInfo":{"name":"test","version":"0.0.1"},"clientCapabilities":{"fs":{"read":true,"write":true},"terminal":{"create":true}}}}"#;
        server.handle_message(req).await;
        let _ = rx.recv().await.unwrap(); // consume the response

        assert!(server.client_fs_read_supported().await);
        assert!(server.client_fs_write_supported().await);
        assert!(server.client_terminal_supported().await);
    }

    /// Initialize with partial capabilities: fs.read declared but fs.write absent.
    /// Verifies the default-false fall-through for missing fields.
    #[tokio::test]
    async fn initialize_partial_capabilities_default_false() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":501,"method":"initialize","params":{"protocolVersion":"2026-04","clientInfo":{"name":"t","version":"0"},"clientCapabilities":{"fs":{"read":true}}}}"#;
        server.handle_message(req).await;
        let _ = rx.recv().await.unwrap();
        assert!(server.client_fs_read_supported().await);
        assert!(
            !server.client_fs_write_supported().await,
            "write defaults to false when not declared"
        );
        assert!(!server.client_terminal_supported().await);
    }

    /// Initialize with no clientCapabilities at all (legacy clients) — all
    /// capabilities default to false; we don't crash.
    #[tokio::test]
    async fn initialize_no_capabilities_field() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new(tx);
        let req = r#"{"jsonrpc":"2.0","id":502,"method":"initialize","params":{"protocolVersion":"2026-04","clientInfo":{"name":"t","version":"0"}}}"#;
        server.handle_message(req).await;
        let _ = rx.recv().await.unwrap();
        assert!(!server.client_fs_read_supported().await);
        assert!(!server.client_fs_write_supported().await);
        assert!(!server.client_terminal_supported().await);
    }

    /// acp_maybe_read_text_file returns None when no ACP server is installed
    /// (the standalone-CLI fall-through case).
    #[tokio::test]
    async fn acp_maybe_read_returns_none_outside_acp() {
        let result = acp_maybe_read_text_file("/tmp/x", None, None).await;
        assert!(result.is_none(), "no ACP server → fall through to local");
    }

    /// acp_maybe_write_text_file returns None outside ACP mode.
    #[tokio::test]
    async fn acp_maybe_write_returns_none_outside_acp() {
        let result = acp_maybe_write_text_file("/tmp/x", "data").await;
        assert!(result.is_none());
    }

    /// acp_maybe_run_shell_cmd returns None outside ACP mode — CliTool falls
    /// through to local execution in standalone launches.
    #[tokio::test]
    async fn acp_maybe_run_shell_returns_none_outside_acp() {
        let result = acp_maybe_run_shell_cmd("echo hi", None, 5, 4000).await;
        assert!(result.is_none());
    }

    /// Gate returns Allow when there's no current ACP session (standalone CLI,
    /// web UI, etc. should not be gated).
    #[tokio::test]
    async fn gate_allows_when_no_acp_session() {
        // No CURRENT_ACP_SERVER installed in this test binary, AND no task-local
        // session either. Gate must return Allow.
        let result = acp_permission_gate("write_file", &serde_json::json!({"path":"x"})).await;
        assert_eq!(result, AcpPermissionResult::Allow);
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

    /// TurnComplete with thinking_monologue → SessionUpdate::Thinking carrying
    /// the chain-of-thought content. Without monologue, dropped.
    #[test]
    fn event_translation_emits_thinking_from_turn_complete_monologue() {
        use crate::stream_events::AgentEvent;

        let with_thinking = AgentEvent::TurnComplete {
            request_id: "r1".into(),
            full_text: "answer".into(),
            duration_ms: 100,
            tool_calls_count: 0,
            model_calls_count: 1,
            thinking_monologue: Some("step 1: think. step 2: answer.".into()),
        };
        match chump_event_to_acp_update(&with_thinking) {
            Some(SessionUpdate::Thinking { content }) => {
                assert!(content.contains("step 1"));
            }
            other => panic!("expected Thinking, got {:?}", other),
        }

        let without_thinking = AgentEvent::TurnComplete {
            request_id: "r2".into(),
            full_text: "answer".into(),
            duration_ms: 100,
            tool_calls_count: 0,
            model_calls_count: 1,
            thinking_monologue: None,
        };
        assert!(chump_event_to_acp_update(&without_thinking).is_none());
    }

    /// Heartbeat Thinking events (every 500ms during inference) are dropped to
    /// keep the wire quiet — only the substantive monologue from TurnComplete
    /// is forwarded.
    #[test]
    fn event_translation_drops_thinking_heartbeats() {
        use crate::stream_events::AgentEvent;
        let beat = AgentEvent::Thinking { elapsed_ms: 500 };
        assert!(chump_event_to_acp_update(&beat).is_none());
    }

    // ── Content block flattening tests ────────────────────────────────

    /// All-text prompt: blocks join with blank-line separators, content
    /// preserved verbatim, no fanciness.
    #[tokio::test]
    async fn flatten_text_only_joins_with_blank_lines() {
        let blocks = vec![
            ContentBlock::Text {
                text: "first".into(),
            },
            ContentBlock::Text {
                text: "second".into(),
            },
        ];
        let out = flatten_prompt_blocks("acp-test", &blocks).await;
        assert_eq!(out, "first\n\nsecond");
    }

    /// Empty text blocks are skipped (no leading/trailing blank junk).
    #[tokio::test]
    async fn flatten_skips_empty_text_blocks() {
        let blocks = vec![
            ContentBlock::Text { text: "".into() },
            ContentBlock::Text {
                text: "actual".into(),
            },
            ContentBlock::Text { text: "   ".into() },
        ];
        let out = flatten_prompt_blocks("acp-test", &blocks).await;
        assert_eq!(out, "actual");
    }

    /// Image blocks become placeholders that include mime type + estimated
    /// byte size so a text-only model knows the attachment exists.
    #[tokio::test]
    async fn flatten_image_emits_placeholder_with_size() {
        // 16 chars of base64 → ~12 bytes source.
        let blocks = vec![
            ContentBlock::Text {
                text: "look at this".into(),
            },
            ContentBlock::Image {
                data: "AAAABBBBCCCCDDDD".into(),
                mime_type: "image/png".into(),
            },
        ];
        let out = flatten_prompt_blocks("acp-test", &blocks).await;
        assert!(out.contains("look at this"));
        assert!(out.contains("[Image attached: image/png"));
        assert!(out.contains("12 bytes"), "size estimate present: {}", out);
        assert!(out.contains("vision not supported"));
    }

    /// Non-fileish URIs (custom schemes like `chump://`) emit a placeholder
    /// asking the agent to use a tool — we never silently fail to fetch.
    #[tokio::test]
    async fn flatten_resource_unknown_scheme_emits_placeholder() {
        let blocks = vec![ContentBlock::Resource {
            uri: "chump://memory/some-id".into(),
        }];
        let out = flatten_prompt_blocks("acp-test", &blocks).await;
        assert!(out.contains("chump://memory/some-id"));
        assert!(out.contains("scheme not supported"));
    }

    /// File-looking URIs without an active ACP server fall through to a
    /// "no editor fs delegation" placeholder rather than reading from local
    /// disk (which would surprise the editor's filesystem view).
    #[tokio::test]
    async fn flatten_resource_file_uri_outside_acp_emits_placeholder() {
        let blocks = vec![ContentBlock::Resource {
            uri: "file:///tmp/whatever.txt".into(),
        }];
        let out = flatten_prompt_blocks("acp-test", &blocks).await;
        assert!(out.contains("/tmp/whatever.txt"));
        // No ACP server installed in unit tests → falls through to the
        // "no editor fs delegation" branch.
        assert!(out.contains("no editor fs delegation"));
    }

    /// Mixed prompt: text + image + resource → all three slots present in
    /// the right order, joined by blank lines.
    #[tokio::test]
    async fn flatten_mixed_prompt_keeps_all_blocks_in_order() {
        let blocks = vec![
            ContentBlock::Text {
                text: "header".into(),
            },
            ContentBlock::Image {
                data: "AAAA".into(),
                mime_type: "image/jpeg".into(),
            },
            ContentBlock::Resource {
                uri: "https://example.com/api".into(),
            },
            ContentBlock::Text {
                text: "footer".into(),
            },
        ];
        let out = flatten_prompt_blocks("acp-test", &blocks).await;
        let header_pos = out.find("header").expect("header present");
        let image_pos = out.find("[Image attached").expect("image placeholder");
        let resource_pos = out.find("https://example.com").expect("resource present");
        let footer_pos = out.find("footer").expect("footer present");
        assert!(header_pos < image_pos);
        assert!(image_pos < resource_pos);
        assert!(resource_pos < footer_pos);
    }

    /// Image-only prompt produces non-empty output (the placeholder), so
    /// session/prompt won't reject it as empty. The model can then ask the
    /// user what they want done with the image.
    #[tokio::test]
    async fn flatten_image_only_prompt_is_non_empty() {
        let blocks = vec![ContentBlock::Image {
            data: "QQQQ".into(),
            mime_type: "image/png".into(),
        }];
        let out = flatten_prompt_blocks("acp-test", &blocks).await;
        assert!(!out.trim().is_empty());
    }

    /// session/new with `mcpServers` captures them onto SessionEntry rather
    /// than dropping them silently. V3 will spawn + manage; for now we just
    /// guarantee the request is observable.
    #[tokio::test]
    async fn session_new_records_requested_mcp_servers() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);

        let req = r#"{"jsonrpc":"2.0","id":700,"method":"session/new","params":{"cwd":"/repo","mcpServers":[{"name":"gh-mcp","command":"chump-mcp-github","args":["--token-env","GH_TOKEN"]},{"name":"fs-mcp","command":"chump-mcp-fs","args":[]}]}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        let sid = resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let guard = server.sessions.lock().await;
        let entry = guard.get(&sid).expect("session present");
        assert_eq!(entry.requested_mcp_servers.len(), 2);
        let (n0, c0, a0) = &entry.requested_mcp_servers[0];
        assert_eq!(n0, "gh-mcp");
        assert_eq!(c0, "chump-mcp-github");
        assert_eq!(a0, &vec!["--token-env".to_string(), "GH_TOKEN".to_string()]);
        let (n1, c1, a1) = &entry.requested_mcp_servers[1];
        assert_eq!(n1, "fs-mcp");
        assert_eq!(c1, "chump-mcp-fs");
        assert!(a1.is_empty());
    }

    /// session/new with no `mcpServers` (most editors today) leaves the field
    /// empty, no warnings. Backward-compat with the wire format users have
    /// been sending since V1.
    #[tokio::test]
    async fn session_new_empty_mcp_servers_is_fine() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
        let req = r#"{"jsonrpc":"2.0","id":701,"method":"session/new","params":{"cwd":"/repo","mcpServers":[]}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        let sid = resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();
        let guard = server.sessions.lock().await;
        assert!(guard.get(&sid).unwrap().requested_mcp_servers.is_empty());
    }

    // ── session/list_permissions + session/clear_permission tests ─────

    /// list_permissions on a fresh session returns an empty array (no
    /// pre-cached decisions yet). Sticky decisions only land via
    /// request_permission's "allow_always" outcome.
    #[tokio::test]
    async fn list_permissions_empty_for_fresh_session() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
        let new_req = r#"{"jsonrpc":"2.0","id":900,"method":"session/new","params":{"cwd":"/r","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let req = format!(
            r#"{{"jsonrpc":"2.0","id":901,"method":"session/list_permissions","params":{{"sessionId":"{}"}}}}"#,
            sid
        );
        server.handle_message(&req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["permissions"].as_array().unwrap().len(), 0);
    }

    /// list_permissions after seeding two AllowAlways decisions returns
    /// both, sorted by tool name for stable UI rendering.
    #[tokio::test]
    async fn list_permissions_returns_seeded_decisions_sorted() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
        let new_req = r#"{"jsonrpc":"2.0","id":910,"method":"session/new","params":{"cwd":"/r","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        // Seed two decisions out-of-order; expect alphabetical on the wire.
        {
            let mut guard = server.sessions.lock().await;
            let entry = guard.get_mut(&sid).unwrap();
            entry
                .permission_decisions
                .insert("write_file".into(), StickyDecision::AllowAlways);
            entry
                .permission_decisions
                .insert("git_commit".into(), StickyDecision::AllowAlways);
        }

        let req = format!(
            r#"{{"jsonrpc":"2.0","id":911,"method":"session/list_permissions","params":{{"sessionId":"{}"}}}}"#,
            sid
        );
        server.handle_message(&req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        let perms = resp.result.unwrap()["permissions"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(perms.len(), 2);
        // Sorted alphabetically.
        assert_eq!(perms[0]["toolName"].as_str().unwrap(), "git_commit");
        assert_eq!(perms[0]["decision"].as_str().unwrap(), "allow_always");
        assert_eq!(perms[1]["toolName"].as_str().unwrap(), "write_file");
    }

    /// list_permissions for an unknown session returns ERROR_INVALID_PARAMS.
    #[tokio::test]
    async fn list_permissions_unknown_session_returns_invalid_params() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
        let req = r#"{"jsonrpc":"2.0","id":920,"method":"session/list_permissions","params":{"sessionId":"acp-nope"}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
    }

    /// clear_permission with a tool_name removes just that one entry,
    /// returning `cleared: 1`. Other tools' decisions stay intact.
    #[tokio::test]
    async fn clear_permission_single_tool() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
        let new_req = r#"{"jsonrpc":"2.0","id":930,"method":"session/new","params":{"cwd":"/r","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        {
            let mut guard = server.sessions.lock().await;
            let entry = guard.get_mut(&sid).unwrap();
            entry
                .permission_decisions
                .insert("write_file".into(), StickyDecision::AllowAlways);
            entry
                .permission_decisions
                .insert("git_commit".into(), StickyDecision::AllowAlways);
        }

        let req = format!(
            r#"{{"jsonrpc":"2.0","id":931,"method":"session/clear_permission","params":{{"sessionId":"{}","toolName":"write_file"}}}}"#,
            sid
        );
        server.handle_message(&req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert_eq!(resp.result.unwrap()["cleared"], 1);

        let guard = server.sessions.lock().await;
        let entry = guard.get(&sid).unwrap();
        assert!(!entry.permission_decisions.contains_key("write_file"));
        assert!(entry.permission_decisions.contains_key("git_commit"));
    }

    /// clear_permission without `toolName` clears every sticky decision and
    /// returns the count.
    #[tokio::test]
    async fn clear_permission_all() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
        let new_req = r#"{"jsonrpc":"2.0","id":940,"method":"session/new","params":{"cwd":"/r","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        {
            let mut guard = server.sessions.lock().await;
            let entry = guard.get_mut(&sid).unwrap();
            entry
                .permission_decisions
                .insert("write_file".into(), StickyDecision::AllowAlways);
            entry
                .permission_decisions
                .insert("git_commit".into(), StickyDecision::AllowAlways);
            entry
                .permission_decisions
                .insert("run_cli".into(), StickyDecision::AllowAlways);
        }

        let req = format!(
            r#"{{"jsonrpc":"2.0","id":941,"method":"session/clear_permission","params":{{"sessionId":"{}"}}}}"#,
            sid
        );
        server.handle_message(&req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert_eq!(resp.result.unwrap()["cleared"], 3);

        let guard = server.sessions.lock().await;
        assert!(guard.get(&sid).unwrap().permission_decisions.is_empty());
    }

    /// clear_permission for a non-existent tool name returns `cleared: 0`
    /// (not an error). Idempotent.
    #[tokio::test]
    async fn clear_permission_unknown_tool_returns_zero() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
        let new_req = r#"{"jsonrpc":"2.0","id":950,"method":"session/new","params":{"cwd":"/r","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let req = format!(
            r#"{{"jsonrpc":"2.0","id":951,"method":"session/clear_permission","params":{{"sessionId":"{}","toolName":"never_seen"}}}}"#,
            sid
        );
        server.handle_message(&req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_none(), "unknown tool is not an error");
        assert_eq!(resp.result.unwrap()["cleared"], 0);
    }

    /// clear_permission for an unknown session returns INVALID_PARAMS.
    #[tokio::test]
    async fn clear_permission_unknown_session_returns_invalid_params() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);
        let req = r#"{"jsonrpc":"2.0","id":960,"method":"session/clear_permission","params":{"sessionId":"acp-nope"}}"#;
        server.handle_message(req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, ERROR_INVALID_PARAMS);
    }

    /// session/list `mode` filter returns only sessions matching the requested
    /// mode. Sessions default to "work" on session/new; we set_mode one to
    /// "research" and verify the filter splits them.
    #[tokio::test]
    async fn session_list_filter_by_mode() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);

        // Create two sessions; both default to "work".
        for i in 0..2 {
            let req = format!(
                r#"{{"jsonrpc":"2.0","id":{},"method":"session/new","params":{{"cwd":"/r{}","mcpServers":[]}}}}"#,
                970 + i,
                i
            );
            server.handle_message(&req).await;
            let _ = rx.recv().await.unwrap();
        }

        // Switch one of them to "research".
        let sid_research = {
            let guard = server.sessions.lock().await;
            let sid = guard.keys().next().unwrap().clone();
            sid
        };
        let set_req = format!(
            r#"{{"jsonrpc":"2.0","id":972,"method":"session/set_mode","params":{{"sessionId":"{}","modeId":"research"}}}}"#,
            sid_research
        );
        server.handle_message(&set_req).await;
        let _ = rx.recv().await.unwrap(); // ModeChanged notification
        let _ = rx.recv().await.unwrap(); // ack

        // List with mode=research → exactly the one we switched.
        let list_req =
            r#"{"jsonrpc":"2.0","id":973,"method":"session/list","params":{"mode":"research"}}"#;
        server.handle_message(list_req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        let sessions = resp.result.unwrap()["sessions"].as_array().unwrap().clone();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["sessionId"].as_str().unwrap(), sid_research);
        assert_eq!(sessions[0]["currentMode"].as_str().unwrap(), "research");

        // List with mode=work → exactly the other one.
        let list_req =
            r#"{"jsonrpc":"2.0","id":974,"method":"session/list","params":{"mode":"work"}}"#;
        server.handle_message(list_req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        let sessions = resp.result.unwrap()["sessions"].as_array().unwrap().clone();
        assert_eq!(sessions.len(), 1);
        assert_ne!(sessions[0]["sessionId"].as_str().unwrap(), sid_research);

        // List with no filter → both.
        let list_req = r#"{"jsonrpc":"2.0","id":975,"method":"session/list","params":{}}"#;
        server.handle_message(list_req).await;
        let resp = parse_response(&rx.recv().await.unwrap());
        assert_eq!(
            resp.result.unwrap()["sessions"].as_array().unwrap().len(),
            2
        );
    }

    /// End-to-end mock-client lifecycle test. Simulates a real ACP client by
    /// driving an AcpServer through initialize → session/new → session/set_mode
    /// → session/list → session/cancel notification → session/load (in-memory
    /// hit). Verifies that every step's response shape matches what an editor
    /// would expect, including the ModeChanged notification ordering.
    #[tokio::test]
    async fn end_to_end_mock_client_lifecycle() {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let server = AcpServer::new_with_persist_dir(tx, None);

        // 1) initialize — agent declares its capabilities.
        let init = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-04","clientInfo":{"name":"mock-editor","version":"1.0"},"clientCapabilities":{"fs":{"read":true,"write":true},"terminal":{"create":true},"permissions":{"request":true}}}}"#;
        server.handle_message(init).await;
        let init_resp = parse_response(&rx.recv().await.unwrap());
        assert!(init_resp.error.is_none(), "initialize must succeed");
        assert_eq!(
            init_resp.result.as_ref().unwrap()["agentInfo"]["name"],
            "chump"
        );
        assert!(server.client_fs_read_supported().await);
        assert!(server.client_terminal_supported().await);

        // 2) session/new — get a sessionId + modes + configOptions.
        let new_req = r#"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/repo","mcpServers":[]}}"#;
        server.handle_message(new_req).await;
        let new_resp = parse_response(&rx.recv().await.unwrap());
        let sid = new_resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        // 3) session/set_mode → ModeChanged notification + ack response.
        let set_req = format!(
            r#"{{"jsonrpc":"2.0","id":3,"method":"session/set_mode","params":{{"sessionId":"{}","modeId":"research"}}}}"#,
            sid
        );
        server.handle_message(&set_req).await;
        let note_msg = rx.recv().await.unwrap();
        let note: Value = serde_json::from_str(&note_msg).unwrap();
        assert_eq!(note["method"], "session/update");
        assert_eq!(note["params"]["update"]["type"], "mode_changed");
        assert_eq!(note["params"]["update"]["modeId"], "research");
        let set_ack = parse_response(&rx.recv().await.unwrap());
        assert!(set_ack.error.is_none());

        // 4) session/list — verify our session shows up with messageCount 0.
        let list_req = r#"{"jsonrpc":"2.0","id":4,"method":"session/list","params":{}}"#;
        server.handle_message(list_req).await;
        let list_resp = parse_response(&rx.recv().await.unwrap());
        let sessions = list_resp.result.unwrap()["sessions"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["sessionId"].as_str().unwrap(), sid);

        // 5) session/cancel notification — no response expected.
        let cancel = format!(
            r#"{{"jsonrpc":"2.0","id":null,"method":"session/cancel","params":{{"sessionId":"{}"}}}}"#,
            sid
        );
        server.handle_message(&cancel).await;
        let recv_after_cancel =
            tokio::time::timeout(std::time::Duration::from_millis(50), rx.recv()).await;
        assert!(recv_after_cancel.is_err(), "cancel must not respond");

        // 6) session/load with in-memory hit — should return configOptions + modes.
        let load_req = format!(
            r#"{{"jsonrpc":"2.0","id":6,"method":"session/load","params":{{"sessionId":"{}","cwd":"","mcpServers":[]}}}}"#,
            sid
        );
        server.handle_message(&load_req).await;
        let load_resp = parse_response(&rx.recv().await.unwrap());
        assert!(load_resp.error.is_none());
        let load_result = load_resp.result.unwrap();
        assert!(load_result.get("sessionId").is_none());
        assert!(load_result["modes"].as_array().unwrap().len() >= 3);
    }
}
