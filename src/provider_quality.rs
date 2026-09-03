//! Per-slot quality (success vs sanity_fail) for cascade. Phase 3a: record on each call;
//! skip slots with rolling sanity-fail rate >10% in first_available_slot.

use crate::db_pool;
use anyhow::Result;

const SANITY_FAIL_RATE_THRESHOLD: f64 = 0.10;

/// Full quality row: success, sanity_fail, latency p50/p95, tool_call_accuracy.
pub type QualityFullRow = (i64, i64, Option<f64>, Option<f64>, Option<f64>);

fn upsert_quality(
    conn: &rusqlite::Connection,
    slot_name: &str,
    success_delta: i64,
    sanity_fail_delta: i64,
) -> Result<()> {
    conn.execute(
        "INSERT INTO chump_provider_quality (slot_name, success_count, sanity_fail_count, last_updated)
         VALUES (?1, ?2, ?3, datetime('now'))
         ON CONFLICT(slot_name) DO UPDATE SET
           success_count = success_count + excluded.success_count,
           sanity_fail_count = sanity_fail_count + excluded.sanity_fail_count,
           last_updated = datetime('now')",
        rusqlite::params![slot_name, success_delta, sanity_fail_delta],
    )?;
    Ok(())
}

pub fn record_slot_success(slot_name: &str) {
    if let Err(e) = db_pool::get().and_then(|conn| upsert_quality(&conn, slot_name, 1, 0)) {
        tracing::warn!("provider_quality: failed to record success for {slot_name}: {e}");
    }
}

pub fn record_slot_failure(slot_name: &str) {
    if slot_name.is_empty() || slot_name == "unknown" {
        return;
    }
    if let Err(e) = db_pool::get().and_then(|conn| upsert_quality(&conn, slot_name, 0, 1)) {
        tracing::warn!("provider_quality: failed to record failure for {slot_name}: {e}");
    }
}

/// CREDIBLE-227: record a 429 (rate-limited) response for this slot, separate
/// from generic sanity failures. Called alongside `record_slot_failure` when
/// the failover reason classifies as "429".
pub fn record_slot_rate_limited(slot_name: &str) {
    if slot_name.is_empty() || slot_name == "unknown" {
        return;
    }
    if let Err(e) = db_pool::get().and_then(|conn| {
        conn.execute(
            "UPDATE chump_provider_quality SET rate_limited_count = rate_limited_count + 1, last_updated = datetime('now') WHERE slot_name = ?1",
            rusqlite::params![slot_name],
        )?;
        Ok(())
    }) {
        tracing::warn!("provider_quality: failed to record rate_limited for {slot_name}: {e}");
    }
}

/// CREDIBLE-227 AC #5: close the loop between observed quality signals and
/// the declared RPD ceiling. `provider_quality` already records 429s
/// (`rate_limited_count`) but nothing compared that back to the configured
/// daily cap. A slot that has been 429ing repeatedly while its total
/// recorded call volume (success + sanity_fail) is well under its declared
/// RPD is evidence the declared number is wrong (too high) — return a
/// human-readable finding describing the mismatch so the caller can holler
/// (ambient event -> gap) instead of silently trusting the declared value.
pub fn declared_rpd_evidence(slot_name: &str, declared_rpd: u32) -> Option<String> {
    if declared_rpd == 0 {
        return None; // 0 = unlimited, nothing to compare against
    }
    const MIN_RATE_LIMITED_SAMPLES: i64 = 5;
    let conn = db_pool::get().ok()?;
    let (success, sanity_fail, rate_limited): (i64, i64, i64) = conn
        .query_row(
            "SELECT success_count, sanity_fail_count, rate_limited_count FROM chump_provider_quality WHERE slot_name = ?1",
            rusqlite::params![slot_name],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .ok()?;
    if rate_limited < MIN_RATE_LIMITED_SAMPLES {
        return None;
    }
    let total_calls = success + sanity_fail;
    let half_declared = (declared_rpd as i64) / 2;
    if total_calls < half_declared {
        Some(format!(
            "slot {slot_name} hit 429 {rate_limited} times while total observed calls ({total_calls}) stayed under half its declared RPD ({declared_rpd}) — declared RPD is likely too high"
        ))
    } else {
        None
    }
}

/// True if this slot should be skipped due to high sanity-fail rate (>10%).
pub fn should_skip_slot(slot_name: &str) -> bool {
    let conn = match db_pool::get() {
        Ok(c) => c,
        Err(_) => return false,
    };
    let (success, sanity_fail): (i64, i64) = match conn.query_row(
        "SELECT success_count, sanity_fail_count FROM chump_provider_quality WHERE slot_name = ?1",
        rusqlite::params![slot_name],
        |r| Ok((r.get(0)?, r.get(1)?)),
    ) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let total = success + sanity_fail;
    if total < 5 {
        return false;
    }
    (sanity_fail as f64 / total as f64) > SANITY_FAIL_RATE_THRESHOLD
}

pub fn get_quality(slot_name: &str) -> Option<(i64, i64)> {
    let conn = db_pool::get().ok()?;
    conn.query_row(
        "SELECT success_count, sanity_fail_count FROM chump_provider_quality WHERE slot_name = ?1",
        rusqlite::params![slot_name],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .ok()
}

/// Full quality row for /api/cascade-status (Phase 5c). Returns (success, sanity_fail, latency_p50, latency_p95, tool_call_accuracy).
pub fn get_quality_full(slot_name: &str) -> Option<QualityFullRow> {
    let conn = db_pool::get().ok()?;
    conn.query_row(
        "SELECT success_count, sanity_fail_count, latency_ms_p50, latency_ms_p95, tool_call_accuracy FROM chump_provider_quality WHERE slot_name = ?1",
        rusqlite::params![slot_name],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2).ok(), r.get(3).ok(), r.get(4).ok())),
    )
    .ok()
}

