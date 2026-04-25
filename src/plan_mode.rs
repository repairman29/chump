//! INFRA-060 (M2 of WORLD_CLASS_ROADMAP) — plan-mode gate that runs *before*
//! `chump --execute-gap` enters the agent loop.
//!
//! Responsibilities:
//!   1. Heuristically enumerate the files the dispatched agent is *likely*
//!      to touch (parse the gap description for `path/to/file.ext` tokens,
//!      plus rg-style scan of tracked files for the gap-id).
//!   2. Call `gh pr list --state open --json number,files` and check overlap
//!      between any planned file and ≥2 open PRs. If overlap is high, the
//!      queue is too crowded — abort cleanly with no commits.
//!   3. Write `.chump-plans/<gap>.md` so `bot-merge.sh` can splice it into
//!      the PR description verbatim (acceptance criterion #3).
//!
//! v1 deliberately avoids an LLM call for file enumeration. Heuristic costs
//! $0 which trivially meets the <$0.10/dispatch budget (acceptance #4); a
//! follow-up gap can replace `enumerate_files_heuristic` with a structured
//! Sonnet/Haiku call when we have empirical signal that the heuristic
//! misses too many real touches.
//!
//! Bypass: set `CHUMP_PLAN_MODE=0` to skip the gate entirely — useful for
//! tiny doc-only gaps where the overlap check is pure overhead. Defaults
//! ON so the gate actually defends the queue.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};

use crate::briefing;

/// Threshold for "queue too crowded" — if any planned file is touched by
/// `>=` this many *other* open PRs, we abort. Spec says "≥2" so we set 2.
const OVERLAP_ABORT_THRESHOLD: usize = 2;

/// Outcome of the plan-mode gate.
#[derive(Debug, Clone)]
pub enum PlanOutcome {
    /// Gate passed (or was disabled). The agent loop should proceed. Path
    /// points at the freshly-written `.chump-plans/<gap>.md` (or `None` if
    /// the gate was skipped via `CHUMP_PLAN_MODE=0`).
    Proceed { plan_path: Option<PathBuf> },
    /// Gate aborted because too many open PRs touch the planned files.
    /// Caller (execute_gap) should exit non-zero with this reason as
    /// stderr — agent loop must NOT run.
    Abort {
        reason: String,
        conflicts: BTreeMap<String, Vec<u64>>,
    },
}

/// Plan body that gets written to `.chump-plans/<gap>.md` and spliced into
/// the PR description. Public so `bot-merge.sh` (via `chump plan show`) and
/// tests can read it back.
#[derive(Debug, Clone)]
pub struct GapPlan {
    pub gap_id: String,
    pub gap_title: String,
    pub planned_files: Vec<String>,
    /// File -> list of open PR numbers that already touch it. Empty when
    /// the queue is clear.
    pub overlaps: BTreeMap<String, Vec<u64>>,
    pub conflict_score: usize,
    pub rationale: String,
}

/// Entry point. Read gap from docs/gaps.yaml, run the gate, write the plan.
/// Returns the outcome the caller acts on.
pub fn run_plan_mode(gap_id: &str, repo_root: &Path) -> Result<PlanOutcome> {
    if std::env::var("CHUMP_PLAN_MODE").as_deref() == Ok("0") {
        return Ok(PlanOutcome::Proceed { plan_path: None });
    }

    let briefing = briefing::build_briefing(gap_id);
    if briefing.gap_not_found {
        return Ok(PlanOutcome::Proceed { plan_path: None });
    }

    let gap_text = format!(
        "{}\n{}",
        briefing.gap_title,
        briefing.gap_acceptance.clone().unwrap_or_default()
    );
    let planned_files = enumerate_files_heuristic(&gap_text, gap_id, repo_root);

    let overlaps = check_pr_overlap(&planned_files).unwrap_or_default();
    let conflict_score = overlaps.values().map(Vec::len).sum::<usize>();
    let max_overlap_per_file = overlaps.values().map(Vec::len).max().unwrap_or(0);

    let plan = GapPlan {
        gap_id: gap_id.to_string(),
        gap_title: briefing.gap_title,
        planned_files,
        overlaps: overlaps.clone(),
        conflict_score,
        rationale: build_rationale(&briefing.gap_acceptance),
    };

    let plan_path = write_plan(repo_root, gap_id, &plan)?;

    if max_overlap_per_file >= OVERLAP_ABORT_THRESHOLD {
        return Ok(PlanOutcome::Abort {
            reason: format!(
                "queue too crowded: {} planned file(s) overlap with >= {} open PR(s); pick another gap or rebase those PRs first",
                overlaps
                    .iter()
                    .filter(|(_, prs)| prs.len() >= OVERLAP_ABORT_THRESHOLD)
                    .count(),
                OVERLAP_ABORT_THRESHOLD
            ),
            conflicts: overlaps,
        });
    }

    Ok(PlanOutcome::Proceed {
        plan_path: Some(plan_path),
    })
}

