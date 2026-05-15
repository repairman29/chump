//! INFRA-741: lightweight model capability probe + result cache.
//!
//! On first use of a new `OPENAI_MODEL` + `OPENAI_API_BASE` combo, a short
//! probe request is sent to detect:
//!   - tool-use / function-call support
//!   - think-tag emission (`<think>` / `<thinking>`)
//!   - approximate context window (from `/v1/models` if available)
//!
//! Results are cached to `~/.chump/model_probes.json` keyed by
//! `"{model}@{base_url}"`. The cache is read synchronously by
//! `detect_model_family` in `model_overlay.rs` to supplement heuristic
//! matching. Probe failure is non-fatal — the caller falls back to the
//! substring heuristic.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

const PROBE_TIMEOUT_MS: u64 = 4_000;
const PROBE_MAX_TOKENS: u32 = 64;

// ── Data types ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProbeResult {
    pub model: String,
    pub base_url: String,
    /// Model responded correctly to a function-call / tool-use request.
    pub has_tool_use: bool,
    /// Model's response contained `<think>` or `<thinking>` tags.
    pub has_think_tags: bool,
    /// Approximate context window in tokens (from /v1/models if available).
    pub context_window: Option<u32>,
    /// ISO-8601 timestamp of when the probe ran.
    pub probed_at: String,
}

impl ProbeResult {
    pub fn cache_key(model: &str, base_url: &str) -> String {
        format!("{}@{}", model, base_url.trim_end_matches('/'))
    }
}

// ── Cache I/O ────────────────────────────────────────────────────────────────

fn cache_path() -> Option<PathBuf> {
    let home = std::env::var("CHUMP_HOME")
        .ok()
        .or_else(|| std::env::var("HOME").ok())?;
    Some(PathBuf::from(home).join(".chump").join("model_probes.json"))
}

pub fn load_cache() -> HashMap<String, ProbeResult> {
    let Some(path) = cache_path() else {
        return HashMap::new();
    };
    let Ok(data) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    serde_json::from_str(&data).unwrap_or_default()
}

fn save_cache(cache: &HashMap<String, ProbeResult>) {
    let Some(path) = cache_path() else { return };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string_pretty(cache) {
        let _ = std::fs::write(&path, json);
    }
}

/// Return cached probe for `(model, base_url)` if one exists.
pub fn get_cached(model: &str, base_url: &str) -> Option<ProbeResult> {
    let key = ProbeResult::cache_key(model, base_url);
    load_cache().remove(&key)
}

// ── Live probe ───────────────────────────────────────────────────────────────

/// Run a capability probe against the configured endpoint and cache the result.
///
/// Non-fatal: any HTTP or parse error returns a `ProbeResult` with all
/// capabilities set to `false`/`None` so callers always get a usable value.
pub async fn probe_and_cache(model: &str, base_url: &str) -> ProbeResult {
    let result = run_probe(model, base_url)
        .await
        .unwrap_or_else(|err| {
            tracing::warn!(model, base_url, error = %err, "INFRA-741: model probe failed, using defaults");
            ProbeResult {
                model: model.to_string(),
                base_url: base_url.trim_end_matches('/').to_string(),
                has_tool_use: false,
                has_think_tags: false,
                context_window: None,
                probed_at: utc_now(),
            }
        });
    tracing::info!(
        model,
        base_url,
        has_tool_use = result.has_tool_use,
        has_think_tags = result.has_think_tags,
        context_window = ?result.context_window,
        "INFRA-741: model capability probe complete"
    );
    let key = ProbeResult::cache_key(model, base_url);
    let mut cache = load_cache();
    cache.insert(key, result.clone());
    save_cache(&cache);
    result
}

/// Return the cached probe for `(model, base_url)`, running a fresh probe only
/// if no cached entry exists.
pub async fn probe_or_cached(model: &str, base_url: &str) -> ProbeResult {
    if let Some(cached) = get_cached(model, base_url) {
        return cached;
    }
    probe_and_cache(model, base_url).await
}

// ── Probe implementation ─────────────────────────────────────────────────────