const LATENCY_ALPHA: f64 = 0.1;

/// Record latency for EMA of p50/p95. Call after each successful completion. Row must exist (from record_slot_success).
/// Also records into the per-slot request history ring buffer (PRODUCT-055).
pub fn record_latency(slot_name: &str, latency_ms: f64) {
    if slot_name.is_empty() {
        return;
    }
    // PRODUCT-055: append to per-slot request history (tokens_out unknown at this callsite).
    record_request_history(slot_name, latency_ms, 0);
    if let Err(e) = db_pool::get().and_then(|conn| {
        let (old_p50, old_p95): (Option<f64>, Option<f64>) = conn
            .query_row(
                "SELECT latency_ms_p50, latency_ms_p95 FROM chump_provider_quality WHERE slot_name = ?1",
                rusqlite::params![slot_name],
                |r| Ok((r.get(0).ok().flatten(), r.get(1).ok().flatten())),
            )
            .ok()
            .unwrap_or((None, None));
        let new_p50 = old_p50.map(|p| LATENCY_ALPHA * latency_ms + (1.0 - LATENCY_ALPHA) * p).unwrap_or(latency_ms);
        let new_p95 = old_p95.map(|p| LATENCY_ALPHA * latency_ms + (1.0 - LATENCY_ALPHA) * p).unwrap_or(latency_ms);
        conn.execute(
            "UPDATE chump_provider_quality SET latency_ms_p50 = ?1, latency_ms_p95 = ?2, last_updated = datetime('now') WHERE slot_name = ?3",
            rusqlite::params![new_p50, new_p95, slot_name],
        )?;
        Ok(())
    }) {
        tracing::warn!("provider_quality: failed to record latency for {slot_name}: {e}");
    }
}

/// Record tool-call parse success (1.0) or failure (0.0) for accuracy EMA.
pub fn record_tool_call_result(slot_name: &str, success: bool) {
    if slot_name.is_empty() {
        return;
    }
    if let Err(e) = db_pool::get().and_then(|conn| {
        let old: Option<f64> = conn
            .query_row(
                "SELECT tool_call_accuracy FROM chump_provider_quality WHERE slot_name = ?1",
                rusqlite::params![slot_name],
                |r| Ok(r.get::<_, Option<f64>>(0).ok().flatten()),
            )
            .ok()
            .flatten();
        let val = if success { 1.0 } else { 0.0 };
        let new_acc = old.map(|p| LATENCY_ALPHA * val + (1.0 - LATENCY_ALPHA) * p).unwrap_or(val);
        conn.execute(
            "UPDATE chump_provider_quality SET tool_call_accuracy = ?1, last_updated = datetime('now') WHERE slot_name = ?2",
            rusqlite::params![new_acc, slot_name],
        )?;
        Ok(())
    }) {
        tracing::warn!("provider_quality: failed to record tool_call_accuracy for {slot_name}: {e}");
    }
}

/// PRODUCT-055: a single entry in the per-slot request history ring buffer.
#[derive(Debug, serde::Serialize)]
pub struct SlotRequestEntry {
    pub latency_ms: f64,
    pub tokens_out: i64,
    pub recorded_at: String,
}

/// PRODUCT-055: Record a single inference request into the per-slot history ring buffer.
/// Keeps only the most recent 10 rows per slot (older rows are pruned after insert).
/// `latency_ms`: wall-clock from request start to first token or completion.
/// `tokens_out`: output tokens from the response (0 when unavailable).
pub fn record_request_history(slot_name: &str, latency_ms: f64, tokens_out: i64) {
    if slot_name.is_empty() {
        return;
    }
    if let Err(e) = db_pool::get().and_then(|conn| {
        conn.execute(
            "INSERT INTO chump_slot_request_history (slot_name, latency_ms, tokens_out) VALUES (?1, ?2, ?3)",
            rusqlite::params![slot_name, latency_ms, tokens_out],
        )?;
        // Prune to last 10 rows per slot (ring buffer).
        conn.execute(
            "DELETE FROM chump_slot_request_history
             WHERE slot_name = ?1
               AND id NOT IN (
                 SELECT id FROM chump_slot_request_history
                 WHERE slot_name = ?1
                 ORDER BY recorded_at DESC
                 LIMIT 10
               )",
            rusqlite::params![slot_name],
        )?;
        Ok(())
    }) {
        tracing::warn!("provider_quality: failed to record request history for {slot_name}: {e}");
    }
}

/// PRODUCT-055: Return up to the last 10 request entries for a slot (newest first).
pub fn get_request_history(slot_name: &str) -> Vec<SlotRequestEntry> {
    let conn = match db_pool::get() {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let mut stmt = match conn.prepare(
        "SELECT latency_ms, tokens_out, recorded_at
         FROM chump_slot_request_history
         WHERE slot_name = ?1
         ORDER BY recorded_at DESC
         LIMIT 10",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    stmt.query_map(rusqlite::params![slot_name], |r| {
        Ok(SlotRequestEntry {
            latency_ms: r.get(0)?,
            tokens_out: r.get(1)?,
            recorded_at: r.get(2)?,
        })
    })
    .ok()
    .map(|rows| rows.flatten().collect())
    .unwrap_or_default()
}

/// Effective priority for cascade sort: demoted slots (sanity-fail >10%) get +10 so they are tried last.
pub fn demotion_offset(slot_name: &str) -> u32 {
    if should_skip_slot(slot_name) {
        10
    } else {
        0
    }
}
