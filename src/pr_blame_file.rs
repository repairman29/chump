//! INFRA-1445: `chump pr blame-file <path>` — surfaces squash-merged +
//! cherry-picked history that plain `git log -- <path>` misses.
//!
//! `git log -- <path>` only shows commits git's own history walk can
//! attribute to the path. It misses landed fixes when a squash-merge's
//! net diff to a file isn't picked up by the walk from the operator's
//! current vantage point (shallow clones, force-pushed rebases,
//! cherry-picks that reproduce a diff under a different SHA). GitHub
//! itself always knows which merged PR's merge commit actually touched
//! a path — this combines both signals into one table.
//!
//! Two independent sources feed the report, merged and de-duplicated by
//! commit SHA:
//! 1. `git log` on the path (the baseline operators already know).
//! 2. `pr_state` rows in `.chump/github_cache.db` where `merged_at` is
//!    set — for each, extract `merge_commit_sha` from `raw_payload_json`
//!    and check (via the pluggable `touches_path` callback) whether that
//!    commit's diff actually touched the path. Real callers check this
//!    with `git diff-tree`; tests inject a fixture.

use anyhow::{Context, Result};
use regex::Regex;
use rusqlite::Connection;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashSet;
use std::path::Path;
use std::process::Command;

/// One row read from `pr_state` for a merged PR.
#[derive(Debug, Clone)]
pub struct MergedPrRow {
    pub number: u64,
    pub title: String,
    pub merged_at: Option<String>,
    pub raw_payload_json: Option<String>,
}

/// One row of the combined blame-file report.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BlameRow {
    pub landed_commit: String,
    pub landed_pr: Option<u64>,
    pub landed_gap_id: Option<String>,
    pub landed_at: Option<String>,
}

/// Extract a `GAP-1234`-shaped ID from a PR title (`feat(INFRA-1404): ...`
/// or `INFRA-1404: ...`). Mirrors the pattern used in
/// `src/revert_pr.rs::extract_gap_id`.
pub fn extract_gap_id(title: &str) -> Option<String> {
    let re = Regex::new(r"\b([A-Z]+-\d+)\b").ok()?;
    re.captures(title)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
}

/// Pull `merge_commit_sha` out of a cached webhook payload. Accepts both
/// the full webhook shape (`{"pull_request": {"merge_commit_sha": ...}}`)
/// and a flat PR-object shape (`{"merge_commit_sha": ...}`).
pub fn extract_merge_commit_sha(raw_payload_json: &str) -> Option<String> {
    let v: Value = serde_json::from_str(raw_payload_json).ok()?;
    v.get("pull_request")
        .and_then(|pr| pr.get("merge_commit_sha"))
        .or_else(|| v.get("merge_commit_sha"))
        .and_then(|s| s.as_str())
        .map(|s| s.to_string())
}

/// Combine `git log` rows (`(sha, date)`) with merged-PR rows into a
/// deduplicated, date-descending blame report. `touches_path` decides
/// whether a given commit SHA's diff actually touched the path in
/// question — real callers shell to `git diff-tree`, tests inject a
/// fixture closure.
pub fn build_report(
    git_log_rows: Vec<(String, String)>,
    merged_prs: Vec<MergedPrRow>,
    touches_path: impl Fn(&str) -> bool,
) -> Vec<BlameRow> {
    let mut rows: Vec<BlameRow> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    for (sha, date) in git_log_rows {
        if seen.insert(sha.clone()) {
            rows.push(BlameRow {
                landed_commit: sha,
                landed_pr: None,
                landed_gap_id: None,
                landed_at: Some(date),
            });
        }
    }

    for pr in merged_prs {
        let Some(sha) = pr
            .raw_payload_json
            .as_deref()
            .and_then(extract_merge_commit_sha)
        else {
            continue;
        };
        if !touches_path(&sha) {
            continue;
        }
        if let Some(existing) = rows.iter_mut().find(|r| r.landed_commit == sha) {
            existing.landed_pr = Some(pr.number);
            existing.landed_gap_id = extract_gap_id(&pr.title);
            if existing.landed_at.is_none() {
                existing.landed_at = pr.merged_at.clone();
            }
            continue;
        }
        if seen.insert(sha.clone()) {
            rows.push(BlameRow {
                landed_commit: sha,
                landed_pr: Some(pr.number),
                landed_gap_id: extract_gap_id(&pr.title),
                landed_at: pr.merged_at.clone(),
            });
        }
    }

    rows.sort_by(|a, b| b.landed_at.cmp(&a.landed_at));
    rows
}

