//! Persistent tool health: record structural failures (not installed, permission denied, etc.)
//! so assemble_context can inject "Tools degraded/unavailable" and Chump avoids retrying.
//! Same DB file as chump_memory.

use anyhow::Result;
#[cfg(test)]
use rusqlite::Connection;

#[cfg(not(test))]
fn open_db() -> Result<r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>> {
    crate::db_pool::get()
}

#[cfg(test)]
fn open_db() -> Result<Connection> {
    let path = std::env::current_dir()
        .unwrap_or_else(|_| std::path::PathBuf::from("."))
        .join("sessions/chump_memory.db");
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let conn = Connection::open(&path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chump_tool_health (
            tool TEXT PRIMARY KEY, status TEXT DEFAULT 'ok', last_error TEXT,
            last_checked TEXT, failure_count INTEGER DEFAULT 0
        );",
    )?;
    Ok(conn)
}

fn now_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}", t.as_secs(), t.subsec_millis())
}

/// Record a structural tool failure (e.g. command not found, permission denied).
/// status: "degraded" or "unavailable". Call from tools when they detect a persistent failure.
pub fn record_failure(tool: &str, status: &str, last_error: Option<&str>) -> Result<()> {
    let conn = open_db()?;
    let now = now_iso();
    let err = last_error.unwrap_or("");
    conn.execute(
        "INSERT INTO chump_tool_health (tool, status, last_error, last_checked, failure_count) \
         VALUES (?1, ?2, ?3, ?4, 1) \
         ON CONFLICT(tool) DO UPDATE SET \
         status = ?2, last_error = ?3, last_checked = ?4, failure_count = failure_count + 1",
        rusqlite::params![tool, status, err, now],
    )?;
    Ok(())
}

/// List tools with status 'degraded'.
pub fn list_degraded() -> Result<Vec<String>> {
    let conn = open_db()?;
    let mut stmt =
        conn.prepare("SELECT tool FROM chump_tool_health WHERE status = 'degraded' ORDER BY tool")?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// List tools with status 'unavailable'.
pub fn list_unavailable() -> Result<Vec<String>> {
    let conn = open_db()?;
    let mut stmt = conn
        .prepare("SELECT tool FROM chump_tool_health WHERE status = 'unavailable' ORDER BY tool")?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Clear status for a tool (e.g. after successful use). Optional.
#[allow(dead_code)]
pub fn clear_status(tool: &str) -> Result<()> {
    let conn = open_db()?;
    conn.execute("DELETE FROM chump_tool_health WHERE tool = ?1", [tool])?;
    Ok(())
}

pub fn tool_health_available() -> bool {
    open_db().is_ok()
}
