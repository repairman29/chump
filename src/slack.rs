//! Slack messaging adapter (COMP-004c).
//!
//! Uses Slack's **Socket Mode** — a persistent WebSocket connection so no
//! public URL / webhook endpoint is needed. Two tokens are required:
//!
//! - `SLACK_APP_TOKEN` (xapp-...) Socket Mode token. Grants the WSS URL.
//! - `SLACK_BOT_TOKEN` (xoxb-...) Bot OAuth token. Used for all REST API
//!   calls (chat.postMessage, auth.test, ...).
//!
//! ## Socket Mode lifecycle
//!
//! 1. POST `apps.connections.open` with `SLACK_APP_TOKEN` → receives a
//!    one-time WSS URL (valid for a few minutes; reconnect on close).
//! 2. Connect WebSocket; acknowledge every event envelope immediately with
//!    `{"envelope_id":"<id>","payload":""}` to prevent Slack re-delivering.
//! 3. On `events_api` envelope + `event.type == "message"` (or `app_mention`):
//!    build an `IncomingMessage` and forward to the platform-router queue.
//! 4. On disconnect / error: re-acquire a new WSS URL and reconnect.
//!
//! ## Channel naming
//!
//! Channel IDs are namespaced `slack:<team_id>:<channel_id>`, e.g.
//! `slack:T0123456:C0987654`. That matches the MessagingHub prefix
//! and lets `MessagingHub::adapter_for` route replies back.
//!
//! ## Sending
//!
//! `chat.postMessage` with the bot token. Thread replies use
//! `thread_ts` extracted from `platform_metadata`. DMs use `chat.postMessage`
//! with the user ID as the channel.
//!
//! ## What's V2 (deferred)
//!
//! - Block Kit interactive messages (approval buttons)
//! - Multi-workspace installs (each workspace needs its own bot token)
//! - Slash command payload type (currently only message events)
//! - File attachment upload

use crate::messaging::{ApprovalResponse, IncomingMessage, MessagingAdapter, OutgoingMessage};
use crate::platform_router::{InputQueue, PlatformMessage};
use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::time::Duration;
use tokio_tungstenite::tungstenite::protocol::Message as WsMessage;
use tokio_tungstenite::tungstenite::protocol::frame::coding::Utf8Bytes;

/// REST base URL. Override via `SLACK_API_BASE` for testing.
fn api_base() -> String {
    std::env::var("SLACK_API_BASE").unwrap_or_else(|_| "https://slack.com/api".to_string())
}

/// Reconnect back-off ceiling in seconds.
const MAX_BACKOFF_SECS: u64 = 60;

/// Single Slack text message truncation limit (Slack caps messages at 3000
/// chars for the `text` field in chat.postMessage; 3000 - 10 safety margin).
const SLACK_MAX_TEXT: usize = 2990;

// ---------------------------------------------------------------------------
// Wire types (subset of Slack's Socket Mode envelope + Events API payload)
// ---------------------------------------------------------------------------

/// The outer Socket Mode envelope every frame is wrapped in.
#[derive(Debug, serde::Deserialize)]
struct Envelope {
    #[serde(rename = "type")]
    kind: String,
    envelope_id: Option<String>,
    payload: Option<serde_json::Value>,
    reason: Option<String>,
}

/// The `event` object nested inside an `events_api` envelope payload.
#[derive(Debug, serde::Deserialize)]
struct SlackEvent {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
    user: Option<String>,
    channel: Option<String>,
    /// Thread parent timestamp. Populated when the message is a threaded reply.
    thread_ts: Option<String>,
    /// Timestamp of this message itself (unique per channel, used as thread_ts
    /// in replies).
    ts: Option<String>,
}

