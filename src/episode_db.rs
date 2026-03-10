//! Episodic memory: what happened, when, tags, sentiment. Same DB file as chump_memory.

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
        CREATE TABLE IF NOT EXISTS chump_episodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            happened_at TEXT NOT NULL DEFAULT (datetime('now')),
            summary TEXT NOT NULL,
            detail TEXT,
            tags TEXT,
            repo TEXT,
            sentiment TEXT CHECK(sentiment IN ('win','loss','neutral','frustrating','uncertain')),
            pr_number INTEGER,
            issue_number INTEGER
        );
        ",
    )?;
    Ok(conn)
}

fn now_sqlite() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    format!("{}.{:03}", t.as_secs(), t.subsec_millis())
}

#[derive(Debug, Clone)]
pub struct EpisodeRow {
    pub id: i64,
    pub happened_at: String,
    pub summary: String,
    pub detail: Option<String>,
    pub tags: Option<String>,
    pub repo: Option<String>,
    pub sentiment: Option<String>,
    pub pr_number: Option<i64>,
    pub issue_number: Option<i64>,
}

fn row_from_query(r: &rusqlite::Row) -> Result<EpisodeRow, rusqlite::Error> {
    Ok(EpisodeRow {
        id: r.get(0)?,
        happened_at: r.get(1)?,
        summary: r.get(2)?,
        detail: r.get::<_, Option<String>>(3)?.filter(|s| !s.is_empty()),
        tags: r.get::<_, Option<String>>(4)?.filter(|s| !s.is_empty()),
        repo: r.get::<_, Option<String>>(5)?.filter(|s| !s.is_empty()),
        sentiment: r.get::<_, Option<String>>(6)?.filter(|s| !s.is_empty()),
        pr_number: r.get::<_, Option<i64>>(7)?.filter(|&n| n != 0),
        issue_number: r.get::<_, Option<i64>>(8)?.filter(|&n| n != 0),
    })
}

/// Log one episode.
pub fn episode_log(
    summary: &str,
    detail: Option<&str>,
    tags: Option<&str>,
    repo: Option<&str>,
    sentiment: Option<&str>,
    pr_number: Option<i64>,
    issue_number: Option<i64>,
) -> Result<i64> {
    let conn = open_db()?;
    let now = now_sqlite();
    let sentiment = sentiment
        .filter(|s| {
            ["win", "loss", "neutral", "frustrating", "uncertain"]
                .iter()
                .any(|a| a.eq_ignore_ascii_case(s))
        })
        .unwrap_or("neutral");
    conn.execute(
        "INSERT INTO chump_episodes (happened_at, summary, detail, tags, repo, sentiment, pr_number, issue_number) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        rusqlite::params![
            now,
            summary,
            detail.unwrap_or(""),
            tags.unwrap_or(""),
            repo.unwrap_or(""),
            sentiment,
            pr_number.unwrap_or(0),
            issue_number.unwrap_or(0),
        ],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Recent episodes, optionally filtered by repo. Order newest first.
pub fn episode_recent(repo_filter: Option<&str>, limit: usize) -> Result<Vec<EpisodeRow>> {
    let conn = open_db()?;
    let limit = limit.min(100);
    let out: Vec<EpisodeRow> = if let Some(repo) = repo_filter.filter(|s| !s.is_empty()) {
        let mut stmt = conn.prepare(
            "SELECT id, happened_at, summary, detail, tags, repo, sentiment, pr_number, issue_number \
             FROM chump_episodes WHERE repo = ?1 ORDER BY id DESC LIMIT ?2",
        )?;
        let rows: Vec<EpisodeRow> = stmt
            .query_map(rusqlite::params![repo, limit], |r| row_from_query(r))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    } else {
        let mut stmt = conn.prepare(
            "SELECT id, happened_at, summary, detail, tags, repo, sentiment, pr_number, issue_number \
             FROM chump_episodes ORDER BY id DESC LIMIT ?1",
        )?;
        let rows: Vec<EpisodeRow> = stmt
            .query_map(rusqlite::params![limit], |r| row_from_query(r))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    Ok(out)
}

/// Search episodes by summary/detail/tags (LIKE %query%).
pub fn episode_search(query: &str, limit: usize) -> Result<Vec<EpisodeRow>> {
    if query.trim().is_empty() {
        return episode_recent(None, limit);
    }
    let conn = open_db()?;
    let limit = limit.min(50);
    let pattern = format!("%{}%", query.trim());
    let mut stmt = conn.prepare(
        "SELECT id, happened_at, summary, detail, tags, repo, sentiment, pr_number, issue_number \
         FROM chump_episodes WHERE summary LIKE ?1 OR detail LIKE ?1 OR tags LIKE ?1 ORDER BY id DESC LIMIT ?2",
    )?;
    let rows = stmt.query_map(rusqlite::params![pattern, limit], |r| row_from_query(r))?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub fn episode_available() -> bool {
    open_db().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn episode_log_recent_search() {
        let dir = std::env::temp_dir().join("chump_episode_db_test");
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let id = episode_log(
            "Fixed login bug",
            Some("Tested locally."),
            Some("auth,bug"),
            Some("owner/repo"),
            Some("win"),
            Some(61),
            Some(52),
        )
        .unwrap();
        assert!(id > 0);

        let recent = episode_recent(None, 5).unwrap();
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].summary, "Fixed login bug");
        assert_eq!(recent[0].sentiment.as_deref(), Some("win"));
        assert_eq!(recent[0].repo.as_deref(), Some("owner/repo"));

        let by_repo = episode_recent(Some("owner/repo"), 5).unwrap();
        assert_eq!(by_repo.len(), 1);

        let found = episode_search("login", 5).unwrap();
        assert_eq!(found.len(), 1);
        assert!(found[0].summary.contains("login"));

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join("sessions/chump_memory.db");
        let _ = std::fs::remove_file(db_file);
    }
}
