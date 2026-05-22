//! INFRA-1416: `chump pr explain-block <PR>` — single coherent explanation
//! for a stuck PR. Replaces the ~6× manual `gh pr view ... statusCheckRollup`
//! digging observed 2026-05-22.
//!
//! Output shape:
//! - For each failing/queued check: test name + failure class + whether
//!   the failure is local to this PR or fleet-wide (cross-ref open PRs
//!   failing the same check).
//! - Next mechanical action per row.
//! - Top-level summary tag (LOCAL / SIBLING_BLOCKED / FLEET_WIDE).
//!
//! Cross-fleet signal: when ≥3 open PRs fail the same check, surface
//! that as "fleet-wide block" instead of nagging each PR's author into
//! local debugging.

use anyhow::{anyhow, Result};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;

const FLEET_WIDE_THRESHOLD: usize = 3;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CheckRow {
    pub name: String,
    pub conclusion: String, // FAILURE | CANCELLED | TIMED_OUT | PENDING | SUCCESS | …
    pub status: String,     // QUEUED | IN_PROGRESS | COMPLETED
    pub scope: String,      // local | sibling_blocked | fleet_wide
    pub also_failing_prs: Vec<u64>,
    pub next_action: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ExplainReport {
    pub pr_number: u64,
    pub overall: String, // local | sibling_blocked | fleet_wide | green
    pub rows: Vec<CheckRow>,
    pub summary: String,
}

/// Pluggable provider: for a given PR number, return its status-check
/// rollup as the raw JSON array shape that `gh pr view --json
/// statusCheckRollup` emits. Default ([`gh_rollup_provider`]) shells
/// out; tests inject fixtures.
pub type RollupProvider<'a> = Box<dyn Fn(u64) -> Vec<Value> + 'a>;

/// Pluggable provider: for a given check name, return the list of OTHER
/// open PR numbers whose latest run on that check failed. Used for the
/// fleet-wide cross-ref. Default ([`gh_fleet_failing_provider`]) shells
/// out to `gh pr list --json …`; tests inject fixtures.
pub type FleetFailingProvider<'a> = Box<dyn Fn(&str) -> Vec<u64> + 'a>;

/// Build the explanation report.
pub fn build_report(
    pr_number: u64,
    rollup: Vec<Value>,
    fleet_failing: &FleetFailingProvider<'_>,
) -> ExplainReport {
    let mut rows: Vec<CheckRow> = Vec::new();
    let mut worst_scope: Option<String> = None;

    for entry in &rollup {
        let name = entry
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("?")
            .to_string();
        let conclusion = entry
            .get("conclusion")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let status = entry
            .get("status")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // Skip green / skipping rows — they don't block.
        if matches!(conclusion.as_str(), "SUCCESS" | "NEUTRAL" | "SKIPPED") {
            continue;
        }
        if conclusion.is_empty() && status == "COMPLETED" {
            continue; // unknown but completed; not a blocker
        }
        // Failure or in-progress — investigate cross-fleet.
        let others = fleet_failing(&name);
        let (scope, action) = classify_and_advise(&name, &conclusion, &status, pr_number, &others);
        update_worst_scope(&mut worst_scope, &scope);
        rows.push(CheckRow {
            name,
            conclusion,
            status,
            scope,
            also_failing_prs: others,
            next_action: action,
        });
    }

    let overall = worst_scope.unwrap_or_else(|| "green".to_string());
    let summary = match overall.as_str() {
        "fleet_wide" => {
            "this PR is blocked by a fleet-wide failure — wait for the keystone fix or file P0"
                .to_string()
        }
        "sibling_blocked" => "this PR is waiting on a sibling-PR fix already in flight".to_string(),
        "local" => "this PR has local failures — fix in worktree and push".to_string(),
        _ => "all checks green or in progress — no mechanical action needed".to_string(),
    };

    ExplainReport {
        pr_number,
        overall,
        rows,
        summary,
    }
}

fn update_worst_scope(current: &mut Option<String>, candidate: &str) {
    // Severity order: fleet_wide > sibling_blocked > local > green
    let rank = |s: &str| match s {
        "fleet_wide" => 3,
        "sibling_blocked" => 2,
        "local" => 1,
        _ => 0,
    };
    let cur_rank = current.as_deref().map(rank).unwrap_or(0);
    if rank(candidate) > cur_rank {
        *current = Some(candidate.to_string());
    }
}

fn classify_and_advise(
    name: &str,
    conclusion: &str,
    status: &str,
    self_pr: u64,
    others: &[u64],
) -> (String, String) {
    let pending = matches!(status, "QUEUED" | "IN_PROGRESS");
    if pending {
        return (
            "local".to_string(),
            "pending — let CI finish before debugging".to_string(),
        );
    }
    let others_count = others.iter().filter(|&&n| n != self_pr).count();
    if others_count >= FLEET_WIDE_THRESHOLD {
        let action = format!(
            "fleet-wide failure on '{name}' ({others_count} other PRs also red) — wait for keystone fix or file P0; see kind=ci_failure_cluster ambient events"
        );
        return ("fleet_wide".to_string(), action);
    }
    if others_count >= 1 {
        let preview: Vec<String> = others.iter().take(3).map(|n| format!("#{n}")).collect();
        let action = format!(
            "sibling PRs also failing '{name}': {} — likely shared root cause; rebase against main after the first one merges",
            preview.join(", ")
        );
        return ("sibling_blocked".to_string(), action);
    }
    // Local-only failure — give a class hint based on the check name.
    let action = local_action_hint(name, conclusion);
    ("local".to_string(), action)
}

fn local_action_hint(name: &str, conclusion: &str) -> String {
    let lower = name.to_lowercase();
    if lower.contains("clippy") {
        return "fix locally: cargo clippy --workspace --all-targets -- -D warnings, then push"
            .to_string();
    }
    if lower.contains("fmt") {
        return "fix locally: cargo fmt --all, then push".to_string();
    }
    if lower.contains("audit") || lower.contains("env-var") || lower.contains("allowlist") {
        return "audit/allowlist drift — likely a 1-line fix in scripts/ci/event-registry-reserved.txt or scripts/ci/env-vars-internal.txt".to_string();
    }
    if lower.contains("test") || lower.contains("cargo-test") {
        return format!(
            "cargo test failed locally on '{name}' — re-run the failing test, fix, push"
        );
    }
    if lower.contains("rebase") || lower.contains("update-branch") {
        return "behind main — run `gh pr update-branch --rebase <PR>` or wait for INFRA-1429 paramedic".to_string();
    }
    if conclusion == "CANCELLED" {
        return "cancelled — likely cascade-cancel from a sibling shard failing; re-run after that lands".to_string();
    }
    format!("{conclusion} on '{name}' — inspect the run log: gh run view --log-failed")
}

/// Default rollup provider — shells out to `gh pr view --json statusCheckRollup`.
pub fn gh_rollup_provider() -> RollupProvider<'static> {
    Box::new(|pr: u64| -> Vec<Value> {
        let out = std::process::Command::new("gh")
            .args(["pr", "view", &pr.to_string(), "--json", "statusCheckRollup"])
            .output();
        let Ok(o) = out else {
            return Vec::new();
        };
        if !o.status.success() {
            return Vec::new();
        }
        let v: Value = serde_json::from_slice(&o.stdout).unwrap_or(Value::Null);
        v.get("statusCheckRollup")
            .and_then(|x| x.as_array())
            .cloned()
            .unwrap_or_default()
    })
}

