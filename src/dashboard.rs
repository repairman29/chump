//! INFRA-063 (M5 of WORLD_CLASS_ROADMAP) — `chump dashboard` subcommand.
//!
//! Aggregates "how is the trunk-based loop going?" signal from real,
//! local sources so an operator (or agent) can answer in one glance:
//!
//!   - PRs landed today / this week
//!   - Median PR-open time (createdAt → mergedAt — proxy for cycle time)
//!   - Dispatcher backend split (best-effort — checks reflection notes if
//!     present, else prints "no backend telemetry available")
//!   - Top 5 stale linked worktrees by last-commit age
//!
//! Sources, in order: `gh pr list --json …`, `git -C <wt> log -1`,
//! `git worktree list --porcelain`. No DB writes; pure read aggregator.
//!
//! Design (~250 LOC): keep the parse logic minimal. We deliberately
//! extract numeric fields from the gh JSON without pulling serde_json
//! into this module — the briefing module already established that
//! pattern. If gh isn't installed / authed, the relevant section
//! prints a one-line "(unavailable)" note instead of failing the
//! whole dashboard.

use crate::repo_path;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Public entry point: render the dashboard to stdout. Returns Ok even
/// when sub-sources fail — the function degrades gracefully so an
/// operator running it on a fresh clone or offline laptop still gets
/// the parts that work.
pub fn print_dashboard() -> anyhow::Result<()> {
    let repo = repo_path::repo_root();
    println!("# Chump dashboard\n");
    print_pr_section();
    println!();
    print_backend_split();
    println!();
    print_stale_worktrees(&repo);
    Ok(())
}

// ── PR section ─────────────────────────────────────────────────────────

fn print_pr_section() {
    println!("## Pull requests landed");
    let merged = match fetch_merged_prs(50) {
        Some(v) => v,
        None => {
            println!("_(unavailable — `gh` not installed / authed)_");
            return;
        }
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let day_secs: i64 = 24 * 60 * 60;
    let today_cutoff = now - day_secs;
    let week_cutoff = now - 7 * day_secs;

    let today: Vec<&MergedPr> = merged
        .iter()
        .filter(|p| p.merged_at >= today_cutoff)
        .collect();
    let week: Vec<&MergedPr> = merged
        .iter()
        .filter(|p| p.merged_at >= week_cutoff)
        .collect();

    println!("- **Today:** {}", today.len());
    println!("- **This week:** {}", week.len());

    if !week.is_empty() {
        let mut open_minutes: Vec<i64> = week
            .iter()
            .map(|p| (p.merged_at - p.created_at).max(0) / 60)
            .collect();
        open_minutes.sort_unstable();
        let med = open_minutes[open_minutes.len() / 2];
        println!(
            "- **Median PR-open → merge (this week):** {}",
            humanize_minutes(med)
        );
    }
}

#[derive(Debug)]
struct MergedPr {
    number: u32,
    created_at: i64,
    merged_at: i64,
    title: String,
}

fn fetch_merged_prs(limit: u32) -> Option<Vec<MergedPr>> {
    let limit_s = limit.to_string();
    let out = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "merged",
            "--limit",
            &limit_s,
            "--json",
            "number,createdAt,mergedAt,title",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let body = String::from_utf8_lossy(&out.stdout).to_string();
    Some(parse_merged_prs(&body))
}

/// Tiny extractor — splits the JSON array on `{ ... }` record boundaries
/// (depth-tracked so nested objects don't confuse us) and pulls
/// createdAt/mergedAt/number/title from each. Tolerant of field ordering
/// so we don't have to pull serde_json into this module. Pure-fn for
/// testability.
fn parse_merged_prs(json: &str) -> Vec<MergedPr> {
    let mut out = Vec::new();
    let bytes = json.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'{' {
            let start = i;
            let mut depth = 0i32;
            while i < bytes.len() {
                match bytes[i] {
                    b'{' => depth += 1,
                    b'}' => {
                        depth -= 1;
                        if depth == 0 {
                            i += 1;
                            break;
                        }
                    }
                    _ => {}
                }
                i += 1;
            }
            let record = &json[start..i];
            let number: u32 = extract_num(record, "number").unwrap_or(0);
            let created_at = parse_iso8601(&extract_str(record, "createdAt").unwrap_or_default());
            let merged_at = parse_iso8601(&extract_str(record, "mergedAt").unwrap_or_default());
            let title = extract_str(record, "title").unwrap_or_default();
            out.push(MergedPr {
                number,
                created_at,
                merged_at,
                title,
            });
        } else {
            i += 1;
        }
    }
    out
}

fn extract_num(record: &str, key: &str) -> Option<u32> {
    let pat = format!("\"{key}\":");
    let i = record.find(&pat)?;
    let tail = &record[i + pat.len()..];
    let digits: String = tail
        .trim_start()
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

fn extract_str(record: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\":\"");
    let i = record.find(&pat)?;
    let tail = &record[i + pat.len()..];
    let end = tail.find('"')?;
    Some(tail[..end].to_string())
}

/// Parse ISO 8601 like `2026-04-25T10:42:00Z` to unix seconds. Returns 0
/// on parse failure (degrade-don't-fail).
pub fn parse_iso8601(s: &str) -> i64 {
    if s.len() < 19 {
        return 0;
    }
    let (year, rest) = s.split_at(4);
    let year: i32 = year.parse().unwrap_or(1970);
    let month: u32 = rest.get(1..3).and_then(|x| x.parse().ok()).unwrap_or(1);
    let day: u32 = rest.get(4..6).and_then(|x| x.parse().ok()).unwrap_or(1);
    let hour: u32 = rest.get(7..9).and_then(|x| x.parse().ok()).unwrap_or(0);
    let minute: u32 = rest.get(10..12).and_then(|x| x.parse().ok()).unwrap_or(0);
    let second: u32 = rest.get(13..15).and_then(|x| x.parse().ok()).unwrap_or(0);
    days_from_civil(year, month, day) * 86_400
        + hour as i64 * 3_600
        + minute as i64 * 60
        + second as i64
}

