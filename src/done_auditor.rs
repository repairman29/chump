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

/// Name of the persisted resume-cursor file, relative to `.chump-locks/`.
const CURSOR_FILE: &str = "done_auditor_cursor.json";

/// Read the persisted `(closed_at, gap_id)` cursor from a prior run, if any.
/// Missing/malformed files are treated as "no cursor" (start from the top)
/// rather than an error — the cursor is an optimization, not a correctness
/// requirement.
fn read_cursor(repo_root: &Path) -> Option<(i64, String)> {
    let raw = std::fs::read_to_string(repo_root.join(".chump-locks").join(CURSOR_FILE)).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let closed_at = v.get("last_closed_at")?.as_i64()?;
    let id = v.get("last_id")?.as_str()?.to_string();
    Some((closed_at, id))
}

/// Persist `(closed_at, gap_id)` of the last gap examined so the next run
/// resumes past it instead of re-auditing the same oldest-closed window.
fn write_cursor(repo_root: &Path, closed_at: i64, id: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let body = format!(r#"{{"last_closed_at":{closed_at},"last_id":{id:?}}}"#);
    let _ = std::fs::write(lock_dir.join(CURSOR_FILE), body);
}

/// Pure windowing: given gaps already ordered oldest-closed-first, return up
/// to `limit` entries strictly after `cursor` (by `(closed_at, id)`, treating
/// a missing `closed_at` as the earliest possible value — matching SQLite's
/// NULLS-first ASC ordering used by `list_by_status_ordered`). `cursor: None`
/// starts from the top. Split out from `audit` so the resume behavior is
/// unit-testable without a real gap store or network calls.
fn select_window<'a>(
    gaps: &'a [chump_gap_store::GapRow],
    cursor: Option<(i64, &str)>,
    limit: usize,
) -> &'a [chump_gap_store::GapRow] {
    let start = match cursor {
        None => 0,
        Some((c_at, c_id)) => gaps
            .iter()
            .position(|g| {
                let at = g.closed_at.unwrap_or(i64::MIN);
                (at, g.id.as_str()) > (c_at, c_id)
            })
            .unwrap_or(gaps.len()),
    };
    let end = (start + limit).min(gaps.len());
    &gaps[start..end]
}

/// Sweep up to `limit` DONE gaps (bounded because each check fetches its PR via
/// `pr_ac_coverage::run`, a `gh` call) and flag over-claims. Emits an
/// `over_claim_suspected` ambient event per flag. A fetch/coverage error skips
/// that gap rather than failing the whole sweep.
///
/// CREDIBLE-951/CREDIBLE-1025: gaps are ordered oldest-closed-first and swept
/// through a persisted `(closed_at, id)` resume cursor (`.chump-locks/done_auditor_cursor.json`)
/// so each run examines a fresh window instead of re-auditing the same oldest
/// N gaps forever. When the cursor runs off the end of the list, the next run
/// wraps back to the top so coverage stays continuous over time.
pub fn audit(repo_root: &Path, limit: usize) -> Result<DoneAuditReport> {
    let store = chump_gap_store::GapStore::open(repo_root)?;
    let done = store.list_by_status_ordered("done")?;
    let cursor = read_cursor(repo_root);
    let cursor_ref = cursor.as_ref().map(|(at, id)| (*at, id.as_str()));
    let mut batch = select_window(&done, cursor_ref, limit);
    if batch.is_empty() && cursor.is_some() {
        // Ran off the end of the list — wrap around to the top.
        batch = select_window(&done, None, limit);
    }
    let mut report = DoneAuditReport::default();
    let mut last_seen: Option<(i64, String)> = None;
    for g in batch {
        last_seen = Some((g.closed_at.unwrap_or(i64::MIN), g.id.clone()));
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
    if let Some((at, id)) = last_seen {
        write_cursor(repo_root, at, &id);
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
    use chump_gap_store::GapRow;

    fn done_gap(id: &str, closed_at: i64) -> GapRow {
        GapRow {
            id: id.to_string(),
            domain: "CREDIBLE".to_string(),
            title: "t".to_string(),
            description: String::new(),
            priority: "P2".to_string(),
            effort: "s".to_string(),
            status: "done".to_string(),
            acceptance_criteria: "1. did the thing".to_string(),
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

    /// CREDIBLE-1025 AC2: two consecutive audit runs (mediated by the
    /// persisted `(closed_at, id)` cursor) examine disjoint sets of gaps —
    /// logs the IDs processed in each run and asserts no overlap.
    #[test]
    fn select_window_two_consecutive_runs_are_disjoint() {
        let gaps: Vec<GapRow> = (0..250)
            .map(|i| done_gap(&format!("CREDIBLE-{i:04}"), 1_000_000 + i as i64))
            .collect();

        // Run 1: no cursor yet — starts from the top.
        let run1 = select_window(&gaps, None, 100);
        let run1_ids: std::collections::HashSet<&str> =
            run1.iter().map(|g| g.id.as_str()).collect();
        assert_eq!(run1_ids.len(), 100);

        // Persist the cursor the way `audit` does: (closed_at, id) of the
        // last gap examined in run 1.
        let last = run1.last().unwrap();
        let cursor = (last.closed_at.unwrap(), last.id.as_str());

        // Run 2: resumes from the cursor.
        let run2 = select_window(&gaps, Some(cursor), 100);
        let run2_ids: std::collections::HashSet<&str> =
            run2.iter().map(|g| g.id.as_str()).collect();
        assert_eq!(run2_ids.len(), 100);

        assert!(
            run1_ids.is_disjoint(&run2_ids),
            "run1={run1_ids:?} run2={run2_ids:?} must not overlap"
        );

        // AC3: previously-unreachable gaps (indices 100..250, the "skipped"
        // 94.5%-style tail under the old always-take-first-N behavior) are
        // now reached by run 2.
        assert!(run2_ids.contains("CREDIBLE-0100"));
        assert!(!run1_ids.contains("CREDIBLE-0100"));
    }

    /// The cursor round-trips through disk exactly as `audit` uses it, and a
    /// cursor past the end of the list yields an empty window (the "wrap
    /// around" trigger in `audit`).
    #[test]
    fn cursor_round_trips_and_exhausts_at_end() {
        let dir = tempfile::TempDir::new().unwrap();
        assert!(read_cursor(dir.path()).is_none());

        write_cursor(dir.path(), 42, "CREDIBLE-0009");
        assert_eq!(
            read_cursor(dir.path()),
            Some((42, "CREDIBLE-0009".to_string()))
        );

        let gaps: Vec<GapRow> = (0..10)
            .map(|i| done_gap(&format!("CREDIBLE-{i:04}"), i as i64))
            .collect();
        let cursor = read_cursor(dir.path()).unwrap();
        let window = select_window(&gaps, Some((cursor.0, cursor.1.as_str())), 5);
        // closed_at=42 is past every synthetic gap's closed_at (0..10) — the
        // window is empty, which is what tells `audit` to wrap around.
        assert!(window.is_empty());
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
}