/// The `authorizations[0]` inside an `events_api` payload — gives us
/// the team_id to build the namespaced channel_id.
#[derive(Debug, serde::Deserialize)]
struct Authorization {
    team_id: String,
    user_id: Option<String>,
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

/// Slack Socket Mode adapter.
#[derive(Clone)]
pub struct SlackAdapter {
    /// xoxb-... Bot OAuth token for REST calls.
    bot_token: String,
    /// xapp-... App-level token for Socket Mode (acquiring the WSS URL).
    app_token: String,
    client: reqwest::Client,
    /// When set, incoming messages are pushed to this shared platform-router
    /// queue rather than handled inline. Attach via `with_queue()`.
    queue: Option<InputQueue>,
}

impl SlackAdapter {
    /// Construct from `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` env vars.
    /// Validates the bot token via `auth.test` at startup.
    pub async fn from_env() -> Result<Self> {
        let bot_token = std::env::var("SLACK_BOT_TOKEN").context(
            "SLACK_BOT_TOKEN not set. Create a Slack app at api.slack.com, install it to your \
             workspace, copy the xoxb-... token, and add it to .env.",
        )?;
        let app_token = std::env::var("SLACK_APP_TOKEN").context(
            "SLACK_APP_TOKEN not set. In your Slack app settings → Settings → Socket Mode, enable \
             Socket Mode and generate an xapp-... App-Level Token with connections:write scope.",
        )?;
        if bot_token.trim().is_empty() || app_token.trim().is_empty() {
            return Err(anyhow!("SLACK_BOT_TOKEN or SLACK_APP_TOKEN is empty"));
        }
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .context("reqwest client build")?;
        let adapter = Self {
            bot_token: bot_token.trim().to_string(),
            app_token: app_token.trim().to_string(),
            client,
            queue: None,
        };
        adapter.validate_bot_token().await?;
        Ok(adapter)
    }

    /// Attach a platform-router queue. Chainable.
    pub fn with_queue(mut self, queue: InputQueue) -> Self {
        self.queue = Some(queue);
        self
    }

    /// Call `auth.test` to confirm the bot token is valid. Logs the bot
    /// username and team name so the operator can confirm the right workspace.
    async fn validate_bot_token(&self) -> Result<()> {
        let resp = self
            .client
            .post(format!("{}/auth.test", api_base()))
            .bearer_auth(&self.bot_token)
            .send()
            .await
            .context("auth.test request")?;
        let body: serde_json::Value = resp.json().await.context("auth.test response")?;
        if body["ok"] != true {
            return Err(anyhow!(
                "auth.test failed: {}",
                body.get("error")
                    .and_then(|e| e.as_str())
                    .unwrap_or("unknown")
            ));
        }
        let user = body["user"].as_str().unwrap_or("?");
        let team = body["team"].as_str().unwrap_or("?");
        tracing::info!(bot = user, workspace = team, "slack: bot validated");
        Ok(())
    }

    /// Call `apps.connections.open` with the app token. Returns the one-time
    /// WSS URL for Socket Mode.
    async fn get_wss_url(&self) -> Result<String> {
        let resp = self
            .client
            .post(format!("{}/apps.connections.open", api_base()))
            .bearer_auth(&self.app_token)
            .send()
            .await
            .context("apps.connections.open request")?;
        let body: serde_json::Value = resp
            .json()
            .await
            .context("apps.connections.open response")?;
        if body["ok"] != true {
            return Err(anyhow!(
                "apps.connections.open failed: {}",
                body.get("error")
                    .and_then(|e| e.as_str())
                    .unwrap_or("unknown")
            ));
        }
        body["url"]
            .as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| anyhow!("apps.connections.open: no url in response"))
    }

    /// POST chat.postMessage. text is plain UTF-8. channel is the Slack
    /// channel ID (C... or U... for DMs). thread_ts threads the reply.
    async fn post_message(&self, channel: &str, text: &str, thread_ts: Option<&str>) -> Result<()> {
        let truncated = if text.chars().count() > SLACK_MAX_TEXT {
            let mut t: String = text.chars().take(SLACK_MAX_TEXT - 6).collect();
            t.push_str("\n[…]");
            t
        } else {
            text.to_string()
        };
        let mut payload = serde_json::json!({
            "channel": channel,
            "text": truncated,
        });
        if let Some(ts) = thread_ts {
            payload["thread_ts"] = ts.into();
        }
        let resp = self
            .client
            .post(format!("{}/chat.postMessage", api_base()))
            .bearer_auth(&self.bot_token)
            .json(&payload)
            .send()
            .await
            .context("chat.postMessage request")?;
        let body: serde_json::Value = resp.json().await.context("chat.postMessage response")?;
        if body["ok"] != true {
            return Err(anyhow!(
                "chat.postMessage failed (channel={}): {}",
                channel,
                body.get("error")
                    .and_then(|e| e.as_str())
                    .unwrap_or("unknown")
            ));
        }
        Ok(())
    }

    /// Namespace a (team_id, channel_id) pair as a channel_id string.
    fn make_channel_id(team_id: &str, channel_id: &str) -> String {
        format!("slack:{}:{}", team_id, channel_id)
    }

    /// Extract Slack (team_id, channel_id) from our namespaced channel_id.
    fn parse_channel_id(channel_id: &str) -> Option<(String, String)> {
        let rest = channel_id.strip_prefix("slack:")?;
        let mut parts = rest.splitn(2, ':');
        let team = parts.next()?.to_string();
        let chan = parts.next()?.to_string();
        Some((team, chan))
    }

