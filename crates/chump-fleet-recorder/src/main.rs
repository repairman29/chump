//! `chump-fleet-recorder` — INFRA-2174 (INFRA-2164 sub-slice a)
//!
//! Capture daemon that writes fleet events to `.chump/fleet_events.db`.
//! Two sources:
//!
//! 1. **NATS JetStream** — durable push consumer on `chump.events.>` and
//!    `chump.work.>`. Restart resumes from last-acked sequence; no events lost.
//!
//! 2. **ambient.jsonl tail** — tails `.chump-locks/ambient.jsonl` from the
//!    current EOF on first run. Persists the byte offset in a `cursor` table
//!    so restart picks up where it left off. On file rotation (inode change),
//!    resumes from the new file's head.
//!
//! ## Schema
//!
//! ```sql
//! CREATE TABLE events (
//!   id INTEGER PRIMARY KEY AUTOINCREMENT,
//!   ts TEXT NOT NULL,
//!   ts_ms INTEGER NOT NULL,
//!   source TEXT NOT NULL,
//!   subject TEXT,
//!   event_kind TEXT NOT NULL,
//!   session_id TEXT,
//!   gap_id TEXT,
//!   payload TEXT NOT NULL,
//!   UNIQUE(ts_ms, session_id, event_kind, gap_id)
//! );
//! ```
//!
//! ## Env vars
//!
//! | Variable | Default | Purpose |
//! |---|---|---|
//! | `CHUMP_NATS_URL` | `nats://127.0.0.1:4222` | NATS broker address |
//! | `CHUMP_FLEET_EVENTS_DB` | `.chump/fleet_events.db` | SQLite path override |
//! | `CHUMP_AMBIENT_LOG` | `.chump-locks/ambient.jsonl` | ambient file to tail |
//! | `CHUMP_FLEET_RECORDER_TTL_DAYS` | `7` | event retention in days |

use std::fs;
use std::io::{self, BufRead, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use async_nats::jetstream::{self, consumer};
use chrono::Utc;
use futures::StreamExt;
use rusqlite::{params, Connection};
use serde_json::Value;
use tokio::sync::Mutex;
use tokio::time;
use tracing::{debug, error, info, warn};

// ── constants ──────────────────────────────────────────────────────────────

const CONSUMER_NAME: &str = "chump-fleet-recorder";
const EVENTS_STREAM: &str = "CHUMP_EVENTS";
const WORK_STREAM: &str = "CHUMP_WORK";
const EVENTS_SUBJECT: &str = "chump.events.>";
const WORK_SUBJECT: &str = "chump.work.>";
const DEFAULT_NATS_URL: &str = "nats://127.0.0.1:4222";
const DEFAULT_TTL_DAYS: u64 = 7;
const TTL_PRUNE_INTERVAL_SECS: u64 = 3600; // 60 min
const AMBIENT_POLL_INTERVAL_MS: u64 = 250;

// ── DB helpers ─────────────────────────────────────────────────────────────

/// Resolve the fleet_events.db path.
fn resolve_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_FLEET_EVENTS_DB") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    // Try git root first.
    let root = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| ".".to_string());
    PathBuf::from(root).join(".chump").join("fleet_events.db")
}

/// Resolve the ambient.jsonl path.
fn resolve_ambient_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AMBIENT_LOG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    PathBuf::from(".chump-locks/ambient.jsonl")
}

/// Open SQLite and apply schema migrations.
fn open_db(path: &Path) -> Result<Connection> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("create .chump dir")?;
    }
    let conn = Connection::open(path).context("open fleet_events.db")?;

    // WAL mode for concurrent readers.
    conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")?;

    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS events (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         TEXT    NOT NULL,
            ts_ms      INTEGER NOT NULL,
            source     TEXT    NOT NULL,
            subject    TEXT,
            event_kind TEXT    NOT NULL,
            session_id TEXT,
            gap_id     TEXT,
            payload    TEXT    NOT NULL,
            UNIQUE(ts_ms, session_id, event_kind, gap_id)
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts_ms   ON events(ts_ms);
        CREATE INDEX IF NOT EXISTS idx_events_session  ON events(session_id, ts_ms);
        CREATE INDEX IF NOT EXISTS idx_events_gap      ON events(gap_id, ts_ms);
        CREATE INDEX IF NOT EXISTS idx_events_kind     ON events(event_kind, ts_ms);

        CREATE TABLE IF NOT EXISTS cursor (
            source     TEXT PRIMARY KEY,
            position   INTEGER NOT NULL DEFAULT 0,
            inode      INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT    NOT NULL DEFAULT ''
        );
        "#,
    )
    .context("schema migration")?;

    Ok(conn)
}

