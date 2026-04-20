//! Belief state module: maintains per-tool confidence and task-level uncertainty,
//! updated each turn via Bayesian beta-distribution updates.
//!
//! Implements the proactive uncertainty awareness from Active Inference (Section 2.1
//! of CHUMP_TO_COMPLEX.md). The belief state drives Expected Free Energy scoring
//! and epistemic escalation.
//!
//! Part of the Synthetic Consciousness Framework, Section 2.

use std::collections::HashMap;
use std::sync::Mutex;

/// Per-tool reliability belief, modeled as a Beta(alpha, beta) distribution.
/// Alpha = successes + 1 prior, Beta = failures + 1 prior.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ToolBelief {
    pub alpha: f64,
    pub beta: f64,
    pub latency_mean_ms: f64,
    pub latency_var_ms: f64,
    pub sample_count: u64,
}

impl ToolBelief {
    fn new() -> Self {
        Self {
            alpha: 1.0,
            beta: 1.0,
            latency_mean_ms: 500.0,
            latency_var_ms: 250000.0,
            sample_count: 0,
        }
    }

    /// Mean of the Beta distribution = alpha / (alpha + beta). Range [0, 1].
    pub fn reliability(&self) -> f64 {
        self.alpha / (self.alpha + self.beta)
    }

    /// Variance of the Beta distribution: measures uncertainty about reliability.
    /// High variance = we don't know if this tool is reliable or not.
    pub fn uncertainty(&self) -> f64 {
        let ab = self.alpha + self.beta;
        (self.alpha * self.beta) / (ab * ab * (ab + 1.0))
    }

    fn update(&mut self, success: bool, latency_ms: u64) {
        if success {
            self.alpha += 1.0;
        } else {
            self.beta += 1.0;
        }
        self.sample_count += 1;
        let n = self.sample_count as f64;
        let lat = latency_ms as f64;
        let old_mean = self.latency_mean_ms;
        self.latency_mean_ms += (lat - old_mean) / n;
        if n > 1.0 {
            self.latency_var_ms += (lat - old_mean) * (lat - self.latency_mean_ms);
        }
    }

    /// Standard deviation of observed latency.
    pub fn latency_std_ms(&self) -> f64 {
        if self.sample_count < 2 {
            return self.latency_mean_ms;
        }
        (self.latency_var_ms / (self.sample_count - 1) as f64).sqrt()
    }
}

/// Task-level belief state: overall confidence in the current task trajectory.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TaskBelief {
    /// Confidence that we're on the right path (0.0 = lost, 1.0 = certain).
    pub trajectory_confidence: f64,
    /// Freshness of our environment model (decays with time, resets on observation).
    pub model_freshness: f64,
    /// Number of consecutive successes in the current task.
    pub streak_successes: u32,
    /// Number of consecutive failures.
    pub streak_failures: u32,
}

impl TaskBelief {
    fn new() -> Self {
        Self {
            trajectory_confidence: 0.5,
            model_freshness: 1.0,
            streak_successes: 0,
            streak_failures: 0,
        }
    }

    fn update(&mut self, success: bool) {
        if success {
            self.streak_successes += 1;
            self.streak_failures = 0;
            self.trajectory_confidence = (self.trajectory_confidence + 0.1).min(1.0);
            self.model_freshness = (self.model_freshness + 0.05).min(1.0);
        } else {
            self.streak_failures += 1;
            self.streak_successes = 0;
            self.trajectory_confidence = (self.trajectory_confidence - 0.15).max(0.0);
            self.model_freshness = (self.model_freshness - 0.1).max(0.0);
        }
    }

    /// Overall uncertainty: higher when trajectory confidence is low or model is stale.
    pub fn uncertainty(&self) -> f64 {
        1.0 - (self.trajectory_confidence * 0.6 + self.model_freshness * 0.4)
    }

    /// Decay model freshness (call once per turn to model "staleness").
    pub fn decay_freshness(&mut self) {
        self.model_freshness = (self.model_freshness - 0.02).max(0.0);
    }
}

/// Expected Free Energy components for a candidate tool call.
#[derive(Debug, Clone)]
pub struct EFEScore {
    pub tool_name: String,
    /// Ambiguity: how uncertain we are about this tool's outcome.
    pub ambiguity: f64,
    /// Risk: expected cost of failure (based on beta and latency variance).
    pub risk: f64,
    /// Pragmatic value: expected utility toward the goal.
    pub pragmatic_value: f64,
    /// G = ambiguity + risk - pragmatic_value (lower is better).
    pub g: f64,
}

