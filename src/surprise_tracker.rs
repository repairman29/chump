//! Prediction error tracking and surprise metrics (Active Inference foundation).
//!
//! Records what the agent predicted would happen vs what actually happened after
//! each tool call. Maintains a running exponential moving average of surprisal
//! to drive adaptive behavior in later phases (precision tuning, model escalation).
//!
//! Part of the Synthetic Consciousness Framework, Phase 1.

use anyhow::Result;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// EMA smoothing factor for surprisal (0..1). Lower = slower adaptation.
/// Override with CHUMP_SURPRISE_EMA_ALPHA env var.
fn ema_alpha() -> f64 {
    std::env::var("CHUMP_SURPRISE_EMA_ALPHA")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&v| v > 0.0 && v <= 1.0)
        .unwrap_or(0.1)
}

/// Global running EMA of surprisal, stored as f64 bits in an AtomicU64.
static SURPRISAL_EMA: AtomicU64 = AtomicU64::new(0);
static TOTAL_PREDICTIONS: AtomicU64 = AtomicU64::new(0);
static HIGH_SURPRISE_COUNT: AtomicU64 = AtomicU64::new(0);

/// Threshold (in standard deviations above mean) to flag as "high surprise".
const HIGH_SURPRISE_SIGMA: f64 = 2.0;

static VARIANCE_STATE: Mutex<Option<WelfordState>> = Mutex::new(None);

struct WelfordState {
    count: u64,
    mean: f64,
    m2: f64,
}

fn update_welford(value: f64) -> (f64, f64) {
    let mut guard = VARIANCE_STATE.lock().unwrap_or_else(|e| e.into_inner());
    let state = guard.get_or_insert(WelfordState {
        count: 0,
        mean: 0.0,
        m2: 0.0,
    });
    state.count += 1;
    let delta = value - state.mean;
    state.mean += delta / state.count as f64;
    let delta2 = value - state.mean;
    state.m2 += delta * delta2;
    let variance = if state.count > 1 {
        state.m2 / (state.count - 1) as f64
    } else {
        0.0
    };
    (state.mean, variance)
}

fn load_ema() -> f64 {
    f64::from_bits(SURPRISAL_EMA.load(Ordering::Relaxed))
}

fn store_ema(val: f64) {
    SURPRISAL_EMA.store(val.to_bits(), Ordering::Relaxed);
}

/// Compute a simple surprisal score from a tool call outcome.
///
/// Surprisal is modeled as:
/// - 0.0 for expected success (ok outcome)
/// - 1.0 for unexpected failure (error/timeout on a typically-reliable tool)
/// - 0.5 for partial surprise (slow response, degraded output)
///
/// Future phases can refine this with semantic comparison of expected vs actual output.
pub fn compute_surprisal(outcome: &str, latency_ms: u64, expected_latency_ms: u64) -> f64 {
    let outcome_surprise = match outcome {
        "ok" => 0.0,
        "timeout" => 1.0,
        "error" => 0.8,
        _ => 0.5,
    };

    let latency_ratio = if expected_latency_ms > 0 {
        latency_ms as f64 / expected_latency_ms as f64
    } else {
        1.0
    };
    let latency_surprise = if latency_ratio > 3.0 {
        0.5
    } else if latency_ratio > 1.5 {
        0.2
    } else {
        0.0
    };

    f64::min(outcome_surprise + latency_surprise, 1.0)
}

