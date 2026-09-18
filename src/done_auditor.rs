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
use serde::{Deserialize, Serialize};
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

/// Resume position for the done-gap audit sweep: the (closed_at, id) key of
/// the last gap processed in the previous run. Keyset-paginated (not
/// offset-paginated) so inserts/deletes elsewhere in the table can't shift
/// which gaps a later run sees.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct Cursor {
    closed_at: i64,
    id: String,
}

fn cursor_path(repo_root: &Path) -> PathBuf {
    repo_root.join(".chump-locks").join("done_auditor_cursor.json")
}

fn load_cursor(repo_root: &Path) -> Option<Cursor> {
    let data = std::fs::read_to_string(cursor_path(repo_root)).ok()?;
    serde_json::from_str(&data).ok()
}

fn save_cursor(repo_root: &Path, cursor: &Cursor) {
    let path = cursor_path(repo_root);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(data) = serde_json::to_string(cursor) {
        let _ = std::fs::write(path, data);
    }
}

/// Pure keyset-pagination step: given the full closed_at-ordered done list and
/// the cursor left by the previous run, return the slice of gaps strictly
/// after that cursor. Wraps back to the start of the list when the cursor has
/// already consumed everything, so coverage keeps cycling instead of going
/// permanently idle once it reaches the end.
fn resume_batch<'a>(
    done: &'a [chump_gap_store::GapRow],
    cursor: Option<&Cursor>,
) -> Vec<&'a chump_gap_store::GapRow> {
    let start_idx = match cursor {
        Some(c) => done
            .iter()
            .position(|g| {
                let closed_at = g.closed_at.unwrap_or(i64::MIN);
                (closed_at, g.id.as_str()) > (c.closed_at, c.id.as_str())
            })
            .unwrap_or(done.len()),
        None => 0,
    };
    if start_idx >= done.len() {
        done.iter().collect()
    } else {
        done[start_idx..].iter().collect()
    }
}

/// Sweep up to `limit` DONE gaps (bounded because each check fetches its PR via
/// `pr_ac_coverage::run`, a `gh` call) and flag over-claims. Emits an
/// `over_claim_suspected` ambient event per flag. A fetch/coverage error skips
/// that gap rather than failing the whole sweep.
///
/// CREDIBLE-1332: gaps are returned oldest-closed-first (CREDIBLE-339) and a
/// persisted keyset cursor (`.chump-locks/done_auditor_cursor.json`) tracks the
/// last (closed_at, id) processed, so consecutive runs pick up strictly after
/// where the previous run left off instead of re-auditing the same head of the
/// list every time. Once the cursor reaches the end of the done gaps, the next
/// run wraps back to the start so coverage keeps cycling rather than going
/// permanently idle.
pub fn audit(repo_root: &Path, limit: usize) -> Result<DoneAuditReport> {
    let store = chump_gap_store::GapStore::open(repo_root)?;
    let done = store.list_by_status_ordered("done")?;
    let cursor = load_cursor(repo_root);
    let ordered = resume_batch(&done, cursor.as_ref());

    let mut report = DoneAuditReport::default();
    let mut last_seen: Option<Cursor> = None;
    for g in ordered.into_iter().take(limit) {
        last_seen = Some(Cursor {
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
        save_cursor(repo_root, &c);
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

    fn done_gap(id: &str, closed_at: Option<i64>) -> chump_gap_store::GapRow {
        chump_gap_store::GapRow {
            id: id.to_string(),
            domain: "INFRA".to_string(),
            title: "t".to_string(),
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

    #[test]
    fn resume_batch_with_no_cursor_starts_at_beginning() {
        let done = vec![
            done_gap("A-1", Some(10)),
            done_gap("A-2", Some(20)),
            done_gap("A-3", Some(30)),
        ];
        let batch = resume_batch(&done, None);
        assert_eq!(
            batch.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["A-1", "A-2", "A-3"]
        );
    }

    #[test]
    fn resume_batch_skips_everything_up_to_and_including_cursor() {
        let done = vec![
            done_gap("A-1", Some(10)),
            done_gap("A-2", Some(20)),
            done_gap("A-3", Some(30)),
        ];
        let cursor = Cursor {
            closed_at: 20,
            id: "A-2".to_string(),
        };
        let batch = resume_batch(&done, Some(&cursor));
        assert_eq!(
            batch.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["A-3"]
        );
    }

    #[test]
    fn resume_batch_wraps_around_when_cursor_exhausts_list() {
        let done = vec![done_gap("A-1", Some(10)), done_gap("A-2", Some(20))];
        let cursor = Cursor {
            closed_at: 20,
            id: "A-2".to_string(),
        };
        let batch = resume_batch(&done, Some(&cursor));
        assert_eq!(
            batch.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["A-1", "A-2"]
        );
    }

    #[test]
    fn two_consecutive_batches_are_disjoint() {
        let done: Vec<_> = (0..250)
            .map(|i| done_gap(&format!("A-{i}"), Some(i as i64)))
            .collect();
        let first = resume_batch(&done, None);
        let first_ids: std::collections::HashSet<&str> =
            first.iter().take(100).map(|g| g.id.as_str()).collect();
        let last_of_first = first[99];
        let cursor = Cursor {
            closed_at: last_of_first.closed_at.unwrap(),
            id: last_of_first.id.clone(),
        };
        let second = resume_batch(&done, Some(&cursor));
        let second_ids: std::collections::HashSet<&str> =
            second.iter().take(100).map(|g| g.id.as_str()).collect();
        assert!(first_ids.is_disjoint(&second_ids));
        assert_eq!(second_ids.len(), 100);
    }

    #[test]
    fn cursor_round_trips_through_disk() {
        let dir = tempfile::tempdir().unwrap();
        let cursor = Cursor {
            closed_at: 42,
            id: "A-7".to_string(),
        };
        save_cursor(dir.path(), &cursor);
        let loaded = load_cursor(dir.path()).expect("cursor should load");
        assert_eq!(loaded, cursor);
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
