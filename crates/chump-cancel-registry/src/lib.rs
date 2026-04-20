//! AGT-002: Global registry of per-session `CancellationToken`s.
//!
//! When a web turn starts, the orchestrator calls [`register`] to store the
//! token keyed by `request_id`.  The `/api/stop` handler calls [`cancel`] to
//! fire it.  The token is removed when the turn ends (or is cancelled) via
//! [`unregister`].
//!
//! Tokens are created by the call site, not here — this module is only the
//! shared lookup table.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use tokio_util::sync::CancellationToken;

static REGISTRY: OnceLock<Mutex<HashMap<String, CancellationToken>>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<String, CancellationToken>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Register a cancellation token under `id` (typically the turn's `request_id`).
/// Any prior token stored under that id is silently replaced.
pub fn register(id: &str, token: CancellationToken) {
    let mut map = registry().lock().expect("cancel registry lock poisoned");
    map.insert(id.to_string(), token);
}

/// Remove the token for `id` (call when the turn finishes or is cancelled).
pub fn unregister(id: &str) {
    let mut map = registry().lock().expect("cancel registry lock poisoned");
    map.remove(id);
}

/// Fire the cancellation token for `id`.
///
/// Returns `true` if a token was found and cancelled, `false` if there was no
/// active turn under that id.
pub fn cancel(id: &str) -> bool {
    let map = registry().lock().expect("cancel registry lock poisoned");
    if let Some(token) = map.get(id) {
        token.cancel();
        true
    } else {
        false
    }
}

/// Create a fresh token, register it under `id`, and return it.
///
/// This is the preferred helper — call it at the start of each turn.
pub fn create_and_register(id: &str) -> CancellationToken {
    let token = CancellationToken::new();
    register(id, token.clone());
    token
}

#[cfg(test)]
mod tests {
    use super::*;

    // Note: tests share the global REGISTRY, so each test uses a unique id.

    #[test]
    fn create_and_register_returns_a_fresh_token() {
        let token = create_and_register("test-create-register-1");
        assert!(!token.is_cancelled());
        unregister("test-create-register-1");
    }

    #[test]
    fn cancel_fires_a_registered_token() {
        let token = create_and_register("test-cancel-fires-2");
        assert!(!token.is_cancelled());
        let was_present = cancel("test-cancel-fires-2");
        assert!(was_present);
        assert!(token.is_cancelled());
        unregister("test-cancel-fires-2");
    }

    #[test]
    fn cancel_returns_false_for_unknown_id() {
        let was_present = cancel("test-no-such-id-3");
        assert!(!was_present);
    }

    #[test]
    fn unregister_removes_the_entry() {
        let token = create_and_register("test-unregister-4");
        unregister("test-unregister-4");
        // After unregister, cancel should miss.
        let was_present = cancel("test-unregister-4");
        assert!(!was_present);
        // The previously-handed-out token is unaffected.
        assert!(!token.is_cancelled());
    }

    #[test]
    fn register_replaces_prior_token_at_same_id() {
        let first = create_and_register("test-replace-5");
        let second = create_and_register("test-replace-5");
        cancel("test-replace-5");
        // The most recent registration is the one that fires.
        assert!(second.is_cancelled());
        // The replaced token is NOT fired (no longer in the map).
        assert!(!first.is_cancelled());
        unregister("test-replace-5");
    }
}
