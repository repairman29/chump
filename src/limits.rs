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
            max,
            content.len()
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
            max,
            s.len()
        ));
    }
    Ok(())
}

/// Lightweight sanity check on model reply before using it for destructive or high-impact actions.
/// Returns Ok(()) if the reply looks valid, Err(reason) otherwise.
pub fn sanity_check_reply(text: &str) -> Result<(), String> {
    let t = text.trim();
    if t.is_empty() {
        return Err("reply is empty".to_string());
    }
    if t.chars().all(|c| c.is_whitespace()) {
        return Err("reply is only whitespace".to_string());
    }
    if t.len() >= 2 {
        if let Some(first) = t.chars().next() {
            if t.chars().all(|c| c == first) {
                return Err("reply is a single repeated character".to_string());
            }
        }
    }
    let newlines = t.matches('\n').count();
    if t.contains("Error:") && newlines >= 5 {
        return Err("reply looks like a raw error stack trace".to_string());
    }
    // Refusal / inability phrasing often indicates model didn't actually do the task
    let lower = t.to_lowercase();
    if (lower.contains("i cannot") || lower.contains("i'm unable") || lower.contains("i am unable"))
        && t.len() < 500
    {
        return Err("reply indicates inability (I cannot / I'm unable); may need retry or different prompt".to_string());
    }
    Ok(())
}
