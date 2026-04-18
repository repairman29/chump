//! Background episode-to-blackboard extractor (MEM-005 / Phase 8.1).
//!
//! Scans recent [`crate::episode_db`] entries that have not yet been
//! processed and attempts to extract one durable fact per episode via the
//! delegate worker model.  Extracted facts are written directly to
//! `chump_blackboard_persist` so they survive session boundaries.
//!
//! ## Idempotency
//! A `chump_blackboard_cursor` row (singleton, `id=1`) tracks the highest
//! episode `id` that has been processed.  Re-running never re-extracts the
//! same episode.
//!
//! ## Size bounds
//! - At most `CHUMP_EXTRACT_BATCH` (default 20) episodes per invocation.
//! - Facts are truncated to `CHUMP_EXTRACT_FACT_CHARS` (default 500) chars.
//! - The `chump_blackboard_persist` table is pruned to 50 rows after each
//!   run (same limit as [`crate::blackboard::persist_high_salience`]).
//!
//! ## Enabling
//! Requires `CHUMP_DELEGATE_CONCURRENT=1` (safe concurrent LLM access) plus
//! the delegate worker to be configured (`CHUMP_WORKER_API_BASE` or
//! `OPENAI_API_BASE`).  When either condition is absent the function returns
//! `Ok(0)` immediately.
//!
//! ## CLI
//! Run one extraction pass with:
//! ```bash
//! chump --extract-episodes
//! ```

use anyhow::Result;
use tracing::{info, warn};

/// Default number of episodes to process in a single extraction pass.
const DEFAULT_BATCH_SIZE: usize = 20;
/// Default maximum character length for a persisted blackboard fact.
const DEFAULT_MAX_FACT_CHARS: usize = 500;
/// Salience assigned to automatically extracted blackboard entries.
const EXTRACTED_SALIENCE: f64 = 0.55;
/// Source tag written to `chump_blackboard_persist`.
const SOURCE_TAG: &str = "EpisodeExtractor";
/// Maximum rows kept in `chump_blackboard_persist` after pruning.
const PERSIST_ROW_CAP: usize = 50;

/// The delegate extract instruction used for every episode.
const EXTRACT_INSTRUCTION: &str = "Extract ONE durable fact, architectural \
    decision, or project rule that should be remembered between sessions. \
    Output only the fact as a single sentence. \
    If there is no durable fact worth preserving, reply with exactly: none";

fn batch_size() -> usize {
    std::env::var("CHUMP_EXTRACT_BATCH")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(DEFAULT_BATCH_SIZE)
}

fn max_fact_chars() -> usize {
    std::env::var("CHUMP_EXTRACT_FACT_CHARS")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(DEFAULT_MAX_FACT_CHARS)
}

/// True when extraction can proceed (delegate worker must be safe to call concurrently).
pub fn extraction_available() -> bool {
    crate::delegate_tool::concurrent_llm_safe()
}

// ---------------------------------------------------------------------------
// Cursor helpers
// ---------------------------------------------------------------------------

fn read_cursor(conn: &rusqlite::Connection) -> i64 {
    conn.query_row(
        "SELECT last_episode_id FROM chump_blackboard_cursor WHERE id = 1",
        [],
        |row| row.get(0),
    )
    .unwrap_or(0)
}

fn write_cursor(conn: &rusqlite::Connection, episode_id: i64) {
    let _ = conn.execute(
        "UPDATE chump_blackboard_cursor \
         SET last_episode_id = ?1, updated_at = datetime('now') \
         WHERE id = 1",
        rusqlite::params![episode_id],
    );
}

// ---------------------------------------------------------------------------
// Main extraction function
// ---------------------------------------------------------------------------