/// Record a prediction error observation, update EMA, and persist to DB.
pub fn record_prediction(
    tool_name: &str,
    outcome: &str,
    latency_ms: u64,
    expected_latency_ms: u64,
) {
    let surprisal = compute_surprisal(outcome, latency_ms, expected_latency_ms);

    let base_alpha = ema_alpha();
    let reward_scale = crate::neuromodulation::reward_scaling();
    let alpha = (base_alpha * reward_scale).min(1.0);
    let old_ema = load_ema();
    let new_ema = alpha * surprisal + (1.0 - alpha) * old_ema;
    store_ema(new_ema);

    TOTAL_PREDICTIONS.fetch_add(1, Ordering::Relaxed);

    let (mean, variance) = update_welford(surprisal);
    let stddev = variance.sqrt();
    if stddev > 0.0 && surprisal > mean + HIGH_SURPRISE_SIGMA * stddev {
        HIGH_SURPRISE_COUNT.fetch_add(1, Ordering::Relaxed);

        // Post high-surprise events to the global blackboard
        crate::blackboard::post(
            crate::blackboard::Module::SurpriseTracker,
            format!(
                "High prediction error on '{}': outcome={}, surprisal={:.2} (mean={:.2}, threshold={:.2})",
                tool_name, outcome, surprisal, mean, mean + HIGH_SURPRISE_SIGMA * stddev
            ),
            crate::blackboard::SalienceFactors {
                novelty: 0.9,
                uncertainty_reduction: 0.3,
                goal_relevance: 0.6,
                urgency: if outcome == "timeout" { 0.9 } else { 0.5 },
            },
        );
    }

    let _ = db_record_prediction(tool_name, outcome, latency_ms, surprisal);
}

/// Current surprisal EMA (0.0 = fully predictable, 1.0 = maximally surprising).
pub fn current_surprisal_ema() -> f64 {
    load_ema()
}

/// Total predictions recorded this session.
pub fn total_predictions() -> u64 {
    TOTAL_PREDICTIONS.load(Ordering::Relaxed)
}

/// Count of high-surprise events (> 2 sigma above mean).
pub fn high_surprise_count() -> u64 {
    HIGH_SURPRISE_COUNT.load(Ordering::Relaxed)
}

/// Percentage of predictions that were high-surprise.
pub fn high_surprise_pct() -> f64 {
    let total = total_predictions();
    if total == 0 {
        return 0.0;
    }
    high_surprise_count() as f64 / total as f64 * 100.0
}

/// Summary string for health endpoint and context injection.
pub fn summary() -> String {
    let ema = current_surprisal_ema();
    let total = total_predictions();
    let high = high_surprise_count();
    let pct = high_surprise_pct();
    format!(
        "surprisal EMA: {:.3}, total predictions: {}, high-surprise: {} ({:.1}%)",
        ema, total, high, pct
    )
}

// --- SQLite persistence ---

fn db_record_prediction(
    tool_name: &str,
    outcome: &str,
    latency_ms: u64,
    surprisal: f64,
) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_prediction_log (tool, outcome, latency_ms, surprisal) \
         VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![tool_name, outcome, latency_ms as i64, surprisal],
    )?;
    // Only prune when 10% over cap to avoid expensive DELETE on every insert
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM chump_prediction_log", [], |r| {
            r.get(0)
        })
        .unwrap_or(0);
    if count > 1100 {
        let _ = conn.execute(
            "DELETE FROM chump_prediction_log WHERE id NOT IN (
                SELECT id FROM chump_prediction_log ORDER BY id DESC LIMIT 1000
            )",
            [],
        );
    }
    Ok(())
}

/// Query recent prediction errors for a specific tool.
pub fn recent_predictions(tool_filter: Option<&str>, limit: usize) -> Result<Vec<PredictionRow>> {
    let conn = crate::db_pool::get()?;
    let limit = limit.min(100);
    if let Some(tool) = tool_filter {
        let mut stmt = conn.prepare(
            "SELECT id, tool, outcome, latency_ms, surprisal, recorded_at \
             FROM chump_prediction_log WHERE tool = ?1 ORDER BY id DESC LIMIT ?2",
        )?;
        let rows = stmt
            .query_map(rusqlite::params![tool, limit as i64], row_from_query)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    } else {
        let mut stmt = conn.prepare(
            "SELECT id, tool, outcome, latency_ms, surprisal, recorded_at \
             FROM chump_prediction_log ORDER BY id DESC LIMIT ?1",
        )?;
        let rows = stmt
            .query_map(rusqlite::params![limit as i64], row_from_query)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }
}

