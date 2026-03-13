//! Agent-to-agent: send a DM to the other bot (CHUMP_A2A_PEER_USER_ID). Enables Mabel ↔ Chump over Discord.

use crate::discord_dm;
use crate::limits;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct A2aTool;

/// True when CHUMP_A2A_PEER_USER_ID is set (enables a2a tool and accepting DMs from peer).
pub fn a2a_peer_configured() -> bool {
    std::env::var("CHUMP_A2A_PEER_USER_ID")
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
}

#[async_trait]
impl Tool for A2aTool {
    fn name(&self) -> String {
        "message_peer".to_string()
    }

    fn description(&self) -> String {
        "Send a message to the other bot (Chump or Mabel) over Discord. Use to delegate, ask for status, or coordinate. The peer will receive it as a DM and can reply. Input: message (string). Only available when CHUMP_A2A_PEER_USER_ID is set.".to_string()
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
