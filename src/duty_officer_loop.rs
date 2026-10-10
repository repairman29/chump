//! Standing duty-officer loop (RESILIENT-274 slice, RESILIENT-445).
//!
//! Wires the two halves shipped by RESILIENT-443 (`playbook_registry`) and
//! RESILIENT-444 (`duty_officer`) into a running loop: poll health signals,
//! look each one up in the registry, and route it through the `DutyOfficer`.
//! See `docs/design/DUTY_OFFICER.md` for the full design and
//! `docs/process/PLAYBOOK_REGISTRY.yaml` for the real registry contents.
//!
//! Started from `src/main.rs` behind the `duty_officer` feature flag.

use std::collections::VecDeque;
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal, Tier as OfficerTier};
use crate::playbook_registry::{PlaybookRegistry, Tier as RegistryTier};

/// Default location of the ambient event stream the production signal
/// source tails for health signals.
const DEFAULT_AMBIENT_PATH: &str = ".chump-locks/ambient.jsonl";

/// Default wait between poll cycles in production.
const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(30);

/// Produces the next batch of health signals to evaluate. The production
/// implementation (`AmbientSignalSource`) tails `ambient.jsonl`, where
/// ship-rate, disk, auth, and wedge detectors already emit their findings
/// as events (`disk_critical`, `farmer_auth_dead`, `fleet_wedge`,
/// `pr_stuck`, ...). Tests supply a fixed/mock sequence instead.
pub trait SignalSource {
    fn poll(&mut self) -> Vec<Signal>;
}

/// Tails `ambient.jsonl` for newly appended lines and maps each one's
/// `kind` field to a `Signal`. Lines that aren't valid JSON or lack a
/// `kind` field are skipped rather than failing the whole poll.
pub struct AmbientSignalSource {
    path: PathBuf,
    byte_offset: u64,
}

impl AmbientSignalSource {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            byte_offset: 0,
        }
    }

    pub fn at_default_path() -> Self {
        Self::new(DEFAULT_AMBIENT_PATH)
    }
}

impl SignalSource for AmbientSignalSource {
    fn poll(&mut self) -> Vec<Signal> {
        let Ok(contents) = fs::read(&self.path) else {
            return Vec::new();
        };
        if (contents.len() as u64) < self.byte_offset {
            // File was truncated/rotated since last poll; restart from the top.
            self.byte_offset = 0;
        }
        let new_bytes = &contents[self.byte_offset as usize..];
        self.byte_offset = contents.len() as u64;

        String::from_utf8_lossy(new_bytes)
            .lines()
            .filter_map(parse_ambient_line)
            .collect()
    }
}

fn parse_ambient_line(line: &str) -> Option<Signal> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let kind = value.get("kind")?.as_str()?.to_string();
    Some(Signal {
        kind,
        detail: line.to_string(),
    })
}

/// Test harness `SignalSource`: yields one pre-loaded batch of signals per
/// `poll()` call, then empty batches once exhausted. Used by tests to
/// simulate ambient.jsonl, ship-rate, disk, auth, and wedge signals without
/// touching the filesystem.
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

fn registry_tier_to_officer_tier(tier: RegistryTier) -> OfficerTier {
    match tier {
        RegistryTier::AutoHeal => OfficerTier::AutoHeal,
        RegistryTier::Runbook => OfficerTier::Runbook,
        RegistryTier::Escalate => OfficerTier::Escalate,
    }
}

/// Looks `signal` up in `registry` and routes it through `officer`. Falls
/// back to `officer.evaluate` when the registry has no entry for this
/// signal's kind, so an unregistered signal still gets routed (to
/// `Escalate` by the `TestDutyOfficer`'s default, or whatever the
/// production `DutyOfficer` decides) instead of being silently dropped.
fn evaluate_and_route(
    registry: &PlaybookRegistry,
    officer: &impl DutyOfficer,
    signal: Signal,
) -> Result<()> {
    let tier = match registry.get_entry(&signal.kind) {
        Some(entry) => registry_tier_to_officer_tier(entry.tier),
        None => officer.evaluate(signal.clone()),
    };
    officer.route(tier, signal)
}

/// Runs the standing duty-officer loop against the production signal
/// source (`AmbientSignalSource` at `.chump-locks/ambient.jsonl`), forever,
/// sleeping `DEFAULT_POLL_INTERVAL` between polls. This is the entry point
/// started from `src/main.rs` behind the `duty_officer` feature flag.
pub async fn run_duty_officer_loop(
    registry: PlaybookRegistry,
    officer: impl DutyOfficer,
) -> Result<()> {
    run_duty_officer_loop_with_source(
        registry,
        officer,
        AmbientSignalSource::at_default_path(),
        DEFAULT_POLL_INTERVAL,
        None,
    )
    .await
}

