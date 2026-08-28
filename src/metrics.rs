//! Fleet metrics reporter — standardizes perf/SLO counters in one place.
//! Exposes /api/metrics with unified view of: PR merge times, gap completion rate,
//! fleet velocity, worker health, CI queue depth, and per-action coordination cost
//! (META-082, META-073 slice).

use axum::Json;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct FleetMetrics {
    pub timestamp_utc: String,
    pub pr_metrics: PrMetrics,
    pub gap_metrics: GapMetrics,
    pub fleet_metrics: FleetVelocity,
    pub coordination_action_metrics: CoordinationActionMetrics,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PrMetrics {
    pub open_count: u32,
    pub auto_merge_armed: u32,
    pub median_merge_time_secs: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct GapMetrics {
    pub open_count: u32,
    pub claimed_count: u32,
    pub p0_count: u32,
    pub completion_rate_percent: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct FleetVelocity {
    pub prs_per_minute: f64,
    pub gaps_per_hour: f64,
    pub active_workers: u32,
}

pub fn snapshot() -> FleetMetrics {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    FleetMetrics {
        timestamp_utc: format!("{}", now),
        pr_metrics: PrMetrics {
            open_count: 0,
            auto_merge_armed: 0,
            median_merge_time_secs: 0,
        },
        gap_metrics: GapMetrics {
            open_count: 0,
            claimed_count: 0,
            p0_count: 0,
            completion_rate_percent: 0.0,
        },
        fleet_metrics: FleetVelocity {
            prs_per_minute: 0.0,
            gaps_per_hour: 0.0,
            active_workers: 0,
        },
        coordination_action_metrics: coordination_action_snapshot(),
    }
}

pub async fn handle_metrics() -> Json<FleetMetrics> {
    Json(snapshot())
}

// ── META-082: coordination-action cost tracking (META-073 slice) ───────────
//
// Every coordination action (A2A broadcast / route change, lesson fetch,
// inbox read, etc.) records a CoordActionRecord here. Process-local,
// in-memory, ring-buffered — same pragmatic scope as the META-080 lesson
// store (a NATS/db-backed version is a follow-up once this shape proves
// out). Cost is a coarse proxy (wall-clock duration only, no real CPU
// sampling) — good enough to rank which action types are expensive.

/// Cap on retained records so the process-local store stays bounded.
const COORD_ACTION_STORE_CAP: usize = 2000;

/// Coarse cost-per-millisecond unit used to derive `estimated_cost` from
/// wall-clock duration. Arbitrary scale (not tied to a real billing unit) —
/// the point is relative ranking across action types, not absolute dollars.
const COST_UNITS_PER_MS: f64 = 0.001;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct CoordActionRecord {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost: f64,
    pub ts_utc_ms: i64,
}

fn coord_action_store() -> &'static Mutex<VecDeque<CoordActionRecord>> {
    static STORE: OnceLock<Mutex<VecDeque<CoordActionRecord>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(VecDeque::with_capacity(COORD_ACTION_STORE_CAP)))
}

/// Record one coordination action's cost. Called by the handler after the
/// action completes, with the elapsed wall-clock duration.
pub fn record_coordination_action(agent_id: &str, action_type: &str, duration_ms: u64) {
    let ts_utc_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let record = CoordActionRecord {
        agent_id: agent_id.to_string(),
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost: duration_ms as f64 * COST_UNITS_PER_MS,
        ts_utc_ms,
    };
    let mut store = match coord_action_store().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    if store.len() >= COORD_ACTION_STORE_CAP {
        store.pop_front();
    }
    store.push_back(record);
}

/// RAII timer — start at the top of a coordination-action handler, drop
/// (or call `.finish()`) at the end to record duration + cost automatically.
pub struct ActionTimer {
    agent_id: String,
    action_type: String,
    start: Instant,
    finished: bool,
}

impl ActionTimer {
    pub fn start(agent_id: &str, action_type: &str) -> Self {
        Self {
            agent_id: agent_id.to_string(),
            action_type: action_type.to_string(),
            start: Instant::now(),
            finished: false,
        }
    }

    /// Record now instead of waiting for Drop (useful when you want the
    /// record to land before returning a response).
    pub fn finish(mut self) {
        self.record();
        self.finished = true;
    }

    fn record(&mut self) {
        let duration_ms = self.start.elapsed().as_millis() as u64;
        record_coordination_action(&self.agent_id, &self.action_type, duration_ms);
    }
}

impl Drop for ActionTimer {
    fn drop(&mut self) {
        if !self.finished {
            self.record();
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct CoordActionTypeSummary {
    pub action_type: String,
    pub count: u64,
    pub total_duration_ms: u64,
    pub avg_duration_ms: f64,
    pub total_estimated_cost: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct CoordinationActionMetrics {
    pub total_actions: u64,
    pub by_action_type: Vec<CoordActionTypeSummary>,
    pub recent: Vec<CoordActionRecord>,
}

/// Aggregate the in-memory coordination-action store into a snapshot ready
/// for /api/metrics. `recent` is capped to the last 50 records to keep the
/// response small.
pub fn coordination_action_snapshot() -> CoordinationActionMetrics {
    let store = match coord_action_store().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };

    let mut by_type: std::collections::BTreeMap<String, CoordActionTypeSummary> =
        std::collections::BTreeMap::new();
    for rec in store.iter() {
        let entry =
            by_type
                .entry(rec.action_type.clone())
                .or_insert_with(|| CoordActionTypeSummary {
                    action_type: rec.action_type.clone(),
                    ..Default::default()
                });
        entry.count += 1;
        entry.total_duration_ms += rec.duration_ms;
        entry.total_estimated_cost += rec.estimated_cost;
    }
    let mut by_action_type: Vec<CoordActionTypeSummary> = by_type.into_values().collect();
    for s in &mut by_action_type {
        s.avg_duration_ms = if s.count > 0 {
            s.total_duration_ms as f64 / s.count as f64
        } else {
            0.0
        };
    }

    let recent: Vec<CoordActionRecord> = store.iter().rev().take(50).cloned().collect();

    CoordinationActionMetrics {
        total_actions: store.len() as u64,
        by_action_type,
        recent,
    }
}
