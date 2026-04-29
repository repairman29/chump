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
    let prev_hash: String = conn
        .query_row(
            "SELECT audit_hash FROM chump_tool_calls ORDER BY id DESC LIMIT 1",
            [],
            |r| r.get(0),
        )
        .unwrap_or_else(|_| "genesis_hash_00000000000000000000000000000000".to_string());

    let ts: String = conn
        .query_row("SELECT datetime('now')", [], |r| r.get(0))
        .unwrap_or_else(|_| "1970-01-01 00:00:00".to_string());

    use sha2::{Digest, Sha256};
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
    /// True when the oldest surviving row's predecessor has been deleted by
    /// the 200-row cap, so we used that row's stored_hash as the effective
    /// genesis for verification (rolling-genesis pattern, INFRA-142). The
    /// oldest row's own stored_hash is unverifiable in this mode; tampering
    /// of any *subsequent* row still surfaces as a chain break.
    #[serde(default)]
    pub rolling_genesis: bool,
}

/// Run on startup to verify the cryptographic integrity of the tool call chain.
/// Returns true if intact. On tamper detection, posts a high-salience blackboard
/// entry so agents see the corruption, and writes a SECURITY WARNING to stderr.
pub fn verify_audit_chain() -> bool {
    audit_chain_status().map(|s| s.intact).unwrap_or(false)
}