/// Same loop as `run_duty_officer_loop`, parameterized over the signal
/// source, poll interval, and iteration count — the hook tests use to
/// inject a `MockSignalSource` and bound the run instead of looping
/// forever. `max_iterations: None` loops until the process is killed;
/// `Some(n)` returns after `n` poll cycles.
pub async fn run_duty_officer_loop_with_source(
    registry: PlaybookRegistry,
    officer: impl DutyOfficer,
    mut source: impl SignalSource,
    poll_interval: Duration,
    max_iterations: Option<usize>,
) -> Result<()> {
    let mut iterations = 0usize;
    loop {
        for signal in source.poll() {
            evaluate_and_route(&registry, &officer, signal)?;
        }

        iterations += 1;
        if let Some(max) = max_iterations {
            if iterations >= max {
                return Ok(());
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
    use std::path::Path;

    fn registry_with(entries: &str) -> PlaybookRegistry {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(file, "{entries}").unwrap();
        crate::playbook_registry::load_registry(file.path()).unwrap()
    }

    #[tokio::test]
    async fn routes_registry_entry_at_its_registered_tier() {
        let registry = registry_with(
            r#"[{"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-critical-reactor.sh"}]"#,
        );
        let officer = TestDutyOfficer::default();
        let source = MockSignalSource::new(vec![vec![Signal {
            kind: "disk_critical".to_string(),
            detail: "free_gb=5".to_string(),
        }]]);

        run_duty_officer_loop_with_source(
            registry,
            officer_ref(&officer),
            source,
            Duration::from_millis(0),
            Some(1),
        )
        .await
        .unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 1);
        assert_eq!(routed[0].0, OfficerTier::AutoHeal);
        assert_eq!(routed[0].1.kind, "disk_critical");
    }

    #[tokio::test]
    async fn falls_back_to_officer_evaluate_when_signal_unregistered() {
        let registry = registry_with("[]");
        let officer = TestDutyOfficer::default();
        // TestDutyOfficer::evaluate maps "pr_pipeline_wedged" -> Runbook
        // when there's no registry entry overriding it.
        let source = MockSignalSource::new(vec![vec![Signal {
            kind: "pr_pipeline_wedged".to_string(),
            detail: "wedge detail".to_string(),
        }]]);

        run_duty_officer_loop_with_source(
            registry,
            officer_ref(&officer),
            source,
            Duration::from_millis(0),
            Some(1),
        )
        .await
        .unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 1);
        assert_eq!(routed[0].0, OfficerTier::Runbook);
    }

    #[tokio::test]
    async fn drains_multiple_mock_signal_categories_across_polls() {
        // Simulates ambient.jsonl, ship-rate, disk, auth, and wedge sources
        // each surfacing one signal across separate poll cycles.
        let registry = registry_with("[]");
        let officer = TestDutyOfficer::default();
        let source = MockSignalSource::new(vec![
            vec![Signal {
                kind: "disk_critical".to_string(),
                detail: "disk".to_string(),
            }],
            vec![Signal {
                kind: "farmer_auth_dead".to_string(),
                detail: "auth".to_string(),
            }],
            vec![Signal {
                kind: "fleet_wedge".to_string(),
                detail: "wedge".to_string(),
            }],
        ]);

        run_duty_officer_loop_with_source(
            registry,
            officer_ref(&officer),
            source,
            Duration::from_millis(0),
            Some(3),
        )
        .await
        .unwrap();

        assert_eq!(officer.routed.borrow().len(), 3);
    }

    #[test]
    fn ambient_signal_source_parses_kind_from_new_lines() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        writeln!(file, r#"{{"kind":"disk_critical","detail":"free_gb=5"}}"#).unwrap();
        file.flush().unwrap();

        let mut source = AmbientSignalSource::new(file.path());
        let signals = source.poll();
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].kind, "disk_critical");

        // A second poll with no new lines appended yields nothing.
        assert!(source.poll().is_empty());

        writeln!(file, r#"{{"kind":"fleet_wedge","detail":"x"}}"#).unwrap();
        file.flush().unwrap();
        let signals = source.poll();
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].kind, "fleet_wedge");
    }

    #[test]
    fn ambient_signal_source_skips_malformed_lines() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        writeln!(file, "not json").unwrap();
        writeln!(file, r#"{{"no_kind_field": true}}"#).unwrap();
        writeln!(file, r#"{{"kind":"disk_critical"}}"#).unwrap();
        file.flush().unwrap();

        let mut source = AmbientSignalSource::new(file.path());
        let signals = source.poll();
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].kind, "disk_critical");
    }

    #[test]
    fn ambient_signal_source_tolerates_missing_file() {
        let mut source = AmbientSignalSource::new(Path::new("/nonexistent/ambient.jsonl"));
        assert!(source.poll().is_empty());
    }

    // Tests need to inspect `officer.routed` after the loop returns, so
    // they pass a reference rather than moving the officer into the loop.
    impl<T: DutyOfficer> DutyOfficer for &T {
        fn evaluate(&self, signal: Signal) -> OfficerTier {
            (**self).evaluate(signal)
        }

        fn route(&self, tier: OfficerTier, signal: Signal) -> Result<()> {
            (**self).route(tier, signal)
        }
    }

    fn officer_ref<T: DutyOfficer>(officer: &T) -> &T {
        officer
    }
}
