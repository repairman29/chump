//! Ego tool: read/write Chump's persistent inner state (mood, focus, frustrations, etc.).

use crate::state_db;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct EgoTool;

#[async_trait]
impl Tool for EgoTool {
    fn name(&self) -> String {
        "ego".to_string()
    }

    fn description(&self) -> String {
        "Read and update Chump's persistent inner state: mood, current_focus, frustrations, curiosities, recent_wins, things_jeff_should_know, drive_scores, last_session_summary. Use at session start (read_all) and session end (write).".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "description": "read_all | read | write | append" },
                "key": { "type": "string", "description": "State key (for read/write/append): current_focus, mood, frustrations, curiosities, recent_wins, things_jeff_should_know, drive_scores, last_session_summary" },
                "value": { "type": "string", "description": "Value to write or append" }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !state_db::state_available() {
            return Err(anyhow!("State DB not available"));
        }
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing action"))?
            .trim()
            .to_lowercase();

        match action.as_str() {
            "read_all" => {
                let block = state_db::state_read_all()?;
                Ok(if block.is_empty() {
                    "No state yet.".to_string()
                } else {
                    block
                })
            }
            "read" => {
                let key = input
                    .get("key")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("read requires key"))?
                    .trim();
                if key.is_empty() {
                    return Err(anyhow!("key is empty"));
                }
                match state_db::state_read(key)? {
                    Some(v) => Ok(v),
                    None => Ok(format!("No value for key '{}'.", key)),
                }
            }
            "write" => {
                let key = input
                    .get("key")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("write requires key"))?
                    .trim();
                let value = input
                    .get("value")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("write requires value"))?
                    .trim();
                if key.is_empty() {
                    return Err(anyhow!("key is empty"));
                }
                state_db::state_write(key, value)?;
                Ok(format!("Wrote {} ({} chars).", key, value.len()))
            }
            "append" => {
                let key = input
                    .get("key")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("append requires key"))?
                    .trim();
                let value = input
                    .get("value")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("append requires value"))?
                    .trim();
                if key.is_empty() {
                    return Err(anyhow!("key is empty"));
                }
                state_db::state_append(key, value)?;
                Ok(format!("Appended to {}.", key))
            }
            _ => Err(anyhow!("action must be read_all, read, write, or append")),
        }
    }
}
