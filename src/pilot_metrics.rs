//! Read-only JSON for pilot / market metric N4-style reporting. See `docs/WEDGE_PILOT_METRICS.md`.

use anyhow::Result;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::db_pool;
use crate::speculative_execution;
use crate::task_db;

/// Aggregate task counts, episode totals, recent tool-call ring stats, last speculative batch.
pub fn pilot_summary_json() -> Result<Value> {
    let conn = db_pool::get()?;
    let tasks = task_db::task_list(None)?;
    let mut tasks_by_status: BTreeMap<String, usize> = BTreeMap::new();
    for t in &tasks {
        *tasks_by_status.entry(t.status.clone()).or_insert(0) += 1;
    }
    let tasks_total = tasks.len();

    let episodes_total: i64 = conn
        .query_row("SELECT COUNT(*) FROM chump_episodes", [], |r| r.get(0))
        .unwrap_or(0);

    let tool_calls_ring: i64 = conn
        .query_row("SELECT COUNT(*) FROM chump_tool_calls", [], |r| r.get(0))
        .unwrap_or(0);

    let run_cli_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM chump_tool_calls WHERE lower(tool) = lower('run_cli')",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);

    let mut last_tool_calls: Vec<Value> = Vec::new();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT tool, args_snippet, outcome, called_at FROM chump_tool_calls ORDER BY id DESC LIMIT 8",
    ) {
        if let Ok(iter) = stmt.query_map([], |r| {
            Ok(json!({
                "tool": r.get::<_, String>(0)?,
                "args_snippet": r.get::<_, String>(1)?,
                "outcome": r.get::<_, String>(2)?,
                "called_at": r.get::<_, String>(3)?,
            }))
        }) {
            for row in iter.flatten() {
                last_tool_calls.push(row);
            }
        }
    }

    let generated_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    Ok(json!({
        "generated_at_unix": generated_at_unix,
        "tasks_total": tasks_total,
        "tasks_by_status": tasks_by_status,
        "episodes_total": episodes_total,
        "tool_calls_ring_buffer_rows": tool_calls_ring,
        "run_cli_invocations_in_ring": run_cli_count,
        "last_tool_calls_sample": last_tool_calls,
        "speculative_batch_last": speculative_execution::last_speculative_metrics_json(),
    }))
}
