//! Synthetic neuromodulation: system-wide "chemical" meta-parameters that
//! simultaneously shift precision weights, exploration rate, memory consolidation,
//! and temporal patience.
//!
//! Three modulators inspired by biological neurotransmitters:
//! - **Dopamine proxy**: reward sensitivity — scales how aggressively the system
//!   shifts regimes after successes/failures.
//! - **Noradrenaline proxy**: precision weight (γ) — scales exploitation pressure;
//!   high = tighter focus, low = broader exploration.
//! - **Serotonin proxy**: temporal discount — patience for multi-step plans vs
//!   immediate tool calls; high = willing to wait, low = impulsive.
//!
//! Each modulator is updated per-turn based on belief state, surprisal, and
//! task trajectory. They wire into precision_controller thresholds, tool budget
//! multipliers, blackboard salience weights, and context window allocation.
//!
//! Part of the Synthetic Consciousness Framework, Section 3.3.
//!
//! Heuristic interpretation (not biophysical claims): [NEUROMODULATION_HEURISTICS.md](../docs/research/NEUROMODULATION_HEURISTICS.md) (WP-6.2).

use std::io::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// The three synthetic neuromodulators (all clamped to [0.0, 2.0]).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct NeuromodState {
    /// Reward sensitivity. >1.0 = amplified reward/punishment signals.
    pub dopamine: f64,
    /// Precision weight. >1.0 = more exploitation; <1.0 = more exploration.
    pub noradrenaline: f64,
    /// Temporal patience. >1.0 = patient (multi-step OK); <1.0 = impulsive.
    pub serotonin: f64,
}

impl NeuromodState {
    fn baseline() -> Self {
        Self {
            dopamine: 1.0,
            noradrenaline: 1.0,
            serotonin: 1.0,
        }
    }

    fn clamp(&mut self) {
        self.dopamine = self.dopamine.clamp(0.1, 2.0);
        self.noradrenaline = self.noradrenaline.clamp(0.1, 2.0);
        self.serotonin = self.serotonin.clamp(0.1, 2.0);
    }
}

static STATE: std::sync::OnceLock<Mutex<NeuromodState>> = std::sync::OnceLock::new();
static TURN_COUNTER: AtomicU64 = AtomicU64::new(0);

fn state() -> &'static Mutex<NeuromodState> {
    STATE.get_or_init(|| Mutex::new(NeuromodState::baseline()))
}

/// Get a snapshot of the current neuromodulator levels.
pub fn levels() -> NeuromodState {
    state()
        .lock()
        .map(|g| g.clone())
        .unwrap_or_else(|_| NeuromodState::baseline())
}

/// COG-006 / EVAL-043 gate: when disabled, neuromod updates are skipped entirely.
/// Modulators stay at baseline (1.0/1.0/1.0) forever and all downstream consumers
/// (`modulated_*_threshold`, `tool_budget_multiplier`, `effective_tool_timeout_secs`, ...)
/// produce their unmodulated values. Used by the neuromod A/B harness to compare
/// task success with vs without modulator dynamics.
///
/// **Two ways to disable (either is sufficient):**
/// - `CHUMP_BYPASS_NEUROMOD=1` (or `true`) — EVAL-043 ablation convention, consistent with
///   other `CHUMP_BYPASS_*` flags.
/// - `CHUMP_NEUROMOD_ENABLED=0` (or `false`/`off`) — legacy COG-006 gate, still supported.
pub fn neuromod_enabled() -> bool {
    // EVAL-043: check CHUMP_BYPASS_NEUROMOD first (new convention).
    if crate::env_flags::chump_bypass_neuromod() {
        return false;
    }
    // COG-006: legacy gate.
    !matches!(
        std::env::var("CHUMP_NEUROMOD_ENABLED").as_deref(),
        Ok("0") | Ok("false") | Ok("off")
    )
}

