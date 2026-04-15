//! decompose_task: orchestrator tool to break a task into independent subtasks (disjoint files).
//! Single completion via cascade; returns JSON array of { description, files_to_modify, branch_name, test_command }.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::provider::Message;
use axonerai::tool::Tool;
use serde_json::{json, Value};

use crate::provider_cascade;

const DECOMPOSE_SYSTEM_PROMPT: &str = r#"Given the codebase digest and task description, decompose into independent subtasks.
Each subtask must touch a disjoint set of files (no two subtasks edit the same file).
Output only a valid JSON array of objects. Each object must have:
- "description": string (what to do)
- "files_to_modify": array of strings (file paths, disjoint across subtasks)
- "branch_name": string (e.g. chump/task-1-subtask-1)
- "test_command": string (e.g. "cargo test" or "npm test")
- "depends_on": array of integers (0-based indices of subtasks that must finish first; empty [] if independent)
Order subtasks so independent ones appear first. Express dependencies via the depends_on field.
Output nothing else except the JSON array."#;

fn extract_json_array(text: &str) -> Result<Value> {
    let trimmed = text.trim();
    let start = trimmed
        .find('[')
        .ok_or_else(|| anyhow!("no '[' in response"))?;
    let end = trimmed
        .rfind(']')
        .ok_or_else(|| anyhow!("no ']' in response"))?;
    let slice = trimmed
        .get(start..=end)
        .ok_or_else(|| anyhow!("slice failed"))?;
    let parsed = serde_json::from_str::<Value>(slice)?;
    if parsed.is_array() {
        Ok(parsed)
    } else {
        Err(anyhow!("parsed value is not an array"))
    }
}

pub struct DecomposeTaskTool;

#[async_trait]
impl Tool for DecomposeTaskTool {
    fn name(&self) -> String {
        "decompose_task".to_string()
    }

    fn description(&self) -> String {
        "Decompose a task into independent subtasks (disjoint files). Params: task (string), codebase_digest (string). Returns JSON array of { description, files_to_modify[], branch_name, test_command }. Use before spawn_worker.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "task": { "type": "string", "description": "Task description" },
                "codebase_digest": { "type": "string", "description": "Codebase digest (e.g. from codebase_digest tool or chump-brain digest)" },
                "repo": { "type": "string", "description": "Optional repo name for branch prefix" }
            },
            "required": ["task", "codebase_digest"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let task = input
            .get("task")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing task"))?
            .trim();
        let digest = input
            .get("codebase_digest")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing codebase_digest"))?
            .trim();
        let _repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty());

        let user_content = format!(
            "Task:\n{}\n\nCodebase digest:\n{}\n\nOutput the JSON array of subtasks.",
            task, digest
        );
        let messages = vec![Message {
            role: "user".to_string(),
            content: user_content,
        }];
        let provider = provider_cascade::build_provider();
        let response = provider
            .complete(
                messages,
                None,
                Some(4096),
                Some(DECOMPOSE_SYSTEM_PROMPT.to_string()),
            )
            .await?;
        let text = response
            .text
            .unwrap_or_else(|| "".to_string())
            .trim()
            .to_string();
        if text.is_empty() {
            return Err(anyhow!("empty response from model"));
        }
        let parsed = extract_json_array(&text).or_else(|e| {
            let retry = text
                .replace("```json", "")
                .replace("```", "")
                .trim()
                .to_string();
            extract_json_array(&retry).map_err(|_| anyhow!("parse failed: {}; raw: {}", e, text))
        })?;
        Ok(parsed.to_string())
    }
}
