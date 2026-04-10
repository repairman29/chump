//! Per-session cost visibility: Tavily usage and model call/token counts.
//! Optional session budgets (CHUMP_SESSION_BUDGET_TAVILY, CHUMP_SESSION_BUDGET_REQUESTS) log and can inject a warning when exceeded.
//! Phase 5b: per-provider call/token tracking for daily Discord summary.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

static TAVILY_CALLS: AtomicU64 = AtomicU64::new(0);
static TAVILY_CREDITS: AtomicU64 = AtomicU64::new(0);
static MODEL_REQUESTS: AtomicU64 = AtomicU64::new(0);
static MODEL_INPUT_TOKENS: AtomicU64 = AtomicU64::new(0);
static MODEL_OUTPUT_TOKENS: AtomicU64 = AtomicU64::new(0);

static PROVIDER_CALLS: Mutex<Option<HashMap<String, (u64, u64)>>> = Mutex::new(None);

/// Record one Tavily call. Credits: 1 for basic/fast/ultra-fast, 2 for advanced.
pub fn record_tavily(calls: u64, credits: u64) {
    TAVILY_CALLS.fetch_add(calls, Ordering::Relaxed);
    TAVILY_CREDITS.fetch_add(credits, Ordering::Relaxed);
}

/// Record one model completion (request count and token usage).
pub fn record_completion(requests: u64, input_tokens: u64, output_tokens: u64) {
    MODEL_REQUESTS.fetch_add(requests, Ordering::Relaxed);
    MODEL_INPUT_TOKENS.fetch_add(input_tokens, Ordering::Relaxed);
    MODEL_OUTPUT_TOKENS.fetch_add(output_tokens, Ordering::Relaxed);
}

/// Record a provider call for daily summary (slot_name, estimated output tokens from response chars/4).
pub fn record_provider_call(slot_name: &str, estimated_tokens: u64) {
    if slot_name.is_empty() {
        return;
    }
    if let Ok(mut guard) = PROVIDER_CALLS.lock() {
        let map = guard.get_or_insert_with(HashMap::new);
        let entry = map.entry(slot_name.to_string()).or_insert((0, 0));
        entry.0 += 1;
        entry.1 = entry.1.saturating_add(estimated_tokens);
    }
}

/// Per-slot call count and estimated tokens for daily Discord summary.
pub fn provider_daily_summary() -> String {
    let mut lines: Vec<String> = if let Ok(guard) = PROVIDER_CALLS.lock() {
        guard
            .as_ref()
            .map(|m| {
                m.iter()
                    .map(|(name, (calls, tokens))| {
                        format!("{}: {} calls, ~{}k tokens", name, calls, tokens / 1000)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    } else {
        return String::new();
    };
    if lines.is_empty() {
        return String::new();
    }
    lines.sort();
    format!("Provider usage: {}.", lines.join("; "))
}

/// One-line summary for context or logs.
pub fn summary() -> String {
    let tavily = TAVILY_CALLS.load(Ordering::Relaxed);
    let credits = TAVILY_CREDITS.load(Ordering::Relaxed);
    let requests = MODEL_REQUESTS.load(Ordering::Relaxed);
    let inp = MODEL_INPUT_TOKENS.load(Ordering::Relaxed);
    let out = MODEL_OUTPUT_TOKENS.load(Ordering::Relaxed);
    format!(
        "this session: {} model requests ({} in / {} out tokens), {} Tavily calls ({} credits)",
        requests, inp, out, tavily, credits
    )
}

/// If session budgets are set and exceeded, returns a short warning to inject into context.
pub fn budget_warning() -> Option<String> {
    let tavily_budget = std::env::var("CHUMP_SESSION_BUDGET_TAVILY")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok());
    let requests_budget = std::env::var("CHUMP_SESSION_BUDGET_REQUESTS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok());
    let credits = TAVILY_CREDITS.load(Ordering::Relaxed);
    let requests = MODEL_REQUESTS.load(Ordering::Relaxed);
    let mut over = Vec::new();
    if let Some(b) = tavily_budget {
        if credits >= b {
            over.push(format!("Tavily credits at or over session budget ({})", b));
        }
    }
    if let Some(b) = requests_budget {
        if requests >= b {
            over.push(format!("model requests at or over session budget ({})", b));
        }
    }
    if over.is_empty() {
        None
    } else {
        Some(format!("Session budget exceeded: {}.", over.join("; ")))
    }
}

/// Reset counters (e.g. at start of a new session if you want per-session accounting across restarts you'd need persistence).
#[allow(dead_code)]
pub fn reset() {
    TAVILY_CALLS.store(0, Ordering::Relaxed);
    TAVILY_CREDITS.store(0, Ordering::Relaxed);
    MODEL_REQUESTS.store(0, Ordering::Relaxed);
    MODEL_INPUT_TOKENS.store(0, Ordering::Relaxed);
    MODEL_OUTPUT_TOKENS.store(0, Ordering::Relaxed);
}
