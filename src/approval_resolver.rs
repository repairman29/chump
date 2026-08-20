//! Pending tool-approval requests. Agent registers a request and blocks; Discord/web calls resolve_approval when the user allows/denies.
//!
//! RESILIENT-277: the retry loop used to mint a brand-new `request_id` (and a
//! brand-new Discord card) every time the model re-attempted a gated tool
//! call, abandoning every earlier receiver. A tap on any but the newest card
//! silently resolved nothing (`guard.remove` on an unknown id). FIX 1 below
//! dedupes in-flight requests by (tool, args) so a retry JOINS the existing
//! request instead of spawning a second one; a single `watch` channel lets
//! every joiner observe the same decision (unlike `oneshot`, which only
//! supports one receiver).

use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::watch;

/// Resolution state broadcast to every waiter on a pending approval.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalDecision {
    Pending,
    Allowed,
    Denied,
}

struct PendingRequest {
    /// Dedupe key this request was filed under, if any (`request_approval()`
    /// callers that don't have a natural key get `None` and are never joined).
    dedupe_key: Option<String>,
    tx: watch::Sender<ApprovalDecision>,
}

/// Both maps are always mutated together, so they share ONE mutex rather than
/// two independently-locked ones. Two separate mutexes (dedupe-then-pending
/// in `request_approval_for`, pending-then-dedupe in `resolve_approval`) is a
/// textbook lock-order inversion — deadlocks under concurrent access, which
/// is exactly the "duplicate approval requests firing concurrently" scenario
/// this module exists to handle.
#[derive(Default)]
struct State {
    pending: HashMap<String, PendingRequest>,
    /// dedupe key -> request_id currently holding it.
    dedupe: HashMap<String, String>,
}

/// Outcome of a `resolve_approval` call — distinguishes a tap that actually
/// found a live receiver from one that resolved nothing (RESILIENT-277 FIX4:
/// "make taps observable"). Before this, a tap on an orphaned card and a tap
/// that never arrived looked identical in the log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolveOutcome {
    /// A pending receiver was found and notified.
    Hit,
    /// No pending request existed for this id (already resolved, or the
    /// id belonged to a card that was superseded/abandoned).
    Orphan,
}

static STATE: std::sync::OnceLock<Mutex<State>> = std::sync::OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| Mutex::new(State::default()))
}

/// Build the dedupe key for an in-flight approval: same tool + same
/// human-readable args preview should resolve to the SAME request rather
/// than minting a second one (RESILIENT-277 FIX1).
pub fn dedupe_key(tool_name: &str, args_preview: &str) -> String {
    format!("{}::{}", tool_name, args_preview)
}

/// Create a pending approval request with no dedupe key (always a fresh id).
/// Kept for callers (tests, non-tool-gated approval flows) that have no
/// natural (tool, args) key to join on.
pub fn request_approval() -> (String, watch::Receiver<ApprovalDecision>) {
    let request_id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = watch::channel(ApprovalDecision::Pending);
    if let Ok(mut guard) = state().lock() {
        guard.pending.insert(
            request_id.clone(),
            PendingRequest {
                dedupe_key: None,
                tx,
            },
        );
    }
    (request_id, rx)
}

/// Create (or join) a pending approval request for `key` (see [`dedupe_key`]).
/// Returns `(request_id, receiver, joined)` — `joined=true` means an
/// in-flight request for the same key already existed and the caller should
/// NOT show a second UI card; it should just await the returned receiver
/// alongside whoever is already waiting.
pub fn request_approval_for(key: &str) -> (String, watch::Receiver<ApprovalDecision>, bool) {
    let mut guard = match state().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    if let Some(existing_id) = guard.dedupe.get(key) {
        if let Some(req) = guard.pending.get(existing_id) {
            return (existing_id.clone(), req.tx.subscribe(), true);
        }
    }
    let request_id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = watch::channel(ApprovalDecision::Pending);
    guard.pending.insert(
        request_id.clone(),
        PendingRequest {
            dedupe_key: Some(key.to_string()),
            tx,
        },
    );
    guard.dedupe.insert(key.to_string(), request_id.clone());
    (request_id, rx, false)
}

