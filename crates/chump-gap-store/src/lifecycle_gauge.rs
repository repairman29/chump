//! CapabilityLifecycleGauge — CREDIBLE-1034 (CREDIBLE-299 slice).
//!
//! Tracks a single capability's progression through the CREDIBLE lifecycle:
//! built -> merged -> deployed -> wired -> running -> doing-its-job.
//! Stage order is fixed; transitions must move strictly forward so a
//! capability can never be reported as "further along" than it actually is
//! nor silently rewound by an out-of-order status update.

use std::fmt;

/// The six CREDIBLE lifecycle stages, in the order a capability must pass
/// through them. `PartialOrd`/`Ord` follow declaration order, so `Built <
/// DoingItsJob` etc. hold naturally.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum LifecycleStage {
    Built,
    Merged,
    Deployed,
    Wired,
    Running,
    DoingItsJob,
}

impl fmt::Display for LifecycleStage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            LifecycleStage::Built => "built",
            LifecycleStage::Merged => "merged",
            LifecycleStage::Deployed => "deployed",
            LifecycleStage::Wired => "wired",
            LifecycleStage::Running => "running",
            LifecycleStage::DoingItsJob => "doing-its-job",
        };
        f.write_str(s)
    }
}

/// Error returned when a requested stage update would not move the
/// capability strictly forward.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutOfOrderTransition {
    pub capability_id: String,
    pub current_stage: LifecycleStage,
    pub attempted_stage: LifecycleStage,
}

impl fmt::Display for OutOfOrderTransition {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "capability '{}' is at stage '{}'; refusing out-of-order update to '{}'",
            self.capability_id, self.current_stage, self.attempted_stage
        )
    }
}

impl std::error::Error for OutOfOrderTransition {}

/// Tracks the current lifecycle stage of a single capability.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapabilityLifecycleGauge {
    capability_id: String,
    stage: LifecycleStage,
}

impl CapabilityLifecycleGauge {
    /// Creates a new gauge for `capability_id`, starting at `LifecycleStage::Built`.
    pub fn new(capability_id: impl Into<String>) -> Self {
        Self {
            capability_id: capability_id.into(),
            stage: LifecycleStage::Built,
        }
    }

    /// Creates a new gauge for `capability_id`, starting at an explicit stage
    /// (e.g. when reconstructing a gauge from a prior report).
    pub fn with_stage(capability_id: impl Into<String>, stage: LifecycleStage) -> Self {
        Self {
            capability_id: capability_id.into(),
            stage,
        }
    }

    pub fn capability_id(&self) -> &str {
        &self.capability_id
    }

    pub fn stage(&self) -> LifecycleStage {
        self.stage
    }

    /// Attempts to move the capability to `next`. Only succeeds when `next`
    /// is strictly later than the current stage; an equal or earlier stage
    /// is rejected as an out-of-order update rather than silently ignored
    /// or applied, so callers can distinguish "already there" / "regression"
    /// from a genuine forward transition.
    pub fn transition_to(&mut self, next: LifecycleStage) -> Result<(), OutOfOrderTransition> {
        if next <= self.stage {
            return Err(OutOfOrderTransition {
                capability_id: self.capability_id.clone(),
                current_stage: self.stage,
                attempted_stage: next,
            });
        }
        self.stage = next;
        Ok(())
    }

    /// True once the capability has reached the terminal `DoingItsJob` stage.
    pub fn is_done(&self) -> bool {
        self.stage == LifecycleStage::DoingItsJob
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_gauge_starts_at_built() {
        let g = CapabilityLifecycleGauge::new("cap-1");
        assert_eq!(g.stage(), LifecycleStage::Built);
        assert_eq!(g.capability_id(), "cap-1");
        assert!(!g.is_done());
    }

    #[test]
    fn valid_forward_transition_succeeds() {
        let mut g = CapabilityLifecycleGauge::new("cap-1");
        assert!(g.transition_to(LifecycleStage::Merged).is_ok());
        assert_eq!(g.stage(), LifecycleStage::Merged);
        assert!(g.transition_to(LifecycleStage::Deployed).is_ok());
        assert_eq!(g.stage(), LifecycleStage::Deployed);
    }

    #[test]
    fn valid_transition_can_skip_stages() {
        let mut g = CapabilityLifecycleGauge::new("cap-1");
        assert!(g.transition_to(LifecycleStage::Running).is_ok());
        assert_eq!(g.stage(), LifecycleStage::Running);
    }

    #[test]
    fn reaching_doing_its_job_marks_done() {
        let mut g = CapabilityLifecycleGauge::with_stage("cap-1", LifecycleStage::Running);
        assert!(!g.is_done());
        g.transition_to(LifecycleStage::DoingItsJob).unwrap();
        assert!(g.is_done());
    }

    #[test]
    fn out_of_order_backward_update_is_rejected() {
        let mut g = CapabilityLifecycleGauge::with_stage("cap-1", LifecycleStage::Running);
        let err = g
            .transition_to(LifecycleStage::Built)
            .expect_err("backward transition must be rejected");
        assert_eq!(err.current_stage, LifecycleStage::Running);
        assert_eq!(err.attempted_stage, LifecycleStage::Built);
        // Stage must remain unchanged after a rejected transition.
        assert_eq!(g.stage(), LifecycleStage::Running);
    }

    #[test]
    fn duplicate_same_stage_update_is_rejected() {
        let mut g = CapabilityLifecycleGauge::with_stage("cap-1", LifecycleStage::Deployed);
        let err = g
            .transition_to(LifecycleStage::Deployed)
            .expect_err("same-stage update must be rejected");
        assert_eq!(err.current_stage, LifecycleStage::Deployed);
        assert_eq!(err.attempted_stage, LifecycleStage::Deployed);
    }

    #[test]
    fn stage_ordering_matches_declaration_order() {
        assert!(LifecycleStage::Built < LifecycleStage::Merged);
        assert!(LifecycleStage::Merged < LifecycleStage::Deployed);
        assert!(LifecycleStage::Deployed < LifecycleStage::Wired);
        assert!(LifecycleStage::Wired < LifecycleStage::Running);
        assert!(LifecycleStage::Running < LifecycleStage::DoingItsJob);
    }
}
