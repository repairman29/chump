//! Ask Jeff: store a question, notify the owner. Jeff can answer via Discord (answer: #N ...) or CLI; next session sees the answer in context.

use crate::ask_jeff_db;
use crate::notify_tool::NotifyTool;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct AskJeffTool;

#[async_trait]
impl Tool for AskJeffTool {
    fn name(&self) -> String {
        "ask_jeff".to_string()
    }

    fn description(&self) -> String {
        "Ask Jeff a question asynchronously. Stores the question, sends a DM to the owner, and returns. Jeff's answer will appear in your next session context. Params: question (required), context (optional), priority (blocking|curious|fyi). Use blocking when you cannot proceed without an answer.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "question": { "type": "string", "description": "The question to ask Jeff" },
                "context": { "type": "string", "description": "Optional context (e.g. what you were doing)" },
                "priority": { "type": "string", "description": "blocking | curious | fyi (default curious)" }
            },
            "required": ["question"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !ask_jeff_db::ask_jeff_available() {
            return Err(anyhow!("ask_jeff DB not available"));
        }
        let question = input
            .get("question")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing question"))?
            .trim();
        if question.is_empty() {
            return Err(anyhow!("question is empty"));
        }
        let context = input.get("context").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
        let priority = input
            .get("priority")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("curious");

        let id = ask_jeff_db::question_ask(question, context, priority)?;
        let msg = format!("Question #{} ({}): {}", id, priority, question);
        let notify = NotifyTool;
        let _ = notify.execute(json!({ "message": msg })).await;
        Ok(format!("Question #{} sent to Jeff. You'll see the answer in your next session.", id))
    }
}
