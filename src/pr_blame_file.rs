//! INFRA-1445: `chump pr blame-file <path>` — surfaces squash-merged +
//! cherry-picked history that plain `git log -- <path>` misses.
//!
//! Motivating incident: `git log -- scripts/ci/test-cache-mergestatestatus.sh`
//! on chump/main showed only INFRA-1368 (#2105) + INFRA-1383 (#2130,
//! unrelated) — but the file content on main was already the FIXED
//! version. Some other PR had landed the fix and `git log` alone gave no
//! way to find which one. Cost: 5min of confused investigation plus the
//! wrong assumption that the fix wasn't on main.
//!
//! `git log` alone is blind to squash-merge commits whose PR body/diff
//! isn't reflected in the file's own commit trail (e.g. the file was
//! touched as a side-effect of a larger squash, or history was rewritten).
//! This command cross-references `.chump/github_cache.db`'s `pr_state`
//! table (`raw_payload_json`, populated by the webhook receiver) for
//! merged PRs whose file list touched the path, and merges that with the
//! plain git log so both sources are visible in one table.

use anyhow::Result;
use serde::Serialize;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct GitLogEntry {
    pub commit: String,
    pub date: String,
    pub subject: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CacheEntry {
    pub pr_number: u64,
    pub title: String,
    pub merged_at: String,
    pub head_sha: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BlameRow {
    pub landed_commit: String,
    pub landed_pr: Option<u64>,
    pub landed_gap_id: Option<String>,
    pub landed_at: String,
    pub source: String, // git_log | github_pr_cache
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BlameReport {
    pub path: String,
    pub rows: Vec<BlameRow>,
}

/// Matches a GH squash-merge commit subject suffix like `(#1234)`.
fn extract_pr_number(subject: &str) -> Option<u64> {
    let start = subject.rfind("(#")?;
    let rest = &subject[start + 2..];
    let end = rest.find(')')?;
    rest[..end].parse::<u64>().ok()
}

/// Matches a gap id like `INFRA-1445`, `RESILIENT-409`, `META-046` anywhere
/// in the text (title or commit subject).
fn extract_gap_id(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_uppercase() {
            let start = i;
            let mut j = i + 1;
            while j < bytes.len() && (bytes[j].is_ascii_uppercase() || bytes[j] == b'_') {
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b'-' && j > start {
                let mut k = j + 1;
                let digit_start = k;
                while k < bytes.len() && bytes[k].is_ascii_digit() {
                    k += 1;
                }
                if k > digit_start {
                    return Some(text[start..k].to_string());
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    None
}

/// Pure combine step: merge git-log-visible commits with cache-surfaced
/// squash-merged PRs that touched the path but may not show up (or show
/// up unattributed) in the plain git log.
pub fn build_report(path: &str, git_log: Vec<GitLogEntry>, cache: Vec<CacheEntry>) -> BlameReport {
    let mut rows: Vec<BlameRow> = Vec::new();

    for entry in &git_log {
        let landed_pr = extract_pr_number(&entry.subject);
        let landed_gap_id = extract_gap_id(&entry.subject);
        rows.push(BlameRow {
            landed_commit: entry.commit.clone(),
            landed_pr,
            landed_gap_id,
            landed_at: entry.date.clone(),
            source: "git_log".to_string(),
        });
    }

    let known_prs: std::collections::HashSet<u64> =
        rows.iter().filter_map(|r| r.landed_pr).collect();

    for c in &cache {
        if known_prs.contains(&c.pr_number) {
            continue; // already surfaced via git log
        }
        rows.push(BlameRow {
            landed_commit: c.head_sha.clone(),
            landed_pr: Some(c.pr_number),
            landed_gap_id: extract_gap_id(&c.title),
            landed_at: c.merged_at.clone(),
            source: "github_pr_cache".to_string(),
        });
    }

    rows.sort_by(|a, b| b.landed_at.cmp(&a.landed_at));

    BlameReport {
        path: path.to_string(),
        rows,
    }
}

/// Default git log provider — `git log --format=... -- <path>` in `repo_root`.
fn git_log_provider(repo_root: &Path, path: &str) -> Vec<GitLogEntry> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args([
            "log",
            "--date=iso-strict",
            "--format=%H%x1f%ad%x1f%s",
            "--",
            path,
        ])
        .output();
    let Ok(o) = out else {
        return Vec::new();
    };
    if !o.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&o.stdout)
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(3, '\u{1f}');
            let commit = parts.next()?.to_string();
            let date = parts.next()?.to_string();
            let subject = parts.next().unwrap_or("").to_string();
            Some(GitLogEntry {
                commit,
                date,
                subject,
            })
        })
        .collect()
}

/// Default cache provider — reads merged PRs from `.chump/github_cache.db`
/// (`pr_state.raw_payload_json`) and keeps rows whose `files[].filename`
/// list contains `path`.
fn cache_provider(repo_root: &Path, path: &str) -> Vec<CacheEntry> {
    cache_provider_from_db(&repo_root.join(".chump").join("github_cache.db"), path)
}

fn cache_provider_from_db(db: &Path, path: &str) -> Vec<CacheEntry> {
    if !db.exists() {
        return Vec::new();
    }
    // \x1f (unit separator) field delimiter to survive titles with commas/tabs.
    let out = Command::new("sqlite3")
        .arg("-separator")
        .arg("\u{1f}")
        .arg(db)
        .arg(
            "SELECT number, title, merged_at, head_sha, raw_payload_json FROM pr_state \
             WHERE merged_at IS NOT NULL",
        )
        .output();
    let Ok(o) = out else {
        return Vec::new();
    };
    if !o.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&o.stdout)
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(5, '\u{1f}');
            let number: u64 = parts.next()?.parse().ok()?;
            let title = parts.next()?.to_string();
            let merged_at = parts.next()?.to_string();
            let head_sha = parts.next().unwrap_or("").to_string();
            let raw_payload_json = parts.next().unwrap_or("");
            if !payload_touches_path(raw_payload_json, path) {
                return None;
            }
            Some(CacheEntry {
                pr_number: number,
                title,
                merged_at,
                head_sha,
            })
        })
        .collect()
}

