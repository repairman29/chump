//! Bin-local Discord adapter shim. Implements the [`chump_messaging::MessagingAdapter`]
//! trait but reuses chump's existing `crate::discord_dm` helper for the actual DM send.
//!
//! Lives here (not in the standalone `chump-messaging` crate) because it
//! references the bin's internal `discord_dm` module — would force the
//! published crate to depend on chump-internal symbols.

use anyhow::Result;
use async_trait::async_trait;

use crate::messaging::{IncomingMessage, MessagingAdapter, OutgoingMessage};

/// Discord-flavored adapter shim. Reuses the existing `discord_dm` helper.
///
/// Real Discord startup is in `src/discord.rs::main_loop`, called from
/// `main.rs`'s `--discord` branch. Wiring the full event loop through this
/// trait is COMP-004a-b follow-up; the shim is here so the trait surface
/// has a concrete example.
pub struct DiscordShim;

#[async_trait]
impl MessagingAdapter for DiscordShim {
    fn platform_name(&self) -> &str {
        "discord"
    }

    async fn start(&self) -> Result<()> {
        anyhow::bail!(
            "DiscordShim::start unimplemented — Discord starts via main.rs --discord today. \
             See src/discord.rs::main_loop. The trait surface is the COMP-004a deliverable."
        )
    }

    async fn send_reply(&self, incoming: &IncomingMessage, _msg: OutgoingMessage) -> Result<()> {
        anyhow::bail!(
            "DiscordShim::send_reply unimplemented for channel {} — Discord replies go through \
             ctx.http inside the EventHandler today. Wiring through the shim is follow-up.",
            incoming.channel_id
        )
    }

    async fn send_dm(&self, user_id: &str, msg: OutgoingMessage) -> Result<()> {
        crate::discord_dm::send_dm_if_configured(&format!("[to:{}] {}", user_id, msg.text)).await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::messaging::ApprovalResponse;

    #[tokio::test]
    async fn discord_shim_default_approval_returns_pending() {
        let shim = DiscordShim;
        // Default impl tries send_dm then returns Pending. send_dm here
        // calls the real discord_dm helper which is a no-op when
        // CHUMP_DM_USER_ID isn't set in test env.
        let res = shim.request_approval("user-9", "approve?", 10).await;
        assert!(res.is_ok(), "default impl must not error in test env");
        assert_eq!(res.unwrap(), ApprovalResponse::Pending);
    }
}
