//! TaskPlanner: write a multi-step plan into `chump_tasks` (Vector 2 state machine).

use crate::task_db;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct TaskPlannerTool;

#[async_trait]
impl Tool for TaskPlannerTool {
    fn name(&self) -> String {
        "task_planner".to_string()
    }

    fn description(&self) -> String {
        "Submit an ordered multi-step plan into SQLite (`chump_tasks`). Pass `objectives` as a JSON array of strings (one row per step). First step is set in_progress, later steps open. Returns `planner_group_id`. Advance steps with the `task` tool (update status to done / in_progress / blocked).".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "objectives": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Ordered list of step titles (non-empty strings)"
                },
                "assignee": { "type": "string", "description": "Optional assignee (default chump)" }
            },
            "required": ["objectives"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !task_db::task_available() {
            return Err(anyhow!("Task DB not available (sessions dir?)"));
        }
        let arr = input
            .get("objectives")
            .and_then(|v| v.as_array())
            .ok_or_else(|| anyhow!("objectives must be a JSON array"))?;
        let mut objectives: Vec<String> = Vec::new();
        for v in arr {
            if let Some(s) = v.as_str() {
                objectives.push(s.to_string());
            } else if v.is_object() {
                let title = v
                    .get("title")
                    .or_else(|| v.get("objective"))
                    .or_else(|| v.get("text"))
                    .and_then(|x| x.as_str())
                    .unwrap_or("");
                if !title.trim().is_empty() {
                    objectives.push(title.to_string());
                }
            }
        }
        let assignee = input
            .get("assignee")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty());
        let group = task_db::planner_submit_objectives(&objectives, assignee)?;
        Ok(format!(
            "TaskPlanner: wrote {} step(s). planner_group_id={}",
            objectives.len(),
            group
        ))
    }
}