/// Insert one event row; silently ignores duplicates via INSERT OR IGNORE.
/// 9 args mirrors the 9-column schema — a struct would be indirection without gain here.
#[allow(clippy::too_many_arguments)]
fn insert_event(
    conn: &Connection,
    ts: &str,
    ts_ms: i64,
    source: &str,
    subject: Option<&str>,
    event_kind: &str,
    session_id: Option<&str>,
    gap_id: Option<&str>,
    payload: &str,
) -> Result<()> {
    conn.execute(
        r#"INSERT OR IGNORE INTO events
           (ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"#,
        params![ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload],
    )
    .context("insert_event")?;
    Ok(())
}

// ── event parsing helpers ──────────────────────────────────────────────────

/// Extract (ts, ts_ms, event_kind, session_id, gap_id) from a raw JSON payload.
/// Falls back gracefully if fields are absent.
fn parse_event_fields(payload: &Value) -> (String, i64, String, Option<String>, Option<String>) {
    let ts = payload
        .get("ts")
        .and_then(|v| v.as_str())
        .map(String::from)
        .unwrap_or_else(|| Utc::now().to_rfc3339());

    let ts_ms = chrono::DateTime::parse_from_rfc3339(&ts)
        .map(|dt| dt.timestamp_millis())
        .unwrap_or_else(|_| Utc::now().timestamp_millis());

    // "kind" is the canonical field; "event" is the legacy ambient alias.
    let event_kind = payload
        .get("kind")
        .or_else(|| payload.get("event"))
        .and_then(|v| v.as_str())
        .map(String::from)
        .unwrap_or_else(|| "unknown".to_string());

    let session_id = payload
        .get("session")
        .or_else(|| payload.get("session_id"))
        .and_then(|v| v.as_str())
        .map(String::from);

    let gap_id = payload
        .get("gap")
        .or_else(|| payload.get("gap_id"))
        .and_then(|v| v.as_str())
        .map(String::from);

    (ts, ts_ms, event_kind, session_id, gap_id)
}

// ── NATS consumer ──────────────────────────────────────────────────────────

/// Ensure a JetStream stream exists for the given subjects.
async fn ensure_stream(
    js: &jetstream::Context,
    name: &str,
    subjects: Vec<String>,
) -> Result<jetstream::stream::Stream> {
    let stream = js
        .get_or_create_stream(jetstream::stream::Config {
            name: name.to_string(),
            subjects,
            max_age: Duration::from_secs(86_400), // 24h retention on broker
            ..Default::default()
        })
        .await
        .with_context(|| format!("ensure stream {name}"))?;
    Ok(stream)
}

type PullMsgResult = Result<
    jetstream::Message,
    async_nats::error::Error<jetstream::consumer::pull::MessagesErrorKind>,
>;
type PullStream = std::pin::Pin<Box<dyn futures::Stream<Item = PullMsgResult> + Send + Unpin>>;

/// Get or create a durable pull consumer on the given stream.
/// Durable name scoped per-stream so both stream consumers are independent.
async fn ensure_durable_consumer(
    stream: &jetstream::stream::Stream,
    consumer_name: &str,
    filter_subject: &str,
) -> Result<PullStream> {
    let consumer = stream
        .get_or_create_consumer::<consumer::pull::Config>(
            consumer_name,
            consumer::pull::Config {
                durable_name: Some(consumer_name.to_string()),
                filter_subject: filter_subject.to_string(),
                ack_policy: consumer::AckPolicy::Explicit,
                ..Default::default()
            },
        )
        .await
        .with_context(|| format!("ensure consumer {consumer_name}"))?;

    let messages = consumer
        .messages()
        .await
        .with_context(|| format!("subscribe consumer {consumer_name}"))?;
    Ok(Box::pin(messages))
}

/// Drain a NATS subject stream into the DB.
/// Returns only on fatal error or SIGTERM.
async fn nats_ingest_loop(
    db: Arc<Mutex<Connection>>,
    js: jetstream::Context,
    stream_name: &str,
    stream_subjects: Vec<String>,
    filter_subject: &str,
    source_label: &str,
) -> Result<()> {
    info!("[recorder] starting NATS loop source={source_label}");

    let stream = ensure_stream(&js, stream_name, stream_subjects).await?;
    let consumer_name = format!("{CONSUMER_NAME}-{stream_name}");
    let mut messages = ensure_durable_consumer(&stream, &consumer_name, filter_subject).await?;

    while let Some(msg_result) = messages.next().await {
        let msg = match msg_result {
            Ok(m) => m,
            Err(e) => {
                warn!("[recorder] NATS message error on {source_label}: {e}");
                continue;
            }
        };

        let subject = msg.subject.to_string();
        let raw = String::from_utf8_lossy(&msg.payload).to_string();

        let parsed: Value = match serde_json::from_str(&raw) {
            Ok(v) => v,
            Err(_) => {
                // Non-JSON payload — store raw, treat kind as "raw"
                serde_json::json!({"raw": raw})
            }
        };

        let (ts, ts_ms, event_kind, session_id, gap_id) = parse_event_fields(&parsed);
        let payload_str = serde_json::to_string(&parsed).unwrap_or(raw);

        {
            let conn = db.lock().await;
            if let Err(e) = insert_event(
                &conn,
                &ts,
                ts_ms,
                source_label,
                Some(&subject),
                &event_kind,
                session_id.as_deref(),
                gap_id.as_deref(),
                &payload_str,
            ) {
                error!("[recorder] DB insert error: {e}");
            }
        }

        // Ack after successful write so durable consumer tracks position.
        if let Err(e) = msg.ack().await {
            warn!("[recorder] ack error: {e}");
        }

        debug!("[recorder] recorded {source_label} {event_kind} ts={ts}");
    }

    warn!("[recorder] NATS loop exited for {source_label}");
    Ok(())
}

// ── ambient.jsonl tailer ───────────────────────────────────────────────────

/// Read the persisted cursor position for the ambient file.
fn load_cursor(conn: &Connection, source: &str) -> (u64, u64) {
    let result = conn.query_row(
        "SELECT position, inode FROM cursor WHERE source = ?1",
        params![source],
        |row| Ok((row.get::<_, i64>(0)? as u64, row.get::<_, i64>(1)? as u64)),
    );
    result.unwrap_or((0, 0))
}

/// Persist the cursor position.
fn save_cursor(conn: &Connection, source: &str, position: u64, inode: u64) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    conn.execute(
        r#"INSERT INTO cursor (source, position, inode, updated_at)
           VALUES (?1, ?2, ?3, ?4)
           ON CONFLICT(source) DO UPDATE SET position=excluded.position,
                                              inode=excluded.inode,
                                              updated_at=excluded.updated_at"#,
        params![source, position as i64, inode as i64, now],
    )?;
    Ok(())
}

