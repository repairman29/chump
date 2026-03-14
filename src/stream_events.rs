//! Events emitted during an agent turn. Sent through a channel to the SSE handler or ignored when event_tx is None.

use serde::Serialize;
use tokio::sync::mpsc;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentEvent {
    TurnStart {
        request_id: String,
        timestamp: String,
    },
    Thinking {
        elapsed_ms: u64,
    },
    #[allow(dead_code)] // reserved for future streaming UI
    TextDelta {
        delta: String,
    },
    TextComplete {
        text: String,
    },
    ToolCallStart {
        tool_name: String,
        tool_input: serde_json::Value,
        call_id: String,
    },
    ToolCallResult {
        call_id: String,
        tool_name: String,
        result: String,
        duration_ms: u64,
        success: bool,
    },
    ModelCallStart {
        round: u32,
    },
    TurnComplete {
        request_id: String,
        full_text: String,
        duration_ms: u64,
        tool_calls_count: u32,
        model_calls_count: u32,
    },
    TurnError {
        request_id: String,
        error: String,
    },
}

impl AgentEvent {
    /// SSE event name for this variant (e.g. "turn_start", "text_delta").
    pub fn event_type(&self) -> &'static str {
        match self {
            AgentEvent::TurnStart { .. } => "turn_start",
            AgentEvent::Thinking { .. } => "thinking",
            AgentEvent::TextDelta { .. } => "text_delta",
            AgentEvent::TextComplete { .. } => "text_complete",
            AgentEvent::ToolCallStart { .. } => "tool_call_start",
            AgentEvent::ToolCallResult { .. } => "tool_call_result",
            AgentEvent::ModelCallStart { .. } => "model_call_start",
            AgentEvent::TurnComplete { .. } => "turn_complete",
            AgentEvent::TurnError { .. } => "turn_error",
        }
    }
}

pub type EventSender = mpsc::UnboundedSender<AgentEvent>;
pub type EventReceiver = mpsc::UnboundedReceiver<AgentEvent>;

pub fn event_channel() -> (EventSender, EventReceiver) {
    mpsc::unbounded_channel()
}
