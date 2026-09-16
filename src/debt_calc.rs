//! CREDIBLE-1276: compute_debt — debt calculation for high-criticality dormant stages.
//!
//! CREDIBLE-1240 slice of CREDIBLE-356. Sibling of [`crate::prune_ledger`],
//! which identifies *low*-criticality dormant stages eligible for pruning.
//! `compute_debt` looks at the opposite end: *high*-criticality dormant
//! stages represent accrued debt, weighted by how many stages short of the
//! target pipeline depth they are.

/// A single stage entry considered for debt accrual.
#[derive(Debug, Clone, PartialEq)]
pub struct DebtStage {
    pub id: String,
    pub criticality: f64,
    pub dormant: bool,
    /// How many stages short of the target pipeline depth this stage is.
    pub stages_short: u32,
}

/// Sum `criticality * stages_short` across high-criticality dormant stages.
///
/// A stage contributes to debt when `dormant` is true AND
/// `criticality >= threshold`. Pure: takes a snapshot, returns a scalar,
/// touches no global state. Returns `0.0` when no stage qualifies
/// (including the empty-input case).
pub fn compute_debt(stages: &[DebtStage], threshold: f64) -> f64 {
    stages
        .iter()
        .filter(|stage| stage.dormant && stage.criticality >= threshold)
        .map(|stage| stage.criticality * stage.stages_short as f64)
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stage(id: &str, criticality: f64, dormant: bool, stages_short: u32) -> DebtStage {
        DebtStage {
            id: id.to_string(),
            criticality,
            dormant,
            stages_short,
        }
    }

    #[test]
    fn empty_input_returns_zero() {
        assert_eq!(compute_debt(&[], 0.5), 0.0);
    }

    #[test]
    fn no_high_crit_dormant_stages_returns_zero() {
        let stages = vec![
            stage("a", 0.1, true, 3),  // low crit, dormant — not counted
            stage("b", 0.9, false, 2), // high crit, active — not counted
        ];
        assert_eq!(compute_debt(&stages, 0.5), 0.0);
    }

    #[test]
    fn sums_crit_times_stages_short_for_high_crit_dormant_stages() {
        let stages = vec![
            stage("a", 0.9, true, 2),  // 1.8
            stage("b", 0.2, true, 5),  // below threshold, excluded
            stage("c", 0.6, true, 3),  // 1.8
            stage("d", 0.7, false, 4), // active, excluded
        ];
        assert!((compute_debt(&stages, 0.5) - 3.6).abs() < f64::EPSILON);
    }

    #[test]
    fn is_pure_does_not_mutate_input() {
        let stages = vec![stage("a", 0.9, true, 1)];
        let before = stages.clone();
        let _ = compute_debt(&stages, 0.5);
        assert_eq!(stages, before);
    }
}
