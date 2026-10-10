//! Standing Duty Officer loop (RESILIENT-274 slice, RESILIENT-445).
//!
//! Polls health signal sources (ambient.jsonl tail, ship-rate, disk, auth,
//! wedge scan in production), looks each signal up in the `PlaybookRegistry`
//! (RESILIENT-443), and routes it through a `DutyOfficer` (RESILIENT-444).
//! See `docs/design/DUTY_OFFICER.md` for the full design.

use std::collections::VecDeque;
use std::time::Duration;

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal, Tier as OfficerTier};
use crate::playbook_registry::{PlaybookRegistry, Tier as RegistryTier};

/// Supplies raw health signals for the duty officer loop to evaluate.
///
/// Production callers implement this against the real sources named in
/// RESILIENT-274 (ambient.jsonl tail, ship-rate check, disk check,
/// auth-status check, wedge scan). Tests use `MockSignalSource`, which
/// plays back a fixed sequence of signal batches.
pub trait SignalSource {
    fn poll(&mut self) -> Vec<Signal>;
}

/// Test harness signal source: plays back pre-recorded batches in order,
/// then returns no further signals. Used to exercise the loop against
/// canned ambient.jsonl / ship-rate / disk / auth / wedge signals without
/// touching real fleet state.
#[derive(Debug, Default)]
pub struct MockSignalSource {
    batches: VecDeque<Vec<Signal>>,
}

impl MockSignalSource {
    pub fn new(batches: Vec<Vec<Signal>>) -> Self {
        Self {
            batches: batches.into(),
        }
    }
}

impl SignalSource for MockSignalSource {
    fn poll(&mut self) -> Vec<Signal> {
        self.batches.pop_front().unwrap_or_default()
    }
}

fn to_officer_tier(tier: RegistryTier) -> OfficerTier {
    match tier {
        RegistryTier::AutoHeal => OfficerTier::AutoHeal,
        RegistryTier::Runbook => OfficerTier::Runbook,
        RegistryTier::Escalate => OfficerTier::Escalate,
    }
}

/// Runs the standing duty-officer loop: poll `source` for signals, look each
/// up in `registry`, and route the matching tier through `officer`.
///
/// Signals with no registry entry are skipped (unregistered signal kinds are
/// not yet playbooked — logging that gap is a job for the caller, not this
/// loop). Stops after `max_empty_polls` consecutive empty polls, which lets
/// tests run the loop to completion; production callers pass `usize::MAX` to
/// run forever.
pub async fn run_duty_officer_loop(
    registry: PlaybookRegistry,
    officer: impl DutyOfficer,
    mut source: impl SignalSource,
    poll_interval: Duration,
    max_empty_polls: usize,
) -> Result<()> {
    let mut empty_polls = 0usize;
    loop {
        let signals = source.poll();

        if signals.is_empty() {
            empty_polls += 1;
            if empty_polls >= max_empty_polls {
                return Ok(());
            }
            tokio::time::sleep(poll_interval).await;
            continue;
        }
        empty_polls = 0;

        for signal in signals {
            if let Some(entry) = registry.get_entry(&signal.kind) {
                let tier = to_officer_tier(entry.tier);
                officer.route(tier, signal)?;
            }
        }

        tokio::time::sleep(poll_interval).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::duty_officer::TestDutyOfficer;
    use std::io::Write;

    fn signal(kind: &str) -> Signal {
        Signal {
            kind: kind.to_string(),
            detail: String::new(),
        }
    }

    fn registry_with_five_signal_sources() -> PlaybookRegistry {
        // Covers all 5 mock signal sources named in RESILIENT-445 AC2:
        // ambient.jsonl, ship-rate, disk, auth, wedges.
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(
            file,
            r#"[
                {{"signal": "ambient_lessons_injection_active", "tier": 1, "action": "noop"}},
                {{"signal": "ship_rate_low", "tier": 2, "action": "investigate ship rate"}},
                {{"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-cleanup.sh"}},
                {{"signal": "farmer_auth_dead", "tier": 3, "action": "page operator"}},
                {{"signal": "pr_pipeline_wedged", "tier": 2, "action": "diagnose the blocking check"}}
            ]"#
        )
        .unwrap();

        crate::playbook_registry::load_registry(file.path()).expect("fixture registry loads")
    }

    #[tokio::test]
    async fn routed_tiers_match_registry_entries() {
        let registry = registry_with_five_signal_sources();
        let officer = std::rc::Rc::new(TestDutyOfficer::default());

        struct RcOfficer(std::rc::Rc<TestDutyOfficer>);
        impl DutyOfficer for RcOfficer {
            fn evaluate(&self, signal: Signal) -> OfficerTier {
                self.0.evaluate(signal)
            }
            fn route(&self, tier: OfficerTier, signal: Signal) -> Result<()> {
                self.0.route(tier, signal)
            }
        }

        let batch = vec![
            signal("ambient_lessons_injection_active"),
            signal("ship_rate_low"),
            signal("disk_critical"),
            signal("farmer_auth_dead"),
            signal("pr_pipeline_wedged"),
            signal("unregistered_signal_kind"),
        ];
        let source = MockSignalSource::new(vec![batch]);

        run_duty_officer_loop(
            registry,
            RcOfficer(officer.clone()),
            source,
            Duration::from_millis(0),
            1,
        )
        .await
        .expect("loop should finish once the mock source goes dry");

        let routed = officer.routed.borrow();
        // The unregistered signal is dropped: only the 5 registered sources route.
        assert_eq!(routed.len(), 5);
        assert_eq!(
            routed[0],
            (
                OfficerTier::AutoHeal,
                signal("ambient_lessons_injection_active")
            )
        );
        assert_eq!(routed[1], (OfficerTier::Runbook, signal("ship_rate_low")));
        assert_eq!(routed[2], (OfficerTier::AutoHeal, signal("disk_critical")));
        assert_eq!(
            routed[3],
            (OfficerTier::Escalate, signal("farmer_auth_dead"))
        );
        assert_eq!(
            routed[4],
            (OfficerTier::Runbook, signal("pr_pipeline_wedged"))
        );
    }

    #[tokio::test]
    async fn empty_source_stops_loop_after_max_empty_polls() {
        let registry = PlaybookRegistry::default();
        let officer = TestDutyOfficer::default();
        let source = MockSignalSource::new(vec![]);

        run_duty_officer_loop(registry, officer, source, Duration::from_millis(0), 1)
            .await
            .expect("loop with no signals should terminate under the test harness");
    }
}
