//! Thermodynamic precision controller: dynamically adjusts agent behavior parameters
//! based on prediction error history, implementing the exploration/exploitation trade-off
//! from Active Inference and Thermodynamic AI.
//!
//! When surprisal is high (environment is unpredictable), the agent increases exploration:
//! more tool calls, more questions, escalation to capable models.
//! When surprisal is low (environment is predictable), the agent exploits:
//! fewer tool calls, decisive action, cheaper/faster models.
//!
//! Also implements energy budget tracking: treats API tokens, tool calls, and time
//! as a finite energy budget and optimizes allocation.
//!
//! Part of the Synthetic Consciousness Framework, Phase 5.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Precision regime: how the agent should behave given current surprisal levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrecisionRegime {
    /// Low surprisal: act decisively, use fast/cheap models, minimal exploration.
    Exploit,
    /// Moderate surprisal: balanced behavior.
    Balanced,
    /// High surprisal: explore more, use capable models, gather more information.
    Explore,
    /// Very high surprisal: conservative mode, seek human guidance.
    Conservative,
}

impl std::fmt::Display for PrecisionRegime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PrecisionRegime::Exploit => write!(f, "exploit"),
            PrecisionRegime::Balanced => write!(f, "balanced"),
            PrecisionRegime::Explore => write!(f, "explore"),
            PrecisionRegime::Conservative => write!(f, "conservative"),
        }
    }
}

/// Thresholds for regime transitions (surprisal EMA values).
/// Override via `CHUMP_EXPLOIT_THRESHOLD`, `CHUMP_BALANCED_THRESHOLD`, `CHUMP_EXPLORE_THRESHOLD`.
const EXPLOIT_THRESHOLD: f64 = 0.15;
const BALANCED_THRESHOLD: f64 = 0.35;
const EXPLORE_THRESHOLD: f64 = 0.60;

