//! Agent Client Protocol (ACP) adapter.
//!
//! ACP standardizes communication between code editors and coding agents, similar to
//! how LSP standardized editor/language-server communication. Built by JetBrains + Zed,
//! now supported by Claude Code, Cursor, Codex CLI, Copilot CLI, Gemini CLI, OpenCode.
//!
//! By implementing ACP, Chump becomes discoverable via the ACP Agent Registry and can
//! be used as a coding agent inside any ACP-compatible editor (Zed, JetBrains IDEs,
//! future IDE integrations).
//!
//! **Status:** V1 is a minimal viable implementation — init + session/new + session/prompt
//! with the existing agent loop as the backend. Full spec support (tool call streaming,
//! permission requests back to the IDE, terminal/filesystem operations from the IDE side)
//! is V2 work.
//!
//! **Transport:** JSON-RPC over stdio. Launch via `chump acp` subcommand (or `chump --acp`)
//! and the editor pipes stdin/stdout to the process.
//!
//! **Spec reference:** https://agentclientprotocol.com

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// ACP protocol version this implementation targets.
pub const PROTOCOL_VERSION: &str = "2026-04";

// ── Initialization ────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitializeRequest {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    #[serde(rename = "clientInfo")]
    pub client_info: ClientInfo,
    #[serde(rename = "clientCapabilities", default)]
    pub client_capabilities: ClientCapabilities,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ClientCapabilities {
    #[serde(default)]
    pub fs: FsCapabilities,
    #[serde(default)]
    pub terminal: TerminalCapabilities,
    #[serde(default)]
    pub permissions: PermissionsCapabilities,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FsCapabilities {
    #[serde(default)]
    pub read: bool,
    #[serde(default)]
    pub write: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TerminalCapabilities {
    #[serde(default)]
    pub create: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PermissionsCapabilities {
    #[serde(default)]
    pub request: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitializeResponse {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    #[serde(rename = "agentInfo")]
    pub agent_info: AgentInfo,
    #[serde(rename = "agentCapabilities")]
    pub agent_capabilities: AgentCapabilities,
    #[serde(rename = "authMethods", default)]
    pub auth_methods: Vec<AuthMethod>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AgentCapabilities {
    #[serde(default)]
    pub tools: bool,
    #[serde(default)]
    pub streaming: bool,
    #[serde(default)]
    pub modes: bool,
    #[serde(rename = "mcpServers", default)]
    pub mcp_servers: bool,
    #[serde(default)]
    pub skills: bool,  // Chump-specific extension
}

/// ACP registry-valid auth method. The `type` field must be "agent" or "terminal" for
/// inclusion in the agentclientprotocol/registry CI auth check.
///
/// - **agent**: the agent itself negotiates credentials via the ACP protocol
/// - **terminal**: the agent trusts its execution environment; user is already
///   authenticated via their shell/OS (standard for local-first agents like Chump,
///   Claude Code, Codex CLI, Cursor, Opencode)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthMethod {
    pub id: String,
    pub name: String,
    pub description: String,
    #[serde(rename = "type")]
    pub auth_type: String,
}

// ── Session management ────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewSessionRequest {
    pub cwd: String,
    #[serde(rename = "mcpServers", default)]
    pub mcp_servers: Vec<McpServerConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpServerConfig {
    pub name: String,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewSessionResponse {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "configOptions", default)]
    pub config_options: Vec<ConfigOption>,
    #[serde(default)]
    pub modes: Vec<AgentMode>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigOption {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub value: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentMode {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
}

// ── Session load / list (V1: resumption + enumeration) ────────────────

/// `session/load` — reattach to a previously-created session so the client can
/// continue interacting with it (for example after an IDE reload). Shape mirrors
/// `NewSessionRequest` plus the target `sessionId`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoadSessionRequest {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub cwd: String,
    #[serde(rename = "mcpServers", default)]
    pub mcp_servers: Vec<McpServerConfig>,
}

/// Response to `session/load`. Does not repeat the `sessionId` (caller already
/// has it). Returns the same config options and modes the session was created
/// with so the client can restore its UI state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoadSessionResponse {
    #[serde(rename = "configOptions", default)]
    pub config_options: Vec<ConfigOption>,
    #[serde(default)]
    pub modes: Vec<AgentMode>,
}

/// `session/list` — enumerate sessions available to the client. Supports
/// cursor-based pagination: the response's `nextCursor` (when present) is
/// the `sessionId` of the last item on the page; pass it back as `cursor`
/// to fetch the next page. Page size defaults to 50, capped at 200.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ListSessionsRequest {
    /// Opaque cursor for pagination — the `sessionId` of the last item on the
    /// previous page. If supplied, the next page starts AFTER this id (in the
    /// sort order: most-recently-accessed first).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    /// Filter to sessions whose `cwd` matches exactly.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Max sessions per page. Server clamps to [1, 200]. Default 50.
    #[serde(rename = "pageSize", default, skip_serializing_if = "Option::is_none")]
    pub page_size: Option<u32>,
}

/// Default page size for `session/list` when caller doesn't specify.
pub const SESSION_LIST_DEFAULT_PAGE_SIZE: u32 = 50;
/// Max page size — clients can't request more than this no matter what.
pub const SESSION_LIST_MAX_PAGE_SIZE: u32 = 200;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ListSessionsResponse {
    pub sessions: Vec<SessionInfo>,
    #[serde(rename = "nextCursor", default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

/// Session metadata returned by `session/list`. Timestamps are RFC3339 strings
/// so the wire format stays JSON-native.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub cwd: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
    #[serde(rename = "lastAccessedAt")]
    pub last_accessed_at: String,
    #[serde(rename = "messageCount", default)]
    pub message_count: u32,
}

// ── Session mutation (mid-session mode + config updates) ──────────────

/// `session/set_mode` — client asks the agent to switch the session's active
/// mode. The mode controls which context engine + prompting style Chump uses
/// for subsequent `session/prompt` calls. Server emits a `ModeChanged`
/// notification on success so other clients attached to the same session can
/// update their UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetModeRequest {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "modeId")]
    pub mode_id: String,
}

/// `session/set_config_option` — client updates a runtime-configurable option
/// (one of those advertised in `NewSessionResponse::config_options`). The
/// value's schema is option-specific; validation is performed by the agent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetConfigOptionRequest {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "optionId")]
    pub option_id: String,
    pub value: serde_json::Value,
}