/// Returns `false` when **`CHUMP_BYPASS_BELIEF_STATE=1`** (or `true`).
///
/// When bypassed:
/// - `update_tool_belief` and `decay_turn` become no-ops.
/// - `context_summary` returns an empty string (no context injection).
/// - `should_escalate_epistemic` always returns `false`.
///
/// This flag exists specifically for the EVAL-035 A/B ablation so the
/// belief-state contribution can be isolated without touching any other
/// consciousness module. It mirrors the `CHUMP_BYPASS_SURPRISAL` pattern.
pub fn belief_state_enabled() -> bool {
    !std::env::var("CHUMP_BYPASS_BELIEF_STATE")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// Global belief state singleton.
static BELIEF_STATE: std::sync::OnceLock<Mutex<BeliefStateInner>> = std::sync::OnceLock::new();

struct BeliefStateInner {
    tool_beliefs: HashMap<String, ToolBelief>,
    task_belief: TaskBelief,
}

fn state() -> &'static Mutex<BeliefStateInner> {
    BELIEF_STATE.get_or_init(|| {
        Mutex::new(BeliefStateInner {
            tool_beliefs: HashMap::new(),
            task_belief: TaskBelief::new(),
        })
    })
}

/// Record a tool call outcome and update beliefs.
/// No-op when `CHUMP_BYPASS_BELIEF_STATE=1`.
pub fn update_tool_belief(tool_name: &str, success: bool, latency_ms: u64) {
    if !belief_state_enabled() {
        return;
    }
    if let Ok(mut guard) = state().lock() {
        let belief = guard
            .tool_beliefs
            .entry(tool_name.to_string())
            .or_insert_with(ToolBelief::new);
        belief.update(success, latency_ms);
        guard.task_belief.update(success);
    }
}

/// Decay task freshness (call once per turn).
/// No-op when `CHUMP_BYPASS_BELIEF_STATE=1`.
pub fn decay_turn() {
    if !belief_state_enabled() {
        return;
    }
    if let Ok(mut guard) = state().lock() {
        guard.task_belief.decay_freshness();
    }
}

/// Adjust trajectory confidence by a delta (positive = increase, negative = decrease).
/// Used by the perception layer to lower confidence when input is highly ambiguous.
/// No-op when `CHUMP_BYPASS_BELIEF_STATE=1`.
pub fn nudge_trajectory(delta: f64) {
    if !belief_state_enabled() {
        return;
    }
    if let Ok(mut guard) = state().lock() {
        guard.task_belief.trajectory_confidence =
            (guard.task_belief.trajectory_confidence + delta).clamp(0.0, 1.0);
    }
}

/// Get belief for a specific tool.
pub fn tool_belief(tool_name: &str) -> Option<ToolBelief> {
    state()
        .lock()
        .ok()
        .and_then(|g| g.tool_beliefs.get(tool_name).cloned())
}

/// Get the current task belief state.
pub fn task_belief() -> TaskBelief {
    state()
        .lock()
        .map(|g| g.task_belief.clone())
        .unwrap_or_else(|_| TaskBelief::new())
}

/// Snapshot the full inner state for speculative execution forking.
pub fn snapshot_inner() -> (HashMap<String, ToolBelief>, TaskBelief) {
    state()
        .lock()
        .map(|g| (g.tool_beliefs.clone(), g.task_belief.clone()))
        .unwrap_or_else(|_| (HashMap::new(), TaskBelief::new()))
}

/// Restore belief state from a snapshot (used by speculative execution rollback).
pub fn restore_from_snapshot(tool_beliefs: HashMap<String, ToolBelief>, task_belief: TaskBelief) {
    if let Ok(mut guard) = state().lock() {
        guard.tool_beliefs = tool_beliefs;
        guard.task_belief = task_belief;
    }
}

