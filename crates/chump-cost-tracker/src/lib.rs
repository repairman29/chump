//! Per-session cost visibility: Tavily usage and model call/token counts.
//! Optional session budgets (CHUMP_SESSION_BUDGET_TAVILY, CHUMP_SESSION_BUDGET_REQUESTS) log and can inject a warning when exceeded.
//! Phase 5b: per-provider call/token tracking for daily Discord summary.
//! INFRA-COST-CEILING: hard spend ceiling + soft warn via CHUMP_COST_CEILING_USD / CHUMP_COST_WARN_USD.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

static TAVILY_CALLS: AtomicU64 = AtomicU64::new(0);
static TAVILY_CREDITS: AtomicU64 = AtomicU64::new(0);
static MODEL_REQUESTS: AtomicU64 = AtomicU64::new(0);
static MODEL_INPUT_TOKENS: AtomicU64 = AtomicU64::new(0);
static MODEL_OUTPUT_TOKENS: AtomicU64 = AtomicU64::new(0);

/// Accumulated session spend in micro-USD (1 USD = 1_000_000 units).
/// Updated via `add_session_cost_usd`.
static SESSION_COST_MICRO_USD: AtomicU64 = AtomicU64::new(0);

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
    SESSION_COST_MICRO_USD.store(0, Ordering::Relaxed);
}

// ── INFRA-COST-CEILING ────────────────────────────────────────────────────────

const DEFAULT_COST_CEILING_USD: f64 = 5.00;
const DEFAULT_COST_WARN_USD: f64 = 2.00;

/// Add `usd` to the session spend accumulator.
/// Call this after each provider call with the estimated cost.
pub fn add_session_cost_usd(usd: f64) {
    if usd <= 0.0 {
        return;
    }
    let micro = (usd * 1_000_000.0) as u64;
    SESSION_COST_MICRO_USD.fetch_add(micro, Ordering::Relaxed);
}

/// Current accumulated session spend in USD.
pub fn session_cost_usd() -> f64 {
    SESSION_COST_MICRO_USD.load(Ordering::Relaxed) as f64 / 1_000_000.0
}

/// Read the hard ceiling from `CHUMP_COST_CEILING_USD` (default 5.00).
pub fn cost_ceiling_usd() -> f64 {
    std::env::var("CHUMP_COST_CEILING_USD")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&v| v > 0.0)
        .unwrap_or(DEFAULT_COST_CEILING_USD)
}

/// Read the soft warn threshold from `CHUMP_COST_WARN_USD` (default 2.00).
pub fn cost_warn_usd() -> f64 {
    std::env::var("CHUMP_COST_WARN_USD")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&v| v > 0.0)
        .unwrap_or(DEFAULT_COST_WARN_USD)
}

/// Check the spend ceiling before making a provider call.
///
/// - Returns `Err(String)` if the hard ceiling has been reached (caller must NOT
///   make the API call).
/// - Returns `Ok(true)` if the soft warn threshold has been crossed but the hard
///   ceiling has not (caller should print a warning to stderr; the call is still
///   permitted).
/// - Returns `Ok(false)` if spend is below both thresholds (normal path).
///
/// The caller is responsible for actually printing the warning so that the
/// message lands on the right stderr stream.
pub fn check_ceiling() -> Result<bool, String> {
    let current = session_cost_usd();
    let ceiling = cost_ceiling_usd();
    let warn = cost_warn_usd();

    if current >= ceiling {
        return Err(format!(
            "COST CEILING REACHED: ${:.2} spent this session (hard limit: ${:.2}); \
             raise CHUMP_COST_CEILING_USD to continue",
            current, ceiling
        ));
    }

    if current >= warn {
        return Ok(true);
    }

    Ok(false)
}
