//! Telegram adapter — implements [`MessagingAdapter`].
//!
//! Migrated from `src/adapters/telegram.rs` as part of INFRA-MESSAGING-DEDUPE:
//! `PlatformAdapter` (send-only scaffold) retired; `MessagingAdapter` (richer
//! surface: `send_reply`, `send_dm`, `request_approval`) is the one true trait.
//!
//! ## V1 status
//!
//! Send-only via the Telegram Bot HTTP API (`sendMessage`). `start()` is a
//! no-op; V2 will add long-poll / webhook intake to drive inbound messages into
//! the agent loop (see AGT-004).
//!
//! ## Configuration
//!
//! - `CHUMP_TELEGRAM_ENABLED=1` — opt-in gate checked by [`available_adapters`].
//! - `TELEGRAM_BOT_TOKEN`       — bot token from @BotFather.
//!
//! ## Channel-id convention
//!
//! `IncomingMessage.channel_id` uses the prefix `"telegram:"`, e.g.
//! `"telegram:chat-123456789"`. `send_reply` strips the prefix to get the
//! raw Telegram `chat_id`.

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;

use super::{IncomingMessage, MessagingAdapter, OutgoingMessage};

const TELEGRAM_API_BASE: &str = "https://api.telegram.org";

/// Telegram Bot API adapter (V1: send-only).
#[derive(Debug, Clone)]
pub struct TelegramAdapter {
    bot_token: String,
    http: reqwest::Client,
}

impl TelegramAdapter {
    /// Construct with an explicit bot token.
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

    /// Construct by reading `TELEGRAM_BOT_TOKEN` from the environment.
    pub fn from_env() -> Result<Self> {
        let token = std::env::var("TELEGRAM_BOT_TOKEN")
            .map_err(|_| anyhow!("TELEGRAM_BOT_TOKEN env var is not set"))?;
        Self::new(token)
    }

    fn endpoint(&self, method: &str) -> String {
        format!("{}/bot{}/{}", TELEGRAM_API_BASE, self.bot_token, method)
    }

    /// Extract the raw Telegram chat_id from a namespaced `channel_id`.
    ///
    /// `"telegram:chat-123"` → `"123"` (strips `"telegram:chat-"` prefix).
    /// `"telegram:123456789"` → `"123456789"` (strips `"telegram:"` prefix).
    /// Unrecognised format: returned as-is so the API can fail with a real error.
    fn chat_id_from_channel(channel_id: &str) -> &str {
        channel_id
            .strip_prefix("telegram:chat-")
            .or_else(|| channel_id.strip_prefix("telegram:"))
            .unwrap_or(channel_id)
    }

    /// POST `sendMessage` to the Telegram Bot API.
    async fn send_message(&self, chat_id: &str, text: &str, reply_to: Option<i64>) -> Result<()> {
        let url = self.endpoint("sendMessage");
        // Telegram has a 4096-char limit; truncate gracefully.
        let text = truncate(text, 4096);
        let mut body = serde_json::json!({
            "chat_id": chat_id,
            "text": text,
        });
        if let Some(id) = reply_to {
            body["reply_to_message_id"] = serde_json::json!(id);
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
            let body = resp.text().await.unwrap_or_default();
            return Err(anyhow!(
                "telegram sendMessage failed: status={} body={}",
                status,
                body
            ));
        }
        Ok(())
    }
}

#[async_trait]
impl MessagingAdapter for TelegramAdapter {
    fn platform_name(&self) -> &str {
        "telegram"
    }

    /// V1: no-op listener. V2 will spawn a long-poll / webhook loop here.
    async fn start(&self) -> Result<()> {
        tracing::info!(
            adapter = self.platform_name(),
            "telegram adapter started in send-only V1 mode (no inbound polling)"
        );
        Ok(())
    }

    async fn send_reply(&self, incoming: &IncomingMessage, msg: OutgoingMessage) -> Result<()> {
        let chat_id = Self::chat_id_from_channel(&incoming.channel_id);
        // Honour in_reply_to when it's a numeric Telegram message-id.
        let reply_to = msg
            .in_reply_to
            .as_deref()
            .and_then(|s| s.parse::<i64>().ok());
        self.send_message(chat_id, &msg.text, reply_to).await
    }

    async fn send_dm(&self, user_id: &str, msg: OutgoingMessage) -> Result<()> {
        // In Telegram, `user_id` == `chat_id` for private chats.
        self.send_message(user_id, &msg.text, None).await
    }
    // request_approval uses the default MessagingAdapter impl:
    // send_dm(prompt) + return ApprovalResponse::Pending.
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max])
    }
}

/// Returns true when Telegram is enabled via `CHUMP_TELEGRAM_ENABLED=1`.
pub fn telegram_enabled() -> bool {
    std::env::var("CHUMP_TELEGRAM_ENABLED")
        .map(|v| matches!(v.as_str(), "1" | "true" | "TRUE" | "yes" | "on"))
        .unwrap_or(false)
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
        assert_eq!(a.platform_name(), "telegram");
        assert!(a
            .endpoint("sendMessage")
            .contains("/botdummy:token/sendMessage"));
    }

    #[test]
    fn from_env_errors_when_unset() {
        let key = "TELEGRAM_BOT_TOKEN";
        let prev = std::env::var(key).ok();
        std::env::remove_var(key);
        assert!(TelegramAdapter::from_env().is_err());
        if let Some(v) = prev {
            std::env::set_var(key, v);
        }
    }

    #[test]
    fn chat_id_extraction() {
        assert_eq!(
            TelegramAdapter::chat_id_from_channel("telegram:chat-123456"),
            "123456"
        );
        assert_eq!(
            TelegramAdapter::chat_id_from_channel("telegram:987654321"),
            "987654321"
        );
        assert_eq!(TelegramAdapter::chat_id_from_channel("raw"), "raw");
    }

    #[test]
    fn truncate_helper() {
        assert_eq!(truncate("abc", 10), "abc");
        assert_eq!(truncate("abcdef", 3), "abc…");
    }

    #[test]
    fn telegram_enabled_reads_env() {
        let key = "CHUMP_TELEGRAM_ENABLED";
        let prev = std::env::var(key).ok();
        std::env::set_var(key, "1");
        assert!(telegram_enabled());
        std::env::set_var(key, "0");
        assert!(!telegram_enabled());
        std::env::remove_var(key);
        assert!(!telegram_enabled());
        if let Some(v) = prev {
            std::env::set_var(key, v);
        }
    }
}
