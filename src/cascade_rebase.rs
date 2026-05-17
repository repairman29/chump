//! INFRA-1458: `chump pr cascade-rebase <check-name>`
//!
//! Lists every open PR with FAILURE conclusion on <check-name>,
//! then runs `gh pr update-branch --rebase` on each.
//!
//! Options:
//!   --dry-run          print action plan as JSON without executing
//!   --skip-conflict    continue past PRs that hit merge conflicts
//!   --exclude-labels   comma-sep list of labels to skip (default: do-not-paramedic)
//!   --json             output machine-readable JSON
//!
//! Testability:
//!   CHUMP_GH env var overrides the `gh` binary (for stub injection).
//!   CHUMP_AMBIENT_LOG env var overrides ambient.jsonl path.

use std::process::Command;
use std::time::{Duration, Instant};

// Per-PR update-branch budget (AC-5)
const PR_BUDGET_SECS: u64 = 30;

fn gh_cmd() -> String {
    std::env::var("CHUMP_GH").unwrap_or_else(|_| "gh".to_string())
}

fn ambient_log() -> Option<String> {
    std::env::var("CHUMP_AMBIENT_LOG")
        .ok()
        .filter(|s| !s.is_empty())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RebaseOutcome {
    Success,
    Conflict,
    Timeout,
    Error(String),
    Skipped { reason: String },
    DryRun,
}

#[derive(Debug, Clone)]
pub struct PrResult {
    pub number: u64,
    pub title: String,
    pub branch: String,
    pub outcome: RebaseOutcome,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone)]
pub struct CascadeReport {
    pub check_name: String,
    pub dry_run: bool,
    pub pr_results: Vec<PrResult>,
}

impl CascadeReport {
    pub fn success_count(&self) -> usize {
        self.pr_results
            .iter()
            .filter(|r| r.outcome == RebaseOutcome::Success)
            .count()
    }

    pub fn conflict_count(&self) -> usize {
        self.pr_results
            .iter()
            .filter(|r| r.outcome == RebaseOutcome::Conflict)
            .count()
    }

    pub fn skipped_count(&self) -> usize {
        self.pr_results
            .iter()
            .filter(|r| matches!(&r.outcome, RebaseOutcome::Skipped { .. }))
            .count()
    }

    pub fn error_count(&self) -> usize {
        self.pr_results
            .iter()
            .filter(|r| matches!(&r.outcome, RebaseOutcome::Error(_) | RebaseOutcome::Timeout))
            .count()
    }
}

pub struct CascadeOptions {
    pub check_name: String,
    pub dry_run: bool,
    pub skip_conflict: bool,
    pub exclude_labels: Vec<String>,
    pub json: bool,
    pub repo_root: std::path::PathBuf,
}

impl Default for CascadeOptions {
    fn default() -> Self {
        CascadeOptions {
            check_name: String::new(),
            dry_run: false,
            skip_conflict: false,
            exclude_labels: vec!["do-not-paramedic".to_string()],
            json: false,
            repo_root: std::path::PathBuf::from("."),
        }
    }
}