/// Read all merged PRs (`merged_at IS NOT NULL`) from `.chump/github_cache.db`.
/// Missing/unreadable DB is not fatal — returns an empty Vec so the
/// report degrades to plain `git log` output.
pub fn read_merged_prs(db_path: &Path) -> Vec<MergedPrRow> {
    let conn =
        match Connection::open_with_flags(db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) {
            Ok(c) => c,
            Err(_) => return vec![],
        };
    let mut stmt = match conn.prepare(
        "SELECT number, title, merged_at, raw_payload_json FROM pr_state WHERE merged_at IS NOT NULL",
    ) {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    let rows = stmt.query_map([], |row| {
        Ok(MergedPrRow {
            number: row.get::<_, i64>(0)? as u64,
            title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
            merged_at: row.get(2)?,
            raw_payload_json: row.get(3)?,
        })
    });
    match rows {
        Ok(iter) => iter.filter_map(|r| r.ok()).collect(),
        Err(_) => vec![],
    }
}

/// `git log --format=%H%x1f%ad --date=iso-strict -- <path>` on the given
/// repo root. Empty Vec on any git error (e.g. path never existed).
pub fn git_log_for_path(repo_root: &Path, path: &str) -> Vec<(String, String)> {
    let out = Command::new("git")
        .args([
            "-C",
            repo_root.to_string_lossy().as_ref(),
            "log",
            "--format=%H%x1f%ad",
            "--date=iso-strict",
            "--",
            path,
        ])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter_map(|l| {
                let mut parts = l.splitn(2, '\u{1f}');
                let sha = parts.next()?.to_string();
                let date = parts.next()?.to_string();
                Some((sha, date))
            })
            .collect(),
        _ => vec![],
    }
}

/// Default `touches_path` implementation: `git diff-tree` the commit and
/// check whether the path shows up in its changed-file list.
pub fn commit_touches_path(repo_root: &Path, sha: &str, path: &str) -> bool {
    let out = Command::new("git")
        .args([
            "-C",
            repo_root.to_string_lossy().as_ref(),
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            sha,
            "--",
            path,
        ])
        .output();
    match out {
        Ok(o) => o.status.success() && !o.stdout.is_empty(),
        Err(_) => false,
    }
}

/// End-to-end: build the report for `path` against the repo at
/// `repo_root` and the cache DB at `db_path`.
pub fn run(repo_root: &Path, db_path: &Path, path: &str) -> Result<Vec<BlameRow>> {
    let git_log_rows = git_log_for_path(repo_root, path);
    let merged_prs = read_merged_prs(db_path);
    let repo_root = repo_root.to_path_buf();
    let path_owned = path.to_string();
    Ok(build_report(git_log_rows, merged_prs, move |sha| {
        commit_touches_path(&repo_root, sha, &path_owned)
    }))
}

/// Render as a plain-text table.
pub fn render_text(path: &str, rows: &[BlameRow]) -> String {
    let mut out = format!("chump pr blame-file {path}\n");
    if rows.is_empty() {
        out.push_str("(no landed history found)\n");
        return out;
    }
    out.push_str(&format!(
        "{:<10} {:<8} {:<12} {}\n",
        "COMMIT", "PR", "GAP", "LANDED_AT"
    ));
    for r in rows {
        out.push_str(&format!(
            "{:<10} {:<8} {:<12} {}\n",
            &r.landed_commit[..r.landed_commit.len().min(10)],
            r.landed_pr.map(|n| format!("#{n}")).unwrap_or_default(),
            r.landed_gap_id.clone().unwrap_or_default(),
            r.landed_at.clone().unwrap_or_default(),
        ));
    }
    out
}