fn exploit_threshold() -> f64 {
    std::env::var("CHUMP_EXPLOIT_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(EXPLOIT_THRESHOLD)
}

fn balanced_threshold() -> f64 {
    std::env::var("CHUMP_BALANCED_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(BALANCED_THRESHOLD)
}

fn explore_threshold() -> f64 {
    std::env::var("CHUMP_EXPLORE_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(EXPLORE_THRESHOLD)
}

/// Rolling task outcomes for optional regime adaptation (`CHUMP_ADAPTIVE_REGIME=1`).
/// Override window size via `CHUMP_ADAPTIVE_OUTCOME_WINDOW`.
const ADAPTIVE_OUTCOME_WINDOW: usize = 16;

fn adaptive_outcome_window() -> usize {
    std::env::var("CHUMP_ADAPTIVE_OUTCOME_WINDOW")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(ADAPTIVE_OUTCOME_WINDOW)
}

/// Base exploit threshold (env-configurable). Used by `neuromodulation` for NA scaling.
pub fn base_exploit_threshold() -> f64 {
    exploit_threshold()
}

/// Base balanced threshold (env-configurable). Used by `neuromodulation` for NA scaling.
pub fn base_balanced_threshold() -> f64 {
    balanced_threshold()
}

/// Base explore threshold (env-configurable). Used by `neuromodulation` for NA scaling.
pub fn base_explore_threshold() -> f64 {
    explore_threshold()
}

static ADAPTIVE_OUTCOMES: OnceLock<Mutex<VecDeque<bool>>> = OnceLock::new();

fn adaptive_outcomes_queue() -> &'static Mutex<VecDeque<bool>> {
    ADAPTIVE_OUTCOMES.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn adaptive_regime_env_on() -> bool {
    // Accept both CHUMP_ADAPTIVE_REGIME (legacy) and CHUMP_ADAPTIVE_REGIMES (COG-003 canonical).
    crate::env_flags::env_trim_eq("CHUMP_ADAPTIVE_REGIME", "1")
        || crate::env_flags::env_trim_eq("CHUMP_ADAPTIVE_REGIMES", "1")
}

// COG-003: learned threshold delta, updated via gradient descent on recent task success rate.
// Positive delta raises all thresholds (favor Explore); negative lowers them (favor Exploit).
static ADAPTIVE_THRESHOLD_DELTA: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

/// Read the current learned threshold delta (as f64 stored as bits).
pub fn adaptive_threshold_delta() -> f64 {
    f64::from_bits(ADAPTIVE_THRESHOLD_DELTA.load(Ordering::Relaxed))
}

fn set_adaptive_threshold_delta(v: f64) {
    ADAPTIVE_THRESHOLD_DELTA.store(v.to_bits(), Ordering::Relaxed);
}

/// Record a terminal task outcome when `CHUMP_ADAPTIVE_REGIME(S)=1` (e.g. from `task_db`).
/// Recent successes nudge the effective surprisal **down** (favor exploit); failures nudge up.
/// COG-003: also applies online gradient update to learned threshold delta.
pub fn record_task_outcome_for_regime(success: bool) {
    if !adaptive_regime_env_on() {
        return;
    }
    if let Ok(mut q) = adaptive_outcomes_queue().lock() {
        if q.len() >= adaptive_outcome_window() {
            q.pop_front();
        }
        q.push_back(success);

        // COG-003: gradient update on learned threshold delta.
        // Success rate > 0.6 → lower thresholds (confidence → Exploit).
        // Success rate < 0.4 → raise thresholds (uncertainty → Explore).
        // Learning rate 0.005; clamp delta to ±0.3 to prevent runaway.
        const LR: f64 = 0.005;
        let rate = q.iter().filter(|x| **x).count() as f64 / q.len() as f64;
        let gradient = 0.5 - rate; // positive when failing → push toward Explore
        let delta = adaptive_threshold_delta() + gradient * LR;
        set_adaptive_threshold_delta(delta.clamp(-0.3, 0.3));
    }
}

fn adaptive_surprisal_nudge() -> f64 {
    if !adaptive_regime_env_on() {
        return 0.0;
    }
    let q = match adaptive_outcomes_queue().lock() {
        Ok(g) => g,
        Err(_) => return 0.0,
    };
    if q.is_empty() {
        return 0.0;
    }
    let successes = q.iter().filter(|x| **x).count() as f64;
    let rate = successes / q.len() as f64;
    // High success rate → negative nudge (treat EMA as calmer → easier Exploit).
    (0.5 - rate) * 0.1
}

/// Determine the current precision regime based on surprisal EMA.
pub fn current_regime() -> PrecisionRegime {
    regime_for_surprisal(0.0_f64)
}

fn regime_for_surprisal(ema: f64) -> PrecisionRegime {
    let ema_eff = (ema + adaptive_surprisal_nudge()).max(0.0);
    // COG-003: apply learned threshold delta when adaptive regimes are enabled.
    let thr_delta = if adaptive_regime_env_on() {
        adaptive_threshold_delta()
    } else {
        0.0
    };
    let et = (crate::neuromodulation::modulated_exploit_threshold() + thr_delta).max(0.0);
    let bt = (crate::neuromodulation::modulated_balanced_threshold() + thr_delta).max(0.0);
    let xt = (crate::neuromodulation::modulated_explore_threshold() + thr_delta).max(0.0);
    if ema_eff < et {
        PrecisionRegime::Exploit
    } else if ema_eff < bt {
        PrecisionRegime::Balanced
    } else if ema_eff < xt {
        PrecisionRegime::Explore
    } else {
        PrecisionRegime::Conservative
    }
}

#[cfg(test)]
pub(crate) fn test_reset_adaptive_regime_outcomes() {
    if let Ok(mut q) = adaptive_outcomes_queue().lock() {
        q.clear();
    }
    set_adaptive_threshold_delta(0.0);
}

/// Model tier recommendation based on precision regime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelTier {
    /// Fast/cheap model (local, small)
    Fast,
    /// Standard model (default configured)
    Standard,
    /// Capable model (larger, more expensive)
    Capable,
}

impl std::fmt::Display for ModelTier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ModelTier::Fast => write!(f, "fast"),
            ModelTier::Standard => write!(f, "standard"),
            ModelTier::Capable => write!(f, "capable"),
        }
    }
}

/// Recommend which model tier to use based on current precision regime.
pub fn recommended_model_tier() -> ModelTier {
    match current_regime() {
        PrecisionRegime::Exploit => ModelTier::Fast,
        PrecisionRegime::Balanced => ModelTier::Standard,
        PrecisionRegime::Explore => ModelTier::Capable,
        PrecisionRegime::Conservative => ModelTier::Capable,
    }
}

/// Whether the current regime suggests escalation to a more capable model.
pub fn should_escalate_model() -> bool {
    matches!(recommended_model_tier(), ModelTier::Capable)
}

/// Recommended maximum **parallel** `delegate` batch workers (`CHUMP_DELEGATE_MAX_PARALLEL`, default 4).
/// When **`CHUMP_BELIEF_TOOL_BUDGET`** is on and task uncertainty is high, uses the same **3/4** tightening
/// as [`recommended_max_tool_calls`] (WP-6.1).
pub fn recommended_max_delegate_parallel() -> usize {
    let configured = std::env::var("CHUMP_DELEGATE_MAX_PARALLEL")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (1..=32).contains(&n))
        .unwrap_or(4);
    let mut n = configured;
    if crate::env_flags::chump_belief_tool_budget() {
        let u = crate::belief_state::task_belief().uncertainty();
        if u > 0.55 {
            n = (n * 3 / 4).max(1);
        }
    }
    n
}

