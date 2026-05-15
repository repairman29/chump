//! Greedy dispatch-plan builder.
//!
//! Selection process:
//!   1. Filter the corpus to `Status::Open`.
//!   2. Drop gaps with `closed_pr` set — those go to the reconciliation
//!      surface, not the rank list. (Mixing them in would mean the planner
//!      recommends "claiming" a gap that's already shipped.)
//!   3. Unless `--include-blocked`, drop gaps with at least one open hard
//!      predecessor.
//!   4. Score every survivor.
//!   5. Greedy top-N selection. With `respect_pillar_cap=true`, we maintain
//!      a running domain-share counter as we pick; once a domain crosses
//!      50% of the picks so far, subsequent picks from that domain take the
//!      `pillar_cap_penalty` (re-scored on the fly).

use crate::gap::{Domain, Gap, GapId, Status};
use crate::graph::DependencyGraph;
use crate::score::{score, Scored, TelemetryInputs, Weights};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct PlanRequest {
    pub agents: usize,
    pub pillar_filter: Option<Domain>,
    pub max_effort: Option<crate::gap::Effort>,
    pub respect_pillar_cap: bool,
    pub include_blocked: bool,
}

impl Default for PlanRequest {
    fn default() -> Self {
        Self {
            agents: 5,
            pillar_filter: None,
            max_effort: None,
            respect_pillar_cap: true,
            include_blocked: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PlanItem {
    pub gap: Gap,
    pub score: Scored,
    pub prerequisites: Vec<GapId>,
    /// INFRA-1281: topological layer in the open dep graph. 0 = no open
    /// prereqs (foundation). Enables tier-aware picking (INFRA-1258).
    pub layer: u32,
    /// INFRA-1281: longest forward chain of `Effort::days()` from this
    /// gap through all transitive open dependents to a leaf.
    pub critical_path_days: f32,
}

pub fn build_plan(
    gaps: &[Gap],
    graph: &DependencyGraph,
    req: &PlanRequest,
    telemetry: &TelemetryInputs<'_>,
    today: chrono::NaiveDate,
    weights: &Weights,
) -> Vec<PlanItem> {
    // Open set excludes closed/done AND reconciliation-pending (`closed_pr`
    // set on an `open` row) gaps — the latter aren't really pickable.
    let open_set: HashSet<GapId> = gaps
        .iter()
        .filter(|g| matches!(g.status, Status::Open) && g.closed_pr.is_none())
        .map(|g| g.id.clone())
        .collect();

    let mut candidates: Vec<(&Gap, Vec<GapId>)> = Vec::new();
    for g in gaps {
        if !open_set.contains(&g.id) {
            continue;
        }
        if let Some(p) = req.pillar_filter {
            if g.domain != p {
                continue;
            }
        }
        if let Some(max) = req.max_effort {
            if g.effort > max {
                continue;
            }
        }
        let prereqs = graph.open_prerequisites(&g.id, &open_set);
        if !req.include_blocked && !prereqs.is_empty() {
            continue;
        }
        candidates.push((g, prereqs));
    }

    // Initial scoring without any in-flight pillar-cap penalty (the cap
    // gets applied during greedy selection as the running share crosses
    // 50%).
    let mut scored: Vec<(usize, Scored, Vec<GapId>)> = candidates
        .iter()
        .enumerate()
        .map(|(i, (g, prereqs))| {
            let s = score(g, graph, &open_set, telemetry, today, weights);
            (i, s, prereqs.clone())
        })
        .collect();

    scored.sort_by(|a, b| {
        b.1.total
            .partial_cmp(&a.1.total)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.1.gap_id.0.cmp(&b.1.gap_id.0))
    });

    // INFRA-1281: precompute layer + critical_path_days for every open gap
    // once; attach to each PlanItem during picking. O(V+E) each — cheap at
    // the ~400-open-gap scale and keeps the picker stateless about graph shape.
    let layers = graph.layers(&open_set);
    let cpds = graph.critical_path_days(gaps, &open_set);

    let want = req.agents.max(1);
    let mut picked: Vec<PlanItem> = Vec::new();
    let mut domain_picks: HashMap<Domain, usize> = HashMap::new();

    for (idx, scored_item, prereqs) in scored {
        let gap = candidates[idx].0;

        let mut item_score = scored_item;
        if req.respect_pillar_cap && !picked.is_empty() {
            let total_picks = picked.len();
            let share = *domain_picks.get(&gap.domain).unwrap_or(&0) as f64 / total_picks as f64;
            if share > 0.5 {
                item_score
                    .breakdown
                    .push(("pillar_cap_running", weights.pillar_cap_penalty));
                item_score.total += weights.pillar_cap_penalty;
            }
        }

        let layer = layers.get(&gap.id).copied().unwrap_or(0);
        let critical_path_days = cpds.get(&gap.id).copied().unwrap_or(gap.effort.days());
        picked.push(PlanItem {
            gap: gap.clone(),
            score: item_score,
            prerequisites: prereqs,
            layer,
            critical_path_days,
        });
        *domain_picks.entry(gap.domain).or_insert(0) += 1;

        if picked.len() >= want {
            // Re-sort once cap is in play; the greedy bound is N, and
            // re-sorting at N is cheaper than maintaining a heap.
            picked.sort_by(|a, b| {
                b.score
                    .total
                    .partial_cmp(&a.score.total)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.score.gap_id.0.cmp(&b.score.gap_id.0))
            });
            // If new entry slid below an earlier pick, the bottom one is
            // still legitimately picked — we only ever grow up to `want`.
            break;
        }
    }

    picked
}