/// Resolve a pending approval. Called by Discord button handler or POST
/// /api/approve. Idempotent if request_id already resolved or unknown —
/// returns [`ResolveOutcome::Orphan`] in that case so the caller can log the
/// distinction instead of pretending the tap did something (RESILIENT-277 FIX4).
pub fn resolve_approval(request_id: &str, allowed: bool) -> ResolveOutcome {
    let outcome = {
        let mut guard = match state().lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(req) = guard.pending.remove(request_id) {
            let decision = if allowed {
                ApprovalDecision::Allowed
            } else {
                ApprovalDecision::Denied
            };
            let _ = req.tx.send(decision);
            if let Some(key) = req.dedupe_key {
                // Only clear the mapping if it still points at this id —
                // guards against clobbering a newer request that reused
                // the same key after this one was removed.
                if guard.dedupe.get(&key).map(|v| v.as_str()) == Some(request_id) {
                    guard.dedupe.remove(&key);
                }
            }
            ResolveOutcome::Hit
        } else {
            ResolveOutcome::Orphan
        }
    };
    crate::pending_peer_approval::clear_pending_peer_approval(request_id);
    outcome
}

/// Remove a request without resolving it in either direction — used when a
/// wait gives up (timeout) so a later retry with the same key mints a fresh
/// request rather than joining a channel nobody will ever send on again.
pub fn abandon(request_id: &str) {
    let mut guard = match state().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    if let Some(req) = guard.pending.remove(request_id) {
        if let Some(key) = req.dedupe_key {
            if guard.dedupe.get(&key).map(|v| v.as_str()) == Some(request_id) {
                guard.dedupe.remove(&key);
            }
        }
    }
}

/// True when `request_id` is still awaiting a decision (not yet resolved/expired).
/// Used by the INFRA-1340 Web Push escalation worker to skip pushing when the
/// operator already responded.
pub fn is_pending(request_id: &str) -> bool {
    if let Ok(guard) = state().lock() {
        return guard.pending.contains_key(request_id);
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
        rx.changed().await.unwrap();
        assert_eq!(*rx.borrow(), ApprovalDecision::Allowed);
    }

    #[tokio::test]
    async fn resolve_sends_deny_to_receiver() {
        let (id, mut rx) = request_approval();
        assert_eq!(resolve_approval(&id, false), ResolveOutcome::Hit);
        rx.changed().await.unwrap();
        assert_eq!(*rx.borrow(), ApprovalDecision::Denied);
    }

    #[tokio::test]
    async fn resolve_unknown_id_no_panic() {
        assert_eq!(
            resolve_approval("00000000-0000-0000-0000-000000000099", true),
            ResolveOutcome::Orphan
        );
    }

    #[tokio::test]
    async fn duplicate_request_joins_instead_of_minting_new_id() {
        let key = dedupe_key("run_cli", "echo hi");
        let (id1, _rx1, joined1) = request_approval_for(&key);
        assert!(
            !joined1,
            "first request for a key must not be marked joined"
        );
        let (id2, mut rx2, joined2) = request_approval_for(&key);
        assert!(joined2, "second request for the same key must join");
        assert_eq!(
            id1, id2,
            "joined request must reuse the original request_id"
        );

        // Resolving the ORIGINAL id notifies the joiner too — one card, one
        // live receiver, both waiters see the same decision.
        assert_eq!(resolve_approval(&id1, true), ResolveOutcome::Hit);
        rx2.changed().await.unwrap();
        assert_eq!(*rx2.borrow(), ApprovalDecision::Allowed);
    }

    #[tokio::test]
    async fn different_keys_never_join() {
        let (id1, _rx1, joined1) = request_approval_for(&dedupe_key("run_cli", "echo one"));
        let (id2, _rx2, joined2) = request_approval_for(&dedupe_key("run_cli", "echo two"));
        assert!(!joined1);
        assert!(!joined2);
        assert_ne!(id1, id2);
    }

    #[tokio::test]
    async fn abandon_lets_next_request_for_same_key_mint_fresh_id() {
        let key = dedupe_key("run_cli", "echo hi");
        let (id1, _rx1, _joined1) = request_approval_for(&key);
        abandon(&id1);
        assert!(!is_pending(&id1));
        let (id2, _rx2, joined2) = request_approval_for(&key);
        assert!(!joined2, "abandoned request must not be joined by a retry");
        assert_ne!(id1, id2);
    }

    #[tokio::test]
    async fn resolve_after_abandon_is_orphan() {
        let (id, _rx) = request_approval();
        abandon(&id);
        assert_eq!(resolve_approval(&id, true), ResolveOutcome::Orphan);
    }
}
