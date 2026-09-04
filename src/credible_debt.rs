//! CREDIBLE-356 slice: debt scoring for dormant pipeline stages.
//!
//! A "stage" here is any tracked unit of work (pillar stage, pipeline
//! phase, etc.) that carries a criticality weight and a count of how many
//! stages it has fallen behind. Debt only accrues for stages that are both
//! dormant (no recent activity) and above the high-criticality threshold —
//! low-crit dormancy is expected slack, not debt.

/// Minimum `crit` value for a stage to count toward debt when dormant.
pub const HIGH_CRIT_THRESHOLD: u32 = 7;

/// A single tracked stage's debt inputs.
#[derive(Debug, Clone, Copy)]
pub struct StageDebtInput {
    /// Criticality weight of this stage (higher = more important).
    pub crit: u32,
    /// How many stages behind the current baseline this stage is.
    pub stages_short: u32,
    /// Whether this stage has had no recent activity.
    pub dormant: bool,
}

/// Computes total debt as the sum of `crit * stages_short` across all
/// dormant stages whose `crit` meets or exceeds [`HIGH_CRIT_THRESHOLD`].
///
/// Stages that are not dormant, or whose `crit` is below the threshold,
/// contribute zero debt.
pub fn compute_debt(stages: &[StageDebtInput]) -> u64 {
    stages
        .iter()
        .filter(|s| s.dormant && s.crit >= HIGH_CRIT_THRESHOLD)
        .map(|s| u64::from(s.crit) * u64::from(s.stages_short))
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sums_only_high_crit_dormant_stages() {
        let stages = vec![
            StageDebtInput {
                crit: 9,
                stages_short: 3,
                dormant: true,
            }, // 27
            StageDebtInput {
                crit: 5,
                stages_short: 10,
                dormant: true,
            }, // below threshold, excluded
            StageDebtInput {
                crit: 8,
                stages_short: 2,
                dormant: false,
            }, // not dormant, excluded
            StageDebtInput {
                crit: 7,
                stages_short: 4,
                dormant: true,
            }, // 28
        ];
        assert_eq!(compute_debt(&stages), 55);
    }

    #[test]
    fn empty_input_yields_zero_debt() {
        assert_eq!(compute_debt(&[]), 0);
    }

    #[test]
    fn no_qualifying_stages_yields_zero_debt() {
        let stages = vec![
            StageDebtInput {
                crit: 1,
                stages_short: 100,
                dormant: true,
            },
            StageDebtInput {
                crit: 10,
                stages_short: 100,
                dormant: false,
            },
        ];
        assert_eq!(compute_debt(&stages), 0);
    }
}