/// Tail the ambient.jsonl file, writing new lines into the DB.
/// Runs until the tokio runtime shuts down.
async fn ambient_tail_loop(db: Arc<Mutex<Connection>>, ambient_path: PathBuf) -> Result<()> {
    let source_label = "ambient";
    let source_key = format!("file:{}", ambient_path.display());

    // Determine initial position: if cursor stored, use it; else seek to EOF
    // (we only want new events from this run forward).
    let (mut position, mut known_inode) = {
        let conn = db.lock().await;
        load_cursor(&conn, &source_key)
    };

    // If no saved cursor, seek to current EOF so we don't replay history.
    if position == 0 && known_inode == 0 {
        if let Ok(meta) = fs::metadata(&ambient_path) {
            position = meta.len();
            known_inode = meta.ino();
            let conn = db.lock().await;
            let _ = save_cursor(&conn, &source_key, position, known_inode);
        }
    }

    info!(
        "[recorder] ambient tail starting at byte={position} path={}",
        ambient_path.display()
    );

    let mut interval = time::interval(Duration::from_millis(AMBIENT_POLL_INTERVAL_MS));
    interval.set_missed_tick_behavior(time::MissedTickBehavior::Skip);

    loop {
        interval.tick().await;

        // Check for file rotation (inode change).
        let current_inode = match fs::metadata(&ambient_path) {
            Ok(m) => m.ino(),
            Err(_) => {
                // File gone — wait for it to reappear.
                continue;
            }
        };

        if current_inode != known_inode && known_inode != 0 {
            info!("[recorder] ambient file rotated (inode {known_inode}→{current_inode}), resetting to head");
            position = 0;
            known_inode = current_inode;
        } else if known_inode == 0 {
            known_inode = current_inode;
        }

        // Open file and seek to our position.
        let mut file = match fs::OpenOptions::new().read(true).open(&ambient_path) {
            Ok(f) => f,
            Err(_) => continue,
        };

        if let Err(e) = file.seek(SeekFrom::Start(position)) {
            warn!("[recorder] ambient seek failed: {e}");
            continue;
        }

        let mut reader = io::BufReader::new(&mut file);
        let mut new_position = position;
        let mut inserted = 0u32;

        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => break, // EOF
                Ok(n) => {
                    new_position += n as u64;
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }

                    let parsed: Value = match serde_json::from_str(trimmed) {
                        Ok(v) => v,
                        Err(_) => continue, // skip malformed lines
                    };

                    let (ts, ts_ms, event_kind, session_id, gap_id) = parse_event_fields(&parsed);
                    let payload_str = serde_json::to_string(&parsed).unwrap_or_default();

                    let conn = db.lock().await;
                    if let Err(e) = insert_event(
                        &conn,
                        &ts,
                        ts_ms,
                        source_label,
                        None, // no NATS subject for ambient lines
                        &event_kind,
                        session_id.as_deref(),
                        gap_id.as_deref(),
                        &payload_str,
                    ) {
                        error!("[recorder] ambient DB insert: {e}");
                    } else {
                        inserted += 1;
                    }
                }
                Err(e) => {
                    warn!("[recorder] ambient read error: {e}");
                    break;
                }
            }
        }

        if new_position != position {
            position = new_position;
            let conn = db.lock().await;
            let _ = save_cursor(&conn, &source_key, position, known_inode);
            if inserted > 0 {
                debug!("[recorder] ambient ingested {inserted} lines, cursor={position}");
            }
        }
    }
}