/// Mode ids that Chump's session exposes. Kept in one place so dispatcher
/// validation and `build_new_session_response` can't drift.
pub const KNOWN_MODE_IDS: &[&str] = &["work", "research", "light"];

/// Config option ids that Chump's session advertises in `configOptions`.
/// Used by `session/set_config_option` to validate the `optionId` param.
pub const KNOWN_CONFIG_OPTION_IDS: &[&str] = &["context_engine", "consciousness_enabled"];

// ── Permission requests (agent → client) ──────────────────────────────

/// Agent-initiated request asking the client to surface a permission prompt to
/// the user. Sent via `session/request_permission`. The agent blocks until the
/// client responds with a `PermissionOutcome` (or the request times out).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestPermissionParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "toolCall")]
    pub tool_call: PermissionToolCall,
    pub options: Vec<PermissionOption>,
}

/// Metadata the client displays when asking the user for consent. `input` is
/// the tool's raw JSON input — clients may redact it for display but must echo
/// `tool_call_id` unchanged in observability.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionToolCall {
    #[serde(rename = "toolCallId")]
    pub tool_call_id: String,
    #[serde(rename = "toolName")]
    pub tool_name: String,
    pub input: serde_json::Value,
}

/// A user-facing option rendered in the client's permission UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionOption {
    pub id: String,
    pub label: String,
    /// Conceptual kind so clients can render icons/shortcuts consistently.
    /// Free-form; Chump uses `allow_once`, `allow_always`, `deny`.
    pub kind: String,
}

