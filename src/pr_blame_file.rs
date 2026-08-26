//! INFRA-1445: `chump pr blame-file <path>` — surfaces squash-merged +
//! cherry-picked history for a file that plain `git log -- <path>` misses.
//!
//! Motivating incident: `git log -- scripts/ci/test-cache-mergestatestatus.sh`
//! on `main` showed only INFRA-1368 (#2105) + an unrelated INFRA-1383
//! (#2130), but the file content on `main` was already the *fixed* version —
//! some other PR had squash-merged the fix without leaving a `git log --`
//! trail the operator could find (e.g. the fix line was folded into a squash
//! commit whose subject didn't mention the path). Cost: 5 min of confused
//! investigation and a wrong "the fix isn't on main" assumption.
//!
//! This command combines two sources:
//! 1. `git log --follow -- <path>` — direct commit history (may be sparse
//!    after a squash-merge rewrites history relative to the PR branch).
//! 2. `.chump/github_cache.db` `pr_state.raw_payload_json` — merged PRs
//!    whose cached payload lists the path in a `files` array, surfacing
//!    squash-merges `git log` alone doesn't attribute correctly.
//!
//! Rows are deduped by commit sha and sorted newest-first.

use serde::Serialize;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BlameRow {
    pub landed_commit: String,
    pub landed_pr: Option<u64>,
    pub landed_gap_id: Option<String>,
    pub landed_at: String,
    pub source: String, // git_log | github_cache
    pub subject: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BlameReport {
    pub path: String,
    pub rows: Vec<BlameRow>,
}

/// Direct `git log` history for the path. Pluggable for tests.
pub type GitLogProvider<'a> = Box<dyn Fn(&str) -> Vec<BlameRow> + 'a>;

/// Cache-sourced history for the path (squash-merges git log misses).
/// Pluggable for tests.
pub type CacheProvider<'a> = Box<dyn Fn(&str) -> Vec<BlameRow> + 'a>;

/// Build the combined blame report: git log rows + cache rows, deduped by
/// commit sha (git log wins on collision since it has ground-truth sha),
/// sorted newest-first by landed_at.
pub fn build_report(
    path: &str,
    git_log: &GitLogProvider<'_>,
    cache: &CacheProvider<'_>,
) -> BlameReport {
    let mut rows = git_log(path);
    let known_shas: std::collections::HashSet<String> =
        rows.iter().map(|r| r.landed_commit.clone()).collect();

    for row in cache(path) {
        if known_shas.contains(&row.landed_commit) {
            continue;
        }
        rows.push(row);
    }

    rows.sort_by(|a, b| b.landed_at.cmp(&a.landed_at));
    BlameReport {
        path: path.to_string(),
        rows,
    }
}

/// Default git-log provider — shells out to `git log --follow --format=...`.
pub fn git_log_provider(repo_root: &Path) -> GitLogProvider<'static> {
    let repo_root = repo_root.to_path_buf();
    Box::new(move |path: &str| -> Vec<BlameRow> {
        // %H=full sha  %aI=author date ISO  %s=subject
        let out = Command::new("git")
            .arg("-C")
            .arg(&repo_root)
            .args(["log", "--follow", "--format=%H%x1f%aI%x1f%s", "--", path])
            .output();
        let Ok(o) = out else {
            return Vec::new();
        };
        if !o.status.success() {
            return Vec::new();
        }
        let text = String::from_utf8_lossy(&o.stdout);
        text.lines()
            .filter_map(|line| {
                let mut parts = line.splitn(3, '\u{1f}');
                let sha = parts.next()?.to_string();
                let at = parts.next()?.to_string();
                let subject = parts.next().unwrap_or("").to_string();
                Some(BlameRow {
                    landed_pr: extract_pr_number(&subject),
                    landed_gap_id: extract_gap_id(&subject),
                    landed_at: at,
                    source: "git_log".to_string(),
                    subject,
                    landed_commit: sha,
                })
            })
            .collect()
    })
}