/// Score a set of candidate tools by Expected Free Energy.
/// Returns scores sorted by G ascending (lowest G = best choice).
///
/// G = ambiguity + risk - pragmatic_value
/// - ambiguity: tool belief uncertainty (high when we haven't used the tool much)
/// - risk: (1 - reliability) * latency_cost_factor (unreliable + slow = risky)
/// - pragmatic_value: reliability * (1 - normalized_latency) (reliable + fast = valuable)
pub fn score_tools(candidate_tools: &[&str]) -> Vec<EFEScore> {
    let guard = match state().lock() {
        Ok(g) => g,
        Err(_) => return Vec::new(),
    };

    let mut scores: Vec<EFEScore> = candidate_tools
        .iter()
        .map(|&name| {
            let belief = guard.tool_beliefs.get(name);

            let (ambiguity, reliability, latency_norm) = match belief {
                Some(b) => {
                    let rel = b.reliability();
                    let unc = b.uncertainty();
                    let lat_norm = (b.latency_mean_ms / 10000.0).min(1.0);
                    (unc * 4.0, rel, lat_norm)
                }
                None => (0.5, 0.5, 0.3),
            };

            let risk = (1.0 - reliability) * (0.5 + latency_norm * 0.5);
            let pragmatic_value = reliability * (1.0 - latency_norm * 0.3);
            let g = ambiguity + risk - pragmatic_value;

            EFEScore {
                tool_name: name.to_string(),
                ambiguity,
                risk,
                pragmatic_value,
                g,
            }
        })
        .collect();

    scores.sort_by(|a, b| a.g.partial_cmp(&b.g).unwrap_or(std::cmp::Ordering::Equal));
    scores
}

/// Should the agent escalate to the human due to epistemic uncertainty?
/// Returns `false` (no escalation) when `CHUMP_BYPASS_BELIEF_STATE=1`.
/// Otherwise returns true when task uncertainty is very high (> threshold).
pub fn should_escalate_epistemic() -> bool {
    if !belief_state_enabled() {
        return false;
    }
    let threshold = std::env::var("CHUMP_EPISTEMIC_ESCALATION_THRESHOLD")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&v| v > 0.0 && v <= 1.0)
        .unwrap_or(0.75);
    let tb = task_belief();
    tb.uncertainty() > threshold
}

/// Format belief state summary for context injection.
/// Returns an empty string when `CHUMP_BYPASS_BELIEF_STATE=1` (no injection).
pub fn context_summary() -> String {
    if !belief_state_enabled() {
        return String::new();
    }
    let (tb_snapshot, uncertain, tool_count, task_uncertainty) = {
        let guard = match state().lock() {
            Ok(g) => g,
            Err(_) => return String::new(),
        };

        let tb = &guard.task_belief;
        let tool_count = guard.tool_beliefs.len();
        if tool_count == 0 {
            return String::new();
        }

        let snapshot = (
            tb.trajectory_confidence,
            tb.model_freshness,
            tb.uncertainty(),
        );
        let task_unc = tb.uncertainty();

        let mut uncertain: Vec<_> = guard
            .tool_beliefs
            .iter()
            .map(|(name, b)| (name.clone(), b.uncertainty(), b.reliability()))
            .collect();
        uncertain.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        (snapshot, uncertain, tool_count, task_unc)
    }; // guard dropped here

    let mut out = format!(
        "Belief state: trajectory={:.2}, freshness={:.2}, uncertainty={:.2}, tools_observed={}",
        tb_snapshot.0, tb_snapshot.1, tb_snapshot.2, tool_count
    );

    if !uncertain.is_empty() {
        out.push_str(". Least certain: ");
        for (i, (name, unc, rel)) in uncertain.iter().take(3).enumerate() {
            if i > 0 {
                out.push_str(", ");
            }
            out.push_str(&format!("{}(rel={:.2},unc={:.3})", name, rel, unc));
        }
    }

    let threshold = std::env::var("CHUMP_EPISTEMIC_ESCALATION_THRESHOLD")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&v| v > 0.0 && v <= 1.0)
        .unwrap_or(0.75);
    if task_uncertainty > threshold {
        out.push_str(
            ". WARNING: high epistemic uncertainty — consider asking the user for guidance.",
        );
    }

    out
}

