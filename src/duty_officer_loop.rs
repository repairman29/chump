//! Standing loop that watches health signals and invokes the playbook
//! registry (RESILIENT-274 slice, RESILIENT-445).
//!
//! Wires `duty_officer::DutyOfficer` (RESILIENT-444) to
//! `playbook_registry::PlaybookRegistry` (RESILIENT-443): for each observed
//! `Signal`, look up its `PlaybookEntry` in the registry (if any), then hand
//! the signal to the officer for routing. The officer's own `evaluate`
//! decides the tier independently of the registry entry — the registry
//! lookup exists so the officer's `route` can consult the entry's `action`/
//! `detect`/`verify` fields (future slice); this loop's job is only to wire
//! the call sequence, not to interpret the entry.
//!
//! See `docs/design/DUTY_OFFICER.md` for the full design.

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal};
use crate::playbook_registry::PlaybookRegistry;

/// Source of health signals to feed the duty-officer loop.
///
/// Production wiring reads real sources (ambient.jsonl tail, ship-rate,
/// disk, auth, wedges — see `docs/design/DUTY_OFFICER.md`); tests use a
/// fixed `Vec<Signal>` harness (`VecSignalSource`) so the loop logic is
/// exercised deterministically without touching the filesystem or network.
pub trait SignalSource {
    /// Returns the next batch of signals observed since the last poll.
    /// An empty vec means "nothing new this tick".
    fn poll(&mut self) -> Vec<Signal>;
}

/// Test/mock signal source: yields each inner `Vec<Signal>` batch in order,
/// one batch per `poll()` call, then empty vecs forever after exhaustion.
#[derive(Debug, Default)]
pub struct VecSignalSource {
    batches: std::collections::VecDeque<Vec<Signal>>,
}

impl VecSignalSource {
    pub fn new(batches: Vec<Vec<Signal>>) -> Self {
        Self {
            batches: batches.into(),
        }
    }
}

impl SignalSource for VecSignalSource {
    fn poll(&mut self) -> Vec<Signal> {
        self.batches.pop_front().unwrap_or_default()
    }
}

/// Runs the duty-officer loop for `max_ticks` polls of `source`, routing
/// every observed signal through `registry.get_entry` then `officer.route`.
///
/// Returns the number of signals routed, for test assertions. A real
/// standing loop (production wiring) calls this in a `loop { }` with a
/// sleep between ticks instead of a fixed `max_ticks` bound.
pub async fn run_duty_officer_loop(
    registry: &PlaybookRegistry,
    officer: &impl DutyOfficer,
    source: &mut impl SignalSource,
    max_ticks: usize,
) -> Result<usize> {
    let mut routed_count = 0;

    for _ in 0..max_ticks {
        for signal in source.poll() {
            // Registry lookup surfaces the playbook entry (action/detect/
            // verify) for this signal kind, if one is registered. The
            // officer's own evaluate() independently classifies the tier;
            // route() is handed the signal regardless of whether a
            // registry entry exists, so unregistered signals still reach
            // the officer (e.g. to escalate as "no playbook").
            let _entry = registry.get_entry(&signal.kind);

            let tier = officer.evaluate(signal.clone());
            officer.route(tier, signal)?;
            routed_count += 1;
        }
    }

    Ok(routed_count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::duty_officer::{TestDutyOfficer, Tier};
    use crate::playbook_registry::PlaybookRegistry;

    #[tokio::test]
    async fn routes_signals_from_mock_sources() {
        let registry = PlaybookRegistry::default();
        let officer = TestDutyOfficer::default();
        let mut source = VecSignalSource::new(vec![
            vec![Signal {
                kind: "disk_critical".to_string(),
                detail: "free_gb=10".to_string(),
            }],
            vec![Signal {
                kind: "pr_pipeline_wedged".to_string(),
                detail: "pr=1234".to_string(),
            }],
            vec![],
        ]);

        let routed = run_duty_officer_loop(&registry, &officer, &mut source, 3)
            .await
            .unwrap();

        assert_eq!(routed, 2);
        let seen = officer.routed.borrow();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0].0, Tier::AutoHeal);
        assert_eq!(seen[1].0, Tier::Runbook);
    }

    #[tokio::test]
    async fn empty_source_routes_nothing() {
        let registry = PlaybookRegistry::default();
        let officer = TestDutyOfficer::default();
        let mut source = VecSignalSource::new(vec![vec![], vec![]]);

        let routed = run_duty_officer_loop(&registry, &officer, &mut source, 2)
            .await
            .unwrap();

        assert_eq!(routed, 0);
        assert!(officer.routed.borrow().is_empty());
    }

    #[tokio::test]
    async fn unregistered_signal_still_reaches_officer() {
        let registry = PlaybookRegistry::default();
        let officer = TestDutyOfficer::default();
        let mut source = VecSignalSource::new(vec![vec![Signal {
            kind: "totally_unknown_signal".to_string(),
            detail: "".to_string(),
        }]]);

        let routed = run_duty_officer_loop(&registry, &officer, &mut source, 1)
            .await
            .unwrap();

        assert_eq!(routed, 1);
        assert_eq!(officer.routed.borrow()[0].0, Tier::Escalate);
    }
}