/// Extract durable facts from unprocessed episodes and write them to the
/// persisted blackboard.
///
/// Returns the number of blackboard entries written.  Returns `Ok(0)` when
/// the delegate worker is unavailable or there are no new episodes.
pub async fn extract_episodes_to_blackboard() -> Result<usize> {
    if !extraction_available() {
        info!("EpisodeExtractor: CHUMP_DELEGATE_CONCURRENT not set — skipping");
        return Ok(0);
    }

    let conn = crate::db_pool::get()?;
    let cursor_id = read_cursor(&conn);
    let batch = batch_size() as i64;

    // Fetch episodes after the cursor, oldest first.
    let mut stmt = conn.prepare(
        "SELECT id, summary, detail FROM chump_episodes \
         WHERE id > ?1 ORDER BY id ASC LIMIT ?2",
    )?;
    let episodes: Vec<(i64, String, Option<String>)> = stmt
        .query_map(rusqlite::params![cursor_id, batch], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;

    if episodes.is_empty() {
        info!("EpisodeExtractor: no new episodes since id={cursor_id}");
        return Ok(0);
    }

    info!(
        "EpisodeExtractor: processing {} episode(s) after id={}",
        episodes.len(),
        cursor_id
    );

    let max_chars = max_fact_chars();
    let mut written = 0usize;
    let mut last_id = cursor_id;

    for (id, summary, detail) in &episodes {
        let text = match detail.as_deref() {
            Some(d) if !d.trim().is_empty() => format!("{}\n{}", summary, d),
            _ => summary.clone(),
        };

        // Limit input to the worker to avoid context blowout.
        let capped_text: String = text.chars().take(3_000).collect();

        let fact = match crate::delegate_tool::run_delegate_extract(
            &capped_text,
            EXTRACT_INSTRUCTION,
        )
        .await
        {
            Ok(f) => f.trim().to_string(),
            Err(err) => {
                warn!(episode_id = id, err = %err, "EpisodeExtractor: delegate failed; skipping episode");
                last_id = *id;
                continue;
            }
        };

        last_id = *id;

        // Skip episodes where the worker found nothing worth persisting.
        if fact.is_empty() || fact.eq_ignore_ascii_case("none") {
            continue;
        }

        // Truncate to the configured char cap.
        let fact_stored: String = if fact.chars().count() > max_chars {
            format!(
                "{}…",
                fact.chars()
                    .take(max_chars.saturating_sub(1))
                    .collect::<String>()
            )
        } else {
            fact
        };

        match conn.execute(
            "INSERT INTO chump_blackboard_persist (source, content, salience) \
             VALUES (?1, ?2, ?3)",
            rusqlite::params![SOURCE_TAG, fact_stored, EXTRACTED_SALIENCE],
        ) {
            Ok(_) => {
                written += 1;
                info!(
                    episode_id = id,
                    "EpisodeExtractor: wrote fact to blackboard"
                );
            }
            Err(err) => {
                warn!(episode_id = id, err = %err, "EpisodeExtractor: DB insert failed");
            }
        }
    }

    // Prune: keep at most PERSIST_ROW_CAP rows by salience (matches persist_high_salience).
    let _ = conn.execute(
        &format!(
            "DELETE FROM chump_blackboard_persist \
             WHERE id NOT IN (SELECT id FROM chump_blackboard_persist \
                              ORDER BY salience DESC LIMIT {PERSIST_ROW_CAP})"
        ),
        [],
    );

    write_cursor(&conn, last_id);
    info!("EpisodeExtractor: wrote {written} fact(s); cursor advanced to id={last_id}");
    Ok(written)
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn batch_size_default() {
        std::env::remove_var("CHUMP_EXTRACT_BATCH");
        assert_eq!(batch_size(), DEFAULT_BATCH_SIZE);
    }

    #[test]
    #[serial]
    fn batch_size_reads_env() {
        std::env::set_var("CHUMP_EXTRACT_BATCH", "7");
        assert_eq!(batch_size(), 7);
        std::env::remove_var("CHUMP_EXTRACT_BATCH");
    }

    #[test]
    #[serial]
    fn max_fact_chars_default() {
        std::env::remove_var("CHUMP_EXTRACT_FACT_CHARS");
        assert_eq!(max_fact_chars(), DEFAULT_MAX_FACT_CHARS);
    }

    #[test]
    #[serial]
    fn extraction_unavailable_without_concurrent_flag() {
        std::env::remove_var("CHUMP_DELEGATE_CONCURRENT");
        assert!(!extraction_available());
    }

    #[test]
    #[serial]
    fn extraction_available_with_concurrent_flag() {
        std::env::set_var("CHUMP_DELEGATE_CONCURRENT", "1");
        assert!(extraction_available());
        std::env::remove_var("CHUMP_DELEGATE_CONCURRENT");
    }

    #[tokio::test]
    #[serial]
    async fn returns_zero_when_concurrent_not_set() {
        std::env::remove_var("CHUMP_DELEGATE_CONCURRENT");
        let result = extract_episodes_to_blackboard().await.unwrap();
        assert_eq!(result, 0);
    }

    #[test]
    fn cursor_roundtrip_in_memory_db() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        // Manually create the cursor table and seed row.
        conn.execute_batch(
            "CREATE TABLE chump_blackboard_cursor (
                id INTEGER PRIMARY KEY,
                last_episode_id INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            INSERT INTO chump_blackboard_cursor (id, last_episode_id) VALUES (1, 0);",
        )
        .unwrap();
        assert_eq!(read_cursor(&conn), 0);
        write_cursor(&conn, 42);
        assert_eq!(read_cursor(&conn), 42);
        write_cursor(&conn, 100);
        assert_eq!(read_cursor(&conn), 100);
    }
}
