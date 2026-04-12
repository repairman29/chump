//! Context window management: approximate token counts and trim thresholds.
//! When `CHUMP_CONTEXT_SUMMARY_THRESHOLD` / `CHUMP_CONTEXT_MAX_TOKENS` are set, the local provider
//! trims oldest messages and injects **verbatim** SQLite FTS5 excerpts (web session + memory),
//! not delegate LLM summarization.

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

/// Trim oldest messages when total approx tokens exceed this (e.g. 80% of model context). Env CHUMP_CONTEXT_SUMMARY_THRESHOLD (default 0).
/// When CHUMP_CURRENT_SLOT_CONTEXT_K > 32 (e.g. Gemini 1M), threshold is doubled so trimming kicks in later.
pub fn summary_threshold() -> usize {
    let base: usize = std::env::var("CHUMP_CONTEXT_SUMMARY_THRESHOLD")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0);
    let context_k: u32 = std::env::var("CHUMP_CURRENT_SLOT_CONTEXT_K")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0);
    if context_k > 32 && base > 0 {
        base.saturating_mul(2)
    } else {
        base
    }
}

/// Number of recent turns to keep verbatim. Env CHUMP_CONTEXT_VERBATIM_TURNS (default 0 = use CHUMP_MAX_CONTEXT_MESSAGES in provider).
pub fn verbatim_turns() -> usize {
    std::env::var("CHUMP_CONTEXT_VERBATIM_TURNS")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0)
}

/// When **`1`** / **`true`**, sliding-window memory snippets use [`crate::memory_tool::recall_for_context`]
/// (keyword + semantic + graph RRF when embed server / in-process embed is available). Otherwise FTS5 keyword only.
#[inline]
pub fn context_hybrid_memory_sliding_window() -> bool {
    std::env::var("CHUMP_CONTEXT_HYBRID_MEMORY")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// Max long-term memory lines to inject after a trim. Env **`CHUMP_CONTEXT_MEMORY_SNIPPETS`** (default **8**).
#[inline]
pub fn context_memory_snippet_limit() -> usize {
    std::env::var("CHUMP_CONTEXT_MEMORY_SNIPPETS")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(8)
}
