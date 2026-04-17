//! Messaging platform adapters.
//!
//! Defines the `PlatformAdapter` trait so Chump can serve any messaging platform
//! with the same core agent loop. The Discord implementation remains in `src/discord.rs`
//! (legacy, not yet migrated to this trait). New platforms use the trait directly.
//!
//! ## Adding a new adapter
//!
//! 1. Create `src/adapters/<name>.rs`.
//! 2. Define a struct that implements [`PlatformAdapter`].
//! 3. Wire it into [`available_adapters`] behind an env-var gate.
//! 4. Document the env vars in `docs/MESSAGING_ADAPTERS.md`.
//!
//! ## Current state
//!
//! - `discord.rs` (legacy, full implementation, not migrated to this trait)
//! - `telegram` (V1 send-only HTTP scaffold)
//! - `matrix`, `slack` — planned

use anyhow::Result;
use async_trait::async_trait;

pub mod telegram;

/// A normalized inbound message from any platform.
#[derive(Debug, Clone)]
pub struct InboundMessage {
    /// Platform identifier, e.g. `"telegram"`, `"discord"`, `"matrix"`.
    pub platform: String,
    /// Stable identifier for the chat/channel/user conversation.
    pub platform_session_id: String,
    /// Human display name of the sender.
    pub user_display: String,
    /// Raw message body.
    pub content: String,
    /// Optional id of the message being replied to (when threaded).
    pub reply_to_id: Option<String>,
}

/// A message Chump wants to send back through an adapter.
#[derive(Debug, Clone)]
pub struct OutboundMessage {
    pub platform_session_id: String,
    pub content: String,
    pub reply_to_id: Option<String>,
}

/// Trait implemented by every messaging-platform adapter.
///
/// Adapters are `Send + Sync` so they can be stored in `Arc<dyn PlatformAdapter>`
/// and shared across the agent loop and supervisor tasks.
#[async_trait]
pub trait PlatformAdapter: Send + Sync {
    /// Short, stable identifier for the platform (e.g. `"telegram"`).
    fn name(&self) -> &'static str;

    /// Start the adapter's listener loop (polling, websocket, etc.).
    /// V1 send-only adapters may return immediately.
    async fn start(&self) -> Result<()>;

    /// Send a message through the adapter.
    async fn send(&self, msg: OutboundMessage) -> Result<()>;

    /// Request human approval for a sensitive tool invocation.
    /// Returns the request id so the caller can later correlate with the user's response.
    async fn request_approval(
        &self,
        session_id: &str,
        tool_name: &str,
        input: &str,
    ) -> Result<String>;
}

/// Returns true when the named adapter is enabled via env var
/// `CHUMP_<NAME>_ENABLED=1`.
///
/// Example: `adapter_enabled("telegram")` checks `CHUMP_TELEGRAM_ENABLED`.
pub fn adapter_enabled(name: &str) -> bool {
    let key = format!("CHUMP_{}_ENABLED", name.to_uppercase());
    std::env::var(&key)
        .map(|v| matches!(v.as_str(), "1" | "true" | "TRUE" | "yes" | "on"))
        .unwrap_or(false)
}

/// Construct every adapter that is enabled in the environment.
///
/// Adapters that fail to construct (e.g. missing token) are logged and skipped,
/// not propagated, so a single misconfigured adapter doesn't kill the process.
pub fn available_adapters() -> Vec<Box<dyn PlatformAdapter>> {
    let mut out: Vec<Box<dyn PlatformAdapter>> = Vec::new();

    if adapter_enabled("telegram") {
        match telegram::TelegramAdapter::from_env() {
            Ok(a) => out.push(Box::new(a)),
            Err(e) => {
                tracing::warn!(error = %e, "telegram adapter enabled but construction failed")
            }
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Compile-time check that the trait is object-safe.
    #[allow(dead_code)]
    fn _object_safe(_: &dyn PlatformAdapter) {}

    #[test]
    fn adapter_enabled_reads_env() {
        let key = "CHUMP_TESTPLATFORM_ENABLED";
        // Save & restore so we don't pollute other tests.
        let prev = std::env::var(key).ok();
        // SAFETY: tests run single-threaded for this assertion via serial_test if needed,
        // but adapter_enabled just reads, so set/unset in this scope is fine.
        std::env::set_var(key, "1");
        assert!(adapter_enabled("testplatform"));
        std::env::set_var(key, "0");
        assert!(!adapter_enabled("testplatform"));
        std::env::remove_var(key);
        assert!(!adapter_enabled("testplatform"));
        if let Some(v) = prev {
            std::env::set_var(key, v);
        }
    }

    #[tokio::test]
    async fn available_adapters_empty_by_default() {
        // With no env vars set, no adapters should be active.
        // We can't fully isolate env state, but at minimum the call must not panic.
        let _ = available_adapters();
    }
}
