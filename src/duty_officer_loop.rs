//! Standing loop wiring health signals through the Playbook Registry to the
//! Duty Officer (RESILIENT-274 slice, RESILIENT-445).
//!
//! Ties together `playbook_registry::PlaybookRegistry` (RESILIENT-443) and
//! `duty_officer::DutyOfficer` (RESILIENT-444): poll a `SignalSource` for
//! health signals, look each one up in the registry, and route it through
//! the officer. See `docs/design/DUTY_OFFICER.md` for the full design.

use std::collections::VecDeque;
use std::time::Duration;

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal, Tier as DutyTier};
use crate::playbook_registry::{PlaybookRegistry, Tier as RegistryTier};

/// Source of health signals the duty officer loop polls each cycle.
///
/// Production sources would tail `ambient.jsonl` and sample ship-rate, disk,
/// auth, and wedge state; `MockSignalSource` below is the test harness
/// implementation (AC2).
pub trait SignalSource {
    /// Returns the signals observed since the last poll (possibly empty).
    fn poll(&mut self) -> Vec<Signal>;
}

/// Test harness `SignalSource`: drains a fixed queue of signals, one poll's
/// worth of ambient/ship-rate/disk/auth/wedge signals at a time.
#[derive(Debug, Default)]
pub struct MockSignalSource {
    queue: VecDeque<Signal>,
}

impl MockSignalSource {
    /// Builds a mock source that replays `signals` in order, one per `poll`
    /// call, then returns empty batches once exhausted.
    pub fn new(signals: Vec<Signal>) -> Self {
        Self {
            queue: signals.into(),
        }
    }
}

impl SignalSource for MockSignalSource {
    fn poll(&mut self) -> Vec<Signal> {
        self.queue.pop_front().into_iter().collect()
    }
}

fn to_duty_tier(tier: RegistryTier) -> DutyTier {
    match tier {
        RegistryTier::AutoHeal => DutyTier::AutoHeal,
        RegistryTier::Runbook => DutyTier::Runbook,
        RegistryTier::Escalate => DutyTier::Escalate,
    }
}

/// Runs the duty officer standing loop for `iterations` poll cycles,
/// sleeping `poll_interval` between cycles.
///
/// Each cycle: poll `source` for signals; for each signal, look it up via
/// `registry.get_entry` (AC3) — on a hit, route the registry's tier through
/// `officer.route`; on a miss, fall back to `officer.evaluate` so unknown
/// signals still reach the operator-escalation tier rather than being
/// silently dropped.
pub async fn run_duty_officer_loop(
    registry: PlaybookRegistry,
    officer: impl DutyOfficer,
    mut source: impl SignalSource,
    iterations: usize,
    poll_interval: Duration,
) -> Result<()> {
    for _ in 0..iterations {
        for signal in source.poll() {
            let tier = match registry.get_entry(&signal.kind) {
                Some(entry) => to_duty_tier(entry.tier),
                None => officer.evaluate(signal.clone()),
            };
            officer.route(tier, signal)?;
        }
        tokio::time::sleep(poll_interval).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::duty_officer::TestDutyOfficer;
    use std::io::Write;
    use std::rc::Rc;

    // `run_duty_officer_loop` takes `officer: impl DutyOfficer` by value
    // (AC1), so a test that wants to inspect `TestDutyOfficer::routed` after
    // the loop runs needs a shared handle rather than moving the officer in
    // outright. `Rc<TestDutyOfficer>` gives us that handle; this delegates
    // the trait through to the inner `RefCell`-backed recorder.
    impl DutyOfficer for Rc<TestDutyOfficer> {
        fn evaluate(&self, signal: Signal) -> DutyTier {
            (**self).evaluate(signal)
        }

        fn route(&self, tier: DutyTier, signal: Signal) -> Result<()> {
            (**self).route(tier, signal)
        }
    }

    fn registry_fixture() -> PlaybookRegistry {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(
            file,
            r#"[
                {{"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-cleanup.sh"}},
                {{"signal": "pr_pipeline_wedged", "tier": 2, "action": "diagnose the blocking check"}}
            ]"#
        )
        .unwrap();
        crate::playbook_registry::load_registry(file.path()).unwrap()
    }

    #[tokio::test]
    async fn routes_known_signal_via_registry_tier() {
        let registry = registry_fixture();
        let officer = TestDutyOfficer::default();
        let signal = Signal {
            kind: "disk_critical".to_string(),
            detail: "free_gb=10".to_string(),
        };
        let source = MockSignalSource::new(vec![signal.clone()]);

        run_duty_officer_loop(registry, officer, source, 1, Duration::from_millis(0))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn routes_known_and_unknown_signals_across_mock_sources() {
        let registry = registry_fixture();
        let officer = Rc::new(TestDutyOfficer::default());
        let officer_handle = Rc::clone(&officer);

        // Mirrors the 5 mock signal sources named in AC2: ambient.jsonl,
        // ship-rate, disk, auth, wedges. Only the ones the registry knows
        // about hit the registry tier; the rest fall back to
        // `officer.evaluate`.
        let signals = vec![
            Signal {
                kind: "disk_critical".to_string(),
                detail: "ambient.jsonl: free_gb=5".to_string(),
            },
            Signal {
                kind: "pr_pipeline_wedged".to_string(),
                detail: "wedges: queue stalled 30m".to_string(),
            },
            Signal {
                kind: "ship_rate_drop".to_string(),
                detail: "ship-rate: 2/10 last hour".to_string(),
            },
            Signal {
                kind: "farmer_auth_dead".to_string(),
                detail: "auth: oauth token expired".to_string(),
            },
        ];
        let expected_routed = signals.len();
        let source = MockSignalSource::new(signals);

        run_duty_officer_loop(
            registry,
            officer_handle,
            source,
            expected_routed,
            Duration::from_millis(0),
        )
        .await
        .unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), expected_routed);
        // Known-to-the-registry signals route at the registry's tier...
        assert_eq!(routed[0].0, DutyTier::AutoHeal); // disk_critical
        assert_eq!(routed[1].0, DutyTier::Runbook); // pr_pipeline_wedged
                                                    // ...unknown signals fall back to officer.evaluate's default tier.
        assert_eq!(routed[2].0, DutyTier::Escalate); // ship_rate_drop
        assert_eq!(routed[3].0, DutyTier::Escalate); // farmer_auth_dead
    }

    #[tokio::test]
    async fn empty_queue_runs_without_error() {
        let registry = registry_fixture();
        let officer = TestDutyOfficer::default();
        let source = MockSignalSource::new(vec![]);

        run_duty_officer_loop(registry, officer, source, 3, Duration::from_millis(0))
            .await
            .unwrap();
    }
}
