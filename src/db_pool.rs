//! Shared SQLite connection pool for chump_memory.db (WAL + busy_timeout).
//! Intended for 24/7 concurrent access: heartbeats, Discord, and web API share the pool
//! to avoid database locks. All DB modules use this pool instead of opening a connection per call.

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
        -- repo allowlist (Phase 2c): dynamic authorize/deauthorize in addition to CHUMP_GITHUB_REPOS
        CREATE TABLE IF NOT EXISTS chump_authorized_repos (
            repo TEXT PRIMARY KEY,
            added_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- provider_quality (Phase 3a/5c): per-slot success/sanity_fail, latency (EMA), tool_call_accuracy
        CREATE TABLE IF NOT EXISTS chump_provider_quality (
            slot_name TEXT PRIMARY KEY,
            success_count INTEGER NOT NULL DEFAULT 0,
            sanity_fail_count INTEGER NOT NULL DEFAULT 0,
            last_updated TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- push subscriptions (PWA Tier 2 Phase 3.1)
        CREATE TABLE IF NOT EXISTS chump_push_subscriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            endpoint TEXT NOT NULL UNIQUE,
            p256dh TEXT,
            auth TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- prediction_log (Synthetic Consciousness Phase 1: surprise tracking)
        CREATE TABLE IF NOT EXISTS chump_prediction_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tool TEXT NOT NULL,
            outcome TEXT NOT NULL,
            latency_ms INTEGER NOT NULL DEFAULT 0,
            surprisal REAL NOT NULL DEFAULT 0.0,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_prediction_log_tool ON chump_prediction_log (tool, recorded_at DESC);
        -- memory_graph (Synthetic Consciousness Phase 2: associative memory)
        CREATE TABLE IF NOT EXISTS chump_memory_graph (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            subject TEXT NOT NULL,
            relation TEXT NOT NULL,
            object TEXT NOT NULL,
            source_memory_id INTEGER,
            source_episode_id INTEGER,
            weight REAL NOT NULL DEFAULT 1.0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_memory_graph_subject ON chump_memory_graph (subject);
        CREATE INDEX IF NOT EXISTS idx_memory_graph_object ON chump_memory_graph (object);
        -- causal_lessons (Synthetic Consciousness Phase 4: counterfactual reasoning)
        CREATE TABLE IF NOT EXISTS chump_causal_lessons (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_type TEXT,
            action_taken TEXT NOT NULL,
            alternative TEXT,
            lesson TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.5,
            times_applied INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_causal_lessons_type ON chump_causal_lessons (task_type);
        -- blackboard_persist (Synthetic Consciousness: cross-session blackboard continuity)
        CREATE TABLE IF NOT EXISTS chump_blackboard_persist (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            content TEXT NOT NULL,
            salience REAL NOT NULL DEFAULT 0.0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_bb_persist_salience ON chump_blackboard_persist (salience DESC);
        -- consciousness_metrics (per-session phi/surprisal for correlation tracking)
        CREATE TABLE IF NOT EXISTS chump_consciousness_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            phi_proxy REAL NOT NULL DEFAULT 0.0,
            surprisal_ema REAL NOT NULL DEFAULT 0.0,
            coupling_score REAL NOT NULL DEFAULT 0.0,
            regime TEXT,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS chump_turn_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            turn_number INTEGER NOT NULL DEFAULT 0,
            tool_calls INTEGER NOT NULL DEFAULT 0,
            tokens_spent INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            regime TEXT,
            surprisal_ema REAL NOT NULL DEFAULT 0.0,
            dissipation_rate REAL NOT NULL DEFAULT 0.0,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_turn_metrics_session ON chump_turn_metrics (session_id);
        -- Vector 3: automated battle / benchmark baselines (telemetry snapshots)
        CREATE TABLE IF NOT EXISTS chump_battle_baselines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL DEFAULT (datetime('now')),
            label TEXT NOT NULL,
            turns_to_resolution INTEGER NOT NULL DEFAULT 0,
            total_tool_errors INTEGER NOT NULL DEFAULT 0,
            resolution_duration_ms INTEGER NOT NULL DEFAULT 0,
            reply_contains_done INTEGER NOT NULL DEFAULT 0,
            extra_json TEXT
        );
        -- async job log (P2.2): autonomy runs, future server-triggered work
        CREATE TABLE IF NOT EXISTS chump_async_jobs (
            id TEXT PRIMARY KEY,
            job_type TEXT NOT NULL,
            status TEXT NOT NULL,
            task_id INTEGER,
            session_id TEXT,
            last_error TEXT,
            detail TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_async_jobs_updated ON chump_async_jobs (updated_at DESC);
        ",
    )?;
    // provider_quality Phase 5c: latency and tool_call_accuracy columns
    let _ = conn.execute(
        "ALTER TABLE chump_provider_quality ADD COLUMN latency_ms_p50 REAL DEFAULT NULL",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_provider_quality ADD COLUMN latency_ms_p95 REAL DEFAULT NULL",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_provider_quality ADD COLUMN tool_call_accuracy REAL DEFAULT NULL",
        [],
    );
    // task_db migrations (add columns if missing)
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN priority INTEGER DEFAULT 0",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN assignee TEXT DEFAULT 'chump'",
        [],
    );
    // episode_db Phase 4: counterfactual reasoning columns
    let _ = conn.execute(
        "ALTER TABLE chump_episodes ADD COLUMN action_taken TEXT",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_episodes ADD COLUMN alternatives_considered TEXT",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_episodes ADD COLUMN counterfactual_analysis TEXT",
        [],
    );
    // TaskPlanner: ordered steps within a plan group (Vector 2 state machine).
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN planner_group_id TEXT",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN planner_step INTEGER DEFAULT 0",
        [],
    );
    // Task dependency DAGs: JSON array of task IDs, e.g. "[3, 5]"
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN depends_on TEXT DEFAULT '[]'",
        [],
    );
    // Session-level analytics (G7)
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chump_session_metrics (
            session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL DEFAULT 0,
            tool_calls INTEGER NOT NULL DEFAULT 0,
            narration_count INTEGER NOT NULL DEFAULT 0,
            latency_ms INTEGER NOT NULL DEFAULT 0,
            satisfaction INTEGER DEFAULT NULL,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (session_id, turn_index)
        );
        CREATE INDEX IF NOT EXISTS idx_session_metrics_time ON chump_session_metrics(recorded_at DESC);
        ",
    )?;
    // Message-level feedback (thumbs up/down)
    let _ = conn.execute(
        "ALTER TABLE chump_web_messages ADD COLUMN feedback INTEGER DEFAULT NULL",
        [],
    );
    // Web chat: optional model `<thinking>` monologue for this assistant message (not shown in default UI).
    let _ = conn.execute(
        "ALTER TABLE chump_web_messages ADD COLUMN thinking_monologue TEXT",
        [],
    );
    // Web chat: user feedback on messages (-1 = thumbs down, 0 = neutral, 1 = thumbs up).
    let _ = conn.execute(
        "ALTER TABLE chump_web_messages ADD COLUMN feedback INTEGER DEFAULT 0",
        [],
    );
    // Session metrics for G7 analytics dashboard.
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS chump_session_metrics (
            session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL,
            tool_calls INTEGER NOT NULL DEFAULT 0,
            narration_count INTEGER NOT NULL DEFAULT 0,
            latency_ms INTEGER NOT NULL DEFAULT 0,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (session_id, turn_index)
        );
        CREATE INDEX IF NOT EXISTS idx_session_metrics_session ON chump_session_metrics(session_id);
        ",
    )
    .ok();
    // FTS5 over web chat messages for verbatim context retrieval (replaces LLM summarization of middle turns).
    conn.execute_batch(
        "
        CREATE VIRTUAL TABLE IF NOT EXISTS web_messages_fts USING fts5(
            content,
            content='chump_web_messages',
            content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_ai AFTER INSERT ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_ad AFTER DELETE ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(web_messages_fts, rowid, content) VALUES('delete', old.id, old.content);
        END;
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_au AFTER UPDATE ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(web_messages_fts, rowid, content) VALUES('delete', old.id, old.content);
            INSERT INTO web_messages_fts(rowid, content) VALUES (new.id, new.content);
        END;
        ",
    )?;
    sync_web_messages_fts(conn)?;
    Ok(())
}

