//! Pending tool-approval requests. Agent registers a request and blocks; Discord/web calls resolve_approval when the user allows/denies.

use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::oneshot;

static PENDING: std::sync::OnceLock<Mutex<HashMap<String, oneshot::Sender<bool>>>> =
    std::sync::OnceLock::new();

fn pending() -> &'static Mutex<HashMap<String, oneshot::Sender<bool>>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Create a pending approval request. Returns (request_id, receiver). Caller should emit ToolApprovalRequest with request_id, then await the receiver (with timeout). Resolver calls resolve_approval(request_id, allowed).
pub fn request_approval() -> (String, oneshot::Receiver<bool>) {
    let request_id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = oneshot::channel();
    if let Ok(mut guard) = pending().lock() {
        guard.insert(request_id.clone(), tx);
    }
    (request_id, rx)
}

/// Resolve a pending approval. Called by Discord button handler or POST /api/approve. Idempotent if request_id already resolved or unknown.
pub fn resolve_approval(request_id: &str, allowed: bool) {
    if let Ok(mut guard) = pending().lock() {
        if let Some(tx) = guard.remove(request_id) {
            let _ = tx.send(allowed);
        }
    }
    crate::pending_peer_approval::clear_pending_peer_approval(request_id);
}

/// Default timeout for waiting for approval (seconds). Env CHUMP_APPROVAL_TIMEOUT_SECS.
pub fn approval_timeout_secs() -> u64 {
    std::env::var("CHUMP_APPROVAL_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60)
        .clamp(5, 600)
}
