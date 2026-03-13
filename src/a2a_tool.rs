//! Agent-to-agent: send a message to the other bot (CHUMP_A2A_PEER_USER_ID). Enables Mabel ↔ Chump over Discord.
//! When CHUMP_A2A_CHANNEL_ID is set, messages go to that server channel so the user can follow along.

use crate::discord_dm;
use crate::limits;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct A2aTool;

/// True when CHUMP_A2A_PEER_USER_ID is set (enables a2a tool and accepting messages from peer).
pub fn a2a_peer_configured() -> bool {
    std::env::var("CHUMP_A2A_PEER_USER_ID")
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
}

/// True when CHUMP_A2A_CHANNEL_ID is set (a2a happens in this server channel; else DMs).
pub fn a2a_channel_configured() -> bool {
    std::env::var("CHUMP_A2A_CHANNEL_ID")
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
}

#[async_trait]
impl Tool for A2aTool {
    fn name(&self) -> String {
        "message_peer".to_string()
    }

    fn description(&self) -> String {
        if a2a_channel_configured() {
            "Send a message to the other bot (Chump or Mabel) in the a2a server channel. Use to delegate, ask for status, or coordinate. The peer will see it in the channel and can reply there so the user can follow along. Input: message (string).".to_string()
        } else {
            "Send a message to the other bot (Chump or Mabel) over Discord DM. Use to delegate, ask for status, or coordinate. The peer will receive it and can reply. Input: message (string). Only available when CHUMP_A2A_PEER_USER_ID is set.".to_string()
        }
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "message": { "type": "string", "description": "Message to send to the other bot" }
            },
            "required": ["message"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let message = input
            .get("message")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing message"))?
            .trim();
        if message.is_empty() {
            return Err(anyhow!("message is empty"));
        }
        let token = std::env::var("DISCORD_TOKEN")
            .map_err(|_| anyhow!("DISCORD_TOKEN not set"))?
            .trim()
            .to_string();
        if token.is_empty() {
            return Err(anyhow!("DISCORD_TOKEN is empty"));
        }
        if a2a_channel_configured() {
            let channel_id = std::env::var("CHUMP_A2A_CHANNEL_ID")
                .map_err(|_| anyhow!("CHUMP_A2A_CHANNEL_ID not set"))?
                .trim()
                .parse::<u64>()
                .map_err(|_| anyhow!("CHUMP_A2A_CHANNEL_ID must be a numeric channel id"))?;
            discord_dm::send_channel_message(&token, channel_id, message).await?;
            Ok("Message sent to the a2a channel. The other bot can reply there.".to_string())
        } else {
            let peer_id = std::env::var("CHUMP_A2A_PEER_USER_ID")
                .map_err(|_| anyhow!("CHUMP_A2A_PEER_USER_ID not set"))?
                .trim()
                .to_string();
            if peer_id.is_empty() {
                return Err(anyhow!("CHUMP_A2A_PEER_USER_ID is empty"));
            }
            discord_dm::send_dm_to_user(&token, &peer_id, message).await?;
            Ok("Message sent to the other bot. They may reply in this DM thread.".to_string())
        }
    }
}
