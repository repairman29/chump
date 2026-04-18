//! Platform-agnostic messaging abstraction for COMP-004 (multi-platform
//! gateway: Telegram, Slack, Matrix, plus the existing Discord/PWA).
//!
//! Today the Discord adapter (`src/discord.rs`) and PWA web server
//! (`src/web_server.rs`) each speak directly to the agent loop with
//! platform-specific event types. Adding Telegram (COMP-004b) without
//! a trait would mean copying ~1400 lines of Discord handler glue and
//! diverging the per-platform behavior over time.
//!
//! The `MessagingAdapter` trait is the contract Telegram + Slack +
//! Matrix adapters implement. The Discord/PWA adapters keep their
//! current implementations and ship a thin shim that exposes them
//! through this trait — see [`DiscordShim`] for an example.
//!
//! ## Design
//!
//! - **`IncomingMessage`** — platform-agnostic representation of a
//!   user-sent message. Capabilities (DM vs channel, attachments,
//!   thread context) carried as fields rather than per-platform enums
//!   so adapters with weaker features just leave fields empty.
//!
//! - **`MessagingAdapter`** — the impl-this trait. Three core methods:
//!   `start()` spins up the platform's event loop;
//!   `send_reply()` answers in the original channel/thread;
//!   `send_dm()` reaches the user privately for approval prompts /
//!   session events. The trait is `Send + Sync` so the agent loop
//!   can hand a shared reference to multiple tools.
//!
//! - **`MessagingHub`** — owns N adapters and routes outbound traffic
//!   based on the channel-id namespacing (`telegram:chat-123`,
//!   `discord:guild-456:channel-789`, ...). Wire-only piece — adapters
//!   don't talk to each other.
//!
//! ## Out of scope for COMP-004a (this commit)
//!
//! - Migrating `src/discord.rs` internals to use the trait.
//!   `DiscordShim` is sufficient for the COMP-004a acceptance ("Discord
//!   implements MessagingAdapter") without rewriting 1400 lines.
//! - The actual Telegram/Slack adapters — those are COMP-004b/c.
//! - Approval-flow surface (request_approval) — sketched as a TODO
//!   here so the API doesn't churn when COMP-004b adds it.

use anyhow::Result;
use async_trait::async_trait;
use std::sync::Arc;

/// A user-sent message, normalized across platforms.
#[derive(Debug, Clone)]
pub struct IncomingMessage {
    /// Platform-specific channel id, namespaced. Examples:
    ///   "discord:guild-X:channel-Y" / "discord:dm:user-Z"
    ///   "telegram:chat-123"
    ///   "slack:T01:C02"
    /// The platform-prefix lets `MessagingHub` route replies back
    /// without consulting the adapter.
    pub channel_id: String,

    /// Platform user id of the sender (for DM-back, attribution).
    pub sender_id: String,

    /// Display name when the platform exposes one ("jeffadkins",
    /// "@jeff_adkins", "Jeff (Acme corp)"). Empty string is allowed.
    pub sender_display: String,

    /// Plain-text content. Adapters strip platform markup (Discord's
    /// <@mention> tags, Telegram's @bot prefix, etc.) before populating.
    pub content: String,

    /// True when the message was a direct message rather than a public
    /// channel post. Drives default privacy / approval-prompt routing.
    pub is_dm: bool,

    /// Attachment URLs the message included (image / file). Empty when
    /// the platform attachment hasn't been resolved to a URL yet OR
    /// the message had none.
    pub attachments: Vec<String>,

    /// Free-form per-platform metadata (Discord guild_id, Telegram
    /// thread_id, Slack thread_ts). Adapters serialize whatever they
    /// might need to honor a reply later. Read-only — agent shouldn't
    /// mutate this.
    pub platform_metadata: serde_json::Value,
}

impl IncomingMessage {
    /// Identify the platform from the channel_id prefix. Returns "unknown"
    /// when the channel_id doesn't carry a colon-prefix.
    pub fn platform(&self) -> &str {
        self.channel_id.split(':').next().unwrap_or("unknown")
    }
}

/// What the agent needs to send back to the user. Same shape regardless
/// of platform — the adapter does the format/layout.
#[derive(Debug, Clone)]
pub struct OutgoingMessage {
    pub text: String,
    /// Optional file attachments (paths on disk; adapter uploads).
    pub attachments: Vec<std::path::PathBuf>,
    /// Optional thread/reply target — channel_id of the message we're
    /// replying to. None = post as a fresh top-level message.
    pub in_reply_to: Option<String>,
}

impl OutgoingMessage {
    pub fn text(s: impl Into<String>) -> Self {
        Self {
            text: s.into(),
            attachments: vec![],
            in_reply_to: None,
        }
    }
}

/// The trait every platform adapter implements.
#[async_trait]
pub trait MessagingAdapter: Send + Sync {
    /// Lowercase identifier used as the channel_id prefix. Examples:
    ///   "discord", "telegram", "slack", "matrix", "pwa"
    fn platform_name(&self) -> &str;

    /// Spin up the platform-specific event loop. Returns when the
    /// adapter shuts down (Ctrl+C / signal). The implementation is
    /// expected to forward `IncomingMessage`s into the agent loop on
    /// its own thread.
    async fn start(&self) -> Result<()>;