/// Recommended maximum tool calls per turn based on regime, modulated by serotonin.
/// When **`CHUMP_BELIEF_TOOL_BUDGET=1`** (or `true`), high **task** uncertainty
/// (`belief_state::task_belief().uncertainty()` > 0.55) tightens the cap (~25% reduction, min 1) — WP-6.1.
pub fn recommended_max_tool_calls() -> u32 {
    let base = match current_regime() {
        PrecisionRegime::Exploit => 3,
        PrecisionRegime::Balanced => 5,
        PrecisionRegime::Explore => 8,
        PrecisionRegime::Conservative => 4,
    };
    let multiplier = crate::neuromodulation::tool_budget_multiplier();
    let mut cap = ((base as f64 * multiplier).round() as u32).max(1);
    if crate::env_flags::chump_belief_tool_budget() {
        let u = crate::belief_state::task_belief().uncertainty();
        if u > 0.55 {
            cap = (cap.saturating_mul(3) / 4).max(1);
        }
    }
    cap
}

/// Recommended context budget allocation (fraction of total context to allocate to
/// dynamic/exploratory content vs fixed content).
///
/// Scaled by [`crate::neuromodulation::context_exploration_multiplier`] (WP-6.2).
pub fn context_exploration_budget() -> f64 {
    let base = match current_regime() {
        PrecisionRegime::Exploit => 0.2,
        PrecisionRegime::Balanced => 0.35,
        PrecisionRegime::Explore => 0.5,
        PrecisionRegime::Conservative => 0.3,
    };
    let m = crate::neuromodulation::context_exploration_multiplier();
    (base * m).clamp(0.08, 0.65)
}

// --- Energy Budget Tracking ---

static ENERGY_BUDGET_TOKENS: AtomicU64 = AtomicU64::new(0);
static ENERGY_BUDGET_TOOL_CALLS: AtomicU64 = AtomicU64::new(0);
static ENERGY_SPENT_TOKENS: AtomicU64 = AtomicU64::new(0);
static ENERGY_SPENT_TOOL_CALLS: AtomicU64 = AtomicU64::new(0);
static ESCALATION_COUNT: AtomicU64 = AtomicU64::new(0);
static TOTAL_MODEL_DECISIONS: AtomicU64 = AtomicU64::new(0);

/// Set the energy budget for the current session/task.
pub fn set_energy_budget(max_tokens: u64, max_tool_calls: u64) {
    ENERGY_BUDGET_TOKENS.store(max_tokens, Ordering::Relaxed);
    ENERGY_BUDGET_TOOL_CALLS.store(max_tool_calls, Ordering::Relaxed);
}