async fn run_probe(model: &str, base_url: &str) -> Result<ProbeResult> {
    let base = base_url.trim_end_matches('/');
    let api_key = std::env::var("OPENAI_API_KEY").unwrap_or_default();

    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(PROBE_TIMEOUT_MS))
        .build()?;

    let is_local = base.contains("127.0.0.1") || base.contains("localhost");
    let skip_auth = is_local && (api_key.is_empty() || api_key == "not-needed");

    // ── Tool-use probe ──────────────────────────────────────────────────────
    let tool_def = json!([{
        "type": "function",
        "function": {
            "name": "chump_probe",
            "description": "Capability probe — call this function.",
            "parameters": {"type": "object", "properties": {}, "required": []}
        }
    }]);
    let tool_body = json!({
        "model": model,
        "messages": [{"role": "user", "content": "Call the chump_probe function."}],
        "tools": tool_def,
        "tool_choice": {"type": "function", "function": {"name": "chump_probe"}},
        "max_tokens": PROBE_MAX_TOKENS,
        "stream": false,
        "temperature": 0.0
    });

    let url = format!("{}/chat/completions", base);
    let mut req = client.post(&url).json(&tool_body);
    if !skip_auth {
        req = req.header("Authorization", format!("Bearer {}", api_key));
    }
    let tool_resp: Value = req.send().await?.json().await?;
    let has_tool_use = response_has_tool_call(&tool_resp);

    // ── Think-tag probe ─────────────────────────────────────────────────────
    let think_body = json!({
        "model": model,
        "messages": [{"role": "user", "content": "Reply with one word."}],
        "max_tokens": PROBE_MAX_TOKENS,
        "stream": false,
        "temperature": 0.0
    });
    let mut req2 = client.post(&url).json(&think_body);
    if !skip_auth {
        req2 = req2.header("Authorization", format!("Bearer {}", api_key));
    }
    let think_resp: Value = req2.send().await?.json().await?;
    let think_text = response_content_text(&think_resp);
    let has_think_tags = think_text.contains("<think>") || think_text.contains("<thinking>");

    // ── Context window (best-effort from /v1/models) ────────────────────────
    let context_window = fetch_context_window(&client, base, model, skip_auth, &api_key).await;

    Ok(ProbeResult {
        model: model.to_string(),
        base_url: base.to_string(),
        has_tool_use,
        has_think_tags,
        context_window,
        probed_at: utc_now(),
    })
}

fn response_has_tool_call(resp: &Value) -> bool {
    resp["choices"]
        .as_array()
        .and_then(|arr| arr.first())
        .and_then(|c| c["message"]["tool_calls"].as_array())
        .map(|tc| !tc.is_empty())
        .unwrap_or(false)
}

fn response_content_text(resp: &Value) -> String {
    resp["choices"]
        .as_array()
        .and_then(|arr| arr.first())
        .and_then(|c| c["message"]["content"].as_str())
        .unwrap_or("")
        .to_string()
}

async fn fetch_context_window(
    client: &reqwest::Client,
    base: &str,
    model: &str,
    skip_auth: bool,
    api_key: &str,
) -> Option<u32> {
    let url = format!("{}/models/{}", base, model);
    let mut req = client.get(&url);
    if !skip_auth {
        req = req.header("Authorization", format!("Bearer {}", api_key));
    }
    let resp: Value = req.send().await.ok()?.json().await.ok()?;
    // OpenAI-compatible: `context_window` or `context_length`
    resp["context_window"]
        .as_u64()
        .or_else(|| resp["context_length"].as_u64())
        .and_then(|n| u32::try_from(n).ok())
}

fn utc_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Produce a rough ISO-8601 string without an external date crate.
    let s = secs;
    let min = s / 60;
    let hour = min / 60;
    let day_secs = hour / 24;
    let sec = s % 60;
    let m = (min % 60) as u8;
    let h = (hour % 24) as u8;
    // Days since epoch → rough date (good enough for a cache key timestamp)
    let days = day_secs;
    // 2000-01-01 = day 10957 since unix epoch
    let days_since_2000 = days.saturating_sub(10957);
    let year = 2000 + days_since_2000 / 365;
    let day_of_year = days_since_2000 % 365;
    let month = (day_of_year / 30 + 1).min(12) as u8;
    let day = (day_of_year % 30 + 1).min(31) as u8;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, h, m, sec
    )
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_key_trims_trailing_slash() {
        let k1 = ProbeResult::cache_key("gpt-4", "http://localhost:11434/v1/");
        let k2 = ProbeResult::cache_key("gpt-4", "http://localhost:11434/v1");
        assert_eq!(k1, k2);
    }

    #[test]
    fn response_has_tool_call_detects_call() {
        let resp = serde_json::json!({
            "choices": [{"message": {"tool_calls": [{"function": {"name": "chump_probe"}}]}}]
        });
        assert!(response_has_tool_call(&resp));
    }

    #[test]
    fn response_has_tool_call_empty() {
        let resp = serde_json::json!({"choices": [{"message": {"content": "hi"}}]});
        assert!(!response_has_tool_call(&resp));
    }

    #[test]
    fn think_tag_detection() {
        let resp = serde_json::json!({
            "choices": [{"message": {"content": "<think>hmm</think>yes"}}]
        });
        let text = response_content_text(&resp);
        assert!(text.contains("<think>"));
    }

    #[test]
    fn utc_now_looks_like_iso8601() {
        let s = utc_now();
        assert!(s.contains('T') && s.ends_with('Z'), "got: {s}");
        assert_eq!(s.len(), 20);
    }
}