fn run_gh(args: &[&str]) -> Result<String, String> {
    let out = Command::new(gh_cmd())
        .args(args)
        .output()
        .map_err(|e| format!("gh not found: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "gh {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// List open PRs with their CI status rollup.
fn list_prs_with_checks() -> Result<Vec<serde_json::Value>, String> {
    let raw = run_gh(&[
        "pr",
        "list",
        "--state",
        "open",
        "--json",
        "number,title,headRefName,labels,statusCheckRollup",
        "--limit",
        "200",
    ])?;
    serde_json::from_str::<Vec<serde_json::Value>>(&raw).map_err(|e| format!("parse pr list: {e}"))
}

/// Returns true if the PR has a FAILURE conclusion for check_name.
fn pr_fails_check(pr: &serde_json::Value, check_name: &str) -> bool {
    let Some(arr) = pr.get("statusCheckRollup").and_then(|v| v.as_array()) else {
        return false;
    };
    arr.iter().any(|c| {
        let name = c.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let conclusion = c.get("conclusion").and_then(|v| v.as_str()).unwrap_or("");
        name.contains(check_name) && conclusion.eq_ignore_ascii_case("failure")
    })
}

/// Returns true if the PR has any of the exclude_labels.
fn pr_has_excluded_label(pr: &serde_json::Value, exclude_labels: &[String]) -> Option<String> {
    let Some(labels) = pr.get("labels").and_then(|v| v.as_array()) else {
        return None;
    };
    for label in labels {
        let name = label.get("name").and_then(|v| v.as_str()).unwrap_or("");
        for excl in exclude_labels {
            if name.eq_ignore_ascii_case(excl) {
                return Some(name.to_string());
            }
        }
    }
    None
}

/// Run `gh pr update-branch --rebase <number>` with a 30s budget.
/// Returns (outcome, elapsed_ms).
fn rebase_pr(number: u64) -> (RebaseOutcome, u64) {
    let t0 = Instant::now();
    let result = Command::new(gh_cmd())
        .args(["pr", "update-branch", "--rebase", &number.to_string()])
        .output();

    let elapsed = t0.elapsed();
    let elapsed_ms = elapsed.as_millis() as u64;

    // Check budget
    if elapsed >= Duration::from_secs(PR_BUDGET_SECS) {
        return (RebaseOutcome::Timeout, elapsed_ms);
    }

    match result {
        Err(e) => (
            RebaseOutcome::Error(format!("exec failed: {e}")),
            elapsed_ms,
        ),
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr).to_lowercase();
            let stdout = String::from_utf8_lossy(&out.stdout).to_lowercase();
            let combined = format!("{stderr}{stdout}");

            if out.status.success() {
                (RebaseOutcome::Success, elapsed_ms)
            } else if combined.contains("conflict")
                || combined.contains("merge conflict")
                || combined.contains("rebase conflict")
                || combined.contains("cannot rebase")
            {
                (RebaseOutcome::Conflict, elapsed_ms)
            } else {
                let msg = String::from_utf8_lossy(&out.stderr)
                    .trim()
                    .chars()
                    .take(200)
                    .collect::<String>();
                (RebaseOutcome::Error(msg), elapsed_ms)
            }
        }
    }
}

fn emit_ambient(repo_root: &std::path::Path, json: &str) {
    // Try CHUMP_AMBIENT_LOG env, then repo_root/.chump-locks/ambient.jsonl
    let path = ambient_log()
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| repo_root.join(".chump-locks").join("ambient.jsonl"));

    if let Some(parent) = path.parent() {
        if parent.exists() {
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
            {
                use std::io::Write;
                let _ = writeln!(f, "{json}");
            }
        }
    }
}

fn iso8601_now() -> String {
    let d = std::time::SystemTime::UNIX_EPOCH
        .elapsed()
        .unwrap_or_default();
    let secs = d.as_secs();
    let mins = secs / 60;
    let hrs = mins / 60;
    let days = hrs / 24;
    // Approximate date arithmetic (good enough for event timestamps)
    let _ = days; // not needed for ISO format via env
                  // Prefer using the `date` command for correctness
    std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| format!("{secs}"))
}