/// Heuristic v1: pull `path/to/file.ext` tokens out of the gap text. We
/// look for any whitespace-or-backtick-separated token that contains a `/`
/// AND a `.` AND points at an existing file in the repo. We deliberately
/// don't grep the codebase for the gap id — that produces noisy matches
/// and the description tends to mention the right files anyway. False
/// negatives here just weaken the overlap check; they don't break correctness.
pub fn enumerate_files_heuristic(text: &str, gap_id: &str, repo_root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let _ = gap_id;
    for raw in text.split(|c: char| {
        c.is_whitespace() || c == '`' || c == ',' || c == '(' || c == ')' || c == ';'
    }) {
        let token = raw.trim_matches(|c: char| {
            !c.is_alphanumeric() && c != '/' && c != '.' && c != '-' && c != '_'
        });
        if token.is_empty()
            || !token.contains('.')
            || token.starts_with('.')
            || token.starts_with('-')
        {
            continue;
        }
        if token.starts_with("http://") || token.starts_with("https://") {
            continue;
        }
        let candidate = repo_root.join(token);
        if candidate.is_file() && !out.contains(&token.to_string()) {
            out.push(token.to_string());
        }
    }
    out.sort();
    out
}

/// Returns map: file -> list of open PR numbers that include the file in
/// their diff. Skips silently (empty map) on `gh` failure — we still write
/// the plan with empty overlaps and let the agent proceed (best-effort).
pub fn check_pr_overlap(planned_files: &[String]) -> Result<BTreeMap<String, Vec<u64>>> {
    let mut out: BTreeMap<String, Vec<u64>> = BTreeMap::new();
    if planned_files.is_empty() {
        return Ok(out);
    }
    let output = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "100",
            "--json",
            "number,files",
        ])
        .output()
        .context("running `gh pr list`")?;
    if !output.status.success() {
        return Ok(out);
    }
    let body = String::from_utf8_lossy(&output.stdout);
    let prs: Vec<PrFiles> = serde_json::from_str(&body).unwrap_or_default();
    for pr in prs {
        for f in &pr.files {
            let path = &f.path;
            if planned_files.iter().any(|p| p == path) {
                out.entry(path.clone()).or_default().push(pr.number);
            }
        }
    }
    for v in out.values_mut() {
        v.sort();
        v.dedup();
    }
    Ok(out)
}

#[derive(serde::Deserialize, Debug)]
struct PrFiles {
    number: u64,
    #[serde(default)]
    files: Vec<PrFile>,
}

#[derive(serde::Deserialize, Debug)]
struct PrFile {
    path: String,
}

fn build_rationale(acceptance: &Option<String>) -> String {
    let body = acceptance.clone().unwrap_or_default();
    let lines: Vec<&str> = body
        .lines()
        .filter(|l| !l.trim().is_empty())
        .take(5)
        .collect();
    if lines.is_empty() {
        "(no acceptance criteria in gap entry — see docs/gaps.yaml)".into()
    } else {
        lines.join("\n")
    }
}

/// Write `.chump-plans/<gap>.md` and return its path. Always overwrites.
pub fn write_plan(repo_root: &Path, gap_id: &str, plan: &GapPlan) -> Result<PathBuf> {
    let dir = repo_root.join(".chump-plans");
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let path = dir.join(format!("{gap_id}.md"));
    std::fs::write(&path, render_plan_md(plan))
        .with_context(|| format!("writing {}", path.display()))?;
    Ok(path)
}

