//! Input caps: max user message length and max tool-call args size. Configurable via env.

const DEFAULT_MAX_MESSAGE_LEN: usize = 16384;
const DEFAULT_MAX_TOOL_ARGS_LEN: usize = 32768;

/// Max user message length (chars). Env CHUMP_MAX_MESSAGE_LEN (default 16384).
pub fn max_message_len() -> usize {
    std::env::var("CHUMP_MAX_MESSAGE_LEN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_MAX_MESSAGE_LEN)
}

/// Max tool-call arguments size (bytes, as JSON). Env CHUMP_MAX_TOOL_ARGS_LEN (default 32768).
pub fn max_tool_args_len() -> usize {
    std::env::var("CHUMP_MAX_TOOL_ARGS_LEN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_MAX_TOOL_ARGS_LEN)
}

/// Returns Ok(()) if message length is within cap, else Err with user-facing message.
pub fn check_message_len(content: &str) -> Result<(), String> {
    let max = max_message_len();
    if content.len() > max {
        return Err(format!(
            "Message too long (max {} characters). You sent {}.",
            max, content.len()
        ));
    }
    Ok(())
}

/// Returns Ok(()) if serialized tool input is within cap, else Err with message.
pub fn check_tool_input_len(input: &serde_json::Value) -> Result<(), String> {
    let s = serde_json::to_string(input).unwrap_or_default();
    let max = max_tool_args_len();
    if s.len() > max {
        return Err(format!(
            "Tool input too large (max {} bytes). Got {}.",
            max, s.len()
        ));
    }
    Ok(())
}
