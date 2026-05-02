//! Telegram messaging adapter (COMP-004b).
//!
//! V1: reqwest-only long-poll loop using the Telegram Bot HTTP API. No
//! new crate deps. Send-text + receive-text + DM-back. Inline-keyboard
//! approval flow is V2 work.
//!
//! Set `TELEGRAM_BOT_TOKEN` in `.env` (created via @BotFather → /newbot).
//! Run with `chump --telegram`.
//!
//! Implements [`crate::messaging::MessagingAdapter`] (COMP-004a). On
//! incoming message: routes through the same agent loop as Discord.
//! On outgoing reply: posts to `sendMessage` against the originating
//! chat_id.
//!
//! Two key differences vs Discord:
//!
//! 1. **Long-poll, not WebSocket.** Telegram's bot API uses HTTP
//!    long-poll (`getUpdates?timeout=N`). Each iteration blocks up to N
//!    seconds waiting for new messages. We use 25s — Telegram's max is
//!    50s but their proxies sometimes 504 around 30+.
//!
//! 2. **chat_id is the channel.** Telegram doesn't have a server/channel
//!    hierarchy; `chat_id` is both the routing target AND the user-/
//!    group-identifier. We namespace as `telegram:<chat_id>` so
//!    `MessagingHub::adapter_for` can route replies back.

use crate::messaging::{ApprovalResponse, IncomingMessage, MessagingAdapter, OutgoingMessage};
use crate::platform_router::{InputQueue, PlatformMessage};
use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// HTTP base for the Telegram Bot API. Override via `TELEGRAM_API_BASE`
/// for testing against a mock.
fn api_base() -> String {
    std::env::var("TELEGRAM_API_BASE").unwrap_or_else(|_| "https://api.telegram.org".to_string())
}

