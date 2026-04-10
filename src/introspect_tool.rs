//! Introspect tool: query recent tool call history from chump_tool_calls table.
//! Answers "what did I actually do last session?" without digging through logs.
//! Records are written by tool_middleware on every successful/failed/timed-out call.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct IntrospectTool;

/// Record a tool invocation in the persistent ring buffer (capped at 200 rows).
/// Called from tool_middleware so every call is captured without changing individual tools.
/// Silently no-ops when DB is unavailable to avoid disrupting tool execution.
pub fn record_call(tool: &str, args_snippet: &str, outcome: &str) {
    let Ok(conn) = crate::db_pool::get() else {
        return;
    };
    let _ = conn.execute(
        "INSERT INTO chump_tool_calls (tool, args_snippet, outcome) VALUES (?1, ?2, ?3)",
        rusqlite::params![tool, args_snippet, outcome],
    );
    // Keep at most 200 rows: delete oldest beyond cap
    let _ = conn.execute(
        "DELETE FROM chump_tool_calls WHERE id NOT IN (
            SELECT id FROM chump_tool_calls ORDER BY id DESC LIMIT 200
        )",
        [],
    );
}

pub fn introspect_available() -> bool {
    crate::db_pool::get().is_ok()
}

/// Last N tool calls for `GET /health` (`recent_tool_calls` field). Newest first.
/// Returns an empty array if the DB is unavailable or the query fails.
pub fn recent_tool_calls_json(limit: usize) -> serde_json::Value {
    let lim = limit.clamp(1, 50) as i64;
    let Ok(conn) = crate::db_pool::get() else {
        return json!([]);
    };
    let mut stmt = match conn.prepare(
        "SELECT tool, args_snippet, outcome, called_at FROM chump_tool_calls ORDER BY id DESC LIMIT ?1",
    ) {
        Ok(s) => s,
        Err(_) => return json!([]),
    };
    let iter = match stmt.query_map(rusqlite::params![lim], |r| {
        Ok(json!({
            "tool": r.get::<_, String>(0)?,
            "args_snippet": r.get::<_, String>(1)?,
            "outcome": r.get::<_, String>(2)?,
            "called_at": r.get::<_, String>(3)?,
        }))
    }) {
        Ok(i) => i,
        Err(_) => return json!([]),
    };
    let mut rows: Vec<serde_json::Value> = Vec::new();
    for row in iter {
        if let Ok(v) = row {
            rows.push(v);
        }
    }
    json!(rows)
}

#[async_trait]
impl Tool for IntrospectTool {
    fn name(&self) -> String {
        "introspect".to_string()
    }

    fn description(&self) -> String {
        "Query recent tool call history: what tools you called, with what args, and whether they succeeded. \
Action 'recent' returns the last N calls (default 20). Useful for \"what did I do last session?\" \
or confirming that a tool was actually called."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "description": "recent (only supported action)" },
                "limit": { "type": "integer", "description": "Number of rows to return (default 20, max 50)" },
                "tool": { "type": "string", "description": "Optional: filter to a specific tool name" }
            },
            "required": []
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .unwrap_or("recent");
        match action {
            "recent" | "" => {
                let limit = input
                    .get("limit")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(20)
                    .min(50) as usize;
                let filter_tool = input.get("tool").and_then(|v| v.as_str()).unwrap_or("");
                let conn = crate::db_pool::get()?;
                let mut rows: Vec<(String, String, String, String)> = if filter_tool.is_empty() {
                    let mut stmt = conn.prepare(
                        "SELECT tool, args_snippet, outcome, called_at FROM chump_tool_calls ORDER BY id DESC LIMIT ?1",
                    )?;
                    let collected = stmt
                        .query_map(rusqlite::params![limit as i64], |r| {
                            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                        })?
                        .collect::<Result<Vec<_>, _>>()?;
                    collected
                } else {
                    let mut stmt = conn.prepare(
                        "SELECT tool, args_snippet, outcome, called_at FROM chump_tool_calls WHERE tool = ?1 ORDER BY id DESC LIMIT ?2",
                    )?;
                    let collected = stmt
                        .query_map(rusqlite::params![filter_tool, limit as i64], |r| {
                            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                        })?
                        .collect::<Result<Vec<_>, _>>()?;
                    collected
                };
                rows.reverse(); // oldest-first for readability
                if rows.is_empty() {
                    return Ok("No tool calls recorded yet.".to_string());
                }
                let mut out = format!("Last {} tool calls (oldest first):\n", rows.len());
                for (tool, args, outcome, called_at) in &rows {
                    let mark = if outcome == "ok" { "✓" } else { "✗" };
                    out.push_str(&format!("  {} {} | {} | {}\n", mark, tool, args, called_at));
                }
                Ok(out)
            }
            other => Err(anyhow::anyhow!("Unknown action '{}'. Use: recent", other)),
        }
    }
}