/// Standard permission option ids + kinds Chump sends. Clients may display any
/// subset.
pub fn default_permission_options() -> Vec<PermissionOption> {
    vec![
        PermissionOption {
            id: "allow_once".into(),
            label: "Allow once".into(),
            kind: "allow_once".into(),
        },
        PermissionOption {
            id: "allow_always".into(),
            label: "Allow for this session".into(),
            kind: "allow_always".into(),
        },
        PermissionOption {
            id: "deny".into(),
            label: "Deny".into(),
            kind: "deny".into(),
        },
    ]
}

/// Response body for `session/request_permission` — what the client returns to
/// the agent after the user picks an option (or dismisses the prompt).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestPermissionResponse {
    pub outcome: PermissionOutcome,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PermissionOutcome {
    /// User picked an option. `option_id` matches one of the `options` from
    /// the request (or may be an extended value the client invented).
    Selected {
        #[serde(rename = "optionId")]
        option_id: String,
    },
    /// User dismissed the prompt without choosing (closed dialog, Esc, etc.).
    Cancelled,
}

impl PermissionOutcome {
    /// True when the outcome grants execution (allow_once / allow_always).
    /// Anything else — including unknown option ids — is treated as denial.
    pub fn is_allowed(&self) -> bool {
        matches!(
            self,
            PermissionOutcome::Selected { option_id } if option_id == "allow_once" || option_id == "allow_always"
        )
    }

    /// True when the outcome should be remembered for the rest of the session.
    pub fn is_sticky(&self) -> bool {
        matches!(
            self,
            PermissionOutcome::Selected { option_id } if option_id == "allow_always"
        )
    }
}

// ── Filesystem delegation (agent → client) ────────────────────────────
//
// Optional methods Chump can call when the client's `ClientCapabilities.fs`
// declares support. Useful when the agent runs on a different host than the
// editor (e.g. SSH remote, devcontainer) — the editor reads/writes files in
// its own filesystem and ships text to/from the agent over the wire.

/// `fs/read_text_file` — agent asks the client to return the textual contents
/// of a file path the client can resolve. `line` and `limit` are 1-indexed
/// optional slicing parameters; if omitted, the client returns the whole file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadTextFileParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub path: String,
    /// 1-indexed first line to read. None = start of file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// Max number of lines to return. None = no limit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadTextFileResponse {
    pub content: String,
}

/// `fs/write_text_file` — agent asks the client to write `content` to `path`,
/// creating parent directories as needed. The client owns the on-disk
/// representation (encoding, line endings) — the agent provides UTF-8 text.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WriteTextFileParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub path: String,
    pub content: String,
}

// ── Terminal delegation (agent → client) ──────────────────────────────
//
// Spawn and observe a shell process inside the client's environment. Same
// motivation as fs/*: when Chump runs on a different host than the editor,
// commands the agent wants to execute should run in the editor's environment
// (correct cwd, env vars, secrets, network) — not on the agent's host.
//
// Lifecycle: create → output (poll) / wait_for_exit (block) → kill / release.
// The client returns a terminalId on create which the agent uses for all
// subsequent operations on that terminal.

/// One environment variable for a spawned terminal. Vec<EnvVar> rather than a
/// map so wire ordering is deterministic.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvVar {
    pub name: String,
    pub value: String,
}

/// `terminal/create` — agent asks the client to spawn a shell process.
/// `output_byte_limit` caps how much output the client retains; older bytes
/// roll off and `truncated=true` is set on `terminal/output`. Defaults to
/// client-defined.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateTerminalParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<Vec<EnvVar>>,
    #[serde(
        rename = "outputByteLimit",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub output_byte_limit: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateTerminalResponse {
    #[serde(rename = "terminalId")]
    pub terminal_id: String,
}

/// Process-exit status. `exit_code` is set on a clean exit; `signal` is set
/// when killed by signal. Both null while the process is still running.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalExitStatus {
    #[serde(
        rename = "exitCode",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub exit_code: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signal: Option<String>,
}

