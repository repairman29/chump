//! Pending tool-approval requests. Agent registers a request and blocks; Discord/web calls resolve_approval when the user allows/denies.
//!
//! RESILIENT-277: a naive retry loop that mints a brand-new `request_id` per
//! attempt leaves earlier receivers orphaned — tapping an older card resolves
//! an id with no receiver, which Discord accepts silently and the turn stays
//! hung. `request_or_join_approval` dedupes in-flight requests keyed on
//! (tool_name, normalized args) so a retry for the *same* question joins the
//! live request instead of minting a second one and posting a duplicate card.

use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::broadcast;

/// Outcome of a `resolve_approval` call, surfaced so callers can distinguish
/// "the tap actually reached a live receiver" (HIT) from "the id had already
/// been resolved/abandoned/never existed" (ORPHAN) — previously both cases
/// were silently identical, which is why the RESILIENT-277 incident needed a
/// live operator report instead of showing up in telemetry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolveOutcome {
    Hit,
    Orphan,
}

struct PendingEntry {
    tx: broadcast::Sender<bool>,
    tool_name: String,
    args_key: String,
}

static PENDING: std::sync::OnceLock<Mutex<HashMap<String, PendingEntry>>> =
    std::sync::OnceLock::new();

fn pending() -> &'static Mutex<HashMap<String, PendingEntry>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Canonical string key for an approval request: tool name + args with object
/// keys sorted so field-reordering (which some providers do across retries)
/// doesn't defeat dedupe.
fn normalize_args_key(args: &serde_json::Value) -> String {
    fn sort(v: &serde_json::Value) -> serde_json::Value {
        match v {
            serde_json::Value::Object(map) => {
                let sorted: std::collections::BTreeMap<String, serde_json::Value> =
                    map.iter().map(|(k, v)| (k.clone(), sort(v))).collect();
                serde_json::json!(sorted)
            }
            serde_json::Value::Array(arr) => {
                serde_json::Value::Array(arr.iter().map(sort).collect())
            }
            other => other.clone(),
        }
    }
    sort(args).to_string()
}

/// Create a pending approval request, or join an already-pending request for
/// the same (tool_name, args) instead of minting a new one. Returns
/// (request_id, receiver, is_new). Caller should only emit a fresh
/// ToolApprovalRequest UI card when `is_new` is true — otherwise a live card
/// already exists and the caller should just await the shared receiver.
pub fn request_or_join_approval(
    tool_name: &str,
    args: &serde_json::Value,
) -> (String, broadcast::Receiver<bool>, bool) {
    let args_key = normalize_args_key(args);
    let mut guard = match pending().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    if let Some((id, entry)) = guard
        .iter()
        .find(|(_, e)| e.tool_name == tool_name && e.args_key == args_key)
    {
        return (id.clone(), entry.tx.subscribe(), false);
    }
    let request_id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = broadcast::channel(1);
    guard.insert(
        request_id.clone(),
        PendingEntry {
            tx,
            tool_name: tool_name.to_string(),
            args_key,
        },
    );
    (request_id, rx, true)
}

/// Create a pending approval request. Returns (request_id, receiver). Caller should emit ToolApprovalRequest with request_id, then await the receiver (with timeout). Resolver calls resolve_approval(request_id, allowed).
/// Test-only convenience wrapper: each call uses a fresh random args key so
/// parallel `#[tokio::test]`s never accidentally join each other's request
/// (the real dedupe behavior is covered explicitly by the join/no-join tests
/// below).
#[cfg(test)]
pub fn request_approval() -> (String, broadcast::Receiver<bool>) {
    let (id, rx, _is_new) = request_or_join_approval(
        "test_tool",
        &serde_json::json!({"nonce": uuid::Uuid::new_v4().to_string()}),
    );
    (id, rx)
}

/// Resolve a pending approval. Called by Discord button handler or POST /api/approve.
/// Returns [`ResolveOutcome::Hit`] when a live receiver was found and notified,
/// [`ResolveOutcome::Orphan`] when the id was unknown (already resolved,
/// abandoned/superseded, or never existed) — callers should log this
/// distinction (RESILIENT-277 FIX4) instead of treating both cases as silent
/// success.
pub fn resolve_approval(request_id: &str, allowed: bool) -> ResolveOutcome {
    let outcome = if let Ok(mut guard) = pending().lock() {
        if let Some(entry) = guard.remove(request_id) {
            let _ = entry.tx.send(allowed);
            ResolveOutcome::Hit
        } else {
            ResolveOutcome::Orphan
        }
    } else {
        ResolveOutcome::Orphan
    };
    crate::pending_peer_approval::clear_pending_peer_approval(request_id);
    outcome
}

