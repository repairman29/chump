//! SQLite-backed memory with FTS5 keyword search. Used when sessions/chump_memory.db exists.
//! Migrates from JSON on first use. Phase 1a of ROADMAP (hybrid memory).

use anyhow::Result;
use rusqlite::Connection;
use std::path::PathBuf;

#[allow(dead_code)]
const DB_FILENAME: &str = "sessions/chump_memory.db";
const JSON_FALLBACK_PATH: &str = "sessions/chump_memory.json";

#[derive(Debug, Clone)]
pub struct MemoryRow {
    pub id: i64,
    pub content: String,
    pub ts: String,
    pub source: String,
    pub confidence: f64,
    pub verified: i32,
    pub sensitivity: String,
    pub expires_at: Option<String>,
    pub memory_type: String,
}

/// Optional enrichment fields for memory insertion.
#[derive(Debug, Clone, Default)]
pub struct MemoryEnrichment {
    pub confidence: Option<f64>,
    pub verified: Option<i32>,
    pub sensitivity: Option<String>,
    pub expires_at: Option<String>,
    pub memory_type: Option<String>,
}

/// Helper to build a MemoryRow from a rusqlite::Row, tolerating missing columns on old DBs.
fn row_to_memory(r: &rusqlite::Row<'_>) -> rusqlite::Result<MemoryRow> {
    Ok(MemoryRow {
        id: r.get(0)?,
        content: r.get(1)?,
        ts: r.get(2)?,
        source: r.get(3)?,
        confidence: r.get::<_, f64>(4).unwrap_or(1.0),
        verified: r.get::<_, i32>(5).unwrap_or(0),
        sensitivity: r.get::<_, String>(6).unwrap_or_else(|_| "internal".into()),
        expires_at: r.get::<_, Option<String>>(7).unwrap_or(None),
        memory_type: r
            .get::<_, String>(8)
            .unwrap_or_else(|_| "semantic_fact".into()),
    })
}

fn json_path() -> PathBuf {
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(JSON_FALLBACK_PATH)
}

#[cfg(not(test))]
fn open_db() -> Result<r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>> {
    crate::db_pool::get()
}

#[cfg(test)]
fn open_db() -> Result<rusqlite::Connection> {
    let path = std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(DB_FILENAME);
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let conn = rusqlite::Connection::open(&path)?;
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS chump_memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL, ts TEXT NOT NULL, source TEXT NOT NULL,
            confidence REAL DEFAULT 1.0,
            verified INTEGER DEFAULT 0,
            sensitivity TEXT DEFAULT 'internal',
            expires_at TEXT,
            memory_type TEXT DEFAULT 'semantic_fact'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            content, content='chump_memory', content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON chump_memory BEGIN
            INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_fts_delete AFTER DELETE ON chump_memory BEGIN
            INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_fts_update AFTER UPDATE ON chump_memory BEGIN
            INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
            INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
        END;
        ",
    )?;
    Ok(conn)
}

/// Migrate existing JSON entries into the DB if JSON exists and DB is empty.
fn migrate_from_json_if_needed(conn: &Connection) -> Result<()> {
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM chump_memory", [], |r| r.get(0))?;
    if count > 0 {
        return Ok(());
    }
    let path = json_path();
    if !path.exists() {
        return Ok(());
    }
    let s = std::fs::read_to_string(&path)?;
    let entries: Vec<JsonEntry> = serde_json::from_str(&s).unwrap_or_default();
    for e in entries {
        conn.execute(
            "INSERT INTO chump_memory (content, ts, source) VALUES (?1, ?2, ?3)",
            [&e.content, &e.ts, &e.source],
        )?;
    }
    // Rebuild FTS from main table (triggers don't fire for bulk insert in some setups)
    conn.execute("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')", [])?;
    Ok(())
}

#[derive(serde::Deserialize)]
struct JsonEntry {
    content: String,
    ts: String,
    source: String,
}

/// Returns true if the SQLite backend is available (pool or direct path can serve a connection).
pub fn db_available() -> bool {
    #[cfg(not(test))]
    return crate::db_pool::get().is_ok();
    #[cfg(test)]
    open_db().is_ok()
}

/// Load all non-expired rows from DB. Caller should check db_available() first.
pub fn load_all() -> Result<Vec<MemoryRow>> {
    let conn = open_db()?;
    migrate_from_json_if_needed(&conn)?;
    let mut stmt = conn.prepare(
        "SELECT id, content, ts, source, confidence, verified, sensitivity, expires_at, memory_type \
         FROM chump_memory \
         WHERE (expires_at IS NULL OR CAST(expires_at AS INTEGER) > CAST(strftime('%s','now') AS INTEGER)) \
         ORDER BY id",
    )?;
    let rows = stmt.query_map([], row_to_memory)?;
    let out: Result<Vec<_>, _> = rows.collect();
    Ok(out?)
}