/// `terminal/output` — agent polls the client for accumulated output. Pull-based
/// rather than push so we don't have to invent a streaming notification channel
/// for sub-RPC events.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalOutputParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "terminalId")]
    pub terminal_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalOutputResponse {
    pub output: String,
    /// True when the client dropped older bytes to stay under `output_byte_limit`.
    #[serde(default)]
    pub truncated: bool,
    /// Set once the process has exited; None while still running.
    #[serde(
        rename = "exitStatus",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub exit_status: Option<TerminalExitStatus>,
}

/// `terminal/wait_for_exit` — agent blocks until the process exits, then gets
/// the exit status. Use a long timeout when calling.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WaitForTerminalExitParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "terminalId")]
    pub terminal_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WaitForTerminalExitResponse {
    #[serde(rename = "exitStatus")]
    pub exit_status: TerminalExitStatus,
}

/// `terminal/kill` — send SIGKILL (or platform equivalent) to the process.
/// Idempotent: safe to call after the process has already exited.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KillTerminalParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "terminalId")]
    pub terminal_id: String,
}

/// `terminal/release` — tell the client we're done with this terminal so it
/// can free the buffer + handles. Should always be called when the agent is
/// finished, even if the process is still running (kill it first if needed).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseTerminalParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "terminalId")]
    pub terminal_id: String,
}

// ── Prompt processing ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptRequest {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub prompt: Vec<ContentBlock>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ContentBlock {
    Text { text: String },
    Image { data: String, mime_type: String },
    Resource { uri: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptResponse {
    #[serde(rename = "stopReason")]
    pub stop_reason: StopReason,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    EndTurn,
    MaxTokens,
    Cancelled,
    Error,
}

// ── Session updates (notifications from agent to client) ──────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionNotification {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub update: SessionUpdate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SessionUpdate {
    AgentMessageDelta { content: String },
    AgentMessageComplete { content: String },
    ToolCallStart {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        #[serde(rename = "toolName")]
        tool_name: String,
        input: serde_json::Value,
    },
    ToolCallResult {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        result: String,
        success: bool,
    },
    Thinking { content: String },
    ModeChanged {
        #[serde(rename = "modeId")]
        mode_id: String,
    },
}

// ── JSON-RPC wire format ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: serde_json::Value,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i32,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcNotification {
    pub jsonrpc: String,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

// Standard JSON-RPC error codes
pub const ERROR_PARSE: i32 = -32700;
pub const ERROR_INVALID_REQUEST: i32 = -32600;
pub const ERROR_METHOD_NOT_FOUND: i32 = -32601;
pub const ERROR_INVALID_PARAMS: i32 = -32602;
pub const ERROR_INTERNAL: i32 = -32603;

// ── Agent handler (high-level dispatch) ───────────────────────────────

/// Build the Chump agent's initialize response. Declares our capabilities.
pub fn build_initialize_response() -> InitializeResponse {
    InitializeResponse {
        protocol_version: PROTOCOL_VERSION.to_string(),
        agent_info: AgentInfo {
            name: "chump".to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
        },
        agent_capabilities: AgentCapabilities {
            tools: true,
            streaming: true,
            modes: true,
            mcp_servers: true,
            skills: true,
        },
        // Declare terminal auth: Chump trusts its execution environment. The user is
        // already authenticated to their own system (they launched the binary via their
        // shell), so no in-protocol credential exchange is needed. This is the same
        // posture as Claude Code, Codex CLI, Cursor, and Opencode. Required for
        // inclusion in the ACP Registry (agentclientprotocol/registry).
        auth_methods: vec![AuthMethod {
            id: "terminal".to_string(),
            name: "Terminal authentication".to_string(),
            description: "User is authenticated via their shell environment; Chump is a local-first binary and trusts the invoking terminal session.".to_string(),
            auth_type: "terminal".to_string(),
        }],
    }
}

