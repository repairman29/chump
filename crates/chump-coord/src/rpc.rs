// crates/chump-coord/src/rpc.rs — INFRA-1759
//
// A2A Layer 2b foundation slice (1/4) — strongly-typed request/response
// RPC between Opus sessions with deadlines + idempotency.
//
// This file ships ONLY: RpcRequest + RpcResponse wire types, RpcError enum,
// in-memory dedup table, and stub call_rpc + serve_rpc async signatures
// that return NotImplemented at runtime. The real implementation (NATS
// subject routing + tokio-channel response delivery + handler crash
// detection within 5s + 5 use-case wrappers) lands in INFRA-1119 slice 2/4.
//
// Why stub-first: lets ask-eta / ask-overlap / ask-handoff / ask-progress /
// ask-capability wrappers (slice 2) be type-designed today against stable
// RpcRequest/RpcResponse shapes.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Instant;

/// Default RPC client deadline. Real impl in slice 2/4 wires this through
/// to a `tokio::time::timeout` on the response channel.
pub const DEFAULT_RPC_TIMEOUT_MS: u64 = 10_000;

/// Dedup window for idempotent retries. Real impl in slice 2/4 expires
/// entries via a tokio task that scans every 30s.
pub const DEDUP_WINDOW_SECONDS: u64 = 60;

/// Request envelope sent from a caller to a target_session over Layer 2b.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcRequest {
    /// UUIDv4-style identifier. Server dedups within the dedup window so
    /// network-blip retries are safe.
    pub request_id: String,
    /// Method name (e.g. "ask-eta", "ask-overlap").
    pub method: String,
    /// JSON payload — method-specific.
    pub args: serde_json::Value,
    /// ISO-8601 send time. Used to compute one-way latency.
    pub sent_at: String,
}

/// Response envelope returned from server-side handler.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcResponse {
    /// Mirrors `RpcRequest.request_id`.
    pub request_id: String,
    /// Method's typed result, or None when `error` is populated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    /// Server-side error string, or None on success.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Round-trip latency the server observed before responding.
    pub latency_ms: u64,
}

/// Error type for `call_rpc`. INFRA-1119 v1 file-backed transport (mirrors
/// the INFRA-1828 bash wrappers' on-wire shape). NATS subject routing is a
/// later swap that preserves these variants.
#[derive(Debug)]
pub enum RpcError {
    /// Reserved — caller will not see this variant in v1; kept for
    /// API stability with the stub-era code.
    #[allow(dead_code)]
    NotImplemented,
    /// Wire-format decode error.
    Deserialize(serde_json::Error),
    /// Client deadline (`timeout_ms`) elapsed before a reply landed.
    /// Emits `kind=a2a_rpc_timeout` to ambient. AC #4.
    Timeout,
    /// Server-side handler panicked OR otherwise crashed mid-call. Distinct
    /// from Timeout per AC #5 — emits `kind=a2a_rpc_handler_crashed`.
    HandlerCrashed(String),
    /// Transport-layer failure (could not write request OR poll inbox).
    Network(String),
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RpcError::NotImplemented => write!(f, "RPC v1 reserves this variant for API stability"),
            RpcError::Deserialize(e) => write!(f, "deserialize failed: {e}"),
            RpcError::Timeout => write!(f, "RPC timeout (no reply within deadline)"),
            RpcError::HandlerCrashed(s) => write!(f, "RPC handler crashed: {s}"),
            RpcError::Network(s) => write!(f, "RPC transport error: {s}"),
        }
    }
}

impl std::error::Error for RpcError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            RpcError::Deserialize(e) => Some(e),
            _ => None,
        }
    }
}

impl From<serde_json::Error> for RpcError {
    fn from(e: serde_json::Error) -> Self {
        RpcError::Deserialize(e)
    }
}

impl From<std::io::Error> for RpcError {
    fn from(e: std::io::Error) -> Self {
        RpcError::Network(e.to_string())
    }
}

/// In-memory dedup table. Maps `request_id` → first-seen `Instant`.
/// Real impl in slice 2/4 will add a tokio task that scans and evicts
/// entries older than DEDUP_WINDOW_SECONDS.
pub struct DedupTable {
    seen: Mutex<HashMap<String, Instant>>,
}

