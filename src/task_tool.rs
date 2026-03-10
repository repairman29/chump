//! Task queue tool: create, list, update, complete. Gives Chump continuity across heartbeat rounds.

use crate::task_db;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct TaskTool;

#[async_trait]
impl Tool for TaskTool {
    fn name(&self) -> String {
        "task".to_string()
    }

    fn description(&self) -> String {
        "Persistent task queue. Actions: create (title, repo?, issue_number?) -> id; list (status?: open|blocked|in_progress|done|abandoned) -> tasks; update (id, status, notes?) -> ok; complete (id, notes?) -> ok; status can be open, in_progress, blocked, done, abandoned. Heartbeat rounds should list open/blocked first.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "description": "create | list | update | complete" },
                "id": { "type": "number", "description": "Task id (for update/complete)" },
                "title": { "type": "string", "description": "Task title (for create)" },
                "repo": { "type": "string", "description": "Repo owner/name (for create)" },
                "issue_number": { "type": "number", "description": "GitHub issue number (for create)" },
                "status": { "type": "string", "description": "open | in_progress | blocked | done | abandoned (for update)" },
                "notes": { "type": "string", "description": "Notes (for update/complete)" }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !task_db::task_available() {
            return Err(anyhow!("Task DB not available (sessions dir?)"));
        }
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing action"))?
            .trim()
            .to_lowercase();

        match action.as_str() {
            "create" => {
                let title = input
                    .get("title")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("create requires title"))?
                    .trim();
                if title.is_empty() {
                    return Err(anyhow!("title is empty"));
                }
                let repo = input.get("repo").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let issue_number = input.get("issue_number").and_then(|v| v.as_i64());
                let id = task_db::task_create(title, repo, issue_number)?;
                Ok(format!("Created task {} (id {}).", title, id))
            }
            "list" => {
                let status = input
                    .get("status")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty());
                let rows = task_db::task_list(status)?;
                if rows.is_empty() {
                    return Ok("No tasks.".to_string());
                }
                let lines: Vec<String> = rows
                    .into_iter()
                    .map(|r| {
                        let repo = r.repo.as_deref().unwrap_or("—");
                        let issue = r
                            .issue_number
                            .map(|n| n.to_string())
                            .unwrap_or_else(|| "—".to_string());
                        format!(
                            "id={} | {} | repo={} issue={} | {} | notes={}",
                            r.id,
                            r.title,
                            repo,
                            issue,
                            r.status,
                            r.notes.as_deref().unwrap_or("")
                        )
                    })
                    .collect();
                Ok(lines.join("\n"))
            }
            "update" => {
                let id = input
                    .get("id")
                    .and_then(|v| v.as_i64())
                    .ok_or_else(|| anyhow!("update requires id"))?;
                let status = input
                    .get("status")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("update requires status"))?
                    .trim();
                if !["open", "in_progress", "blocked", "done", "abandoned"].contains(&status) {
                    return Err(anyhow!("status must be open, in_progress, blocked, done, or abandoned"));
                }
                let notes = input.get("notes").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let ok = task_db::task_update_status(id, status, notes)?;
                if ok {
                    Ok(format!("Updated task {} to {}.", id, status))
                } else {
                    Err(anyhow!("Task id {} not found.", id))
                }
            }
            "complete" => {
                let id = input
                    .get("id")
                    .and_then(|v| v.as_i64())
                    .ok_or_else(|| anyhow!("complete requires id"))?;
                let notes = input.get("notes").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let ok = task_db::task_complete(id, notes)?;
                if ok {
                    Ok(format!("Task {} completed.", id))
                } else {
                    Err(anyhow!("Task id {} not found.", id))
                }
            }
            _ => Err(anyhow!("action must be create, list, update, or complete")),
        }
    }
}
