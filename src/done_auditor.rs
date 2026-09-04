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
use chump_gap_store::GapRow;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Pure decision (no network) over an already-computed coverage result: a done
/// gap over-claims if its PR left acceptance bullets uncovered AND unwaived.
/// Returns the uncovered bullet indices, or None when every bullet is covered or
/// waived. Split out from the network sweep so the flag rule is unit-testable.
pub fn is_over_claim(coverage: &AcCoverageResult) -> Option<Vec<usize>> {
    let uncovered: Vec<usize> = coverage
        .bullets
        .iter()
        .filter(|b| !b.covered && !b.waived)
        .map(|b| b.index)
        .collect();
    if uncovered.is_empty() {
        None
    } else {
        Some(uncovered)
    }
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
    pub flagged: Vec<OverClaim>,
    /// CREDIBLE-794: ids of the gaps this run's batch examined, in the order
    /// examined — printed so consecutive runs can be diffed in logs to prove
    /// disjoint batches.
    pub batch_gap_ids: Vec<String>,
    /// CREDIBLE-794: resume cursor (`closed_at`) before/after this run.
    pub cursor_before: Option<i64>,
    pub cursor_after: Option<i64>,
}

impl DoneAuditReport {
    /// True when at least one done gap over-claims — the CI/daemon exit signal.
    pub fn failing(&self) -> bool {
        !self.flagged.is_empty()
    }