/// Default fleet-failing provider — caches one `gh pr list --json` call
/// internally per process so we don't fan out N gh calls per check.
pub fn gh_fleet_failing_provider() -> FleetFailingProvider<'static> {
    let cache: std::cell::RefCell<Option<HashMap<String, Vec<u64>>>> =
        std::cell::RefCell::new(None);
    Box::new(move |check_name: &str| -> Vec<u64> {
        // Populate cache lazily once per process.
        {
            let mut c = cache.borrow_mut();
            if c.is_none() {
                *c = Some(build_fleet_failing_map());
            }
        }
        cache
            .borrow()
            .as_ref()
            .and_then(|m| m.get(check_name).cloned())
            .unwrap_or_default()
    })
}

fn build_fleet_failing_map() -> HashMap<String, Vec<u64>> {
    let out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "100",
            "--json",
            "number,statusCheckRollup",
        ])
        .output();
    let Ok(o) = out else {
        return HashMap::new();
    };
    if !o.status.success() {
        return HashMap::new();
    }
    let arr: Vec<Value> = serde_json::from_slice(&o.stdout).unwrap_or_default();
    let mut map: HashMap<String, Vec<u64>> = HashMap::new();
    for pr in arr {
        let n = pr.get("number").and_then(|v| v.as_u64()).unwrap_or(0);
        if n == 0 {
            continue;
        }
        let Some(rollup) = pr.get("statusCheckRollup").and_then(|v| v.as_array()) else {
            continue;
        };
        for entry in rollup {
            let conclusion = entry
                .get("conclusion")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if !matches!(conclusion, "FAILURE" | "CANCELLED" | "TIMED_OUT") {
                continue;
            }
            let name = entry
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if name.is_empty() {
                continue;
            }
            map.entry(name).or_default().push(n);
        }
    }
    map
}

/// Run end-to-end with the default gh providers.
pub fn run(pr_number: u64, json_out: bool) -> Result<()> {
    let rollup_provider = gh_rollup_provider();
    let fleet_provider = gh_fleet_failing_provider();
    let rollup = rollup_provider(pr_number);
    if rollup.is_empty() {
        return Err(anyhow!(
            "no statusCheckRollup for PR #{pr_number} — does it exist? are you authenticated?"
        ));
    }
    let report = build_report(pr_number, rollup, &fleet_provider);
    if json_out {
        println!("{}", serde_json::to_string_pretty(&report).unwrap());
    } else {
        print!("{}", render_text(&report));
    }
    Ok(())
}

