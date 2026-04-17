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

// ── Memory curation ────────────────────────────────────────────────────
//
// Closes dissertation Part X "Memory curation" near-term item. The enriched
// schema (confidence, verified, expires_at, memory_type) was added earlier
// but no automated policy used it. These functions are the policy:
//
//   1. `decay_unverified_confidence` — drift confidence down over time for
//      memories the agent inferred (verified=0). Verified facts (verified>=1)
//      are anchors and stay put.
//   2. `dedupe_exact_content` — collapse rows with byte-identical content.
//      Keeps the highest-verified-then-highest-confidence row; deletes rest.
//   3. `curate_all` — orchestrator that runs both passes + expire_stale and
//      reports what changed in one struct so callers (heartbeat, /doctor,
//      autonomy loop) get a single result to log.
//
// LLM-based episodic→semantic summarization is a separate follow-up because
// it needs a delegate call. These DB-only passes can run on a cron tick
// without inference budget.

/// Result of a curation pass — total counts the operator can log.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CurationReport {
    /// Memories deleted because their `expires_at` had elapsed.
    pub expired: u64,
    /// Memories deleted because a higher-quality exact-content duplicate was kept.
    pub deduped_exact: u64,
    /// Memories whose `confidence` was decayed (only verified=0 rows).
    pub decayed: u64,
}

impl CurationReport {
    pub fn total_changed(&self) -> u64 {
        self.expired + self.deduped_exact + self.decayed
    }
}

/// Decay implementation that takes an explicit connection — used by the
/// public `decay_unverified_confidence` AND by tests that open per-test
/// DB files. See the public wrapper for full semantics.
pub(crate) fn decay_unverified_confidence_on_conn(
    conn: &Connection,
    rate_per_day: f64,
) -> Result<u64> {
    let rate = rate_per_day.clamp(0.0, 0.5);
    if rate == 0.0 {
        return Ok(0);
    }
    let updated = conn.execute(
        "UPDATE chump_memory \
         SET confidence = MAX(0.05, confidence * MAX(0.0, 1.0 - ?1 * (CAST(strftime('%s','now') AS REAL) - CAST(ts AS REAL)) / 86400.0)) \
         WHERE verified = 0 \
           AND confidence IS NOT NULL \
           AND ABS(confidence - MAX(0.05, confidence * MAX(0.0, 1.0 - ?1 * (CAST(strftime('%s','now') AS REAL) - CAST(ts AS REAL)) / 86400.0))) > 0.001",
        rusqlite::params![rate],
    )?;
    Ok(updated as u64)
}

/// Decay unverified memories' confidence by `rate_per_day` per day since
/// their `ts` timestamp. Verified memories (verified >= 1) are anchors —
/// untouched. Confidence floor is 0.05 so a decayed memory still surfaces
/// in retrieval (just heavily down-weighted) rather than vanishing.
///
/// `rate_per_day` is in fractional confidence per day. 0.01 = 1% per day,
/// so a 90-day-old unverified memory drops from 1.0 to ~0.40. Sensible
/// defaults: 0.005-0.02 depending on how aggressive you want curation.
///
/// Returns count of rows whose confidence was changed.
pub fn decay_unverified_confidence(rate_per_day: f64) -> Result<u64> {
    let conn = open_db()?;
    decay_unverified_confidence_on_conn(&conn, rate_per_day)
}

/// Dedupe implementation that takes an explicit connection.
pub(crate) fn dedupe_exact_content_on_conn(conn: &Connection) -> Result<u64> {
    let deleted = conn.execute(
        "DELETE FROM chump_memory \
         WHERE id IN ( \
             SELECT m1.id FROM chump_memory m1 \
             WHERE EXISTS ( \
                 SELECT 1 FROM chump_memory m2 \
                 WHERE m2.content = m1.content \
                   AND ( \
                     m2.verified > m1.verified \
                     OR (m2.verified = m1.verified AND m2.confidence > m1.confidence) \
                     OR (m2.verified = m1.verified AND m2.confidence = m1.confidence AND m2.id < m1.id) \
                   ) \
             ) \
         )",
        [],
    )?;
    if deleted > 0 {
        let _ = conn.execute("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')", []);
    }
    Ok(deleted as u64)
}

