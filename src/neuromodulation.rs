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

use std::sync::Mutex;

/// The three synthetic neuromodulators (all clamped to [0.0, 2.0]).
#[derive(Debug, Clone)]
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

/// Update neuromodulators based on the latest turn outcome.
///
/// Called once per turn after tool execution. Adjusts modulators based on:
/// - Surprisal EMA (environment predictability)
/// - Task belief trajectory (success/failure streaks)
/// - Energy budget remaining
pub fn update_from_turn() {
    let surprisal = crate::surprise_tracker::current_surprisal_ema();
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
        guard.noradrenaline += (target_na - guard.noradrenaline) * 0.15;

        // Serotonin: rises with trajectory confidence, drops under time pressure
        let patience_signal = task.trajectory_confidence - (1.0 - energy_remaining) * 0.5;
        let target_sero = 1.0 + patience_signal * 0.3;
        guard.serotonin += (target_sero - guard.serotonin) * 0.1;

        guard.clamp();
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

/// Regime transition thresholds, shifted by noradrenaline.
/// High NA tightens thresholds (regime shifts toward Exploit earlier).
/// Low NA loosens them (stays in Explore longer).
pub fn modulated_exploit_threshold() -> f64 {
    let na = levels().noradrenaline;
    0.15 * na // Higher NA → higher threshold → easier to stay in Exploit
}

pub fn modulated_balanced_threshold() -> f64 {
    let na = levels().noradrenaline;
    0.35 * na
}

pub fn modulated_explore_threshold() -> f64 {
    let na = levels().noradrenaline;
    0.60 * na
}

/// Tool call budget multiplier from serotonin.
/// High serotonin = patient = more tool calls allowed per turn.
/// Low serotonin = impulsive = fewer tool calls, faster decisions.
pub fn tool_budget_multiplier() -> f64 {
    levels().serotonin.clamp(0.5, 1.5)
}

/// Dopamine-modulated reward scaling: amplifies or dampens surprisal EMA updates.
///
/// Wired into [`crate::surprise_tracker::record_prediction`] as a multiplier on `CHUMP_SURPRISE_EMA_ALPHA`
/// (capped at 1.0). Exported for metrics_json.
pub fn reward_scaling() -> f64 {
    levels().dopamine.clamp(0.5, 1.5)
}

/// Context exploration budget multiplier: serotonin affects how much context
/// is allocated to exploratory content vs fixed content.
///
/// **Not yet wired:** precision_controller uses its own regime table, not this
/// multiplier. Exported for metrics_json and future use.
pub fn context_exploration_multiplier() -> f64 {
    let sero = levels().serotonin;
    let na = levels().noradrenaline;
    (sero * 0.6 + (2.0 - na) * 0.4).clamp(0.5, 1.5)
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
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_baseline_levels() {
        reset();
        let nm = levels();
        assert!((nm.dopamine - 1.0).abs() < 0.01);
        assert!((nm.noradrenaline - 1.0).abs() < 0.01);
        assert!((nm.serotonin - 1.0).abs() < 0.01);
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
    }
}
