//! Integration cycle policy — governs whether a cycle should fire.
//!
//! The policy layer is deliberately thin in Phase 1: it only checks the
//! volume threshold (minimum candidates before we bother). Future phases
//! will add time-window gating (CHUMP_INTEGRATOR_CADENCE_MIN), cost budget
//! checks, and operator-override signals from ambient.jsonl.

use crate::config::IntegratorConfig;
use crate::cycle::GapCandidate;

/// Decision returned by the policy layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PolicyDecision {
    /// Proceed with the given candidates.
    Proceed,
    /// Skip this cycle (reason included for logging).
    Skip(String),
}

/// Evaluate whether an integration cycle should proceed given the selected
/// candidates and the current config.
pub fn evaluate(candidates: &[GapCandidate], cfg: &IntegratorConfig) -> PolicyDecision {
    if candidates.is_empty() {
        return PolicyDecision::Skip("no eligible candidates on work-board".to_string());
    }
    if candidates.len() < cfg.volume_threshold {
        return PolicyDecision::Skip(format!(
            "only {} candidate(s) — below volume threshold of {}",
            candidates.len(),
            cfg.volume_threshold
        ));
    }
    PolicyDecision::Proceed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cycle::GapCandidate;

    fn make_candidate(gap_id: &str) -> GapCandidate {
        GapCandidate {
            gap_id: gap_id.to_string(),
            title: "test gap".to_string(),
            priority: "P1".to_string(),
            ready_at: chrono::Utc::now().to_rfc3339(),
            queue_age_s: 60,
            estimated_loc: 100,
            branch: format!("chump/{}", gap_id.to_lowercase()),
            author: None,
            tags: String::new(),
        }
    }

    #[test]
    fn test_empty_candidates_skip() {
        let cfg = IntegratorConfig::default();
        assert_eq!(
            evaluate(&[], &cfg),
            PolicyDecision::Skip("no eligible candidates on work-board".to_string())
        );
    }

    #[test]
    fn test_below_threshold_skip() {
        let cfg = IntegratorConfig {
            volume_threshold: 5,
            ..IntegratorConfig::default()
        };
        let candidates: Vec<_> = (0..3)
            .map(|i| make_candidate(&format!("GAP-{i}")))
            .collect();
        match evaluate(&candidates, &cfg) {
            PolicyDecision::Skip(reason) => {
                assert!(
                    reason.contains("3"),
                    "reason should mention count: {reason}"
                );
                assert!(
                    reason.contains("5"),
                    "reason should mention threshold: {reason}"
                );
            }
            other => panic!("expected Skip, got {other:?}"),
        }
    }

    #[test]
    fn test_at_threshold_proceeds() {
        let cfg = IntegratorConfig {
            volume_threshold: 3,
            ..IntegratorConfig::default()
        };
        let candidates: Vec<_> = (0..3)
            .map(|i| make_candidate(&format!("GAP-{i}")))
            .collect();
        assert_eq!(evaluate(&candidates, &cfg), PolicyDecision::Proceed);
    }

    #[test]
    fn test_above_threshold_proceeds() {
        let cfg = IntegratorConfig {
            volume_threshold: 2,
            ..IntegratorConfig::default()
        };
        let candidates: Vec<_> = (0..5)
            .map(|i| make_candidate(&format!("GAP-{i}")))
            .collect();
        assert_eq!(evaluate(&candidates, &cfg), PolicyDecision::Proceed);
    }
}