/// Run the cascade rebase.
pub fn run(opts: &CascadeOptions) -> Result<CascadeReport, String> {
    let all_prs = list_prs_with_checks()?;

    // Filter to PRs failing the target check (AC-1)
    let mut candidates: Vec<(u64, String, String)> = all_prs
        .iter()
        .filter(|pr| pr_fails_check(pr, &opts.check_name))
        .map(|pr| {
            let number = pr.get("number").and_then(|v| v.as_u64()).unwrap_or(0);
            let title = pr
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let branch = pr
                .get("headRefName")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            (number, title, branch)
        })
        .collect();

    // Dedupe by number, sort for determinism
    candidates.sort_by_key(|(n, _, _)| *n);
    candidates.dedup_by_key(|(n, _, _)| *n);

    let mut results = Vec::new();

    for (number, title, branch) in candidates {
        // Check excluded labels (AC-4)
        let pr_data = all_prs
            .iter()
            .find(|p| p.get("number").and_then(|v| v.as_u64()) == Some(number));
        if let Some(pr) = pr_data {
            if let Some(label) = pr_has_excluded_label(pr, &opts.exclude_labels) {
                results.push(PrResult {
                    number,
                    title,
                    branch,
                    outcome: RebaseOutcome::Skipped {
                        reason: format!("label:{label}"),
                    },
                    elapsed_ms: 0,
                });
                continue;
            }
        }

        if opts.dry_run {
            results.push(PrResult {
                number,
                title,
                branch,
                outcome: RebaseOutcome::DryRun,
                elapsed_ms: 0,
            });
            continue;
        }

        // Execute rebase (AC-1)
        let (outcome, elapsed_ms) = rebase_pr(number);

        // If conflict and !skip-conflict, stop iteration (AC-3)
        let is_conflict = outcome == RebaseOutcome::Conflict;
        results.push(PrResult {
            number,
            title,
            branch,
            outcome,
            elapsed_ms,
        });

        if is_conflict && !opts.skip_conflict {
            // Stop and report
            break;
        }
    }

    let report = CascadeReport {
        check_name: opts.check_name.clone(),
        dry_run: opts.dry_run,
        pr_results: results,
    };

    // Emit ambient event (AC-5)
    if !opts.dry_run {
        let ts = iso8601_now();
        let event = format!(
            r#"{{"ts":"{ts}","kind":"cascade_rebase_run","check":"{check}","pr_count":{pr_count},"success_count":{success},"conflict_count":{conflict},"skipped_count":{skipped},"error_count":{error},"dry_run":false}}"#,
            check = report.check_name.replace('"', "\\\""),
            pr_count = report.pr_results.len(),
            success = report.success_count(),
            conflict = report.conflict_count(),
            skipped = report.skipped_count(),
            error = report.error_count(),
        );
        emit_ambient(&opts.repo_root, &event);
    }

    Ok(report)
}

/// Render as plain text table.
pub fn render_text(report: &CascadeReport) -> String {
    let mut out = String::new();
    let mode = if report.dry_run { " [DRY-RUN]" } else { "" };
    out.push_str(&format!(
        "cascade-rebase: check='{}'{}\n",
        report.check_name, mode
    ));
    out.push_str(&format!(
        "  {} PRs matched | {} success | {} conflict | {} skipped | {} error\n\n",
        report.pr_results.len(),
        report.success_count(),
        report.conflict_count(),
        report.skipped_count(),
        report.error_count(),
    ));

    if report.pr_results.is_empty() {
        out.push_str("  (no open PRs failing this check)\n");
        return out;
    }

    out.push_str(&format!("  {:<6}  {:<12}  {}\n", "PR", "OUTCOME", "TITLE"));
    out.push_str(&format!("  {}\n", "-".repeat(70)));
    for r in &report.pr_results {
        let outcome_str = match &r.outcome {
            RebaseOutcome::Success => "success".to_string(),
            RebaseOutcome::Conflict => "conflict".to_string(),
            RebaseOutcome::Timeout => "timeout".to_string(),
            RebaseOutcome::Error(e) => format!("error:{}", &e[..e.len().min(30)]),
            RebaseOutcome::Skipped { reason } => format!("skipped({})", reason),
            RebaseOutcome::DryRun => "dry-run".to_string(),
        };
        let title_short: String = r.title.chars().take(45).collect();
        out.push_str(&format!(
            "  #{:<5}  {:<12}  {}\n",
            r.number, outcome_str, title_short
        ));
    }
    out
}