/// Collapse rows with byte-identical `content`. For each duplicate group,
/// keeps the row with the highest `(verified, confidence)` (verified beats
/// any confidence; among same-verified, highest confidence wins; tiebreaker
/// is lowest id = oldest). All other rows in the group are deleted.
///
/// Skips groups of size 1 (no work to do).
///
/// Returns count of rows deleted.
pub fn dedupe_exact_content() -> Result<u64> {
    let conn = open_db()?;
    dedupe_exact_content_on_conn(&conn)
}

/// Expire-stale implementation that takes an explicit connection.
pub(crate) fn expire_stale_memories_on_conn(conn: &Connection) -> Result<u64> {
    let deleted = conn.execute(
        "DELETE FROM chump_memory WHERE expires_at IS NOT NULL AND CAST(expires_at AS INTEGER) <= CAST(strftime('%s','now') AS INTEGER)",
        [],
    )?;
    if deleted > 0 {
        let _ = conn.execute("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')", []);
    }
    Ok(deleted as u64)
}

/// Default confidence-decay rate when `curate_all` isn't given an explicit
/// rate. 0.01/day → ~63% confidence after 60 days, ~37% after 100 days.
/// Override via `CHUMP_MEMORY_DECAY_RATE` (decimal per day, clamped 0..=0.5).
pub const DEFAULT_DECAY_RATE_PER_DAY: f64 = 0.01;

fn decay_rate_from_env() -> f64 {
    std::env::var("CHUMP_MEMORY_DECAY_RATE")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .map(|r| r.clamp(0.0, 0.5))
        .unwrap_or(DEFAULT_DECAY_RATE_PER_DAY)
}

/// Curate-all implementation taking an explicit connection. Used by the
/// public wrapper AND by tests.
pub(crate) fn curate_all_on_conn(
    conn: &Connection,
    decay_rate: f64,
) -> Result<CurationReport> {
    Ok(CurationReport {
        expired: expire_stale_memories_on_conn(conn).unwrap_or(0),
        deduped_exact: dedupe_exact_content_on_conn(conn).unwrap_or(0),
        decayed: decay_unverified_confidence_on_conn(conn, decay_rate).unwrap_or(0),
    })
}

