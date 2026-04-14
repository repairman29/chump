//! Append short, non-secret “next step” hints to user-visible agent errors (web SSE, streaming).

fn push_unique_paragraph(msg: &mut String, addition: &str) {
    if addition.is_empty() {
        return;
    }
    let trim_add = addition.trim();
    if msg.contains(trim_add) {
        return;
    }
    if !msg.ends_with('\n') && !msg.is_empty() {
        msg.push(' ');
    }
    msg.push_str(trim_add);
}

/// Enrich agent-facing error text with pointers to ops docs (idempotent if hints already present).
pub fn append_agent_error_hints(message: &str) -> String {
    let mut msg = message.to_string();
    let lower = msg.to_lowercase();

    if (lower.contains("connection refused")
        || lower.contains("timed out")
        || lower.contains("timeout")
        || lower.contains("tcp connect")
        || lower.contains("error sending request"))
        && !msg.contains("OPERATIONS.md")
    {
        push_unique_paragraph(
            &mut msg,
            "Check OPENAI_API_BASE is running and reachable (e.g. Ollama :11434/v1). See docs/OPERATIONS.md.",
        );
    }

    if (msg.contains("401")
        || lower.contains("models permission")
        || lower.contains("unauthorized"))
        && !msg.contains("check-providers.sh")
    {
        push_unique_paragraph(
            &mut msg,
            "Verify API keys and scopes. Run ./scripts/check-providers.sh from the Chump repo for cascade/local probes.",
        );
    }

    if (lower.contains("429")
        || lower.contains("rate limit")
        || lower.contains("too many requests"))
        && !msg.contains("PROVIDER_CASCADE.md")
    {
        push_unique_paragraph(
            &mut msg,
            "Provider may be rate-limited — wait or enable another slot in docs/PROVIDER_CASCADE.md.",
        );
    }

    if (lower.contains("context length")
        || lower.contains("maximum context")
        || lower.contains("token limit")
        || lower.contains("too many tokens")
        || lower.contains("max_tokens")
        || lower.contains("maximum tokens"))
        && !msg.contains("CHUMP_CONTEXT")
    {
        push_unique_paragraph(
            &mut msg,
            "Context may exceed model limits — shorten the thread, raise CHUMP_CONTEXT_MAX_TOKENS / CHUMP_CONTEXT_SUMMARY_THRESHOLD, or start a new session. See docs/OPERATIONS.md.",
        );
    }

    if lower.contains("circuit")
        && (lower.contains("open") || lower.contains("cooldown"))
        && !msg.contains("INFERENCE_STABILITY.md")
    {
        push_unique_paragraph(
            &mut msg,
            "Model circuit may be open after failures — see docs/INFERENCE_STABILITY.md (degraded mode).",
        );
    }

    if (lower.contains("database is locked") || lower.contains("sqlite busy"))
        && !msg.contains("single writer")
    {
        push_unique_paragraph(
            &mut msg,
            "SQLite contention — avoid multiple chump processes writing the same DB; see docs/OPERATIONS.md.",
        );
    }

    if lower.contains("exhausted")
        && lower.contains("cascade")
        && !msg.contains("PROVIDER_CASCADE.md")
    {
        push_unique_paragraph(
            &mut msg,
            "All cascade slots failed this round — check docs/PROVIDER_CASCADE.md and ./scripts/check-providers.sh.",
        );
    }

    if (lower.contains("503")
        || lower.contains("service unavailable")
        || lower.contains("model not loaded")
        || lower.contains("model is loading")
        || lower.contains("loading model"))
        && !msg.contains("INFERENCE_STABILITY.md")
    {
        push_unique_paragraph(
            &mut msg,
            "Model server may be cold, unloading, or busy — wait and retry; confirm /v1/models. See docs/INFERENCE_STABILITY.md and docs/OPERATIONS.md.",
        );
    }

    msg
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_inference_hint_for_refused() {
        let s = append_agent_error_hints("connection refused");
        assert!(s.contains("OPERATIONS.md"));
    }

    #[test]
    fn idempotent_second_call() {
        let s = append_agent_error_hints("connection refused");
        let s2 = append_agent_error_hints(&s);
        assert_eq!(s, s2);
    }

    #[test]
    fn rate_limit_hint() {
        let s = append_agent_error_hints("HTTP 429 too many requests");
        assert!(s.contains("PROVIDER_CASCADE.md"));
    }

    #[test]
    fn model_unavailable_hint() {
        let s = append_agent_error_hints("HTTP 503: model not loaded");
        assert!(s.contains("INFERENCE_STABILITY.md"));
    }
}