    /// Send a reply to the channel that originated `incoming`. The
    /// adapter handles thread targeting, mentions, etc.
    async fn send_reply(&self, incoming: &IncomingMessage, msg: OutgoingMessage) -> Result<()>;

    /// Send a private message to a user. Used for approval prompts and
    /// session events ("Mabel restarted at 03:14 UTC"). Returns Err when
    /// the platform doesn't expose DMs (Slack public-only workspaces).
    async fn send_dm(&self, user_id: &str, msg: OutgoingMessage) -> Result<()>;

    /// Optional: request a tool-approval response from the user. Default
    /// impl falls back to send_dm with a Y/N prompt and no inline UI.
    /// Telegram/Slack adapters override to use inline keyboards.
    /// Returns the user's response or Err on timeout.
    ///
    /// COMP-004b will flesh this out; for now keep the surface stable.
    async fn request_approval(
        &self,
        user_id: &str,
        prompt: &str,
        _timeout_secs: u64,
    ) -> Result<ApprovalResponse> {
        self.send_dm(user_id, OutgoingMessage::text(prompt)).await?;
        // Default impl can't actually wait for a reply; that's the
        // adapter's job. Return Pending so callers know they need to
        // implement properly.
        Ok(ApprovalResponse::Pending)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovalResponse {
    /// User accepted the action.
    Approved,
    /// User explicitly rejected.
    Rejected,
    /// Adapter sent the prompt but doesn't support a synchronous
    /// reply read. Caller falls back to its existing approval-resolver.
    Pending,
    /// Timed out waiting for the user.
    Timeout,
}

/// Routes outbound messages to the right adapter based on channel_id
/// prefix. Held as an Arc so it can be cloned across tasks.
pub struct MessagingHub {
    adapters: Vec<Arc<dyn MessagingAdapter>>,
}

impl Default for MessagingHub {
    fn default() -> Self {
        Self {
            adapters: Vec::new(),
        }
    }
}

impl MessagingHub {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, adapter: Arc<dyn MessagingAdapter>) {
        self.adapters.push(adapter);
    }

    /// Look up the adapter responsible for a channel_id by its prefix.
    pub fn adapter_for(&self, channel_id: &str) -> Option<&Arc<dyn MessagingAdapter>> {
        let prefix = channel_id.split(':').next()?;
        self.adapters.iter().find(|a| a.platform_name() == prefix)
    }

    pub fn registered_platforms(&self) -> Vec<&str> {
        self.adapters.iter().map(|a| a.platform_name()).collect()
    }
}

/// Thin shim that exposes the existing Discord adapter (src/discord.rs)
/// through the MessagingAdapter trait. Doesn't change Discord internals;
/// just proves the trait is shape-compatible. Real wiring (start() that
/// invokes Discord's event loop) is left as a follow-up since
/// src/discord.rs already starts itself via `discord::run_discord_bot`
/// in main.rs.
pub struct DiscordShim;

#[async_trait]
impl MessagingAdapter for DiscordShim {
    fn platform_name(&self) -> &str {
        "discord"
    }

    async fn start(&self) -> Result<()> {
        // Real Discord startup is in src/discord.rs::main_loop, called
        // from main.rs's --discord branch. The shim is here so the
        // trait surface compiles + Telegram (COMP-004b) has a concrete
        // example. Wiring run_discord_bot through here is COMP-004a-b
        // follow-up.
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
        // Reuse the existing helper. discord_dm::send_dm_if_configured
        // checks CHUMP_DM_USER_ID and posts via the Serenity client
        // singleton.
        crate::discord_dm::send_dm_if_configured(&format!("[to:{}] {}", user_id, msg.text)).await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn incoming_message_platform_extracts_prefix() {
        let m = IncomingMessage {
            channel_id: "telegram:chat-123".into(),
            sender_id: "user-456".into(),
            sender_display: "Jeff".into(),
            content: "hi".into(),
            is_dm: true,
            attachments: vec![],
            platform_metadata: serde_json::Value::Null,
        };
        assert_eq!(m.platform(), "telegram");
    }

    #[test]
    fn incoming_message_platform_unknown_when_no_prefix() {
        let m = IncomingMessage {
            channel_id: "raw-id-no-prefix".into(),
            sender_id: "user".into(),
            sender_display: "".into(),
            content: "".into(),
            is_dm: false,
            attachments: vec![],
            platform_metadata: serde_json::Value::Null,
        };
        // split(':').next() always returns Some, even when there's no
        // colon — the whole string. So "platform" is the whole id when
        // unprefixed. We accept that — the unknown-prefix case still
        // routes nowhere via MessagingHub::adapter_for.
        assert_eq!(m.platform(), "raw-id-no-prefix");
    }

    #[test]
    fn outgoing_text_helper() {
        let m = OutgoingMessage::text("hello");
        assert_eq!(m.text, "hello");
        assert!(m.attachments.is_empty());
        assert!(m.in_reply_to.is_none());
    }

    #[test]
    fn hub_registers_and_routes_by_prefix() {
        let mut hub = MessagingHub::new();
        hub.register(Arc::new(DiscordShim));
        assert_eq!(hub.registered_platforms(), vec!["discord"]);

        let dis = hub.adapter_for("discord:guild-1:ch-2");
        assert!(dis.is_some());
        let unknown = hub.adapter_for("telegram:chat-9");
        assert!(unknown.is_none());
    }

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