/// Render as JSON.
pub fn render_json(report: &CascadeReport) -> String {
    let prs_json: Vec<String> = report
        .pr_results
        .iter()
        .map(|r| {
            let outcome = match &r.outcome {
                RebaseOutcome::Success => "\"success\"".to_string(),
                RebaseOutcome::Conflict => "\"conflict\"".to_string(),
                RebaseOutcome::Timeout => "\"timeout\"".to_string(),
                RebaseOutcome::Error(e) => {
                    format!(
                        "\"error:{}\"",
                        e.replace('"', "\\\"").chars().take(100).collect::<String>()
                    )
                }
                RebaseOutcome::Skipped { reason } => {
                    format!("\"skipped:{}\"", reason.replace('"', "\\\""))
                }
                RebaseOutcome::DryRun => "\"dry-run\"".to_string(),
            };
            format!(
                r#"{{"number":{},"title":"{}","branch":"{}","outcome":{},"elapsed_ms":{}}}"#,
                r.number,
                r.title
                    .replace('"', "\\\"")
                    .chars()
                    .take(100)
                    .collect::<String>(),
                r.branch.replace('"', "\\\""),
                outcome,
                r.elapsed_ms,
            )
        })
        .collect();

    format!(
        r#"{{"check_name":"{}","dry_run":{},"pr_count":{},"success_count":{},"conflict_count":{},"skipped_count":{},"error_count":{},"prs":[{}]}}"#,
        report.check_name.replace('"', "\\\""),
        report.dry_run,
        report.pr_results.len(),
        report.success_count(),
        report.conflict_count(),
        report.skipped_count(),
        report.error_count(),
        prs_json.join(","),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_pr(number: u64, check: &str, conclusion: &str) -> serde_json::Value {
        serde_json::json!({
            "number": number,
            "title": format!("PR #{number}"),
            "headRefName": format!("branch-{number}"),
            "labels": [],
            "statusCheckRollup": [
                {"name": check, "conclusion": conclusion}
            ]
        })
    }

    #[test]
    fn test_pr_fails_check_match() {
        let pr = make_pr(1, "fast-checks", "FAILURE");
        assert!(pr_fails_check(&pr, "fast-checks"));
    }

    #[test]
    fn test_pr_fails_check_no_match() {
        let pr = make_pr(2, "fast-checks", "SUCCESS");
        assert!(!pr_fails_check(&pr, "fast-checks"));
    }

    #[test]
    fn test_pr_fails_check_partial_name() {
        // check_name is a substring matcher
        let pr = make_pr(3, "fast-checks-required", "FAILURE");
        assert!(pr_fails_check(&pr, "fast-checks"));
    }

    #[test]
    fn test_pr_has_excluded_label() {
        let pr = serde_json::json!({
            "number": 4,
            "title": "PR",
            "headRefName": "br",
            "labels": [{"name": "do-not-paramedic"}],
            "statusCheckRollup": []
        });
        let labels = vec!["do-not-paramedic".to_string()];
        assert!(pr_has_excluded_label(&pr, &labels).is_some());
    }

    #[test]
    fn test_pr_no_excluded_label() {
        let pr = serde_json::json!({
            "number": 5,
            "title": "PR",
            "headRefName": "br",
            "labels": [{"name": "safe-label"}],
            "statusCheckRollup": []
        });
        let labels = vec!["do-not-paramedic".to_string()];
        assert!(pr_has_excluded_label(&pr, &labels).is_none());
    }

    #[test]
    fn test_render_text_empty() {
        let report = CascadeReport {
            check_name: "mycheck".to_string(),
            dry_run: false,
            pr_results: vec![],
        };
        let text = render_text(&report);
        assert!(text.contains("mycheck"));
        assert!(text.contains("no open PRs"));
    }

    #[test]
    fn test_render_json_structure() {
        let report = CascadeReport {
            check_name: "mycheck".to_string(),
            dry_run: true,
            pr_results: vec![PrResult {
                number: 42,
                title: "Test PR".to_string(),
                branch: "test-branch".to_string(),
                outcome: RebaseOutcome::DryRun,
                elapsed_ms: 0,
            }],
        };
        let json = render_json(&report);
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        assert_eq!(parsed["check_name"], "mycheck");
        assert_eq!(parsed["dry_run"], true);
        assert_eq!(parsed["pr_count"], 1);
        assert!(parsed["prs"].is_array());
    }
}
