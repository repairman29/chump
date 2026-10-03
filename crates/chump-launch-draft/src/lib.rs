//! chump-launch-draft — persisted model for launch drafts (EFFECTIVE-365
//! slice, EFFECTIVE-1508).
//!
//! This crate defines only the storage schema + a thin CRUD surface for
//! launch drafts: staged outbound copy (platform + title + body) on its way
//! to publication. The authoring/approval/publish pipeline is out of scope
//! here — see EFFECTIVE-365.

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use std::fs;
use std::path::{Path, PathBuf};

/// A single launch draft row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchDraft {
    pub id: i64,
    pub platform: String,
    pub title: String,
    pub body: String,
    pub status: String,
    pub created_at: String,
    pub updated_at: String,
}

/// Resolve the repo root. Prefers CHUMP_REPO_ROOT (test override), then the
/// current dir.
pub fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        let p = PathBuf::from(r);
        if p.is_dir() {
            return p;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Resolve the launch-drafts DB path. Defaults to `<repo>/.chump/launch_drafts.db`.
/// Override via CHUMP_LAUNCH_DRAFT_DB for tests.
pub fn launch_draft_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_LAUNCH_DRAFT_DB") {
        return PathBuf::from(p);
    }
    repo_root().join(".chump/launch_drafts.db")
}

/// Resolve the migration SQL path. CHUMP_LAUNCH_DRAFT_MIGRATION lets tests
/// point at an isolated fixture; default is repo_root/migrations/launch_drafts_v1.sql.
fn migration_sql_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_LAUNCH_DRAFT_MIGRATION") {
        return PathBuf::from(p);
    }
    repo_root().join("migrations/launch_drafts_v1.sql")
}

/// Open (and lazily initialize) the launch-drafts DB. Applies the v1 schema
/// idempotently every open — every CREATE statement is `IF NOT EXISTS`.
pub fn open_db() -> Result<Connection> {
    open_db_at(&launch_draft_db_path(), &migration_sql_path())
}

/// Explicit-path variant — bypasses env-var resolution. Used by tests and
/// callers that need isolation from CHUMP_LAUNCH_DRAFT_DB.
pub fn open_db_at(db_path: &Path, schema_path: &Path) -> Result<Connection> {
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating parent dir for {}", db_path.display()))?;
    }
    let conn = Connection::open(db_path)
        .with_context(|| format!("opening launch-drafts DB at {}", db_path.display()))?;
    let sql = fs::read_to_string(schema_path)
        .with_context(|| format!("reading launch-drafts schema at {}", schema_path.display()))?;
    conn.execute_batch(&sql)
        .with_context(|| "applying launch-drafts schema")?;
    Ok(conn)
}

fn row_to_draft(row: &rusqlite::Row) -> rusqlite::Result<LaunchDraft> {
    Ok(LaunchDraft {
        id: row.get(0)?,
        platform: row.get(1)?,
        title: row.get(2)?,
        body: row.get(3)?,
        status: row.get(4)?,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

const SELECT_COLUMNS: &str = "id, platform, title, body, status, created_at, updated_at";

/// Create a launch draft for a platform. Status defaults to 'draft'.
pub fn create_draft(conn: &Connection, platform: &str, title: &str, body: &str) -> Result<i64> {
    conn.execute(
        "INSERT INTO launch_drafts (platform, title, body) VALUES (?1, ?2, ?3)",
        params![platform, title, body],
    )
    .context("inserting launch draft")?;
    Ok(conn.last_insert_rowid())
}

/// Read a single launch draft by id.
pub fn get_draft(conn: &Connection, id: i64) -> Result<Option<LaunchDraft>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {SELECT_COLUMNS} FROM launch_drafts WHERE id = ?1"
    ))?;
    let mut rows = stmt.query_map(params![id], row_to_draft)?;
    match rows.next() {
        Some(row) => Ok(Some(row?)),
        None => Ok(None),
    }
}