/// JSON metrics for the health endpoint.
pub fn metrics_json() -> serde_json::Value {
    let (tb_json, tools, escalate) = {
        let guard = match state().lock() {
            Ok(g) => g,
            Err(_) => {
                return serde_json::json!({
                    "task_uncertainty": 0.5,
                    "tools_observed": 0,
                })
            }
        };

        let tb = &guard.task_belief;
        let task_unc = tb.uncertainty();
        let threshold = std::env::var("CHUMP_EPISTEMIC_ESCALATION_THRESHOLD")
            .ok()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|&v| v > 0.0 && v <= 1.0)
            .unwrap_or(0.75);

        let tb_json = serde_json::json!({
            "trajectory_confidence": (tb.trajectory_confidence * 1000.0).round() / 1000.0,
            "model_freshness": (tb.model_freshness * 1000.0).round() / 1000.0,
            "task_uncertainty": (task_unc * 1000.0).round() / 1000.0,
            "streak_successes": tb.streak_successes,
            "streak_failures": tb.streak_failures,
        });

        let tools: serde_json::Value = guard
            .tool_beliefs
            .iter()
            .map(|(name, b)| {
                (
                    name.clone(),
                    serde_json::json!({
                        "reliability": (b.reliability() * 1000.0).round() / 1000.0,
                        "uncertainty": (b.uncertainty() * 10000.0).round() / 10000.0,
                        "samples": b.sample_count,
                        "latency_mean_ms": b.latency_mean_ms.round(),
                    }),
                )
            })
            .collect::<serde_json::Map<String, serde_json::Value>>()
            .into();

        (tb_json, tools, task_unc > threshold)
    }; // guard dropped

    let mut result = tb_json.as_object().cloned().unwrap_or_default();
    result.insert(
        "should_escalate_epistemic".to_string(),
        serde_json::json!(escalate),
    );
    result.insert("tools".to_string(), tools);
    serde_json::Value::Object(result)
}

/// Reliability of a single tool from the Beta mean. Returns 0.5 (prior) if unknown.
pub fn tool_reliability(tool_name: &str) -> f64 {
    state()
        .lock()
        .ok()
        .and_then(|g| g.tool_beliefs.get(tool_name).map(|b| b.reliability()))
        .unwrap_or(0.5)
}

