//! Async questions to Jeff: store question, optional answer. Used by ask_jeff tool and assemble_context.

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
        "CREATE TABLE IF NOT EXISTS chump_questions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            question TEXT NOT NULL, context TEXT, priority TEXT DEFAULT 'curious',
            asked_at TEXT DEFAULT (datetime('now')), answered_at TEXT, answer TEXT
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

pub fn question_ask(question: &str, context: Option<&str>, priority: &str) -> Result<i64> {
    let conn = open_db()?;
    let now = now_iso();
    let priority = match priority {
        "blocking" | "curious" | "fyi" => priority,
        _ => "curious",
    };
    conn.execute(
        "INSERT INTO chump_questions (question, context, priority, asked_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![question, context.unwrap_or(""), priority, now],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn question_answer(id: i64, answer: &str) -> Result<bool> {
    let conn = open_db()?;
    let now = now_iso();
    let n = conn.execute(
        "UPDATE chump_questions SET answer = ?1, answered_at = ?2 WHERE id = ?3 AND answered_at IS NULL",
        rusqlite::params![answer, now, id],
    )?;
    Ok(n > 0)
}

/// Unanswered questions with priority=blocking (for assemble_context).
pub fn list_unanswered_blocking(limit: usize) -> Result<Vec<(i64, String, String)>> {
    let conn = open_db()?;
    let limit = limit.min(20);
    let mut stmt = conn.prepare(
        "SELECT id, question, asked_at FROM chump_questions WHERE priority = 'blocking' AND answered_at IS NULL ORDER BY id ASC LIMIT ?1",
    )?;
    let rows = stmt.query_map([limit], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Recently answered questions (for assemble_context to show "Jeff answered").
pub fn list_recent_answers(limit: usize) -> Result<Vec<(i64, String, String)>> {
    let conn = open_db()?;
    let limit = limit.min(10);
    let mut stmt = conn.prepare(
        "SELECT id, question, answer FROM chump_questions WHERE answered_at IS NOT NULL ORDER BY answered_at DESC LIMIT ?1",
    )?;
    let rows = stmt.query_map([limit], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub fn ask_jeff_available() -> bool {
    open_db().is_ok()
}