/// Initialize energy budget from env vars (CHUMP_SESSION_ENERGY_TOKENS, CHUMP_SESSION_ENERGY_TOOLS).
/// Called once at session start. No-ops if env vars are not set.
pub fn init_energy_budget_from_env() {
    let tokens = std::env::var("CHUMP_SESSION_ENERGY_TOKENS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(0);
    let tools = std::env::var("CHUMP_SESSION_ENERGY_TOOLS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(0);
    if tokens > 0 || tools > 0 {
        set_energy_budget(tokens, tools);
    }
}

/// Seed the precision controller from the user's BehaviorRegime (PRODUCT-003).
/// Called once at session start after user_profile is loaded.
///
/// Mapping:
/// - Autonomous → lower surprisal thresholds (stay in Exploit/Balanced longer; trust own work)
/// - Frequent    → raise thresholds (more Explore/Conservative; check in more)
/// - Async       → default thresholds (no override)
///
/// Risk tolerance feeds energy budget: High → generous budget, Low → tight.
pub fn seed_from_behavior_regime(regime: &crate::user_profile::BehaviorRegime) {
    use crate::user_profile::{CheckinFrequency, RiskTolerance};
    match regime.checkin_frequency {
        CheckinFrequency::Autonomous => {
            // Bias toward Exploit: raise thresholds so high surprisal is needed to escalate
            std::env::set_var("CHUMP_EXPLOIT_THRESHOLD", "0.25");
            std::env::set_var("CHUMP_BALANCED_THRESHOLD", "0.50");
            std::env::set_var("CHUMP_EXPLORE_THRESHOLD", "0.75");
        }
        CheckinFrequency::Frequent => {
            // Bias toward Conservative: lower thresholds so agent escalates sooner
            std::env::set_var("CHUMP_EXPLOIT_THRESHOLD", "0.08");
            std::env::set_var("CHUMP_BALANCED_THRESHOLD", "0.20");
            std::env::set_var("CHUMP_EXPLORE_THRESHOLD", "0.40");
        }
        CheckinFrequency::Async => {
            // Use defaults — no override needed
        }
    }
    // Risk tolerance → token/tool budget
    let (tokens, tools) = match regime.risk_tolerance {
        RiskTolerance::High => (200_000u64, 400u64),
        RiskTolerance::Medium => (100_000u64, 200u64),
        RiskTolerance::Low => (40_000u64, 80u64),
    };
    // Only apply if no explicit env override exists
    if std::env::var("CHUMP_SESSION_ENERGY_TOKENS").is_err() {
        set_energy_budget(tokens, tools);
    }
}

/// Record energy expenditure.
pub fn record_energy_spent(tokens: u64, tool_calls: u64) {
    ENERGY_SPENT_TOKENS.fetch_add(tokens, Ordering::Relaxed);
    ENERGY_SPENT_TOOL_CALLS.fetch_add(tool_calls, Ordering::Relaxed);
}

/// Record a model tier decision (for escalation rate tracking).
pub fn record_model_decision(tier: ModelTier) {
    TOTAL_MODEL_DECISIONS.fetch_add(1, Ordering::Relaxed);
    if tier == ModelTier::Capable {
        ESCALATION_COUNT.fetch_add(1, Ordering::Relaxed);
    }
}

/// Fraction of token budget remaining (0.0 = exhausted, 1.0 = full).
pub fn token_budget_remaining() -> f64 {
    let budget = ENERGY_BUDGET_TOKENS.load(Ordering::Relaxed);
    if budget == 0 {
        return 1.0; // No budget set = unlimited
    }
    let spent = ENERGY_SPENT_TOKENS.load(Ordering::Relaxed);
    if spent >= budget {
        0.0
    } else {
        (budget - spent) as f64 / budget as f64
    }
}

/// Fraction of tool call budget remaining.
pub fn tool_call_budget_remaining() -> f64 {
    let budget = ENERGY_BUDGET_TOOL_CALLS.load(Ordering::Relaxed);
    if budget == 0 {
        return 1.0;
    }
    let spent = ENERGY_SPENT_TOOL_CALLS.load(Ordering::Relaxed);
    if spent >= budget {
        0.0
    } else {
        (budget - spent) as f64 / budget as f64
    }
}

/// Whether the energy budget is critically low (< 15% remaining on either dimension).
pub fn budget_critical() -> bool {
    token_budget_remaining() < 0.15 || tool_call_budget_remaining() < 0.15
}

/// Model escalation rate: fraction of model decisions that resulted in escalation.
pub fn escalation_rate() -> f64 {
    let total = TOTAL_MODEL_DECISIONS.load(Ordering::Relaxed);
    if total == 0 {
        return 0.0;
    }
    ESCALATION_COUNT.load(Ordering::Relaxed) as f64 / total as f64
}

/// Summary string for context injection and health endpoint.
pub fn summary() -> String {
    let regime = current_regime();
    let tier = recommended_model_tier();
    let ema = 0.0_f64;
    let esc_rate = escalation_rate();
    let token_rem = token_budget_remaining();
    let tool_rem = tool_call_budget_remaining();
    format!(
        "regime: {}, model_tier: {}, surprisal: {:.3}, escalation_rate: {:.1}%, \
         energy: tokens={:.0}% tool_calls={:.0}%",
        regime,
        tier,
        ema,
        esc_rate * 100.0,
        token_rem * 100.0,
        tool_rem * 100.0,
    )
}

/// Adaptive parameters: a bundle of recommendations the agent loop can consume.
pub struct AdaptiveParams {
    pub regime: PrecisionRegime,
    pub model_tier: ModelTier,
    pub max_tool_calls: u32,
    pub context_exploration_fraction: f64,
    pub budget_critical: bool,
}

/// Get the current adaptive parameters bundle.
pub fn adaptive_params() -> AdaptiveParams {
    AdaptiveParams {
        regime: current_regime(),
        model_tier: recommended_model_tier(),
        max_tool_calls: recommended_max_tool_calls(),
        context_exploration_fraction: context_exploration_budget(),
        budget_critical: budget_critical(),
    }
}

// --- Noise-as-resource: epsilon-greedy exploration ---

/// Epsilon value for tool selection randomization, based on regime.
/// Higher epsilon = more random exploration.
pub fn exploration_epsilon() -> f64 {
    match current_regime() {
        PrecisionRegime::Exploit => 0.0,
        PrecisionRegime::Balanced => 0.05,
        PrecisionRegime::Explore => 0.15,
        PrecisionRegime::Conservative => 0.02,
    }
}

/// Given a ranked list of candidate tool names (best first), return the index
/// to select. With probability epsilon, picks a random non-first index.
/// Returns 0 (the best) most of the time; occasional random exploration in Explore.
pub fn epsilon_greedy_select(candidates_len: usize) -> usize {
    if candidates_len <= 1 {
        return 0;
    }
    let eps = exploration_epsilon();
    if eps <= 0.0 {
        return 0;
    }
    let roll: f64 = {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut h = DefaultHasher::new();
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            .hash(&mut h);
        (h.finish() % 10000) as f64 / 10000.0
    };
    if roll < eps {
        // Pick a random non-zero index
        let offset = (roll * 1000.0) as usize;
        1 + (offset % (candidates_len - 1))
    } else {
        0
    }
}

// --- Dissipation tracking: log compute cost per turn ---

static TURN_COUNTER: AtomicU64 = AtomicU64::new(0);

/// When false, optional swarm-only metrics (mesh RTT, delegate-worker surprisal) must not be recorded.
#[inline]
pub fn swarm_supplementary_metrics_enabled() -> bool {
    !crate::cluster_mesh::force_local_primary_execution()
}

/// Hook for future mesh / worker latency samples; no-op unless [`swarm_supplementary_metrics_enabled`].
pub fn record_swarm_latency_hint(_worker_rtt_ms: Option<u64>) {
    if swarm_supplementary_metrics_enabled() {
        // Future: persist mesh RTT / worker samples for swarm dashboards.
    }
}

/// Record the cost of a completed turn (dissipation = resource expenditure per unit of work).
pub fn record_turn_metrics(tool_calls: u32, tokens_spent: u64, duration_ms: u64) {
    let turn = TURN_COUNTER.fetch_add(1, Ordering::Relaxed);
    let regime = current_regime();
    let ema = 0.0_f64;

    // Dissipation rate: normalized cost per tool call (lower = more efficient).
    // Models thermodynamic efficiency: how much "energy" is spent per useful action.
    let dissipation = if tool_calls > 0 {
        (tokens_spent as f64 + duration_ms as f64 * 0.1) / tool_calls as f64
    } else {
        0.0
    };

    let session_id = crate::state_db::state_read("session_count")
        .ok()
        .flatten()
        .unwrap_or_else(|| "0".to_string());

    if let Ok(conn) = crate::db_pool::get() {
        let _ = conn.execute(
            "INSERT INTO chump_turn_metrics \
             (session_id, turn_number, tool_calls, tokens_spent, duration_ms, regime, surprisal_ema, dissipation_rate) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![
                session_id,
                turn,
                tool_calls,
                tokens_spent as i64,
                duration_ms as i64,
                regime.to_string(),
                ema,
                dissipation,
            ],
        );
    }
}

/// Post regime changes to the blackboard when they occur.
static LAST_REGIME: Mutex<Option<PrecisionRegime>> = Mutex::new(None);

pub fn check_regime_change() {
    let current = current_regime();
    let changed = if let Ok(mut last) = LAST_REGIME.lock() {
        let changed = last.is_none_or(|prev| prev != current);
        *last = Some(current);
        changed
    } else {
        false
    };

    if changed {
        crate::blackboard::post(
            crate::blackboard::Module::Custom("precision_controller".to_string()),
            format!(
                "Precision regime changed to '{}'. Model tier: {}",
                current,
                recommended_model_tier(),
            ),
            crate::blackboard::SalienceFactors {
                novelty: 0.9,
                uncertainty_reduction: 0.4,
                goal_relevance: 0.5,
                urgency: if current == PrecisionRegime::Conservative {
                    0.8
                } else {
                    0.3
                },
            },
        );
    }
}

// --- Vector 3: battle benchmark telemetry (model rounds, tool/CLI failures, duration) ---

#[derive(Debug)]
struct BattleSession {
    label: String,
    started: Instant,
}

static BATTLE_SESSION: OnceLock<Mutex<Option<BattleSession>>> = OnceLock::new();
static BATTLE_MODEL_ROUNDS: AtomicU32 = AtomicU32::new(0);
static BATTLE_TOOL_ERRORS: AtomicU32 = AtomicU32::new(0);

fn battle_session_cell() -> &'static Mutex<Option<BattleSession>> {
    BATTLE_SESSION.get_or_init(|| Mutex::new(None))
}

