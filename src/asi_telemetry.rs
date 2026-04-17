//! COG-012: ASI telemetry — token log-probabilities + tool latency spikes.
//!
//! Stores min/avg logprob per turn (from provider responses) and peak tool latency
//! so reflection can flag high-uncertainty generation segments and slow tool paths.
//! Gracefully no-ops when provider does not return logprobs or DB is unavailable.

use std::sync::{Mutex, OnceLock};

/// Logprob snapshot for a single generation turn.
#[derive(Debug, Clone)]
pub struct LogprobSnapshot {
    /// Minimum (most uncertain) logprob across all tokens in the turn.
    pub min_logprob: f64,
    /// Average logprob across all tokens in the turn.
    pub avg_logprob: f64,
    pub turn_id: u64,
}

/// Tool latency record from a single invocation.
#[derive(Debug, Clone)]
pub struct ToolLatencyRecord {
    pub tool_name: String,
    pub peak_latency_ms: u64,
}

static LATEST_LOGPROB: OnceLock<Mutex<Option<LogprobSnapshot>>> = OnceLock::new();
static RECENT_LATENCIES: OnceLock<Mutex<Vec<ToolLatencyRecord>>> = OnceLock::new();
const MAX_LATENCY_HISTORY: usize = 50;

fn logprob_store() -> &'static Mutex<Option<LogprobSnapshot>> {
    LATEST_LOGPROB.get_or_init(|| Mutex::new(None))
}

fn latency_store() -> &'static Mutex<Vec<ToolLatencyRecord>> {
    RECENT_LATENCIES.get_or_init(|| Mutex::new(Vec::new()))
}

/// Record logprob telemetry from a generation turn. No-ops if logprobs are not available.
pub fn record_logprobs(min_logprob: f64, avg_logprob: f64) {
    let turn_id = crate::agent_turn::current();
    if let Ok(mut guard) = logprob_store().lock() {
        *guard = Some(LogprobSnapshot {
            min_logprob,
            avg_logprob,
            turn_id,
        });
    }
    // Persist to DB (graceful no-op on failure).
    let _ = persist_logprob_to_db(turn_id, min_logprob, avg_logprob);
}

/// Record peak latency for a tool invocation.
pub fn record_tool_latency(tool_name: &str, latency_ms: u64) {
    if let Ok(mut guard) = latency_store().lock() {
        guard.push(ToolLatencyRecord {
            tool_name: tool_name.to_string(),
            peak_latency_ms: latency_ms,
        });
        if guard.len() > MAX_LATENCY_HISTORY {
            guard.remove(0);
        }
    }
    let _ = persist_latency_to_db(tool_name, latency_ms);
}

/// Get the latest logprob snapshot (None if no data yet).
pub fn latest_logprob_snapshot() -> Option<LogprobSnapshot> {
    logprob_store().lock().ok()?.clone()
}

/// Return tool names whose recent peak latency exceeded `threshold_ms`.
pub fn recent_slow_tools(threshold_ms: u64) -> Vec<String> {
    latency_store()
        .lock()
        .ok()
        .map(|g| {
            g.iter()
                .filter(|r| r.peak_latency_ms > threshold_ms)
                .map(|r| r.tool_name.clone())
                .collect()
        })
        .unwrap_or_default()
}

/// Extract min and avg logprob from an OpenAI-format response JSON value.
/// Returns None if the response does not include logprobs.
pub fn extract_logprobs_from_response(response: &serde_json::Value) -> Option<(f64, f64)> {
    let content = response
        .get("choices")?
        .get(0)?
        .get("logprobs")?
        .get("content")?
        .as_array()?;

    if content.is_empty() {
        return None;
    }

    let logprobs: Vec<f64> = content
        .iter()
        .filter_map(|tok| tok.get("logprob")?.as_f64())
        .collect();

    if logprobs.is_empty() {
        return None;
    }

    let min = logprobs.iter().cloned().fold(f64::INFINITY, f64::min);
    let avg = logprobs.iter().sum::<f64>() / logprobs.len() as f64;
    Some((min, avg))
}

fn persist_logprob_to_db(turn_id: u64, min_logprob: f64, avg_logprob: f64) -> anyhow::Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT OR IGNORE INTO chump_asi_telemetry (turn_id, min_logprob, avg_logprob) VALUES (?1, ?2, ?3)",
        rusqlite::params![turn_id as i64, min_logprob, avg_logprob],
    )?;
    Ok(())
}

fn persist_latency_to_db(tool_name: &str, peak_latency_ms: u64) -> anyhow::Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_tool_latency (tool_name, peak_latency_ms) VALUES (?1, ?2)",
        rusqlite::params![tool_name, peak_latency_ms as i64],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_logprobs_from_valid_response() {
        let response = serde_json::json!({
            "choices": [{
                "logprobs": {
                    "content": [
                        {"logprob": -0.1},
                        {"logprob": -0.5},
                        {"logprob": -2.0}
                    ]
                }
            }]
        });
        let result = extract_logprobs_from_response(&response);
        assert!(result.is_some());
        let (min, avg) = result.unwrap();
        assert!(
            (min - (-2.0)).abs() < 1e-6,
            "min should be -2.0, got {}",
            min
        );
        let expected_avg = (-0.1 + -0.5 + -2.0) / 3.0;
        assert!((avg - expected_avg).abs() < 1e-6);
    }

    #[test]
    fn extract_logprobs_returns_none_for_missing_field() {
        let response = serde_json::json!({"choices": [{"message": {"content": "hello"}}]});
        assert!(extract_logprobs_from_response(&response).is_none());
    }

    #[test]
    fn record_and_retrieve_logprobs() {
        record_logprobs(-0.3, -0.7);
        let snap = latest_logprob_snapshot();
        assert!(snap.is_some());
        let s = snap.unwrap();
        assert!((s.min_logprob - (-0.3)).abs() < 1e-6);
        assert!((s.avg_logprob - (-0.7)).abs() < 1e-6);
    }

    #[test]
    fn recent_slow_tools_filters_by_threshold() {
        record_tool_latency("__test_slow__", 5000);
        record_tool_latency("__test_fast__", 10);
        let slow = recent_slow_tools(1000);
        assert!(slow.contains(&"__test_slow__".to_string()));
        assert!(!slow.contains(&"__test_fast__".to_string()));
    }
}