/// Detailed audit chain verification. Use this when you need to know *where* tampering
/// occurred, not just whether the chain is intact.
///
/// **Rolling-genesis semantics (INFRA-142).** The 200-row cap deletes the
/// oldest surviving rows on every insert beyond the cap, which means after
/// the table has filled once, the row chain no longer reaches back to the
/// `"genesis_hash_..."` constant — the oldest surviving row's stored_hash
/// was originally chained against a now-deleted predecessor, so a strict
/// genesis-verifier would flag a "TAMPER DETECTED" on every chump invocation
/// after the table fills (false positive observed 2026-04-26 at row 429).
///
/// Fix: treat the oldest surviving row's `stored_hash` as the effective
/// genesis for this verification run. We can't verify that row itself —
/// its predecessor is gone — but every subsequent row IS verified against
/// its actual predecessor's stored_hash. Tampering with any non-oldest row
/// still surfaces as a chain break at the row immediately after the modified
/// one. The `rolling_genesis` field on [`AuditChainStatus`] is `true` when
/// this mode was used so callers can reason about what was and wasn't
/// verifiable.
///
/// When `id == 1` is still present (the cap has not yet been exercised) we
/// use the literal genesis constant and verify the whole chain end-to-end.
pub fn audit_chain_status() -> Result<AuditChainStatus> {
    let conn = crate::db_pool::get()?;
    let status = audit_chain_status_with_conn(&conn)?;
    // Broadcast tamper detection to the blackboard with high salience so agents see it.
    // This side effect lives only in the public wrapper, so the pure verifier
    // helper stays test-friendly.
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

/// Inner helper: verify the chain against an arbitrary `Connection`. Split out
/// from [`audit_chain_status`] so tests can pass a fresh in-memory SQLite
/// without going through the global `db_pool` OnceLock (which is already
/// initialized in any process running other tests). Pure: no side effects
/// beyond stderr (security-warning print on tamper).
pub(crate) fn audit_chain_status_with_conn(
    conn: &rusqlite::Connection,
) -> Result<AuditChainStatus> {
    let mut stmt = conn.prepare(
        "SELECT id, tool, args_snippet, outcome, called_at, audit_hash \
         FROM chump_tool_calls ORDER BY id ASC",
    )?;
    let mut status = AuditChainStatus {
        intact: true,
        chained_rows: 0,
        legacy_rows: 0,
        tamper_points: Vec::new(),
        rolling_genesis: false,
    };

    use sha2::{Digest, Sha256};
    let mut rows = stmt.query([])?;
    let mut expected_prev_hash: Option<String> = None;
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

        // First chained row we encounter: pick the genesis we'll verify
        // against. If the row is id == 1, the cap hasn't trimmed yet so the
        // literal genesis constant is correct. Otherwise, the predecessor
        // has been aged out by the cap, so we treat THIS row's stored_hash
        // as the rolling genesis and skip verifying it (we have no way to
        // recompute the deleted predecessor's hash). All subsequent rows
        // chain forward from here normally.
        if expected_prev_hash.is_none() {
            if row_id == 1 {
                expected_prev_hash =
                    Some("genesis_hash_00000000000000000000000000000000".to_string());
            } else {
                status.rolling_genesis = true;
                expected_prev_hash = Some(stored_hash.clone());
                status.chained_rows += 1;
                continue;
            }
        }
        let prev = expected_prev_hash.as_ref().expect("set above");

        let mut hasher = Sha256::new();
        hasher.update(prev);
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
            status
                .tamper_points
                .push((row_id, tool.clone(), ts.clone()));
            status.intact = false;
        }
        status.chained_rows += 1;
        expected_prev_hash = Some(stored_hash);
    }

    Ok(status)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use sha2::{Digest, Sha256};

    /// Spin up an in-memory SQLite with the chump_tool_calls schema and
    /// insert `n` rows whose audit_hash chains form a valid chain rooted
    /// at the literal genesis_hash constant. Returns the populated
    /// connection.
    fn make_chained_db(n: usize) -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE chump_tool_calls (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                tool          TEXT,
                args_snippet  TEXT,
                outcome       TEXT,
                called_at     TEXT,
                audit_hash    TEXT
            );",
        )
        .unwrap();
        let mut prev = "genesis_hash_00000000000000000000000000000000".to_string();
        for i in 1..=n {
            let tool = format!("tool_{i}");
            let args = format!("args_{i}");
            let outcome = "ok".to_string();
            let ts = format!("2026-04-28T12:00:{:02}Z", i % 60);
            let mut h = Sha256::new();
            h.update(&prev);
            h.update(&ts);
            h.update(&tool);
            h.update(&args);
            h.update(&outcome);
            let next = hex::encode(h.finalize());
            conn.execute(
                "INSERT INTO chump_tool_calls (tool, args_snippet, outcome, called_at, audit_hash) VALUES (?1,?2,?3,?4,?5)",
                rusqlite::params![tool, args, outcome, ts, next],
            )
            .unwrap();
            prev = next;
        }
        conn
    }

    #[test]
    fn chain_intact_when_no_aging_yet() {
        // Cap not exercised: id == 1 is still present, full genesis verify.
        let conn = make_chained_db(50);
        let s = audit_chain_status_with_conn(&conn).unwrap();
        assert!(s.intact, "tamper_points: {:?}", s.tamper_points);
        assert_eq!(s.chained_rows, 50);
        assert!(!s.rolling_genesis);
    }

    #[test]
    fn chain_intact_when_oldest_rows_aged_out_by_cap() {
        // INFRA-142 regression: simulate the cap deleting the first 50 rows
        // of a 250-row history. id == 1 is gone; oldest surviving row's
        // predecessor is gone. Pre-fix this would falsely report TAMPER on
        // every chump invocation. Post-fix: rolling_genesis kicks in and the
        // chain verifies cleanly forward from the new oldest row.
        let conn = make_chained_db(250);
        conn.execute(
            "DELETE FROM chump_tool_calls WHERE id NOT IN (
                SELECT id FROM chump_tool_calls ORDER BY id DESC LIMIT 200
            )",
            [],
        )
        .unwrap();
        let s = audit_chain_status_with_conn(&conn).unwrap();
        assert!(
            s.intact,
            "post-cap chain should verify; tamper: {:?}",
            s.tamper_points
        );
        assert!(s.rolling_genesis, "should switch to rolling-genesis mode");
        // 200 surviving rows; oldest used as effective genesis (counted but
        // not re-verified), 199 verified against their predecessor.
        assert_eq!(s.chained_rows, 200);
    }

    #[test]
    fn tamper_in_non_oldest_row_still_detected_after_cap() {
        // Build 250 rows, cap to last 200, then UPDATE a middle row's
        // audit_hash. The verifier must catch this — rolling-genesis must
        // not paper over tampering of any row beyond the oldest.
        let conn = make_chained_db(250);
        conn.execute(
            "DELETE FROM chump_tool_calls WHERE id NOT IN (
                SELECT id FROM chump_tool_calls ORDER BY id DESC LIMIT 200
            )",
            [],
        )
        .unwrap();
        // Pick a row well past the rolling genesis (id 100, which is in the
        // middle of the surviving range 51..250).
        conn.execute(
            "UPDATE chump_tool_calls SET audit_hash = ?1 WHERE id = 100",
            rusqlite::params!["deadbeef".repeat(8)],
        )
        .unwrap();
        let s = audit_chain_status_with_conn(&conn).unwrap();
        assert!(!s.intact, "expected tamper, got intact chain");
        // Tamper at id 100 means row 100's hash doesn't match what its
        // ancestor's hash would compute, AND row 101 chains forward against
        // a now-bogus hash so its computed != stored either. Both rows surface.
        assert!(
            s.tamper_points
                .iter()
                .any(|(id, _, _)| *id == 100 || *id == 101),
            "tamper should be reported at row 100 or 101: {:?}",
            s.tamper_points
        );
    }

    #[test]
    fn empty_table_is_trivially_intact() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE chump_tool_calls (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                tool          TEXT, args_snippet TEXT, outcome TEXT,
                called_at     TEXT, audit_hash TEXT
            );",
        )
        .unwrap();
        let s = audit_chain_status_with_conn(&conn).unwrap();
        assert!(s.intact);
        assert_eq!(s.chained_rows, 0);
        assert!(!s.rolling_genesis);
    }

    #[test]
    fn legacy_rows_without_audit_hash_are_skipped() {
        let conn = make_chained_db(5);
        // Insert two more rows with empty audit_hash — these are pre-migration
        // legacy rows, must not be counted toward chained_rows or break the
        // verifier.
        conn.execute(
            "INSERT INTO chump_tool_calls (tool, args_snippet, outcome, called_at, audit_hash) VALUES (?1,?2,?3,?4,?5)",
            rusqlite::params!["legacy", "x", "ok", "2026-04-28T13:00:00Z", ""],
        )
        .unwrap();
        let s = audit_chain_status_with_conn(&conn).unwrap();
        assert!(s.intact, "tamper: {:?}", s.tamper_points);
        assert_eq!(s.chained_rows, 5);
        assert_eq!(s.legacy_rows, 1);
    }
}