/// Update neuromodulators based on the latest turn outcome.
///
/// Called once per turn after tool execution. Adjusts modulators based on:
/// - Surprisal EMA (environment predictability)
/// - Task belief trajectory (success/failure streaks)
/// - Energy budget remaining
///
/// Short-circuits to a no-op when `CHUMP_NEUROMOD_ENABLED=0` (COG-006 gate).
pub fn update_from_turn() {
    if !neuromod_enabled() {
        return;
    }
    let surprisal = 0.0_f64;
    let task = crate::belief_state::task_belief();
    let energy_remaining = crate::precision_controller::token_budget_remaining();

    if let Ok(mut guard) = state().lock() {
        // Dopamine: rises with success streaks (reward), drops with failures
        if task.streak_successes > 2 {
            guard.dopamine += 0.05 * task.streak_successes as f64;
        } else if task.streak_failures > 1 {
            guard.dopamine -= 0.08 * task.streak_failures as f64;
        } else {
            // Decay toward baseline
            guard.dopamine += (1.0 - guard.dopamine) * 0.05;
        }

        // Noradrenaline: inversely proportional to surprisal
        // High surprisal → low NA → more exploration
        // Low surprisal → high NA → more exploitation
        let target_na = 1.0 + (0.5 - surprisal);
        guard.noradrenaline += (target_na - guard.noradrenaline) * neuromod_na_alpha();

        // Serotonin: rises with trajectory confidence, drops under time pressure
        let patience_signal = task.trajectory_confidence - (1.0 - energy_remaining) * 0.5;
        let target_sero = 1.0 + patience_signal * 0.3;
        guard.serotonin += (target_sero - guard.serotonin) * neuromod_sero_alpha();

        guard.clamp();
        let turn = TURN_COUNTER.fetch_add(1, Ordering::Relaxed) + 1;
        emit_telemetry(&guard, turn);
    }
}

/// Append one JSON line to `CHUMP_NEUROMOD_TELEMETRY_PATH` (if set).
/// Each line: `{"turn":N,"dopamine":X,"noradrenaline":X,"serotonin":X,"ts_ms":T}`
fn emit_telemetry(nm: &NeuromodState, turn: u64) {
    let path = match std::env::var("CHUMP_NEUROMOD_TELEMETRY_PATH") {
        Ok(p) if !p.is_empty() => p,
        _ => return,
    };
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let line = format!(
        "{{\"turn\":{},\"dopamine\":{:.4},\"noradrenaline\":{:.4},\"serotonin\":{:.4},\"ts_ms\":{}}}\n",
        turn, nm.dopamine, nm.noradrenaline, nm.serotonin, ts
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Reset modulators to baseline (e.g., at session start).
pub fn reset() {
    if let Ok(mut guard) = state().lock() {
        *guard = NeuromodState::baseline();
    }
}

/// Restore modulators from a snapshot (used by speculative execution rollback).
pub fn restore(snapshot: NeuromodState) {
    if let Ok(mut guard) = state().lock() {
        *guard = snapshot;
    }
}

// --- Modulated control parameters ---

/// Lerp alpha for noradrenaline updates. Override via `CHUMP_NEUROMOD_NA_ALPHA`.
fn neuromod_na_alpha() -> f64 {
    std::env::var("CHUMP_NEUROMOD_NA_ALPHA")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.15)
}

/// Lerp alpha for serotonin updates. Override via `CHUMP_NEUROMOD_SERO_ALPHA`.
fn neuromod_sero_alpha() -> f64 {
    std::env::var("CHUMP_NEUROMOD_SERO_ALPHA")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.1)
}

/// Regime transition thresholds, shifted by noradrenaline.
/// High NA tightens thresholds (regime shifts toward Exploit earlier).
/// Low NA loosens them (stays in Explore longer).
/// Base values configurable via `CHUMP_EXPLOIT_THRESHOLD`, etc. in precision_controller.
pub fn modulated_exploit_threshold() -> f64 {
    let na = levels().noradrenaline;
    crate::precision_controller::base_exploit_threshold() * na
}

pub(crate) fn modulated_balanced_threshold() -> f64 {
    let na = levels().noradrenaline;
    crate::precision_controller::base_balanced_threshold() * na
}

pub(crate) fn modulated_explore_threshold() -> f64 {
    let na = levels().noradrenaline;
    crate::precision_controller::base_explore_threshold() * na
}

/// Tool call budget multiplier from serotonin.
/// High serotonin = patient = more tool calls allowed per turn.
/// Low serotonin = impulsive = fewer tool calls, faster decisions.
pub fn tool_budget_multiplier() -> f64 {
    levels().serotonin.clamp(0.5, 1.5)
}

/// Dopamine-modulated reward scaling (exported for metrics_json).
pub(crate) fn reward_scaling() -> f64 {
    levels().dopamine.clamp(0.5, 1.5)
}

/// Context exploration budget multiplier: serotonin affects how much context
/// is allocated to exploratory content vs fixed content.
///
/// Wired into [`crate::precision_controller::context_exploration_budget`] (WP-6.2).
pub fn context_exploration_multiplier() -> f64 {
    let sero = levels().serotonin;
    let na = levels().noradrenaline;
    (sero * 0.6 + (2.0 - na) * 0.4).clamp(0.5, 1.5)
}

