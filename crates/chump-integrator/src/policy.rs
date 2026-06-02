//! Integration cycle policy — governs whether a cycle should fire.
//!
//! The policy layer is deliberately thin in Phase 1: it checks the volume
//! threshold (minimum candidates before we bother) and the stale-SLA fallback
//! (INFRA-2418): when candidate count is below threshold but any candidate has
//! been waiting longer than `stale_sla_hours`, the cycle fires anyway so that
//! single-candidate queues don't stall indefinitely.
//!
//! Future phases will add time-window gating (CHUMP_INTEGRATOR_CADENCE_MIN),
//! cost budget checks, and operator-override signals from ambient.jsonl.

use crate::config::IntegratorConfig;
use crate::cycle::GapCandidate;

/// Decision returned by the policy layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PolicyDecision {
    /// Proceed with the given candidates (volume threshold met).
    Proceed,
    /// Skip this cycle (reason included for logging).
    Skip(String),
    /// Proceed via stale-SLA fallback: below volume threshold but at least one
    /// candidate has exceeded the configured stale age.
    ///
    /// Carries `oldest_stale_hours` (rounded up to whole hours) for the
    /// `integrator_stale_sla_fired` ambient event.
    StaleSla { oldest_stale_hours: u64 },
}

/// Evaluate whether an integration cycle should proceed given the selected
/// candidates and the current config.
pub fn evaluate(candidates: &[GapCandidate], cfg: &IntegratorConfig) -> PolicyDecision {
    if candidates.is_empty() {
        return PolicyDecision::Skip("no eligible candidates on work-board".to_string());
    }
    if candidates.len() >= cfg.volume_threshold {
        return PolicyDecision::Proceed;
    }

    // Below volume threshold — check stale-SLA fallback (INFRA-2418).
    // Bypass: CHUMP_INTEGRATOR_NO_STALE_SLA=1 restores strict threshold behaviour.
    if cfg.no_stale_sla {
        return PolicyDecision::Skip(format!(
            "only {} candidate(s) — below volume threshold of {} (stale-SLA bypass active)",
            candidates.len(),
            cfg.volume_threshold
        ));
    }

    let sla_threshold_s = cfg.stale_sla_hours * 3600;
    let oldest_s = candidates.iter().map(|c| c.queue_age_s).max().unwrap_or(0);

    if oldest_s >= sla_threshold_s {
        // At least one candidate has waited long enough — fire the SLA fallback.
        let oldest_stale_hours = oldest_s.div_ceil(3600);
        return PolicyDecision::StaleSla { oldest_stale_hours };
    }

    PolicyDecision::Skip(format!(
        "only {} candidate(s) — below volume threshold of {} (oldest {}h < SLA {}h)",
        candidates.len(),
        cfg.volume_threshold,
        oldest_s / 3600,
        cfg.stale_sla_hours,
    ))
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

    fn make_candidate_aged(gap_id: &str, age_s: u64) -> GapCandidate {
        GapCandidate {
            gap_id: gap_id.to_string(),
            title: "test gap".to_string(),
            priority: "P1".to_string(),
            ready_at: chrono::Utc::now().to_rfc3339(),
            queue_age_s: age_s,
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

    // ── Stale-SLA tests (INFRA-2418) ─────────────────────────────────────────

    #[test]
    fn test_stale_sla_fires_when_candidate_aged_past_threshold() {
        // 1 candidate aged 7h (25200s) with SLA threshold of 6h → StaleSla fires.
        let cfg = IntegratorConfig {
            volume_threshold: 5,
            stale_sla_hours: 6,
            no_stale_sla: false,
            ..IntegratorConfig::default()
        };
        let candidates = vec![make_candidate_aged("INFRA-9001", 25200)]; // 7h
        match evaluate(&candidates, &cfg) {
            PolicyDecision::StaleSla { oldest_stale_hours } => {
                assert_eq!(oldest_stale_hours, 7, "7h candidate should report 7h");
            }
            other => panic!("expected StaleSla, got {other:?}"),
        }
    }

    #[test]
    fn test_stale_sla_skips_when_candidate_too_young() {
        // 1 candidate aged 2h (7200s) with SLA threshold of 6h → Skip.
        let cfg = IntegratorConfig {
            volume_threshold: 5,
            stale_sla_hours: 6,
            no_stale_sla: false,
            ..IntegratorConfig::default()
        };
        let candidates = vec![make_candidate_aged("INFRA-9001", 7200)]; // 2h
        match evaluate(&candidates, &cfg) {
            PolicyDecision::Skip(_) => {} // expected
            other => panic!("expected Skip, got {other:?}"),
        }
    }

    #[test]
    fn test_stale_sla_bypass_skips_even_when_aged() {
        // CHUMP_INTEGRATOR_NO_STALE_SLA=1: 1 gap aged 7h → still Skip.
        let cfg = IntegratorConfig {
            volume_threshold: 5,
            stale_sla_hours: 6,
            no_stale_sla: true,
            ..IntegratorConfig::default()
        };
        let candidates = vec![make_candidate_aged("INFRA-9001", 25200)]; // 7h
        match evaluate(&candidates, &cfg) {
            PolicyDecision::Skip(reason) => {
                assert!(
                    reason.contains("bypass"),
                    "skip reason should mention bypass: {reason}"
                );
            }
            other => panic!("expected Skip (bypass active), got {other:?}"),
        }
    }

    #[test]
    fn test_stale_sla_oldest_hours_rounds_up() {
        // 7h 1s (25201s) → oldest_stale_hours rounds up to 8.
        let cfg = IntegratorConfig {
            volume_threshold: 5,
            stale_sla_hours: 6,
            no_stale_sla: false,
            ..IntegratorConfig::default()
        };
        let candidates = vec![make_candidate_aged("INFRA-9001", 25201)]; // 7h 1s
        match evaluate(&candidates, &cfg) {
            PolicyDecision::StaleSla { oldest_stale_hours } => {
                assert_eq!(oldest_stale_hours, 8, "7h1s rounds up to 8h");
            }
            other => panic!("expected StaleSla, got {other:?}"),
        }
    }

    #[test]
    fn test_stale_sla_uses_oldest_candidate() {
        // 3 candidates: 2h, 5h, 7h. Oldest (7h) triggers SLA.
        let cfg = IntegratorConfig {
            volume_threshold: 5,
            stale_sla_hours: 6,
            no_stale_sla: false,
            ..IntegratorConfig::default()
        };
        let candidates = vec![
            make_candidate_aged("INFRA-9001", 7200),  // 2h
            make_candidate_aged("INFRA-9002", 18000), // 5h
            make_candidate_aged("INFRA-9003", 25200), // 7h
        ];
        match evaluate(&candidates, &cfg) {
            PolicyDecision::StaleSla { oldest_stale_hours } => {
                assert_eq!(oldest_stale_hours, 7);
            }
            other => panic!("expected StaleSla, got {other:?}"),
        }
    }

    #[test]
    fn test_stale_sla_exact_boundary_fires() {
        // Candidate aged exactly stale_sla_hours * 3600 → StaleSla (boundary inclusive).
        let cfg = IntegratorConfig {
            volume_threshold: 5,
            stale_sla_hours: 6,
            no_stale_sla: false,
            ..IntegratorConfig::default()
        };
        let candidates = vec![make_candidate_aged("INFRA-9001", 6 * 3600)]; // exactly 6h
        match evaluate(&candidates, &cfg) {
            PolicyDecision::StaleSla { oldest_stale_hours } => {
                assert_eq!(oldest_stale_hours, 6);
            }
            other => panic!("expected StaleSla at exact boundary, got {other:?}"),
        }
    }

    #[test]
    fn test_volume_threshold_met_takes_priority_over_stale_sla() {
        // When volume threshold is met, Proceed regardless of age.
        let cfg = IntegratorConfig {
            volume_threshold: 2,
            stale_sla_hours: 6,
            no_stale_sla: false,
            ..IntegratorConfig::default()
        };
        let candidates = vec![
            make_candidate_aged("INFRA-9001", 25200), // 7h
            make_candidate_aged("INFRA-9002", 25200), // 7h
        ];
        assert_eq!(evaluate(&candidates, &cfg), PolicyDecision::Proceed);
    }
}