/// Append one memory entry with optional enrichment fields.
/// Caller should check db_available() first.
pub fn insert_one(
    content: &str,
    ts: &str,
    source: &str,
    enrichment: Option<&MemoryEnrichment>,
) -> Result<()> {
    let conn = open_db()?;
    migrate_from_json_if_needed(&conn)?;
    let e = enrichment.cloned().unwrap_or_default();
    conn.execute(
        "INSERT INTO chump_memory (content, ts, source, confidence, verified, sensitivity, expires_at, memory_type) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        rusqlite::params![
            content,
            ts,
            source,
            e.confidence.unwrap_or(1.0),
            e.verified.unwrap_or(0),
            e.sensitivity.as_deref().unwrap_or("internal"),
            e.expires_at,
            e.memory_type.as_deref().unwrap_or("semantic_fact"),
        ],
    )?;
    Ok(())
}

/// Load a map of memory id → confidence for RRF weighting.
pub fn load_id_confidence_map() -> Result<std::collections::HashMap<i64, f64>> {
    let conn = open_db()?;
    let mut stmt =
        conn.prepare("SELECT id, confidence FROM chump_memory WHERE confidence IS NOT NULL")?;
    let rows = stmt.query_map([], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1).unwrap_or(1.0)))
    })?;
    let map: std::collections::HashMap<i64, f64> = rows.filter_map(|r| r.ok()).collect();
    Ok(map)
}

/// Delete memories past their expiry. Returns count of deleted rows.
pub fn expire_stale_memories() -> Result<u64> {
    let conn = open_db()?;
    let deleted = conn.execute(
        "DELETE FROM chump_memory WHERE expires_at IS NOT NULL AND CAST(expires_at AS INTEGER) <= CAST(strftime('%s','now') AS INTEGER)",
        [],
    )?;
    if deleted > 0 {
        let _ = conn.execute("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')", []);
    }
    Ok(deleted as u64)
}

/// Escapes a string for safe use in FTS5 MATCH. Wraps each token in double quotes and
/// escapes internal double quotes by doubling them, so FTS5 treats punctuation and
/// special characters (e.g. ":", "-") as literal.
fn escape_fts5_query(s: &str) -> String {
    let tokens: Vec<String> = s
        .split_whitespace()
        .map(|t| {
            let escaped = t.replace('"', "\"\"");
            format!("\"{}\"", escaped)
        })
        .collect();
    tokens.join(" OR ")
}

