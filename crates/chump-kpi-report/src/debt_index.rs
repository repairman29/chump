//! CREDIBLE-357 (Debt Index 4/5): crown gauge on the pane + feed NBA.
//!
//! Builds on [`crate::live_pct`]'s Crit-weighted liveness model. A
//! [`Capability`] is a named unit of work made of one stage (same shape as
//! `live_pct::Stage`, plus identity + a "how far behind" counter), so this
//! module can rank multiple capabilities against each other rather than
//! report a single liveness number for one pipeline.
//!
//! The "crown gauge" is the `live_pct` / `debt` / top-5-dormant-by-Crit
//! summary rendered onto the Tote Board pane (today: the `chump kpi report`
//! text pane — the one surface in this codebase that already renders live,
//! non-fictional data to the operator; see `render_text` on
//! [`CrownGauge`]). `next_best_action_candidates` feeds the NBA list: the
//! high-Crit dormant capabilities worth a "wire the champion" bet.

use crate::live_pct::{compute_live_pct, Criticality, Stage, StageStatus};

/// A named unit of work tracked by the debt index.
#[derive(Debug, Clone)]
pub struct Capability {
    pub name: String,
    pub criticality: Criticality,
    pub status: StageStatus,
    /// How many stages this capability still has to clear before it reaches
    /// `Running` — the "how far behind" signal `debt` weights alongside
    /// criticality. Zero for anything already live.
    pub stages_short: u32,
}

impl Capability {
    fn is_dormant(&self) -> bool {
        self.status < StageStatus::Running
    }

    fn is_high_crit(&self) -> bool {
        matches!(self.criticality, Criticality::Crit)
    }

    fn as_stage(&self) -> Stage {
        Stage {
            status: self.status,
            criticality: self.criticality,
        }
    }
}

/// Sum of `Crit-weight x stages-short` over every high-Crit dormant
/// capability. Low-Crit dormant capabilities contribute nothing (they belong
/// to the CREDIBLE-358 prune ledger, not the debt figure) and live
/// capabilities contribute nothing (there's no gap left to pay down).
pub fn compute_debt(capabilities: &[Capability]) -> f64 {
    capabilities
        .iter()
        .filter(|c| c.is_dormant() && c.is_high_crit())
        .map(|c| c.criticality.weight() * c.stages_short as f64)
        .sum()
}

/// Up to 5 dormant capabilities, ranked by criticality weight (desc) then
/// `stages_short` (desc) — the capabilities furthest behind that matter
/// most. Ties broken by name for reproducible output.
pub fn top5_dormant_by_crit(capabilities: &[Capability]) -> Vec<&Capability> {
    let mut dormant: Vec<&Capability> = capabilities.iter().filter(|c| c.is_dormant()).collect();
    dormant.sort_by(|a, b| {
        b.criticality
            .weight()
            .partial_cmp(&a.criticality.weight())
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.stages_short.cmp(&a.stages_short))
            .then_with(|| a.name.cmp(&b.name))
    });
    dormant.truncate(5);
    dormant
}

/// The high-Crit dormant capabilities — "wire-the-champion" bets — that feed
/// the next_best_action candidate list. Same filter as [`compute_debt`],
/// sorted by `stages_short` desc so the most-behind bet leads.
pub fn next_best_action_candidates(capabilities: &[Capability]) -> Vec<&Capability> {
    let mut candidates: Vec<&Capability> = capabilities
        .iter()
        .filter(|c| c.is_dormant() && c.is_high_crit())
        .collect();
    candidates.sort_by(|a, b| {
        b.stages_short
            .cmp(&a.stages_short)
            .then_with(|| a.name.cmp(&b.name))
    });
    candidates
}

/// The crown-gauge summary rendered onto the Tote Board pane.
#[derive(Debug, Clone)]
pub struct CrownGauge {
    pub live_pct: f64,
    pub debt: f64,
    pub top5_dormant_names: Vec<String>,
}

/// Compute the crown gauge for a capability set.
pub fn compute_crown_gauge(capabilities: &[Capability]) -> CrownGauge {
    let stages: Vec<Stage> = capabilities.iter().map(Capability::as_stage).collect();
    CrownGauge {
        live_pct: compute_live_pct(&stages),
        debt: compute_debt(capabilities),
        top5_dormant_names: top5_dormant_by_crit(capabilities)
            .into_iter()
            .map(|c| c.name.clone())
            .collect(),
    }
}

impl CrownGauge {
    /// Render the crown gauge as the Tote Board pane's markdown block.
    pub fn render_text(&self) -> String {
        let mut out = format!(
            "═══ Debt Index — Crown Gauge (CREDIBLE-357) ═══\n  live_pct: {:.1}%\n  debt: {:.1}\n",
            self.live_pct * 100.0,
            self.debt,
        );
        if self.top5_dormant_names.is_empty() {
            out.push_str("  top-5 dormant-by-Crit: (none)\n");
        } else {
            out.push_str("  top-5 dormant-by-Crit:\n");
            for name in &self.top5_dormant_names {
                out.push_str(&format!("    - {name}\n"));
            }
        }
        out
    }
}

