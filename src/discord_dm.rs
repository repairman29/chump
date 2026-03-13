//! Send a DM via Discord REST API when running in CLI (e.g. heartbeat).
//! When Chump uses the notify tool in CLI mode, the message is queued but not sent.
//! This module sends it via POST /users/@me/channels and POST /channels/{id}/messages
//! so the owner gets DMs from heartbeat rounds without running the Discord bot.

use anyhow::Result;
use reqwest::Client;
use serde_json::json;

const DISCORD_API: &str = "https://discord.com/api/v10";

/// If DISCORD_TOKEN and CHUMP_READY_DM_USER_ID are set, send the message as a DM to that user.
/// No-op if message is empty or env vars are missing. Logs errors but does not fail the process.
pub async fn send_dm_if_configured(message: &str) {
    let message = message.trim();
    if message.is_empty() {
        return;
    }
    let token = match std::env::var("DISCORD_TOKEN") {
        Ok(t) => t.trim().to_string(),
        Err(_) => return,
    };
    if token.is_empty() {
        return;
    }
    let user_id = match std::env::var("CHUMP_READY_DM_USER_ID") {
        Ok(id) => id.trim().to_string(),
        Err(_) => return,
    };
    if user_id.is_empty() {
        return;
    }
    if let Err(e) = send_dm_impl(&token, &user_id, message).await {
        eprintln!(
            "Notify DM (CLI): {}",
            crate::chump_log::redact(&e.to_string())
        );
    }
}

/// Send a DM to an arbitrary Discord user (e.g. the other bot for a2a). Uses Bot token.
pub async fn send_dm_to_user(token: &str, user_id: &str, content: &str) -> Result<()> {
    send_dm_impl(token.trim(), user_id.trim(), content).await
}

/// Send a message to a guild channel (e.g. a2a channel so the user can follow along). Uses Bot token.
pub async fn send_channel_message(token: &str, channel_id: u64, content: &str) -> Result<()> {
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;
    let auth = format!("Bot {}", token.trim());
    let content = content.trim();
    let content = if content.len() > 2000 {
        format!("{}…", &content[..1999])
    } else {
        content.to_string()
    };
    let url = format!("{}/channels/{}/messages", DISCORD_API, channel_id);
    let body = json!({ "content": content });
    let resp = client
        .post(&url)
        .header("Authorization", &auth)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("Discord channel message {}: {}", status, text);
    }
    Ok(())
}

async fn send_dm_impl(token: &str, user_id: &str, content: &str) -> Result<()> {
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;
    let auth = format!("Bot {}", token);

    // Create DM channel (idempotent for same user)
    let create_url = format!("{}/users/@me/channels", DISCORD_API);
    let body = json!({ "recipient_id": user_id });
    let resp = client
        .post(&create_url)
        .header("Authorization", &auth)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("Discord create DM {}: {}", status, text);
    }
    let channel: serde_json::Value = resp.json().await?;
    let channel_id = channel
        .get("id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Discord response missing channel id"))?;

    // Send message (Discord content limit 2000)
    let content = if content.len() > 2000 {
        format!("{}…", &content[..1999])
    } else {
        content.to_string()
    };
    let msg_url = format!("{}/channels/{}/messages", DISCORD_API, channel_id);
    let msg_body = json!({ "content": content });
    let resp = client
        .post(&msg_url)
        .header("Authorization", &auth)
        .header("Content-Type", "application/json")
        .json(&msg_body)
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("Discord send message {}: {}", status, text);
    }
    Ok(())
}
