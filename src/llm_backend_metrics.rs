//! Last LLM completion + cumulative counts by backend (mistral in-process, cascade slot, HTTP, OpenAI API).
//! See [MISTRALRS.md](../docs/architecture/MISTRALRS.md) Tier A and [METRICS.md](../docs/operations/METRICS.md) §1c.

use serde_json::json;
use std::cell::Cell;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
struct LastCompletion {
    kind: &'static str,
    label: String,
    stream_text_deltas: bool,
    at_unix_ms: u64,
}

static LAST: Mutex<Option<LastCompletion>> = Mutex::new(None);
static TOTALS: LazyLock<Mutex<HashMap<String, u64>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

thread_local! {
    static RECORDING_PAUSED_DEPTH: Cell<u32> = const { Cell::new(0) };
    static CASCADE_INNER_DEPTH: Cell<u32> = const { Cell::new(0) };
}

/// While held, [`record_openai_http`] is a no-op (cascade records the slot instead).
pub struct CascadeInnerGuard;

impl CascadeInnerGuard {
    pub fn new() -> Self {
        CASCADE_INNER_DEPTH.with(|d| d.set(d.get().saturating_add(1)));
        CascadeInnerGuard
    }
}

impl Drop for CascadeInnerGuard {
    fn drop(&mut self) {
        CASCADE_INNER_DEPTH.with(|d| d.set(d.get().saturating_sub(1)));
    }
}

fn inside_cascade_http_inner() -> bool {
    CASCADE_INNER_DEPTH.with(|d| d.get() > 0)
}

/// Host[:port] from an OpenAI base URL for operator-visible labels (no path).
pub fn short_openai_endpoint_label(base_url: &str) -> String {
    let t = base_url.trim();
    if t.is_empty() {
        return "openai_http".to_string();
    }
    let rest = t
        .strip_prefix("http://")
        .or_else(|| t.strip_prefix("https://"))
        .unwrap_or(t);
    let end = rest.find('/').unwrap_or(rest.len());
    let hostport = rest[..end].trim_end_matches('/');
    if hostport.is_empty() {
        if t.len() > 64 {
            format!("{}…", &t[..61])
        } else {
            t.to_string()
        }
    } else {
        hostport.to_string()
    }
}

fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn recording_allowed() -> bool {
    RECORDING_PAUSED_DEPTH.with(|d| d.get() == 0)
}

/// While held, successful completions do not update last/totals (e.g. cascade warm probes).
pub struct RecordingPauseGuard;

impl RecordingPauseGuard {
    pub fn new() -> Self {
        RECORDING_PAUSED_DEPTH.with(|d| d.set(d.get().saturating_add(1)));
        RecordingPauseGuard
    }
}

impl Drop for RecordingPauseGuard {
    fn drop(&mut self) {
        RECORDING_PAUSED_DEPTH.with(|d| d.set(d.get().saturating_sub(1)));
    }
}

fn merge_record(kind: &'static str, label: &str, stream_text_deltas: bool) {
    if !recording_allowed() {
        return;
    }
    let key = format!("{}::{}", kind, label);
    let at = now_unix_ms();
    if let Ok(mut g) = LAST.lock() {
        *g = Some(LastCompletion {
            kind,
            label: label.to_string(),
            stream_text_deltas,
            at_unix_ms: at,
        });
    }
    if let Ok(mut g) = TOTALS.lock() {
        *g.entry(key).or_insert(0) += 1;
    }
}

/// In-process mistral.rs (`label` = HF model id).
pub fn record_mistralrs(model_id: &str, stream_text_deltas: bool) {
    merge_record("mistralrs", model_id, stream_text_deltas);
}

/// Cascade slot that served the completion (`CHUMP_PROVIDER_*_NAME` or `local`).
pub fn record_cascade_slot(slot_name: &str) {
    merge_record("cascade", slot_name, false);
}

/// Single-slot OpenAI-compatible HTTP (`label` = short host or `openai_http`).
pub fn record_openai_http(label: &str) {
    if inside_cascade_http_inner() {
        return;
    }
    merge_record("openai_http", label, false);
}

/// Hosted OpenAI API (no `OPENAI_API_BASE`); `label` is typically the model id.
pub fn record_openai_api(label: &str) {
    merge_record("openai_api", label, false);
}

pub fn snapshot_last_json() -> serde_json::Value {
    let Ok(g) = LAST.lock() else {
        return serde_json::Value::Null;
    };
    match g.as_ref() {
        Some(l) => {
            json!({
                "kind": l.kind,
                "label": l.label,
                "stream_text_deltas": l.stream_text_deltas,
                "at_unix_ms": l.at_unix_ms,
            })
        }
        None => serde_json::Value::Null,
    }
}

pub fn snapshot_totals_json() -> serde_json::Value {
    let Ok(g) = TOTALS.lock() else {
        return json!({});
    };
    let mut m = serde_json::Map::new();
    for (k, v) in g.iter() {
        m.insert(k.clone(), json!(v));
    }
    serde_json::Value::Object(m)
}

#[cfg(test)]
pub(crate) fn reset_for_test() {
    if let Ok(mut g) = LAST.lock() {
        *g = None;
    }
    if let Ok(mut g) = TOTALS.lock() {
        g.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn short_label_host_port() {
        assert_eq!(
            short_openai_endpoint_label("http://127.0.0.1:11434/v1"),
            "127.0.0.1:11434"
        );
        assert_eq!(
            short_openai_endpoint_label("https://api.example.com/v1/chat"),
            "api.example.com"
        );
    }

    #[test]
    #[serial]
    fn record_then_snapshot() {
        reset_for_test();
        record_cascade_slot("test_slot");
        let last = snapshot_last_json();
        assert_eq!(last.get("kind").and_then(|x| x.as_str()), Some("cascade"));
        assert_eq!(
            last.get("label").and_then(|x| x.as_str()),
            Some("test_slot")
        );
        let totals = snapshot_totals_json();
        assert_eq!(
            totals.get("cascade::test_slot").and_then(|x| x.as_u64()),
            Some(1)
        );
    }

    #[test]
    #[serial]
    fn openai_http_suppressed_inside_cascade_inner() {
        reset_for_test();
        let _g = CascadeInnerGuard::new();
        record_openai_http("should-not-record");
        assert!(snapshot_last_json().is_null());
    }
}