/// Default cache provider — reads `.chump/github_cache.db` `pr_state`
/// table for merged PRs whose `raw_payload_json.files[].filename` matches
/// the requested path. Read-only, no network call — mirrors the
/// INFRA-1081 cache-first discipline.
pub fn cache_provider(repo_root: &Path) -> CacheProvider<'static> {
    let db_path = repo_root.join(".chump").join("github_cache.db");
    Box::new(move |path: &str| -> Vec<BlameRow> {
        let Ok(conn) = rusqlite::Connection::open_with_flags(
            &db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        ) else {
            return Vec::new();
        };
        rows_from_conn(&conn, path)
    })
}

fn rows_from_conn(conn: &rusqlite::Connection, path: &str) -> Vec<BlameRow> {
    let mut stmt = match conn.prepare(
        "SELECT number, title, merged_at, raw_payload_json FROM pr_state \
         WHERE merged_at IS NOT NULL AND raw_payload_json IS NOT NULL",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let query = match stmt.query_map([], |row| {
        let number: i64 = row.get(0)?;
        let title: Option<String> = row.get(1)?;
        let merged_at: Option<String> = row.get(2)?;
        let raw: Option<String> = row.get(3)?;
        Ok((number, title, merged_at, raw))
    }) {
        Ok(q) => q,
        Err(_) => return Vec::new(),
    };

    let mut out = Vec::new();
    for r in query.flatten() {
        let (number, title, merged_at, raw) = r;
        let Some(raw) = raw else { continue };
        let Ok(payload) = serde_json::from_str::<serde_json::Value>(&raw) else {
            continue;
        };
        if !payload_touches_path(&payload, path) {
            continue;
        }
        let merge_sha = payload
            .get("merge_commit_sha")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let title = title.unwrap_or_default();
        out.push(BlameRow {
            landed_commit: merge_sha,
            landed_pr: Some(number as u64),
            landed_gap_id: extract_gap_id(&title),
            landed_at: merged_at.unwrap_or_default(),
            source: "github_cache".to_string(),
            subject: title,
        });
    }
    out
}

fn payload_touches_path(payload: &serde_json::Value, path: &str) -> bool {
    let Some(files) = payload.get("files").and_then(|v| v.as_array()) else {
        return false;
    };
    files.iter().any(|f| {
        f.get("filename")
            .and_then(|v| v.as_str())
            .map(|f| f == path)
            .unwrap_or(false)
    })
}

/// Squash-merge commit subjects end with `(#1234)`.
fn extract_pr_number(subject: &str) -> Option<u64> {
    let start = subject.rfind("(#")?;
    let rest = &subject[start + 2..];
    let end = rest.find(')')?;
    rest[..end].parse().ok()
}

/// Gap IDs look like `INFRA-1234`, `META-46`, `CREDIBLE-90`, etc. — an
/// uppercase-word prefix, a dash, then digits.
fn extract_gap_id(subject: &str) -> Option<String> {
    let bytes = subject.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i].is_ascii_uppercase() {
            let start = i;
            let mut j = i;
            while j < bytes.len() && (bytes[j].is_ascii_uppercase() || bytes[j] == b'_') {
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b'-' && j > start {
                let digit_start = j + 1;
                let mut k = digit_start;
                while k < bytes.len() && bytes[k].is_ascii_digit() {
                    k += 1;
                }
                if k > digit_start {
                    return Some(subject[start..k].to_string());
                }
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    None
}

pub fn render_text(r: &BlameReport) -> String {
    let mut s = String::new();
    s.push_str(&format!("=== chump pr blame-file {} ===\n", r.path));
    if r.rows.is_empty() {
        s.push_str("  no landed history found (git log + github cache both empty).\n");
        return s;
    }
    s.push_str(&format!(
        "  {:<10}  {:<8}  {:<12}  {:<24}  {}\n",
        "PR", "GAP", "COMMIT", "LANDED_AT", "SUBJECT"
    ));
    for row in &r.rows {
        let pr = row
            .landed_pr
            .map(|n| format!("#{n}"))
            .unwrap_or_else(|| "-".to_string());
        let gap = row.landed_gap_id.clone().unwrap_or_else(|| "-".to_string());
        let commit = if row.landed_commit.len() >= 8 {
            &row.landed_commit[..8]
        } else {
            &row.landed_commit
        };
        s.push_str(&format!(
            "  {:<10}  {:<8}  {:<12}  {:<24}  {}\n",
            pr, gap, commit, row.landed_at, row.subject
        ));
    }
    s
}

/// Run end-to-end with the default git + cache providers.
pub fn run(path: &str, repo_root: &Path, json_out: bool) -> anyhow::Result<()> {
    let git_log = git_log_provider(repo_root);
    let cache = cache_provider(repo_root);
    let report = build_report(path, &git_log, &cache);
    if json_out {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        print!("{}", render_text(&report));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn empty_git_log() -> GitLogProvider<'static> {
        Box::new(|_path: &str| Vec::new())
    }

    fn empty_cache() -> CacheProvider<'static> {
        Box::new(|_path: &str| Vec::new())
    }

    #[test]
    fn extracts_pr_number_from_squash_subject() {
        assert_eq!(
            extract_pr_number("INFRA-1368: fix mergeStateStatus test (#2105)"),
            Some(2105)
        );
        assert_eq!(extract_pr_number("no pr number here"), None);
    }

    #[test]
    fn extracts_gap_id_from_subject() {
        assert_eq!(
            extract_gap_id("INFRA-1368: fix mergeStateStatus test (#2105)"),
            Some("INFRA-1368".to_string())
        );
        assert_eq!(
            extract_gap_id("RESILIENT-408: close gap yaml (#4258)"),
            Some("RESILIENT-408".to_string())
        );
        assert_eq!(extract_gap_id("no gap id here"), None);
    }

    #[test]
    fn empty_sources_produce_empty_report() {
        let r = build_report("some/path.sh", &empty_git_log(), &empty_cache());
        assert!(r.rows.is_empty());
    }

    #[test]
    fn git_log_row_surfaces_directly() {
        let git_log: GitLogProvider<'static> = Box::new(|_path: &str| {
            vec![BlameRow {
                landed_commit: "abc123deadbeef".to_string(),
                landed_pr: Some(2105),
                landed_gap_id: Some("INFRA-1368".to_string()),
                landed_at: "2026-05-01T00:00:00Z".to_string(),
                source: "git_log".to_string(),
                subject: "INFRA-1368: fix (#2105)".to_string(),
            }]
        });
        let r = build_report("path.sh", &git_log, &empty_cache());
        assert_eq!(r.rows.len(), 1);
        assert_eq!(r.rows[0].landed_pr, Some(2105));
    }

    #[test]
    fn cache_row_surfaces_squash_merge_git_log_missed() {
        // Reproduces the motivating incident: git log is empty for this
        // path (squash-merge left no direct trail) but the cache's
        // raw_payload_json.files[] lists the path.
        let cache: CacheProvider<'static> = Box::new(|path: &str| {
            let payload = json!({
                "merge_commit_sha": "deadbeef00",
                "files": [{"filename": path}],
            });
            vec![BlameRow {
                landed_commit: payload["merge_commit_sha"].as_str().unwrap().to_string(),
                landed_pr: Some(2200),
                landed_gap_id: Some("INFRA-1445".to_string()),
                landed_at: "2026-08-20T00:00:00Z".to_string(),
                source: "github_cache".to_string(),
                subject: "INFRA-1445: fix cache mergeStateStatus test (#2200)".to_string(),
            }]
        });
        let r = build_report(
            "scripts/ci/test-cache-mergestatestatus.sh",
            &empty_git_log(),
            &cache,
        );
        assert_eq!(r.rows.len(), 1);
        assert_eq!(r.rows[0].source, "github_cache");
        assert_eq!(r.rows[0].landed_pr, Some(2200));
    }

    #[test]
    fn dedupes_by_commit_sha_preferring_git_log() {
        let git_log: GitLogProvider<'static> = Box::new(|_path: &str| {
            vec![BlameRow {
                landed_commit: "sameshaaaaa".to_string(),
                landed_pr: Some(1),
                landed_gap_id: None,
                landed_at: "2026-01-01T00:00:00Z".to_string(),
                source: "git_log".to_string(),
                subject: "from git log".to_string(),
            }]
        });
        let cache: CacheProvider<'static> = Box::new(|_path: &str| {
            vec![BlameRow {
                landed_commit: "sameshaaaaa".to_string(),
                landed_pr: Some(1),
                landed_gap_id: None,
                landed_at: "2026-01-01T00:00:00Z".to_string(),
                source: "github_cache".to_string(),
                subject: "from cache".to_string(),
            }]
        });
        let r = build_report("path.sh", &git_log, &cache);
        assert_eq!(r.rows.len(), 1);
        assert_eq!(r.rows[0].source, "git_log");
    }

    #[test]
    fn sorted_newest_first() {
        let git_log: GitLogProvider<'static> = Box::new(|_path: &str| {
            vec![
                BlameRow {
                    landed_commit: "old".to_string(),
                    landed_pr: None,
                    landed_gap_id: None,
                    landed_at: "2026-01-01T00:00:00Z".to_string(),
                    source: "git_log".to_string(),
                    subject: "old".to_string(),
                },
                BlameRow {
                    landed_commit: "new".to_string(),
                    landed_pr: None,
                    landed_gap_id: None,
                    landed_at: "2026-06-01T00:00:00Z".to_string(),
                    source: "git_log".to_string(),
                    subject: "new".to_string(),
                },
            ]
        });
        let r = build_report("path.sh", &git_log, &empty_cache());
        assert_eq!(r.rows[0].landed_commit, "new");
        assert_eq!(r.rows[1].landed_commit, "old");
    }

    #[test]
    fn render_text_includes_header_and_rows() {
        let git_log: GitLogProvider<'static> = Box::new(|_path: &str| {
            vec![BlameRow {
                landed_commit: "abc123deadbeef".to_string(),
                landed_pr: Some(2105),
                landed_gap_id: Some("INFRA-1368".to_string()),
                landed_at: "2026-05-01T00:00:00Z".to_string(),
                source: "git_log".to_string(),
                subject: "fix".to_string(),
            }]
        });
        let r = build_report("path.sh", &git_log, &empty_cache());
        let out = render_text(&r);
        assert!(out.contains("blame-file path.sh"));
        assert!(out.contains("#2105"));
        assert!(out.contains("INFRA-1368"));
    }

    #[test]
    fn cache_row_ignored_when_files_dont_match_path() {
        let cache: CacheProvider<'static> = Box::new(|_path: &str| {
            let conn = rusqlite::Connection::open_in_memory().unwrap();
            conn.execute_batch(
                "CREATE TABLE pr_state (number INTEGER, title TEXT, merged_at TEXT, raw_payload_json TEXT);
                 INSERT INTO pr_state VALUES (1, 'unrelated', '2026-01-01T00:00:00Z',
                    '{\"merge_commit_sha\":\"x\",\"files\":[{\"filename\":\"other/path.sh\"}]}');",
            )
            .unwrap();
            rows_from_conn(&conn, "target/path.sh")
        });
        let r = build_report("target/path.sh", &empty_git_log(), &cache);
        assert!(r.rows.is_empty());
    }

    #[test]
    fn rows_from_conn_matches_real_sqlite_schema() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE pr_state (number INTEGER PRIMARY KEY, title TEXT, merged_at TEXT, raw_payload_json TEXT);
             INSERT INTO pr_state VALUES (2200, 'INFRA-1445: fix cache mergeStateStatus test (#2200)',
                '2026-08-20T00:00:00Z',
                '{\"merge_commit_sha\":\"deadbeef00\",\"files\":[{\"filename\":\"scripts/ci/test-cache-mergestatestatus.sh\"}]}');
             INSERT INTO pr_state VALUES (2130, 'INFRA-1383: unrelated (#2130)',
                '2026-08-19T00:00:00Z',
                '{\"merge_commit_sha\":\"cafefeed\",\"files\":[{\"filename\":\"docs/other.md\"}]}');",
        )
        .unwrap();
        let rows = rows_from_conn(&conn, "scripts/ci/test-cache-mergestatestatus.sh");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].landed_pr, Some(2200));
        assert_eq!(rows[0].landed_commit, "deadbeef00");
        assert_eq!(rows[0].landed_gap_id, Some("INFRA-1445".to_string()));
    }
}
