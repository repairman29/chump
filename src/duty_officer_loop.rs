//! Standing duty-officer loop (RESILIENT-274 slice, RESILIENT-445).
//!
//! Wires together the two halves shipped by the prior slices: the
//! `PlaybookRegistry` (RESILIENT-443, `playbook_registry::load_registry`)
//! and the `DutyOfficer` trait contract (RESILIENT-444, `duty_officer`).
//! Each tick, the loop polls a set of health `SignalSource`s, looks each
//! raw signal up in the registry, and routes it through the officer.
//!
//! See `docs/design/DUTY_OFFICER.md` for the full design.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal, Tier as OfficerTier};
use crate::playbook_registry::{PlaybookRegistry, Tier as RegistryTier};

/// Converts a registry-side tier (loaded from JSON) to the officer-side tier
/// (the routing contract). The two enums live in separate crates-of-origin
/// (RESILIENT-443 vs RESILIENT-444) and are kept decoupled on purpose, so
/// this is the one place that bridges them.
fn registry_tier_to_officer_tier(tier: RegistryTier) -> OfficerTier {
    match tier {
        RegistryTier::AutoHeal => OfficerTier::AutoHeal,
        RegistryTier::Runbook => OfficerTier::Runbook,
        RegistryTier::Escalate => OfficerTier::Escalate,
    }
}

/// A source of raw health signals the duty-officer loop polls each tick.
///
/// Production sources read real fleet state (`ambient.jsonl`, ship rate,
/// disk, auth, wedge counts); tests substitute a `MockSignalSource` that
/// returns a fixed, scripted list of signals so the loop's dispatch logic
/// can be exercised without any real fleet state on disk.
pub trait SignalSource: Send + Sync {
    /// Human-readable name for logging (e.g. "ambient.jsonl", "ship-rate").
    fn name(&self) -> &str;

    /// Poll for currently-active signals. Must not panic on missing files
    /// or commands — a source that can't observe anything returns `vec![]`.
    fn poll(&self) -> Vec<Signal>;
}

/// Reads the tail of an `ambient.jsonl` stream and turns lines with a
/// `"kind"` field into signals. Malformed or unreadable input yields no
/// signals rather than erroring, since ambient absence just means "nothing
/// to report" for this source.
pub struct AmbientJsonlSource {
    pub path: PathBuf,
    pub tail_lines: usize,
}

impl AmbientJsonlSource {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            tail_lines: 200,
        }
    }
}

impl SignalSource for AmbientJsonlSource {
    fn name(&self) -> &str {
        "ambient.jsonl"
    }

    fn poll(&self) -> Vec<Signal> {
        let Ok(raw) = std::fs::read_to_string(&self.path) else {
            return vec![];
        };
        raw.lines()
            .rev()
            .take(self.tail_lines)
            .filter_map(|line| {
                let value: serde_json::Value = serde_json::from_str(line).ok()?;
                let kind = value.get("kind")?.as_str()?.to_string();
                Some(Signal {
                    kind,
                    detail: line.to_string(),
                })
            })
            .collect()
    }
}

/// Mock signal source for tests: returns a fixed, scripted list of signals
/// every poll. This is the "test harness" the loop is exercised through
/// (RESILIENT-445 AC2) — one instance per mocked category (ship-rate,
/// disk, auth, wedges, ambient).
#[derive(Debug, Default, Clone)]
pub struct MockSignalSource {
    pub label: String,
    pub signals: Vec<Signal>,
}

impl MockSignalSource {
    pub fn new(label: impl Into<String>, signals: Vec<Signal>) -> Self {
        Self {
            label: label.into(),
            signals,
        }
    }
}

impl SignalSource for MockSignalSource {
    fn name(&self) -> &str {
        &self.label
    }

    fn poll(&self) -> Vec<Signal> {
        self.signals.clone()
    }
}

/// How long to sleep between ticks in the production (unbounded) loop.
const TICK_INTERVAL: Duration = Duration::from_secs(30);

/// Runs the standing duty-officer loop: forever, poll every signal source,
/// resolve each signal against the registry (falling back to the officer's
/// own `evaluate` when the registry has no entry), and route it.
///
/// This is the entry point named in RESILIENT-445 AC1. It wires up the
/// default production signal sources (ambient.jsonl, ship-rate, disk,
/// auth, wedges) and never returns under normal operation.
pub async fn run_duty_officer_loop(
    registry: PlaybookRegistry,
    officer: impl DutyOfficer,
) -> Result<()> {
    let sources = default_signal_sources();
    run_duty_officer_loop_ticks(&registry, &officer, &sources, None).await
}