/// Build a new session response with available modes (mapped from Chump's heartbeat types
/// and context engines).
pub fn build_new_session_response(session_id: String) -> NewSessionResponse {
    NewSessionResponse {
        session_id,
        config_options: vec![
            ConfigOption {
                id: "context_engine".to_string(),
                name: "Context Engine".to_string(),
                description: Some("default | light | autonomy".to_string()),
                value: serde_json::json!("default"),
            },
            ConfigOption {
                id: "consciousness_enabled".to_string(),
                name: "Consciousness Framework".to_string(),
                description: Some("Enable belief state, surprise tracking, neuromodulation".to_string()),
                value: serde_json::json!(true),
            },
        ],
        modes: vec![
            AgentMode {
                id: "work".to_string(),
                name: "Work".to_string(),
                description: Some("General coding tasks".to_string()),
            },
            AgentMode {
                id: "research".to_string(),
                name: "Research".to_string(),
                description: Some("Synthesis across sources".to_string()),
            },
            AgentMode {
                id: "light".to_string(),
                name: "Light Chat".to_string(),
                description: Some("Fast responses, slim context".to_string()),
            },
        ],
    }
}

/// Build a load-session response for an existing session. Returns the same
/// config options and modes `build_new_session_response` uses so resumed
/// sessions surface identically to freshly-created ones in the client UI.
/// `_session_id` is accepted for forward-compatibility with per-session
/// configuration (V2 may vary modes based on saved state).
pub fn build_load_session_response(_session_id: &str) -> LoadSessionResponse {
    // Reuse new-session defaults to guarantee shape parity.
    let NewSessionResponse {
        config_options,
        modes,
        ..
    } = build_new_session_response(String::new());
    LoadSessionResponse {
        config_options,
        modes,
    }
}

/// Build a standard JSON-RPC error response.
pub fn error_response(id: serde_json::Value, code: i32, message: String) -> JsonRpcResponse {
    JsonRpcResponse {
        jsonrpc: "2.0".to_string(),
        id,
        result: None,
        error: Some(JsonRpcError {
            code,
            message,
            data: None,
        }),
    }
}

