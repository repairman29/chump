//! Ask Jeff: store a question, notify the owner. Jeff can answer via Discord (answer: #N ...) or CLI; next session sees the answer in context.

use crate::ask_jeff_db;
use crate::notify_tool::NotifyTool;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct AskJeffTool;

/// Returns true when the question is a "should I use tool X?" query that the
/// agent should answer itself by just calling the tool. These never require
/// human judgment and are the primary over-use pattern (INFRA-346).
fn is_trivial_tool_query(question: &str) -> bool {
    let q = question.to_lowercase();

    // "permission to act" patterns — agent should decide and act, not ask
    let permission_patterns = [
        "should i use ",
        "should i run ",
        "should i call ",
        "should i try ",
        "should i invoke ",
        "can i use ",
        "can i run ",
        "can i call ",
        "is it ok to ",
        "is it okay to ",
        "am i allowed to ",
        "do i need permission to",
        "should i attempt ",
        "can i attempt ",
        "is it safe to call ",
        "is it safe to run ",
        "should i go ahead and ",
    ];

    // Tool names agents must use directly rather than asking permission first
    let tool_names = [
        "web_search",
        "run_cli",
        "read_file",
        "write_file",
        "patch_file",
        "list_dir",
        "read_url",
        "git_commit",
        "git_push",
        "diff_review",
        "notify",
        "schedule",
        "memory",
        "memory_brain",
        "episode",
        "task",
        "cargo ",
        "cargo build",
        "cargo check",
        "cargo test",
        "cargo clippy",
        "cargo fmt",
    ];

    let has_permission_pattern = permission_patterns.iter().any(|p| q.contains(p));
    let has_tool_name = tool_names.iter().any(|t| q.contains(t));
    has_permission_pattern && has_tool_name
}

#[async_trait]
impl Tool for AskJeffTool {
    fn name(&self) -> String {
        "ask_jeff".to_string()
    }

    fn description(&self) -> String {
        "Ask Jeff a human question that ONLY a human can answer. Prerequisites — ALL must be true: \
         (1) you already tried to fix/resolve it yourself, \
         (2) you ran web_search if it was a 'how do I' question and applied the result, \
         (3) the question is NOT about whether to use a tool — if you're wondering whether to call \
         web_search, run_cli, read_file, cargo, git, etc., just call it; do not ask Jeff. \
         Use priority=blocking only for decisions that will halt progress without a human answer. \
         Params: question (required), context (optional), priority (blocking|curious|fyi)."
            .to_string()
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
        if is_trivial_tool_query(question) {
            return Err(anyhow!(
                "Rejected: this looks like a tool-permission question ('should I use X?' / 'can I run Y?'). \
                 Just call the tool directly — no approval needed. \
                 ask_jeff is for decisions only a human can make, not for tool-use authorization."
            ));
        }
        let context = input
            .get("context")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty());
        let priority = input
            .get("priority")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("curious");

        let id = ask_jeff_db::question_ask(question, context, priority)?;
        let msg = format!("Question #{} ({}): {}", id, priority, question);
        let notify = NotifyTool;
        if let Err(e) = notify.execute(json!({ "message": msg })).await {
            tracing::warn!("ask_jeff notification send failed: {e}");
        }
        Ok(format!(
            "Question #{} sent to Jeff. You'll see the answer in your next session.",
            id
        ))
    }
}