impl DedupTable {
    pub fn new() -> Self {
        Self {
            seen: Mutex::new(HashMap::new()),
        }
    }

    /// Record + check: returns true if `request_id` is new (caller should
    /// process), false if already-seen within the dedup window.
    pub fn record(&self, request_id: &str) -> bool {
        let mut g = self.seen.lock().expect("dedup poisoned");
        let now = Instant::now();
        // Evict stale entries opportunistically.
        let window = std::time::Duration::from_secs(DEDUP_WINDOW_SECONDS);
        g.retain(|_, t| now.duration_since(*t) < window);
        if g.contains_key(request_id) {
            false
        } else {
            g.insert(request_id.to_string(), now);
            true
        }
    }

    /// Snapshot of the current size. Useful for tests.
    pub fn len(&self) -> usize {
        self.seen.lock().expect("dedup poisoned").len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl Default for DedupTable {
    fn default() -> Self {
        Self::new()
    }
}

/// Generate a new request_id. Falls back to ts+pid+counter when uuid crate
/// isn't available. Real impl in slice 2/4 will use uuidv4 properly.
pub fn new_request_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let c = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:x}-{:x}-{}", nanos, std::process::id(), c)
}

/// Resolve the current session id for self-inbox addressing.
fn self_session() -> String {
    std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("SESSION_ID"))
        .or_else(|_| std::env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| format!("rust-{}", std::process::id()))
}

/// Resolve the rpc-inbox dir. Honors CHUMP_LOCK_DIR for test isolation.
fn rpc_inbox_dir() -> std::path::PathBuf {
    let lock_dir = std::env::var("CHUMP_LOCK_DIR")
        .ok()
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(".chump-locks"));
    lock_dir.join("rpc-inbox")
}

fn inbox_path_for(session: &str) -> std::path::PathBuf {
    let safe = session.replace(['/', ':'], "_");
    rpc_inbox_dir().join(format!("{safe}.jsonl"))
}

fn write_envelope_to_inbox(target_session: &str, payload: &str) -> std::io::Result<()> {
    use std::io::Write;
    let inbox = inbox_path_for(target_session);
    if let Some(parent) = inbox.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&inbox)?;
    writeln!(f, "{}", payload)?;
    Ok(())
}

fn poll_for_reply(self_sess: &str, needle: &str) -> Option<serde_json::Value> {
    let inbox = inbox_path_for(self_sess);
    let content = std::fs::read_to_string(&inbox).ok()?;
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || !line.contains(needle) {
            continue;
        }
        let env: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if env.get("kind") != Some(&serde_json::Value::String("a2a_rpc_reply".into())) {
            continue;
        }
        let response = env.get("response").cloned()?;
        if response.get("request_id") == Some(&serde_json::Value::String(needle.into())) {
            return Some(response);
        }
    }
    None
}