/// Build a successful JSON-RPC response.
pub fn success_response<T: Serialize>(id: serde_json::Value, result: T) -> Result<JsonRpcResponse> {
    Ok(JsonRpcResponse {
        jsonrpc: "2.0".to_string(),
        id,
        result: Some(serde_json::to_value(result)?),
        error: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_response_declares_chump_capabilities() {
        let resp = build_initialize_response();
        assert_eq!(resp.agent_info.name, "chump");
        assert!(resp.agent_capabilities.tools);
        assert!(resp.agent_capabilities.streaming);
        assert!(resp.agent_capabilities.skills);
    }

    /// Registry compliance: agentclientprotocol/registry CI requires at least one
    /// authMethod with `type` of "agent" or "terminal". Chump declares "terminal".
    #[test]
    fn initialize_auth_methods_meet_registry_requirements() {
        let resp = build_initialize_response();
        assert!(!resp.auth_methods.is_empty(), "must declare at least one authMethod");
        let has_valid_type = resp
            .auth_methods
            .iter()
            .any(|m| m.auth_type == "agent" || m.auth_type == "terminal");
        assert!(
            has_valid_type,
            "at least one authMethod must have type 'agent' or 'terminal'"
        );
    }

    /// Registry compliance: authMethod must serialize with `type` as a JSON field.
    #[test]
    fn auth_method_serializes_type_field() {
        let m = AuthMethod {
            id: "terminal".into(),
            name: "Terminal".into(),
            description: "x".into(),
            auth_type: "terminal".into(),
        };
        let v = serde_json::to_value(&m).unwrap();
        assert_eq!(v["type"], "terminal");
        assert_eq!(v["id"], "terminal");
    }

    #[test]
    fn new_session_response_has_modes() {
        let resp = build_new_session_response("test-session".to_string());
        assert_eq!(resp.session_id, "test-session");
        assert!(resp.modes.len() >= 3);
        assert!(resp.modes.iter().any(|m| m.id == "work"));
        assert!(resp.modes.iter().any(|m| m.id == "light"));
    }

    #[test]
    fn jsonrpc_request_parses() {
        let json = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#;
        let req: JsonRpcRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.method, "initialize");
        assert_eq!(req.id, serde_json::json!(1));
    }

    #[test]
    fn content_block_text_serializes() {
        let cb = ContentBlock::Text {
            text: "hello".to_string(),
        };
        let json = serde_json::to_value(&cb).unwrap();
        assert_eq!(json["type"], "text");
        assert_eq!(json["text"], "hello");
    }

    #[test]
    fn session_update_tool_call_start_serializes() {
        let update = SessionUpdate::ToolCallStart {
            tool_call_id: "tc-1".to_string(),
            tool_name: "read_file".to_string(),
            input: serde_json::json!({"path": "README.md"}),
        };
        let json = serde_json::to_value(&update).unwrap();
        assert_eq!(json["type"], "tool_call_start");
        assert_eq!(json["toolCallId"], "tc-1");
        assert_eq!(json["toolName"], "read_file");
    }

    #[test]
    fn error_response_format() {
        let resp = error_response(
            serde_json::json!(1),
            ERROR_METHOD_NOT_FOUND,
            "method not found".to_string(),
        );
        assert_eq!(resp.jsonrpc, "2.0");
        assert!(resp.error.is_some());
        let err = resp.error.unwrap();
        assert_eq!(err.code, ERROR_METHOD_NOT_FOUND);
    }

    #[test]
    fn success_response_format() {
        let resp = success_response(
            serde_json::json!("abc"),
            serde_json::json!({"result": "ok"}),
        )
        .unwrap();
        assert_eq!(resp.jsonrpc, "2.0");
        assert!(resp.result.is_some());
    }

    #[test]
    fn stop_reason_serializes_snake_case() {
        let json = serde_json::to_value(&StopReason::EndTurn).unwrap();
        assert_eq!(json, serde_json::json!("end_turn"));
    }

    #[test]
    fn load_session_response_has_same_modes_as_new() {
        let new_resp = build_new_session_response("sid-x".to_string());
        let load_resp = build_load_session_response("sid-x");
        assert_eq!(new_resp.modes.len(), load_resp.modes.len());
        assert_eq!(
            new_resp.config_options.len(),
            load_resp.config_options.len()
        );
        // sessionId is deliberately absent from LoadSessionResponse
        let v = serde_json::to_value(&load_resp).unwrap();
        assert!(v.get("sessionId").is_none());
        assert!(v.get("modes").is_some());
    }

    #[test]
    fn list_sessions_response_serializes_empty() {
        let resp = ListSessionsResponse::default();
        let v = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["sessions"], serde_json::json!([]));
        // nextCursor is omitted when None
        assert!(v.get("nextCursor").is_none());
    }

    #[test]
    fn session_info_uses_camel_case_fields() {
        let info = SessionInfo {
            session_id: "acp-1".into(),
            cwd: "/tmp".into(),
            created_at: "2026-04-15T00:00:00Z".into(),
            last_accessed_at: "2026-04-15T00:01:00Z".into(),
            message_count: 3,
        };
        let v = serde_json::to_value(&info).unwrap();
        assert_eq!(v["sessionId"], "acp-1");
        assert_eq!(v["createdAt"], "2026-04-15T00:00:00Z");
        assert_eq!(v["lastAccessedAt"], "2026-04-15T00:01:00Z");
        assert_eq!(v["messageCount"], 3);
    }

    #[test]
    fn load_session_request_parses() {
        let json = r#"{"sessionId":"acp-abc","cwd":"/tmp","mcpServers":[]}"#;
        let req: LoadSessionRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.session_id, "acp-abc");
        assert_eq!(req.cwd, "/tmp");
    }

    #[test]
    fn list_sessions_request_defaults() {
        // Empty params must still parse (both fields optional)
        let req: ListSessionsRequest = serde_json::from_str("{}").unwrap();
        assert!(req.cursor.is_none());
        assert!(req.cwd.is_none());
    }
}
