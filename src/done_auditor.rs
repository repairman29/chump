//! INFRA-3495 (COTG-3.2): anti-over-claim watchdog — the "umbrella-done !=
//! actually-done" sweep over DONE gaps.
//!
//! The gardener audits OPEN gaps for hygiene; nothing audited DONE gaps for
//! hollowness. `pr_ac_coverage` (INFRA-1541) scores a PR's diff against its
//! gap's acceptance bullets, but only PRE-merge, per-PR. This re-runs that SAME
//! coverage engine AFTER the fact, against each recently-closed gap's PR, and
//! flags any whose acceptance bullets shipped uncovered and unwaived — a gap
//! marked `done` whose AC weren't actually met. Reuses the coverage engine
//! wholesale; only the "sweep what already shipped" loop is new.

use crate::pr_ac_coverage::{self, AcCoverageResult};
use anyhow::Result;
use std::io::Write;
use std::path::{Path, PathBuf};

/// CREDIBLE-279 AC5: `default_acceptance_criteria` (src/main.rs) auto-generates
/// three boilerplate AC lines for every gap reserved without explicit
/// `--acceptance-criteria`. No diff can meaningfully cover or fail them — the
/// first is satisfied by any change to the gap's own domain, the other two are
/// generic process reminders repeated verbatim on every gap. Scoring them as
/// real signal is what let all 79 CREDIBLE-279 false-dones slip past
/// `audit-done`'s AC-coverage check: nearly every bullet it flagged in the
/// 2026-08-10 run was one of these three. Matched structurally (not full-text)
/// because the first line interpolates the gap's title + domain.
fn is_boilerplate_ac(text: &str) -> bool {
    let t = text.trim();
    (t.starts_with("The change described by \"")
        && t.contains("is implemented in the relevant")
        && t.ends_with("code path(s).")
        )
        || t == "At least one test (cargo test or scripts/ci/test-*.sh) proves the new behavior and fails without the change."
        || t == "cargo fmt + clippy --all-targets -D warnings + check pass; no regression to existing tests."
}

/// Pure decision (no network) over an already-computed coverage result: a done
/// gap over-claims if its PR left acceptance bullets uncovered AND unwaived.
/// Returns the uncovered bullet indices, or None when every bullet is covered,
/// waived, or boilerplate (CREDIBLE-279 AC5 — boilerplate bullets are excluded
/// from the denominator entirely, not scored either way). Split out from the
/// network sweep so the flag rule is unit-testable.
pub fn is_over_claim(coverage: &AcCoverageResult) -> Option<Vec<usize>> {
    let uncovered: Vec<usize> = coverage
        .bullets
        .iter()
        .filter(|b| !b.covered && !b.waived && !is_boilerplate_ac(&b.text))
        .map(|b| b.index)
        .collect();
    if uncovered.is_empty() {
        None
    } else {
        Some(uncovered)
    }
}

/// Count of a coverage result's bullets that are boilerplate — excluded from
/// both the numerator and denominator, but worth reporting so the audit
/// "says so" per AC5 rather than silently shrinking the bullet count.
fn boilerplate_count(coverage: &AcCoverageResult) -> usize {
    coverage
        .bullets
        .iter()
        .filter(|b| is_boilerplate_ac(&b.text))
        .count()
}

/// One flagged over-claim.
#[derive(Debug, Clone)]
pub struct OverClaim {
    pub gap_id: String,
    pub closed_pr: i64,
    pub uncovered: Vec<usize>,
    pub total_bullets: usize,
}

/// Result of a done-gap audit sweep.
#[derive(Debug, Default)]
pub struct DoneAuditReport {
    pub audited: usize,
    pub skipped_no_pr: usize,
    pub skipped_no_ac: usize,
    pub fetch_errors: usize,
    /// AC5: boilerplate bullets seen across all audited gaps this run — excluded
    /// from the over-claim denominator, but counted and surfaced so the report
    /// "says so" rather than silently shrinking.
    pub boilerplate_excluded: usize,
    pub flagged: Vec<OverClaim>,
}

impl DoneAuditReport {
    /// True when at least one done gap over-claims — the CI/daemon exit signal.
    pub fn failing(&self) -> bool {
        !self.flagged.is_empty()
    }

