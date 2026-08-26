//! INFRA-1445: `chump pr blame-file <path>` — surfaces squash-merged +
//! cherry-picked history for a file that `git log -- <path>` alone
//! misses.
//!
//! Motivating incident: `git log -- scripts/ci/test-cache-mergestatestatus.sh`
//! on `main` showed only two unrelated PRs, but the file content on
//! `main` was already the fixed version — some other PR had landed the
//! fix and `git log` gave no way to find which one. Cost: 5 min of
//! confused investigation + a wrong "the fix isn't on main" assumption.
//!
//! Approach: combine local `git log --follow` history on the path with
//! `.chump/github_cache.db` (`pr_state.raw_payload_json`) so merged PRs
//! the cache knows about — but whose commit a stale/shallow local
//! checkout hasn't fetched yet, or whose squash subject doesn't carry a
//! `(#NNN)` suffix — still surface. Cherry-pick trailers
//! (`cherry picked from commit <sha>`) are threaded through so a fix
//! that was cherry-picked onto another branch/PR is visible too.

use regex::Regex;
use rusqlite::Connection;
use serde::Serialize;
use std::path::Path;
use std::process::Command;

/// One row of `git log --follow -- <path>` history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitLogEntry {
    pub commit: String,
    pub subject: String,
    pub author_date: String,
    pub body: String,
}

/// One merged-PR row read out of `pr_state` in `github_cache.db`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CacheRow {
    pub number: u64,
    pub title: Option<String>,
    pub merged_at: Option<String>,
    pub raw_payload_json: Option<String>,
}

/// One line of `chump pr blame-file` output.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BlameRow {
    pub landed_commit: String,
    pub landed_pr: Option<u64>,
    pub landed_gap_id: Option<String>,
    pub landed_at: Option<String>,
    /// Set when this commit's message carries a
    /// `(cherry picked from commit <sha>)` trailer.
    pub cherry_picked_from: Option<String>,
    /// `git_log` (found via local `git log --follow -- path`) or
    /// `cache_only` (found only via github_cache.db cross-ref — local
    /// git history doesn't have/show the commit).
    pub source: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct BlameReport {
    pub path: String,
    pub rows: Vec<BlameRow>,
}

fn pr_number_from_subject(subject: &str) -> Option<u64> {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"\(#(\d+)\)\s*$").expect("valid regex"));
    re.captures(subject)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse().ok())
}

fn cherry_pick_source(body: &str) -> Option<String> {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(r"cherry picked from commit ([0-9a-fA-F]{7,40})").expect("valid regex")
    });
    re.captures(body)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
}

/// Best-effort gap-ID extraction (`INFRA-1234`, `RESILIENT-42`, ...)
/// from a PR title or body.
fn gap_id_from_text(text: &str) -> Option<String> {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"\b([A-Z][A-Z0-9]{2,}-\d+)\b").expect("valid regex"));
    re.captures(text).map(|c| c[1].to_string())
}

fn cache_row_for_pr(cache_rows: &[CacheRow], pr: u64) -> Option<&CacheRow> {
    cache_rows.iter().find(|r| r.number == pr)
}

fn gap_id_for_cache_row(row: &CacheRow) -> Option<String> {
    if let Some(title) = &row.title {
        if let Some(g) = gap_id_from_text(title) {
            return Some(g);
        }
    }
    if let Some(raw) = &row.raw_payload_json {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) {
            if let Some(body) = v.get("body").and_then(|b| b.as_str()) {
                if let Some(g) = gap_id_from_text(body) {
                    return Some(g);
                }
            }
        }
    }
    None
}

/// Does this cache row's `raw_payload_json` indicate the PR's patch
/// touched `path`? Real webhook payloads don't carry a file list, but
/// the fixture-fed test path (and any future receiver enrichment) may
/// stash one under a top-level `files` array — check for it.
fn cache_row_touches_path(row: &CacheRow, path: &str) -> bool {
    let Some(raw) = &row.raw_payload_json else {
        return false;
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) else {
        return false;
    };
    v.get("files")
        .and_then(|f| f.as_array())
        .map(|files| {
            files
                .iter()
                .any(|f| f.as_str().map(|s| s == path).unwrap_or(false))
        })
        .unwrap_or(false)
}

fn merge_commit_from_raw(row: &CacheRow) -> Option<String> {
    let raw = row.raw_payload_json.as_ref()?;
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    v.get("merge_commit_sha")
        .and_then(|s| s.as_str())
        .map(|s| s.to_string())
}