    /// Parse one WebSocket frame into an `IncomingMessage` if it represents a
    /// user text message (and not our own bot's messages). Returns `None` for
    /// non-message events, bot messages, empty text, etc.
    fn frame_to_incoming(
        &self,
        envelope: &Envelope,
        bot_user_id: Option<&str>,
    ) -> Option<IncomingMessage> {
        // Only handle events_api type
        if envelope.kind != "events_api" {
            return None;
        }
        let payload = envelope.payload.as_ref()?;

        // Extract the inner event object
        let event: SlackEvent = serde_json::from_value(payload["event"].clone()).ok()?;
        // We handle "message" and "app_mention" event types.
        if event.kind != "message" && event.kind != "app_mention" {
            return None;
        }
        // Skip subtypes (edited messages, bot_message, etc.)
        if payload["event"]["subtype"].is_string() {
            return None;
        }
        let text = event.text.filter(|t| !t.trim().is_empty())?;
        let user_id = event.user.as_deref().unwrap_or("").to_string();

        // Skip our own bot messages to avoid reply loops.
        if let Some(bot_uid) = bot_user_id {
            if user_id == bot_uid {
                return None;
            }
        }

        let slack_channel = event.channel.as_deref().unwrap_or("").to_string();
        // Extract team_id from authorizations[0] if present
        let team_id = payload["authorizations"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|auth| auth["team_id"].as_str())
            .unwrap_or("T_UNKNOWN")
            .to_string();

        let channel_id = Self::make_channel_id(&team_id, &slack_channel);
        // is_dm: Slack DM channels start with 'D'
        let is_dm = slack_channel.starts_with('D');
        let ts = event.ts.as_deref().unwrap_or("").to_string();
        let thread_ts = event.thread_ts.as_deref().unwrap_or(&ts).to_string();

        Some(IncomingMessage {
            channel_id,
            sender_id: user_id,
            sender_display: String::new(), // Slack doesn't provide display name in the event
            content: text,
            is_dm,
            attachments: vec![],
            platform_metadata: serde_json::json!({
                "team_id": team_id,
                "channel": slack_channel,
                "ts": ts,
                "thread_ts": thread_ts,
            }),
        })
    }

    /// Connect to Socket Mode and run the event loop. Reconnects with
    /// exponential back-off on error or normal WSS close.
    async fn run_socket_loop(&self) -> Result<()> {
        let mut backoff = Duration::from_secs(1);

        loop {
            match self.socket_session().await {
                Ok(()) => {
                    // Clean close — reconnect immediately.
                    backoff = Duration::from_secs(1);
                    tracing::info!("slack: socket closed cleanly; reconnecting");
                }
                Err(e) => {
                    tracing::warn!(error = %e, backoff_secs = backoff.as_secs(), "slack: socket error; backing off");
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(Duration::from_secs(MAX_BACKOFF_SECS));
                }
            }
        }
    }