/// Mean surprisal per tool over recent history (for identifying consistently surprising tools).
pub fn mean_surprisal_by_tool(limit: usize) -> Result<Vec<(String, f64, u64)>> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT tool, AVG(surprisal), COUNT(*) FROM (
            SELECT tool, surprisal FROM chump_prediction_log ORDER BY id DESC LIMIT ?1
        ) GROUP BY tool ORDER BY AVG(surprisal) DESC",
    )?;
    let rows = stmt
        .query_map(rusqlite::params![limit as i64], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, f64>(1)?,
                r.get::<_, u64>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

#[derive(Debug, Clone)]
pub struct PredictionRow {
    pub id: i64,
    pub tool: String,
    pub outcome: String,
    pub latency_ms: i64,
    pub surprisal: f64,
    pub recorded_at: String,
}

fn row_from_query(r: &rusqlite::Row) -> Result<PredictionRow, rusqlite::Error> {
    Ok(PredictionRow {
        id: r.get(0)?,
        tool: r.get(1)?,
        outcome: r.get(2)?,
        latency_ms: r.get(3)?,
        surprisal: r.get(4)?,
        recorded_at: r.get(5)?,
    })
}

pub fn prediction_log_available() -> bool {
    crate::db_pool::get().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn test_compute_surprisal_ok() {
        let s = compute_surprisal("ok", 100, 200);
        assert!(s < 0.01, "ok within expected latency should be ~0");
    }

    #[test]
    fn test_compute_surprisal_timeout() {
        let s = compute_surprisal("timeout", 30000, 5000);
        assert!(s >= 0.9, "timeout should be high surprisal: {}", s);
    }

    #[test]
    fn test_compute_surprisal_slow_ok() {
        let s = compute_surprisal("ok", 10000, 2000);
        assert!(
            (0.1..=0.6).contains(&s),
            "ok but 5x latency should be moderate: {}",
            s
        );
    }

    #[test]
    fn test_ema_updates() {
        store_ema(0.0);
        let alpha = ema_alpha();
        let s1 = 0.8;
        let new = alpha * s1 + (1.0 - alpha) * 0.0;
        store_ema(new);
        assert!((load_ema() - (alpha * 0.8)).abs() < 0.001);
    }

    #[test]
    fn test_summary_format() {
        let s = summary();
        assert!(s.contains("surprisal EMA"));
        assert!(s.contains("total predictions"));
    }

    #[test]
    #[serial]
    fn reward_scaling_affects_ema_update() {
        let prev_alpha = std::env::var("CHUMP_SURPRISE_EMA_ALPHA").ok();
        std::env::set_var("CHUMP_SURPRISE_EMA_ALPHA", "0.5");
        store_ema(0.0);
        crate::neuromodulation::reset();
        crate::neuromodulation::restore(crate::neuromodulation::NeuromodState {
            dopamine: 1.5,
            noradrenaline: 1.0,
            serotonin: 1.0,
        });
        record_prediction("t", "timeout", 1000, 100);
        let high = current_surprisal_ema();
        store_ema(0.0);
        crate::neuromodulation::restore(crate::neuromodulation::NeuromodState {
            dopamine: 0.5,
            noradrenaline: 1.0,
            serotonin: 1.0,
        });
        record_prediction("t", "timeout", 1000, 100);
        let low = current_surprisal_ema();
        match prev_alpha {
            Some(ref v) => std::env::set_var("CHUMP_SURPRISE_EMA_ALPHA", v),
            None => std::env::remove_var("CHUMP_SURPRISE_EMA_ALPHA"),
        }
        crate::neuromodulation::reset();
        assert!(
            high > low + 1e-6,
            "higher dopamine should scale EMA alpha up: {} vs {}",
            high,
            low
        );
    }
}
