//! Shared SQLite connection pool for chump_memory.db (WAL + busy_timeout).
//! All DB modules (state_db, task_db, episode_db, schedule_db, ask_jeff_db, tool_health_db, memory_db)
//! use this pool instead of opening a new connection per call.

use anyhow::Result;
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use std::path::PathBuf;
use std::sync::OnceLock;

type PooledConn = r2d2::PooledConnection<SqliteConnectionManager>;

static POOL: OnceLock<Pool<SqliteConnectionManager>> = OnceLock::new();

fn chump_memory_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_MEMORY_DB_PATH") {
        return PathBuf::from(p);
    }
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("sessions/chump_memory.db")
}

/// Run all table schemas and migrations for chump_memory.db (shared by all modules).
fn init_schema(conn: &rusqlite::Connection) -> Result<()> {
    conn.execute_batch(
        "
        -- state_db
        CREATE TABLE IF NOT EXISTS chump_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- task_db
        CREATE TABLE IF NOT EXISTS chump_tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            repo TEXT,
            issue_number INTEGER,
            status TEXT DEFAULT 'open',
            notes TEXT,
            priority INTEGER DEFAULT 0,
            created_at TEXT,
            updated_at TEXT
        );
        -- episode_db
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
        -- schedule_db
        CREATE TABLE IF NOT EXISTS chump_scheduled (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fire_at TEXT NOT NULL,
            prompt TEXT NOT NULL,
            context TEXT,
            fired INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_chump_scheduled_fire ON chump_scheduled (fired, fire_at);
        -- ask_jeff_db
        CREATE TABLE IF NOT EXISTS chump_questions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            question TEXT NOT NULL,
            context TEXT,
            priority TEXT DEFAULT 'curious',
            asked_at TEXT DEFAULT (datetime('now')),
            answered_at TEXT,
            answer TEXT
        );
        -- tool_health_db
        CREATE TABLE IF NOT EXISTS chump_tool_health (
            tool TEXT PRIMARY KEY,
            status TEXT DEFAULT 'ok',
            last_error TEXT,
            last_checked TEXT,
            failure_count INTEGER DEFAULT 0
        );
        -- introspect_tool: ring buffer of recent tool invocations (capped at 200 rows)
        CREATE TABLE IF NOT EXISTS chump_tool_calls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tool TEXT NOT NULL,
            args_snippet TEXT,
            outcome TEXT NOT NULL DEFAULT 'ok',
            called_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_chump_tool_calls_called ON chump_tool_calls (called_at DESC);
        -- memory_db
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
        -- web_sessions_db (PWA Tier 2 Phase 1.1)
        CREATE TABLE IF NOT EXISTS chump_web_sessions (
            id TEXT PRIMARY KEY,
            bot TEXT NOT NULL DEFAULT 'chump',
            title TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_web_sessions_updated ON chump_web_sessions(bot, updated_at DESC);
        CREATE TABLE IF NOT EXISTS chump_web_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
            content TEXT NOT NULL,
            tool_calls_json TEXT,
            attachments_json TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_web_messages_session ON chump_web_messages(session_id, created_at);
        -- web_uploads (PWA Tier 2 Phase 1.2)
        CREATE TABLE IF NOT EXISTS chump_web_uploads (
            file_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            filename TEXT NOT NULL,
            mime_type TEXT,
            size_bytes INTEGER NOT NULL,
            storage_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_web_uploads_session ON chump_web_uploads(session_id);
        -- push subscriptions (PWA Tier 2 Phase 3.1)
        CREATE TABLE IF NOT EXISTS chump_push_subscriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            endpoint TEXT NOT NULL UNIQUE,
            p256dh TEXT,
            auth TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        ",
    )?;
    // task_db migrations (add columns if missing)
    let _ = conn.execute("ALTER TABLE chump_tasks ADD COLUMN priority INTEGER DEFAULT 0", []);
    let _ = conn.execute("ALTER TABLE chump_tasks ADD COLUMN assignee TEXT DEFAULT 'chump'", []);
    Ok(())
}

fn init_pool() -> Result<Pool<SqliteConnectionManager>> {
    let path = chump_memory_db_path();
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let manager = SqliteConnectionManager::file(&path)
        .with_init(|c| {
            c.execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;")
        });
    let pool = Pool::new(manager)?;
    let conn = pool.get()?;
    init_schema(&conn)?;
    Ok(pool)
}

/// Return a connection from the shared pool. Initializes the pool (and schema) on first use.
pub fn get() -> Result<PooledConn> {
    let pool = POOL.get_or_init(|| init_pool().expect("chump_memory db pool init"));
    pool.get().map_err(Into::into)
}