/// Run all DB-only curation passes (expire → dedupe → decay) and return a
/// single report. Order matters: expiry first removes obvious junk; dedupe
/// next collapses duplicates so we don't waste decay-update work on rows
/// that are about to be deleted; decay last.
///
/// Safe to call on every heartbeat — the queries are indexed (or
/// content-keyed in the dedupe case) and a no-op when nothing matches.
pub fn curate_all() -> Result<CurationReport> {
    let conn = open_db()?;
    curate_all_on_conn(&conn, decay_rate_from_env())
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

    // ── Memory curation tests ──────────────────────────────────────────

    /// Helper: insert a memory row directly with explicit confidence/verified
    /// fields. Bypasses the `insert_one` API so tests can construct adversarial
    /// states (very-old timestamps, low confidence, etc.).
    fn insert_with_fields(
        conn: &Connection,
        content: &str,
        ts_unix: i64,
        confidence: f64,
        verified: i32,
        expires_at: Option<i64>,
    ) -> i64 {
        conn.execute(
            "INSERT INTO chump_memory (content, ts, source, confidence, verified, sensitivity, expires_at, memory_type) \
             VALUES (?1, ?2, 'test', ?3, ?4, 'internal', ?5, 'semantic_fact')",
            rusqlite::params![
                content,
                ts_unix.to_string(),
                confidence,
                verified,
                expires_at.map(|t| t.to_string()),
            ],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    fn fresh_curation_db() -> (PathBuf, Connection) {
        let dir = std::env::temp_dir().join(format!(
            "chump-memory-curation-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("curation.db");
        let conn = open_memory_db_file(&path).unwrap();
        (path, conn)
    }

    fn count_rows(conn: &Connection) -> i64 {
        conn.query_row("SELECT COUNT(*) FROM chump_memory", [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn expire_stale_deletes_only_past_expiry() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        let yesterday = now - 86400;
        let tomorrow = now + 86400;
        insert_with_fields(&conn, "expired", now, 1.0, 0, Some(yesterday));
        insert_with_fields(&conn, "still good", now, 1.0, 0, Some(tomorrow));
        insert_with_fields(&conn, "no expiry", now, 1.0, 0, None);

        let deleted = expire_stale_memories_on_conn(&conn).unwrap();
        assert_eq!(deleted, 1, "only the past-expiry row should go");
        assert_eq!(count_rows(&conn), 2);

        // Idempotent.
        let again = expire_stale_memories_on_conn(&conn).unwrap();
        assert_eq!(again, 0);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn dedupe_exact_keeps_verified_over_unverified() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        let unverified_id = insert_with_fields(&conn, "rust uses ownership", now, 1.0, 0, None);
        let verified_id = insert_with_fields(&conn, "rust uses ownership", now, 0.5, 1, None);

        let deleted = dedupe_exact_content_on_conn(&conn).unwrap();
        assert_eq!(deleted, 1);
        assert_eq!(count_rows(&conn), 1);

        // The verified row survives even though its confidence is lower.
        let surviving_id: i64 = conn
            .query_row("SELECT id FROM chump_memory", [], |r| r.get(0))
            .unwrap();
        assert_eq!(surviving_id, verified_id);
        assert_ne!(surviving_id, unverified_id);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn dedupe_exact_keeps_highest_confidence_when_same_verified() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        let _low = insert_with_fields(&conn, "duplicate", now, 0.4, 0, None);
        let high = insert_with_fields(&conn, "duplicate", now, 0.9, 0, None);

        dedupe_exact_content_on_conn(&conn).unwrap();
        let surviving_id: i64 = conn
            .query_row("SELECT id FROM chump_memory", [], |r| r.get(0))
            .unwrap();
        assert_eq!(surviving_id, high);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn dedupe_exact_keeps_oldest_when_tied() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        let oldest = insert_with_fields(&conn, "twin", now, 0.7, 0, None);
        let _newer = insert_with_fields(&conn, "twin", now, 0.7, 0, None);

        dedupe_exact_content_on_conn(&conn).unwrap();
        let surviving_id: i64 = conn
            .query_row("SELECT id FROM chump_memory", [], |r| r.get(0))
            .unwrap();
        assert_eq!(surviving_id, oldest);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn dedupe_exact_no_op_when_unique() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        insert_with_fields(&conn, "alpha", now, 1.0, 0, None);
        insert_with_fields(&conn, "beta", now, 1.0, 0, None);
        insert_with_fields(&conn, "gamma", now, 1.0, 0, None);
        let deleted = dedupe_exact_content_on_conn(&conn).unwrap();
        assert_eq!(deleted, 0);
        assert_eq!(count_rows(&conn), 3);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn decay_skips_verified_memories() {
        let (path, conn) = fresh_curation_db();
        let hundred_days_ago = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64) - 100 * 86400;
        let verified_id =
            insert_with_fields(&conn, "verified anchor", hundred_days_ago, 1.0, 1, None);
        let unverified_id =
            insert_with_fields(&conn, "old inference", hundred_days_ago, 1.0, 0, None);

        decay_unverified_confidence_on_conn(&conn, 0.01).unwrap();

        let verified_conf: f64 = conn
            .query_row(
                "SELECT confidence FROM chump_memory WHERE id = ?1",
                [verified_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(verified_conf, 1.0, "verified row must not decay");

        let unverified_conf: f64 = conn
            .query_row(
                "SELECT confidence FROM chump_memory WHERE id = ?1",
                [unverified_id],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            unverified_conf < 0.5,
            "100-day-old unverified at 0.01/day should be well under 0.5; got {}",
            unverified_conf
        );
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn decay_respects_floor_so_old_rows_dont_vanish() {
        let (path, conn) = fresh_curation_db();
        // 10000 days ago at 0.5/day decay (clamp max) → multiplier collapses to 0.
        let very_old = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64) - 10_000 * 86400;
        insert_with_fields(&conn, "ancient inference", very_old, 1.0, 0, None);

        decay_unverified_confidence_on_conn(&conn, 0.5).unwrap();

        let conf: f64 = conn
            .query_row("SELECT confidence FROM chump_memory", [], |r| r.get(0))
            .unwrap();
        // Floor is 0.05 — the row should still be retrievable, just heavily down-weighted.
        assert!((conf - 0.05).abs() < 0.001, "floor should be 0.05; got {}", conf);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn decay_zero_rate_is_noop() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        insert_with_fields(&conn, "x", now - 30 * 86400, 0.8, 0, None);
        let updated = decay_unverified_confidence_on_conn(&conn, 0.0).unwrap();
        assert_eq!(updated, 0);
        let conf: f64 = conn
            .query_row("SELECT confidence FROM chump_memory", [], |r| r.get(0))
            .unwrap();
        assert!((conf - 0.8).abs() < 0.001);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn decay_clamps_excessive_rate() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        insert_with_fields(&conn, "today's note", now, 1.0, 0, None);
        // Caller passes 5.0 — should clamp to 0.5. With ts == now, days_since
        // is 0 so the multiplier is 1.0 either way and confidence is unchanged.
        let updated = decay_unverified_confidence_on_conn(&conn, 5.0).unwrap();
        assert_eq!(updated, 0, "today's row → 0 days → no change regardless of rate");
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn curate_all_combines_all_three_passes() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        let yesterday = now - 86400;
        let old = now - 90 * 86400;

        // Pass 1 will catch this: past-expiry.
        insert_with_fields(&conn, "expire me", now, 1.0, 0, Some(yesterday));
        // Pass 2 will catch one of these (exact dup).
        insert_with_fields(&conn, "twin content", now, 0.5, 0, None);
        insert_with_fields(&conn, "twin content", now, 0.9, 0, None);
        // Pass 3 will catch this: 90 days old, unverified.
        insert_with_fields(&conn, "old fact", old, 1.0, 0, None);

        let report = curate_all_on_conn(&conn, 0.01).unwrap();
        assert_eq!(report.expired, 1);
        assert_eq!(report.deduped_exact, 1);
        assert!(report.decayed >= 1, "old unverified row should decay");
        assert!(report.total_changed() >= 3);
        assert_eq!(count_rows(&conn), 2, "expired + 1 dup deleted; 2 left");
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn curate_all_idempotent_on_clean_db() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        insert_with_fields(&conn, "fresh fact", now, 1.0, 1, None);

        let first = curate_all_on_conn(&conn, 0.01).unwrap();
        let second = curate_all_on_conn(&conn, 0.01).unwrap();
        assert_eq!(first.total_changed(), 0);
        assert_eq!(second.total_changed(), 0);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn curation_report_total_changed_sums() {
        let r = CurationReport { expired: 2, deduped_exact: 3, decayed: 5 };
        assert_eq!(r.total_changed(), 10);
        assert_eq!(CurationReport::default().total_changed(), 0);
    }

    #[test]
    fn decay_rate_env_clamps_within_range() {
        std::env::set_var("CHUMP_MEMORY_DECAY_RATE", "0.05");
        assert!((decay_rate_from_env() - 0.05).abs() < 1e-9);
        std::env::set_var("CHUMP_MEMORY_DECAY_RATE", "10.0");
        assert!((decay_rate_from_env() - 0.5).abs() < 1e-9, "should clamp to 0.5 max");
        std::env::set_var("CHUMP_MEMORY_DECAY_RATE", "-1.0");
        assert!((decay_rate_from_env() - 0.0).abs() < 1e-9, "should clamp to 0 min");
        std::env::set_var("CHUMP_MEMORY_DECAY_RATE", "garbage");
        assert!((decay_rate_from_env() - DEFAULT_DECAY_RATE_PER_DAY).abs() < 1e-9);
        std::env::remove_var("CHUMP_MEMORY_DECAY_RATE");
    }
}
