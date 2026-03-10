//! schedule: set alarms (fire_at + prompt + context). Heartbeat checks schedule_due() first.

use crate::schedule_db;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct ScheduleTool;

#[async_trait]
impl Tool for ScheduleTool {
    fn name(&self) -> String {
        "schedule".to_string()
    }

    fn description(&self) -> String {
        "Set your own alarms. Create a reminder that fires at a time and becomes your next session prompt. fire_at: unix timestamp (seconds) or relative (e.g. 4h, 2d, 30m). Actions: create (fire_at, prompt, context?), list (include_fired?), cancel (id). Heartbeat runner checks due items first.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "description": "create | list | cancel" },
                "fire_at": { "type": "string", "description": "When to fire: unix timestamp or 4h, 2d, 30m" },
                "prompt": { "type": "string", "description": "Session prompt when this fires (for create)" },
                "context": { "type": "string", "description": "Optional context: task id, PR number, etc. (for create)" },
                "id": { "type": "number", "description": "Schedule id (for cancel)" },
                "include_fired": { "type": "boolean", "description": "If true, list includes already-fired items" }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !schedule_db::schedule_available() {
            return Err(anyhow!("Schedule DB not available"));
        }
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing action"))?
            .trim()
            .to_lowercase();

        match action.as_str() {
            "create" => {
                let fire_at = input
                    .get("fire_at")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("create requires fire_at"))?
                    .trim();
                let prompt = input
                    .get("prompt")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("create requires prompt"))?
                    .trim();
                if prompt.is_empty() {
                    return Err(anyhow!("prompt is empty"));
                }
                let context = input.get("context").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let id = schedule_db::schedule_create(fire_at, prompt, context)?;
                Ok(format!(
                    "Scheduled id {} to fire at {} (prompt: {}).",
                    id,
                    fire_at,
                    if prompt.len() > 60 {
                        format!("{}…", &prompt[..60])
                    } else {
                        prompt.to_string()
                    }
                ))
            }
            "list" => {
                let include_fired = input.get("include_fired").and_then(|v| v.as_bool()).unwrap_or(false);
                let rows = schedule_db::schedule_list(include_fired)?;
                if rows.is_empty() {
                    return Ok("No scheduled items.".to_string());
                }
                let lines: Vec<String> = rows
                    .into_iter()
                    .map(|r| {
                        let fired = if r.fired != 0 { " [fired]" } else { "" };
                        let ctx = r.context.as_deref().unwrap_or("");
                        format!(
                            "id={} | fire_at={} | {} | context={}{}",
                            r.id,
                            r.fire_at,
                            if r.prompt.len() > 50 {
                                format!("{}…", &r.prompt[..50])
                            } else {
                                r.prompt
                            },
                            ctx,
                            fired
                        )
                    })
                    .collect();
                Ok(lines.join("\n"))
            }
            "cancel" => {
                let id = input
                    .get("id")
                    .and_then(|v| v.as_i64())
                    .ok_or_else(|| anyhow!("cancel requires id"))?;
                let ok = schedule_db::schedule_cancel(id)?;
                if ok {
                    Ok(format!("Cancelled schedule {}.", id))
                } else {
                    Err(anyhow!("Schedule id {} not found.", id))
                }
            }
            _ => Err(anyhow!("action must be create, list, or cancel")),
        }
    }
}