/// Rebuild FTS shadow index if it is behind `chump_web_messages` (e.g. DB existed before FTS).
fn sync_web_messages_fts(conn: &rusqlite::Connection) -> Result<()> {
    let fts_ok: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='web_messages_fts'",
        [],
        |r| r.get(0),
    )?;
    if fts_ok == 0 {
        return Ok(());
    }
    let rows: i64 = conn.query_row("SELECT COUNT(*) FROM chump_web_messages", [], |r| r.get(0))?;
    let fts_rows: i64 =
        conn.query_row("SELECT COUNT(*) FROM web_messages_fts", [], |r| r.get(0))?;
    if rows > fts_rows {
        let _ = conn.execute(
            "INSERT INTO web_messages_fts(web_messages_fts) VALUES('rebuild')",
            [],
        );
    }
    Ok(())
}

fn init_pool() -> Result<Pool<SqliteConnectionManager>> {
    let path = chump_memory_db_path();
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let manager = SqliteConnectionManager::file(&path).with_init(|c| {
        // WAL: concurrent readers + one writer; busy_timeout: wait up to 5s on lock.
        // synchronous=NORMAL: safe with WAL, fewer fsyncs for better throughput.
        c.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;",
        )
    });
    let pool = Pool::builder().max_size(16).build(manager)?;
    let conn = pool.get()?;
    init_schema(&conn)?;
    Ok(pool)
}

/// Return a connection from the shared pool. Initializes the pool (and schema) on first use.
pub fn get() -> Result<PooledConn> {
    let pool = POOL.get_or_init(|| {
        init_pool().unwrap_or_else(|e| {
            eprintln!("FATAL: chump_memory db pool init failed: {e}");
            std::process::exit(1);
        })
    });
    pool.get().map_err(Into::into)
}
