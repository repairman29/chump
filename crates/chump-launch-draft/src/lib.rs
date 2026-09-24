//! chump-launch-draft — launch draft data model + persistence.
//!
//! EFFECTIVE-1508 (EFFECTIVE-365 slice): the publisher co-pilot's draft →
//! approve → drive → track workflow (`org/RUN/publication/roles/publisher.md`)
//! starts with a typed draft artifact. This crate owns just that: the
//! `LaunchDraft` model and its SQLite persistence (create/read/update/delete).
//!
//! Storage: caller-supplied SQLite path (production: `.chump/launch_drafts.db`,
//! separate from canonical state.db so this schema can churn independently).

use anyhow::Result;
use rusqlite::{params, Connection, OptionalExtension};

/// Lifecycle status of a launch draft, per the publisher co-pilot's
/// draft → approve → drive → track workflow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchDraftStatus {
    Draft,
    Approved,
    Posted,
    Tracked,
}

impl LaunchDraftStatus {
    fn as_str(self) -> &'static str {
        match self {
            LaunchDraftStatus::Draft => "draft",
            LaunchDraftStatus::Approved => "approved",
            LaunchDraftStatus::Posted => "posted",
            LaunchDraftStatus::Tracked => "tracked",
        }
    }

    fn from_str(s: &str) -> Result<Self> {
        match s {
            "draft" => Ok(LaunchDraftStatus::Draft),
            "approved" => Ok(LaunchDraftStatus::Approved),
            "posted" => Ok(LaunchDraftStatus::Posted),
            "tracked" => Ok(LaunchDraftStatus::Tracked),
            other => Err(anyhow::anyhow!("unknown launch draft status: {other}")),
        }
    }
}

/// A per-platform launch post draft (Show HN, r/webdev, LinkedIn, Substack, ...).
#[derive(Debug, Clone)]
pub struct LaunchDraft {
    pub id: i64,
    pub platform: String,
    pub title: String,
    pub body: String,
    pub status: LaunchDraftStatus,
    pub created_at: i64,
    pub updated_at: i64,
}

/// Open (creating if absent) the launch-draft SQLite DB at `path` and apply
/// the schema. Safe to call repeatedly (idempotent `CREATE TABLE IF NOT EXISTS`).
pub fn open_db(path: &str) -> Result<Connection> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS launch_drafts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            platform    TEXT NOT NULL,
            title       TEXT NOT NULL,
            body        TEXT NOT NULL,
            status      TEXT NOT NULL DEFAULT 'draft',
            created_at  INTEGER NOT NULL,
            updated_at  INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_launch_drafts_status ON launch_drafts(status);
        CREATE INDEX IF NOT EXISTS idx_launch_drafts_platform ON launch_drafts(platform);",
    )?;
    Ok(conn)
}

fn row_to_draft(row: &rusqlite::Row) -> rusqlite::Result<LaunchDraft> {
    let status_raw: String = row.get(4)?;
    Ok(LaunchDraft {
        id: row.get(0)?,
        platform: row.get(1)?,
        title: row.get(2)?,
        body: row.get(3)?,
        status: LaunchDraftStatus::from_str(&status_raw).map_err(|e| {
            rusqlite::Error::InvalidColumnType(4, e.to_string(), rusqlite::types::Type::Text)
        })?,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

/// Create a new launch draft, defaulting `status` to `draft`. Returns the new row id.
pub fn create_draft(
    conn: &Connection,
    platform: &str,
    title: &str,
    body: &str,
    now: i64,
) -> Result<i64> {
    conn.execute(
        "INSERT INTO launch_drafts (platform, title, body, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
        params![
            platform,
            title,
            body,
            LaunchDraftStatus::Draft.as_str(),
            now
        ],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Fetch a single draft by id, or `None` if it doesn't exist.
pub fn get_draft(conn: &Connection, id: i64) -> Result<Option<LaunchDraft>> {
    let draft = conn
        .query_row(
            "SELECT id, platform, title, body, status, created_at, updated_at
             FROM launch_drafts WHERE id = ?1",
            params![id],
            row_to_draft,
        )
        .optional()?;
    Ok(draft)
}

/// List all drafts, most recently created first.
pub fn list_drafts(conn: &Connection) -> Result<Vec<LaunchDraft>> {
    let mut stmt = conn.prepare(
        "SELECT id, platform, title, body, status, created_at, updated_at
         FROM launch_drafts ORDER BY created_at DESC",
    )?;
    let rows = stmt.query_map([], row_to_draft)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Update title/body/status on an existing draft. Returns `false` if no row matched.
pub fn update_draft(
    conn: &Connection,
    id: i64,
    title: &str,
    body: &str,
    status: LaunchDraftStatus,
    now: i64,
) -> Result<bool> {
    let changed = conn.execute(
        "UPDATE launch_drafts SET title = ?1, body = ?2, status = ?3, updated_at = ?4 WHERE id = ?5",
        params![title, body, status.as_str(), now, id],
    )?;
    Ok(changed > 0)
}

/// Delete a draft by id. Returns `false` if no row matched.
pub fn delete_draft(conn: &Connection, id: i64) -> Result<bool> {
    let changed = conn.execute("DELETE FROM launch_drafts WHERE id = ?1", params![id])?;
    Ok(changed > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_db() -> Connection {
        open_db(":memory:").expect("open in-memory launch_drafts db")
    }

    #[test]
    fn create_read_update_delete_roundtrip() {
        let conn = test_db();

        // create
        let id = create_draft(&conn, "hn", "Show HN: Chump", "we built a thing", 1_000).unwrap();
        assert!(id > 0);

        // read
        let fetched = get_draft(&conn, id).unwrap().expect("draft should exist");
        assert_eq!(fetched.platform, "hn");
        assert_eq!(fetched.title, "Show HN: Chump");
        assert_eq!(fetched.body, "we built a thing");
        assert_eq!(fetched.status, LaunchDraftStatus::Draft);
        assert_eq!(fetched.created_at, 1_000);
        assert_eq!(fetched.updated_at, 1_000);

        // update
        let updated = update_draft(
            &conn,
            id,
            "Show HN: Chump v2",
            "we built a better thing",
            LaunchDraftStatus::Approved,
            2_000,
        )
        .unwrap();
        assert!(updated);

        let fetched = get_draft(&conn, id)
            .unwrap()
            .expect("draft should still exist");
        assert_eq!(fetched.title, "Show HN: Chump v2");
        assert_eq!(fetched.body, "we built a better thing");
        assert_eq!(fetched.status, LaunchDraftStatus::Approved);
        assert_eq!(fetched.created_at, 1_000);
        assert_eq!(fetched.updated_at, 2_000);

        // list
        let all = list_drafts(&conn).unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].id, id);

        // delete
        let deleted = delete_draft(&conn, id).unwrap();
        assert!(deleted);
        assert!(get_draft(&conn, id).unwrap().is_none());
        assert!(list_drafts(&conn).unwrap().is_empty());
    }

    #[test]
    fn update_and_delete_missing_row_return_false() {
        let conn = test_db();
        assert!(!update_draft(&conn, 999, "x", "y", LaunchDraftStatus::Posted, 1).unwrap());
        assert!(!delete_draft(&conn, 999).unwrap());
    }

    #[test]
    fn multiple_drafts_ordered_newest_first() {
        let conn = test_db();
        let first = create_draft(&conn, "hn", "First", "body", 100).unwrap();
        let second = create_draft(&conn, "linkedin", "Second", "body", 200).unwrap();

        let all = list_drafts(&conn).unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].id, second);
        assert_eq!(all[1].id, first);
    }
}
