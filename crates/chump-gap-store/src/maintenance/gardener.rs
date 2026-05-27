//! Registry health audit + queue-depth signal — port of
//! `scripts/coord/gap-gardener.py` (Phase 1 of INFRA-2000).
//!
//! ## What this module is
//!
//! The Python `gap-gardener.py` does two things:
//!
//! 1. **Audit** the registry's PM-health invariants (P0 count + age,
//!    vague-AC pickable gaps, pillar mix). This is the half that needs
//!    the canonical [`crate::GapStore`].
//! 2. **Seed** new gaps by parsing RED_LETTER.md / failing CI / TODO
//!    sources and opening a PR. This is operationally heavyweight
//!    (network calls, branch creation, `gh pr create`) and currently
//!    a moving target — porting it 1:1 would be hundreds of LOC of
//!    `tokio::process::Command` wrappers around `gh`.
//!
//! Phase 1 ports **the audit half** — the part that has typed-Rust
//! benefit. The seeding path stays in Python; the CLI shim only routes
//! the audit subcommand and the no-op `--check` flag to Rust. The
//! seeding workflow keeps running through the Python body.
//!
//! ## Audit invariants
//!
//! Matches `chump gap audit-priorities`:
//!
//! - P0 budget: count of `priority:P0 status:open` gaps, with ages.
//! - Vague pickable: `acceptance_criteria` empty or every item TODO.
//! - Pillar coverage: count per E/C/R/Z title prefix tag.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};

use crate::{acceptance_criteria_is_vague, GapStore};

/// PM-health audit report. Mirrors the columns `chump gap
/// audit-priorities` writes when run with `--json`.
#[derive(Debug, Clone, Default)]
pub struct AuditReport {
    /// Count of `priority:P0 status:open` gaps.
    pub p0_count: usize,
    /// Per-gap-id age in seconds (open P0s only).
    pub p0_ages_seconds: BTreeMap<String, i64>,
    /// Gap IDs whose age exceeds the 7-day stuck threshold.
    pub stuck_p0_ids: Vec<String>,
    /// IDs of open gaps with vague (or empty) acceptance_criteria.
    pub vague_pickable_ids: Vec<String>,
    /// Per-pillar-prefix open count (`EFFECTIVE` / `CREDIBLE` / `RESILIENT` /
    /// `ZERO-WASTE` / `MISSION` / `(none)`).
    pub pillar_open_counts: BTreeMap<String, usize>,
    /// Total open gap count across all pillars.
    pub total_open: usize,
}

/// 7 days in seconds — the audit's stuck-P0 threshold.
pub const P0_STUCK_THRESHOLD_SECS: i64 = 7 * 24 * 60 * 60;

/// The five pillar prefixes we recognize in titles. Matches the project's
/// title-tagging convention (CLAUDE.md "Pillar inventory" section).
pub const PILLAR_PREFIXES: &[&str] = &[
    "EFFECTIVE",
    "CREDIBLE",
    "RESILIENT",
    "ZERO-WASTE",
    "MISSION",
];

/// Read-only registry gardener. Holds a path; opens a short-lived
/// [`GapStore`] connection on each audit.
pub struct GapGardener {
    repo_root: std::path::PathBuf,
}

impl GapGardener {
    /// Build a gardener rooted at `repo_root`.
    pub fn new(repo_root: impl AsRef<Path>) -> Self {
        Self {
            repo_root: repo_root.as_ref().to_path_buf(),
        }
    }

    /// Run one full audit pass. Read-only; no mutations.
    pub fn audit(&self) -> Result<AuditReport> {
        let store = GapStore::open(&self.repo_root)
            .with_context(|| format!("open gap-store at {}", self.repo_root.display()))?;
        let opens = store.list(Some("open"))?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        let mut report = AuditReport {
            total_open: opens.len(),
            ..Default::default()
        };
        // Pre-seed pillar counts to a known order so JSON output is stable.
        for p in PILLAR_PREFIXES {
            report.pillar_open_counts.insert(p.to_string(), 0);
        }
        report.pillar_open_counts.insert("(none)".to_string(), 0);

        for gap in &opens {
            // P0 budget tracking.
            if gap.priority == "P0" {
                report.p0_count += 1;
                let age = if gap.created_at > 0 {
                    now - gap.created_at
                } else {
                    0
                };
                report.p0_ages_seconds.insert(gap.id.clone(), age);
                if age >= P0_STUCK_THRESHOLD_SECS {
                    report.stuck_p0_ids.push(gap.id.clone());
                }
            }
            // Vague pickable.
            if acceptance_criteria_is_vague(&gap.acceptance_criteria) {
                report.vague_pickable_ids.push(gap.id.clone());
            }
            // Pillar tagging from title.
            let pillar = title_pillar(&gap.title);
            *report.pillar_open_counts.entry(pillar).or_insert(0) += 1;
        }

        report.stuck_p0_ids.sort();
        report.vague_pickable_ids.sort();
        Ok(report)
    }
}