    pub fn render(&self) -> String {
        let mut out = format!(
            "done-gap over-claim audit: {} audited, {} flagged ({} no-pr, {} no-ac, {} fetch-err skipped, {} boilerplate bullets excluded from scoring)\n",
            self.audited,
            self.flagged.len(),
            self.skipped_no_pr,
            self.skipped_no_ac,
            self.fetch_errors,
            self.boilerplate_excluded
        );
        for oc in &self.flagged {
            out.push_str(&format!(
                "  \u{26a0} {} (#{}) over-claims: {}/{} acceptance bullets uncovered+unwaived (indices {:?})\n",
                oc.gap_id,
                oc.closed_pr,
                oc.uncovered.len(),
                oc.total_bullets,
                oc.uncovered
            ));
        }
        if self.flagged.is_empty() {
            out.push_str("  \u{2713} no over-claims among audited done gaps\n");
        }
        out
    }
}

/// CREDIBLE-279 AC3: `GapStore::list` is `ORDER BY id`, and the old call site
/// did `.take(100)` against that — every run re-examined the same alphabetical
/// prefix (COG-*, CREDIBLE-0xx) forever; 1,520 of 1,608 done gaps (94.5%) had
/// never once been looked at. This persists a resume cursor keyed on
/// `(closed_at, id)` so each run advances past what the last run covered,
/// wrapping back to the oldest-closed gap once the sweep reaches the end.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
struct AuditCursor {
    last_closed_at: i64,
    last_id: String,
}

fn cursor_path(repo_root: &Path) -> PathBuf {
    repo_root
        .join(".chump-locks")
        .join("done_auditor_cursor.json")
}