    /// One Socket Mode session: acquire WSS URL → connect → event loop.
    /// Returns Ok(()) on clean close, Err on unrecoverable error.
    async fn socket_session(&self) -> Result<()> {
        let wss_url = self.get_wss_url().await?;
        tracing::info!("slack: connecting to Socket Mode WSS");

        let (ws_stream, _) = tokio_tungstenite::connect_async(&wss_url)
            .await
            .context("slack WSS connect")?;
        let (mut write, mut read) = ws_stream.split();

        // Resolve our own bot user ID so we can filter self-messages.
        // This is best-effort; None is safe (we just won't filter our own msgs).
        let bot_user_id: Option<String> = async {
            let resp = self
                .client
                .post(format!("{}/auth.test", api_base()))
                .bearer_auth(&self.bot_token)
                .send()
                .await
                .ok()?;
            let body: serde_json::Value = resp.json().await.ok()?;
            body["user_id"].as_str().map(|s| s.to_string())
        }
        .await;

        // Process frames until the connection closes.
        while let Some(frame) = read.next().await {
            let msg = match frame {
                Ok(m) => m,
                Err(e) => return Err(e.into()),
            };

            match msg {
                WsMessage::Text(text) => {
                    let text_str: &str = text.as_str();
                    let envelope: Envelope = match serde_json::from_str(text_str) {
                        Ok(e) => e,
                        Err(parse_err) => {
                            tracing::warn!(error = %parse_err, raw = %text_str, "slack: failed to parse envelope");
                            continue;
                        }
                    };

                    // Acknowledge every envelope immediately.
                    if let Some(ref env_id) = envelope.envelope_id {
                        let ack = serde_json::json!({"envelope_id": env_id, "payload": ""});
                        let _ = write.send(WsMessage::Text(Utf8Bytes::from(ack.to_string()))).await;
                    }

                    match envelope.kind.as_str() {
                        "hello" => {
                            tracing::info!("slack: Socket Mode hello received — connection ready");
                        }
                        "disconnect" => {
                            tracing::info!(
                                reason = envelope.reason.as_deref().unwrap_or("none"),
                                "slack: disconnect event; will reconnect"
                            );
                            return Ok(());
                        }
                        "events_api" => {
                            if let Some(incoming) =
                                self.frame_to_incoming(&envelope, bot_user_id.as_deref())
                            {
                                tracing::info!(
                                    from = incoming.sender_id.as_str(),
                                    channel = incoming.channel_id.as_str(),
                                    len = incoming.content.len(),
                                    "slack: incoming message"
                                );
                                if let Some(q) = &self.queue {
                                    let msg = PlatformMessage {
                                        incoming,
                                        adapter: Arc::new(self.clone()),
                                    };
                                    if q.try_send(msg).is_err() {
                                        tracing::warn!(
                                            "platform_router queue full; dropping slack message"
                                        );
                                    }
                                } else if let Err(e) = self.handle_incoming(&incoming).await {
                                    tracing::warn!(error = %e, "slack: handle_incoming error");
                                }
                            }
                        }
                        other => {
                            tracing::debug!(kind = other, "slack: unhandled envelope type");
                        }
                    }
                }
                WsMessage::Close(_) => {
                    tracing::info!("slack: WSS close frame; will reconnect");
                    return Ok(());
                }
                WsMessage::Ping(data) => {
                    let _ = write.send(WsMessage::Pong(data)).await;
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// Inline handler used when no platform-router queue is attached.
    async fn handle_incoming(&self, incoming: &IncomingMessage) -> Result<()> {
        let (agent, ready_session) = crate::discord::build_chump_agent_cli()
            .map_err(|e| anyhow!("build_chump_agent_cli: {}", e))?;
        let running = ready_session.start();
        let outcome = agent
            .run(&incoming.content)
            .await
            .map_err(|e| anyhow!("agent.run: {}", e))?;
        running.close();
        let reply = crate::thinking_strip::strip_for_public_reply(&outcome.reply);
        // Reply in thread when we have a thread_ts.
        let thread_ts = incoming
            .platform_metadata
            .get("thread_ts")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        if let Some((_, slack_channel)) = Self::parse_channel_id(&incoming.channel_id) {
            let _ = self
                .post_message(&slack_channel, &reply, thread_ts.as_deref())
                .await;
        }
        Ok(())
    }
}

#[async_trait]
impl MessagingAdapter for SlackAdapter {
    fn platform_name(&self) -> &str {
        "slack"
    }

    async fn start(&self) -> Result<()> {
        tracing::info!("slack: Socket Mode adapter starting");
        self.run_socket_loop().await
    }

    async fn send_reply(&self, incoming: &IncomingMessage, msg: OutgoingMessage) -> Result<()> {
        let (_, slack_channel) = Self::parse_channel_id(&incoming.channel_id)
            .ok_or_else(|| anyhow!("not a slack channel: {}", incoming.channel_id))?;
        // Thread reply when platform_metadata carries thread_ts.
        let thread_ts = incoming
            .platform_metadata
            .get("thread_ts")
            .and_then(|v| v.as_str());
        self.post_message(&slack_channel, &msg.text, thread_ts)
            .await
    }

    async fn send_dm(&self, user_id: &str, msg: OutgoingMessage) -> Result<()> {
        // Slack DMs: chat.postMessage with the user ID as the channel.
        // The Slack API opens or reuses the DM channel automatically.
        self.post_message(user_id, &msg.text, None).await
    }

    async fn request_approval(
        &self,
        user_id: &str,
        prompt: &str,
        _timeout_secs: u64,
    ) -> Result<ApprovalResponse> {
        // V1: text prompt only. Block Kit interactive messages are V2.
        let augmented = format!("{}\n\nReply `approve` or `reject`.", prompt);
        self.send_dm(user_id, OutgoingMessage::text(augmented))
            .await?;
        Ok(ApprovalResponse::Pending)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_adapter() -> SlackAdapter {
        SlackAdapter {
            bot_token: "xoxb-test".into(),
            app_token: "xapp-test".into(),
            client: reqwest::Client::new(),
            queue: None,
        }
    }

    #[test]
    fn make_channel_id_and_parse_roundtrip() {
        let id = SlackAdapter::make_channel_id("T123", "C456");
        assert_eq!(id, "slack:T123:C456");
        let parsed = SlackAdapter::parse_channel_id(&id);
        assert_eq!(parsed, Some(("T123".into(), "C456".into())));
    }

    #[test]
    fn parse_channel_id_rejects_non_slack() {
        assert!(SlackAdapter::parse_channel_id("discord:guild:ch").is_none());
        assert!(SlackAdapter::parse_channel_id("telegram:12345").is_none());
    }

    #[test]
    fn parse_channel_id_rejects_incomplete() {
        assert!(SlackAdapter::parse_channel_id("slack:T123").is_none());
        assert!(SlackAdapter::parse_channel_id("slack:").is_none());
        assert!(SlackAdapter::parse_channel_id("slack:T123:").is_some()); // empty channel_id is valid
    }

    #[test]
    fn platform_name_is_slack() {
        assert_eq!(make_adapter().platform_name(), "slack");
    }

    #[test]
    fn frame_to_incoming_parses_message_event() {
        let adapter = make_adapter();
        let envelope = Envelope {
            kind: "events_api".into(),
            envelope_id: Some("env1".into()),
            payload: Some(serde_json::json!({
                "event": {
                    "type": "message",
                    "text": "hello agent",
                    "user": "U123",
                    "channel": "C456",
                    "ts": "1234567890.123456",
                    "thread_ts": "1234567890.000000"
                },
                "authorizations": [{"team_id": "T789", "user_id": "U_BOT"}]
            })),
            reason: None,
        };
        let incoming = adapter.frame_to_incoming(&envelope, None);
        assert!(incoming.is_some());
        let m = incoming.unwrap();
        assert_eq!(m.channel_id, "slack:T789:C456");
        assert_eq!(m.sender_id, "U123");
        assert_eq!(m.content, "hello agent");
        assert!(!m.is_dm);
        assert_eq!(m.platform_metadata["thread_ts"], "1234567890.000000");
    }

    #[test]
    fn frame_to_incoming_skips_bot_own_message() {
        let adapter = make_adapter();
        let envelope = Envelope {
            kind: "events_api".into(),
            envelope_id: Some("env2".into()),
            payload: Some(serde_json::json!({
                "event": {
                    "type": "message",
                    "text": "bot reply",
                    "user": "U_BOT",
                    "channel": "C456",
                    "ts": "111.111"
                },
                "authorizations": [{"team_id": "T789", "user_id": "U_BOT"}]
            })),
            reason: None,
        };
        let incoming = adapter.frame_to_incoming(&envelope, Some("U_BOT"));
        assert!(incoming.is_none(), "should skip own bot messages");
    }

    #[test]
    fn frame_to_incoming_skips_non_events_api() {
        let adapter = make_adapter();
        let envelope = Envelope {
            kind: "hello".into(),
            envelope_id: None,
            payload: None,
            reason: None,
        };
        assert!(adapter.frame_to_incoming(&envelope, None).is_none());
    }

    #[test]
    fn frame_to_incoming_skips_message_subtype() {
        let adapter = make_adapter();
        let envelope = Envelope {
            kind: "events_api".into(),
            envelope_id: Some("env3".into()),
            payload: Some(serde_json::json!({
                "event": {
                    "type": "message",
                    "subtype": "message_changed",
                    "text": "edited",
                    "user": "U123",
                    "channel": "C456",
                    "ts": "111.222"
                },
                "authorizations": [{"team_id": "T789", "user_id": "U_BOT"}]
            })),
            reason: None,
        };
        assert!(adapter.frame_to_incoming(&envelope, None).is_none());
    }

    #[test]
    fn is_dm_true_for_d_channel() {
        let adapter = make_adapter();
        let envelope = Envelope {
            kind: "events_api".into(),
            envelope_id: Some("env4".into()),
            payload: Some(serde_json::json!({
                "event": {
                    "type": "message",
                    "text": "dm text",
                    "user": "U123",
                    "channel": "DABC123",   // D-prefix = DM
                    "ts": "999.000"
                },
                "authorizations": [{"team_id": "T789", "user_id": "U_BOT"}]
            })),
            reason: None,
        };
        let m = adapter.frame_to_incoming(&envelope, None).unwrap();
        assert!(m.is_dm);
    }

    #[test]
    fn text_truncation_at_2990_chars() {
        // The truncation path is inside post_message which needs a real HTTP
        // client. Just verify the constant is sane and won't cause off-by-ones.
        const { assert!(SLACK_MAX_TEXT < 3000) };
        const { assert!(SLACK_MAX_TEXT > 2980) };
    }
}