/// Pure builder — no I/O. Combines `git log --follow -- path` entries
/// with `pr_state` cache rows into the final blame report.
pub fn build_report(path: &str, git_log: &[GitLogEntry], cache_rows: &[CacheRow]) -> BlameReport {
    let mut rows: Vec<BlameRow> = Vec::new();
    let mut seen_prs: std::collections::HashSet<u64> = std::collections::HashSet::new();

    for entry in git_log {
        let pr = pr_number_from_subject(&entry.subject);
        let cherry_from = cherry_pick_source(&entry.body);

        let (gap_id, landed_at) = if let Some(pr_num) = pr {
            seen_prs.insert(pr_num);
            match cache_row_for_pr(cache_rows, pr_num) {
                Some(row) => (gap_id_for_cache_row(row), row.merged_at.clone()),
                None => (
                    gap_id_from_text(&entry.subject),
                    Some(entry.author_date.clone()),
                ),
            }
        } else {
            (
                gap_id_from_text(&entry.subject),
                Some(entry.author_date.clone()),
            )
        };

        rows.push(BlameRow {
            landed_commit: entry.commit.clone(),
            landed_pr: pr,
            landed_gap_id: gap_id,
            landed_at,
            cherry_picked_from: cherry_from,
            source: "git_log".to_string(),
        });
    }

    // Cache cross-ref: merged PRs the cache says touched `path` whose
    // number never showed up in the local git-log walk above — these
    // are the ones a stale/shallow checkout, or a squash subject with
    // no `(#NNN)` suffix, would make `git log` alone miss.
    for row in cache_rows {
        if seen_prs.contains(&row.number) {
            continue;
        }
        if !cache_row_touches_path(row, path) {
            continue;
        }
        rows.push(BlameRow {
            landed_commit: merge_commit_from_raw(row)
                .unwrap_or_else(|| "unknown (not in local git log)".to_string()),
            landed_pr: Some(row.number),
            landed_gap_id: gap_id_for_cache_row(row),
            landed_at: row.merged_at.clone(),
            cherry_picked_from: None,
            source: "cache_only".to_string(),
        });
    }

    BlameReport {
        path: path.to_string(),
        rows,
    }
}

pub fn render_text(report: &BlameReport) -> String {
    if report.rows.is_empty() {
        return format!(
            "chump pr blame-file: no landed history found for {}\n",
            report.path
        );
    }
    let mut out = format!(
        "{:<10} {:<8} {:<14} {:<22} {}\n",
        "COMMIT", "PR", "GAP_ID", "LANDED_AT", "SOURCE"
    );
    for row in &report.rows {
        out.push_str(&format!(
            "{:<10} {:<8} {:<14} {:<22} {}{}\n",
            &row.landed_commit[..row.landed_commit.len().min(10)],
            row.landed_pr.map(|p| format!("#{p}")).unwrap_or_default(),
            row.landed_gap_id.clone().unwrap_or_default(),
            row.landed_at.clone().unwrap_or_default(),
            row.source,
            row.cherry_picked_from
                .as_ref()
                .map(|s| format!(" (cherry-picked from {})", &s[..s.len().min(10)]))
                .unwrap_or_default(),
        ));
    }
    out
}

/// Runs `git log --follow --format=... -- <path>` in `repo_root` and
/// parses the records into [`GitLogEntry`] rows.
fn git_log_provider(repo_root: &Path, path: &str) -> Result<Vec<GitLogEntry>, String> {
    const FIELD_SEP: &str = "\x1f";
    const RECORD_SEP: &str = "\x1e";
    let format = format!("%H{FIELD_SEP}%s{FIELD_SEP}%aI{FIELD_SEP}%B{RECORD_SEP}");
    let out = Command::new("git")
        .current_dir(repo_root)
        .args(["log", "--follow", &format!("--format={format}"), "--", path])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "git log failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut entries = Vec::new();
    for record in stdout.split(RECORD_SEP) {
        let record = record.trim_start_matches('\n');
        if record.trim().is_empty() {
            continue;
        }
        let mut fields = record.splitn(4, FIELD_SEP);
        let commit = fields.next().unwrap_or("").to_string();
        let subject = fields.next().unwrap_or("").to_string();
        let author_date = fields.next().unwrap_or("").to_string();
        let body = fields.next().unwrap_or("").trim().to_string();
        if commit.is_empty() {
            continue;
        }
        entries.push(GitLogEntry {
            commit,
            subject,
            author_date,
            body,
        });
    }
    Ok(entries)
}

/// Reads all merged PR rows out of `.chump/github_cache.db`. Returns an
/// empty Vec (not an error) when the DB is absent — blame-file still
/// works off local `git log` alone in that case.
fn cache_rows_provider(repo_root: &Path) -> Vec<CacheRow> {
    let db_path = repo_root.join(".chump/github_cache.db");
    let Ok(conn) =
        Connection::open_with_flags(&db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
    else {
        return Vec::new();
    };
    query_cache_rows(&conn).unwrap_or_default()
}

fn query_cache_rows(conn: &Connection) -> Result<Vec<CacheRow>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT number, title, merged_at, raw_payload_json FROM pr_state WHERE merged_at IS NOT NULL",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(CacheRow {
            number: row.get(0)?,
            title: row.get(1)?,
            merged_at: row.get(2)?,
            raw_payload_json: row.get(3)?,
        })
    })?;
    rows.collect()
}