/// Abandon a pending request without resolving it (e.g. the wait timed out
/// and the caller gave up). Removes it from the pending map so a future
/// retry for the same (tool, args) mints a fresh request rather than joining
/// a channel nobody is listening to anymore, and callers can supersede the
/// stale UI card. No-op if already resolved/absent.
pub fn abandon(request_id: &str) {
    if let Ok(mut guard) = pending().lock() {
        guard.remove(request_id);
    }
    crate::pending_peer_approval::clear_pending_peer_approval(request_id);
}

/// True when `request_id` is still awaiting a decision (not yet resolved/expired).
/// Used by the INFRA-1340 Web Push escalation worker to skip pushing when the
/// operator already responded.
pub fn is_pending(request_id: &str) -> bool {
    if let Ok(guard) = pending().lock() {
        return guard.contains_key(request_id);
    }
    false
}

/// Default timeout for waiting for approval (seconds). Env CHUMP_APPROVAL_TIMEOUT_SECS.
pub fn approval_timeout_secs() -> u64 {
    std::env::var("CHUMP_APPROVAL_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60)
        .clamp(5, 600)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn resolve_sends_allow_to_receiver() {
        let (id, mut rx) = request_approval();
        assert_eq!(resolve_approval(&id, true), ResolveOutcome::Hit);
        assert!(rx.recv().await.unwrap());
    }

    #[tokio::test]
    async fn resolve_sends_deny_to_receiver() {
        let (id, mut rx) = request_approval();
        assert_eq!(resolve_approval(&id, false), ResolveOutcome::Hit);
        assert!(!rx.recv().await.unwrap());
    }

    #[tokio::test]
    async fn resolve_unknown_id_no_panic_and_reports_orphan() {
        assert_eq!(
            resolve_approval("00000000-0000-0000-0000-000000000099", true),
            ResolveOutcome::Orphan
        );
    }

    #[tokio::test]
    async fn resolve_after_abandon_is_orphan() {
        let (id, _rx) = request_approval();
        abandon(&id);
        assert_eq!(resolve_approval(&id, true), ResolveOutcome::Orphan);
    }

    #[test]
    fn same_tool_and_args_joins_existing_request() {
        let args = serde_json::json!({"command": "ls -la"});
        let (id1, _rx1, is_new1) = request_or_join_approval("run_cli", &args);
        assert!(is_new1);
        let (id2, _rx2, is_new2) = request_or_join_approval("run_cli", &args);
        assert_eq!(
            id1, id2,
            "second attempt should join the first, not mint a new id"
        );
        assert!(!is_new2);
        abandon(&id1);
    }

    #[test]
    fn args_key_ignores_field_order() {
        let a = serde_json::json!({"command": "ls", "cwd": "/tmp"});
        let b = serde_json::json!({"cwd": "/tmp", "command": "ls"});
        assert_eq!(normalize_args_key(&a), normalize_args_key(&b));
    }

    #[test]
    fn different_args_do_not_join() {
        let (id1, _rx1, _) =
            request_or_join_approval("run_cli", &serde_json::json!({"command": "ls"}));
        let (id2, _rx2, is_new2) =
            request_or_join_approval("run_cli", &serde_json::json!({"command": "rm -rf /tmp/x"}));
        assert!(is_new2);
        assert_ne!(id1, id2);
        abandon(&id1);
        abandon(&id2);
    }

    #[tokio::test]
    async fn joined_receiver_gets_same_resolution() {
        let args = serde_json::json!({"command": "ls"});
        let (id1, mut rx1, _) = request_or_join_approval("run_cli", &args);
        let (_id2, mut rx2, is_new2) = request_or_join_approval("run_cli", &args);
        assert!(!is_new2);
        assert_eq!(resolve_approval(&id1, true), ResolveOutcome::Hit);
        assert!(rx1.recv().await.unwrap());
        assert!(rx2.recv().await.unwrap());
    }
}