impl AuditReport {
    /// Exit-code non-zero (1) when any audit invariant fails. Matches
    /// `chump gap audit-priorities`'s contract used in CI gates.
    pub fn failing(&self) -> bool {
        self.p0_count > 5 || !self.stuck_p0_ids.is_empty() || !self.vague_pickable_ids.is_empty()
    }

    /// Render a human-readable summary matching the Python tool's
    /// final-block output shape closely enough for parity smoke checks.
    pub fn render(&self) -> String {
        let mut out = String::new();
        out.push_str("== gap-gardener: registry audit ==\n");
        out.push_str(&format!("  Total open gaps    : {}\n", self.total_open));
        out.push_str(&format!(
            "  P0 open count      : {} (budget 5)\n",
            self.p0_count
        ));
        if !self.stuck_p0_ids.is_empty() {
            out.push_str(&format!(
                "  Stuck P0 gaps (>7d): {}\n",
                self.stuck_p0_ids.len()
            ));
            for gid in &self.stuck_p0_ids {
                let age = self.p0_ages_seconds.get(gid).copied().unwrap_or(0);
                out.push_str(&format!(
                    "      {} (age {} days)\n",
                    gid,
                    age / (24 * 60 * 60)
                ));
            }
        }
        if !self.vague_pickable_ids.is_empty() {
            out.push_str(&format!(
                "  Vague pickable     : {} (no/TODO acceptance_criteria)\n",
                self.vague_pickable_ids.len()
            ));
            for gid in self.vague_pickable_ids.iter().take(10) {
                out.push_str(&format!("      {}\n", gid));
            }
            if self.vague_pickable_ids.len() > 10 {
                out.push_str(&format!(
                    "      ... {} more\n",
                    self.vague_pickable_ids.len() - 10
                ));
            }
        }
        out.push_str("  Pillar coverage    :\n");
        for (pillar, count) in &self.pillar_open_counts {
            out.push_str(&format!("      {:11} {}\n", pillar, count));
        }
        if self.failing() {
            out.push_str("\nFAIL: registry audit invariant breached.\n");
        } else {
            out.push_str("\nOK: registry audit invariants hold.\n");
        }
        out
    }

    /// Serialize the report as compact JSON for downstream consumers
    /// (e.g. the launchd planner). Stable keys.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "total_open": self.total_open,
            "p0_count": self.p0_count,
            "p0_ages_seconds": self.p0_ages_seconds,
            "stuck_p0_ids": self.stuck_p0_ids,
            "vague_pickable_ids": self.vague_pickable_ids,
            "pillar_open_counts": self.pillar_open_counts,
            "failing": self.failing(),
        })
    }
}

/// Map a gap title to the pillar prefix it declares (if any).
/// `(none)` when the title doesn't start with a known pillar prefix.
fn title_pillar(title: &str) -> String {
    let trimmed = title.trim_start();
    for p in PILLAR_PREFIXES {
        // Patterns observed in titles: `EFFECTIVE:`, `EFFECTIVE -`, `EFFECTIVE —`.
        if trimmed.starts_with(*p) {
            // Confirm the next char is a separator, not e.g. `EFFECTIVENESS`.
            let after = trimmed[p.len()..].chars().next();
            if matches!(
                after,
                Some(':') | Some(' ') | Some('-') | Some('—') | Some('/')
            ) {
                return (*p).to_string();
            }
        }
    }
    "(none)".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_pillar_recognizes_each_prefix() {
        assert_eq!(title_pillar("EFFECTIVE: add foo"), "EFFECTIVE");
        assert_eq!(title_pillar("CREDIBLE — measure bar"), "CREDIBLE");
        assert_eq!(title_pillar("RESILIENT - rescue baz"), "RESILIENT");
        assert_eq!(title_pillar("ZERO-WASTE: prune qux"), "ZERO-WASTE");
        assert_eq!(title_pillar("MISSION: ship it"), "MISSION");
        // EFFECTIVENESS should NOT match EFFECTIVE.
        assert_eq!(title_pillar("EFFECTIVENESS metric tweak"), "(none)");
        assert_eq!(title_pillar("just a title"), "(none)");
    }

    #[test]
    fn audit_report_failing_logic() {
        let mut r = AuditReport::default();
        assert!(!r.failing());
        r.p0_count = 6;
        assert!(r.failing());
        r.p0_count = 3;
        r.stuck_p0_ids.push("INFRA-1".to_string());
        assert!(r.failing());
        r.stuck_p0_ids.clear();
        r.vague_pickable_ids.push("INFRA-2".to_string());
        assert!(r.failing());
    }
}
