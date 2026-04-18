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
    let mut map = registry().lock().unwrap();
    map.insert(id.to_string(), token);
}

/// Remove the token for `id` (call when the turn finishes or is cancelled).
pub fn unregister(id: &str) {
    let mut map = registry().lock().unwrap();
    map.remove(id);
}

/// Fire the cancellation token for `id`.
///
/// Returns `true` if a token was found and cancelled, `false` if there was no
/// active turn under that id.
pub fn cancel(id: &str) -> bool {
    let map = registry().lock().unwrap();
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