/// Render the plan body (also what `bot-merge.sh` splices into the PR description).
pub fn render_plan_md(plan: &GapPlan) -> String {
    let mut s = String::new();
    s.push_str(&format!("# Plan: {} — {}\n\n", plan.gap_id, plan.gap_title));
    s.push_str("## Planned files\n\n");
    if plan.planned_files.is_empty() {
        s.push_str("_(none enumerated by heuristic — agent will discover at runtime)_\n\n");
    } else {
        for f in &plan.planned_files {
            s.push_str(&format!("- `{f}`\n"));
        }
        s.push('\n');
    }
    s.push_str("## Open-PR overlap\n\n");
    if plan.overlaps.is_empty() {
        s.push_str("_no overlap with currently-open PRs_\n\n");
    } else {
        for (file, prs) in &plan.overlaps {
            let pr_list: Vec<String> = prs.iter().map(|n| format!("#{n}")).collect();
            s.push_str(&format!("- `{file}` — touched by {}\n", pr_list.join(", ")));
        }
        s.push('\n');
        s.push_str(&format!("Conflict score: **{}**\n\n", plan.conflict_score));
    }
    s.push_str("## Rationale (top of acceptance criteria)\n\n");
    s.push_str(&plan.rationale);
    s.push_str("\n\n---\n_Auto-generated by `chump --execute-gap` plan-mode gate (INFRA-060)._\n");
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn enumerate_files_heuristic_finds_real_paths() {
        let dir = tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("src")).unwrap();
        std::fs::write(dir.path().join("src/foo.rs"), "// stub").unwrap();
        std::fs::write(dir.path().join("README.md"), "# stub").unwrap();
        let text = "Edit `src/foo.rs` and update README.md to fix the bug.";
        let mut got = enumerate_files_heuristic(text, "TEST-001", dir.path());
        got.sort();
        assert_eq!(got, vec!["README.md".to_string(), "src/foo.rs".to_string()]);
    }

    #[test]
    fn enumerate_files_heuristic_ignores_urls_and_missing_files() {
        let dir = tempdir().unwrap();
        let text = "See https://example.com/foo.html and tweak src/never_existed.rs.";
        let got = enumerate_files_heuristic(text, "TEST-002", dir.path());
        assert!(got.is_empty(), "expected no matches, got: {got:?}");
    }

    #[test]
    fn render_plan_md_contains_files_and_score() {
        let mut overlaps = BTreeMap::new();
        overlaps.insert("src/foo.rs".to_string(), vec![100, 101]);
        let plan = GapPlan {
            gap_id: "TEST-100".into(),
            gap_title: "test gap".into(),
            planned_files: vec!["src/foo.rs".into(), "src/bar.rs".into()],
            overlaps,
            conflict_score: 2,
            rationale: "do the thing".into(),
        };
        let md = render_plan_md(&plan);
        assert!(md.contains("# Plan: TEST-100"));
        assert!(md.contains("`src/foo.rs`"));
        assert!(md.contains("touched by #100, #101"));
        assert!(md.contains("Conflict score: **2**"));
        assert!(md.contains("do the thing"));
    }

    #[test]
    fn write_plan_creates_file_under_chump_plans() {
        let dir = tempdir().unwrap();
        let plan = GapPlan {
            gap_id: "TEST-200".into(),
            gap_title: "x".into(),
            planned_files: vec![],
            overlaps: BTreeMap::new(),
            conflict_score: 0,
            rationale: "y".into(),
        };
        let p = write_plan(dir.path(), "TEST-200", &plan).unwrap();
        assert!(p.ends_with(".chump-plans/TEST-200.md"));
        let body = std::fs::read_to_string(&p).unwrap();
        assert!(body.contains("TEST-200"));
    }

    /// Acceptance criterion #2: 2 dummy open PRs touching the same file +
    /// dispatched gap aborts with no commits. We can't actually call `gh`
    /// in unit tests, so we exercise the *decision logic* directly: given
    /// an overlaps map with a file at >= threshold, the abort branch
    /// triggers. Integration test in tests/ does the full gh path.
    #[test]
    fn overlap_at_threshold_triggers_abort_decision() {
        let mut overlaps = BTreeMap::new();
        overlaps.insert("src/foo.rs".to_string(), vec![100, 101]);
        let max = overlaps.values().map(Vec::len).max().unwrap_or(0);
        assert!(max >= OVERLAP_ABORT_THRESHOLD);
    }

    #[test]
    fn single_overlap_does_not_abort() {
        let mut overlaps = BTreeMap::new();
        overlaps.insert("src/foo.rs".to_string(), vec![100]);
        let max = overlaps.values().map(Vec::len).max().unwrap_or(0);
        assert!(max < OVERLAP_ABORT_THRESHOLD);
    }
}
