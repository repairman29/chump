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

/// Error type for `call_rpc`. Stub returns NotImplemented; real impl will
/// add Timeout (rc=124 equivalent), HandlerCrashed (distinct from Timeout
/// per slice-3 chaos test), and Network (transport failure) variants.
#[derive(Debug)]
pub enum RpcError {
    /// Stub-only — real impl lands in INFRA-1119 slice 2/4.
    NotImplemented,
    /// Wire-format decode error.
    Deserialize(serde_json::Error),
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RpcError::NotImplemented => {
                write!(f, "RPC stub — real impl ships in INFRA-1119 slice 2/4")
            }
            RpcError::Deserialize(e) => write!(f, "deserialize failed: {e}"),
        }
    }
}

impl std::error::Error for RpcError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            RpcError::NotImplemented => None,
            RpcError::Deserialize(e) => Some(e),
        }
    }
}

impl From<serde_json::Error> for RpcError {
    fn from(e: serde_json::Error) -> Self {
        RpcError::Deserialize(e)
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

/// Send an RPC to a peer session. Stub returns NotImplemented + emits
/// `a2a_rpc_stub_called` to ambient.
///
/// Real impl (slice 2/4): publishes RpcRequest to NATS subject
/// `chump.rpc.<target_session>.<method>`, awaits response on
/// `chump.rpc.reply.<request_id>` with `tokio::time::timeout(timeout_ms)`.
pub async fn call_rpc(
    target_session: &str,
    method: &str,
    args: serde_json::Value,
    timeout_ms: u64,
) -> Result<RpcResponse, RpcError> {
    let request_id = new_request_id();
    let ts = chrono::Utc::now().to_rfc3339();
    let line = format!(
        r#"{{"ts":"{ts}","kind":"a2a_rpc_stub_called","target":"{target_session}","method":"{method}","request_id":"{request_id}","timeout_ms":{timeout_ms}}}"#
    );
    let _ = append_ambient(&line);
    let _ = args; // accept but ignore for stub
    Err(RpcError::NotImplemented)
}

/// Server-side handler registration. Stub returns NotImplemented; real
/// impl in slice 2/4 will register the handler against a NATS subject
/// subscription and serialize responses through a tokio task.
pub async fn serve_rpc<F>(method: &str, handler: F) -> Result<(), RpcError>
where
    F: Fn(serde_json::Value) -> Result<serde_json::Value, String> + Send + Sync + 'static,
{
    let _ = method;
    let _ = handler;
    let ts = chrono::Utc::now().to_rfc3339();
    let line = format!(
        r#"{{"ts":"{ts}","kind":"a2a_rpc_stub_called","method":"{method}","mode":"serve"}}"#
    );
    let _ = append_ambient(&line);
    Err(RpcError::NotImplemented)
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