/// List launch drafts by platform, newest first by id.
pub fn list_by_platform(conn: &Connection, platform: &str) -> Result<Vec<LaunchDraft>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {SELECT_COLUMNS} FROM launch_drafts WHERE platform = ?1 ORDER BY id"
    ))?;
    let rows = stmt
        .query_map(params![platform], row_to_draft)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Update a launch draft's title/body/status. Pass the current value for
/// any field that should stay unchanged. Bumps `updated_at`. Returns
/// `false` if no row with that id exists.
pub fn update_draft(
    conn: &Connection,
    id: i64,
    title: &str,
    body: &str,
    status: &str,
) -> Result<bool> {
    let changed = conn
        .execute(
            "UPDATE launch_drafts
             SET title = ?2, body = ?3, status = ?4,
                 updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
             WHERE id = ?1",
            params![id, title, body, status],
        )
        .context("updating launch draft")?;
    Ok(changed > 0)
}

/// Delete a launch draft by id. Returns `false` if no row with that id
/// existed.
pub fn delete_draft(conn: &Connection, id: i64) -> Result<bool> {
    let changed = conn
        .execute("DELETE FROM launch_drafts WHERE id = ?1", params![id])
        .context("deleting launch draft")?;
    Ok(changed > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn migration_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("migrations")
            .join("launch_drafts_v1.sql")
    }

    #[test]
    fn schema_applies_cleanly_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("launch_drafts.db");
        let conn = open_db_at(&db_path, &migration_path()).unwrap();
        // Re-applying the schema on an already-initialized DB must not error.
        let sql = fs::read_to_string(migration_path()).unwrap();
        conn.execute_batch(&sql).unwrap();

        // Re-opening (simulating a fresh process, e.g. staging) must also work.
        drop(conn);
        let conn2 = open_db_at(&db_path, &migration_path()).unwrap();
        conn2
            .execute("SELECT 1 FROM launch_drafts LIMIT 0", [])
            .unwrap();
    }

    #[test]
    fn indexes_exist_for_platform_and_status() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("launch_drafts.db");
        let conn = open_db_at(&db_path, &migration_path()).unwrap();

        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'launch_drafts'")
            .unwrap();
        let names: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();

        assert!(names.contains(&"launch_drafts_platform_idx".to_string()));
        assert!(names.contains(&"launch_drafts_status_idx".to_string()));
    }

    #[test]
    fn create_read_update_delete_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("launch_drafts.db");
        let conn = open_db_at(&db_path, &migration_path()).unwrap();

        // Create
        let id = create_draft(&conn, "substack", "Ribbon cut", "We shipped it.").unwrap();
        assert!(id > 0);

        // Read
        let draft = get_draft(&conn, id).unwrap().expect("draft should exist");
        assert_eq!(draft.platform, "substack");
        assert_eq!(draft.title, "Ribbon cut");
        assert_eq!(draft.body, "We shipped it.");
        assert_eq!(draft.status, "draft");
        assert!(!draft.created_at.is_empty());
        assert_eq!(draft.created_at, draft.updated_at);

        let by_platform = list_by_platform(&conn, "substack").unwrap();
        assert_eq!(by_platform.len(), 1);
        assert_eq!(by_platform[0].id, id);

        let none = list_by_platform(&conn, "twitter").unwrap();
        assert!(none.is_empty());

        // Update
        let updated =
            update_draft(&conn, id, "Ribbon cut!", "We shipped it well.", "approved").unwrap();
        assert!(updated);
        let draft = get_draft(&conn, id).unwrap().unwrap();
        assert_eq!(draft.title, "Ribbon cut!");
        assert_eq!(draft.body, "We shipped it well.");
        assert_eq!(draft.status, "approved");

        let missing_update = update_draft(&conn, id + 999, "x", "y", "draft").unwrap();
        assert!(!missing_update);

        // Delete
        let deleted = delete_draft(&conn, id).unwrap();
        assert!(deleted);
        assert!(get_draft(&conn, id).unwrap().is_none());

        let missing_delete = delete_draft(&conn, id).unwrap();
        assert!(!missing_delete);
    }
}
