//! Middleware around every tool call: timeout, per-tool circuit breaker,
//! optional **global concurrency cap** (`CHUMP_TOOL_MAX_IN_FLIGHT`),
//! optional **sliding-window rate limit** for selected tools (WP-3.2:
//! `CHUMP_TOOL_RATE_LIMIT_*`), and tracing (see docs/RUST_INFRASTRUCTURE.md).
//!
//! Today: one wrapper that applies a configurable timeout to `execute()`,
//! records timeout/errors to tool_health_db when available, and records
//! tool-call counts for observability (GET /health). Per-tool circuit breaker:
//! after N consecutive failures a tool is in cooldown for M seconds (env
//! CHUMP_TOOL_CIRCUIT_FAILURES, CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS).

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::timeout;

/// Per-tool circuit state: consecutive failures and last failure time.
fn circuit_state() -> &'static Mutex<HashMap<String, (u32, Instant)>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, (u32, Instant)>>> =
        std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn circuit_failure_threshold() -> u32 {
    std::env::var("CHUMP_TOOL_CIRCUIT_FAILURES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3)
        .max(1)
}

fn circuit_cooldown_secs() -> u64 {
    std::env::var("CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60)
        .max(1)
}

/// Returns true if the tool is in cooldown (circuit open): >= N consecutive failures and within cooldown window.
fn circuit_open(tool_name: &str) -> bool {
    let threshold = circuit_failure_threshold();
    let cooldown = Duration::from_secs(circuit_cooldown_secs());
    let guard = match circuit_state().lock() {
        Ok(g) => g,
        Err(_) => return false,
    };
    if let Some((failures, last)) = guard.get(tool_name) {
        *failures >= threshold && last.elapsed() < cooldown
    } else {
        false
    }
}

fn record_circuit_failure(tool_name: &str) {
    if let Ok(mut guard) = circuit_state().lock() {
        let entry = guard
            .entry(tool_name.to_string())
            .or_insert((0, Instant::now()));
        entry.0 += 1;
        entry.1 = Instant::now();
    }
}

fn clear_circuit(tool_name: &str) {
    if let Ok(mut guard) = circuit_state().lock() {
        guard.remove(tool_name);
    }
}

// --- Global in-flight tool concurrency (WP-3.1) ---

static TOOL_IN_FLIGHT_STATE: Mutex<Option<(usize, Arc<Semaphore>)>> = Mutex::new(None);

/// Max concurrent `execute()` calls across all tools and sessions. **`0` = unlimited** (default).
fn max_in_flight_from_env() -> usize {
    std::env::var("CHUMP_TOOL_MAX_IN_FLIGHT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

fn clamp_max_in_flight(n: usize) -> usize {
    n.min(10_000)
}

/// Semaphore matching current env (rebuilt when `CHUMP_TOOL_MAX_IN_FLIGHT` changes).
fn tool_in_flight_semaphore() -> Option<Arc<Semaphore>> {
    let cap = clamp_max_in_flight(max_in_flight_from_env());
    let mut guard = TOOL_IN_FLIGHT_STATE.lock().ok()?;
    if cap == 0 {
        *guard = None;
        return None;
    }
    let replace = match guard.as_ref() {
        None => true,
        Some((cached, _)) => *cached != cap,
    };
    if replace {
        let sem = Arc::new(Semaphore::new(cap));
        *guard = Some((cap, sem.clone()));
        Some(sem)
    } else {
        guard.as_ref().map(|(_, s)| s.clone())
    }
}

/// For **GET /health**: current configured cap, or `None` if unlimited.
pub fn max_in_flight_for_health() -> Option<usize> {
    let n = clamp_max_in_flight(max_in_flight_from_env());
    if n == 0 {
        None
    } else {
        Some(n)
    }
}

// --- Per-tool sliding-window rate limit (WP-3.2) ---

fn rate_limit_tool_names() -> Option<HashSet<String>> {
    let raw = std::env::var("CHUMP_TOOL_RATE_LIMIT_TOOLS").ok()?;
    let set: HashSet<String> = raw
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if set.is_empty() {
        None
    } else {
        Some(set)
    }
}

fn rate_limit_max_per_window() -> u32 {
    std::env::var("CHUMP_TOOL_RATE_LIMIT_MAX")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(30)
        .clamp(1, 100_000)
}

fn rate_limit_window_secs() -> u64 {
    std::env::var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(60)
        .clamp(1, 86_400)
}

fn rate_limit_timestamps() -> &'static Mutex<HashMap<String, VecDeque<Instant>>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, VecDeque<Instant>>>> =
        std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

/// If rate limiting is configured and `tool_name` is listed, enforce sliding window
/// `CHUMP_TOOL_RATE_LIMIT_MAX` calls per `CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS` per tool.
/// Records this invocation on success (counts attempts, not just successes).
pub(crate) fn enforce_tool_rate_limit(tool_name: &str) -> Result<()> {
    let Some(ref names) = rate_limit_tool_names() else {
        return Ok(());
    };
    if !names.contains(tool_name) {
        return Ok(());
    }
    let max = rate_limit_max_per_window() as usize;
    let window = Duration::from_secs(rate_limit_window_secs());
    let mut guard = rate_limit_timestamps()
        .lock()
        .map_err(|_| anyhow!("tool rate limit state poisoned"))?;
    let q = guard.entry(tool_name.to_string()).or_default();
    let now = Instant::now();
    while let Some(&front) = q.front() {
        if now.duration_since(front) > window {
            q.pop_front();
        } else {
            break;
        }
    }
    if q.len() >= max {
        return Err(anyhow!(
            "tool {} rate limited: max {} calls per {}s (sliding window)",
            tool_name,
            max,
            rate_limit_window_secs()
        ));
    }
    q.push_back(now);
    Ok(())
}

/// **GET /health:** JSON fragment when rate limiting is active, else `null`.
pub fn rate_limit_config_for_health() -> Value {
    let Some(ref names) = rate_limit_tool_names() else {
        return Value::Null;
    };
    let mut tools: Vec<&String> = names.iter().collect();
    tools.sort();
    json!({
        "tools": tools.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
        "max_per_window": rate_limit_max_per_window(),
        "window_secs": rate_limit_window_secs(),
    })
}

#[cfg(test)]
pub fn test_reset_rate_limits() {
    if let Ok(mut g) = rate_limit_timestamps().lock() {
        g.clear();
    }
}

#[cfg(test)]
pub fn test_reset_tool_in_flight(cap: Option<usize>) {
    let mut g = TOOL_IN_FLIGHT_STATE.lock().expect("tool in-flight lock");
    match cap {
        None | Some(0) => *g = None,
        Some(n) => {
            let n = clamp_max_in_flight(n);
            let sem = Arc::new(Semaphore::new(n));
            *g = Some((n, sem));
        }
    }
}

/// Global tool-call counts (tool name -> count). Used by health server.
fn tool_counts() -> &'static Mutex<HashMap<String, u64>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, u64>>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Record a tool call for observability. Call from middleware on success and failure.
pub fn record_tool_call(tool_name: &str, success: bool) {
    let key = if success {
        format!("{}_ok", tool_name)
    } else {
        format!("{}_fail", tool_name)
    };
    if let Ok(mut guard) = tool_counts().lock() {
        *guard.entry(key).or_insert(0) += 1;
    }
}

/// Snapshot of tool-call counts for GET /health. Returns total calls per tool name
/// (ok + fail combined as the single count for display).
pub fn tool_call_counts() -> HashMap<String, u64> {
    let guard = match tool_counts().lock() {
        Ok(g) => g,
        Err(_) => return HashMap::new(),
    };
    let mut out: HashMap<String, u64> = HashMap::new();
    for (key, count) in guard.iter() {
        let tool_name = key
            .strip_suffix("_ok")
            .or_else(|| key.strip_suffix("_fail"))
            .unwrap_or(key);
        *out.entry(tool_name.to_string()).or_insert(0) += count;
    }
    out
}

/// Per-tool historical latency EMA for better surprisal calibration.
/// Falls back to timeout/3 for tools with no history.
fn tool_latency_ema() -> &'static Mutex<HashMap<String, f64>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, f64>>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn tool_expected_latency(tool_name: &str, timeout_ms: u64) -> u64 {
    let fallback = timeout_ms / 3;
    if let Ok(guard) = tool_latency_ema().lock() {
        if let Some(&ema) = guard.get(tool_name) {
            return ema as u64;
        }
    }
    fallback
}

fn update_tool_latency_ema(tool_name: &str, latency_ms: u64) {
    const LATENCY_ALPHA: f64 = 0.2;
    if let Ok(mut guard) = tool_latency_ema().lock() {
        let entry = guard
            .entry(tool_name.to_string())
            .or_insert(latency_ms as f64);
        *entry = LATENCY_ALPHA * latency_ms as f64 + (1.0 - LATENCY_ALPHA) * *entry;
    }
}

/// Per-turn tool call counter for precision-regime soft cap.
static TURN_TOOL_CALLS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Reset the per-turn tool call counter (call at the start of each agent turn).
pub fn reset_turn_tool_calls() {
    TURN_TOOL_CALLS.store(0, std::sync::atomic::Ordering::Relaxed);
}

/// Check if tool calls this turn exceed the precision regime's recommended max.
/// Posts a warning to the blackboard if exceeded (once per threshold crossing).
fn check_tool_call_budget() {
    let count = TURN_TOOL_CALLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
    let max = crate::precision_controller::recommended_max_tool_calls();
    if count == max + 1 {
        crate::blackboard::post(
            crate::blackboard::Module::ToolMiddleware,
            format!(
                "Tool call budget exceeded: {} calls this turn (regime recommends max {}). Consider wrapping up.",
                count, max
            ),
            crate::blackboard::SalienceFactors {
                novelty: 0.8,
                uncertainty_reduction: 0.2,
                goal_relevance: 0.6,
                urgency: 0.7,
            },
        );
    }
}

// ── Action verification pipeline ────────────────────────────────────────

/// Result of post-execution verification for write tools.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ToolVerification {
    pub tool_name: String,
    pub call_id: String,
    pub proposed_action: String,
    pub actual_outcome: ToolOutcome,
    pub side_effects: Vec<String>,
    pub verified: bool,
    pub verification_method: VerificationMethod,
}

#[derive(Debug, Clone, serde::Serialize)]
pub enum ToolOutcome {
    Success,
    Partial,
    Failed,
}

#[derive(Debug, Clone, serde::Serialize)]
pub enum VerificationMethod {
    OutputParsing,
    SurprisalCheck,
    None,
}

/// Global storage for the last verification result; retrieved by agent_loop after tool execution.
static LAST_VERIFICATION: std::sync::OnceLock<Mutex<Option<ToolVerification>>> =
    std::sync::OnceLock::new();

fn verification_store() -> &'static Mutex<Option<ToolVerification>> {
    LAST_VERIFICATION.get_or_init(|| Mutex::new(None))
}

fn store_verification(v: ToolVerification) {
    if let Ok(mut guard) = verification_store().lock() {
        *guard = Some(v);
    }
}

/// Take the last verification result (consuming it). Called by agent_loop after tool execution.
pub fn take_last_verification() -> Option<ToolVerification> {
    verification_store().lock().ok().and_then(|mut g| g.take())
}

/// Tools that modify external state and warrant post-execution verification.
fn is_write_tool(name: &str) -> bool {
    matches!(
        name,
        "write_file" | "run_cli" | "git_commit" | "git_push" | "patch_file"
            | "git_stash" | "git_revert" | "cleanup_branches" | "merge_subtask"
    )
}

/// Verify tool execution by inspecting the output and current surprisal state.
fn verify_tool_execution(tool_name: &str, input: &Value, output: &str) -> ToolVerification {
    let proposed_action = summarize_tool_action(tool_name, input);

    // Check output for error signals
    let output_ok = !output.starts_with("Tool error:")
        && !output.starts_with("DENIED:")
        && !output.contains("Permission denied")
        && !output.contains("No such file or directory")
        && !output.contains("fatal:");

    // Check surprisal — if EMA is very high, outcome was unexpected
    let surprisal_ema = crate::surprise_tracker::current_surprisal_ema();
    let surprisal_ok = surprisal_ema < 0.6;

    let (verified, method, outcome) = if !output_ok {
        (false, VerificationMethod::OutputParsing, ToolOutcome::Failed)
    } else if !surprisal_ok {
        (false, VerificationMethod::SurprisalCheck, ToolOutcome::Partial)
    } else {
        (true, VerificationMethod::OutputParsing, ToolOutcome::Success)
    };

    let side_effects = extract_side_effects(tool_name, output);

    ToolVerification {
        tool_name: tool_name.to_string(),
        call_id: String::new(), // filled by caller if needed
        proposed_action,
        actual_outcome: outcome,
        side_effects,
        verified,
        verification_method: method,
    }
}

fn summarize_tool_action(tool_name: &str, input: &Value) -> String {
    match tool_name {
        "write_file" => format!(
            "Write to {}",
            input.get("path").and_then(|v| v.as_str()).unwrap_or("unknown")
        ),
        "run_cli" => format!(
            "Execute: {}",
            input
                .get("command")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
        ),
        "patch_file" => format!(
            "Patch {}",
            input.get("path").and_then(|v| v.as_str()).unwrap_or("unknown")
        ),
        "git_commit" => "Git commit".to_string(),
        "git_push" => "Git push".to_string(),
        _ => format!("Execute {}", tool_name),
    }
}

fn extract_side_effects(tool_name: &str, output: &str) -> Vec<String> {
    let mut effects = Vec::new();
    match tool_name {
        "write_file" | "patch_file" => effects.push("File modified on disk".to_string()),
        "git_commit" => effects.push("New commit created".to_string()),
        "git_push" => effects.push("Changes pushed to remote".to_string()),
        "run_cli" => {
            if output.contains("created") || output.contains("Created") {
                effects.push("Resource created".to_string());
            }
            if output.contains("deleted") || output.contains("removed") {
                effects.push("Resource deleted".to_string());
            }
        }
        _ => {}
    }
    effects
}

/// Detects SSRF (Server-Side Request Forgery) attempts by matching explicit RFC1918 
/// boundaries inside serialized tool inputs. Blocks attempts unless `CHUMP_ALLOW_LOCAL_SSRF` is set.
fn detect_ssrf(input: &Value) -> Result<()> {
    if std::env::var("CHUMP_ALLOW_LOCAL_SSRF").is_ok() {
        return Ok(());
    }
    let text = input.to_string();
    if !text.contains("http://") && !text.contains("https://") {
        return Ok(());
    }
    let lower = text.to_lowercase();
    let blocked = [
        "localhost", "127.0.0.1", "0.0.0.0", "10.", "192.168.", "169.254.",
        "172.16.", "172.17.", "172.18.", "172.19.", "172.2", "172.30.", "172.31."
    ];
    for p in blocked {
        if lower.contains(&format!("http://{}", p)) || lower.contains(&format!("https://{}", p)) {
            return Err(anyhow!("SSRF Protection: blocked private network access attempt to '{}'", p));
        }
    }
    Ok(())
}

/// Default timeout for a single tool execution (seconds).
pub const DEFAULT_TOOL_TIMEOUT_SECS: u64 = 30;

/// Wraps a `Tool` so that every `execute()` call is bounded by a timeout.
/// Delegates `name()`, `description()`, and `input_schema()` to the inner tool.
pub struct ToolTimeoutWrapper {
    inner: Arc<dyn Tool + Send + Sync>,
    timeout_duration: Duration,
}

impl ToolTimeoutWrapper {
    /// Wrap `inner` with the default timeout (30s, or CHUMP_TOOL_TIMEOUT_SECS).
    pub fn new(inner: Box<dyn Tool + Send + Sync>) -> Self {
        let secs = std::env::var("CHUMP_TOOL_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_TOOL_TIMEOUT_SECS);
        Self {
            inner: Arc::from(inner),
            timeout_duration: Duration::from_secs(secs),
        }
    }

    /// Wrap with a custom timeout.
    #[allow(dead_code)]
    pub fn with_timeout(inner: Box<dyn Tool + Send + Sync>, secs: u64) -> Self {
        Self {
            inner: Arc::from(inner),
            timeout_duration: Duration::from_secs(secs),
        }
    }
}

#[async_trait]
impl Tool for ToolTimeoutWrapper {
    fn name(&self) -> String {
        self.inner.name()
    }

    fn description(&self) -> String {
        self.inner.description()
    }

    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }

    #[tracing::instrument(skip(self, input), fields(tool = %self.inner.name()))]
    async fn execute(&self, input: Value) -> Result<String> {
        let name = self.inner.name();
        if circuit_open(&name) {
            return Err(anyhow!(
                "tool {} temporarily unavailable (circuit open)",
                name
            ));
        }
        let _in_flight_permit: Option<OwnedSemaphorePermit> =
            if let Some(sem) = tool_in_flight_semaphore() {
                match sem.acquire_owned().await {
                    Ok(p) => Some(p),
                    Err(_) => {
                        return Err(anyhow!(
                            "tool execution queue unavailable (concurrency semaphore closed)"
                        ));
                    }
                }
            } else {
                None
            };
        detect_ssrf(&input)?;
        enforce_tool_rate_limit(&name)?;
        let inner = self.inner.clone();
        let args_snippet = input
            .as_object()
            .and_then(|m| serde_json::to_string(m).ok())
            .map(|s| {
                if s.len() > 80 {
                    format!("{}…", &s[..80])
                } else {
                    s
                }
            })
            .unwrap_or_default();
        let call_start = Instant::now();
        let timeout_secs = crate::neuromodulation::effective_tool_timeout_secs(
            self.timeout_duration.as_secs().max(1),
        );
        let timeout_dur = Duration::from_secs(timeout_secs);
        let expected_latency_ms = tool_expected_latency(&name, timeout_dur.as_millis() as u64);
        // Clone input for post-execution verification (write tools only)
        let input_for_verify = if is_write_tool(&name) { Some(input.clone()) } else { None };
        let fut = async move { inner.execute(input).await };
        let result = match timeout(timeout_dur, fut).await {
            Ok(Ok(out)) => {
                let latency_ms = call_start.elapsed().as_millis() as u64;
                clear_circuit(&name);
                record_tool_call(&name, true);
                update_tool_latency_ema(&name, latency_ms);
                crate::introspect_tool::record_call(&name, &args_snippet, "ok");
                let sub = crate::consciousness_traits::substrate();
                sub.surprise
                    .record(&name, "ok", latency_ms, expected_latency_ms);
                sub.belief.update_tool(&name, true, latency_ms);
                crate::precision_controller::record_energy_spent(0, 1);
                check_tool_call_budget();
                // Post-execution verification for write tools
                if let Some(ref verify_input) = input_for_verify {
                    let verification = verify_tool_execution(&name, verify_input, &out);
                    if !verification.verified {
                        crate::blackboard::post(
                            crate::blackboard::Module::ToolMiddleware,
                            format!(
                                "Verification FAILED for {}: {:?} — {}",
                                verification.tool_name,
                                verification.actual_outcome,
                                verification.proposed_action,
                            ),
                            crate::blackboard::SalienceFactors {
                                novelty: 0.9,
                                uncertainty_reduction: 0.6,
                                goal_relevance: 0.9,
                                urgency: 0.8,
                            },
                        );
                    }
                    store_verification(verification);
                }
                let safe_out = crate::context_firewall::sanitize_text(&out, &name);
                Ok(safe_out)
            }
            Ok(Err(e)) => {
                let latency_ms = call_start.elapsed().as_millis() as u64;
                record_circuit_failure(&name);
                record_tool_call(&name, false);
                let raw_err = e.to_string();
                let err_msg = crate::context_firewall::sanitize_text(&raw_err, &name);
                let _ = crate::tool_health_db::record_failure(
                    name.as_str(),
                    "degraded",
                    Some(err_msg.as_str()),
                );
                crate::introspect_tool::record_call(&name, &args_snippet, "error");
                let sub = crate::consciousness_traits::substrate();
                sub.surprise
                    .record(&name, "error", latency_ms, expected_latency_ms);
                sub.belief.update_tool(&name, false, latency_ms);
                crate::precision_controller::record_energy_spent(0, 1);
                Err(anyhow!("{}", err_msg))
            }
            Err(_elapsed) => {
                let latency_ms = call_start.elapsed().as_millis() as u64;
                record_circuit_failure(&name);
                record_tool_call(&name, false);
                let msg = format!("tool timed out after {}s", timeout_secs);
                let _ = crate::tool_health_db::record_failure(
                    name.as_str(),
                    "degraded",
                    Some(msg.as_str()),
                );
                crate::introspect_tool::record_call(&name, &args_snippet, "timeout");
                let sub = crate::consciousness_traits::substrate();
                sub.surprise
                    .record(&name, "timeout", latency_ms, expected_latency_ms);
                sub.belief.update_tool(&name, false, latency_ms);
                crate::precision_controller::record_energy_spent(0, 1);
                Err(anyhow!("{}", msg))
            }
        };
        result
    }
}

/// Wrap a tool with the default timeout and optional tool-health recording.
/// Use when building the registry so every tool gets the same guarantees.
pub fn wrap_tool(inner: Box<dyn Tool + Send + Sync>) -> Box<dyn Tool + Send + Sync> {
    Box::new(ToolTimeoutWrapper::new(inner))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use std::time::Instant;

    #[test]
    #[serial]
    fn rate_limit_allows_unlisted_tool() {
        test_reset_rate_limits();
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_TOOLS", "web_search");
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_MAX", "1");
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS", "60");
        assert!(enforce_tool_rate_limit("calculator").is_ok());
        assert!(enforce_tool_rate_limit("calculator").is_ok());
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_TOOLS");
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_MAX");
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS");
        test_reset_rate_limits();
    }

    #[test]
    #[serial]
    fn rate_limit_blocks_after_max_per_window() {
        test_reset_rate_limits();
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_TOOLS", "web_search");
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_MAX", "2");
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS", "60");
        assert!(enforce_tool_rate_limit("web_search").is_ok());
        assert!(enforce_tool_rate_limit("web_search").is_ok());
        assert!(enforce_tool_rate_limit("web_search").is_err());
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_TOOLS");
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_MAX");
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS");
        test_reset_rate_limits();
    }

    #[test]
    #[serial]
    fn max_in_flight_for_health_none_when_unset() {
        std::env::remove_var("CHUMP_TOOL_MAX_IN_FLIGHT");
        test_reset_tool_in_flight(None);
        assert_eq!(max_in_flight_for_health(), None);
    }

    #[test]
    #[serial]
    fn max_in_flight_for_health_reads_env() {
        std::env::set_var("CHUMP_TOOL_MAX_IN_FLIGHT", "4");
        test_reset_tool_in_flight(None);
        assert_eq!(max_in_flight_for_health(), Some(4));
        std::env::remove_var("CHUMP_TOOL_MAX_IN_FLIGHT");
    }

    #[tokio::test]
    #[serial]
    async fn global_semaphore_serializes_second_acquire() {
        std::env::set_var("CHUMP_TOOL_MAX_IN_FLIGHT", "1");
        test_reset_tool_in_flight(None);
        let s = tool_in_flight_semaphore().expect("sem");
        let p1 = s.clone().acquire_owned().await.expect("p1");
        let s2 = tool_in_flight_semaphore().expect("sem2");
        let start = Instant::now();
        let h = tokio::spawn(async move { s2.acquire_owned().await.expect("p2") });
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(!h.is_finished(), "second acquire should wait");
        drop(p1);
        let _p2 = h.await.expect("join");
        assert!(
            start.elapsed() >= Duration::from_millis(25),
            "second task should have waited for permit"
        );
        std::env::remove_var("CHUMP_TOOL_MAX_IN_FLIGHT");
        test_reset_tool_in_flight(None);
    }

    #[test]
    #[serial]
    fn circuit_opens_then_recovers_after_cooldown() {
        use std::thread;
        use std::time::Duration;

        if let Ok(mut g) = circuit_state().lock() {
            g.clear();
        }
        std::env::set_var("CHUMP_TOOL_CIRCUIT_FAILURES", "2");
        std::env::set_var("CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS", "1");
        let tool = "__dogfood_circuit_test_tool";
        clear_circuit(tool);
        assert!(!circuit_open(tool));
        record_circuit_failure(tool);
        assert!(!circuit_open(tool));
        record_circuit_failure(tool);
        assert!(circuit_open(tool));
        thread::sleep(Duration::from_millis(1100));
        assert!(
            !circuit_open(tool),
            "after cooldown the circuit should close so calls can proceed"
        );
        clear_circuit(tool);
        std::env::remove_var("CHUMP_TOOL_CIRCUIT_FAILURES");
        std::env::remove_var("CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS");
        if let Ok(mut g) = circuit_state().lock() {
            g.remove(tool);
        }
    }
}
