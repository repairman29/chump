//! Context window management: approximate token counts and trim thresholds.
//! Full summarize-and-trim (replace older turns with a summary block) would require
//! a hook in the session layer (axonerai) or calling the model from the provider;
//! for now we support configurable message cap and token-based trimming in the provider.

/// Rough token approximation: chars / 4. Use for threshold checks only.
pub fn approx_token_count(text: &str) -> usize {
    text.len() / 4
}

/// Max context size in tokens (system + messages). Env CHUMP_CONTEXT_MAX_TOKENS (default 0 = no limit).
pub fn max_tokens() -> usize {
    std::env::var("CHUMP_CONTEXT_MAX_TOKENS")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0)
}

/// Use summarization/trim when total approx tokens exceed this (e.g. 80% of model context). Env CHUMP_CONTEXT_SUMMARY_THRESHOLD (default 0).
pub fn summary_threshold() -> usize {
    std::env::var("CHUMP_CONTEXT_SUMMARY_THRESHOLD")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0)
}

/// Number of recent turns to keep verbatim. Env CHUMP_CONTEXT_VERBATIM_TURNS (default 0 = use CHUMP_MAX_CONTEXT_MESSAGES in provider).
pub fn verbatim_turns() -> usize {
    std::env::var("CHUMP_CONTEXT_VERBATIM_TURNS")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0)
}