    pub fn render(&self) -> String {
        let mut out = format!(
            "done-gap over-claim audit: {} audited, {} flagged ({} no-pr, {} no-ac, {} fetch-err skipped)\n",
            self.audited,
            self.flagged.len(),
            self.skipped_no_pr,
            self.skipped_no_ac,
            self.fetch_errors
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
        out.push_str(&format!(
            "  cursor: {:?} -> {:?}, batch ({} gaps): {:?}\n",
            self.cursor_before,
            self.cursor_after,
            self.batch_gap_ids.len(),
            self.batch_gap_ids
        ));
        out
    }
}

/// Path to the persisted resume cursor (CREDIBLE-794).
fn cursor_path(repo_root: &Path) -> PathBuf {
    repo_root
        .join(".chump-locks")
        .join("done_auditor_cursor.json")
}

/// Read the persisted cursor: the `closed_at` of the last-audited gap from
/// the prior run. `None` means "no prior run" — the next batch starts from
/// the very oldest done gap.
fn read_cursor(repo_root: &Path) -> Option<i64> {
    let raw = std::fs::read_to_string(cursor_path(repo_root)).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    v.get("last_closed_at").and_then(|x| x.as_i64())
}

/// Persist the cursor so the next run resumes past it.
fn write_cursor(repo_root: &Path, cursor: i64) {
    let dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&dir);
    let body = format!(r#"{{"last_closed_at":{cursor}}}"#);
    let _ = std::fs::write(cursor_path(repo_root), body);
}

/// Pure batch-selection: given all done gaps ordered by `closed_at` ASC and a
/// persisted cursor, pick up to `limit` gaps strictly newer (by `closed_at`)
/// than the cursor, and compute the new cursor to persist after the run.
/// Gaps with no `closed_at` sort as the oldest possible value so they are
/// picked up on the first run and never re-picked once passed.
///
/// Split out from `audit()` so cursor advancement is unit-testable without
/// `pr_ac_coverage::run`'s `gh` network dependency.
pub fn select_batch(
    gaps: &[GapRow],
    cursor: Option<i64>,
    limit: usize,
) -> (Vec<GapRow>, Option<i64>) {
    let threshold = cursor.unwrap_or(i64::MIN);
    let batch: Vec<GapRow> = gaps
        .iter()
        .filter(|g| {
            let closed_at = g.closed_at.unwrap_or(i64::MIN);
            cursor.is_none() || closed_at > threshold
        })
        .take(limit)
        .cloned()
        .collect();
    let new_cursor = batch
        .iter()
        .map(|g| g.closed_at.unwrap_or(i64::MIN))
        .max()
        .or(cursor);
    (batch, new_cursor)
}

/// Sweep up to `limit` DONE gaps (bounded because each check fetches its PR via
/// `pr_ac_coverage::run`, a `gh` call) and flag over-claims. Emits an
/// `over_claim_suspected` ambient event per flag. A fetch/coverage error skips
/// that gap rather than failing the whole sweep.
///
/// CREDIBLE-339: gaps returned oldest-closed-first so each limited run
/// makes forward progress without re-auditing the same set.
///
/// CREDIBLE-794: a persisted resume cursor (`.chump-locks/done_auditor_cursor.json`)
/// tracks the `closed_at` of the last gap audited so consecutive runs sweep
/// disjoint sets of gaps instead of re-auditing the same oldest `limit` every
/// time — coverage grows across runs rather than plateauing at `limit`.
pub fn audit(repo_root: &Path, limit: usize) -> Result<DoneAuditReport> {
    let store = chump_gap_store::GapStore::open(repo_root)?;
    let done = store.list_by_status_ordered("done")?;
    let cursor = read_cursor(repo_root);
    let (mut batch, mut new_cursor) = select_batch(&done, cursor, limit);
    // Cursor ran off the newest done gap — wrap around so the sweep keeps
    // making forward progress (and coverage) instead of stalling forever.
    if batch.is_empty() && !done.is_empty() && cursor.is_some() {
        let (b, c) = select_batch(&done, None, limit);
        batch = b;
        new_cursor = c;
    }
    let mut report = DoneAuditReport::default();
    report.cursor_before = cursor;
    report.cursor_after = new_cursor;
    report.batch_gap_ids = batch.iter().map(|g| g.id.clone()).collect();
    for g in batch.iter() {
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
    if let Some(c) = new_cursor {
        write_cursor(repo_root, c);
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

    fn gap(id: &str, closed_at: Option<i64>) -> GapRow {
        GapRow {
            id: id.to_string(),
            domain: "CREDIBLE".to_string(),
            title: id.to_string(),
            description: String::new(),
            priority: "P2".to_string(),
            effort: "s".to_string(),
            status: "done".to_string(),
            acceptance_criteria: "1. did the thing".to_string(),
            depends_on: String::new(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at,
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

    // CREDIBLE-794: resume cursor tests.

    #[test]
    fn select_batch_first_run_starts_from_oldest() {
        let gaps = vec![gap("A", Some(10)), gap("B", Some(20)), gap("C", Some(30))];
        let (batch, cursor) = select_batch(&gaps, None, 2);
        assert_eq!(
            batch.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["A", "B"]
        );
        assert_eq!(cursor, Some(20));
    }

    #[test]
    fn select_batch_second_run_is_disjoint_from_first() {
        let gaps = vec![
            gap("A", Some(10)),
            gap("B", Some(20)),
            gap("C", Some(30)),
            gap("D", Some(40)),
        ];
        let (first, cursor1) = select_batch(&gaps, None, 2);
        let (second, cursor2) = select_batch(&gaps, cursor1, 2);

        let first_ids: std::collections::HashSet<_> = first.iter().map(|g| g.id.clone()).collect();
        let second_ids: std::collections::HashSet<_> =
            second.iter().map(|g| g.id.clone()).collect();
        assert!(
            first_ids.is_disjoint(&second_ids),
            "expected disjoint batches, got {first_ids:?} and {second_ids:?}"
        );
        assert_eq!(
            second.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["C", "D"]
        );
        assert_eq!(cursor2, Some(40));
    }

    #[test]
    fn select_batch_cursor_persists_past_batches_and_covers_more_over_time() {
        // 4 done gaps, limit 2: two runs cover 100% instead of a single run's
        // 50%. This mirrors the real fixture: without a cursor, every run
        // re-audits the same oldest `limit` gaps and coverage plateaus.
        let gaps = vec![
            gap("A", Some(10)),
            gap("B", Some(20)),
            gap("C", Some(30)),
            gap("D", Some(40)),
        ];
        let mut covered = std::collections::HashSet::new();
        let mut cursor = None;
        for _ in 0..2 {
            let (batch, new_cursor) = select_batch(&gaps, cursor, 2);
            covered.extend(batch.iter().map(|g| g.id.clone()));
            cursor = new_cursor;
        }
        assert_eq!(covered.len(), gaps.len(), "two runs should cover all gaps");
    }

    #[test]
    fn select_batch_handles_missing_closed_at_on_first_run_only() {
        let gaps = vec![gap("A", None), gap("B", Some(10))];
        let (first, cursor1) = select_batch(&gaps, None, 10);
        assert_eq!(
            first.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["A", "B"]
        );
        // Second run with the persisted cursor sees nothing new left.
        let (second, _) = select_batch(&gaps, cursor1, 10);
        assert!(second.is_empty());
    }

    #[test]
    fn select_batch_empty_input_returns_empty_batch_and_keeps_cursor() {
        let gaps: Vec<GapRow> = vec![];
        let (batch, cursor) = select_batch(&gaps, Some(5), 10);
        assert!(batch.is_empty());
        assert_eq!(cursor, Some(5));
    }
}
