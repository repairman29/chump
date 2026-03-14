//! Middleware around every tool call: timeout, per-tool circuit breaker,
//! and a single place to add rate limit and tracing later (see docs/RUST_INFRASTRUCTURE.md).
//!
//! Today: one wrapper that applies a configurable timeout to `execute()`,
//! records timeout/errors to tool_health_db when available, and records
//! tool-call counts for observability (GET /health). Per-tool circuit breaker:
//! after N consecutive failures a tool is in cooldown for M seconds (env
//! CHUMP_TOOL_CIRCUIT_FAILURES, CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS).

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant};
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
        let entry = guard.entry(tool_name.to_string()).or_insert((0, Instant::now()));
        entry.0 += 1;
        entry.1 = Instant::now();
    }
}

fn clear_circuit(tool_name: &str) {
    if let Ok(mut guard) = circuit_state().lock() {
        guard.remove(tool_name);
    }
}

/// Global tool-call counts (tool name -> count). Used by health server.
fn tool_counts() -> &'static Mutex<HashMap<String, u64>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, u64>>> =
        std::sync::OnceLock::new();
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

/// Default timeout for a single tool execution (seconds).
pub const DEFAULT_TOOL_TIMEOUT_SECS: u64 = 30;

/// Wraps a `Tool` so that every `execute()` call is bounded by a timeout.
/// Delegates `name()`, `description()`, and `input_schema()` to the inner tool.
pub struct ToolTimeoutWrapper {
    inner: Arc<dyn Tool + Send + Sync>,
    timeout_duration: Duration,
}

impl ToolTimeoutWrapper {
    /// Wrap `inner` with the default timeout (30s).
    pub fn new(inner: Box<dyn Tool + Send + Sync>) -> Self {
        Self {
            inner: Arc::from(inner),
            timeout_duration: Duration::from_secs(DEFAULT_TOOL_TIMEOUT_SECS),
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
        let inner = self.inner.clone();
        let fut = async move { inner.execute(input).await };
        match timeout(self.timeout_duration, fut).await {
            Ok(Ok(out)) => {
                clear_circuit(&name);
                record_tool_call(&name, true);
                Ok(out)
            }
            Ok(Err(e)) => {
                record_circuit_failure(&name);
                record_tool_call(&name, false);
                let err_msg = e.to_string();
                let _ = crate::tool_health_db::record_failure(
                    name.as_str(),
                    "degraded",
                    Some(err_msg.as_str()),
                );
                Err(e)
            }
            Err(_elapsed) => {
                record_circuit_failure(&name);
                record_tool_call(&name, false);
                let msg = format!(
                    "tool timed out after {}s",
                    self.timeout_duration.as_secs()
                );
                let _ = crate::tool_health_db::record_failure(
                    name.as_str(),
                    "degraded",
                    Some(msg.as_str()),
                );
                Err(anyhow!("{}", msg))
            }
        }
    }
}

/// Wrap a tool with the default timeout and optional tool-health recording.
/// Use when building the registry so every tool gets the same guarantees.
pub fn wrap_tool(inner: Box<dyn Tool + Send + Sync>) -> Box<dyn Tool + Send + Sync> {
    Box::new(ToolTimeoutWrapper::new(inner))
}
