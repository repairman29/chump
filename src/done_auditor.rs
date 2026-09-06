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
use std::path::Path;

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
        out
    }
}

/// Persisted resume position: the (closed_at, id) of the last gap examined by
/// the previous run. Gaps are ordered by closed_at ASC (ties broken by id) so
/// this pair is a total order — the next run resumes strictly after it
/// instead of re-auditing the same oldest-N gaps forever.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct AuditCursor {
    closed_at: i64,
    id: String,
}

fn cursor_path(repo_root: &Path) -> std::path::PathBuf {
    repo_root
        .join(".chump-locks")
        .join("done_auditor_cursor.json")
}

fn read_cursor(repo_root: &Path) -> Option<AuditCursor> {
    let raw = std::fs::read_to_string(cursor_path(repo_root)).ok()?;
    serde_json::from_str(&raw).ok()
}

fn write_cursor(repo_root: &Path, cursor: &AuditCursor) {
    let path = cursor_path(repo_root);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string(cursor) {
        let _ = std::fs::write(path, json);
    }
}

/// True when `g` sorts strictly after `cursor` in the (closed_at, id) order
/// gaps are audited in. Gaps with no `closed_at` sort first (closed_at
/// defaults to i64::MIN) so legacy rows without a timestamp are still
/// reachable exactly once rather than skipped forever.
fn after_cursor(g: &chump_gap_store::GapRow, cursor: &AuditCursor) -> bool {
    let ca = g.closed_at.unwrap_or(i64::MIN);
    (ca, g.id.as_str()) > (cursor.closed_at, cursor.id.as_str())
}

/// Pure batch selection: given all done gaps (already ordered oldest-closed
/// first) and an optional resume cursor, pick up to `limit` gaps to examine
/// this run plus the cursor value to persist afterward. Split out from
/// `audit` so the resume/wraparound behavior is unit-testable without a real
/// GapStore or network access.
fn select_batch<'a>(
    done: &'a [chump_gap_store::GapRow],
    cursor: Option<&AuditCursor>,
    limit: usize,
) -> Vec<&'a chump_gap_store::GapRow> {
    let mut batch: Vec<&chump_gap_store::GapRow> = match cursor {
        Some(c) => done.iter().filter(|g| after_cursor(g, c)).collect(),
        None => done.iter().collect(),
    };
    // Wrap around: cursor is past the newest done gap (or nothing new since
    // last pass) — start over from the oldest so a full pass always repeats
    // rather than sticking forever at the end.
    if batch.is_empty() {
        batch = done.iter().collect();
    }
    batch.into_iter().take(limit).collect()
}