/// Render the next_best_action candidate list block.
pub fn render_nba_candidates(capabilities: &[Capability]) -> String {
    let candidates = next_best_action_candidates(capabilities);
    if candidates.is_empty() {
        return "═══ Next Best Action (CREDIBLE-357) ═══\n  No high-Crit dormant candidates.\n"
            .to_string();
    }
    let mut out = "═══ Next Best Action (CREDIBLE-357) ═══\n".to_string();
    for c in candidates {
        out.push_str(&format!(
            "  - {} (stages_short={})\n",
            c.name, c.stages_short
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cap(
        name: &str,
        criticality: Criticality,
        status: StageStatus,
        stages_short: u32,
    ) -> Capability {
        Capability {
            name: name.to_string(),
            criticality,
            status,
            stages_short,
        }
    }

    #[test]
    fn debt_ignores_live_and_low_crit_dormant() {
        let caps = vec![
            cap("live-crit", Criticality::Crit, StageStatus::Running, 3),
            cap("dormant-info", Criticality::Info, StageStatus::Pending, 2),
            cap("dormant-crit", Criticality::Crit, StageStatus::Pending, 2),
        ];
        // Only dormant-crit contributes: weight(4.0) * stages_short(2) = 8.0
        assert!((compute_debt(&caps) - 8.0).abs() < f64::EPSILON);
    }

    #[test]
    fn debt_sums_multiple_high_crit_dormant() {
        let caps = vec![
            cap("a", Criticality::Crit, StageStatus::Pending, 1),
            cap("b", Criticality::Crit, StageStatus::Pending, 3),
        ];
        // 4.0*1 + 4.0*3 = 16.0
        assert!((compute_debt(&caps) - 16.0).abs() < f64::EPSILON);
    }

    #[test]
    fn top5_dormant_ranks_by_crit_then_stages_short() {
        let caps = vec![
            cap("low-crit", Criticality::Info, StageStatus::Pending, 9),
            cap("live", Criticality::Crit, StageStatus::Complete, 9),
            cap("crit-far", Criticality::Crit, StageStatus::Pending, 5),
            cap("crit-near", Criticality::Crit, StageStatus::Pending, 1),
            cap("warn-mid", Criticality::Warn, StageStatus::Pending, 4),
        ];
        let top = top5_dormant_by_crit(&caps);
        let names: Vec<&str> = top.iter().map(|c| c.name.as_str()).collect();
        // "live" excluded (not dormant); crit-far beats crit-near (more
        // stages_short); warn-mid beats low-crit (higher criticality weight).
        assert_eq!(names, vec!["crit-far", "crit-near", "warn-mid", "low-crit"]);
    }

    #[test]
    fn top5_dormant_truncates_to_five() {
        let caps: Vec<Capability> = (0..8)
            .map(|i| cap(&format!("c{i}"), Criticality::Crit, StageStatus::Pending, i))
            .collect();
        assert_eq!(top5_dormant_by_crit(&caps).len(), 5);
    }

    #[test]
    fn nba_candidates_only_high_crit_dormant() {
        let caps = vec![
            cap("live-crit", Criticality::Crit, StageStatus::Running, 3),
            cap("dormant-warn", Criticality::Warn, StageStatus::Pending, 5),
            cap("dormant-crit-1", Criticality::Crit, StageStatus::Pending, 1),
            cap("dormant-crit-2", Criticality::Crit, StageStatus::Pending, 4),
        ];
        let names: Vec<&str> = next_best_action_candidates(&caps)
            .iter()
            .map(|c| c.name.as_str())
            .collect();
        // Excludes live-crit (not dormant) and dormant-warn (not high-Crit);
        // orders by stages_short desc.
        assert_eq!(names, vec!["dormant-crit-2", "dormant-crit-1"]);
    }

    #[test]
    fn crown_gauge_composes_live_pct_debt_and_top5() {
        let caps = vec![
            cap("live", Criticality::Crit, StageStatus::Healthy, 0),
            cap("dormant", Criticality::Crit, StageStatus::Pending, 2),
        ];
        let gauge = compute_crown_gauge(&caps);
        // live weight 4.0 / total weight 8.0 = 0.5
        assert!((gauge.live_pct - 0.5).abs() < f64::EPSILON);
        assert!((gauge.debt - 8.0).abs() < f64::EPSILON);
        assert_eq!(gauge.top5_dormant_names, vec!["dormant".to_string()]);
    }

    #[test]
    fn render_text_includes_live_pct_debt_and_top5() {
        let caps = vec![cap(
            "dormant-crit",
            Criticality::Crit,
            StageStatus::Pending,
            2,
        )];
        let gauge = compute_crown_gauge(&caps);
        let text = gauge.render_text();
        assert!(text.contains("live_pct:"));
        assert!(text.contains("debt:"));
        assert!(text.contains("dormant-crit"));
    }

    #[test]
    fn render_nba_lists_high_crit_dormant_candidates() {
        let caps = vec![
            cap("dormant-crit", Criticality::Crit, StageStatus::Pending, 3),
            cap("dormant-info", Criticality::Info, StageStatus::Pending, 3),
        ];
        let text = render_nba_candidates(&caps);
        assert!(text.contains("dormant-crit"));
        assert!(!text.contains("dormant-info"));
    }

    #[test]
    fn render_nba_reports_none_when_no_candidates() {
        let caps = vec![cap("live", Criticality::Crit, StageStatus::Running, 0)];
        assert!(render_nba_candidates(&caps).contains("No high-Crit dormant candidates"));
    }
}