/// Per-call tool timeout (seconds) from a configured base, scaled by **serotonin**
/// (patient → longer wall clock; impulsive → shorter). Used by
/// [`crate::tool_middleware::ToolTimeoutWrapper`] (WP-6.2).
pub fn effective_tool_timeout_secs(base_secs: u64) -> u64 {
    let base = base_secs.max(1);
    let sero = levels().serotonin.clamp(0.1, 2.0);
    let factor = (0.72 + 0.28 * sero).clamp(0.55, 1.35);
    let scaled = (base as f64 * factor).round() as u64;
    scaled.clamp(5, 300)
}

/// Salience factor modulation: dopamine biases toward goal-relevant entries,
/// noradrenaline biases novelty and urgency. Applied in `blackboard::SalienceFactors::score`
/// unless `CHUMP_NEUROMOD_SALIENCE_WEIGHTS=0`.
pub fn salience_modulation() -> (f64, f64, f64, f64) {
    let nm = levels();
    let novelty_mod = (2.0 - nm.noradrenaline) * 0.5 + 0.5;
    let uncertainty_mod = 1.0;
    let goal_mod = nm.dopamine * 0.8 + 0.2;
    let urgency_mod = nm.noradrenaline * 0.7 + 0.3;
    (novelty_mod, uncertainty_mod, goal_mod, urgency_mod)
}

/// Neuromod-adaptive temperature for LLM sampling.
///
/// High Noradrenaline (focus/exploitation) → low temperature (deterministic).
/// Low Noradrenaline (exploration) → high temperature (creative).
/// The env var `CHUMP_TEMPERATURE` sets the base; neuromod scales around it.
pub fn adaptive_temperature(base: f64) -> f64 {
    let na = levels().noradrenaline; // [0.1, 2.0], baseline 1.0
                                     // NA=2.0 → factor=0.4 (very focused), NA=0.1 → factor=1.6 (very exploratory)
    let factor = 1.8 - 0.7 * na; // maps [0.1,2.0] → ~[1.73, 0.4]
    (base * factor).clamp(0.05, 1.5)
}

/// Neuromod-adaptive top_p for LLM sampling.
///
/// High Dopamine (high reward, exploit known-good) → tighter top_p.
/// Low Dopamine (low reward sensitivity) → broader top_p.
pub fn adaptive_top_p() -> f64 {
    let da = levels().dopamine; // [0.1, 2.0], baseline 1.0
                                // DA=2.0 → top_p=0.7 (tight), DA=0.1 → top_p=0.99 (broad)
    let p = 1.05 - 0.175 * da; // maps [0.1,2.0] → ~[0.99, 0.70]
    p.clamp(0.5, 1.0)
}

/// Summary for context injection.
pub fn context_summary() -> String {
    let nm = levels();
    if (nm.dopamine - 1.0).abs() < 0.1
        && (nm.noradrenaline - 1.0).abs() < 0.1
        && (nm.serotonin - 1.0).abs() < 0.1
    {
        return String::new(); // Near baseline, don't clutter context
    }
    format!(
        "Neuromod: DA={:.2} NA={:.2} 5HT={:.2} ({})",
        nm.dopamine,
        nm.noradrenaline,
        nm.serotonin,
        modulation_summary(&nm),
    )
}

fn modulation_summary(nm: &NeuromodState) -> &'static str {
    if nm.dopamine > 1.3 && nm.noradrenaline > 1.2 {
        "high focus + reward"
    } else if nm.dopamine < 0.7 {
        "low reward sensitivity"
    } else if nm.noradrenaline < 0.7 {
        "broad exploration mode"
    } else if nm.serotonin > 1.3 {
        "patient, multi-step OK"
    } else if nm.serotonin < 0.7 {
        "impulsive, prefer quick actions"
    } else {
        "near baseline"
    }
}

