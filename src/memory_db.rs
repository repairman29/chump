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
    /// Distilled `semantic_fact` rows inserted by LLM summarization.
    /// Zero unless `CHUMP_MEMORY_LLM_SUMMARIZE=1` and a summarizer was provided.
    pub summaries_created: u64,
    /// Episodic rows collapsed into summaries. These are soft-deleted by
    /// setting `expires_at` to now, which `expire_stale_memories` picks up
    /// on the next pass — kept in the DB for one tick for auditability.
    pub episodics_summarized: u64,
}

impl CurationReport {
    pub fn total_changed(&self) -> u64 {
        self.expired
            + self.deduped_exact
            + self.decayed
            + self.summaries_created
            + self.episodics_summarized
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
pub(crate) fn curate_all_on_conn(conn: &Connection, decay_rate: f64) -> Result<CurationReport> {
    Ok(CurationReport {
        expired: expire_stale_memories_on_conn(conn).unwrap_or(0),
        deduped_exact: dedupe_exact_content_on_conn(conn).unwrap_or(0),
        decayed: decay_unverified_confidence_on_conn(conn, decay_rate).unwrap_or(0),
        // DB-only curation path does not summarize (that's the LLM summarizer's job,
        // gated by CHUMP_MEMORY_LLM_SUMMARIZE). Zero is correct here.
        summaries_created: 0,
        episodics_summarized: 0,
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

// ── LLM episodic → semantic summarization ──────────────────────────────
//
// Closes MEM-003 in `docs/gaps.yaml`. The DB-only passes above handle decay
// and dedupe cheaply, but the third pillar the dissertation called for —
// distilling clusters of old episodic memories into a single semantic_fact
// — requires an inference call. We keep the clustering + insertion pure
// and sync (tested here), and accept an injected summarizer closure so the
// async glue to a real delegate lives in the caller (see
// `summarize_old_episodics_with_delegate` in `memory_brain_tool.rs` if/when
// that wiring lands).

/// Input handed to the summarizer: one cluster of episodic memories
/// (ordered oldest → newest by `id`). The summarizer returns the distilled
/// content for a new `semantic_fact` row.
#[derive(Debug, Clone)]
pub struct SummarizationInput {
    /// Opaque cluster identifier (source + age-bucket) — stable enough to
    /// log and diff across curation runs.
    pub cluster_id: String,
    pub memories: Vec<MemoryRow>,
}

/// Output from the summarizer. `tokens_used` is best-effort — zero is fine
/// when the summarizer can't report it (e.g. a test stub).
#[derive(Debug, Clone)]
pub struct SummarizationOutput {
    pub semantic_fact: String,
    pub tokens_used: u64,
}

/// Configuration knobs for summarization. Defaults are conservative so an
/// accidental `CHUMP_MEMORY_LLM_SUMMARIZE=1` on a fresh DB doesn't burn
/// inference budget on tiny clusters.
#[derive(Debug, Clone, Copy)]
pub struct SummarizationConfig {
    /// Minimum episodic rows in a cluster before it's worth summarizing.
    /// `0` or `1` would waste an inference call on a single memory.
    pub min_cluster_size: usize,
    /// Only summarize episodic rows at least this many days old. Recent
    /// episodes still have retrieval value in their raw form.
    pub min_age_days: u64,
    /// Cap the number of clusters summarized per pass. Prevents one
    /// heartbeat from blowing the inference budget.
    pub max_clusters_per_pass: usize,
}

impl Default for SummarizationConfig {
    fn default() -> Self {
        Self {
            min_cluster_size: 5,
            min_age_days: 30,
            max_clusters_per_pass: 3,
        }
    }
}

impl SummarizationConfig {
    /// Build from env:
    ///   CHUMP_MEMORY_SUMMARIZE_MIN_CLUSTER (default 5)
    ///   CHUMP_MEMORY_SUMMARIZE_MIN_AGE_DAYS (default 30)
    ///   CHUMP_MEMORY_SUMMARIZE_MAX_CLUSTERS (default 3)
    pub fn from_env() -> Self {
        let default = Self::default();
        Self {
            min_cluster_size: std::env::var("CHUMP_MEMORY_SUMMARIZE_MIN_CLUSTER")
                .ok()
                .and_then(|s| s.trim().parse::<usize>().ok())
                .filter(|n| *n >= 2)
                .unwrap_or(default.min_cluster_size),
            min_age_days: std::env::var("CHUMP_MEMORY_SUMMARIZE_MIN_AGE_DAYS")
                .ok()
                .and_then(|s| s.trim().parse::<u64>().ok())
                .unwrap_or(default.min_age_days),
            max_clusters_per_pass: std::env::var("CHUMP_MEMORY_SUMMARIZE_MAX_CLUSTERS")
                .ok()
                .and_then(|s| s.trim().parse::<usize>().ok())
                .filter(|n| *n >= 1)
                .unwrap_or(default.max_clusters_per_pass),
        }
    }
}

/// Pure cluster-selection — returns the clusters that are eligible for
/// summarization without running any inference. Grouped by `source` within
/// an age bucket (floor of age-days / 30) so memories from the same
/// conversation / integration stay together.
pub(crate) fn select_episodic_clusters_from_rows(
    rows: &[MemoryRow],
    config: SummarizationConfig,
    now_epoch: i64,
) -> Vec<SummarizationInput> {
    let min_age_secs = (config.min_age_days as i64).saturating_mul(86_400);
    let cutoff = now_epoch.saturating_sub(min_age_secs);

    let mut buckets: std::collections::BTreeMap<String, Vec<MemoryRow>> =
        std::collections::BTreeMap::new();
    for row in rows {
        if row.memory_type != "episodic_event" {
            continue;
        }
        // Parse `ts` as unix epoch (i64). If it's an ISO timestamp or
        // anything else we can't interpret, treat as very old (include it).
        let ts_epoch: i64 = row.ts.trim().parse::<i64>().unwrap_or(0);
        if ts_epoch > cutoff {
            continue;
        }
        // Bucket = source + age_months (floor).
        let age_days = ((now_epoch - ts_epoch) / 86_400).max(0);
        let age_months = age_days / 30;
        let bucket_key = format!("{}::m{}", row.source, age_months);
        buckets.entry(bucket_key).or_default().push(row.clone());
    }

    let mut clusters: Vec<SummarizationInput> = buckets
        .into_iter()
        .filter_map(|(key, mut memories)| {
            if memories.len() < config.min_cluster_size {
                return None;
            }
            memories.sort_by_key(|m| m.id);
            Some(SummarizationInput {
                cluster_id: key,
                memories,
            })
        })
        .collect();

    // Oldest clusters first so a capped pass favors the oldest backlog.
    clusters.sort_by_key(|c| c.memories.first().map(|m| m.id).unwrap_or(0));
    clusters.truncate(config.max_clusters_per_pass);
    clusters
}

/// Find and return eligible clusters from the live DB.
pub fn select_episodic_clusters(config: SummarizationConfig) -> Result<Vec<SummarizationInput>> {
    let conn = open_db()?;
    let mut stmt = conn.prepare(
        "SELECT id, content, ts, source, confidence, verified, sensitivity, expires_at, memory_type \
         FROM chump_memory \
         WHERE memory_type = 'episodic_event' \
           AND (expires_at IS NULL OR CAST(expires_at AS INTEGER) > CAST(strftime('%s','now') AS INTEGER)) \
         ORDER BY id",
    )?;
    let rows: Vec<MemoryRow> = stmt
        .query_map([], row_to_memory)?
        .collect::<Result<Vec<_>, _>>()?;
    let now_epoch: i64 = chrono_like_now_epoch(&conn)?;
    Ok(select_episodic_clusters_from_rows(&rows, config, now_epoch))
}

// We avoid pulling chrono as a new dep — SQLite can give us epoch seconds.
fn chrono_like_now_epoch(conn: &Connection) -> Result<i64> {
    let now: i64 = conn.query_row("SELECT CAST(strftime('%s','now') AS INTEGER)", [], |r| {
        r.get(0)
    })?;
    Ok(now)
}

/// Run summarization with an injected summarizer function. Returns
/// (summaries_created, episodics_marked_for_expiry). The summarizer is
/// called once per cluster; its `semantic_fact` is inserted into
/// `chump_memory` with `memory_type = 'semantic_fact'` and `verified = 1`,
/// and the source episodics get `expires_at` set to now so the next
/// `expire_stale_memories` pass removes them.
///
/// If `CHUMP_MEMORY_LLM_SUMMARIZE` is not set to `1`, returns (0, 0)
/// without running. This is the opt-in gate MEM-003 calls out.
pub fn summarize_old_episodics_with<F>(
    conn: &Connection,
    config: SummarizationConfig,
    mut summarizer: F,
) -> Result<(u64, u64)>
where
    F: FnMut(SummarizationInput) -> Result<SummarizationOutput>,
{
    if !llm_summarize_enabled() {
        return Ok((0, 0));
    }
    let mut stmt = conn.prepare(
        "SELECT id, content, ts, source, confidence, verified, sensitivity, expires_at, memory_type \
         FROM chump_memory \
         WHERE memory_type = 'episodic_event' \
           AND (expires_at IS NULL OR CAST(expires_at AS INTEGER) > CAST(strftime('%s','now') AS INTEGER)) \
         ORDER BY id",
    )?;
    let rows: Vec<MemoryRow> = stmt
        .query_map([], row_to_memory)?
        .collect::<Result<Vec<_>, _>>()?;
    drop(stmt);
    let now_epoch: i64 = chrono_like_now_epoch(conn)?;
    let clusters = select_episodic_clusters_from_rows(&rows, config, now_epoch);

    let mut summaries = 0u64;
    let mut collapsed = 0u64;
    for cluster in clusters {
        let source_ids: Vec<i64> = cluster.memories.iter().map(|m| m.id).collect();
        let cluster_id = cluster.cluster_id.clone();
        let output = match summarizer(cluster) {
            Ok(o) => o,
            Err(e) => {
                tracing::warn!(
                    cluster = %cluster_id,
                    error = %e,
                    "summarizer failed for cluster; skipping"
                );
                continue;
            }
        };
        // Insert the distilled semantic_fact.
        let content = output.semantic_fact.trim();
        if content.is_empty() {
            tracing::warn!(
                cluster = %cluster_id,
                "summarizer returned empty content; skipping"
            );
            continue;
        }
        let now_str = now_epoch.to_string();
        conn.execute(
            "INSERT INTO chump_memory \
             (content, ts, source, confidence, verified, sensitivity, expires_at, memory_type) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, 'semantic_fact')",
            rusqlite::params![
                content,
                now_str,
                format!("summary::{}", cluster_id),
                0.80, // conservative confidence for generated summaries
                1,    // verified — the summarizer is the verification step
                "internal",
            ],
        )?;
        summaries += 1;
        // Soft-delete the source episodics: expires_at = now. Next
        // `expire_stale_memories` pass (or this same `curate_all` run if
        // caller orders it last) picks them up.
        for id in &source_ids {
            conn.execute(
                "UPDATE chump_memory SET expires_at = ?1 WHERE id = ?2",
                rusqlite::params![now_str, id],
            )?;
            collapsed += 1;
        }
    }
    Ok((summaries, collapsed))
}

fn llm_summarize_enabled() -> bool {
    std::env::var("CHUMP_MEMORY_LLM_SUMMARIZE")
        .map(|v| v.trim() == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

// ── MEM-004: async LLM summarizer adapter ─────────────────────────────
//
// MEM-003 shipped sync orchestration with an injected closure. MEM-004
// wires a live Provider to that orchestration so curate_all_async can
// optionally run LLM summarization. Pattern mirrors EVAL-004.

/// Build the summarizer prompt for one cluster. Free fn so tests can pin
/// the wording against snapshot drift.
pub fn build_summarizer_prompt(input: &SummarizationInput) -> String {
    let mut prompt = String::with_capacity(600 + input.memories.len() * 120);
    prompt.push_str(
        "You are distilling a cluster of old episodic memory rows into ONE \
         semantic fact — a standalone sentence capturing the common thread.\n\
         Rules:\n\
         - Output ONLY the distilled fact, no preamble, no explanation.\n\
         - Keep it factual; don't invent details not in the rows.\n\
         - Aim for 1-2 sentences, under 200 characters.\n\n",
    );
    prompt.push_str(&format!("## Cluster: {}\n", input.cluster_id));
    prompt.push_str(&format!(
        "Source: {}, {} episodic rows.\n\n",
        input
            .memories
            .first()
            .map(|m| m.source.as_str())
            .unwrap_or("unknown"),
        input.memories.len()
    ));
    prompt.push_str("## Memories (oldest → newest)\n");
    for (i, mem) in input.memories.iter().enumerate() {
        let snippet: String = mem.content.chars().take(200).collect();
        prompt.push_str(&format!("{}. {}\n", i + 1, snippet));
    }
    prompt.push_str("\nDistilled semantic fact:");
    prompt
}

/// Summarize one cluster via a live Provider.
pub async fn summarize_via_provider(
    provider: &dyn axonerai::provider::Provider,
    input: SummarizationInput,
) -> Result<SummarizationOutput> {
    let prompt = build_summarizer_prompt(&input);
    let messages = vec![axonerai::provider::Message {
        role: "user".to_string(),
        content: prompt,
    }];
    let resp = provider
        .complete(messages, None, Some(150), None)
        .await
        .map_err(|e| anyhow::anyhow!("summarizer provider error: {}", e))?;
    let text = resp.text.unwrap_or_default();
    let fact = text.trim().to_string();
    if fact.is_empty() {
        return Err(anyhow::anyhow!("summarizer returned empty content"));
    }
    Ok(SummarizationOutput {
        semantic_fact: fact,
        tokens_used: 0,
    })
}

/// Async variant of summarize_old_episodics_with that takes a Provider directly.
pub async fn summarize_old_episodics_async(
    conn: &Connection,
    config: SummarizationConfig,
    provider: &dyn axonerai::provider::Provider,
) -> Result<(u64, u64)> {
    if !llm_summarize_enabled() {
        return Ok((0, 0));
    }
    let rows: Vec<MemoryRow> = {
        let mut stmt = conn.prepare(
            "SELECT id, content, ts, source, confidence, verified, sensitivity, expires_at, memory_type \
             FROM chump_memory \
             WHERE memory_type = 'episodic_event' \
               AND (expires_at IS NULL OR CAST(expires_at AS INTEGER) > CAST(strftime('%s','now') AS INTEGER)) \
             ORDER BY id",
        )?;
        let rows_iter = stmt.query_map([], row_to_memory)?;
        let collected: std::result::Result<Vec<_>, _> = rows_iter.collect();
        collected?
    };
    let now_epoch: i64 = chrono_like_now_epoch(conn)?;
    let clusters = select_episodic_clusters_from_rows(&rows, config, now_epoch);

    let mut summaries = 0u64;
    let mut collapsed = 0u64;
    for cluster in clusters {
        let source_ids: Vec<i64> = cluster.memories.iter().map(|m| m.id).collect();
        let cluster_id = cluster.cluster_id.clone();
        let output = match summarize_via_provider(provider, cluster).await {
            Ok(o) => o,
            Err(e) => {
                tracing::warn!(
                    cluster = %cluster_id,
                    error = %e,
                    "summarizer failed for cluster; skipping"
                );
                continue;
            }
        };
        let content = output.semantic_fact.trim();
        if content.is_empty() {
            continue;
        }
        let now_str = now_epoch.to_string();
        conn.execute(
            "INSERT INTO chump_memory \
             (content, ts, source, confidence, verified, sensitivity, expires_at, memory_type) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, 'semantic_fact')",
            rusqlite::params![
                content,
                now_str,
                format!("summary::{}", cluster_id),
                0.80,
                1,
                "internal",
            ],
        )?;
        summaries += 1;
        for id in &source_ids {
            conn.execute(
                "UPDATE chump_memory SET expires_at = ?1 WHERE id = ?2",
                rusqlite::params![now_str, id],
            )?;
            collapsed += 1;
        }
    }
    Ok((summaries, collapsed))
}

/// Async curate_all — runs the DB-only passes then optionally summarizes.
pub async fn curate_all_async(
    provider: Option<&dyn axonerai::provider::Provider>,
) -> Result<CurationReport> {
    let conn = open_db()?;
    let base = curate_all_on_conn(&conn, decay_rate_from_env())?;
    let (summaries, collapsed) = match provider {
        Some(p) => summarize_old_episodics_async(&conn, SummarizationConfig::from_env(), p)
            .await
            .unwrap_or((0, 0)),
        None => (0, 0),
    };
    Ok(CurationReport {
        expired: base.expired,
        deduped_exact: base.deduped_exact,
        decayed: base.decayed,
        summaries_created: summaries,
        episodics_summarized: collapsed,
    })
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

/// Result of a single `memory_curate()` run (MEM-002 + MEM-003).
#[derive(Debug, Default)]
pub struct CurateResult {
    /// Unverified memories whose confidence was decayed by 0.01 this week.
    pub decayed: u64,
    /// Exact-duplicate rows removed (keeping the highest-confidence copy).
    pub deduped: u64,
    /// Episodic entries collapsed into semantic_fact summaries (phase 3).
    pub summarized: u64,
    /// Causal lessons marked stale due to age > 90 days (phase 4 / MEM-003).
    pub causal_staled: u64,
}

/// Curation pass for MEM-002 + MEM-003: confidence decay + deduplication + episodic summarization + causal obsolescence.
///
/// 1. **Confidence decay** — for every unverified memory (`verified = 0`) that is
///    older than 7 days, subtract 0.01 from `confidence`, flooring at 0.
/// 2. **Exact deduplication** — within each `memory_type`, delete rows with
///    identical `content`, keeping only the row with the highest confidence
///    (ties broken by latest `ts`, then highest `id`).
/// 3. **Episodic summarization** — `episodic_memory` entries older than 30 days
///    are grouped into monthly buckets; buckets with ≥ `MIN_EPISODE_CLUSTER` entries
///    are collapsed into a single `semantic_fact` summary row and then deleted.
/// 4. **Causal lesson obsolescence (MEM-003)** — `chump_causal_lessons` rows older
///    than 90 days are marked `stale = 1`; stale lessons are excluded from retrieval.
pub fn memory_curate() -> Result<CurateResult> {
    let conn = open_db()?;
    migrate_from_json_if_needed(&conn)?;

    // ── Phase 1: confidence decay ────────────────────────────────────────
    let decayed = conn.execute(
        "UPDATE chump_memory \
         SET confidence = MAX(0.0, ROUND(confidence - 0.01, 6)) \
         WHERE verified = 0 \
         AND datetime(ts) < datetime('now', '-7 days') \
         AND confidence > 0",
        [],
    )? as u64;

    // ── Phase 2: exact deduplication ────────────────────────────────────
    // For each group of rows with identical (content, memory_type), delete
    // all but the "best" row (highest confidence, then latest ts, then highest id).
    let deduped = conn.execute(
        "DELETE FROM chump_memory \
         WHERE id NOT IN ( \
           SELECT id FROM ( \
             SELECT id, \
                    ROW_NUMBER() OVER ( \
                      PARTITION BY content, memory_type \
                      ORDER BY confidence DESC, ts DESC, id DESC \
                    ) AS rn \
             FROM chump_memory \
           ) WHERE rn = 1 \
         )",
        [],
    )? as u64;

    // ── Phase 3: episodic cluster summarization ──────────────────────────
    let summarized = summarize_old_episodic(&conn)?;

    if deduped > 0 || summarized > 0 {
        let _ = conn.execute("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')", []);
    }

    // ── Phase 4: causal lesson obsolescence (MEM-003) ────────────────────
    // Mark chump_causal_lessons rows older than 90 days as stale.
    let causal_staled = {
        let db_conn = crate::db_pool::get();
        match db_conn {
            Ok(c) => c
                .execute(
                    "UPDATE chump_causal_lessons \
                     SET stale = 1 \
                     WHERE stale = 0 \
                       AND created_at < datetime('now', '-90 days')",
                    [],
                )
                .unwrap_or(0) as u64,
            Err(_) => 0,
        }
    };

    tracing::info!(
        decayed,
        deduped,
        summarized,
        causal_staled,
        "memory_curate complete"
    );
    Ok(CurateResult {
        decayed,
        deduped,
        summarized,
        causal_staled,
    })
}

/// Minimum episodic entries in a monthly bucket to trigger summarization.
const MIN_EPISODE_CLUSTER: usize = 3;
/// Maximum character length of a generated summary entry.
const MAX_SUMMARY_CHARS: usize = 1200;

/// Collapse old episodic_memory entries into semantic_fact summaries.
///
/// Groups `episodic_memory` rows older than 30 days by calendar month (YYYY-MM
/// prefix of the `ts` field). Any month-bucket with ≥ MIN_EPISODE_CLUSTER entries
/// is summarised into one bullet-list `semantic_fact` row, then the originals are
/// deleted. Returns the total number of episodic rows consumed.
fn summarize_old_episodic(conn: &rusqlite::Connection) -> Result<u64> {
    let mut stmt = conn.prepare(
        "SELECT id, content, ts, confidence \
         FROM chump_memory \
         WHERE memory_type = 'episodic_memory' \
         AND datetime(ts) < datetime('now', '-30 days') \
         ORDER BY ts",
    )?;

    let rows: Vec<(i64, String, String, f64)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .filter_map(|r| r.ok())
        .collect();

    // Group by YYYY-MM month bucket.
    let mut clusters: std::collections::BTreeMap<String, Vec<(i64, String, f64)>> =
        std::collections::BTreeMap::new();
    for (id, content, ts, conf) in rows {
        let bucket = if ts.len() >= 7 {
            ts[..7].to_string()
        } else {
            ts.clone()
        };
        clusters
            .entry(bucket)
            .or_default()
            .push((id, content, conf));
    }

    let mut summarized = 0u64;
    for (month, entries) in clusters {
        if entries.len() < MIN_EPISODE_CLUSTER {
            continue;
        }
        let avg_conf: f64 = entries.iter().map(|(_, _, c)| c).sum::<f64>() / entries.len() as f64;

        let mut summary = format!("[episodic summary {}] ", month);
        for (_, content, _) in &entries {
            let snippet = content.chars().take(200).collect::<String>();
            summary.push_str("• ");
            summary.push_str(&snippet);
            summary.push_str("; ");
            if summary.len() >= MAX_SUMMARY_CHARS {
                break;
            }
        }
        summary.truncate(MAX_SUMMARY_CHARS);

        conn.execute(
            "INSERT INTO chump_memory \
             (content, ts, source, confidence, verified, sensitivity, expires_at, memory_type) \
             VALUES (?1, datetime('now'), 'memory_curate', ?2, 0, 'internal', NULL, 'semantic_fact')",
            rusqlite::params![summary, avg_conf],
        )?;

        for (id, _, _) in &entries {
            conn.execute("DELETE FROM chump_memory WHERE id = ?1", [id])?;
        }
        summarized += entries.len() as u64;
    }

    Ok(summarized)
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

/// Rerank a retrieved batch of `MemoryRow`s by a composite relevance score.
///
/// `keyword_search` / `hybrid_search` return candidates ordered by recency,
/// which misses strong semantic hits and ignores verification + confidence.
/// This reranker combines four signals:
///
///   - `bm25_weight`: BM25 keyword relevance (lower = better; flipped and
///     normalized to \[0, 1]). Callers pass a `Vec<(MemoryRow, f64)>` where
///     the f64 is the raw BM25 score from FTS5's `rank` column. Pass `0.0`
///     when BM25 isn't available (e.g. recency-only searches).
///   - `verified` — 1.0 if verified ≥ 1, else 0.0. A verified fact should
///     win over a fresh rumor.
///   - `confidence` — the row's stored confidence (0.0 .. 1.0).
///   - `recency` — normalized age from 0 (newest in batch) to 1 (oldest).
///     Only compared within-batch; we treat "newer" as slightly better but
///     never let it dominate the semantic match.
///
/// Default weights are tuned so a high-BM25-hit verified fact beats a
/// fresh unverified rumor. Override via `CHUMP_RETRIEVAL_RERANK_WEIGHTS`
/// (comma-separated: `bm25,verified,confidence,recency`).
///
/// See dissertation Part X — closes the "retrieval reranking" near-term
/// gap. The prior call sites ordered purely by `id DESC`, which meant a
/// strong keyword hit from 6 months ago lost to an unrelated note from
/// yesterday.
pub fn rerank_memories(scored: Vec<(MemoryRow, f64)>) -> Vec<MemoryRow> {
    if scored.len() <= 1 {
        return scored.into_iter().map(|(r, _)| r).collect();
    }
    let weights = rerank_weights();
    // BM25 from FTS5 is negative (more negative = better match). Normalize
    // within the batch to [0, 1] with 1 = best match.
    let bm25_min = scored.iter().map(|(_, b)| *b).fold(f64::INFINITY, f64::min);
    let bm25_max = scored
        .iter()
        .map(|(_, b)| *b)
        .fold(f64::NEG_INFINITY, f64::max);
    let bm25_range = (bm25_max - bm25_min).abs();
    // Recency: parse id — higher id = more recent; normalize in-batch.
    let id_min = scored.iter().map(|(r, _)| r.id).min().unwrap_or(0) as f64;
    let id_max = scored.iter().map(|(r, _)| r.id).max().unwrap_or(0) as f64;
    let id_range = (id_max - id_min).abs();

    let mut with_score: Vec<(MemoryRow, f64)> = scored
        .into_iter()
        .map(|(row, bm25)| {
            // Normalize BM25: lower (more negative) → closer to 1.
            let bm25_norm = if bm25_range > f64::EPSILON {
                1.0 - ((bm25 - bm25_min) / bm25_range)
            } else {
                0.5
            };
            let verified_norm = if row.verified >= 1 { 1.0 } else { 0.0 };
            let confidence_norm = row.confidence.clamp(0.0, 1.0);
            let recency_norm = if id_range > f64::EPSILON {
                (row.id as f64 - id_min) / id_range
            } else {
                0.5
            };
            let score = weights.bm25 * bm25_norm
                + weights.verified * verified_norm
                + weights.confidence * confidence_norm
                + weights.recency * recency_norm;
            (row, score)
        })
        .collect();
    with_score.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    with_score.into_iter().map(|(r, _)| r).collect()
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct RerankWeights {
    pub bm25: f64,
    pub verified: f64,
    pub confidence: f64,
    pub recency: f64,
}

impl Default for RerankWeights {
    fn default() -> Self {
        // Tuned so a strong BM25 hit dominates, verified fact is a meaningful
        // tiebreaker, confidence nudges, and recency is a small tiebreaker.
        Self {
            bm25: 0.50,
            verified: 0.25,
            confidence: 0.15,
            recency: 0.10,
        }
    }
}

fn rerank_weights() -> RerankWeights {
    let default = RerankWeights::default();
    let Ok(s) = std::env::var("CHUMP_RETRIEVAL_RERANK_WEIGHTS") else {
        return default;
    };
    let parts: Vec<f64> = s
        .split(',')
        .filter_map(|p| p.trim().parse::<f64>().ok())
        .collect();
    if parts.len() != 4 || parts.iter().any(|v| !v.is_finite() || *v < 0.0) {
        return default;
    }
    RerankWeights {
        bm25: parts[0],
        verified: parts[1],
        confidence: parts[2],
        recency: parts[3],
    }
}

/// Keyword search with BM25 reranking. Returns up to `limit` rows, ranked
/// by [`rerank_memories`]. Preferred over [`keyword_search`] when relevance
/// matters more than recency (e.g. `memory_brain` recall during a session).
pub fn keyword_search_reranked(query: &str, limit: usize) -> Result<Vec<MemoryRow>> {
    let conn = open_db()?;
    migrate_from_json_if_needed(&conn)?;
    let limit = limit.min(100);
    let pattern = escape_fts5_query(query);
    if pattern.is_empty() {
        // No query → rerank degenerates to confidence+verified ordering.
        return keyword_search(query, limit);
    }
    let expiry_filter = "AND (m.expires_at IS NULL OR CAST(m.expires_at AS INTEGER) > CAST(strftime('%s','now') AS INTEGER))";
    // Pull 3x candidates from FTS5, rerank, then truncate. Gives the
    // reranker room to lift a verified mid-rank hit above a fresh top-rank.
    let candidate_cap = limit.saturating_mul(3).max(10);
    let sql = format!(
        "SELECT m.id, m.content, m.ts, m.source, m.confidence, m.verified, m.sensitivity, m.expires_at, m.memory_type, memory_fts.rank \
         FROM chump_memory m \
         INNER JOIN memory_fts ON memory_fts.rowid = m.id \
         WHERE memory_fts MATCH ?1 {} \
         ORDER BY memory_fts.rank \
         LIMIT ?2",
        expiry_filter,
    );
    let scored: Vec<(MemoryRow, f64)> = conn
        .prepare(&sql)?
        .query_map(rusqlite::params![pattern, candidate_cap], |r| {
            let row = row_to_memory(r)?;
            let rank: f64 = r.get(9).unwrap_or(0.0);
            Ok((row, rank))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let mut reranked = rerank_memories(scored);
    reranked.truncate(limit);
    Ok(reranked)
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
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
        let hundred_days_ago = (std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64)
            - 100 * 86400;
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
        let very_old = (std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64)
            - 10_000 * 86400;
        insert_with_fields(&conn, "ancient inference", very_old, 1.0, 0, None);

        decay_unverified_confidence_on_conn(&conn, 0.5).unwrap();

        let conf: f64 = conn
            .query_row("SELECT confidence FROM chump_memory", [], |r| r.get(0))
            .unwrap();
        // Floor is 0.05 — the row should still be retrievable, just heavily down-weighted.
        assert!(
            (conf - 0.05).abs() < 0.001,
            "floor should be 0.05; got {}",
            conf
        );
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn decay_zero_rate_is_noop() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        insert_with_fields(&conn, "today's note", now, 1.0, 0, None);
        // Caller passes 5.0 — should clamp to 0.5. With ts == now, days_since
        // is 0 so the multiplier is 1.0 either way and confidence is unchanged.
        let updated = decay_unverified_confidence_on_conn(&conn, 5.0).unwrap();
        assert_eq!(
            updated, 0,
            "today's row → 0 days → no change regardless of rate"
        );
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn curate_all_combines_all_three_passes() {
        let (path, conn) = fresh_curation_db();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        insert_with_fields(&conn, "fresh fact", now, 1.0, 1, None);

        let first = curate_all_on_conn(&conn, 0.01).unwrap();
        let second = curate_all_on_conn(&conn, 0.01).unwrap();
        assert_eq!(first.total_changed(), 0);
        assert_eq!(second.total_changed(), 0);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn curation_report_total_changed_sums() {
        let r = CurationReport {
            expired: 2,
            deduped_exact: 3,
            decayed: 5,
            summaries_created: 0,
            episodics_summarized: 0,
        };
        assert_eq!(r.total_changed(), 10);
        assert_eq!(CurationReport::default().total_changed(), 0);
    }

    #[test]
    fn decay_rate_env_clamps_within_range() {
        std::env::set_var("CHUMP_MEMORY_DECAY_RATE", "0.05");
        assert!((decay_rate_from_env() - 0.05).abs() < 1e-9);
        std::env::set_var("CHUMP_MEMORY_DECAY_RATE", "10.0");
        assert!(
            (decay_rate_from_env() - 0.5).abs() < 1e-9,
            "should clamp to 0.5 max"
        );
        std::env::set_var("CHUMP_MEMORY_DECAY_RATE", "-1.0");
        assert!(
            (decay_rate_from_env() - 0.0).abs() < 1e-9,
            "should clamp to 0 min"
        );
        std::env::set_var("CHUMP_MEMORY_DECAY_RATE", "garbage");
        assert!((decay_rate_from_env() - DEFAULT_DECAY_RATE_PER_DAY).abs() < 1e-9);
        std::env::remove_var("CHUMP_MEMORY_DECAY_RATE");
    }

    // ── Reranker tests ─────────────────────────────────────────────────
    //
    // The reranker is a pure function over a (MemoryRow, f64) batch —
    // doesn't touch the DB. Tests use synthetic MemoryRows. The goal is to
    // verify the score composition does what the docs promise: BM25
    // dominates, verified is a meaningful tiebreaker, recency is a minor
    // nudge.

    fn row(id: i64, content: &str, confidence: f64, verified: i32) -> MemoryRow {
        MemoryRow {
            id,
            content: content.to_string(),
            ts: "2026-04-16T00:00:00Z".to_string(),
            source: "test".to_string(),
            confidence,
            verified,
            sensitivity: "internal".to_string(),
            expires_at: None,
            memory_type: "semantic_fact".to_string(),
        }
    }

    #[test]
    fn rerank_empty_input_returns_empty() {
        let out = rerank_memories(vec![]);
        assert!(out.is_empty());
    }

    #[test]
    fn rerank_single_input_unchanged() {
        let out = rerank_memories(vec![(row(1, "x", 0.5, 0), -1.0)]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, 1);
    }

    #[test]
    fn rerank_better_bm25_wins_when_other_signals_equal() {
        // Two rows with identical verified/confidence/recency; only BM25
        // differs. Row A has stronger BM25 (more negative = better match).
        let a = (row(1, "a", 0.5, 0), -5.0);
        let b = (row(2, "b", 0.5, 0), -1.0);
        // Note: row 2 has higher id = more recent. If BM25 wins, row 1 is
        // returned first despite being older.
        let out = rerank_memories(vec![b, a]);
        assert_eq!(
            out[0].content, "a",
            "stronger BM25 should win even against newer unverified row"
        );
    }

    #[test]
    fn rerank_verified_beats_unverified_at_same_bm25() {
        // Same BM25, same recency. Row B is verified; should rank first.
        let a = (row(1, "a", 0.5, 0), -2.0);
        let b = (row(2, "b", 0.5, 1), -2.0);
        let out = rerank_memories(vec![a.clone(), b.clone()]);
        assert_eq!(
            out[0].content, "b",
            "verified fact should beat unverified at same relevance"
        );
    }

    #[test]
    fn rerank_higher_confidence_wins_at_equal_signals() {
        // Equal BM25, same verified status, same recency.
        let a = (row(1, "low", 0.30, 0), -2.0);
        let b = (row(2, "high", 0.90, 0), -2.0);
        // Row 2 is also more recent — but we're testing confidence tiebreak.
        // Give them very close IDs so recency contribution is minimal and
        // confidence dominates within the tiebreak.
        let out = rerank_memories(vec![a, b]);
        assert_eq!(out[0].content, "high", "higher confidence should win");
    }

    #[test]
    fn rerank_identical_scores_returns_stable_order() {
        // All four signals identical across rows. Reranker should not panic
        // and should return all rows exactly once.
        let a = (row(1, "a", 0.5, 0), -2.0);
        let b = (row(2, "b", 0.5, 0), -2.0);
        let c = (row(3, "c", 0.5, 0), -2.0);
        let out = rerank_memories(vec![a, b, c]);
        assert_eq!(out.len(), 3);
        let mut names: Vec<&str> = out.iter().map(|r| r.content.as_str()).collect();
        names.sort();
        assert_eq!(names, vec!["a", "b", "c"]);
    }

    #[test]
    fn rerank_handles_nan_bm25_gracefully() {
        // Shouldn't happen in practice (FTS5 rank is always finite), but
        // a NaN from a degenerate index shouldn't panic.
        let a = (row(1, "a", 0.5, 0), f64::NAN);
        let b = (row(2, "b", 0.5, 0), -2.0);
        let out = rerank_memories(vec![a, b]);
        assert_eq!(out.len(), 2);
    }

    #[test]
    #[serial_test::serial]
    fn rerank_weights_default_when_env_unset() {
        std::env::remove_var("CHUMP_RETRIEVAL_RERANK_WEIGHTS");
        let w = rerank_weights();
        assert!((w.bm25 - 0.50).abs() < 1e-9);
        assert!((w.verified - 0.25).abs() < 1e-9);
        assert!((w.confidence - 0.15).abs() < 1e-9);
        assert!((w.recency - 0.10).abs() < 1e-9);
    }

    #[test]
    #[serial_test::serial]
    fn rerank_weights_parse_override() {
        std::env::set_var("CHUMP_RETRIEVAL_RERANK_WEIGHTS", "0.3,0.3,0.2,0.2");
        let w = rerank_weights();
        assert!((w.bm25 - 0.3).abs() < 1e-9);
        assert!((w.verified - 0.3).abs() < 1e-9);
        assert!((w.confidence - 0.2).abs() < 1e-9);
        assert!((w.recency - 0.2).abs() < 1e-9);
        std::env::remove_var("CHUMP_RETRIEVAL_RERANK_WEIGHTS");
    }

    #[test]
    #[serial_test::serial]
    fn rerank_weights_reject_wrong_count() {
        // 3 values, not 4 — fall back to defaults.
        std::env::set_var("CHUMP_RETRIEVAL_RERANK_WEIGHTS", "0.3,0.3,0.2");
        let w = rerank_weights();
        assert!((w.bm25 - 0.50).abs() < 1e-9);
        std::env::remove_var("CHUMP_RETRIEVAL_RERANK_WEIGHTS");
    }

    #[test]
    #[serial_test::serial]
    fn rerank_weights_reject_negative() {
        std::env::set_var("CHUMP_RETRIEVAL_RERANK_WEIGHTS", "0.3,-0.1,0.2,0.2");
        let w = rerank_weights();
        // Falls back to default.
        assert!((w.bm25 - 0.50).abs() < 1e-9);
        std::env::remove_var("CHUMP_RETRIEVAL_RERANK_WEIGHTS");
    }

    // ── LLM summarization (MEM-003) ────────────────────────────────────

    fn episodic_row(id: i64, content: &str, source: &str, ts_epoch: i64) -> MemoryRow {
        MemoryRow {
            id,
            content: content.to_string(),
            ts: ts_epoch.to_string(),
            source: source.to_string(),
            confidence: 0.8,
            verified: 0,
            sensitivity: "internal".to_string(),
            expires_at: None,
            memory_type: "episodic_event".to_string(),
        }
    }

    fn semantic_row(id: i64, content: &str, ts_epoch: i64) -> MemoryRow {
        let mut r = episodic_row(id, content, "brain", ts_epoch);
        r.memory_type = "semantic_fact".to_string();
        r
    }

    #[test]
    fn cluster_selection_respects_min_age() {
        let now = 1_700_000_000_i64;
        let one_day = 86_400_i64;
        let rows = vec![
            episodic_row(1, "a1", "discord", now - one_day),
            episodic_row(2, "a2", "discord", now - one_day),
            episodic_row(3, "a3", "discord", now - one_day),
            episodic_row(4, "a4", "discord", now - one_day),
            episodic_row(5, "a5", "discord", now - one_day),
            episodic_row(10, "b1", "web", now - 60 * one_day),
            episodic_row(11, "b2", "web", now - 60 * one_day),
            episodic_row(12, "b3", "web", now - 60 * one_day),
            episodic_row(13, "b4", "web", now - 60 * one_day),
            episodic_row(14, "b5", "web", now - 60 * one_day),
        ];
        let config = SummarizationConfig {
            min_cluster_size: 3,
            min_age_days: 30,
            max_clusters_per_pass: 10,
        };
        let clusters = select_episodic_clusters_from_rows(&rows, config, now);
        assert_eq!(clusters.len(), 1);
        assert!(clusters[0].cluster_id.starts_with("web::m"));
        assert_eq!(clusters[0].memories.len(), 5);
    }

    #[test]
    fn cluster_selection_respects_min_cluster_size() {
        let now = 1_700_000_000_i64;
        let old = now - 60 * 86_400;
        let rows = vec![
            episodic_row(1, "x", "src1", old),
            episodic_row(2, "y", "src1", old),
        ];
        let clusters =
            select_episodic_clusters_from_rows(&rows, SummarizationConfig::default(), now);
        assert!(clusters.is_empty(), "too-small clusters should be dropped");
    }

    #[test]
    fn cluster_selection_ignores_non_episodic() {
        let now = 1_700_000_000_i64;
        let old = now - 60 * 86_400;
        let rows = vec![
            episodic_row(1, "e1", "src", old),
            episodic_row(2, "e2", "src", old),
            semantic_row(3, "s1", old),
            semantic_row(4, "s2", old),
            semantic_row(5, "s3", old),
        ];
        let config = SummarizationConfig {
            min_cluster_size: 2,
            min_age_days: 30,
            max_clusters_per_pass: 10,
        };
        let clusters = select_episodic_clusters_from_rows(&rows, config, now);
        assert_eq!(clusters.len(), 1);
        assert_eq!(clusters[0].memories.len(), 2);
    }

    #[test]
    fn cluster_selection_groups_by_source_and_age_bucket() {
        let now = 1_700_000_000_i64;
        let rows = vec![
            episodic_row(1, "d1", "discord", now - 35 * 86_400),
            episodic_row(2, "d2", "discord", now - 35 * 86_400),
            episodic_row(3, "d3", "discord", now - 35 * 86_400),
            episodic_row(4, "d4", "discord", now - 95 * 86_400),
            episodic_row(5, "d5", "discord", now - 95 * 86_400),
            episodic_row(6, "d6", "discord", now - 95 * 86_400),
        ];
        let config = SummarizationConfig {
            min_cluster_size: 2,
            min_age_days: 30,
            max_clusters_per_pass: 10,
        };
        let clusters = select_episodic_clusters_from_rows(&rows, config, now);
        assert_eq!(clusters.len(), 2, "two age buckets → two clusters");
        assert!(clusters[0].memories[0].id <= clusters[1].memories[0].id);
    }

    #[test]
    fn cluster_selection_caps_at_max_clusters_per_pass() {
        let now = 1_700_000_000_i64;
        let old = now - 60 * 86_400;
        let mut rows = vec![];
        for src_idx in 0..5 {
            let src = format!("src{}", src_idx);
            for r in 0..3 {
                rows.push(episodic_row((src_idx * 10 + r) as i64 + 1, "c", &src, old));
            }
        }
        let config = SummarizationConfig {
            min_cluster_size: 2,
            min_age_days: 30,
            max_clusters_per_pass: 2,
        };
        let clusters = select_episodic_clusters_from_rows(&rows, config, now);
        assert_eq!(clusters.len(), 2, "should cap at max_clusters_per_pass");
    }

    #[test]
    #[serial_test::serial]
    fn summarize_does_nothing_when_flag_unset() {
        std::env::remove_var("CHUMP_MEMORY_LLM_SUMMARIZE");
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE chump_memory (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT, ts TEXT, source TEXT,
                confidence REAL, verified INTEGER, sensitivity TEXT,
                expires_at TEXT, memory_type TEXT
            );
            CREATE VIRTUAL TABLE memory_fts USING fts5(content, content='chump_memory', content_rowid='id');",
        ).unwrap();
        let mut called = 0;
        let (s, c) = summarize_old_episodics_with(&conn, SummarizationConfig::default(), |_| {
            called += 1;
            Ok(SummarizationOutput {
                semantic_fact: "nope".into(),
                tokens_used: 0,
            })
        })
        .unwrap();
        assert_eq!(s, 0);
        assert_eq!(c, 0);
        assert_eq!(called, 0, "summarizer must not run when flag unset");
    }

    #[test]
    #[serial_test::serial]
    fn summarize_inserts_semantic_fact_and_expires_source() {
        std::env::set_var("CHUMP_MEMORY_LLM_SUMMARIZE", "1");
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE chump_memory (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT, ts TEXT, source TEXT,
                confidence REAL, verified INTEGER, sensitivity TEXT,
                expires_at TEXT, memory_type TEXT
            );
            CREATE VIRTUAL TABLE memory_fts USING fts5(content, content='chump_memory', content_rowid='id');",
        ).unwrap();
        let now_epoch: i64 = conn
            .query_row("SELECT CAST(strftime('%s','now') AS INTEGER)", [], |r| {
                r.get(0)
            })
            .unwrap();
        let old = now_epoch - 60 * 86_400;
        for i in 1..=5 {
            conn.execute(
                "INSERT INTO chump_memory (content, ts, source, confidence, verified, sensitivity, memory_type) \
                 VALUES (?1, ?2, 'discord', 0.8, 0, 'internal', 'episodic_event')",
                rusqlite::params![format!("event {}", i), old.to_string()],
            ).unwrap();
        }

        let (s, c) = summarize_old_episodics_with(
            &conn,
            SummarizationConfig {
                min_cluster_size: 3,
                min_age_days: 30,
                max_clusters_per_pass: 5,
            },
            |input| {
                assert!(input.memories.len() >= 3);
                Ok(SummarizationOutput {
                    semantic_fact: format!(
                        "distilled summary of {} events from {}",
                        input.memories.len(),
                        input.cluster_id
                    ),
                    tokens_used: 42,
                })
            },
        )
        .unwrap();
        assert_eq!(s, 1);
        assert_eq!(c, 5);

        let row_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM chump_memory WHERE memory_type = 'semantic_fact' AND content LIKE 'distilled%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(row_count, 1);

        let expired_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM chump_memory WHERE memory_type = 'episodic_event' AND expires_at IS NOT NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(expired_count, 5);

        std::env::remove_var("CHUMP_MEMORY_LLM_SUMMARIZE");
    }

    #[test]
    #[serial_test::serial]
    fn summarize_skips_cluster_when_summarizer_errors() {
        std::env::set_var("CHUMP_MEMORY_LLM_SUMMARIZE", "1");
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE chump_memory (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT, ts TEXT, source TEXT,
                confidence REAL, verified INTEGER, sensitivity TEXT,
                expires_at TEXT, memory_type TEXT
            );
            CREATE VIRTUAL TABLE memory_fts USING fts5(content, content='chump_memory', content_rowid='id');",
        ).unwrap();
        let now_epoch: i64 = conn
            .query_row("SELECT CAST(strftime('%s','now') AS INTEGER)", [], |r| {
                r.get(0)
            })
            .unwrap();
        let old = now_epoch - 60 * 86_400;
        for _ in 0..3 {
            conn.execute(
                "INSERT INTO chump_memory (content, ts, source, confidence, verified, sensitivity, memory_type) \
                 VALUES ('event', ?1, 'x', 0.8, 0, 'internal', 'episodic_event')",
                rusqlite::params![old.to_string()],
            ).unwrap();
        }
        let (s, c) = summarize_old_episodics_with(
            &conn,
            SummarizationConfig {
                min_cluster_size: 2,
                min_age_days: 30,
                max_clusters_per_pass: 1,
            },
            |_| Err(anyhow::anyhow!("simulated provider failure")),
        )
        .unwrap();
        assert_eq!(s, 0);
        assert_eq!(c, 0, "error must NOT orphan-expire source rows");
        std::env::remove_var("CHUMP_MEMORY_LLM_SUMMARIZE");
    }

    #[test]
    #[serial_test::serial]
    fn summarize_skips_empty_output() {
        std::env::set_var("CHUMP_MEMORY_LLM_SUMMARIZE", "1");
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE chump_memory (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT, ts TEXT, source TEXT,
                confidence REAL, verified INTEGER, sensitivity TEXT,
                expires_at TEXT, memory_type TEXT
            );
            CREATE VIRTUAL TABLE memory_fts USING fts5(content, content='chump_memory', content_rowid='id');",
        ).unwrap();
        let now_epoch: i64 = conn
            .query_row("SELECT CAST(strftime('%s','now') AS INTEGER)", [], |r| {
                r.get(0)
            })
            .unwrap();
        let old = now_epoch - 60 * 86_400;
        for _ in 0..3 {
            conn.execute(
                "INSERT INTO chump_memory (content, ts, source, confidence, verified, sensitivity, memory_type) \
                 VALUES ('event', ?1, 'x', 0.8, 0, 'internal', 'episodic_event')",
                rusqlite::params![old.to_string()],
            ).unwrap();
        }
        let (s, c) = summarize_old_episodics_with(
            &conn,
            SummarizationConfig {
                min_cluster_size: 2,
                min_age_days: 30,
                max_clusters_per_pass: 1,
            },
            |_| {
                Ok(SummarizationOutput {
                    semantic_fact: "   ".into(),
                    tokens_used: 0,
                })
            },
        )
        .unwrap();
        assert_eq!(s, 0, "whitespace-only summaries should be rejected");
        assert_eq!(c, 0);
        std::env::remove_var("CHUMP_MEMORY_LLM_SUMMARIZE");
    }

    #[test]
    #[serial_test::serial]
    fn summarization_config_parses_env_overrides() {
        std::env::set_var("CHUMP_MEMORY_SUMMARIZE_MIN_CLUSTER", "10");
        std::env::set_var("CHUMP_MEMORY_SUMMARIZE_MIN_AGE_DAYS", "90");
        std::env::set_var("CHUMP_MEMORY_SUMMARIZE_MAX_CLUSTERS", "7");
        let cfg = SummarizationConfig::from_env();
        assert_eq!(cfg.min_cluster_size, 10);
        assert_eq!(cfg.min_age_days, 90);
        assert_eq!(cfg.max_clusters_per_pass, 7);
        std::env::remove_var("CHUMP_MEMORY_SUMMARIZE_MIN_CLUSTER");
        std::env::remove_var("CHUMP_MEMORY_SUMMARIZE_MIN_AGE_DAYS");
        std::env::remove_var("CHUMP_MEMORY_SUMMARIZE_MAX_CLUSTERS");
    }

    #[test]
    #[serial_test::serial]
    fn summarization_config_rejects_min_cluster_below_2() {
        std::env::set_var("CHUMP_MEMORY_SUMMARIZE_MIN_CLUSTER", "1");
        let cfg = SummarizationConfig::from_env();
        assert_eq!(
            cfg.min_cluster_size,
            SummarizationConfig::default().min_cluster_size
        );
        std::env::remove_var("CHUMP_MEMORY_SUMMARIZE_MIN_CLUSTER");
    }

    #[test]
    fn curation_report_totals_include_summarization_fields() {
        let r = CurationReport {
            expired: 1,
            deduped_exact: 2,
            decayed: 3,
            summaries_created: 4,
            episodics_summarized: 5,
        };
        assert_eq!(r.total_changed(), 15);
    }

    #[test]
    fn memory_curate_summarizes_old_episodic_cluster() {
        let dir = std::env::temp_dir().join(format!(
            "chump_curate_summarize_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = fs::create_dir_all(&dir);
        let db_file = dir.join(DB_FILENAME);
        let conn = setup_curate_db(&db_file);

        // 4 episodic entries from 60 days ago (same month bucket) — exceeds MIN_EPISODE_CLUSTER.
        let old_ts = "2025-02-01 00:00:00";
        for i in 0..4 {
            insert_row(
                &conn,
                &format!("old episode {i}"),
                old_ts,
                0.7,
                0,
                "episodic_memory",
            );
        }
        // 2 episodic entries from 60 days ago in a different month — below threshold; should NOT be summarized.
        let old_ts2 = "2025-03-15 00:00:00";
        insert_row(&conn, "episode A", old_ts2, 0.5, 0, "episodic_memory");
        insert_row(&conn, "episode B", old_ts2, 0.5, 0, "episodic_memory");
        // 1 recent episodic entry — should NOT be touched.
        insert_row(
            &conn,
            "recent episode",
            "2026-04-01 00:00:00",
            0.9,
            0,
            "episodic_memory",
        );

        drop(conn);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let result = memory_curate().unwrap();
        assert_eq!(
            result.summarized, 4,
            "4 old entries from Feb should be summarized"
        );

        let conn2 = open_memory_db_file(&db_file).unwrap();
        // Feb entries gone; replaced by 1 semantic_fact; Mar entries remain; recent entry remains.
        let semantic_facts: Vec<String> = conn2
            .prepare("SELECT content FROM chump_memory WHERE memory_type = 'semantic_fact'")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();
        assert_eq!(
            semantic_facts.len(),
            1,
            "one summary semantic_fact created for Feb cluster"
        );
        assert!(
            semantic_facts[0].contains("[episodic summary 2025-02]"),
            "summary has month label"
        );
        assert!(
            semantic_facts[0].contains("old episode"),
            "summary contains episode content"
        );

        let episodic_remaining: i64 = conn2
            .query_row(
                "SELECT COUNT(*) FROM chump_memory WHERE memory_type = 'episodic_memory'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            episodic_remaining, 3,
            "Mar (2) + recent (1) episodic entries remain"
        );

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let _ = fs::remove_dir_all(dir);
    }
}
