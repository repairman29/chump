//! Telegram adapter (V1: send-only).
//!
//! V1 implements only outbound messages via the Telegram Bot HTTP API
//! (`POST https://api.telegram.org/bot<token>/sendMessage`). We deliberately use
//! `reqwest` (already a dependency) rather than pulling in `teloxide`, to keep the
//! build slim and avoid an optional crate dependency for the scaffold.
//!
//! V2 will add long-poll / webhook intake to wire inbound messages into the
//! agent loop. The trait method [`PlatformAdapter::start`] currently returns Ok
//! immediately as a no-op listener.
//!
//! ## Configuration
//!
//! - `CHUMP_TELEGRAM_ENABLED=1` — turns the adapter on.
//! - `TELEGRAM_BOT_TOKEN`       — bot token from @BotFather.
//!
//! ## Cargo feature
//!
//! A `telegram` cargo feature exists for forward compatibility (e.g. when we
//! adopt `teloxide` for V2 polling). Today the adapter compiles with no feature
//! flag because it only uses `reqwest`. The `#[cfg(feature = "telegram")]` /
//! `#[cfg(not(...))]` split below leaves room for the V2 implementation to gate
//! teloxide behind the feature.

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;

use super::{OutboundMessage, PlatformAdapter};

const TELEGRAM_API_BASE: &str = "https://api.telegram.org";

/// Send-only Telegram adapter using the Bot HTTP API.
#[derive(Debug, Clone)]
pub struct TelegramAdapter {
    bot_token: String,
    http: reqwest::Client,
}

impl TelegramAdapter {
    /// Construct an adapter from the explicit bot token.
    pub fn new(bot_token: impl Into<String>) -> Result<Self> {
        let bot_token = bot_token.into();
        if bot_token.trim().is_empty() {
            return Err(anyhow!("TELEGRAM_BOT_TOKEN is empty"));
        }
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .build()
            .context("building reqwest client for Telegram")?;
        Ok(Self { bot_token, http })
    }

    /// Construct an adapter by reading `TELEGRAM_BOT_TOKEN` from the env.
    pub fn from_env() -> Result<Self> {
        let token = std::env::var("TELEGRAM_BOT_TOKEN")
            .map_err(|_| anyhow!("TELEGRAM_BOT_TOKEN env var is not set"))?;
        Self::new(token)
    }

    fn endpoint(&self, method: &str) -> String {
        format!("{}/bot{}/{}", TELEGRAM_API_BASE, self.bot_token, method)
    }
}

#[async_trait]
impl PlatformAdapter for TelegramAdapter {
    fn name(&self) -> &'static str {
        "telegram"
    }

    /// V1: no-op. V2 will spawn a long-poll loop driving `getUpdates`.
    async fn start(&self) -> Result<()> {
        tracing::info!(
            adapter = self.name(),
            "telegram adapter started in send-only V1 mode (no inbound polling)"
        );
        Ok(())
    }

    async fn send(&self, msg: OutboundMessage) -> Result<()> {
        let url = self.endpoint("sendMessage");
        let mut body = serde_json::json!({
            "chat_id": msg.platform_session_id,
            "text": msg.content,
        });
        if let Some(reply_to) = msg.reply_to_id.as_deref() {
            // reply_to_message_id must be an integer in the Telegram API.
            if let Ok(parsed) = reply_to.parse::<i64>() {
                body["reply_to_message_id"] = serde_json::json!(parsed);
            }
        }

        let resp = self
            .http
            .post(&url)
            .json(&body)
            .send()
            .await
            .context("POST sendMessage")?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!(
                "telegram sendMessage failed: status={} body={}",
                status,
                text
            ));
        }
        Ok(())
    }

    async fn request_approval(
        &self,
        session_id: &str,
        tool_name: &str,
        input: &str,
    ) -> Result<String> {
        // V1: synthesize a human-readable prompt and send it. Approval correlation
        // (matching a user reply back to the request_id) lands with V2 inbound polling.
        let request_id = uuid::Uuid::new_v4().to_string();
        let body = format!(
            "Approval needed [{}]\nTool: {}\nInput: {}\nReply 'approve {}' or 'deny {}'.",
            &request_id[..8],
            tool_name,
            truncate(input, 800),
            &request_id[..8],
            &request_id[..8],
        );
        self.send(OutboundMessage {
            platform_session_id: session_id.to_string(),
            content: body,
            reply_to_id: None,
        })
        .await?;
        Ok(request_id)
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max])
    }
}

// ---------------------------------------------------------------------------
// Stub when the `telegram` feature is explicitly disabled but someone still
// references the future teloxide-backed entry points. Today the active impl
// above compiles unconditionally; this block is reserved for V2's poll loop.
// ---------------------------------------------------------------------------

#[cfg(not(feature = "telegram"))]
pub mod feature_stub {
    use anyhow::{anyhow, Result};

    /// Placeholder for V2 long-poll loop. Returns an error until the
    /// `telegram` cargo feature is enabled and the V2 implementation lands.
    pub async fn run_long_poll_loop() -> Result<()> {
        Err(anyhow!(
            "telegram feature not enabled: rebuild with `--features telegram` once V2 polling lands"
        ))
    }
}

#[cfg(feature = "telegram")]
pub mod feature_stub {
    use anyhow::Result;
    /// V2 long-poll loop will be implemented here once we adopt teloxide.
    pub async fn run_long_poll_loop() -> Result<()> {
        // Placeholder; real implementation pending V2.
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_token() {
        assert!(TelegramAdapter::new("").is_err());
        assert!(TelegramAdapter::new("   ").is_err());
    }

    #[test]
    fn constructs_with_token() {
        let a = TelegramAdapter::new("dummy:token").expect("construct");
        assert_eq!(a.name(), "telegram");
        assert!(a
            .endpoint("sendMessage")
            .contains("/botdummy:token/sendMessage"));
    }

    #[test]
    fn from_env_errors_when_unset() {
        // Snapshot & clear the env var for this assertion.
        let key = "TELEGRAM_BOT_TOKEN";
        let prev = std::env::var(key).ok();
        std::env::remove_var(key);
        let res = TelegramAdapter::from_env();
        assert!(res.is_err());
        if let Some(v) = prev {
            std::env::set_var(key, v);
        }
    }

    #[test]
    fn truncate_helper() {
        assert_eq!(truncate("abc", 10), "abc");
        assert_eq!(truncate("abcdef", 3), "abc…");
    }
}
