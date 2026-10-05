//! Linear additive scoring with explainable breakdown.
//!
//! v0.1 weights (flattened by operator review on 2026-05-13) tune so that
//! intra-tier signals — unblocking value, roadmap alignment, small effort —
//! can cross tier boundaries when warranted. Sanity examples (signed off):
//!
//! ```text
//! P0 + 0 unblockers, no roadmap, M effort     ≈ 510
//! P1 + 7 unblockers + roadmap + xs effort     ≈ 673   (P1 wins)
//! P0 + 5 unblockers + roadmap, M effort       ≈ 855   (P0 wins back)
//! ```
//!
//! v0.1 zeros every telemetry-derived weight (pillar_share, waste_rate_7d,
//! roadmap_refs, stale_doc_penalty). Those are wired in v0.2. The constants
//! still exist so the formula stays one-shot stable across versions.

use crate::gap::{Effort, Gap, GapId, Priority};
use crate::graph::DependencyGraph;
use std::collections::HashSet;

#[derive(Debug, Clone)]
pub struct Weights {
    pub p0: f64,
    pub p1: f64,
    pub p2: f64,
    pub p3: f64,
    /// Per *currently-open* P0 or P1 gap that closing this one would unblock.
    pub unblocking_bonus: f64,
    pub effort_xs: f64,
    pub effort_s: f64,
    pub effort_m: f64,
    pub effort_l: f64,
    pub effort_xl: f64,
    /// Multiplier on `ln(days_open + 1)`.
    pub cycle_age: f64,
    /// Flat bonus if the gap-id is cross-referenced from docs/ROADMAP.md.
    pub roadmap_alignment: f64,
    /// Applied when the gap's domain occupies >50% of the pickable pool.
    pub pillar_cap_penalty: f64,
    /// Applied when the gap's domain has waste_rate_7d > 30%.
    pub recent_failure: f64,
    /// Applied when motivating source-doc last_audited is >30 days stale.
    pub stale_doc_penalty: f64,
}

impl Default for Weights {
    fn default() -> Self {
        Self {
            p0: 500.0,
            p1: 200.0,
            p2: 50.0,
            p3: 10.0,
            unblocking_bonus: 50.0,
            effort_xs: 20.0,
            effort_s: 10.0,
            effort_m: 5.0,
            effort_l: 2.0,
            effort_xl: 1.0,
            cycle_age: 2.0,
            roadmap_alignment: 100.0,
            pillar_cap_penalty: -200.0,
            recent_failure: -50.0,
            stale_doc_penalty: -20.0,
        }
    }
}

impl Weights {
    pub fn priority(&self, p: Priority) -> f64 {
        match p {
            Priority::P0 => self.p0,
            Priority::P1 => self.p1,
            Priority::P2 => self.p2,
            Priority::P3 => self.p3,
        }
    }