/// Long-poll timeout in seconds. Telegram caps at 50; we use 25 to
/// avoid proxy 504s. Override via `TELEGRAM_POLL_TIMEOUT_SECS`.
fn poll_timeout_secs() -> u32 {
    std::env::var("TELEGRAM_POLL_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&s: &u32| s > 0 && s <= 50)
        .unwrap_or(25)
}

#[derive(Debug, Clone)]
pub struct TelegramAdapter {
    token: String,
    /// Highest update_id we've acknowledged. Telegram returns
    /// updates with id > offset; passing offset = max_seen + 1 acks them.
    last_offset: Arc<AtomicI64>,
    client: reqwest::Client,
    /// When set, incoming messages are pushed into the shared
    /// `platform_router` queue instead of being dispatched inline.
    /// Use `with_queue()` to attach a queue after construction.
    queue: Option<InputQueue>,
}

impl TelegramAdapter {
    /// Build from `TELEGRAM_BOT_TOKEN`. Fails when the env var is unset
    /// or when the token doesn't validate against `getMe` (catches
    /// typo'd tokens at startup, not at first message).
    pub async fn from_env() -> Result<Self> {
        let token = std::env::var("TELEGRAM_BOT_TOKEN").context(
            "TELEGRAM_BOT_TOKEN not set. Get one from @BotFather → /newbot, then add to .env.",
        )?;
        if token.trim().is_empty() {
            return Err(anyhow!("TELEGRAM_BOT_TOKEN is empty"));
        }
        let client = reqwest::Client::builder()
            // Long-poll plus a small buffer.
            .timeout(Duration::from_secs(poll_timeout_secs() as u64 + 10))
            .build()
            .context("reqwest client build")?;
        let adapter = Self {
            token: token.trim().to_string(),
            last_offset: Arc::new(AtomicI64::new(0)),
            client,
            queue: None,
        };
        adapter.validate_token().await?;
        Ok(adapter)
    }

    /// Attach a platform-router queue. When set, incoming messages are
    /// pushed to the queue instead of being handled inline. Returns
    /// `self` so this can be chained after `from_env()`.
    pub fn with_queue(mut self, queue: InputQueue) -> Self {
        self.queue = Some(queue);
        self
    }

    async fn validate_token(&self) -> Result<()> {
        let url = format!("{}/bot{}/getMe", api_base(), self.token);
        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .context("getMe request failed")?;
        let status = resp.status();
        let body: serde_json::Value = resp.json().await.context("getMe response not JSON")?;
        if !status.is_success() || body["ok"] != true {
            return Err(anyhow!("getMe failed (HTTP {}): {}", status, body));
        }
        let username = body["result"]["username"].as_str().unwrap_or("?");
        tracing::info!(username, "telegram: bot validated");
        Ok(())
    }

    fn chat_id_to_channel(chat_id: i64) -> String {
        format!("telegram:{}", chat_id)
    }

    fn channel_to_chat_id(channel: &str) -> Option<i64> {
        channel.strip_prefix("telegram:")?.parse().ok()
    }

    /// One getUpdates poll. Returns the parsed updates and updates the
    /// offset for next call. Long-polls up to `poll_timeout_secs()` for
    /// new messages.
    async fn poll_updates(&self) -> Result<Vec<TelegramUpdate>> {
        let offset = self.last_offset.load(Ordering::Relaxed);
        let url = format!("{}/bot{}/getUpdates", api_base(), self.token);
        let resp = self
            .client
            .get(&url)
            .query(&[
                ("offset", offset.to_string()),
                ("timeout", poll_timeout_secs().to_string()),
                ("allowed_updates", "[\"message\"]".to_string()),
            ])
            .send()
            .await
            .context("getUpdates request failed")?;
        let body: TelegramApiResponse<Vec<TelegramUpdate>> = resp
            .json()
            .await
            .context("getUpdates response parse failed")?;
        if !body.ok {
            return Err(anyhow!(
                "getUpdates returned ok=false: {:?}",
                body.description
            ));
        }
        let updates = body.result.unwrap_or_default();
        if let Some(max_id) = updates.iter().map(|u| u.update_id).max() {
            self.last_offset.store(max_id + 1, Ordering::Relaxed);
        }
        Ok(updates)
    }

    /// POST a sendMessage. text is plain — no Markdown parse_mode for V1
    /// to avoid escaping foot-guns. Returns the sent message_id when
    /// available, or just () on the error path.
    async fn send_message(&self, chat_id: i64, text: &str) -> Result<()> {
        let url = format!("{}/bot{}/sendMessage", api_base(), self.token);
        // Telegram caps single messages at 4096 chars. Truncate noisily
        // — better than the API hard-rejecting our long agent reply.
        let truncated = if text.chars().count() > 4096 {
            let mut t: String = text.chars().take(4090).collect();
            t.push_str("\n[…]");
            t
        } else {
            text.to_string()
        };
        let resp = self
            .client
            .post(&url)
            .json(&serde_json::json!({
                "chat_id": chat_id,
                "text": truncated,
            }))
            .send()
            .await
            .context("sendMessage request failed")?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(anyhow!("sendMessage HTTP {}: {}", status, body));
        }
        Ok(())
    }

    /// Convert a Telegram update into a normalized IncomingMessage,
    /// or None for updates that aren't text messages we care about.
    fn update_to_incoming(&self, update: &TelegramUpdate) -> Option<IncomingMessage> {
        let msg = update.message.as_ref()?;
        // text-only V1; ignore stickers / photos / etc until COMP-005a-tg.
        let text = msg.text.clone()?;
        let chat_id = msg.chat.id;
        let from = msg.from.as_ref();
        // is_dm: Telegram's chat.type == "private" means a 1:1 DM.
        let is_dm = msg.chat.kind.as_deref() == Some("private");
        Some(IncomingMessage {
            channel_id: Self::chat_id_to_channel(chat_id),
            sender_id: from.map(|f| f.id.to_string()).unwrap_or_default(),
            sender_display: from
                .and_then(|f| f.username.clone().or_else(|| f.first_name.clone()))
                .unwrap_or_default(),
            content: text,
            is_dm,
            attachments: vec![],
            platform_metadata: serde_json::json!({
                "chat_id": chat_id,
                "chat_type": msg.chat.kind,
                "message_id": msg.message_id,
                "date": msg.date,
            }),
        })
    }
}

#[async_trait]
impl MessagingAdapter for TelegramAdapter {
    fn platform_name(&self) -> &str {
        "telegram"
    }

