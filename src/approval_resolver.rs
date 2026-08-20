//! Pending tool-approval requests. Agent registers a request and blocks; Discord/web calls resolve_approval when the user allows/denies.
//!
//! RESILIENT-277: a naive retry loop that mints a fresh `request_id` on every
//! attempt produces N different cards for the *same* logical question, but
//! only the newest has a live receiver — tapping any older card resolves an
//! id nobody is waiting on. [`request_approval`] dedupes in-flight requests
//! by (tool, normalized args) via [`watch::channel`] so every caller asking
//! the same question joins the one live request instead of minting a new
//! receiver that orphans the others.

use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::watch;

/// Receiver side of a (possibly shared) pending approval.
pub type ApprovalReceiver = watch::Receiver<Option<bool>>;

struct PendingEntry {
    tx: watch::Sender<Option<bool>>,
    dedupe_key: String,
}

/// Result of [`request_approval`]: the request_id to render on the card
/// (existing id if joined) plus whether this call joined an already-pending
/// request rather than minting a new one.
pub struct ApprovalHandle {
    pub request_id: String,
    pub joined: bool,
    pub rx: ApprovalReceiver,
}

/// Outcome of [`resolve_approval`] — did it find a live receiver (HIT) or
/// was the id unknown/already resolved (ORPHAN)? RESILIENT-277 FIX 4: taps
/// that resolve nothing used to look identical in the log to taps that never
/// arrived. Callers should log this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolveOutcome {
    Hit,
    Orphan,
}

static PENDING: std::sync::OnceLock<Mutex<HashMap<String, PendingEntry>>> =
    std::sync::OnceLock::new();
static PENDING_BY_KEY: std::sync::OnceLock<Mutex<HashMap<String, String>>> =
    std::sync::OnceLock::new();

fn pending() -> &'static Mutex<HashMap<String, PendingEntry>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

fn pending_by_key() -> &'static Mutex<HashMap<String, String>> {
    PENDING_BY_KEY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Stable dedupe key for "the same question" — tool name + normalized args.
/// Two calls with identical tool + args produce the same key; a retry loop
/// asking the identical question joins the existing request instead of
/// minting a second one.
pub fn dedupe_key(tool_name: &str, args: &serde_json::Value) -> String {
    format!(
        "{}::{}",
        tool_name.to_lowercase(),
        serde_json::to_string(args).unwrap_or_default()
    )
}

/// Create (or join) a pending approval request for `tool_name`/`args`.
/// RESILIENT-277 FIX 1: if a request for the same (tool, normalized args) is
/// already pending, this returns `joined: true` with the *existing*
/// request_id and a fresh subscription to the same channel — callers should
/// NOT emit a second approval card for a joined request. Caller should emit
/// the approval UI only when `joined` is false, then await `rx` (with
/// timeout). Resolver calls `resolve_approval(request_id, allowed)`.
pub fn request_approval(tool_name: &str, args: &serde_json::Value) -> ApprovalHandle {
    let key = dedupe_key(tool_name, args);
    if let Some(existing_id) = pending_by_key()
        .lock()
        .ok()
        .and_then(|g| g.get(&key).cloned())
    {
        if let Some(rx) = pending()
            .lock()
            .ok()
            .and_then(|g| g.get(&existing_id).map(|e| e.tx.subscribe()))
        {
            return ApprovalHandle {
                request_id: existing_id,
                joined: true,
                rx,
            };
        }
    }
    let request_id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = watch::channel(None);
    if let Ok(mut guard) = pending().lock() {
        guard.insert(
            request_id.clone(),
            PendingEntry {
                tx,
                dedupe_key: key.clone(),
            },
        );
    }
    if let Ok(mut guard) = pending_by_key().lock() {
        guard.insert(key, request_id.clone());
    }
    ApprovalHandle {
        request_id,
        joined: false,
        rx,
    }
}

/// Resolve a pending approval (allow/deny). Called by the Discord button
/// handler or POST /api/approve. Notifies every joined waiter (RESILIENT-277
/// FIX 1) and removes the request so a later tap on the same (now-dead) card
/// is an observable ORPHAN rather than a silent no-op (FIX 4).
pub fn resolve_approval(request_id: &str, allowed: bool) -> ResolveOutcome {
    resolve_with_label(request_id, allowed, "tap")
}