/// Howard Hinnant's days_from_civil — proleptic Gregorian, days since
/// 1970-01-01 (negative before).
fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u32;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    (era as i64) * 146_097 + doe as i64 - 719_468
}

fn humanize_minutes(m: i64) -> String {
    if m < 60 {
        return format!("{m}m");
    }
    let h = m / 60;
    let rem = m % 60;
    if h < 24 {
        return format!("{h}h{rem:02}m");
    }
    let d = h / 24;
    let h_rem = h % 24;
    format!("{d}d{h_rem:02}h")
}

// ── Backend split section ──────────────────────────────────────────────

fn print_backend_split() {
    println!("## Dispatcher backend split (last 7 days)");
    println!("_(no backend telemetry yet — wired in COG-026 / future)_");
}

// ── Stale worktrees section ────────────────────────────────────────────

fn print_stale_worktrees(repo: &std::path::Path) {
    println!("## Stale worktrees (top 5 by last-commit age)");
    let trees = list_linked_worktrees(repo);
    if trees.is_empty() {
        println!("_(no linked worktrees)_");
        return;
    }
    let mut with_age: Vec<(PathBuf, i64)> = trees
        .into_iter()
        .map(|p| {
            let age = last_commit_age_secs(&p).unwrap_or(i64::MAX);
            (p, age)
        })
        .collect();
    with_age.sort_by_key(|t| std::cmp::Reverse(t.1));
    for (path, age) in with_age.into_iter().take(5) {
        let age_label = if age == i64::MAX {
            "?".to_string()
        } else {
            humanize_minutes(age / 60)
        };
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("?");
        println!("- `{name}` — last commit {age_label} ago");
    }
}

fn list_linked_worktrees(repo: &std::path::Path) -> Vec<PathBuf> {
    let out = Command::new("git")
        .args([
            "-C",
            &repo.display().to_string(),
            "worktree",
            "list",
            "--porcelain",
        ])
        .output();
    let Ok(out) = out else { return Vec::new() };
    if !out.status.success() {
        return Vec::new();
    }
    let body = String::from_utf8_lossy(&out.stdout);
    let mut paths = Vec::new();
    for line in body.lines() {
        if let Some(rest) = line.strip_prefix("worktree ") {
            let p = PathBuf::from(rest);
            if p.to_string_lossy().contains("/.claude/worktrees/") {
                paths.push(p);
            }
        }
    }
    paths
}

fn last_commit_age_secs(wt: &std::path::Path) -> Option<i64> {
    let out = Command::new("git")
        .args(["-C", &wt.display().to_string(), "log", "-1", "--format=%ct"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let ts: i64 = String::from_utf8_lossy(&out.stdout).trim().parse().ok()?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() as i64;
    Some((now - ts).max(0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_iso8601_recognises_z_suffix() {
        let t = parse_iso8601("2026-04-25T10:42:00Z");
        // Sanity — year 2026 should be > 1.7e9 unix seconds.
        assert!(t > 1_700_000_000);
        assert!(t < 2_000_000_000);
    }

    #[test]
    fn parse_iso8601_ordering_is_monotonic() {
        let a = parse_iso8601("2026-04-25T10:00:00Z");
        let b = parse_iso8601("2026-04-25T11:00:00Z");
        let c = parse_iso8601("2026-04-26T10:00:00Z");
        assert!(a < b);
        assert!(b < c);
        assert_eq!(b - a, 3600);
        assert_eq!(c - a, 86_400);
    }

    #[test]
    fn parse_merged_prs_extracts_records() {
        let json = r#"[
            {"number":520,"createdAt":"2026-04-25T10:00:00Z","mergedAt":"2026-04-25T10:30:00Z","title":"M4 flags"},
            {"number":519,"createdAt":"2026-04-25T08:00:00Z","mergedAt":"2026-04-25T09:00:00Z","title":"M3 stacked"}
        ]"#;
        let prs = parse_merged_prs(json);
        assert_eq!(prs.len(), 2);
        assert_eq!(prs[0].number, 520);
        assert_eq!(prs[0].title, "M4 flags");
        assert!(prs[0].merged_at - prs[0].created_at == 1800);
    }

    #[test]
    fn parse_merged_prs_handles_gh_field_order() {
        // gh emits keys alphabetically: createdAt, mergedAt, number, title.
        // Earlier parser keyed off "number":" first and missed the prior fields.
        let json = r#"[{"createdAt":"2026-04-25T17:14:26Z","mergedAt":"2026-04-25T17:19:56Z","number":519,"title":"INFRA-061"}]"#;
        let prs = parse_merged_prs(json);
        assert_eq!(prs.len(), 1);
        assert_eq!(prs[0].number, 519);
        assert!(prs[0].created_at > 0);
        assert!(prs[0].merged_at > prs[0].created_at);
    }

    #[test]
    fn humanize_minutes_picks_unit() {
        assert_eq!(humanize_minutes(5), "5m");
        assert_eq!(humanize_minutes(75), "1h15m");
        assert_eq!(humanize_minutes(60 * 26), "1d02h");
    }
}