pub fn render_text(r: &ExplainReport) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "=== chump pr explain-block #{} ===\n  overall: {}\n  summary: {}\n",
        r.pr_number, r.overall, r.summary
    ));
    if r.rows.is_empty() {
        s.push_str("\n  no blocking checks found.\n");
        return s;
    }
    s.push_str("\n  blocking checks:\n");
    for row in &r.rows {
        s.push_str(&format!(
            "    [{}] {} ({}/{})\n      → {}\n",
            row.scope, row.name, row.status, row.conclusion, row.next_action
        ));
        if !row.also_failing_prs.is_empty() {
            let preview: Vec<String> = row
                .also_failing_prs
                .iter()
                .take(5)
                .map(|n| format!("#{n}"))
                .collect();
            s.push_str(&format!("      also failing on: {}\n", preview.join(", ")));
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture_provider(map: HashMap<String, Vec<u64>>) -> FleetFailingProvider<'static> {
        Box::new(move |name: &str| map.get(name).cloned().unwrap_or_default())
    }

    #[test]
    fn green_pr_produces_overall_green() {
        let rollup = vec![
            json!({"name": "test", "conclusion": "SUCCESS", "status": "COMPLETED"}),
            json!({"name": "clippy", "conclusion": "SUCCESS", "status": "COMPLETED"}),
        ];
        let r = build_report(123, rollup, &fixture_provider(HashMap::new()));
        assert_eq!(r.overall, "green");
        assert!(r.rows.is_empty());
        assert!(r.summary.contains("no mechanical"));
    }

    #[test]
    fn local_failure_gets_clippy_action_hint() {
        let rollup =
            vec![json!({"name": "clippy", "conclusion": "FAILURE", "status": "COMPLETED"})];
        let r = build_report(123, rollup, &fixture_provider(HashMap::new()));
        assert_eq!(r.overall, "local");
        assert_eq!(r.rows.len(), 1);
        assert!(r.rows[0].next_action.contains("cargo clippy"));
    }

    #[test]
    fn sibling_failure_below_fleet_wide_threshold() {
        // 2 other PRs failing the same check — sibling_blocked, not fleet-wide.
        let mut m = HashMap::new();
        m.insert(
            "test-cache-mergestatestatus.sh".to_string(),
            vec![2333, 2337],
        );
        let rollup = vec![
            json!({"name": "test-cache-mergestatestatus.sh", "conclusion": "FAILURE", "status": "COMPLETED"}),
        ];
        let r = build_report(123, rollup, &fixture_provider(m));
        assert_eq!(r.overall, "sibling_blocked");
        assert!(r.rows[0].next_action.contains("#2333"));
    }

    #[test]
    fn fleet_wide_failure_when_3_plus_others_fail() {
        let mut m = HashMap::new();
        m.insert("audit-required".to_string(), vec![2333, 2337, 2350]);
        let rollup =
            vec![json!({"name": "audit-required", "conclusion": "FAILURE", "status": "COMPLETED"})];
        let r = build_report(123, rollup, &fixture_provider(m));
        assert_eq!(r.overall, "fleet_wide");
        assert!(r.rows[0].next_action.contains("fleet-wide"));
    }

    #[test]
    fn self_pr_not_double_counted_in_fleet_check() {
        // The fleet map includes the self-PR (gh returns it too). The
        // classification must exclude it when counting sibling failures.
        let mut m = HashMap::new();
        m.insert("test".to_string(), vec![123, 200]); // self + 1 sibling
        let rollup = vec![json!({"name": "test", "conclusion": "FAILURE", "status": "COMPLETED"})];
        let r = build_report(123, rollup, &fixture_provider(m));
        // 1 sibling fail → sibling_blocked, NOT fleet_wide
        assert_eq!(r.overall, "sibling_blocked");
    }

    #[test]
    fn pending_check_gets_pending_advice() {
        let rollup = vec![json!({"name": "cargo-test", "conclusion": "", "status": "IN_PROGRESS"})];
        let r = build_report(123, rollup, &fixture_provider(HashMap::new()));
        assert_eq!(r.overall, "local");
        assert!(r.rows[0].next_action.contains("pending"));
    }

    #[test]
    fn render_text_includes_scope_tag_and_action() {
        let rollup =
            vec![json!({"name": "fast-checks", "conclusion": "FAILURE", "status": "COMPLETED"})];
        let r = build_report(123, rollup, &fixture_provider(HashMap::new()));
        let out = render_text(&r);
        assert!(out.contains("[local]"));
        assert!(out.contains("fast-checks"));
        assert!(out.contains("→"));
    }

    #[test]
    fn worst_scope_tracks_max_severity_across_rows() {
        let mut m = HashMap::new();
        m.insert("audit".to_string(), vec![2333, 2337, 2350]); // fleet_wide
        m.insert("clippy".to_string(), vec![]); // local
        let rollup = vec![
            json!({"name": "clippy", "conclusion": "FAILURE", "status": "COMPLETED"}),
            json!({"name": "audit", "conclusion": "FAILURE", "status": "COMPLETED"}),
        ];
        let r = build_report(123, rollup, &fixture_provider(m));
        assert_eq!(r.overall, "fleet_wide");
    }
}