/// Expire a pending approval that timed out waiting for a decision. Distinct
/// label from [`resolve_approval`] so UI cards can say "timed out" instead of
/// "denied". Idempotent/safe if the request was already resolved by a tap
/// that raced with the timeout (returns ORPHAN).
pub fn expire_approval(request_id: &str) -> ResolveOutcome {
    resolve_with_label(request_id, false, "timeout")
}

fn resolve_with_label(request_id: &str, allowed: bool, via: &'static str) -> ResolveOutcome {
    let entry = pending().lock().ok().and_then(|mut g| g.remove(request_id));
    let outcome = match entry {
        Some(entry) => {
            let _ = entry.tx.send(Some(allowed));
            if let Ok(mut by_key) = pending_by_key().lock() {
                if by_key.get(&entry.dedupe_key).map(|v| v.as_str()) == Some(request_id) {
                    by_key.remove(&entry.dedupe_key);
                }
            }
            ResolveOutcome::Hit
        }
        None => ResolveOutcome::Orphan,
    };
    // RESILIENT-277 FIX 4: a tap that arrived and a tap that never came used
    // to look identical in the log — this is the line that tells them apart.
    tracing::info!(
        request_id = %request_id,
        allowed,
        via,
        outcome = ?outcome,
        "resolve_approval"
    );
    crate::pending_peer_approval::clear_pending_peer_approval(request_id);
    outcome
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
    use serde_json::json;

    #[tokio::test]
    async fn resolve_sends_allow_to_receiver() {
        let mut handle = request_approval("run_cli", &json!({"command": "echo hi"}));
        assert!(!handle.joined);
        assert_eq!(
            resolve_approval(&handle.request_id, true),
            ResolveOutcome::Hit
        );
        handle.rx.changed().await.unwrap();
        assert_eq!(*handle.rx.borrow(), Some(true));
    }

    #[tokio::test]
    async fn resolve_sends_deny_to_receiver() {
        let mut handle = request_approval("run_cli", &json!({"command": "echo bye"}));
        resolve_approval(&handle.request_id, false);
        handle.rx.changed().await.unwrap();
        assert_eq!(*handle.rx.borrow(), Some(false));
    }

    #[tokio::test]
    async fn resolve_unknown_id_is_orphan_no_panic() {
        assert_eq!(
            resolve_approval("00000000-0000-0000-0000-000000000099", true),
            ResolveOutcome::Orphan
        );
    }

    #[tokio::test]
    async fn second_request_same_tool_and_args_joins_first() {
        let args = json!({"command": "cargo test"});
        let h1 = request_approval("run_cli", &args);
        let h2 = request_approval("run_cli", &args);
        assert!(!h1.joined);
        assert!(h2.joined, "second identical request should join the first");
        assert_eq!(h1.request_id, h2.request_id);
        resolve_approval(&h1.request_id, true);
    }

    #[tokio::test]
    async fn joined_receiver_gets_notified_on_resolve() {
        let args = json!({"command": "cargo build"});
        let h1 = request_approval("run_cli_dedupe_test", &args);
        let mut h2 = request_approval("run_cli_dedupe_test", &args);
        assert!(h2.joined);
        resolve_approval(&h1.request_id, true);
        h2.rx.changed().await.unwrap();
        assert_eq!(*h2.rx.borrow(), Some(true));
    }

    #[tokio::test]
    async fn different_args_do_not_join() {
        let h1 = request_approval("run_cli", &json!({"command": "ls"}));
        let h2 = request_approval("run_cli", &json!({"command": "pwd"}));
        assert!(!h2.joined);
        assert_ne!(h1.request_id, h2.request_id);
        resolve_approval(&h1.request_id, false);
        resolve_approval(&h2.request_id, false);
    }

    #[tokio::test]
    async fn resolved_request_frees_dedupe_key_for_a_fresh_ask() {
        let args = json!({"command": "unique_key_test_cmd"});
        let h1 = request_approval("run_cli", &args);
        resolve_approval(&h1.request_id, true);
        // Once resolved, a fresh ask for the same (tool, args) must NOT join
        // the dead entry — it should mint a new live request.
        let h2 = request_approval("run_cli", &args);
        assert!(!h2.joined);
        assert_ne!(h1.request_id, h2.request_id);
        resolve_approval(&h2.request_id, false);
    }
}