/// Send an RPC to a peer session. INFRA-1119 v1 — file-backed transport
/// (mirrors INFRA-1828 bash wrappers). Writes a [`RpcRequest`] JSON to
/// the target's inbox, then polls our own inbox for a matching reply
/// within `timeout_ms`. Emits `a2a_rpc_started`, `a2a_rpc_finished`,
/// `a2a_rpc_timeout`, and `a2a_rpc_handler_crashed` (AC #4 + #5 + #7).
pub async fn call_rpc(
    target_session: &str,
    method: &str,
    args: serde_json::Value,
    timeout_ms: u64,
) -> Result<RpcResponse, RpcError> {
    let request_id = new_request_id();
    let started = std::time::Instant::now();
    let ts_started = chrono::Utc::now().to_rfc3339();
    let from = self_session();

    let req = RpcRequest {
        request_id: request_id.clone(),
        method: method.to_string(),
        args,
        sent_at: ts_started.clone(),
    };
    let envelope_json = serde_json::to_string(&serde_json::json!({
        "kind": "a2a_rpc_request",
        "from": from,
        "request": req,
    }))?;

    write_envelope_to_inbox(target_session, &envelope_json).inspect_err(|e| {
        let _ = append_ambient(&format!(
            r#"{{"ts":"{ts_started}","kind":"a2a_rpc_send_failed","target":"{target_session}","method":"{method}","request_id":"{request_id}","error":"{}"}}"#,
            e.to_string().replace('"', "'")
        ));
    })?;

    let _ = append_ambient(&format!(
        r#"{{"ts":"{ts_started}","kind":"a2a_rpc_started","target":"{target_session}","method":"{method}","request_id":"{request_id}"}}"#
    ));

    let self_sess = self_session();
    let deadline = std::time::Duration::from_millis(timeout_ms);
    let poll_interval = std::time::Duration::from_millis(50);
    let poll_result = tokio::time::timeout(deadline, async {
        loop {
            if let Some(reply) = poll_for_reply(&self_sess, &request_id) {
                return reply;
            }
            tokio::time::sleep(poll_interval).await;
        }
    })
    .await;

    let latency_ms = started.elapsed().as_millis() as u64;
    let ts_done = chrono::Utc::now().to_rfc3339();

    match poll_result {
        Ok(reply_value) => {
            let response: RpcResponse = serde_json::from_value(reply_value)?;
            if let Some(err) = &response.error {
                if err.starts_with("HANDLER_CRASHED:") {
                    let _ = append_ambient(&format!(
                        r#"{{"ts":"{ts_done}","kind":"a2a_rpc_handler_crashed","target":"{target_session}","method":"{method}","request_id":"{request_id}","latency_ms":{latency_ms}}}"#
                    ));
                    return Err(RpcError::HandlerCrashed(err.clone()));
                }
            }
            let _ = append_ambient(&format!(
                r#"{{"ts":"{ts_done}","kind":"a2a_rpc_finished","target":"{target_session}","method":"{method}","request_id":"{request_id}","latency_ms":{latency_ms}}}"#
            ));
            Ok(response)
        }
        Err(_) => {
            let _ = append_ambient(&format!(
                r#"{{"ts":"{ts_done}","kind":"a2a_rpc_timeout","target":"{target_session}","method":"{method}","request_id":"{request_id}","timeout_ms":{timeout_ms}}}"#
            ));
            Err(RpcError::Timeout)
        }
    }
}

/// Server-side handler — polls our own inbox for requests targeting
/// `method`, invokes `handler`, writes replies to the requester's inbox.
/// Per-request_id de-dup within DEDUP_WINDOW_SECONDS (AC #3) makes retries
/// idempotent. Panics inside `handler` are caught and surfaced as
/// `a2a_rpc_handler_crashed` (AC #5 — distinct kind from Timeout).
///
/// `iterations: Some(N)` makes integration tests deterministic; `None`
/// loops forever.
pub async fn serve_rpc_n<F>(
    method: &str,
    handler: F,
    iterations: Option<usize>,
) -> Result<(), RpcError>
where
    F: Fn(serde_json::Value) -> Result<serde_json::Value, String>
        + std::panic::RefUnwindSafe
        + Send
        + Sync
        + 'static,
{
    let dedup = DedupTable::new();
    let self_sess = self_session();
    let poll_interval = std::time::Duration::from_millis(50);
    let mut seek_offset: usize = 0;
    let mut tick: usize = 0;

    loop {
        if let Some(n) = iterations {
            if tick >= n {
                break;
            }
        }
        tick += 1;
        let inbox = inbox_path_for(&self_sess);
        if let Ok(content) = std::fs::read_to_string(&inbox) {
            let from = std::cmp::min(seek_offset, content.len());
            for line in content[from..].lines() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let env: serde_json::Value = match serde_json::from_str(line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                if env.get("kind") != Some(&serde_json::Value::String("a2a_rpc_request".into())) {
                    continue;
                }
                let req_method = env
                    .pointer("/request/method")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if req_method != method {
                    continue;
                }
                let request_id = env
                    .pointer("/request/request_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let from_session = env
                    .get("from")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if !dedup.record(&request_id) {
                    continue;
                }
                let args = env
                    .pointer("/request/args")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                let started = std::time::Instant::now();

                let handler_ref = &handler;
                let result =
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handler_ref(args)));
                let latency_ms = started.elapsed().as_millis() as u64;

                let response = match result {
                    Ok(Ok(v)) => RpcResponse {
                        request_id: request_id.clone(),
                        result: Some(v),
                        error: None,
                        latency_ms,
                    },
                    Ok(Err(e)) => RpcResponse {
                        request_id: request_id.clone(),
                        result: None,
                        error: Some(e),
                        latency_ms,
                    },
                    Err(panic_payload) => {
                        let crash_msg = panic_payload
                            .downcast_ref::<&str>()
                            .map(|s| s.to_string())
                            .or_else(|| panic_payload.downcast_ref::<String>().cloned())
                            .unwrap_or_else(|| "(panic, no message)".to_string());
                        let ts = chrono::Utc::now().to_rfc3339();
                        let _ = append_ambient(&format!(
                            r#"{{"ts":"{ts}","kind":"a2a_rpc_handler_crashed","method":"{method}","request_id":"{request_id}","panic":"{}"}}"#,
                            crash_msg.replace('"', "'")
                        ));
                        RpcResponse {
                            request_id: request_id.clone(),
                            result: None,
                            error: Some(format!("HANDLER_CRASHED: {}", crash_msg)),
                            latency_ms,
                        }
                    }
                };

                let reply_envelope = serde_json::json!({
                    "kind": "a2a_rpc_reply",
                    "from": self_sess,
                    "response": response,
                });
                let _ = write_envelope_to_inbox(&from_session, &reply_envelope.to_string());
            }
            seek_offset = content.len();
        }
        tokio::time::sleep(poll_interval).await;
    }
    Ok(())
}

