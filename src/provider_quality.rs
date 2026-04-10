//! Per-slot quality (success vs sanity_fail) for cascade. Phase 3a: record on each call;
//! skip slots with rolling sanity-fail rate >10% in first_available_slot.

use crate::db_pool;
use anyhow::Result;

const SANITY_FAIL_RATE_THRESHOLD: f64 = 0.10;

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
    let _ = db_pool::get().and_then(|conn| upsert_quality(&conn, slot_name, 1, 0));
}

pub fn record_slot_failure(slot_name: &str) {
    if slot_name.is_empty() || slot_name == "unknown" {
        return;
    }
    let _ = db_pool::get().and_then(|conn| upsert_quality(&conn, slot_name, 0, 1));
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

#[allow(dead_code)]
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
pub fn get_quality_full(
    slot_name: &str,
) -> Option<(i64, i64, Option<f64>, Option<f64>, Option<f64>)> {
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
pub fn record_latency(slot_name: &str, latency_ms: f64) {
    if slot_name.is_empty() {
        return;
    }
    let _ = db_pool::get().and_then(|conn| {
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
    });
}

/// Record tool-call parse success (1.0) or failure (0.0) for accuracy EMA.
#[allow(dead_code)]
pub fn record_tool_call_result(slot_name: &str, success: bool) {
    if slot_name.is_empty() {
        return;
    }
    let _ = db_pool::get().and_then(|conn| {
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
    });
}

/// Effective priority for cascade sort: demoted slots (sanity-fail >10%) get +10 so they are tried last.
pub fn demotion_offset(slot_name: &str) -> u32 {
    if should_skip_slot(slot_name) {
        10
    } else {
        0
    }
}
