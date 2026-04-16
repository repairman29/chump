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
    
    // Sprint A Phase 3: Tamper-evident chain
    let prev_hash: String = conn.query_row(
        "SELECT audit_hash FROM chump_tool_calls ORDER BY id DESC LIMIT 1",
        [],
        |r| r.get(0),
    ).unwrap_or_else(|_| "genesis_hash_00000000000000000000000000000000".to_string());

    let ts: String = conn.query_row("SELECT datetime('now')", [], |r| r.get(0))
        .unwrap_or_else(|_| "1970-01-01 00:00:00".to_string());

    use sha2::{Sha256, Digest};
    let mut hasher = Sha256::new();
    hasher.update(&prev_hash);
    hasher.update(&ts);
    hasher.update(tool);
    hasher.update(args_snippet);
    hasher.update(outcome);
    let audit_hash = hex::encode(hasher.finalize());

    let _ = conn.execute(
        "INSERT INTO chump_tool_calls (tool, args_snippet, outcome, called_at, audit_hash) VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![tool, args_snippet, outcome, ts, audit_hash],
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
    for v in iter.flatten() {
        rows.push(v);
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

/// Structured result of an audit chain verification.
#[derive(Debug, Clone, serde::Serialize)]
pub struct AuditChainStatus {
    /// True if the entire chain verified cleanly.
    pub intact: bool,
    /// Total chained rows (excluding legacy rows without audit_hash).
    pub chained_rows: u64,
    /// Count of legacy rows (pre-migration, no audit_hash). These are skipped for compatibility.
    pub legacy_rows: u64,
    /// Rows where the stored hash didn't match the recomputed hash. Each entry is
    /// `(row_id, tool_name, timestamp)`.
    pub tamper_points: Vec<(i64, String, String)>,
}

/// Run on startup to verify the cryptographic integrity of the tool call chain.
/// Returns true if intact. On tamper detection, posts a high-salience blackboard
/// entry so agents see the corruption, and writes a SECURITY WARNING to stderr.
pub fn verify_audit_chain() -> bool {
    audit_chain_status().map(|s| s.intact).unwrap_or(false)
}

/// Detailed audit chain verification. Use this when you need to know *where* tampering
/// occurred, not just whether the chain is intact.
pub fn audit_chain_status() -> Result<AuditChainStatus> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT id, tool, args_snippet, outcome, called_at, audit_hash \
         FROM chump_tool_calls ORDER BY id ASC",
    )?;
    let mut expected_prev_hash = "genesis_hash_00000000000000000000000000000000".to_string();
    let mut status = AuditChainStatus {
        intact: true,
        chained_rows: 0,
        legacy_rows: 0,
        tamper_points: Vec::new(),
    };

    use sha2::{Digest, Sha256};
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let row_id: i64 = row.get(0).unwrap_or(-1);
        let tool: String = row.get(1).unwrap_or_default();
        let args: String = row.get(2).unwrap_or_default();
        let outcome: String = row.get(3).unwrap_or_default();
        let ts: String = row.get(4).unwrap_or_default();
        let stored_hash: String = row.get(5).unwrap_or_default();

        if stored_hash.is_empty() {
            // Legacy row from before the audit_hash migration. Skip for compatibility.
            status.legacy_rows += 1;
            continue;
        }

        let mut hasher = Sha256::new();
        hasher.update(&expected_prev_hash);
        hasher.update(&ts);
        hasher.update(&tool);
        hasher.update(&args);
        hasher.update(&outcome);
        let computed = hex::encode(hasher.finalize());

        if computed != stored_hash {
            eprintln!(
                "[SECURITY WARNING] Tool audit chain integrity compromised at row {} / {} (tool: {})",
                row_id, ts, tool
            );
            status.tamper_points.push((row_id, tool.clone(), ts.clone()));
            status.intact = false;
        }
        status.chained_rows += 1;
        expected_prev_hash = stored_hash;
    }

    // Broadcast tamper detection to the blackboard with high salience so agents see it.
    if !status.intact {
        crate::blackboard::post(
            crate::blackboard::Module::Custom("audit_chain".into()),
            format!(
                "Security (A3): audit chain TAMPER DETECTED — {} corrupted row(s) in chump_tool_calls. Chain integrity compromised; someone modified the tool-call ledger directly in SQLite.",
                status.tamper_points.len()
            ),
            crate::blackboard::SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.9,
                goal_relevance: 1.0,
                urgency: 1.0,
            },
        );
    }

    Ok(status)
}
