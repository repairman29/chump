//! Persistent task queue (open → in_progress → blocked → done). Same DB file as chump_memory.

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
        CREATE TABLE IF NOT EXISTS chump_tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            repo TEXT,
            issue_number INTEGER,
            status TEXT DEFAULT 'open',
            notes TEXT,
            created_at TEXT,
            updated_at TEXT
        );
        ",
    )?;
    Ok(conn)
}

fn now_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    format!("{}.{:03}", t.as_secs(), t.subsec_millis())
}

#[derive(Debug, Clone)]
pub struct TaskRow {
    pub id: i64,
    pub title: String,
    pub repo: Option<String>,
    pub issue_number: Option<i64>,
    pub status: String,
    pub notes: Option<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

pub fn task_create(title: &str, repo: Option<&str>, issue_number: Option<i64>) -> Result<i64> {
    let conn = open_db()?;
    let now = now_iso();
    conn.execute(
        "INSERT INTO chump_tasks (title, repo, issue_number, status, created_at, updated_at) VALUES (?1, ?2, ?3, 'open', ?4, ?4)",
        [title, repo.unwrap_or(""), &issue_number.unwrap_or(0).to_string(), &now],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn task_list(status_filter: Option<&str>) -> Result<Vec<TaskRow>> {
    let conn = open_db()?;
    let sql = match status_filter {
        Some("open") => "SELECT id, title, repo, issue_number, status, notes, created_at, updated_at FROM chump_tasks WHERE status = 'open' ORDER BY id",
        Some("blocked") => "SELECT id, title, repo, issue_number, status, notes, created_at, updated_at FROM chump_tasks WHERE status = 'blocked' ORDER BY id",
        Some("in_progress") => "SELECT id, title, repo, issue_number, status, notes, created_at, updated_at FROM chump_tasks WHERE status = 'in_progress' ORDER BY id",
        Some("done") => "SELECT id, title, repo, issue_number, status, notes, created_at, updated_at FROM chump_tasks WHERE status = 'done' ORDER BY id",
        Some("abandoned") => "SELECT id, title, repo, issue_number, status, notes, created_at, updated_at FROM chump_tasks WHERE status = 'abandoned' ORDER BY id",
        _ => "SELECT id, title, repo, issue_number, status, notes, created_at, updated_at FROM chump_tasks WHERE status IN ('open', 'blocked', 'in_progress') ORDER BY id",
    };
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([], |r| {
        Ok(TaskRow {
            id: r.get(0)?,
            title: r.get(1)?,
            repo: r.get::<_, Option<String>>(2)?.filter(|s| !s.is_empty()),
            issue_number: r.get::<_, Option<i64>>(3)?.filter(|&n| n != 0),
            status: r.get(4)?,
            notes: r.get(5)?,
            created_at: r.get(6)?,
            updated_at: r.get(7)?,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub fn task_update_status(id: i64, status: &str, notes: Option<&str>) -> Result<bool> {
    let conn = open_db()?;
    let now = now_iso();
    let n = conn.execute(
        "UPDATE chump_tasks SET status = ?1, notes = COALESCE(?2, notes), updated_at = ?3 WHERE id = ?4",
        rusqlite::params![status, notes, now, id],
    )?;
    Ok(n > 0)
}

pub fn task_complete(id: i64, notes: Option<&str>) -> Result<bool> {
    task_update_status(id, "done", notes)
}

pub fn task_available() -> bool {
    open_db().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn task_create_and_list_roundtrip() {
        let dir = std::env::temp_dir().join("chump_task_db_test");
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let id = task_create("Fix login bug", Some("owner/repo"), Some(47)).unwrap();
        assert!(id > 0);
        let open_list = task_list(Some("open")).unwrap();
        assert_eq!(open_list.len(), 1);
        assert_eq!(open_list[0].title, "Fix login bug");
        assert_eq!(open_list[0].repo.as_deref(), Some("owner/repo"));
        assert_eq!(open_list[0].issue_number, Some(47));
        assert_eq!(open_list[0].status, "open");

        task_update_status(id, "in_progress", Some("Working on it")).unwrap();
        let in_progress = task_list(Some("in_progress")).unwrap();
        assert_eq!(in_progress.len(), 1);
        assert_eq!(in_progress[0].notes.as_deref(), Some("Working on it"));

        task_complete(id, Some("Done")).unwrap();
        let done_list = task_list(Some("done")).unwrap();
        assert_eq!(done_list.len(), 1);

        let id2 = task_create("Wontfix idea", None, None).unwrap();
        task_update_status(id2, "abandoned", Some("Out of scope")).unwrap();
        let abandoned_list = task_list(Some("abandoned")).unwrap();
        assert_eq!(abandoned_list.len(), 1);
        assert_eq!(abandoned_list[0].title, "Wontfix idea");

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join(DB_FILENAME);
        let _ = std::fs::remove_file(db_file);
    }
}
