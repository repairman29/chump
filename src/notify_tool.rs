//! Notify tool: queue a DM to CHUMP_READY_DM_USER_ID. Discord handler sends it after the turn.

use crate::chump_log;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct NotifyTool;

#[async_trait]
impl Tool for NotifyTool {
    fn name(&self) -> String {
        "notify".to_string()
    }

    fn description(&self) -> String {
        "Send a DM to the owner (CHUMP_READY_DM_USER_ID). Use when blocked, when a PR is ready for review, or to report what you did. Input: message (string). In Discord mode the DM is sent after your reply; in CLI mode nothing is sent. During heartbeat with CHUMP_INTERRUPT_NOTIFY_POLICY=restrict, the message must include an allowed interrupt tag (e.g. [interrupt:ship_blocked], [human]) — see docs/process/COS_DECISION_LOG.md.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "message": { "type": "string", "description": "Message to DM the owner" }
            },
            "required": ["message"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
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
        let msg = message.to_string();
        if !crate::interrupt_notify::allow_user_notify(&msg) {
            return Ok(
                "Notification not queued: interrupt policy (CHUMP_INTERRUPT_NOTIFY_POLICY=restrict) is active during this heartbeat round. Include an allowed tag or phrase in the message, e.g. [interrupt:approval_timeout], [interrupt:ship_blocked], [interrupt:circuit], [human]. See docs/process/COS_DECISION_LOG.md.".to_string(),
            );
        }
        chump_log::set_pending_notify(msg);
        Ok("Notification queued; you'll get a DM after this turn (if CHUMP_READY_DM_USER_ID is set and running in Discord).".to_string())
    }
}