/// True when `CHUMP_BATTLE_BENCHMARK=1` (or `true`) — enables counters and optional DB persist.
pub fn battle_benchmark_env_on() -> bool {
    std::env::var("CHUMP_BATTLE_BENCHMARK")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Start a benchmark episode: reset counters and record wall-clock start + label.
pub fn battle_benchmark_begin(label: &str) {
    if !battle_benchmark_env_on() {
        return;
    }
    let label = label.trim();
    let label = if label.is_empty() {
        "battle".to_string()
    } else {
        label.to_string()
    };
    if let Ok(mut g) = battle_session_cell().lock() {
        *g = Some(BattleSession {
            label,
            started: Instant::now(),
        });
    }
    BATTLE_MODEL_ROUNDS.store(0, Ordering::Relaxed);
    BATTLE_TOOL_ERRORS.store(0, Ordering::Relaxed);
}

/// One successful outer `Provider::complete` (one orchestrator model step).
pub fn record_battle_benchmark_model_round() {
    if !battle_benchmark_env_on() {
        return;
    }
    let active = battle_session_cell()
        .lock()
        .ok()
        .map(|g| g.is_some())
        .unwrap_or(false);
    if !active {
        return;
    }
    BATTLE_MODEL_ROUNDS.fetch_add(1, Ordering::Relaxed);
}

/// Count tool failures: `Tool error:` (schema / executor), CLI-style failures on run_cli/git/cargo.
pub fn battle_note_tool_result(tool_name: &str, result: &str) {
    if !battle_benchmark_env_on() {
        return;
    }
    let active = battle_session_cell()
        .lock()
        .ok()
        .map(|g| g.is_some())
        .unwrap_or(false);
    if !active {
        return;
    }
    if result.starts_with("DENIED:") {
        return;
    }
    if result.starts_with("Tool error:") {
        BATTLE_TOOL_ERRORS.fetch_add(1, Ordering::Relaxed);
        return;
    }
    if battle_cli_style_failure(tool_name, result) {
        BATTLE_TOOL_ERRORS.fetch_add(1, Ordering::Relaxed);
    }
}

fn battle_cli_style_failure(tool: &str, result: &str) -> bool {
    let cli = tool.eq_ignore_ascii_case("run_cli")
        || tool.eq_ignore_ascii_case("git")
        || tool.eq_ignore_ascii_case("cargo")
        || tool.eq_ignore_ascii_case("run_test");
    if !cli {
        return false;
    }
    let lower = result.to_ascii_lowercase();
    if lower.contains("test result:") && lower.contains("failed") {
        return true;
    }
    if lower.contains("could not compile") || lower.contains("error[e") {
        return true;
    }
    if let Some(pos) = result.find("[exit status:") {
        let tail = &result[pos + "[exit status:".len()..];
        let num: String = tail
            .chars()
            .skip_while(|c| c.is_whitespace())
            .take_while(|c| c.is_ascii_digit() || *c == '-')
            .collect();
        if let Ok(n) = num.parse::<i32>() {
            if n != 0 {
                return true;
            }
        }
    }
    if lower.contains("exit code ") && !lower.contains("exit code 0") {
        return true;
    }
    false
}

/// Persist baseline row and optionally print a single JSON line for shell scripts (`CHUMP_BATTLE_PRINT_METRICS=1`).
pub fn battle_benchmark_finalize(last_reply: &str) {
    if !battle_benchmark_env_on() {
        return;
    }
    let session = if let Ok(mut g) = battle_session_cell().lock() {
        g.take()
    } else {
        None
    };
    let Some(s) = session else {
        return;
    };
    let turns = BATTLE_MODEL_ROUNDS.load(Ordering::Relaxed) as i64;
    let errs = BATTLE_TOOL_ERRORS.load(Ordering::Relaxed) as i64;
    let duration_ms = s.started.elapsed().as_millis() as i64;
    let done = last_reply.to_ascii_uppercase().contains("DONE");
    let extra = serde_json::json!({ "reply_contains_done": done }).to_string();

    if let Ok(conn) = crate::db_pool::get() {
        let _ = conn.execute(
            "INSERT INTO chump_battle_baselines \
             (label, turns_to_resolution, total_tool_errors, resolution_duration_ms, reply_contains_done, extra_json) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![
                s.label,
                turns,
                errs,
                duration_ms,
                if done { 1 } else { 0 },
                extra,
            ],
        );
    }

    if std::env::var("CHUMP_BATTLE_PRINT_METRICS")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        let line = serde_json::json!({
            "label": s.label,
            "turns_to_resolution": turns,
            "total_tool_errors": errs,
            "resolution_duration_ms": duration_ms,
            "reply_contains_done": done,
        });
        println!("CHUMP_BATTLE_BASELINE_JSON:{}", line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn test_regime_thresholds() {
        test_reset_adaptive_regime_outcomes();
        std::env::remove_var("CHUMP_ADAPTIVE_REGIME");
        assert_eq!(regime_for_surprisal(0.0), PrecisionRegime::Exploit);
        assert_eq!(regime_for_surprisal(0.10), PrecisionRegime::Exploit);
        assert_eq!(regime_for_surprisal(0.20), PrecisionRegime::Balanced);
        assert_eq!(regime_for_surprisal(0.40), PrecisionRegime::Explore);
        assert_eq!(regime_for_surprisal(0.80), PrecisionRegime::Conservative);
    }

    #[test]
    fn test_model_tier_for_regime() {
        // Verify the regime→tier mapping is correct (surprisal_ema removed per REMOVAL-002)
        assert_eq!(ModelTier::Fast.to_string(), "fast");
        assert_eq!(ModelTier::Standard.to_string(), "standard");
        assert_eq!(ModelTier::Capable.to_string(), "capable");
    }

    #[test]
    fn test_energy_budget() {
        // Set budget far above any possible pre-existing spent to isolate from other tests
        set_energy_budget(10_000_000, 100_000);
        // After setting huge budget, remaining should be very high
        assert!(
            token_budget_remaining() > 0.5,
            "token remaining should be high with huge budget"
        );
        assert!(
            tool_call_budget_remaining() > 0.5,
            "tool remaining should be high with huge budget"
        );
        assert!(!budget_critical());

        // Now set a tight budget close to current spent to test exhaustion
        let spent = ENERGY_SPENT_TOKENS.load(Ordering::Relaxed);
        let spent_tools = ENERGY_SPENT_TOOL_CALLS.load(Ordering::Relaxed);
        set_energy_budget(spent + 100, spent_tools + 5);
        // Should have ~100 tokens and ~5 tools of headroom
        record_energy_spent(90, 5);
        assert!(
            token_budget_remaining() < 0.15,
            "should be near exhausted: {:.3}",
            token_budget_remaining()
        );
        assert!(budget_critical());
    }

    #[test]
    fn test_escalation_rate() {
        // Reset is not easy with atomics, but we can test the logic
        let total = TOTAL_MODEL_DECISIONS.load(Ordering::Relaxed);
        let esc = ESCALATION_COUNT.load(Ordering::Relaxed);
        record_model_decision(ModelTier::Standard);
        record_model_decision(ModelTier::Capable);
        let new_total = TOTAL_MODEL_DECISIONS.load(Ordering::Relaxed);
        assert_eq!(new_total, total + 2);
        let new_esc = ESCALATION_COUNT.load(Ordering::Relaxed);
        assert_eq!(new_esc, esc + 1);
    }

    #[test]
    fn test_summary_format() {
        let s = summary();
        assert!(s.contains("regime:"));
        assert!(s.contains("model_tier:"));
        assert!(s.contains("energy:"));
    }

    #[test]
    fn test_adaptive_params() {
        let params = adaptive_params();
        // Bounds widened post-REMOVAL-002: neuromod multiplier + belief tightening can take
        // `recommended_max_tool_calls()` below the old raw-regime floor of 3.
        assert!(params.max_tool_calls >= 1 && params.max_tool_calls <= 16);
        assert!(
            params.context_exploration_fraction > 0.0 && params.context_exploration_fraction <= 1.0
        );
    }

    #[test]
    #[serial]
    fn battle_benchmark_counters_smoke() {
        std::env::set_var("CHUMP_BATTLE_BENCHMARK", "1");
        std::env::remove_var("CHUMP_BATTLE_PRINT_METRICS");
        battle_benchmark_begin("unit_smoke");
        record_battle_benchmark_model_round();
        battle_note_tool_result("calc", "Tool error: bad input");
        battle_note_tool_result("run_cli", "stderr\n[exit status: 1]\n");
        battle_benchmark_finalize("DONE");
        std::env::remove_var("CHUMP_BATTLE_BENCHMARK");
    }

    #[test]
    #[serial]
    fn test_adaptive_regime_records_only_when_env_on() {
        test_reset_adaptive_regime_outcomes();
        std::env::remove_var("CHUMP_ADAPTIVE_REGIME");
        record_task_outcome_for_regime(true);
        assert!(
            adaptive_outcomes_queue().lock().unwrap().is_empty(),
            "queue stays empty when env off"
        );

        std::env::set_var("CHUMP_ADAPTIVE_REGIME", "1");
        record_task_outcome_for_regime(false);
        assert_eq!(adaptive_outcomes_queue().lock().unwrap().len(), 1);

        test_reset_adaptive_regime_outcomes();
        std::env::remove_var("CHUMP_ADAPTIVE_REGIME");
    }

    /// COG-003: CHUMP_ADAPTIVE_REGIMES=1 alias works (plural env var).
    #[test]
    #[serial]
    fn adaptive_regimes_env_plural_accepted() {
        test_reset_adaptive_regime_outcomes();
        std::env::remove_var("CHUMP_ADAPTIVE_REGIME");
        std::env::set_var("CHUMP_ADAPTIVE_REGIMES", "1");
        record_task_outcome_for_regime(true);
        assert_eq!(
            adaptive_outcomes_queue().lock().unwrap().len(),
            1,
            "CHUMP_ADAPTIVE_REGIMES=1 must enable recording"
        );
        test_reset_adaptive_regime_outcomes();
        std::env::remove_var("CHUMP_ADAPTIVE_REGIMES");
    }

    /// COG-003: after 50 success outcomes, learned threshold delta converges negative (favor Exploit).
    #[test]
    #[serial]
    fn adaptive_threshold_converges_on_high_success_rate() {
        test_reset_adaptive_regime_outcomes();
        std::env::set_var("CHUMP_ADAPTIVE_REGIMES", "1");
        // 50 consecutive successes — delta should move negative (thresholds lower → more Exploit)
        for _ in 0..50 {
            record_task_outcome_for_regime(true);
        }
        let delta = adaptive_threshold_delta();
        assert!(
            delta < 0.0,
            "after 50 successes, threshold delta must be negative (converged toward Exploit), got {}",
            delta
        );
        test_reset_adaptive_regime_outcomes();
        std::env::remove_var("CHUMP_ADAPTIVE_REGIMES");
    }

    /// COG-003: after 50 failure outcomes, learned threshold delta converges positive (favor Explore).
    #[test]
    #[serial]
    fn adaptive_threshold_converges_on_high_failure_rate() {
        test_reset_adaptive_regime_outcomes();
        std::env::set_var("CHUMP_ADAPTIVE_REGIMES", "1");
        for _ in 0..50 {
            record_task_outcome_for_regime(false);
        }
        let delta = adaptive_threshold_delta();
        assert!(
            delta > 0.0,
            "after 50 failures, threshold delta must be positive (converged toward Explore), got {}",
            delta
        );
        test_reset_adaptive_regime_outcomes();
        std::env::remove_var("CHUMP_ADAPTIVE_REGIMES");
    }

    /// COG-003: delta stays clamped to [-0.3, 0.3].
    #[test]
    #[serial]
    fn adaptive_threshold_delta_is_clamped() {
        test_reset_adaptive_regime_outcomes();
        std::env::set_var("CHUMP_ADAPTIVE_REGIMES", "1");
        for _ in 0..1000 {
            record_task_outcome_for_regime(true);
        }
        let delta = adaptive_threshold_delta();
        assert!(
            (-0.3..=0.3).contains(&delta),
            "delta must stay clamped, got {}",
            delta
        );
        test_reset_adaptive_regime_outcomes();
        std::env::remove_var("CHUMP_ADAPTIVE_REGIMES");
    }

    #[test]
    #[serial]
    fn belief_tool_budget_tightens_under_high_uncertainty() {
        use crate::belief_state::{restore_from_snapshot, snapshot_inner, task_belief, TaskBelief};
        let snap = snapshot_inner();
        std::env::set_var("CHUMP_BELIEF_TOOL_BUDGET", "1");
        let base_cap = recommended_max_tool_calls();
        restore_from_snapshot(
            snap.0.clone(),
            TaskBelief {
                trajectory_confidence: 0.0,
                model_freshness: 0.0,
                streak_successes: 0,
                streak_failures: 10,
            },
        );
        assert!(
            task_belief().uncertainty() > 0.55,
            "fixture should be epistemically stressed"
        );
        let tight = recommended_max_tool_calls();
        let expected = (base_cap.saturating_mul(3) / 4).max(1);
        assert_eq!(
            tight, expected,
            "cap should tighten to 3/4 of regime base (min 1)"
        );
        restore_from_snapshot(snap.0, snap.1);
        std::env::remove_var("CHUMP_BELIEF_TOOL_BUDGET");
    }

    #[test]
    #[serial]
    fn belief_delegate_parallel_tightens_under_high_uncertainty() {
        use crate::belief_state::{restore_from_snapshot, snapshot_inner, task_belief, TaskBelief};
        let prev_dp = std::env::var("CHUMP_DELEGATE_MAX_PARALLEL").ok();
        std::env::set_var("CHUMP_DELEGATE_MAX_PARALLEL", "8");
        let snap = snapshot_inner();
        std::env::set_var("CHUMP_BELIEF_TOOL_BUDGET", "1");
        let base_par = recommended_max_delegate_parallel();
        assert_eq!(base_par, 8, "low uncertainty should keep env cap");
        restore_from_snapshot(
            snap.0.clone(),
            TaskBelief {
                trajectory_confidence: 0.0,
                model_freshness: 0.0,
                streak_successes: 0,
                streak_failures: 10,
            },
        );
        assert!(task_belief().uncertainty() > 0.55);
        let tight = recommended_max_delegate_parallel();
        assert_eq!(tight, 6, "8 * 3/4 = 6");
        restore_from_snapshot(snap.0, snap.1);
        std::env::remove_var("CHUMP_BELIEF_TOOL_BUDGET");
        match prev_dp {
            Some(ref s) => std::env::set_var("CHUMP_DELEGATE_MAX_PARALLEL", s),
            None => std::env::remove_var("CHUMP_DELEGATE_MAX_PARALLEL"),
        }
    }
}
