//! Standing loop that watches health signals and invokes the playbook
//! registry (RESILIENT-274 slice, RESILIENT-445).
//!
//! Wires `playbook_registry::PlaybookRegistry` (RESILIENT-443) and
//! `duty_officer::DutyOfficer` (RESILIENT-444) together: each tick, every
//! configured `SignalSource` is polled for a firing signal, the signal is
//! looked up in the registry, and the resulting tier is routed through the
//! officer. See `docs/design/DUTY_OFFICER.md` §4 for the full contract.

use std::time::Duration;

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal, Tier as DutyTier};
use crate::playbook_registry::{PlaybookRegistry, Tier as RegistryTier};

/// One health-signal watcher, polled once per loop tick.
///
/// Production sources will read ambient.jsonl, `git log --since=1h` (ship
/// rate), disk free, `auth-status.sh`, and fleet_wedge/silent_agent/pr_stuck
/// counts (per DUTY_OFFICER.md §4 step 1). This slice ships the trait plus
/// mock sources exercised by a test harness; wiring real readers is a
/// follow-up slice.
pub trait SignalSource {
    /// Poll for a signal. `None` means nothing fired this tick.
    fn poll(&mut self) -> Option<Signal>;
}

/// Mock source that yields each queued signal once, then stays silent.
///
/// Used both by tests (the harness required by AC2) and as the default
/// no-op source set for the five named categories (ambient.jsonl, ship-rate,
/// disk, auth, wedges) until real readers land.
#[derive(Debug, Default)]
pub struct MockSignalSource {
    queued: Vec<Signal>,
}

impl MockSignalSource {
    pub fn new(queued: Vec<Signal>) -> Self {
        Self { queued }
    }
}

impl SignalSource for MockSignalSource {
    fn poll(&mut self) -> Option<Signal> {
        if self.queued.is_empty() {
            None
        } else {
            Some(self.queued.remove(0))
        }
    }
}

/// The five named health-signal categories from DUTY_OFFICER.md §4 step 1,
/// each backed by a mock source until real readers are wired in.
fn default_signal_sources() -> Vec<Box<dyn SignalSource + Send>> {
    vec![
        Box::new(MockSignalSource::new(Vec::new())), // ambient.jsonl
        Box::new(MockSignalSource::new(Vec::new())), // ship-rate
        Box::new(MockSignalSource::new(Vec::new())), // disk
        Box::new(MockSignalSource::new(Vec::new())), // auth
        Box::new(MockSignalSource::new(Vec::new())), // wedges
    ]
}

fn registry_tier_to_duty_tier(tier: RegistryTier) -> DutyTier {
    match tier {
        RegistryTier::AutoHeal => DutyTier::AutoHeal,
        RegistryTier::Runbook => DutyTier::Runbook,
        RegistryTier::Escalate => DutyTier::Escalate,
    }
}

/// Processes one batch of signals: for each, look it up in `registry` and
/// route the resulting tier through `officer`. Signals with no registry
/// entry fall back to `officer.evaluate` for classification.
///
/// Factored out of `run_duty_officer_loop` so tests can drive it with a
/// synthetic signal batch instead of waiting on a real sleep/poll cycle.
fn process_signals(
    registry: &PlaybookRegistry,
    officer: &impl DutyOfficer,
    signals: Vec<Signal>,
) -> Result<()> {
    for signal in signals {
        let tier = match registry.get_entry(&signal.kind) {
            Some(entry) => registry_tier_to_duty_tier(entry.tier),
            None => officer.evaluate(signal.clone()),
        };
        officer.route(tier, signal)?;
    }
    Ok(())
}

/// Runs the duty-officer standing loop forever: each tick, polls every
/// configured signal source, looks each firing signal up in `registry`, and
/// routes it through `officer`.
pub async fn run_duty_officer_loop(
    registry: PlaybookRegistry,
    officer: impl DutyOfficer,
) -> Result<()> {
    let mut sources = default_signal_sources();
    loop {
        let mut firing = Vec::new();
        for source in sources.iter_mut() {
            if let Some(signal) = source.poll() {
                firing.push(signal);
            }
        }
        process_signals(&registry, &officer, firing)?;
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::duty_officer::TestDutyOfficer;
    use crate::playbook_registry::PlaybookRegistry;

    fn registry_with_disk_critical() -> PlaybookRegistry {
        let raw = r#"[
            {"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-critical-reactor.sh"},
            {"signal": "pr_pipeline_wedged", "tier": 2, "action": "diagnose the blocking check"}
        ]"#;
        let mut file = tempfile::NamedTempFile::new().unwrap();
        std::io::Write::write_all(&mut file, raw.as_bytes()).unwrap();
        crate::playbook_registry::load_registry(file.path()).unwrap()
    }

    #[test]
    fn mock_signal_source_yields_queued_then_none() {
        let mut source = MockSignalSource::new(vec![Signal {
            kind: "disk_critical".to_string(),
            detail: "free_gb=10".to_string(),
        }]);

        assert!(source.poll().is_some());
        assert!(source.poll().is_none());
    }

    #[test]
    fn process_signals_routes_registry_hit_at_registry_tier() {
        let registry = registry_with_disk_critical();
        let officer = TestDutyOfficer::default();
        let signal = Signal {
            kind: "disk_critical".to_string(),
            detail: "free_gb=10".to_string(),
        };

        process_signals(&registry, &officer, vec![signal.clone()]).unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 1);
        assert_eq!(routed[0], (DutyTier::AutoHeal, signal));
    }

    #[test]
    fn process_signals_falls_back_to_officer_evaluate_on_registry_miss() {
        let registry = registry_with_disk_critical();
        let officer = TestDutyOfficer::default();
        let signal = Signal {
            kind: "unregistered_kind".to_string(),
            detail: "whatever".to_string(),
        };

        process_signals(&registry, &officer, vec![signal.clone()]).unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 1);
        // TestDutyOfficer::evaluate defaults unknown kinds to Escalate.
        assert_eq!(routed[0], (DutyTier::Escalate, signal));
    }

    #[test]
    fn process_signals_handles_multiple_sources_in_one_tick() {
        let registry = registry_with_disk_critical();
        let officer = TestDutyOfficer::default();
        let signals = vec![
            Signal {
                kind: "disk_critical".to_string(),
                detail: "free_gb=5".to_string(),
            },
            Signal {
                kind: "pr_pipeline_wedged".to_string(),
                detail: "0 merges in 2h".to_string(),
            },
        ];

        process_signals(&registry, &officer, signals).unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 2);
        assert_eq!(routed[0].0, DutyTier::AutoHeal);
        assert_eq!(routed[1].0, DutyTier::Runbook);
    }
}
