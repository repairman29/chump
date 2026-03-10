//! Persistent ego state: mood, current_focus, frustrations, etc. Same DB file as chump_memory/tasks.

use anyhow::Result;
use rusqlite::Connection;
use std::path::PathBuf;

const DB_FILENAME: &str = "sessions/chump_memory.db";

fn db_path() -> PathBuf {
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(DB_FILENAME)
}

fn open_db() -> Result<Connection> {
    let path = db_path();
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let conn = Connection::open(&path)?;
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS chump_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        ",
    )?;
    Ok(conn)
}

fn now_sqlite() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = t.as_secs();
    let ms = t.subsec_millis();
    format!("{}.{:03}", secs, ms)
}

fn ensure_seeded(conn: &Connection) -> Result<()> {
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM chump_state", [], |r| r.get(0))?;
    if count > 0 {
        return Ok(());
    }
    let now = now_sqlite();
    for (k, v) in [
        ("current_focus", "Getting oriented. Reading the repos."),
        ("mood", "neutral"),
        ("frustrations", "none yet"),
        ("curiosities", "Want to understand the full system architecture."),
        ("recent_wins", "none yet"),
        ("things_jeff_should_know", "none yet"),
        (
            "drive_scores",
            "{\"green_repos\":0,\"recent_ship\":0,\"learning\":0,\"system_understanding\":0}",
        ),
        ("session_count", "0"),
        ("last_session_summary", "First session."),
    ] {
        conn.execute(
            "INSERT OR IGNORE INTO chump_state (key, value, updated_at) VALUES (?1, ?2, ?3)",
            rusqlite::params![k, v, now],
        )?;
    }
    Ok(())
}

/// Read all state as a formatted block (for session start).
pub fn state_read_all() -> Result<String> {
    let conn = open_db()?;
    ensure_seeded(&conn)?;
    let mut stmt = conn.prepare("SELECT key, value, updated_at FROM chump_state ORDER BY key")?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    let mut out = String::new();
    for row in rows {
        let (k, v, updated) = row?;
        out.push_str(&format!("{}: {}\n  (updated {})\n", k, v, updated));
    }
    Ok(out)
}

/// Read one key.
pub fn state_read(key: &str) -> Result<Option<String>> {
    let conn = open_db()?;
    ensure_seeded(&conn)?;
    let mut stmt = conn.prepare("SELECT value FROM chump_state WHERE key = ?1")?;
    let mut rows = stmt.query(rusqlite::params![key])?;
    if let Some(row) = rows.next()? {
        let v: String = row.get(0)?;
        return Ok(Some(v));
    }
    Ok(None)
}

/// Write one key (overwrites).
pub fn state_write(key: &str, value: &str) -> Result<()> {
    let conn = open_db()?;
    ensure_seeded(&conn)?;
    let now = now_sqlite();
    conn.execute(
        "INSERT INTO chump_state (key, value, updated_at) VALUES (?1, ?2, ?3) \
         ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3",
        rusqlite::params![key, value, now],
    )?;
    Ok(())
}

/// Append to a key's value (newline + new content). Creates key if missing.
pub fn state_append(key: &str, value: &str) -> Result<()> {
    let conn = open_db()?;
    ensure_seeded(&conn)?;
    let now = now_sqlite();
    let current: String = conn
        .query_row(
            "SELECT value FROM chump_state WHERE key = ?1",
            rusqlite::params![key],
            |r| r.get(0),
        )
        .unwrap_or_else(|_| String::new());
    let new_value = if current.is_empty() {
        value.to_string()
    } else {
        format!("{}\n{}", current, value)
    };
    conn.execute(
        "INSERT INTO chump_state (key, value, updated_at) VALUES (?1, ?2, ?3) \
         ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3",
        rusqlite::params![key, new_value, now],
    )?;
    Ok(())
}

/// Increment a numeric state key (e.g. session_count). Parses as i64, adds 1, writes back.
pub fn state_increment(key: &str) -> Result<i64> {
    let conn = open_db()?;
    ensure_seeded(&conn)?;
    let now = now_sqlite();
    let current: String = conn
        .query_row(
            "SELECT value FROM chump_state WHERE key = ?1",
            rusqlite::params![key],
            |r| r.get(0),
        )
        .unwrap_or_else(|_| "0".to_string());
    let n: i64 = current.trim().parse().unwrap_or(0);
    let new_val = n + 1;
    conn.execute(
        "INSERT INTO chump_state (key, value, updated_at) VALUES (?1, ?2, ?3) \
         ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3",
        rusqlite::params![key, new_val.to_string(), now],
    )?;
    Ok(new_val)
}

pub fn state_available() -> bool {
    open_db().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn state_seed_read_all_write_read_append() {
        let dir = std::env::temp_dir().join("chump_state_db_test");
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let block = state_read_all().unwrap();
        assert!(block.contains("current_focus"));
        assert!(block.contains("mood"));

        state_write("mood", "focused").unwrap();
        let v = state_read("mood").unwrap().unwrap();
        assert_eq!(v, "focused");

        state_append("frustrations", "Auth module is tricky").unwrap();
        let v = state_read("frustrations").unwrap().unwrap();
        assert!(v.contains("Auth module is tricky"));

        let n = state_increment("session_count").unwrap();
        assert!(n >= 1);

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join("sessions/chump_memory.db");
        let _ = std::fs::remove_file(db_file);
    }
}