// ── TTL pruner ─────────────────────────────────────────────────────────────

/// Periodically delete events older than TTL_DAYS.
/// kind=fleet_recorder_ttl_pruned — scanner-anchor: ambient event emitted by TTL pruner
async fn ttl_prune_loop(db: Arc<Mutex<Connection>>, ttl_days: u64) {
    let mut interval = time::interval(Duration::from_secs(TTL_PRUNE_INTERVAL_SECS));
    interval.set_missed_tick_behavior(time::MissedTickBehavior::Skip);
    loop {
        interval.tick().await;
        let cutoff_ms = Utc::now().timestamp_millis() - (ttl_days as i64 * 86_400 * 1000);
        let conn = db.lock().await;
        match conn.execute("DELETE FROM events WHERE ts_ms < ?1", params![cutoff_ms]) {
            Ok(n) => {
                if n > 0 {
                    info!("[recorder] TTL pruner deleted {n} events older than {ttl_days}d");
                }
            }
            Err(e) => error!("[recorder] TTL prune error: {e}"),
        }
    }
}

// ── main ───────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    // Initialise structured logging via RUST_LOG (default: info).
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let db_path = resolve_db_path();
    let ambient_path = resolve_ambient_path();
    let nats_url = std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| DEFAULT_NATS_URL.to_string());
    let ttl_days: u64 = std::env::var("CHUMP_FLEET_RECORDER_TTL_DAYS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_TTL_DAYS);

    info!(
        "[recorder] starting — db={} ambient={} nats={}",
        db_path.display(),
        ambient_path.display(),
        nats_url
    );

    let conn = open_db(&db_path).context("open fleet DB")?;
    let db: Arc<Mutex<Connection>> = Arc::new(Mutex::new(conn));

    // ── NATS connection (optional — degrade gracefully if unavailable) ──
    let nats_result =
        tokio::time::timeout(Duration::from_millis(1000), async_nats::connect(&nats_url)).await;

    let nats_available = match nats_result {
        Ok(Ok(nats_client)) => {
            info!("[recorder] NATS connected at {nats_url}");
            let js = jetstream::new(nats_client);

            // Spawn NATS ingest tasks for both subjects.
            let db_events = Arc::clone(&db);
            let js_events = js.clone();
            tokio::spawn(async move {
                loop {
                    if let Err(e) = nats_ingest_loop(
                        Arc::clone(&db_events),
                        js_events.clone(),
                        EVENTS_STREAM,
                        vec![format!("chump.events.>")],
                        EVENTS_SUBJECT,
                        "nats:chump.events",
                    )
                    .await
                    {
                        error!("[recorder] events NATS loop error: {e}; restarting in 5s");
                        time::sleep(Duration::from_secs(5)).await;
                    }
                }
            });

            let db_work = Arc::clone(&db);
            let js_work = js.clone();
            tokio::spawn(async move {
                loop {
                    if let Err(e) = nats_ingest_loop(
                        Arc::clone(&db_work),
                        js_work.clone(),
                        WORK_STREAM,
                        vec![format!("chump.work.>")],
                        WORK_SUBJECT,
                        "nats:chump.work",
                    )
                    .await
                    {
                        error!("[recorder] work NATS loop error: {e}; restarting in 5s");
                        time::sleep(Duration::from_secs(5)).await;
                    }
                }
            });

            true
        }
        Ok(Err(e)) => {
            warn!("[recorder] NATS unavailable ({e}); running ambient-only mode");
            false
        }
        Err(_) => {
            warn!("[recorder] NATS connect timed out at {nats_url}; running ambient-only mode");
            false
        }
    };

    if !nats_available {
        info!("[recorder] degraded mode: NATS offline, tailing ambient.jsonl only");
    }

    // ── Ambient tail task (always runs) ───────────────────────────────────
    let db_ambient = Arc::clone(&db);
    tokio::spawn(async move {
        loop {
            if let Err(e) = ambient_tail_loop(Arc::clone(&db_ambient), ambient_path.clone()).await {
                error!("[recorder] ambient tail error: {e}; restarting in 2s");
                time::sleep(Duration::from_secs(2)).await;
            }
        }
    });

    // ── TTL pruner (always runs) ──────────────────────────────────────────
    let db_ttl = Arc::clone(&db);
    tokio::spawn(async move {
        ttl_prune_loop(db_ttl, ttl_days).await;
    });

    // ── Wait for SIGTERM / SIGINT ─────────────────────────────────────────
    // On shutdown, the durable NATS consumer has already acked every processed
    // message, so restart picks up exactly where we left off.
    tokio::signal::ctrl_c().await.context("signal handler")?;
    info!("[recorder] received shutdown signal; exiting cleanly");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn in_memory_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL, ts_ms INTEGER NOT NULL, source TEXT NOT NULL,
                subject TEXT, event_kind TEXT NOT NULL, session_id TEXT,
                gap_id TEXT, payload TEXT NOT NULL,
                UNIQUE(ts_ms, session_id, event_kind, gap_id)
            );
            CREATE TABLE cursor (
                source TEXT PRIMARY KEY, position INTEGER NOT NULL DEFAULT 0,
                inode INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT ''
            );
            "#,
        )
        .unwrap();
        conn
    }

    #[test]
    fn deduplication_via_unique_constraint() {
        let conn = in_memory_conn();
        let ts = "2026-05-29T12:00:00Z";
        let ts_ms: i64 = 1748520000000;

        // First insert succeeds.
        insert_event(
            &conn,
            ts,
            ts_ms,
            "ambient",
            None,
            "gap_claimed",
            Some("s1"),
            Some("G-1"),
            "{}",
        )
        .unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM events", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1, "first insert should land");

        // Duplicate silently ignored.
        insert_event(
            &conn,
            ts,
            ts_ms,
            "ambient",
            None,
            "gap_claimed",
            Some("s1"),
            Some("G-1"),
            r#"{"extra":1}"#,
        )
        .unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM events", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1, "duplicate must be silently ignored");
    }

    #[test]
    fn parse_event_fields_extracts_kind_and_session() {
        let v: Value = serde_json::json!({
            "ts": "2026-05-29T12:00:00Z",
            "kind": "gap_claimed",
            "session": "opus-42",
            "gap": "INFRA-2174"
        });
        let (ts, _ts_ms, kind, session, gap) = parse_event_fields(&v);
        assert_eq!(kind, "gap_claimed");
        assert_eq!(session.unwrap(), "opus-42");
        assert_eq!(gap.unwrap(), "INFRA-2174");
        assert!(ts.starts_with("2026-05-29"));
    }

    #[test]
    fn parse_event_fields_falls_back_to_event_alias() {
        let v: Value = serde_json::json!({ "event": "bash_call", "ts": "2026-05-29T12:00:00Z" });
        let (_, _, kind, _, _) = parse_event_fields(&v);
        assert_eq!(kind, "bash_call");
    }

    #[test]
    fn parse_event_fields_unknown_fallback() {
        let v: Value = serde_json::json!({});
        let (_, _, kind, session, gap) = parse_event_fields(&v);
        assert_eq!(kind, "unknown");
        assert!(session.is_none());
        assert!(gap.is_none());
    }

    #[test]
    fn cursor_round_trip() {
        let conn = in_memory_conn();
        save_cursor(&conn, "file:/tmp/ambient.jsonl", 4096, 99_999).unwrap();
        let (pos, inode) = load_cursor(&conn, "file:/tmp/ambient.jsonl");
        assert_eq!(pos, 4096);
        assert_eq!(inode, 99_999);
    }

    #[tokio::test]
    async fn ambient_tail_ingests_new_lines() {
        // Write a temp file with one line.
        let mut tmp = NamedTempFile::new().unwrap();
        let line1 = r#"{"ts":"2026-05-29T12:00:00Z","kind":"test_event","session":"s1"}"#;
        writeln!(tmp, "{line1}").unwrap();
        tmp.flush().unwrap();

        let tmp_path = tmp.path().to_path_buf();
        let conn = in_memory_conn();
        let db = Arc::new(Mutex::new(conn));

        // Seek cursor to head so the tail picks up from byte 0.
        {
            let c = db.lock().await;
            let meta = fs::metadata(&tmp_path).unwrap();
            save_cursor(&c, &format!("file:{}", tmp_path.display()), 0, 0).unwrap();
            // override inode to 0 to trigger proper detection
            let _ = meta;
        }

        // Write the line before we tail so the tail finds it.
        let db_clone = Arc::clone(&db);
        let path_clone = tmp_path.clone();

        // Run tail with a short timeout.
        let _ = tokio::time::timeout(
            Duration::from_millis(800),
            ambient_tail_loop(db_clone, path_clone),
        )
        .await;

        let count: i64 = {
            let conn = db.lock().await;
            conn.query_row(
                "SELECT COUNT(*) FROM events WHERE event_kind='test_event'",
                [],
                |r| r.get(0),
            )
            .unwrap()
        };
        assert_eq!(
            count, 1,
            "ambient tail should have ingested the test_event line"
        );
    }
}