/// Render as JSON.
pub fn render_json(path: &str, rows: &[BlameRow]) -> Result<String> {
    serde_json::to_string_pretty(&serde_json::json!({
        "path": path,
        "rows": rows,
    }))
    .context("serialize blame-file report")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_gap_id_from_conventional_title() {
        assert_eq!(
            extract_gap_id("INFRA-1368: stamp merge_state_status"),
            Some("INFRA-1368".to_string())
        );
        assert_eq!(
            extract_gap_id("fix(INFRA-1611): stamp opened_date"),
            Some("INFRA-1611".to_string())
        );
        assert_eq!(extract_gap_id("no gap id here"), None);
    }

    #[test]
    fn extract_merge_commit_sha_full_webhook_shape() {
        let payload = r#"{"pull_request":{"number":42,"merge_commit_sha":"abc123"}}"#;
        assert_eq!(
            extract_merge_commit_sha(payload),
            Some("abc123".to_string())
        );
    }

    #[test]
    fn extract_merge_commit_sha_flat_shape() {
        let payload = r#"{"number":42,"merge_commit_sha":"def456"}"#;
        assert_eq!(
            extract_merge_commit_sha(payload),
            Some("def456".to_string())
        );
    }

    #[test]
    fn extract_merge_commit_sha_missing_is_none() {
        assert_eq!(extract_merge_commit_sha(r#"{"number":42}"#), None);
    }

    #[test]
    fn build_report_surfaces_squash_merge_git_log_missed() {
        // git log only knows about one unrelated commit on the path.
        let git_log_rows = vec![("aaa111".to_string(), "2026-01-01T00:00:00Z".to_string())];
        // The cache knows about a merged PR whose merge commit ALSO
        // touched the path — this is the "git log missed it" case.
        let merged_prs = vec![MergedPrRow {
            number: 2130,
            title: "INFRA-1383: fix cache reconcile".to_string(),
            merged_at: Some("2026-02-02T00:00:00Z".to_string()),
            raw_payload_json: Some(r#"{"pull_request":{"merge_commit_sha":"bbb222"}}"#.to_string()),
        }];
        let rows = build_report(git_log_rows, merged_prs, |sha| sha == "bbb222");

        assert_eq!(rows.len(), 2);
        let squash_row = rows
            .iter()
            .find(|r| r.landed_commit == "bbb222")
            .expect("squash-merge row present");
        assert_eq!(squash_row.landed_pr, Some(2130));
        assert_eq!(squash_row.landed_gap_id, Some("INFRA-1383".to_string()));
        assert_eq!(
            squash_row.landed_at,
            Some("2026-02-02T00:00:00Z".to_string())
        );
    }

    #[test]
    fn build_report_skips_merged_pr_that_did_not_touch_path() {
        let merged_prs = vec![MergedPrRow {
            number: 99,
            title: "INFRA-1: unrelated".to_string(),
            merged_at: Some("2026-01-01T00:00:00Z".to_string()),
            raw_payload_json: Some(r#"{"pull_request":{"merge_commit_sha":"ccc333"}}"#.to_string()),
        }];
        let rows = build_report(vec![], merged_prs, |_sha| false);
        assert!(rows.is_empty());
    }

    #[test]
    fn build_report_enriches_git_log_row_when_same_commit_is_a_squash_merge() {
        let git_log_rows = vec![("shared1".to_string(), "2026-03-01T00:00:00Z".to_string())];
        let merged_prs = vec![MergedPrRow {
            number: 500,
            title: "INFRA-500: same commit".to_string(),
            merged_at: Some("2026-03-01T00:00:00Z".to_string()),
            raw_payload_json: Some(
                r#"{"pull_request":{"merge_commit_sha":"shared1"}}"#.to_string(),
            ),
        }];
        let rows = build_report(git_log_rows, merged_prs, |sha| sha == "shared1");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].landed_pr, Some(500));
        assert_eq!(rows[0].landed_gap_id, Some("INFRA-500".to_string()));
    }

    #[test]
    fn read_merged_prs_missing_db_returns_empty() {
        let rows = read_merged_prs(Path::new("/nonexistent/path/github_cache.db"));
        assert!(rows.is_empty());
    }
}
