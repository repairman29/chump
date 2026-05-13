//! Reconciliation surface.
//!
//! A gap with `status: open` but a `closed_pr` set means the PR that
//! closed it landed but `chump gap ship` wasn't recorded — the registry is
//! lying about the gap's state. Until reconciled, scoring that gap would
//! recommend re-claiming work that's already shipped.
//!
//! v0.1 policy: collect these into a `ReconcileReport`; if the count
//! exceeds the configured threshold (default 10), `chump plan` exits
//! non-zero. Operator runs `gap-doctor-reconcile.py` (existing tool) to
//! clear them.

use crate::gap::{Gap, Status};

#[derive(Debug, Clone)]
pub struct ReconcileEntry {
    pub gap_id: crate::gap::GapId,
    pub closed_pr: u64,
    pub title: String,
}

#[derive(Debug, Clone, Default)]
pub struct ReconcileReport {
    pub entries: Vec<ReconcileEntry>,
}

impl ReconcileReport {
    pub fn count(&self) -> usize {
        self.entries.len()
    }

    /// Whether the backlog exceeds the gate threshold and `chump plan`
    /// should exit non-zero.
    pub fn breaches(&self, threshold: usize) -> bool {
        self.entries.len() > threshold
    }
}

pub fn collect_reconcile(gaps: &[Gap]) -> ReconcileReport {
    let mut entries: Vec<ReconcileEntry> = gaps
        .iter()
        .filter_map(|g| match (g.status, g.closed_pr) {
            (Status::Open, Some(pr)) => Some(ReconcileEntry {
                gap_id: g.id.clone(),
                closed_pr: pr,
                title: g.title.clone(),
            }),
            _ => None,
        })
        .collect();
    entries.sort_by(|a, b| a.gap_id.0.cmp(&b.gap_id.0));
    ReconcileReport { entries }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gap::{Domain, Effort, GapId, Priority};

    fn mk(id: &str, status: Status, closed_pr: Option<u64>) -> Gap {
        Gap {
            id: GapId(id.into()),
            domain: Domain::Infra,
            title: format!("title {id}"),
            status,
            priority: Priority::P1,
            effort: Effort::S,
            opened_date: None,
            closed_date: None,
            closed_pr,
            notes: None,
            description: None,
            acceptance_criteria: None,
            depends_on: vec![],
        }
    }

    #[test]
    fn collects_only_open_with_closed_pr() {
        let gaps = vec![
            mk("A", Status::Open, Some(100)),
            mk("B", Status::Open, None),
            mk("C", Status::Done, Some(101)),
            mk("D", Status::Closed, Some(102)),
            mk("E", Status::Open, Some(103)),
        ];
        let r = collect_reconcile(&gaps);
        let ids: Vec<_> = r.entries.iter().map(|e| e.gap_id.0.clone()).collect();
        assert_eq!(ids, vec!["A".to_string(), "E".to_string()]);
    }

    #[test]
    fn threshold_breach() {
        let gaps: Vec<Gap> = (0..15)
            .map(|i| mk(&format!("G-{i}"), Status::Open, Some(i)))
            .collect();
        let r = collect_reconcile(&gaps);
        assert!(r.breaches(10));
        assert!(!r.breaches(20));
    }
}