/// Score all known tools except `excluded`, sorted by EFE ascending (best first).
pub fn score_tools_except(excluded: &str) -> Vec<EFEScore> {
    let names: Vec<String> = state()
        .lock()
        .ok()
        .map(|g| {
            g.tool_beliefs
                .keys()
                .filter(|k| k.as_str() != excluded)
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    let refs: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
    score_tools(&refs)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(test)]
    use serial_test::serial;

    #[test]
    fn test_tool_belief_bayesian_update() {
        let mut b = ToolBelief::new();
        assert!((b.reliability() - 0.5).abs() < 0.01, "prior should be 0.5");

        b.update(true, 100);
        b.update(true, 150);
        b.update(true, 120);
        assert!(
            b.reliability() > 0.7,
            "3 successes should push reliability up: {}",
            b.reliability()
        );

        b.update(false, 5000);
        assert!(
            b.reliability() > 0.5,
            "still mostly reliable: {}",
            b.reliability()
        );
    }

    #[test]
    fn test_uncertainty_decreases_with_samples() {
        let mut b = ToolBelief::new();
        let initial_unc = b.uncertainty();

        for _ in 0..10 {
            b.update(true, 100);
        }
        let after_unc = b.uncertainty();
        assert!(
            after_unc < initial_unc,
            "uncertainty should decrease with more samples: {} -> {}",
            initial_unc,
            after_unc
        );
    }

    #[test]
    fn test_task_belief_updates() {
        let mut tb = TaskBelief::new();
        assert!((tb.trajectory_confidence - 0.5).abs() < 0.01);

        tb.update(true);
        tb.update(true);
        tb.update(true);
        assert!(
            tb.trajectory_confidence > 0.7,
            "successes should increase confidence"
        );
        assert_eq!(tb.streak_successes, 3);
        assert_eq!(tb.streak_failures, 0);

        tb.update(false);
        assert!(
            tb.trajectory_confidence < 0.7,
            "failure should decrease confidence"
        );
        assert_eq!(tb.streak_successes, 0);
        assert_eq!(tb.streak_failures, 1);
    }

    #[test]
    fn test_task_uncertainty() {
        let mut tb = TaskBelief::new();
        let initial = tb.uncertainty();

        for _ in 0..5 {
            tb.update(true);
        }
        assert!(
            tb.uncertainty() < initial,
            "successes should reduce uncertainty"
        );

        for _ in 0..10 {
            tb.update(false);
        }
        assert!(
            tb.uncertainty() > 0.5,
            "many failures should increase uncertainty"
        );
    }

    #[test]
    #[serial(bypass_belief_state)]
    fn test_efe_scoring() {
        update_tool_belief("reliable_tool", true, 50);
        update_tool_belief("reliable_tool", true, 60);
        update_tool_belief("reliable_tool", true, 55);
        update_tool_belief("unreliable_tool", false, 5000);
        update_tool_belief("unreliable_tool", false, 4000);
        update_tool_belief("unreliable_tool", true, 200);

        let scores = score_tools(&["reliable_tool", "unreliable_tool"]);
        assert_eq!(scores.len(), 2);
        assert_eq!(
            scores[0].tool_name, "reliable_tool",
            "reliable tool should score better (lower G)"
        );
        assert!(
            scores[0].g < scores[1].g,
            "reliable G ({}) should be less than unreliable G ({})",
            scores[0].g,
            scores[1].g
        );
    }

    #[test]
    fn test_unknown_tool_gets_prior() {
        let scores = score_tools(&["never_seen_tool"]);
        assert_eq!(scores.len(), 1);
        assert!(
            (scores[0].ambiguity - 0.5).abs() < 0.01,
            "unknown tool should get moderate ambiguity"
        );
    }

    #[test]
    #[serial(bypass_belief_state)]
    fn test_context_summary_nonempty_after_updates() {
        update_tool_belief("ctx_test_tool", true, 100);
        let summary = context_summary();
        assert!(
            summary.contains("Belief state:"),
            "should produce a summary: {}",
            summary
        );
        assert!(summary.contains("trajectory="), "should include trajectory");
    }

    #[test]
    fn test_metrics_json_structure() {
        update_tool_belief("json_test", true, 100);
        let j = metrics_json();
        assert!(j.get("trajectory_confidence").is_some());
        assert!(j.get("task_uncertainty").is_some());
        assert!(j.get("tools").is_some());
        assert!(j.get("should_escalate_epistemic").is_some());
    }

    #[test]
    fn test_freshness_decay() {
        let mut tb = TaskBelief::new();
        let initial = tb.model_freshness;
        tb.decay_freshness();
        assert!(
            tb.model_freshness < initial,
            "freshness should decay: {} -> {}",
            initial,
            tb.model_freshness
        );
    }

    // ── EVAL-035: bypass-belief-state env flag ─────────────────────────────
    //
    // `serial(bypass_belief_state)` prevents env-var races with
    // `test_efe_scoring` and `test_context_summary_nonempty_after_updates`,
    // which call `score_tools` / `context_summary` and would see an unexpected
    // bypass env if this test runs concurrently.
    #[test]
    #[serial(bypass_belief_state)]
    fn bypass_belief_state_flag_behaviour() {
        let key = "CHUMP_BYPASS_BELIEF_STATE";

        // ── 1. Default (unset) → enabled ──────────────────────────────────
        std::env::remove_var(key);
        assert!(belief_state_enabled(), "default: enabled");

        // ── 2. bypass=1 ────────────────────────────────────────────────────
        std::env::set_var(key, "1");
        assert!(!belief_state_enabled(), "bypass=1 disables");

        // All guarded functions must be no-ops / return benign values.
        update_tool_belief("eval035_bypass_test_noop", true, 50);
        decay_turn();
        nudge_trajectory(-0.5);

        // context_summary must return "" — gated at function entry.
        let summary = context_summary();
        assert!(
            summary.is_empty(),
            "context_summary must be empty when bypass=1, got: {:?}",
            summary
        );

        // should_escalate_epistemic must be false.
        assert!(
            !should_escalate_epistemic(),
            "should_escalate_epistemic must be false when bypass=1"
        );

        // ── 3. Various truthy/falsy spellings ─────────────────────────────
        std::env::set_var(key, "true");
        assert!(!belief_state_enabled(), "bypass=true disables");

        std::env::set_var(key, "TRUE");
        assert!(!belief_state_enabled(), "bypass=TRUE disables");

        // "0" re-enables
        std::env::set_var(key, "0");
        assert!(belief_state_enabled(), "bypass=0 keeps enabled");

        // ── 4. Restore ────────────────────────────────────────────────────
        std::env::remove_var(key);
        assert!(belief_state_enabled(), "restored: enabled");
    }
}