/// Default production signal sources, one per named category in AC2.
/// `ship-rate`, `disk`, `auth`, and `wedges` are currently represented as
/// mock/no-op sources (they emit nothing) pending the real integrations —
/// `ambient.jsonl` is wired to the real file since that's the one ambient
/// stream every other fleet script already reads from.
fn default_signal_sources() -> Vec<Box<dyn SignalSource>> {
    vec![
        Box::new(AmbientJsonlSource::new(".chump-locks/ambient.jsonl")),
        Box::new(MockSignalSource::new("ship-rate", vec![])),
        Box::new(MockSignalSource::new("disk", vec![])),
        Box::new(MockSignalSource::new("auth", vec![])),
        Box::new(MockSignalSource::new("wedges", vec![])),
    ]
}

/// Test/internal harness: runs `max_ticks` iterations (or forever if
/// `None`), polling `sources`, resolving each signal via `registry`, and
/// routing it through `officer`. Sleeps `TICK_INTERVAL` between ticks when
/// unbounded so the real loop doesn't busy-spin.
async fn run_duty_officer_loop_ticks(
    registry: &PlaybookRegistry,
    officer: &impl DutyOfficer,
    sources: &[Box<dyn SignalSource>],
    max_ticks: Option<u64>,
) -> Result<()> {
    let mut tick: u64 = 0;
    loop {
        for source in sources {
            for signal in source.poll() {
                dispatch_signal(registry, officer, signal)?;
            }
        }

        tick += 1;
        if let Some(limit) = max_ticks {
            if tick >= limit {
                return Ok(());
            }
        } else {
            tokio::time::sleep(TICK_INTERVAL).await;
        }
    }
}

/// Resolves a single signal against the registry (AC3: `registry.get_entry`
/// then `officer.route`), falling back to the officer's own `evaluate` when
/// the registry has no entry for this signal kind.
fn dispatch_signal(
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::duty_officer::TestDutyOfficer;

    fn registry_with_disk_critical() -> PlaybookRegistry {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        std::io::Write::write_all(
            &mut file,
            br#"[{"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-cleanup.sh"}]"#,
        )
        .unwrap();
        crate::playbook_registry::load_registry(file.path()).unwrap()
    }

    #[tokio::test]
    async fn dispatch_uses_registry_entry_when_present() {
        let registry = registry_with_disk_critical();
        let officer = TestDutyOfficer::default();
        let signal = Signal {
            kind: "disk_critical".to_string(),
            detail: "free_gb=5".to_string(),
        };

        dispatch_signal(&registry, &officer, signal.clone()).unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 1);
        assert_eq!(routed[0], (OfficerTier::AutoHeal, signal));
    }

    #[tokio::test]
    async fn dispatch_falls_back_to_officer_evaluate_when_registry_misses() {
        let registry = registry_with_disk_critical();
        let officer = TestDutyOfficer::default();
        let signal = Signal {
            kind: "pr_pipeline_wedged".to_string(),
            detail: "pr=1234".to_string(),
        };

        dispatch_signal(&registry, &officer, signal.clone()).unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 1);
        // TestDutyOfficer::evaluate maps unknown-to-registry "pr_pipeline_wedged" to Runbook.
        assert_eq!(routed[0], (OfficerTier::Runbook, signal));
    }

    #[tokio::test]
    async fn loop_polls_all_mock_sources_each_tick() {
        let registry = registry_with_disk_critical();
        let officer = TestDutyOfficer::default();
        let sources: Vec<Box<dyn SignalSource>> = vec![
            Box::new(MockSignalSource::new(
                "ship-rate",
                vec![Signal {
                    kind: "ship_rate_zero".to_string(),
                    detail: "0 commits/1h".to_string(),
                }],
            )),
            Box::new(MockSignalSource::new(
                "disk",
                vec![Signal {
                    kind: "disk_critical".to_string(),
                    detail: "free_gb=2".to_string(),
                }],
            )),
        ];

        run_duty_officer_loop_ticks(&registry, &officer, &sources, Some(1))
            .await
            .unwrap();

        let routed = officer.routed.borrow();
        assert_eq!(routed.len(), 2);
        assert!(routed
            .iter()
            .any(|(tier, sig)| *tier == OfficerTier::Escalate && sig.kind == "ship_rate_zero"));
        assert!(routed
            .iter()
            .any(|(tier, sig)| *tier == OfficerTier::AutoHeal && sig.kind == "disk_critical"));
    }

    #[tokio::test]
    async fn loop_runs_bounded_ticks_then_returns() {
        let registry = PlaybookRegistry::default();
        let officer = TestDutyOfficer::default();
        let sources: Vec<Box<dyn SignalSource>> = vec![Box::new(MockSignalSource::new(
            "wedges",
            vec![Signal {
                kind: "fleet_wedge".to_string(),
                detail: "lease overlap".to_string(),
            }],
        ))];

        run_duty_officer_loop_ticks(&registry, &officer, &sources, Some(3))
            .await
            .unwrap();

        // 3 ticks * 1 signal per tick from the single mock source.
        assert_eq!(officer.routed.borrow().len(), 3);
    }
}