    /// Long-poll loop. Each iteration:
    ///   - call getUpdates (blocks up to ~25s for new messages)
    ///   - for each text message: build an IncomingMessage and forward
    ///     to the agent loop (V1: just echo / minimal handler)
    ///
    /// Runs until process exit or unrecoverable Telegram error.
    async fn start(&self) -> Result<()> {
        tracing::info!("telegram: long-poll loop starting");
        loop {
            match self.poll_updates().await {
                Ok(updates) => {
                    for u in updates.iter() {
                        if let Some(incoming) = self.update_to_incoming(u) {
                            tracing::info!(
                                from = incoming.sender_display.as_str(),
                                channel = incoming.channel_id.as_str(),
                                len = incoming.content.len(),
                                "telegram: incoming message"
                            );
                            if let Some(q) = &self.queue {
                                // Route through the shared platform-router
                                // queue — agent dispatch happens off the
                                // poll loop in a separate tokio task.
                                let msg = PlatformMessage {
                                    incoming,
                                    adapter: Arc::new(self.clone()),
                                };
                                if q.try_send(msg).is_err() {
                                    tracing::warn!("platform_router queue full; dropping message");
                                }
                            } else {
                                // Fallback (no queue): handle inline as
                                // before. Used by tests and any code path
                                // that doesn't attach a queue.
                                if let Err(e) = self.handle_incoming(&incoming).await {
                                    tracing::warn!(
                                        error = %e,
                                        channel = incoming.channel_id.as_str(),
                                        "telegram: handle_incoming failed"
                                    );
                                    let _ = self
                                        .send_reply(
                                            &incoming,
                                            OutgoingMessage::text(format!("agent error: {}", e)),
                                        )
                                        .await;
                                }
                            }
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!(error = %e, "telegram: poll error; backing off 5s");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            }
        }
    }

    async fn send_reply(&self, incoming: &IncomingMessage, msg: OutgoingMessage) -> Result<()> {
        let chat_id = Self::channel_to_chat_id(&incoming.channel_id)
            .ok_or_else(|| anyhow!("not a telegram channel: {}", incoming.channel_id))?;
        self.send_message(chat_id, &msg.text).await
    }

    async fn send_dm(&self, user_id: &str, msg: OutgoingMessage) -> Result<()> {
        // For Telegram, the user_id IS the chat_id of their DM thread.
        let chat_id: i64 = user_id
            .parse()
            .with_context(|| format!("user_id not a Telegram numeric id: {}", user_id))?;
        self.send_message(chat_id, &msg.text).await
    }

    async fn request_approval(
        &self,
        user_id: &str,
        prompt: &str,
        _timeout_secs: u64,
    ) -> Result<ApprovalResponse> {
        // V1: send the prompt as a regular DM with a Y/N footer. Inline
        // keyboards are V2 (COMP-004b-keyboards). Caller's existing
        // approval-resolver flow handles the actual decision.
        let augmented = format!("{}\n\nReply Y to approve or N to reject.", prompt);
        self.send_dm(user_id, OutgoingMessage::text(augmented))
            .await?;
        Ok(ApprovalResponse::Pending)
    }
}

impl TelegramAdapter {
    /// Hand off the incoming message to the agent loop. V1: builds a
    /// one-shot ChumpAgent (mirroring Discord's `build_chump_agent_cli`)
    /// and posts the reply back. Conversation history per-chat is NOT
    /// persisted yet — each message is a fresh session.
    async fn handle_incoming(&self, incoming: &IncomingMessage) -> Result<()> {
        let (agent, ready_session) = crate::agent_factory::build_chump_agent_cli()
            .map_err(|e| anyhow!("build_chump_agent_cli: {}", e))?;
        let running = ready_session.start();
        let outcome = agent
            .run(&incoming.content)
            .await
            .map_err(|e| anyhow!("agent.run: {}", e))?;
        running.close();
        let reply = crate::thinking_strip::strip_for_public_reply(&outcome.reply);
        self.send_reply(incoming, OutgoingMessage::text(reply))
            .await
    }
}

// ── Telegram API DTOs ─────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct TelegramApiResponse<T> {
    ok: bool,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    result: Option<T>,
}

#[derive(Debug, Deserialize)]
struct TelegramUpdate {
    update_id: i64,
    #[serde(default)]
    message: Option<TelegramMessage>,
}

#[derive(Debug, Deserialize)]
struct TelegramMessage {
    message_id: i64,
    #[serde(default)]
    from: Option<TelegramUser>,
    chat: TelegramChat,
    date: i64,
    #[serde(default)]
    text: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TelegramUser {
    id: i64,
    #[serde(default)]
    username: Option<String>,
    #[serde(default)]
    first_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TelegramChat {
    id: i64,
    /// "private" / "group" / "supergroup" / "channel"
    #[serde(rename = "type", default)]
    kind: Option<String>,
}

// (Serialize bound retained for future webhook-mode where we'd post
// these structures back. V1 long-poll doesn't need it but the symmetry
// helps when V2 lands.)
#[allow(dead_code)]
#[derive(Debug, Serialize)]
struct SendMessageBody<'a> {
    chat_id: i64,
    text: &'a str,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn chat_id_round_trip() {
        let ch = TelegramAdapter::chat_id_to_channel(123_456_789);
        assert_eq!(ch, "telegram:123456789");
        assert_eq!(TelegramAdapter::channel_to_chat_id(&ch), Some(123_456_789));
    }

    #[test]
    fn channel_to_chat_id_rejects_other_platforms() {
        assert_eq!(TelegramAdapter::channel_to_chat_id("discord:1234"), None);
        assert_eq!(TelegramAdapter::channel_to_chat_id("telegram:abc"), None);
    }

    #[test]
    #[serial]
    fn poll_timeout_default_25() {
        std::env::remove_var("TELEGRAM_POLL_TIMEOUT_SECS");
        assert_eq!(poll_timeout_secs(), 25);
    }

    #[test]
    #[serial]
    fn poll_timeout_clamped_to_50() {
        std::env::set_var("TELEGRAM_POLL_TIMEOUT_SECS", "9999");
        // out-of-range values fall back to default
        assert_eq!(poll_timeout_secs(), 25);
        std::env::set_var("TELEGRAM_POLL_TIMEOUT_SECS", "30");
        assert_eq!(poll_timeout_secs(), 30);
        std::env::remove_var("TELEGRAM_POLL_TIMEOUT_SECS");
    }
}
