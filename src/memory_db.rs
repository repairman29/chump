//! SQLite-backed memory with FTS5 keyword search. Used when sessions/chump_memory.db exists.
//! Migrates from JSON on first use. Phase 1a of ROADMAP (hybrid memory).

use anyhow::Result;
use rusqlite::Connection;
use std::path::PathBuf;

const DB_FILENAME: &str = "sessions/chump_memory.db";
const JSON_FALLBACK_PATH: &str = "sessions/chump_memory.json";

#[derive(Debug, Clone)]
pub struct MemoryRow {
    pub id: i64,
    pub content: String,
    pub ts: String,
    pub source: String,
}

fn db_path() -> PathBuf {
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(DB_FILENAME)
}

fn json_path() -> PathBuf {
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(JSON_FALLBACK_PATH)
}

fn open_db() -> Result<Connection> {
    let path = db_path();
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let conn = Connection::open(&path)?;
    init_schema(&conn)?;
    Ok(conn)
}

fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS chump_memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            ts TEXT NOT NULL,
            source TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            content,
            content='chump_memory',
            content_rowid='id'
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
    Ok(())
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

/// Returns true if the SQLite backend is available (DB path exists or can be created).
pub fn db_available() -> bool {
    let path = db_path();
    path.parent().is_some_and(|p| {
        if !p.exists() {
            std::fs::create_dir_all(p).is_ok()
        } else {
            true
        }
    })
}

/// Load all rows from DB. Caller should check db_available() first.
pub fn load_all() -> Result<Vec<MemoryRow>> {
    let conn = open_db()?;
    migrate_from_json_if_needed(&conn)?;
    let mut stmt = conn.prepare("SELECT id, content, ts, source FROM chump_memory ORDER BY id")?;
    let rows = stmt.query_map([], |r| {
        Ok(MemoryRow {
            id: r.get(0)?,
            content: r.get(1)?,
            ts: r.get(2)?,
            source: r.get(3)?,
        })
    })?;
    let out: Result<Vec<_>, _> = rows.collect();
    Ok(out?)
}

/// Append one memory entry. Caller should check db_available() first.
pub fn insert_one(content: &str, ts: &str, source: &str) -> Result<()> {
    let conn = open_db()?;
    migrate_from_json_if_needed(&conn)?;
    conn.execute(
        "INSERT INTO chump_memory (content, ts, source) VALUES (?1, ?2, ?3)",
        [content, ts, source],
    )?;
    Ok(())
}

/// Escapes a string for safe use in FTS5 MATCH. Wraps each token in double quotes and
/// escapes internal double quotes by doubling them, so FTS5 treats punctuation and
/// special characters (e.g. ":", "-") as literal.
fn escape_fts5_query(s: &str) -> String {
    let tokens: Vec<String> = s
        .trim()
        .split_whitespace()
        .map(|t| {
            let escaped = t.replace('"', "\"\"");
            format!("\"{}\"", escaped)
        })
        .collect();
    tokens.join(" OR ")
}

/// Keyword search via FTS5. Returns up to `limit` rows, most recent first (by id).
/// If query is empty, returns latest entries.
pub fn keyword_search(query: &str, limit: usize) -> Result<Vec<MemoryRow>> {
    let conn = open_db()?;
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
            })
        })?
        .collect::<Result<Vec<_>, _>>()?
    };
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use std::fs;

    #[test]
    fn test_db_available() {
        assert!(db_available());
    }

    #[test]
    #[serial]
    fn test_insert_and_load() {
        let dir = std::env::temp_dir().join("chump_memory_db_test");
        let _ = fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();
        let db_file = dir.join(DB_FILENAME);
        let _ = fs::remove_file(&db_file);

        let conn = open_db().unwrap();
        init_schema(&conn).unwrap();
        conn.execute(
            "INSERT INTO chump_memory (content, ts, source) VALUES (?1, ?2, ?3)",
            ["test content", "123", "test"],
        )
        .unwrap();

        let all = load_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].content, "test content");

        let found = keyword_search("test", 10).unwrap();
        assert_eq!(found.len(), 1);
        assert!(found[0].content.contains("test"));

        let empty = keyword_search("nonexistent", 10).unwrap();
        assert!(empty.is_empty());

        // FTS5 special chars: no panic; either sensible or empty results
        let _ = keyword_search("foo\"bar", 10).unwrap();
        let _ = keyword_search("key:value", 10).unwrap();
        let _ = keyword_search("word-with-dash", 10).unwrap();

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let _ = fs::remove_file(&db_file);
    }
}