/// Keyword search via FTS5. Returns up to `limit` non-expired rows, most recent first (by id).
/// If query is empty, returns latest entries.
pub fn keyword_search(query: &str, limit: usize) -> Result<Vec<MemoryRow>> {
    let conn = open_db()?;
    migrate_from_json_if_needed(&conn)?;
    let limit = limit.min(100);
    let pattern = escape_fts5_query(query);
    let expiry_filter = "AND (m.expires_at IS NULL OR CAST(m.expires_at AS INTEGER) > CAST(strftime('%s','now') AS INTEGER))";
    let out: Vec<MemoryRow> = if pattern.is_empty() {
        let sql = format!(
            "SELECT id, content, ts, source, confidence, verified, sensitivity, expires_at, memory_type \
             FROM chump_memory m WHERE 1=1 {} ORDER BY id DESC LIMIT ?1",
            expiry_filter,
        );
        conn.prepare(&sql)?
            .query_map([limit], row_to_memory)?
            .collect::<Result<Vec<_>, _>>()?
    } else {
        let sql = format!(
            "SELECT m.id, m.content, m.ts, m.source, m.confidence, m.verified, m.sensitivity, m.expires_at, m.memory_type \
             FROM chump_memory m \
             INNER JOIN memory_fts f ON f.rowid = m.id \
             WHERE memory_fts MATCH ?1 {} \
             ORDER BY m.id DESC \
             LIMIT ?2",
            expiry_filter,
        );
        conn.prepare(&sql)?
            .query_map(rusqlite::params![pattern, limit], row_to_memory)?
            .collect::<Result<Vec<_>, _>>()?
    };
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;

    /// Open `chump_memory.db` at an explicit path (no cwd).
    fn open_memory_db_file(db_file: &Path) -> rusqlite::Result<Connection> {
        if let Some(p) = db_file.parent() {
            let _ = fs::create_dir_all(p);
        }
        let conn = Connection::open(db_file)?;
        conn.execute_batch(
            "
        CREATE TABLE IF NOT EXISTS chump_memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL, ts TEXT NOT NULL, source TEXT NOT NULL,
            confidence REAL DEFAULT 1.0,
            verified INTEGER DEFAULT 0,
            sensitivity TEXT DEFAULT 'internal',
            expires_at TEXT,
            memory_type TEXT DEFAULT 'semantic_fact'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            content, content='chump_memory', content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON chump_memory BEGIN
            INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_fts_delete AFTER DELETE ON chump_memory BEGIN
            INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_fts_update AFTER UPDATE ON chump_memory BEGIN
            INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
            INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
        END;
        ",
        )?;
        Ok(conn)
    }

    #[test]
    fn test_db_available() {
        let dir = std::env::temp_dir().join("chump_memory_db_available_test");
        let _ = fs::create_dir_all(&dir);
        let db_file = dir.join(DB_FILENAME);
        let _ = fs::remove_file(&db_file);
        assert!(open_memory_db_file(&db_file).is_ok());
    }

    #[test]
    fn test_insert_and_load() {
        let dir = std::env::temp_dir().join("chump_memory_db_test");
        let _ = fs::create_dir_all(&dir);
        let db_file = dir.join(DB_FILENAME);
        let _ = fs::remove_file(&db_file);

        {
            let conn = open_memory_db_file(&db_file).unwrap();
            conn.execute(
                "INSERT INTO chump_memory (content, ts, source) VALUES (?1, ?2, ?3)",
                ["test content", "123", "test"],
            )
            .unwrap();
        }

        let all = {
            let conn = open_memory_db_file(&db_file).unwrap();
            migrate_from_json_if_needed(&conn).unwrap();
            let mut stmt = conn
                .prepare("SELECT id, content, ts, source FROM chump_memory ORDER BY id")
                .unwrap();
            let rows = stmt
                .query_map([], |r| {
                    Ok(MemoryRow {
                        id: r.get(0)?,
                        content: r.get(1)?,
                        ts: r.get(2)?,
                        source: r.get(3)?,
                        confidence: 1.0,
                        verified: 0,
                        sensitivity: "internal".into(),
                        expires_at: None,
                        memory_type: "semantic_fact".into(),
                    })
                })
                .unwrap();
            rows.collect::<Result<Vec<_>, _>>().unwrap()
        };
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].content, "test content");

        fn kw_at_path(db_file: &Path, query: &str, limit: usize) -> anyhow::Result<Vec<MemoryRow>> {
            let conn = open_memory_db_file(db_file)?;
            migrate_from_json_if_needed(&conn)?;
            let limit = limit.min(100);
            let pattern = escape_fts5_query(query);
            let out: Vec<MemoryRow> = if pattern.is_empty() {
                conn.prepare(
                    "SELECT id, content, ts, source FROM chump_memory ORDER BY id DESC LIMIT ?1",
                )?
                .query_map([limit], |r| {
                    Ok(MemoryRow {
                        id: r.get(0)?,
                        content: r.get(1)?,
                        ts: r.get(2)?,
                        source: r.get(3)?,
                        confidence: 1.0,
                        verified: 0,
                        sensitivity: "internal".into(),
                        expires_at: None,
                        memory_type: "semantic_fact".into(),
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?
            } else {
                conn.prepare(
                    "
            SELECT m.id, m.content, m.ts, m.source
            FROM chump_memory m
            INNER JOIN memory_fts f ON f.rowid = m.id
            WHERE memory_fts MATCH ?1
            ORDER BY m.id DESC
            LIMIT ?2
            ",
                )?
                .query_map(rusqlite::params![pattern, limit], |r| {
                    Ok(MemoryRow {
                        id: r.get(0)?,
                        content: r.get(1)?,
                        ts: r.get(2)?,
                        source: r.get(3)?,
                        confidence: 1.0,
                        verified: 0,
                        sensitivity: "internal".into(),
                        expires_at: None,
                        memory_type: "semantic_fact".into(),
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?
            };
            Ok(out)
        }

        let found = kw_at_path(&db_file, "test", 10).unwrap();
        assert_eq!(found.len(), 1);
        assert!(found[0].content.contains("test"));

        let empty = kw_at_path(&db_file, "nonexistent", 10).unwrap();
        assert!(empty.is_empty());

        let _ = kw_at_path(&db_file, "foo\"bar", 10).unwrap();
        let _ = kw_at_path(&db_file, "key:value", 10).unwrap();
        let _ = kw_at_path(&db_file, "word-with-dash", 10).unwrap();

        let _ = fs::remove_file(&db_file);
    }
}
