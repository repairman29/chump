//! Scheduled alarms: fire_at + prompt + context. Heartbeat checks due() first. Same DB as chump_memory.

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
        CREATE TABLE IF NOT EXISTS chump_scheduled (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fire_at TEXT NOT NULL,
            prompt TEXT NOT NULL,
            context TEXT,
            fired INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_chump_scheduled_fire ON chump_scheduled (fired, fire_at);
        ",
    )?;
    Ok(conn)
}

#[derive(Debug, Clone)]
pub struct ScheduledRow {
    pub id: i64,
    pub fire_at: String,
    pub prompt: String,
    pub context: Option<String>,
    pub fired: i64,
}

/// Parse fire_at: unix timestamp (seconds) or relative (e.g. "4h", "2d", "30m"). Returns epoch seconds.
fn parse_fire_at(s: &str) -> Result<i64> {
    let s = s.trim();
    if s.is_empty() {
        return Err(anyhow::anyhow!("fire_at is empty"));
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    if let Ok(n) = s.parse::<i64>() {
        return Ok(n);
    }
    let lower = s.to_lowercase();
    if lower.ends_with('h') {
        let n: i64 = lower.trim_end_matches('h').trim().parse().map_err(|_| anyhow::anyhow!("fire_at: expected number before 'h' (e.g. 4h)"))?;
        return Ok(now + n * 3600);
    }
    if lower.ends_with('d') {
        let n: i64 = lower.trim_end_matches('d').trim().parse().map_err(|_| anyhow::anyhow!("fire_at: expected number before 'd' (e.g. 2d)"))?;
        return Ok(now + n * 86400);
    }
    if lower.ends_with('m') {
        let n: i64 = lower.trim_end_matches('m').trim().parse().map_err(|_| anyhow::anyhow!("fire_at: expected number before 'm' (e.g. 30m)"))?;
        return Ok(now + n * 60);
    }
    Err(anyhow::anyhow!(
        "fire_at: use unix timestamp (seconds) or relative: 4h, 2d, 30m"
    ))
}

/// Create a scheduled alarm. fire_at: unix epoch (seconds) or RFC3339/ISO datetime string.
pub fn schedule_create(fire_at: &str, prompt: &str, context: Option<&str>) -> Result<i64> {
    let conn = open_db()?;
    let at = parse_fire_at(fire_at)?;
    let at_str = at.to_string();
    conn.execute(
        "INSERT INTO chump_scheduled (fire_at, prompt, context, fired) VALUES (?1, ?2, ?3, 0)",
        rusqlite::params![at_str, prompt, context.unwrap_or("")],
    )?;
    Ok(conn.last_insert_rowid())
}

/// List scheduled items. If include_fired, include already-fired; otherwise only upcoming/pending.
pub fn schedule_list(include_fired: bool) -> Result<Vec<ScheduledRow>> {
    let conn = open_db()?;
    let sql = if include_fired {
        "SELECT id, fire_at, prompt, context, fired FROM chump_scheduled ORDER BY fire_at DESC"
    } else {
        "SELECT id, fire_at, prompt, context, fired FROM chump_scheduled WHERE fired = 0 ORDER BY fire_at ASC"
    };
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([], |r| {
        Ok(ScheduledRow {
            id: r.get(0)?,
            fire_at: r.get(1)?,
            prompt: r.get(2)?,
            context: r.get::<_, Option<String>>(3)?.filter(|s| !s.is_empty()),
            fired: r.get(4)?,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Return all due items (fire_at <= now, not yet fired). Heartbeat runner should call this first; for each item use the prompt as session prompt and then mark_fired(id).
pub fn schedule_due() -> Result<Vec<(i64, String, String)>> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let conn = open_db()?;
    let mut stmt = conn.prepare(
        "SELECT id, prompt, context FROM chump_scheduled WHERE fired = 0 AND CAST(fire_at AS INTEGER) <= ?1 ORDER BY fire_at ASC",
    )?;
    let rows = stmt.query_map([now], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2).unwrap_or_default(),
        ))
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Mark an item as fired so it won't be returned by due() again.
pub fn schedule_mark_fired(id: i64) -> Result<bool> {
    let conn = open_db()?;
    let n = conn.execute("UPDATE chump_scheduled SET fired = 1 WHERE id = ?1", [id])?;
    Ok(n > 0)
}

/// Remove a scheduled item (cancel).
pub fn schedule_cancel(id: i64) -> Result<bool> {
    let conn = open_db()?;
    let n = conn.execute("DELETE FROM chump_scheduled WHERE id = ?1", [id])?;
    Ok(n > 0)
}

pub fn schedule_available() -> bool {
    open_db().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn schedule_create_list_due_mark_fired() {
        let dir = std::env::temp_dir().join("chump_schedule_db_test");
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let id_later = schedule_create("999d", "Check on PR later", Some("pr=61")).unwrap();
        assert!(id_later > 0);
        let list = schedule_list(false).unwrap();
        assert_eq!(list.len(), 1);
        assert!(list[0].prompt.contains("PR"));

        let id_now = schedule_create("0m", "Fire now prompt", Some("task=1")).unwrap();
        let due = schedule_due().unwrap();
        assert!(!due.is_empty());
        let (id, prompt, _ctx) = due.first().unwrap();
        assert!(prompt.contains("Fire now"));
        schedule_mark_fired(*id).unwrap();
        let due_after = schedule_due().unwrap();
        assert!(due_after.is_empty() || due_after.iter().all(|(i, _, _)| *i != id_now));

        schedule_cancel(id_later).unwrap();
        let list2 = schedule_list(true).unwrap();
        assert!(list2.is_empty() || list2.iter().all(|r| r.id != id_later));

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join("sessions/chump_memory.db");
        let _ = std::fs::remove_file(db_file);
    }
}