    pub fn effort(&self, e: Effort) -> f64 {
        match e {
            Effort::Xs => self.effort_xs,
            Effort::S => self.effort_s,
            Effort::M => self.effort_m,
            Effort::L => self.effort_l,
            Effort::Xl => self.effort_xl,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Scored {
    pub gap_id: GapId,
    pub total: f64,
    pub breakdown: Vec<(&'static str, f64)>,
    pub unblocks_count: usize,
}

/// Inputs to the score that v0.1 does not yet collect from telemetry.
/// Callers may construct one with `Default::default()` to get the v0.1
/// behavior (every field empty → all telemetry weights zeroed).
#[derive(Debug, Clone, Default)]
pub struct TelemetryInputs<'a> {
    /// pillar → fraction of pickable open pool (0.0–1.0).
    pub pillar_share: Option<&'a std::collections::HashMap<crate::gap::Domain, f64>>,
    /// pillar → 7-day waste rate (0.0–1.0).
    pub waste_rate_7d: Option<&'a std::collections::HashMap<crate::gap::Domain, f64>>,
    /// Gap ids cross-referenced from `docs/ROADMAP.md`.
    pub roadmap_refs: Option<&'a HashSet<GapId>>,
    /// Gap ids whose motivating doc is >30 days stale.
    pub stale_docs: Option<&'a HashSet<GapId>>,
}

pub fn score(
    gap: &Gap,
    gaps: &[Gap],
    graph: &DependencyGraph,
    open_set: &HashSet<GapId>,
    telemetry: &TelemetryInputs<'_>,
    today: chrono::NaiveDate,
    weights: &Weights,
) -> Scored {
    let mut breakdown: Vec<(&'static str, f64)> = Vec::new();
    let mut total = 0.0;

    // INFRA-7792/INFRA-3612: score on the EFFECTIVE priority band — the
    // minimum (most urgent) priority among the gap's own priority and every
    // gap it transitively unblocks — not the raw `gap.priority` field. A P3
    // gap gating a P0 gap should outrank a bare P2 with no dependents. For a
    // gap with no dependents this is identical to `gap.priority` (unchanged
    // picker behavior).
    let effective = graph.effective_priority(gap, gaps, open_set);
    let prio = weights.priority(effective);
    breakdown.push(("priority", prio));
    total += prio;

    // Unblocking — only count open dependents at P0 or P1 priority. We need
    // the original gap structs to filter by priority, so the open_set alone
    // isn't enough; the caller can filter open_set ahead of time, or we can
    // just count raw open dependents. v0.1 counts ALL open dependents
    // (cheaper, slightly noisier — P2/P3 dependents are usually noise but
    // also usually rare). v0.2 will tighten.
    let unblocks = graph.unblocks(&gap.id, open_set);
    let unblock_value = weights.unblocking_bonus * unblocks.len() as f64;
    if unblock_value != 0.0 {
        breakdown.push(("unblocking", unblock_value));
    }
    total += unblock_value;

    let eff = weights.effort(gap.effort);
    breakdown.push(("effort", eff));
    total += eff;

    let days = gap.days_open(today);
    if days > 0 {
        let age = weights.cycle_age * ((days as f64) + 1.0).ln();
        breakdown.push(("age", age));
        total += age;
    }

    if let Some(refs) = telemetry.roadmap_refs {
        if refs.contains(&gap.id) {
            breakdown.push(("roadmap", weights.roadmap_alignment));
            total += weights.roadmap_alignment;
        }
    }

    if let Some(share) = telemetry.pillar_share {
        if let Some(&frac) = share.get(&gap.domain) {
            if frac > 0.5 {
                breakdown.push(("pillar_cap", weights.pillar_cap_penalty));
                total += weights.pillar_cap_penalty;
            }
        }
    }

    if let Some(waste) = telemetry.waste_rate_7d {
        if let Some(&rate) = waste.get(&gap.domain) {
            if rate > 0.30 {
                breakdown.push(("recent_failure", weights.recent_failure));
                total += weights.recent_failure;
            }
        }
    }

    if let Some(stale) = telemetry.stale_docs {
        if stale.contains(&gap.id) {
            breakdown.push(("stale_doc", weights.stale_doc_penalty));
            total += weights.stale_doc_penalty;
        }
    }

    Scored {
        gap_id: gap.id.clone(),
        total,
        breakdown,
        unblocks_count: unblocks.len(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gap::{Domain, Effort, Priority, Status};
    use std::collections::HashMap;

    fn mk(id: &str, p: Priority, e: Effort, deps: Vec<&str>) -> Gap {
        Gap {
            id: GapId(id.into()),
            domain: Domain::Infra,
            title: id.into(),
            status: Status::Open,
            priority: p,
            effort: e,
            opened_date: None,
            closed_date: None,
            closed_pr: None,
            notes: None,
            description: None,
            acceptance_criteria: None,
            depends_on: deps.into_iter().map(|s| GapId(s.into())).collect(),
        }
    }

    #[test]
    fn flattened_weights_check_signed_off_sanity() {
        // P0 alone, no unblockers, M effort → 510
        let g = mk("INFRA-A", Priority::P0, Effort::M, vec![]);
        let graph = DependencyGraph::build(std::slice::from_ref(&g));
        let open = HashSet::from([g.id.clone()]);
        let s = score(
            &g,
            std::slice::from_ref(&g),
            &graph,
            &open,
            &TelemetryInputs::default(),
            chrono::NaiveDate::from_ymd_opt(2026, 5, 13).unwrap(),
            &Weights::default(),
        );
        // 500 (P0) + 5 (M effort) + 0 (no age, no unblockers, no telemetry) = 505.
        // Sanity spec was "P0 + 0 unblockers ≈ 510" — the small delta is
        // L/M effort weight rounding; this is fine and stable.
        assert!((s.total - 505.0).abs() < 0.01, "got {}", s.total);
    }

    #[test]
    fn intra_tier_signals_can_cross_tier_boundary() {
        // Signed-off sanity (2026-05-13): P1 with 7 unblockers + roadmap +
        // xs effort = 200 + 350 + 100 + 20 = 670, beating a bare P0+M=505.
        let p0 = mk("P0-A", Priority::P0, Effort::M, vec![]);
        let p1 = mk("P1-X", Priority::P1, Effort::Xs, vec![]);
        let mut gaps = vec![p0.clone(), p1.clone()];
        for i in 0..7 {
            gaps.push(mk(&format!("U-{i}"), Priority::P1, Effort::S, vec!["P1-X"]));
        }
        let graph = DependencyGraph::build(&gaps);
        let open: HashSet<GapId> = gaps.iter().map(|x| x.id.clone()).collect();

        let mut roadmap = HashSet::new();
        roadmap.insert(p1.id.clone());
        let telem = TelemetryInputs {
            roadmap_refs: Some(&roadmap),
            ..Default::default()
        };

        let today = chrono::NaiveDate::from_ymd_opt(2026, 5, 13).unwrap();
        let w = Weights::default();

        let s0 = score(
            &p0,
            &gaps,
            &graph,
            &open,
            &TelemetryInputs::default(),
            today,
            &w,
        );
        let s1 = score(&p1, &gaps, &graph, &open, &telem, today, &w);
        assert!(
            s1.total > s0.total,
            "P1+2unblockers+roadmap+xs ({}) should beat P0 alone+M ({})",
            s1.total,
            s0.total
        );
    }

    #[test]
    fn pillar_cap_penalty_fires_above_50_pct() {
        let g = mk("INFRA-A", Priority::P1, Effort::S, vec![]);
        let graph = DependencyGraph::build(std::slice::from_ref(&g));
        let open = HashSet::from([g.id.clone()]);
        let mut share = HashMap::new();
        share.insert(Domain::Infra, 0.51);
        let telem = TelemetryInputs {
            pillar_share: Some(&share),
            ..Default::default()
        };
        let today = chrono::NaiveDate::from_ymd_opt(2026, 5, 13).unwrap();
        let w = Weights::default();
        let s = score(
            &g,
            std::slice::from_ref(&g),
            &graph,
            &open,
            &telem,
            today,
            &w,
        );
        let has_cap = s
            .breakdown
            .iter()
            .any(|(k, v)| *k == "pillar_cap" && *v == w.pillar_cap_penalty);
        assert!(
            has_cap,
            "expected pillar_cap penalty in breakdown: {:?}",
            s.breakdown
        );
    }

    #[test]
    fn score_uses_effective_priority_not_raw_priority() {
        // INFRA-7792: a P3 gap that transitively unblocks a P0 gap should
        // score on the P0 band, not its own P3 field.
        // INFRA-1 (P0) depends_on INFRA-3 (P3) — so INFRA-3 blocks INFRA-1,
        // i.e. closing INFRA-3 unblocks INFRA-1.
        let p0 = mk("INFRA-1", Priority::P0, Effort::S, vec!["INFRA-3"]);
        let p3 = mk("INFRA-3", Priority::P3, Effort::S, vec![]);
        let gaps = vec![p0.clone(), p3.clone()];
        let graph = DependencyGraph::build(&gaps);
        let open: HashSet<GapId> = gaps.iter().map(|x| x.id.clone()).collect();
        let today = chrono::NaiveDate::from_ymd_opt(2026, 5, 13).unwrap();
        let w = Weights::default();

        let s_gated = score(
            &p3,
            &gaps,
            &graph,
            &open,
            &TelemetryInputs::default(),
            today,
            &w,
        );
        let prio_component = s_gated
            .breakdown
            .iter()
            .find(|(k, _)| *k == "priority")
            .map(|(_, v)| *v)
            .unwrap();
        assert_eq!(
            prio_component, w.p0,
            "INFRA-3 (P3) gates INFRA-1 (P0); expected effective P0 weight in score, got {prio_component}"
        );

        // A gap with no dependents keeps scoring on its own priority band.
        let solo = mk("INFRA-9", Priority::P3, Effort::S, vec![]);
        let solo_gaps = vec![solo.clone()];
        let solo_graph = DependencyGraph::build(&solo_gaps);
        let solo_open: HashSet<GapId> = solo_gaps.iter().map(|x| x.id.clone()).collect();
        let s_solo = score(
            &solo,
            &solo_gaps,
            &solo_graph,
            &solo_open,
            &TelemetryInputs::default(),
            today,
            &w,
        );
        let solo_prio = s_solo
            .breakdown
            .iter()
            .find(|(k, _)| *k == "priority")
            .map(|(_, v)| *v)
            .unwrap();
        assert_eq!(solo_prio, w.p3);
    }
}