fn load_cursor(repo_root: &Path) -> AuditCursor {
    std::fs::read_to_string(cursor_path(repo_root))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_cursor(repo_root: &Path, cursor: &AuditCursor) {
    let path = cursor_path(repo_root);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(s) = serde_json::to_string(cursor) {
        let _ = std::fs::write(path, s);
    }
}

/// Order done gaps by `(closed_at, id)` and slice out the next `limit` gaps
/// after `cursor`, wrapping to the start when the cursor is at or past the
/// end. Pure function (no I/O) so the resume/wrap logic is unit-testable
/// without a real GapStore.
fn next_batch(
    mut done: Vec<chump_gap_store::GapRow>,
    cursor: &AuditCursor,
    limit: usize,
) -> Vec<chump_gap_store::GapRow> {
    done.sort_by(|a, b| {
        (a.closed_at.unwrap_or(0), a.id.as_str()).cmp(&(b.closed_at.unwrap_or(0), b.id.as_str()))
    });
    let start = done
        .iter()
        .position(|g| {
            (g.closed_at.unwrap_or(0), g.id.as_str())
                > (cursor.last_closed_at, cursor.last_id.as_str())
        })
        .unwrap_or(done.len());
    let start = if start >= done.len() { 0 } else { start };
    done.into_iter().skip(start).take(limit).collect()
}

/// Sweep up to `limit` DONE gaps (bounded because each check fetches its PR via
/// `pr_ac_coverage::run`, a `gh` call) and flag over-claims. Emits an
/// `over_claim_suspected` ambient event per flag. A fetch/coverage error skips
/// that gap rather than failing the whole sweep. Advances the resume cursor
/// (AC3) so successive calls examine disjoint slices of the done-gap registry.
pub fn audit(repo_root: &Path, limit: usize) -> Result<DoneAuditReport> {
    let store = chump_gap_store::GapStore::open(repo_root)?;
    let done = store.list(Some("done"))?;
    let cursor = load_cursor(repo_root);
    let batch = next_batch(done, &cursor, limit);
    let mut report = DoneAuditReport::default();
    for g in &batch {
        let pr = match g.closed_pr {
            Some(p) if p > 0 => p,
            _ => {
                report.skipped_no_pr += 1;
                continue;
            }
        };
        if g.acceptance_criteria.trim().is_empty() {
            report.skipped_no_ac += 1;
            continue;
        }
        report.audited += 1;
        let coverage = match pr_ac_coverage::run(pr as u64) {
            Ok(c) => c,
            Err(_) => {
                report.fetch_errors += 1;
                continue;
            }
        };
        report.boilerplate_excluded += boilerplate_count(&coverage);
        if let Some(uncovered) = is_over_claim(&coverage) {
            emit_over_claim(repo_root, &g.id, pr, &uncovered, coverage.bullets.len());
            report.flagged.push(OverClaim {
                gap_id: g.id.clone(),
                closed_pr: pr,
                uncovered,
                total_bullets: coverage.bullets.len(),
            });
        }
    }
    if let Some(last) = batch.last() {
        save_cursor(
            repo_root,
            &AuditCursor {
                last_closed_at: last.closed_at.unwrap_or(0),
                last_id: last.id.clone(),
            },
        );
    }
    Ok(report)
}

/// Best-effort append of an `over_claim_suspected` event to the ambient stream.
fn emit_over_claim(repo_root: &Path, gap_id: &str, pr: i64, uncovered: &[usize], total: usize) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let path = lock_dir.join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    // scanner-anchor: "kind":"over_claim_suspected"
    let line = format!(
        r#"{{"ts":"{ts}","kind":"over_claim_suspected","gap_id":"{gap_id}","closed_pr":{pr},"uncovered_bullets":{},"total_bullets":{total}}}"#,
        uncovered.len()
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pr_ac_coverage::{AcCoverageResult, BulletResult, CoverageStatus};

    fn bullet(index: usize, covered: bool, waived: bool) -> BulletResult {
        BulletResult {
            index,
            text: format!("bullet {index}"),
            covered,
            waived,
            waive_reason: None,
            rules_hit: vec![],
            is_proof: false,
            proof_detail: None,
        }
    }

    #[test]
    fn is_over_claim_flags_uncovered_unwaived_bullets() {
        // bullet 0 covered; bullet 1 uncovered+unwaived (over-claim); bullet 2 waived (ok).
        let cov = AcCoverageResult {
            pr_number: 1,
            gap_id: Some("INFRA-1".into()),
            status: CoverageStatus::Pass,
            bullets: vec![
                bullet(0, true, false),
                bullet(1, false, false),
                bullet(2, false, true),
            ],
        };
        assert_eq!(is_over_claim(&cov), Some(vec![1]));
    }

    #[test]
    fn is_over_claim_none_when_all_covered_or_waived() {
        let cov = AcCoverageResult {
            pr_number: 2,
            gap_id: Some("INFRA-2".into()),
            status: CoverageStatus::Pass,
            bullets: vec![bullet(0, true, false), bullet(1, false, true)],
        };
        assert!(is_over_claim(&cov).is_none());
    }

    #[test]
    fn is_over_claim_none_when_no_bullets() {
        let cov = AcCoverageResult {
            pr_number: 3,
            gap_id: None,
            status: CoverageStatus::Pass,
            bullets: vec![],
        };
        assert!(is_over_claim(&cov).is_none());
    }

    // ── AC5: boilerplate AC bullets excluded from scoring ──────────────────

    fn boilerplate_bullet(index: usize, text: &str) -> BulletResult {
        BulletResult {
            index,
            text: text.to_string(),
            covered: false,
            waived: false,
            waive_reason: None,
            rules_hit: vec![],
            is_proof: false,
            proof_detail: None,
        }
    }

    #[test]
    fn is_boilerplate_ac_matches_all_three_known_lines() {
        assert!(is_boilerplate_ac(
            "The change described by \"add a foo widget\" is implemented in the relevant EFFECTIVE code path(s)."
        ));
        assert!(is_boilerplate_ac(
            "At least one test (cargo test or scripts/ci/test-*.sh) proves the new behavior and fails without the change."
        ));
        assert!(is_boilerplate_ac(
            "cargo fmt + clippy --all-targets -D warnings + check pass; no regression to existing tests."
        ));
        assert!(!is_boilerplate_ac(
            "chump gap audit-done rejects any AC that is one of the three boilerplate lines."
        ));
    }

    #[test]
    fn is_over_claim_ignores_uncovered_boilerplate_but_still_flags_real_misses() {
        let cov = AcCoverageResult {
            pr_number: 4,
            gap_id: Some("CREDIBLE-279".into()),
            status: CoverageStatus::Pass,
            bullets: vec![
                boilerplate_bullet(
                    0,
                    "The change described by \"x\" is implemented in the relevant INFRA code path(s).",
                ),
                boilerplate_bullet(
                    1,
                    "At least one test (cargo test or scripts/ci/test-*.sh) proves the new behavior and fails without the change.",
                ),
                bullet(2, false, false), // a real, uncovered, unwaived bullet
            ],
        };
        // Only the real bullet (index 2) is flagged — the two boilerplate lines
        // never enter the denominator, uncovered or not.
        assert_eq!(is_over_claim(&cov), Some(vec![2]));
    }

    #[test]
    fn is_over_claim_none_when_every_uncovered_bullet_is_boilerplate() {
        let cov = AcCoverageResult {
            pr_number: 5,
            gap_id: Some("CREDIBLE-279".into()),
            status: CoverageStatus::Pass,
            bullets: vec![
                boilerplate_bullet(
                    0,
                    "The change described by \"x\" is implemented in the relevant CREDIBLE code path(s).",
                ),
                boilerplate_bullet(
                    1,
                    "cargo fmt + clippy --all-targets -D warnings + check pass; no regression to existing tests.",
                ),
            ],
        };
        assert!(is_over_claim(&cov).is_none());
    }

    // ── AC3: resume cursor advances across runs, disjoint sets ─────────────

    fn gap_row(id: &str, closed_at: i64) -> chump_gap_store::GapRow {
        chump_gap_store::GapRow {
            id: id.to_string(),
            domain: "INFRA".to_string(),
            title: format!("title for {id}"),
            description: String::new(),
            priority: "P2".to_string(),
            effort: "s".to_string(),
            status: "done".to_string(),
            acceptance_criteria: "[]".to_string(),
            depends_on: "[]".to_string(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: Some(closed_at),
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: Some(1),
            skills_required: String::new(),
            preferred_backend: String::new(),
            preferred_machine: String::new(),
            estimated_minutes: String::new(),
            required_model: String::new(),
            shipped_in: None,
            outcome_id: None,
            evidence: None,
        }
    }

    #[test]
    fn next_batch_advances_the_cursor_two_consecutive_runs_are_disjoint() {
        // 10 done gaps, closed_at 1..=10 (ties broken by id, irrelevant here).
        let gaps: Vec<_> = (1..=10).map(|n| gap_row(&format!("G-{n}"), n)).collect();

        let cursor0 = AuditCursor::default();
        let run1 = next_batch(gaps.clone(), &cursor0, 4);
        assert_eq!(
            run1.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["G-1", "G-2", "G-3", "G-4"]
        );

        let cursor1 = AuditCursor {
            last_closed_at: run1.last().unwrap().closed_at.unwrap(),
            last_id: run1.last().unwrap().id.clone(),
        };
        let run2 = next_batch(gaps.clone(), &cursor1, 4);
        assert_eq!(
            run2.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["G-5", "G-6", "G-7", "G-8"]
        );

        // Disjoint: no gap id examined in run1 reappears in run2.
        let run1_ids: std::collections::HashSet<_> = run1.iter().map(|g| g.id.clone()).collect();
        for g in &run2 {
            assert!(
                !run1_ids.contains(&g.id),
                "run2 re-examined {} which run1 already covered",
                g.id
            );
        }
    }

    #[test]
    fn next_batch_wraps_to_the_start_once_the_cursor_reaches_the_end() {
        let gaps: Vec<_> = (1..=5).map(|n| gap_row(&format!("G-{n}"), n)).collect();
        // Cursor parked past the last gap — simulates a prior run that fully
        // consumed the registry.
        let cursor = AuditCursor {
            last_closed_at: 5,
            last_id: "G-5".to_string(),
        };
        let batch = next_batch(gaps, &cursor, 3);
        assert_eq!(
            batch.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["G-1", "G-2", "G-3"],
            "cursor past the end wraps back to the oldest-closed gap"
        );
    }
}
