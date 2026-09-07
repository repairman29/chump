//! CREDIBLE-1049 (CREDIBLE-356 slice): dormant-stage pruning.
//!
//! Sibling of [`crate::live_pct`] — reuses the same `Stage` shape
//! (status + criticality) but answers a different question: not "how alive
//! is this thing" but "which entries are safe to drop from the ledger".
//! A stage is a pruning candidate when it is both **dormant** (terminal:
//! `Complete` or `Failed`, never `Pending`/`Running`/`Healthy`) and
//! **low-criticality** (`Info` or `Warn`, never `Crit` — a `Crit` stage's
//! history stays for audit even once it's done).

use crate::live_pct::{Criticality, Stage, StageStatus};

/// Returns the indices (into `stages`, ascending) of entries eligible for
/// pruning: dormant (`Complete` or `Failed`) *and* low-criticality (`Info`
/// or `Warn`). `Crit` stages are never pruned regardless of status, and
/// stages that haven't reached a terminal status are never pruned regardless
/// of criticality. Deterministic — same input always yields the same output
/// in the same order.
pub fn prune_ledger(stages: &[Stage]) -> Vec<usize> {
    stages
        .iter()
        .enumerate()
        .filter(|(_, stage)| is_dormant(stage.status) && is_low_crit(stage.criticality))
        .map(|(idx, _)| idx)
        .collect()
}

fn is_dormant(status: StageStatus) -> bool {
    matches!(status, StageStatus::Complete | StageStatus::Failed)
}

fn is_low_crit(criticality: Criticality) -> bool {
    !matches!(criticality, Criticality::Crit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_stages_returns_empty() {
        assert_eq!(prune_ledger(&[]), Vec::<usize>::new());
    }

    #[test]
    fn dormant_low_crit_is_pruned() {
        let stages = vec![
            Stage {
                status: StageStatus::Complete,
                criticality: Criticality::Info,
            },
            Stage {
                status: StageStatus::Failed,
                criticality: Criticality::Warn,
            },
        ];
        assert_eq!(prune_ledger(&stages), vec![0, 1]);
    }

    #[test]
    fn crit_stage_never_pruned_even_if_dormant() {
        let stages = vec![Stage {
            status: StageStatus::Complete,
            criticality: Criticality::Crit,
        }];
        assert_eq!(prune_ledger(&stages), Vec::<usize>::new());
    }

    #[test]
    fn non_dormant_stage_never_pruned_even_if_low_crit() {
        let stages = vec![
            Stage {
                status: StageStatus::Pending,
                criticality: Criticality::Info,
            },
            Stage {
                status: StageStatus::Running,
                criticality: Criticality::Warn,
            },
            Stage {
                status: StageStatus::Healthy,
                criticality: Criticality::Info,
            },
        ];
        assert_eq!(prune_ledger(&stages), Vec::<usize>::new());
    }

    #[test]
    fn mixed_stages_returns_only_matching_indices_in_order() {
        let stages = vec![
            Stage {
                status: StageStatus::Complete,
                criticality: Criticality::Crit,
            },
            Stage {
                status: StageStatus::Failed,
                criticality: Criticality::Info,
            },
            Stage {
                status: StageStatus::Running,
                criticality: Criticality::Warn,
            },
            Stage {
                status: StageStatus::Complete,
                criticality: Criticality::Warn,
            },
        ];
        assert_eq!(prune_ledger(&stages), vec![1, 3]);
    }

    #[test]
    fn is_deterministic_across_repeated_calls() {
        let stages = vec![
            Stage {
                status: StageStatus::Complete,
                criticality: Criticality::Info,
            },
            Stage {
                status: StageStatus::Complete,
                criticality: Criticality::Crit,
            },
            Stage {
                status: StageStatus::Failed,
                criticality: Criticality::Warn,
            },
        ];
        let first = prune_ledger(&stages);
        let second = prune_ledger(&stages);
        assert_eq!(first, second);
    }
}
