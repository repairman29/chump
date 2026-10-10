//! Duty Officer standing loop (RESILIENT-274 slice, RESILIENT-445).
//!
//! Polls fleet health signal sources on an interval, looks each signal up
//! in the `PlaybookRegistry`, and routes it to the `DutyOfficer`. See
//! `docs/design/DUTY_OFFICER.md` for the full design, `src/playbook_registry.rs`
//! (RESILIENT-443) for the registry side, and `src/duty_officer.rs`
//! (RESILIENT-444) for the trait side.

use std::time::Duration;

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal, Tier as OfficerTier};
use crate::playbook_registry::{PlaybookRegistry, Tier as RegistryTier};

/// One health signal source the loop polls each tick.
pub trait SignalSource {
    /// Name of the source, used for logging only.
    fn name(&self) -> &str;

    /// Poll for current signals. Empty vec means nothing to report this tick.
    fn poll(&self) -> Vec<Signal>;
}

fn registry_tier_to_officer_tier(tier: RegistryTier) -> OfficerTier {
    match tier {
        RegistryTier::AutoHeal => OfficerTier::AutoHeal,
        RegistryTier::Runbook => OfficerTier::Runbook,
        RegistryTier::Escalate => OfficerTier::Escalate,
    }
}

/// Polls every source once, routing each resulting signal: AC3 — for each
/// signal, calls `registry.get_entry` and then `officer.route`. Falls back
/// to `officer.evaluate` when the signal has no registry entry yet.
fn tick(
    registry: &PlaybookRegistry,
    officer: &impl DutyOfficer,
    sources: &[Box<dyn SignalSource + Send>],
) -> Result<usize> {
    let mut routed = 0;
    for source in sources {
        for signal in source.poll() {
            let tier = match registry.get_entry(&signal.kind) {
                Some(entry) => registry_tier_to_officer_tier(entry.tier),
                None => officer.evaluate(signal.clone()),
            };
            officer.route(tier, signal)?;
            routed += 1;
        }
    }
    Ok(routed)
}

/// Default signal sources: ambient.jsonl, ship-rate, disk, auth, wedges
/// (AC2). RESILIENT-445 wires the loop skeleton — each source is a stub
/// that reports no signals yet; real detection logic per source lands as
/// follow-up gaps against this scaffold.
fn default_sources() -> Vec<Box<dyn SignalSource + Send>> {
    vec![
        Box::new(AmbientJsonlSource),
        Box::new(ShipRateSource),
        Box::new(DiskSource),
        Box::new(AuthSource),
        Box::new(WedgeSource),
    ]
}

struct AmbientJsonlSource;
impl SignalSource for AmbientJsonlSource {
    fn name(&self) -> &str {
        "ambient_jsonl"
    }
    fn poll(&self) -> Vec<Signal> {
        Vec::new()
    }
}

struct ShipRateSource;
impl SignalSource for ShipRateSource {
    fn name(&self) -> &str {
        "ship_rate"
    }
    fn poll(&self) -> Vec<Signal> {
        Vec::new()
    }
}

struct DiskSource;
impl SignalSource for DiskSource {
    fn name(&self) -> &str {
        "disk"
    }
    fn poll(&self) -> Vec<Signal> {
        Vec::new()
    }
}

struct AuthSource;
impl SignalSource for AuthSource {
    fn name(&self) -> &str {
        "auth"
    }
    fn poll(&self) -> Vec<Signal> {
        Vec::new()
    }
}

struct WedgeSource;
impl SignalSource for WedgeSource {
    fn name(&self) -> &str {
        "wedges"
    }
    fn poll(&self) -> Vec<Signal> {
        Vec::new()
    }
}

/// Standing loop (AC1): polls health signal sources on an interval, routing
/// each signal through `registry.get_entry` -> `officer.route`. Runs until
/// the process exits; spawned as a background task behind the
/// `duty_officer` feature flag (AC4, see `src/main.rs`).
pub async fn run_duty_officer_loop(registry: PlaybookRegistry, officer: impl DutyOfficer) {
    let sources = default_sources();
    loop {
        if let Err(err) = tick(&registry, &officer, &sources) {
            tracing::warn!("duty officer loop tick failed: {err:#}");
        }
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::duty_officer::TestDutyOfficer;
    use std::io::Write;

    struct MockSource {
        signals: Vec<Signal>,
    }
    impl SignalSource for MockSource {
        fn name(&self) -> &str {
            "mock"
        }
        fn poll(&self) -> Vec<Signal> {
            self.signals.clone()
        }
    }

    fn registry_with(json: &str) -> PlaybookRegistry {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(file, "{json}").unwrap();
        crate::playbook_registry::load_registry(file.path()).unwrap()
    }

    // AC2: loop reads mock signal sources via this test harness.
    #[test]
    fn tick_routes_signal_from_mock_source_via_registry() {
        let registry = registry_with(
            r#"[{"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-cleanup.sh"}]"#,
        );
        let officer = TestDutyOfficer::default();
        let sources: Vec<Box<dyn SignalSource + Send>> = vec![Box::new(MockSource {
            signals: vec![Signal {
                kind: "disk_critical".to_string(),
                detail: "free_gb=5".to_string(),
            }],
        })];

        let routed = tick(&registry, &officer, &sources).unwrap();
        assert_eq!(routed, 1);

        let routed_calls = officer.routed.borrow();
        assert_eq!(routed_calls.len(), 1);
        assert_eq!(routed_calls[0].0, OfficerTier::AutoHeal);
    }

    #[test]
    fn tick_falls_back_to_officer_evaluate_when_signal_unregistered() {
        let registry = registry_with("[]");
        let officer = TestDutyOfficer::default();
        let sources: Vec<Box<dyn SignalSource + Send>> = vec![Box::new(MockSource {
            signals: vec![Signal {
                kind: "pr_pipeline_wedged".to_string(),
                detail: "n=3".to_string(),
            }],
        })];

        let routed = tick(&registry, &officer, &sources).unwrap();
        assert_eq!(routed, 1);
        let routed_calls = officer.routed.borrow();
        assert_eq!(routed_calls[0].0, OfficerTier::Runbook);
    }

    #[test]
    fn tick_handles_multiple_sources_and_signals() {
        let registry = registry_with("[]");
        let officer = TestDutyOfficer::default();
        let sources: Vec<Box<dyn SignalSource + Send>> = vec![
            Box::new(MockSource {
                signals: vec![Signal {
                    kind: "disk_critical".to_string(),
                    detail: "free_gb=1".to_string(),
                }],
            }),
            Box::new(MockSource {
                signals: vec![Signal {
                    kind: "unknown_signal".to_string(),
                    detail: "".to_string(),
                }],
            }),
        ];

        let routed = tick(&registry, &officer, &sources).unwrap();
        assert_eq!(routed, 2);
        assert_eq!(officer.routed.borrow().len(), 2);
    }

    #[test]
    fn default_sources_cover_all_five_signal_classes() {
        let sources = default_sources();
        let names: Vec<&str> = sources.iter().map(|s| s.name()).collect();
        assert_eq!(
            names,
            vec!["ambient_jsonl", "ship_rate", "disk", "auth", "wedges"]
        );
    }
}
