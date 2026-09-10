//! Trait contract for the Duty Officer (RESILIENT-274 slice, RESILIENT-444).
//!
//! Maps a raw health `Signal` to a response `Tier` (T1 auto-heal, T2 agent
//! runbook, T3 operator escalation) and routes it. See
//! `docs/design/DUTY_OFFICER.md` for the full design.

use anyhow::Result;

/// A raw health signal observed by the fleet (ambient event kind or derived metric).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signal {
    pub kind: String,
    pub detail: String,
}

/// Response tier a signal is routed to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// T1 — deterministic auto-heal, no agent or operator involved.
    AutoHeal,
    /// T2 — agent-run runbook after a reality-check gate.
    Runbook,
    /// T3 — escalate to the operator through the quiet gate.
    Escalate,
}

/// Evaluates a signal into a tier and routes it to the matching action.
pub trait DutyOfficer {
    /// Classify a signal into a response tier.
    fn evaluate(&self, signal: Signal) -> Tier;

    /// Route a signal at the given tier to its action.
    fn route(&self, tier: Tier, signal: Signal) -> Result<()>;
}

/// Mock `DutyOfficer` for tests: classifies by signal kind and records routed
/// actions instead of performing them.
#[derive(Debug, Default)]
pub struct TestDutyOfficer {
    pub routed: std::cell::RefCell<Vec<(Tier, Signal)>>,
}

impl DutyOfficer for TestDutyOfficer {
    fn evaluate(&self, signal: Signal) -> Tier {
        match signal.kind.as_str() {
            "disk_critical" => Tier::AutoHeal,
            "pr_pipeline_wedged" => Tier::Runbook,
            _ => Tier::Escalate,
        }
    }

    fn route(&self, tier: Tier, signal: Signal) -> Result<()> {
        self.routed.borrow_mut().push((tier, signal));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evaluate_and_route_disk_critical() {
        let officer = TestDutyOfficer::default();
        let signal = Signal {
            kind: "disk_critical".to_string(),
            detail: "free_gb=10".to_string(),
        };

        let tier = officer.evaluate(signal.clone());
        assert_eq!(tier, Tier::AutoHeal);

        officer.route(tier, signal.clone()).unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 1);
        assert_eq!(routed[0], (Tier::AutoHeal, signal));
    }
}
