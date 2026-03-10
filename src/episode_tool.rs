//! Episode tool: log events and search past episodes.

use crate::episode_db;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct EpisodeTool;

#[async_trait]
impl Tool for EpisodeTool {
    fn name(&self) -> String {
        "episode".to_string()
    }

    fn description(&self) -> String {
        "Log events to Chump's episodic memory and search past events. Call log at the end of any meaningful action. Call recent at session start to recall what's been happening. Sentiment: win, loss, neutral, frustrating, uncertain.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "description": "log | search | recent" },
                "summary": { "type": "string", "description": "1-2 sentence summary (for log)" },
                "detail": { "type": "string", "description": "Full prose (for log)" },
                "tags": { "type": "string", "description": "Comma-separated tags (for log)" },
                "repo": { "type": "string", "description": "Repo (for log or recent filter)" },
                "sentiment": { "type": "string", "description": "win | loss | neutral | frustrating | uncertain (for log)" },
                "pr_number": { "type": "integer", "description": "PR number (for log)" },
                "issue_number": { "type": "integer", "description": "Issue number (for log)" },
                "query": { "type": "string", "description": "Search term (for search)" },
                "limit": { "type": "integer", "description": "Max results (default 5)" }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !episode_db::episode_available() {
            return Err(anyhow!("Episode DB not available"));
        }
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing action"))?
            .trim()
            .to_lowercase();

        match action.as_str() {
            "log" => {
                let summary = input
                    .get("summary")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("log requires summary"))?
                    .trim();
                if summary.is_empty() {
                    return Err(anyhow!("summary is empty"));
                }
                let detail = input.get("detail").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let tags = input.get("tags").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let repo = input.get("repo").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let sentiment = input.get("sentiment").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let pr_number = input.get("pr_number").and_then(|v| v.as_i64());
                let issue_number = input.get("issue_number").and_then(|v| v.as_i64());
                let id = episode_db::episode_log(summary, detail, tags, repo, sentiment, pr_number, issue_number)?;
                Ok(format!("Logged episode {}: {}", id, summary))
            }
            "recent" => {
                let repo = input.get("repo").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let limit = input.get("limit").and_then(|v| v.as_u64()).unwrap_or(5) as usize;
                let rows = episode_db::episode_recent(repo, limit)?;
                if rows.is_empty() {
                    return Ok("No recent episodes.".to_string());
                }
                let lines: Vec<String> = rows
                    .into_iter()
                    .map(|r| {
                        let sent = r.sentiment.as_deref().unwrap_or("—");
                        let repo_str = r.repo.as_deref().unwrap_or("—");
                        format!("[{}] {} | {} | {} | {}", r.id, r.happened_at, sent, repo_str, r.summary)
                    })
                    .collect();
                Ok(lines.join("\n"))
            }
            "search" => {
                let query = input.get("query").and_then(|v| v.as_str()).map(|s| s.trim()).unwrap_or("");
                let limit = input.get("limit").and_then(|v| v.as_u64()).unwrap_or(10) as usize;
                let rows = episode_db::episode_search(query, limit)?;
                if rows.is_empty() {
                    return Ok("No matching episodes.".to_string());
                }
                let lines: Vec<String> = rows
                    .into_iter()
                    .map(|r| {
                        let sent = r.sentiment.as_deref().unwrap_or("—");
                        format!("[{}] {} | {} | {}", r.id, sent, r.summary, r.detail.as_deref().unwrap_or(""))
                    })
                    .collect();
                Ok(lines.join("\n"))
            }
            _ => Err(anyhow!("action must be log, recent, or search")),
        }
    }
}
