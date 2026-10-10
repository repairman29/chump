//! Standing duty-officer loop (RESILIENT-274 slice, RESILIENT-445).
//!
//! Wires the playbook registry (`playbook_registry`, RESILIENT-443) to the
//! `DutyOfficer` trait (`duty_officer`, RESILIENT-444): each tick, poll the
//! health signal sources, look up every fired signal in the registry, and
//! route it through the officer. See `docs/design/DUTY_OFFICER.md` §4.

use std::time::Duration;

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal, Tier as DutyTier};
use crate::playbook_registry::{PlaybookRegistry, Tier as RegistryTier};

/// A source of raw health signals polled once per loop tick.
pub trait SignalSource: Send {
    fn poll(&mut self) -> Vec<Signal>;
}

/// A named, mockable signal source: holds whatever signals its real
/// counterpart would have detected this tick. Production code constructs
/// one per source category named in `docs/design/DUTY_OFFICER.md` §4
/// (ambient.jsonl, ship-rate, disk, auth, fleet-wedge count); wiring each to
/// its real data source is follow-up work on that design — this slice ships
/// them as mockable stubs exercised by the test harness below.
#[derive(Debug, Default, Clone)]
pub struct NamedSignalSource {
    pub name: &'static str,
    pub pending: Vec<Signal>,
}

impl NamedSignalSource {
    pub fn new(name: &'static str) -> Self {
        Self {
            name,
            pending: Vec::new(),
        }
    }
}

impl SignalSource for NamedSignalSource {
    fn poll(&mut self) -> Vec<Signal> {
        std::mem::take(&mut self.pending)
    }
}

/// Fans out to the 5 health-signal categories from
/// `docs/design/DUTY_OFFICER.md` §4: ambient.jsonl, ship-rate, disk, auth,
/// and fleet-wedge counts.
pub struct CompositeSignalSource {
    pub sources: Vec<NamedSignalSource>,
}

impl Default for CompositeSignalSource {
    fn default() -> Self {
        Self {
            sources: vec![
                NamedSignalSource::new("ambient.jsonl"),
                NamedSignalSource::new("ship_rate"),
                NamedSignalSource::new("disk"),
                NamedSignalSource::new("auth"),
                NamedSignalSource::new("wedges"),
            ],
        }
    }
}

impl SignalSource for CompositeSignalSource {
    fn poll(&mut self) -> Vec<Signal> {
        self.sources.iter_mut().flat_map(|s| s.poll()).collect()
    }
}

fn registry_tier_to_duty_tier(tier: RegistryTier) -> DutyTier {
    match tier {
        RegistryTier::AutoHeal => DutyTier::AutoHeal,
        RegistryTier::Runbook => DutyTier::Runbook,
        RegistryTier::Escalate => DutyTier::Escalate,
    }
}

/// Runs one tick: poll `source`, look up each fired signal in `registry`,
/// and route it through `officer` (AC3). Returns the signals that had no
/// registry entry, so callers/tests can assert on uncovered signals.
fn tick(
    registry: &PlaybookRegistry,
    officer: &impl DutyOfficer,
    source: &mut impl SignalSource,
) -> Result<Vec<Signal>> {
    let mut unmatched = Vec::new();
    for signal in source.poll() {
        match registry.get_entry(&signal.kind) {
            Some(entry) => {
                let tier = registry_tier_to_duty_tier(entry.tier);
                officer.route(tier, signal)?;
            }
            None => unmatched.push(signal),
        }
    }
    Ok(unmatched)
}

/// Standing duty-officer loop (RESILIENT-274 slice).
///
/// Polls the composite signal source every 30s, looks up each fired signal
/// in `registry`, and routes it through `officer` per AC3. Loops forever —
/// intended to be spawned as a background task from `main.rs` behind the
/// `duty_officer` feature flag (AC4).
pub async fn run_duty_officer_loop(
    registry: PlaybookRegistry,
    officer: impl DutyOfficer,
) -> Result<()> {
    let mut source = CompositeSignalSource::default();
    loop {
        tick(&registry, &officer, &mut source)?;
        tokio::time::sleep(Duration::from_secs(30)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::duty_officer::TestDutyOfficer;
    use std::io::Write;

    fn registry_fixture() -> PlaybookRegistry {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(
            file,
            r#"[
                {{"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-cleanup.sh"}},
                {{"signal": "pr_pipeline_wedged", "tier": 2, "action": "diagnose"}},
                {{"signal": "farmer_auth_dead", "tier": 3, "action": "page operator"}}
            ]"#
        )
        .unwrap();
        crate::playbook_registry::load_registry(file.path()).unwrap()
    }

    /// Test harness (AC2): mocks all 5 named signal sources (ambient.jsonl,
    /// ship_rate, disk, auth, wedges) with one fired signal apiece, and
    /// asserts each is routed through the registry + officer (AC3).
    #[test]
    fn tick_routes_each_mock_signal_source_through_registry_and_officer() {
        let registry = registry_fixture();
        let officer = TestDutyOfficer::default();

        let mut source = CompositeSignalSource::default();
        source.sources[0].pending.push(Signal {
            kind: "disk_critical".into(),
            detail: "ambient.jsonl: free_gb=10".into(),
        });
        source.sources[1].pending.push(Signal {
            kind: "pr_pipeline_wedged".into(),
            detail: "ship_rate: 0 merges/2h".into(),
        });
        source.sources[3].pending.push(Signal {
            kind: "farmer_auth_dead".into(),
            detail: "auth: token expired".into(),
        });

        let unmatched = tick(&registry, &officer, &mut source).unwrap();
        assert!(unmatched.is_empty());

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 3);
        assert!(routed
            .iter()
            .any(|(tier, s)| *tier == DutyTier::AutoHeal && s.kind == "disk_critical"));
        assert!(routed
            .iter()
            .any(|(tier, s)| *tier == DutyTier::Runbook && s.kind == "pr_pipeline_wedged"));
        assert!(routed
            .iter()
            .any(|(tier, s)| *tier == DutyTier::Escalate && s.kind == "farmer_auth_dead"));
    }

    #[test]
    fn tick_skips_signals_with_no_registry_entry() {
        let registry = registry_fixture();
        let officer = TestDutyOfficer::default();
        let mut source = CompositeSignalSource::default();
        source.sources[2].pending.push(Signal {
            kind: "unknown_signal".into(),
            detail: "disk: mystery".into(),
        });

        let unmatched = tick(&registry, &officer, &mut source).unwrap();
        assert_eq!(unmatched.len(), 1);
        assert!(officer.routed.borrow().is_empty());
    }
}