/// Forever-loop variant of `serve_rpc_n`. AC #1's canonical public API;
/// integration tests use `serve_rpc_n` with bounded iterations.
pub async fn serve_rpc<F>(method: &str, handler: F) -> Result<(), RpcError>
where
    F: Fn(serde_json::Value) -> Result<serde_json::Value, String>
        + std::panic::RefUnwindSafe
        + Send
        + Sync
        + 'static,
{
    serve_rpc_n(method, handler, None).await
}

fn append_ambient(line: &str) -> std::io::Result<()> {
    use std::io::Write;
    let log = std::env::var("CHUMP_AMBIENT_LOG")
        .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)?;
    writeln!(f, "{}", line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_sane() {
        assert_eq!(DEFAULT_RPC_TIMEOUT_MS, 10_000);
        assert_eq!(DEDUP_WINDOW_SECONDS, 60);
    }

    #[test]
    fn dedup_table_accepts_new_rejects_duplicate() {
        let t = DedupTable::new();
        assert!(t.record("req-1"));
        assert!(!t.record("req-1"), "duplicate should be rejected");
        assert!(t.record("req-2"));
        assert_eq!(t.len(), 2);
    }

    #[test]
    fn new_request_id_unique_per_call() {
        let a = new_request_id();
        let b = new_request_id();
        assert_ne!(a, b, "atomic counter should make consecutive ids distinct");
    }

    #[test]
    fn request_json_round_trip() {
        let r = RpcRequest {
            request_id: "abc-123".to_string(),
            method: "ask-eta".to_string(),
            args: serde_json::json!({"gap_id": "INFRA-1759"}),
            sent_at: "2026-05-23T15:00:00Z".to_string(),
        };
        let j = serde_json::to_string(&r).unwrap();
        let back: RpcRequest = serde_json::from_str(&j).unwrap();
        assert_eq!(r, back);
    }

    #[test]
    fn response_omits_none_fields() {
        let r = RpcResponse {
            request_id: "abc-123".to_string(),
            result: Some(serde_json::json!({"eta_seconds": 120})),
            error: None,
            latency_ms: 42,
        };
        let j = serde_json::to_string(&r).unwrap();
        assert!(!j.contains("\"error\""), "None error should be omitted");
        assert!(j.contains("\"result\""), "Some result should be present");
    }
}