/// JSON metrics for the health endpoint.
pub fn metrics_json() -> serde_json::Value {
    let nm = levels();
    serde_json::json!({
        "dopamine": (nm.dopamine * 1000.0).round() / 1000.0,
        "noradrenaline": (nm.noradrenaline * 1000.0).round() / 1000.0,
        "serotonin": (nm.serotonin * 1000.0).round() / 1000.0,
        "tool_budget_multiplier": (tool_budget_multiplier() * 100.0).round() / 100.0,
        "reward_scaling": (reward_scaling() * 100.0).round() / 100.0,
        "context_exploration_multiplier": (context_exploration_multiplier() * 100.0).round() / 100.0,
        "effective_tool_timeout_secs_30base": effective_tool_timeout_secs(30),
        "adaptive_temperature": (adaptive_temperature(0.3) * 1000.0).round() / 1000.0,
        "adaptive_top_p": (adaptive_top_p() * 1000.0).round() / 1000.0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn test_baseline_levels() {
        reset();
        let nm = levels();
        assert!((nm.dopamine - 1.0).abs() < 0.01);
        assert!((nm.noradrenaline - 1.0).abs() < 0.01);
        assert!((nm.serotonin - 1.0).abs() < 0.01);
    }

    #[test]
    #[serial(neuromod_env)]
    fn neuromod_enabled_default_on() {
        std::env::remove_var("CHUMP_NEUROMOD_ENABLED");
        assert!(neuromod_enabled());
    }

    #[test]
    #[serial(neuromod_env)]
    fn neuromod_enabled_off_via_env() {
        for v in ["0", "false", "off"] {
            std::env::set_var("CHUMP_NEUROMOD_ENABLED", v);
            assert!(!neuromod_enabled(), "expected off for {v}");
        }
        std::env::remove_var("CHUMP_NEUROMOD_ENABLED");
    }

    #[test]
    #[serial(neuromod_env)]
    fn update_from_turn_short_circuits_when_disabled() {
        // With gate off, modulators should stay at baseline regardless of
        // task / surprisal state. Reset first to baseline, set the gate
        // off, call update — values must not budge.
        reset();
        std::env::set_var("CHUMP_NEUROMOD_ENABLED", "0");
        update_from_turn();
        let nm = levels();
        assert!(
            (nm.dopamine - 1.0).abs() < 0.01,
            "dopamine drifted: {}",
            nm.dopamine
        );
        assert!(
            (nm.noradrenaline - 1.0).abs() < 0.01,
            "noradrenaline drifted: {}",
            nm.noradrenaline
        );
        assert!(
            (nm.serotonin - 1.0).abs() < 0.01,
            "serotonin drifted: {}",
            nm.serotonin
        );
        std::env::remove_var("CHUMP_NEUROMOD_ENABLED");
    }

    #[test]
    fn test_modulated_thresholds() {
        reset();
        let et = modulated_exploit_threshold();
        let bt = modulated_balanced_threshold();
        let xt = modulated_explore_threshold();
        assert!(et < bt, "exploit < balanced: {} < {}", et, bt);
        assert!(bt < xt, "balanced < explore: {} < {}", bt, xt);
    }

    #[test]
    fn test_tool_budget_multiplier_at_baseline() {
        reset();
        let m = tool_budget_multiplier();
        assert!((m - 1.0).abs() < 0.01, "at baseline should be ~1.0: {}", m);
    }

    #[test]
    fn test_reward_scaling_at_baseline() {
        reset();
        let r = reward_scaling();
        assert!((r - 1.0).abs() < 0.01, "at baseline should be ~1.0: {}", r);
    }

    #[test]
    fn test_clamping() {
        let mut s = NeuromodState {
            dopamine: 5.0,
            noradrenaline: -1.0,
            serotonin: 3.0,
        };
        s.clamp();
        assert!((s.dopamine - 2.0).abs() < 0.01);
        assert!((s.noradrenaline - 0.1).abs() < 0.01);
        assert!((s.serotonin - 2.0).abs() < 0.01);
    }

    #[test]
    fn test_context_summary_empty_at_baseline() {
        reset();
        let s = context_summary();
        assert!(s.is_empty(), "at baseline should be empty: '{}'", s);
    }

    #[test]
    fn test_salience_modulation_returns_four() {
        let (n, u, g, ur) = salience_modulation();
        assert!(n > 0.0 && n < 3.0);
        assert!(u > 0.0 && u < 3.0);
        assert!(g > 0.0 && g < 3.0);
        assert!(ur > 0.0 && ur < 3.0);
    }

    #[test]
    fn test_metrics_json_structure() {
        let j = metrics_json();
        assert!(j.get("dopamine").is_some());
        assert!(j.get("noradrenaline").is_some());
        assert!(j.get("serotonin").is_some());
        assert!(j.get("tool_budget_multiplier").is_some());
        assert!(j.get("effective_tool_timeout_secs_30base").is_some());
    }

    #[test]
    fn test_effective_tool_timeout_clamped() {
        reset();
        let t = effective_tool_timeout_secs(30);
        assert!((5..=300).contains(&t));
        assert!((25..=45).contains(&t), "near baseline 30: {}", t);
    }
}
