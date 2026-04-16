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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthMethod {
    pub id: String,
    pub name: String,
    pub description: String,
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
        auth_methods: vec![AuthMethod {
            id: "none".to_string(),
            name: "No authentication".to_string(),
            description: "Chump runs locally; no auth required".to_string(),
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
}