/// True if `raw_payload_json` has a `files` array (`[{"filename": "..."}]`
/// or a plain array of path strings) that contains `path`.
fn payload_touches_path(raw_payload_json: &str, path: &str) -> bool {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(raw_payload_json) else {
        return false;
    };
    let Some(files) = v.get("files").and_then(|f| f.as_array()) else {
        return false;
    };
    files.iter().any(|f| {
        let name = f
            .get("filename")
            .and_then(|n| n.as_str())
            .or_else(|| f.as_str());
        name == Some(path)
    })
}

/// Run end-to-end with the default git-log + cache providers.
pub fn run(path: &str, json_out: bool) -> Result<()> {
    let repo_root = crate::repo_path::repo_root();
    let git_log = git_log_provider(&repo_root, path);
    let cache = cache_provider(&repo_root, path);
    let report = build_report(path, git_log, cache);
    if json_out {
        println!("{}", serde_json::to_string_pretty(&report).unwrap());
    } else {
        print!("{}", render_text(&report));
    }
    Ok(())
}

pub fn render_text(r: &BlameReport) -> String {
    let mut s = String::new();
    s.push_str(&format!("=== chump pr blame-file {} ===\n", r.path));
    if r.rows.is_empty() {
        s.push_str("  no landed history found (git log empty and no cache hit).\n");
        return s;
    }
    s.push_str(&format!(
        "  {:<12} {:<9} {:<16} {:<22} source\n",
        "commit", "pr", "gap_id", "landed_at"
    ));
    for row in &r.rows {
        let short_commit = &row.landed_commit[..row.landed_commit.len().min(12)];
        let pr = row
            .landed_pr
            .map(|n| format!("#{n}"))
            .unwrap_or_else(|| "-".to_string());
        let gap = row.landed_gap_id.clone().unwrap_or_else(|| "-".to_string());
        s.push_str(&format!(
            "  {:<12} {:<9} {:<16} {:<22} {}\n",
            short_commit, pr, gap, row.landed_at, row.source
        ));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_pr_number_from_squash_subject() {
        assert_eq!(
            extract_pr_number("INFRA-1368: fix mergestatestatus cache (#2105)"),
            Some(2105)
        );
        assert_eq!(extract_pr_number("no pr ref here"), None);
    }

    #[test]
    fn extract_gap_id_from_text() {
        assert_eq!(
            extract_gap_id("INFRA-1368: fix mergestatestatus cache (#2105)"),
            Some("INFRA-1368".to_string())
        );
        assert_eq!(
            extract_gap_id("RESILIENT-409: close gap yaml"),
            Some("RESILIENT-409".to_string())
        );
        assert_eq!(extract_gap_id("no gap ref here"), None);
    }

    #[test]
    fn git_log_only_no_cache_hits() {
        let git_log = vec![GitLogEntry {
            commit: "abc123".to_string(),
            date: "2026-08-01T00:00:00Z".to_string(),
            subject: "INFRA-1368: fix cache (#2105)".to_string(),
        }];
        let r = build_report("scripts/ci/test-x.sh", git_log, Vec::new());
        assert_eq!(r.rows.len(), 1);
        assert_eq!(r.rows[0].landed_pr, Some(2105));
        assert_eq!(r.rows[0].source, "git_log");
    }

    #[test]
    fn cache_surfaces_pr_missing_from_git_log() {
        // This is the INFRA-1445 motivating scenario: git log shows only
        // an unrelated PR, but a squash-merged PR (not attributed by git
        // log's file-history walk) actually landed the fix.
        let git_log = vec![GitLogEntry {
            commit: "aaa111".to_string(),
            date: "2026-05-01T00:00:00Z".to_string(),
            subject: "INFRA-1383: unrelated (#2130)".to_string(),
        }];
        let cache = vec![CacheEntry {
            pr_number: 2201,
            title: "INFRA-1400: actually fix mergestatestatus".to_string(),
            merged_at: "2026-06-01T00:00:00Z".to_string(),
            head_sha: "bbb222".to_string(),
        }];
        let r = build_report("scripts/ci/test-cache-mergestatestatus.sh", git_log, cache);
        assert_eq!(r.rows.len(), 2);
        let cache_row = r
            .rows
            .iter()
            .find(|row| row.source == "github_pr_cache")
            .expect("cache row present");
        assert_eq!(cache_row.landed_pr, Some(2201));
        assert_eq!(cache_row.landed_gap_id, Some("INFRA-1400".to_string()));
        // Sorted newest-first.
        assert_eq!(r.rows[0].landed_pr, Some(2201));
    }

    #[test]
    fn cache_dedupes_pr_already_seen_in_git_log() {
        let git_log = vec![GitLogEntry {
            commit: "abc123".to_string(),
            date: "2026-08-01T00:00:00Z".to_string(),
            subject: "INFRA-1368: fix cache (#2105)".to_string(),
        }];
        let cache = vec![CacheEntry {
            pr_number: 2105,
            title: "INFRA-1368: fix cache".to_string(),
            merged_at: "2026-08-01T00:00:00Z".to_string(),
            head_sha: "abc123".to_string(),
        }];
        let r = build_report("scripts/ci/test-x.sh", git_log, cache);
        assert_eq!(r.rows.len(), 1);
    }

    #[test]
    fn payload_touches_path_matches_filename_object_shape() {
        let payload = r#"{"files":[{"filename":"scripts/ci/test-x.sh"},{"filename":"other.rs"}]}"#;
        assert!(payload_touches_path(payload, "scripts/ci/test-x.sh"));
        assert!(!payload_touches_path(payload, "not-present.sh"));
    }

    #[test]
    fn payload_touches_path_handles_missing_files_key() {
        let payload = r#"{"number": 5}"#;
        assert!(!payload_touches_path(payload, "scripts/ci/test-x.sh"));
    }

    #[test]
    fn render_text_includes_header_and_rows() {
        let git_log = vec![GitLogEntry {
            commit: "abc123def456".to_string(),
            date: "2026-08-01T00:00:00Z".to_string(),
            subject: "INFRA-1368: fix cache (#2105)".to_string(),
        }];
        let r = build_report("scripts/ci/test-x.sh", git_log, Vec::new());
        let out = render_text(&r);
        assert!(out.contains("blame-file scripts/ci/test-x.sh"));
        assert!(out.contains("#2105"));
        assert!(out.contains("INFRA-1368"));
        assert!(out.contains("git_log"));
    }

    #[test]
    fn empty_report_renders_no_history_message() {
        let r = build_report("scripts/ci/test-x.sh", Vec::new(), Vec::new());
        let out = render_text(&r);
        assert!(out.contains("no landed history found"));
    }
}