/// Entry point for `chump pr blame-file <path> [--json]`.
pub fn run(repo_root: &Path, path: &str, json_out: bool) -> Result<(), String> {
    let git_log = git_log_provider(repo_root, path)?;
    let cache_rows = cache_rows_provider(repo_root);
    let report = build_report(path, &git_log, &cache_rows);
    if json_out {
        println!(
            "{}",
            serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?
        );
    } else {
        print!("{}", render_text(&report));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(commit: &str, subject: &str, date: &str, body: &str) -> GitLogEntry {
        GitLogEntry {
            commit: commit.to_string(),
            subject: subject.to_string(),
            author_date: date.to_string(),
            body: body.to_string(),
        }
    }

    fn cache_row(number: u64, title: &str, merged_at: &str, raw: &str) -> CacheRow {
        CacheRow {
            number,
            title: Some(title.to_string()),
            merged_at: Some(merged_at.to_string()),
            raw_payload_json: Some(raw.to_string()),
        }
    }

    #[test]
    fn extracts_pr_and_gap_id_from_squash_commit_seen_in_git_log() {
        let git_log = vec![entry(
            "abc1234",
            "INFRA-1368: fix cache mergeStateStatus (#2105)",
            "2026-05-01T00:00:00Z",
            "INFRA-1368: fix cache mergeStateStatus (#2105)",
        )];
        let cache_rows = vec![cache_row(
            2105,
            "INFRA-1368: fix cache mergeStateStatus",
            "2026-05-01T00:05:00Z",
            r#"{"body":"Closes INFRA-1368"}"#,
        )];
        let report = build_report(
            "scripts/ci/test-cache-mergestatestatus.sh",
            &git_log,
            &cache_rows,
        );
        assert_eq!(report.rows.len(), 1);
        assert_eq!(report.rows[0].landed_pr, Some(2105));
        assert_eq!(report.rows[0].landed_gap_id.as_deref(), Some("INFRA-1368"));
        assert_eq!(
            report.rows[0].landed_at.as_deref(),
            Some("2026-05-01T00:05:00Z")
        );
        assert_eq!(report.rows[0].source, "git_log");
    }

    #[test]
    fn cache_only_squash_merge_that_git_log_misses_is_surfaced() {
        // git log on the path shows nothing relevant...
        let git_log: Vec<GitLogEntry> = vec![];
        // ...but the cache knows a PR merged whose patch touched the path
        // (this is the exact INFRA-1445 motivating scenario: the fix
        // landed via a PR not visible to a local `git log -- path`).
        let cache_rows = vec![CacheRow {
            number: 2130,
            title: Some("INFRA-1383: unrelated title, but the patch touched the file".to_string()),
            merged_at: Some("2026-05-03T12:00:00Z".to_string()),
            raw_payload_json: Some(
                r#"{"merge_commit_sha":"deadbeef","files":["scripts/ci/test-cache-mergestatestatus.sh"],"body":"Closes INFRA-1383"}"#
                    .to_string(),
            ),
        }];
        let report = build_report(
            "scripts/ci/test-cache-mergestatestatus.sh",
            &git_log,
            &cache_rows,
        );
        assert_eq!(report.rows.len(), 1);
        assert_eq!(report.rows[0].landed_pr, Some(2130));
        assert_eq!(report.rows[0].landed_commit, "deadbeef");
        assert_eq!(report.rows[0].landed_gap_id.as_deref(), Some("INFRA-1383"));
        assert_eq!(report.rows[0].source, "cache_only");
    }

    #[test]
    fn cache_row_not_touching_path_is_excluded() {
        let cache_rows = vec![CacheRow {
            number: 99,
            title: Some("unrelated PR".to_string()),
            merged_at: Some("2026-05-01T00:00:00Z".to_string()),
            raw_payload_json: Some(r#"{"files":["some/other/file.rs"]}"#.to_string()),
        }];
        let report = build_report(
            "scripts/ci/test-cache-mergestatestatus.sh",
            &[],
            &cache_rows,
        );
        assert!(report.rows.is_empty());
    }

    #[test]
    fn cherry_pick_trailer_is_surfaced() {
        let git_log = vec![entry(
            "cherry01",
            "INFRA-9999: backport fix (#3000)",
            "2026-05-10T00:00:00Z",
            "INFRA-9999: backport fix (#3000)\n\n(cherry picked from commit 0123456789abcdef0123456789abcdef01234567)",
        )];
        let report = build_report("some/path.sh", &git_log, &[]);
        assert_eq!(
            report.rows[0].cherry_picked_from.as_deref(),
            Some("0123456789abcdef0123456789abcdef01234567")
        );
    }

    #[test]
    fn render_text_handles_empty_report() {
        let report = build_report("no/history.sh", &[], &[]);
        let text = render_text(&report);
        assert!(text.contains("no landed history"));
    }

    #[test]
    fn query_cache_rows_reads_pr_state_table() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE pr_state (
                number INTEGER PRIMARY KEY,
                title TEXT,
                merged_at TEXT,
                raw_payload_json TEXT
            );
            INSERT INTO pr_state (number, title, merged_at, raw_payload_json)
            VALUES (2130, 'INFRA-1383: fix', '2026-05-03T12:00:00Z', '{\"files\":[\"a.sh\"]}');
            INSERT INTO pr_state (number, title, merged_at, raw_payload_json)
            VALUES (2200, 'still open', NULL, NULL);",
        )
        .unwrap();
        let rows = query_cache_rows(&conn).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].number, 2130);
    }
}