/// Sweep up to `limit` DONE gaps (bounded because each check fetches its PR via
/// `pr_ac_coverage::run`, a `gh` call) and flag over-claims. Emits an
/// `over_claim_suspected` ambient event per flag. A fetch/coverage error skips
/// that gap rather than failing the whole sweep.
///
/// CREDIBLE-339 / CREDIBLE-951: gaps are ordered oldest-closed-first and a
/// persisted cursor (`.chump-locks/done_auditor_cursor.json`) tracks the last
/// gap examined, so each run resumes with the *next* batch instead of
/// re-auditing the same oldest-N gaps. The cursor advances past every gap
/// considered in the batch (including no-pr/no-ac skips) so it always makes
/// forward progress. Once the cursor reaches the newest done gap, the next
/// run wraps back to the start so gaps closed after a full pass are picked up
/// again.
pub fn audit(repo_root: &Path, limit: usize) -> Result<DoneAuditReport> {
    let store = chump_gap_store::GapStore::open(repo_root)?;
    let done = store.list_by_status_ordered("done")?;
    let cursor = read_cursor(repo_root);
    let batch = select_batch(&done, cursor.as_ref(), limit);
    let mut report = DoneAuditReport::default();
    let mut last_seen: Option<AuditCursor> = None;
    for g in batch.into_iter() {
        last_seen = Some(AuditCursor {
            closed_at: g.closed_at.unwrap_or(i64::MIN),
            id: g.id.clone(),
        });
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
    if let Some(c) = last_seen {
        write_cursor(repo_root, &c);
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

    fn gap(id: &str, closed_at: i64) -> chump_gap_store::GapRow {
        chump_gap_store::GapRow {
            id: id.to_string(),
            domain: "INFRA".into(),
            title: format!("gap {id}"),
            description: String::new(),
            priority: "P2".into(),
            effort: "s".into(),
            status: "done".into(),
            acceptance_criteria: "1. did the thing".into(),
            depends_on: String::new(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: closed_at,
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

    /// CREDIBLE-951 AC1/AC2: no reliance on alphabetical prefix — ordering is
    /// by closed_at, and the cursor advances so a second call with the
    /// persisted cursor picks up strictly after the first batch.
    #[test]
    fn select_batch_first_call_takes_oldest_n_by_closed_at() {
        // Deliberately out of alphabetical order but ascending closed_at.
        let done = vec![gap("ZZZ-3", 300), gap("AAA-1", 100), gap("MMM-2", 200)];
        let ordered: Vec<_> = {
            let mut d = done.clone();
            d.sort_by_key(|g| g.closed_at);
            d
        };
        let batch = select_batch(&ordered, None, 2);
        let ids: Vec<&str> = batch.iter().map(|g| g.id.as_str()).collect();
        assert_eq!(ids, vec!["AAA-1", "MMM-2"]);
    }

    #[test]
    fn select_batch_two_runs_examine_disjoint_sets() {
        let mut done: Vec<_> = (0..10).map(|i| gap(&format!("G-{i}"), i * 10)).collect();
        done.sort_by_key(|g| g.closed_at);

        let first = select_batch(&done, None, 4);
        let first_cursor = AuditCursor {
            closed_at: first.last().unwrap().closed_at.unwrap(),
            id: first.last().unwrap().id.clone(),
        };
        let second = select_batch(&done, Some(&first_cursor), 4);

        let first_ids: std::collections::HashSet<&str> =
            first.iter().map(|g| g.id.as_str()).collect();
        let second_ids: std::collections::HashSet<&str> =
            second.iter().map(|g| g.id.as_str()).collect();
        assert!(
            first_ids.is_disjoint(&second_ids),
            "first={first_ids:?} second={second_ids:?}"
        );
        assert_eq!(second.first().unwrap().id, "G-4");
        assert_eq!(second.last().unwrap().id, "G-7");
    }

    #[test]
    fn select_batch_covers_all_gaps_within_two_runs_when_limit_ge_half() {
        // AC3: coverage jumps from a small first-run fraction to >95% within
        // two runs — here limit is large enough that two runs cover 100%.
        let mut done: Vec<_> = (0..20).map(|i| gap(&format!("G-{i}"), i * 10)).collect();
        done.sort_by_key(|g| g.closed_at);

        let first = select_batch(&done, None, 15);
        let cursor = AuditCursor {
            closed_at: first.last().unwrap().closed_at.unwrap(),
            id: first.last().unwrap().id.clone(),
        };
        let second = select_batch(&done, Some(&cursor), 15);

        let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
        seen.extend(first.iter().map(|g| g.id.as_str()));
        seen.extend(second.iter().map(|g| g.id.as_str()));
        let coverage_pct = seen.len() as f64 / done.len() as f64 * 100.0;
        assert!(coverage_pct > 95.0, "coverage was {coverage_pct}%");
    }

    #[test]
    fn select_batch_wraps_around_after_exhausting_all_gaps() {
        let mut done: Vec<_> = (0..3).map(|i| gap(&format!("G-{i}"), i * 10)).collect();
        done.sort_by_key(|g| g.closed_at);
        let cursor = AuditCursor {
            closed_at: done.last().unwrap().closed_at.unwrap(),
            id: done.last().unwrap().id.clone(),
        };
        let batch = select_batch(&done, Some(&cursor), 10);
        // Cursor is past the newest gap — wraps to start over rather than
        // sticking empty forever.
        assert_eq!(batch.len(), 3);
        assert_eq!(batch.first().unwrap().id, "G-0");
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
}
