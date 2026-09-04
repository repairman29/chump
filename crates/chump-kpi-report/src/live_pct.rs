//! CREDIBLE-835 (CREDIBLE-356 slice): Crit-weighted "live" percentage.
//!
//! A demo/mission is made of discrete stages (e.g. build, deploy, smoke-test).
//! Not every stage matters equally — a `Crit` stage failing to come up is a
//! very different signal than an `Info` stage lagging. `compute_live_pct`
//! turns a stage list into a single 0.0-1.0 number: the fraction of
//! *criticality weight* that has reached `Running` or later, so a dashboard
//! can report "how alive is this thing" without the reader needing to scan
//! every individual stage status.

/// Lifecycle status of a single stage. Ordered so `>=` comparison against
/// [`StageStatus::Running`] is the "is this stage live" test the KPI report
/// and any future dashboard consumer share.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum StageStatus {
    /// Not yet started.
    Pending,
    /// Actively executing but not yet confirmed healthy.
    Running,
    /// Confirmed healthy / reachable.
    Healthy,
    /// Terminated successfully.
    Complete,
    /// Terminated unsuccessfully. Ranked above `Complete` so a failed stage
    /// still counts as "live" (it ran) for the purposes of this metric —
    /// `compute_live_pct` measures liveness, not success.
    Failed,
}

/// Relative importance of a stage, used as the weight in the Crit-weighted
/// average computed by [`compute_live_pct`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Criticality {
    Info,
    Warn,
    Crit,
}

impl Criticality {
    /// Numeric weight backing the Crit-weighted average. `Crit` stages count
    /// 4x an `Info` stage, `Warn` 2x — deliberately non-linear so a single
    /// down `Crit` stage visibly drags the overall percentage instead of
    /// being diluted by a long tail of `Info` stages.
    fn weight(self) -> f64 {
        match self {
            Criticality::Info => 1.0,
            Criticality::Warn => 2.0,
            Criticality::Crit => 4.0,
        }
    }
}

/// A single stage in a mission/demo pipeline, as consumed by
/// [`compute_live_pct`].
#[derive(Debug, Clone, Copy)]
pub struct Stage {
    pub status: StageStatus,
    pub criticality: Criticality,
}

/// Returns the Crit-weighted fraction of `stages` whose status is
/// `>= StageStatus::Running` (i.e. `Running`, `Healthy`, `Complete`, or
/// `Failed` — anything past `Pending`).
///
/// Each stage contributes its [`Criticality::weight`] to the denominator,
/// and that same weight to the numerator only if its status has reached
/// `Running` or later. An empty slice returns `0.0` rather than `NaN`.
///
/// # Examples
///
/// ```
/// use chump_kpi_report::live_pct::{compute_live_pct, Criticality, Stage, StageStatus};
///
/// let stages = vec![
///     Stage { status: StageStatus::Healthy, criticality: Criticality::Crit },
///     Stage { status: StageStatus::Pending, criticality: Criticality::Info },
/// ];
/// // Crit weight (4.0) is live, Info weight (1.0) is not: 4.0 / 5.0 = 0.8
/// assert!((compute_live_pct(&stages) - 0.8).abs() < f64::EPSILON);
/// ```
pub fn compute_live_pct(stages: &[Stage]) -> f64 {
    if stages.is_empty() {
        return 0.0;
    }

    let mut total_weight = 0.0;
    let mut live_weight = 0.0;
    for stage in stages {
        let w = stage.criticality.weight();
        total_weight += w;
        if stage.status >= StageStatus::Running {
            live_weight += w;
        }
    }

    if total_weight == 0.0 {
        0.0
    } else {
        live_weight / total_weight
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_stages_returns_zero() {
        assert_eq!(compute_live_pct(&[]), 0.0);
    }

    #[test]
    fn all_pending_is_zero() {
        let stages = vec![
            Stage {
                status: StageStatus::Pending,
                criticality: Criticality::Crit,
            },
            Stage {
                status: StageStatus::Pending,
                criticality: Criticality::Info,
            },
        ];
        assert_eq!(compute_live_pct(&stages), 0.0);
    }

    #[test]
    fn all_running_or_later_is_one() {
        let stages = vec![
            Stage {
                status: StageStatus::Running,
                criticality: Criticality::Crit,
            },
            Stage {
                status: StageStatus::Complete,
                criticality: Criticality::Info,
            },
            Stage {
                status: StageStatus::Failed,
                criticality: Criticality::Warn,
            },
        ];
        assert_eq!(compute_live_pct(&stages), 1.0);
    }

    #[test]
    fn crit_weighting_dominates() {
        let stages = vec![
            Stage {
                status: StageStatus::Healthy,
                criticality: Criticality::Crit,
            },
            Stage {
                status: StageStatus::Pending,
                criticality: Criticality::Info,
            },
        ];
        // 4.0 live / (4.0 + 1.0) total
        assert!((compute_live_pct(&stages) - 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn mixed_weights_partial_live() {
        let stages = vec![
            Stage {
                status: StageStatus::Running,
                criticality: Criticality::Warn,
            },
            Stage {
                status: StageStatus::Pending,
                criticality: Criticality::Crit,
            },
        ];
        // 2.0 live / (2.0 + 4.0) total
        assert!((compute_live_pct(&stages) - (2.0 / 6.0)).abs() < f64::EPSILON);
    }

    #[test]
    fn status_ordering_matches_liveness_semantics() {
        assert!(StageStatus::Running >= StageStatus::Running);
        assert!(StageStatus::Healthy >= StageStatus::Running);
        assert!(StageStatus::Failed >= StageStatus::Running);
        assert!(StageStatus::Pending < StageStatus::Running);
    }
}
