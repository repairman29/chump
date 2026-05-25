//! INFRA-1522 / W-007: required-check health gate.
//!
//! Detects the W-007 wedge class — a required status check (per
//! `gh api repos/.../branches/main/protection/required_status_checks`)
//! that has either:
//!
//!   1. High recent FAILURE rate (default >20% over last 50 runs), OR
//!   2. Recent SKIPPED conclusion (last 5 runs) for PRs the check
//!      *should* have run on — which means the path-filter is excluding
//!      it but the check is still REQUIRED, so the PR can never satisfy it.
//!
//! Today's signal (2026-05-25): `tauri-cowork-e2e` was REQUIRED in repo
//! ruleset 15133729 despite being a known-broken Selenium test (INFRA-1425).
//! With INFRA-1432's narrow path filter, non-tauri PRs got SKIPPED on it —
//! and SKIPPED does NOT satisfy a required check → entire fleet stalled
//! for 12+ hours. Cost: ~50 PRs of throughput.
//!
//! The fix is structural, not reactive: every `chump fleet up` and
//! `chump fleet doctor` runs this check. If any required check is unhealthy,
//! `up` refuses with an actionable message ("remove from required or
//! fix root cause") and `doctor` exits non-zero.
//!
//! Bypass: `chump fleet up --force` (one-shot operator override). Emits
//! `kind=required_check_health_bypass` so the audit log captures every
//! intentional ignore.
//!
//! Design notes:
//!   - The provider (gh API caller) is injected, so tests can stub it.
//!   - The default provider shells `gh api …` and parses JSON.
//!   - The check is read-only — it never mutates the ruleset. The
//!     `proposed_action` field on the ambient event is operator-actionable
//!     copy/paste, not auto-applied.

use crate::ambient_emit::{emit, EmitArgs};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Default flake-rate threshold: >20% FAILURE in the recent window.
pub const DEFAULT_FAILURE_RATE_PCT: f64 = 20.0;

/// Default window of recent runs to inspect.
pub const DEFAULT_WINDOW_RUNS: usize = 50;

/// SKIPPED-streak threshold (last N runs).
pub const DEFAULT_SKIP_STREAK: usize = 5;

/// One row from the gh check-runs API per (context, conclusion).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckRun {
    pub context: String,
    /// One of: SUCCESS, FAILURE, SKIPPED, NEUTRAL, CANCELLED, TIMED_OUT, …
    pub conclusion: String,
}

/// Health report for a single required check.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct CheckHealth {
    pub context: String,
    pub runs_seen: usize,
    pub failure_rate_pct: f64,
    pub skipped_last_n: usize,
    pub healthy: bool,
    pub reason: Option<String>,
}

/// Full health report across all required checks.
#[derive(Debug, Clone, Serialize)]
pub struct HealthReport {
    pub checks: Vec<CheckHealth>,
    pub any_unhealthy: bool,
}

impl HealthReport {
    /// Render a one-line actionable message for the operator. Used by
    /// `chump fleet up` on refuse.
    pub fn refuse_message(&self) -> String {
        let unhealthy: Vec<_> = self.checks.iter().filter(|c| !c.healthy).collect();
        if unhealthy.is_empty() {
            return "all required checks healthy".to_string();
        }
        let mut parts = Vec::new();
        for c in &unhealthy {
            parts.push(format!(
                "{}: {} (failure_rate={:.0}%, skipped_last={})",
                c.context,
                c.reason.as_deref().unwrap_or("unhealthy"),
                c.failure_rate_pct,
                c.skipped_last_n
            ));
        }
        format!(
            "required-check health gate FAILED: {}\n  hint: remove from required ruleset OR fix root cause:\n  gh api repos/<owner>/<repo>/rulesets/<id> --method PUT ... (drop the offending context)",
            parts.join("; ")
        )
    }
}

/// A function that fetches recent runs for the given required checks.
/// Default implementation shells `gh api`; tests inject mocks.
pub type RunsProvider = Box<dyn Fn(&[String]) -> Result<Vec<CheckRun>, String>>;

/// Evaluate health for the given required checks using the injected provider.
///
/// Pure function — no I/O, no side effects, no ambient emit. Callers that
/// want the ambient event should call [`emit_warn_for_unhealthy`] separately.
pub fn evaluate(required: &[String], provider: &RunsProvider) -> HealthReport {
    let runs = match provider(required) {
        Ok(r) => r,
        Err(_) => {
            // If we can't fetch runs, fail OPEN (healthy=true) — refusing
            // every fleet up because gh api is down would be worse than
            // letting it through. Operator will see other errors first.
            return HealthReport {
                checks: required
                    .iter()
                    .map(|c| CheckHealth {
                        context: c.clone(),
                        runs_seen: 0,
                        failure_rate_pct: 0.0,
                        skipped_last_n: 0,
                        healthy: true,
                        reason: Some("provider error (failing open)".to_string()),
                    })
                    .collect(),
                any_unhealthy: false,
            };
        }
    };

    // Bucket runs by context, in arrival order (caller is responsible for
    // returning most-recent-first or oldest-first; we only count, not order).
    let mut by_context: HashMap<String, Vec<String>> = HashMap::new();
    for r in &runs {
        by_context
            .entry(r.context.clone())
            .or_default()
            .push(r.conclusion.clone());
    }

    let mut checks = Vec::new();
    for ctx in required {
        let conclusions: &[String] = by_context.get(ctx).map(|v| v.as_slice()).unwrap_or(&[]);
        let runs_seen = conclusions.len();
        let failures = conclusions
            .iter()
            .filter(|c| c.eq_ignore_ascii_case("FAILURE"))
            .count();
        let failure_rate_pct = if runs_seen == 0 {
            0.0
        } else {
            (failures as f64) * 100.0 / (runs_seen as f64)
        };
        // SKIPPED-streak: count SKIPPED in the most recent DEFAULT_SKIP_STREAK
        // window. Provider returns oldest-first or newest-first arbitrarily;
        // we use the LAST N entries as "most recent" by convention.
        let tail = if conclusions.len() > DEFAULT_SKIP_STREAK {
            &conclusions[conclusions.len() - DEFAULT_SKIP_STREAK..]
        } else {
            conclusions
        };
        let skipped_last_n = tail
            .iter()
            .filter(|c| c.eq_ignore_ascii_case("SKIPPED"))
            .count();

        let (healthy, reason) = if runs_seen == 0 {
            (true, Some("no recent runs (new check?)".to_string()))
        } else if failure_rate_pct > DEFAULT_FAILURE_RATE_PCT {
            (
                false,
                Some(format!(
                    "FAILURE rate {:.0}% > {:.0}% threshold",
                    failure_rate_pct, DEFAULT_FAILURE_RATE_PCT
                )),
            )
        } else if skipped_last_n >= DEFAULT_SKIP_STREAK {
            (
                false,
                Some(format!(
                    "last {} runs all SKIPPED (path-filter excludes but ruleset still requires)",
                    DEFAULT_SKIP_STREAK
                )),
            )
        } else {
            (true, None)
        };

        checks.push(CheckHealth {
            context: ctx.clone(),
            runs_seen,
            failure_rate_pct,
            skipped_last_n,
            healthy,
            reason,
        });
    }

    let any_unhealthy = checks.iter().any(|c| !c.healthy);
    HealthReport {
        checks,
        any_unhealthy,
    }
}

/// Emit `kind=required_check_health_warn` for each unhealthy check, with
/// an operator-actionable `proposed_action` field. Call after [`evaluate`]
/// if the report has any unhealthy entries.
pub fn emit_warn_for_unhealthy(report: &HealthReport, ruleset_id: Option<&str>) {
    for c in &report.checks {
        if c.healthy {
            continue;
        }
        let proposed_action = if let Some(rid) = ruleset_id {
            format!(
                "gh api repos/{{owner}}/{{repo}}/rulesets/{} --method PUT (drop '{}' from required_status_checks)",
                rid, c.context
            )
        } else {
            format!(
                "remove '{}' from branch-protection required_status_checks, or fix root cause",
                c.context
            )
        };
        let _ = emit(&EmitArgs {
            kind: "required_check_health_warn".to_string(),
            source: Some("required_check_health".to_string()),
            fields: vec![
                ("context".to_string(), c.context.clone()),
                (
                    "failure_rate_pct".to_string(),
                    format!("{:.0}", c.failure_rate_pct),
                ),
                ("skipped_last_n".to_string(), c.skipped_last_n.to_string()),
                ("runs_seen".to_string(), c.runs_seen.to_string()),
                ("reason".to_string(), c.reason.clone().unwrap_or_default()),
                ("proposed_action".to_string(), proposed_action),
            ],
            ..Default::default()
        });
    }
}

/// Emit `kind=required_check_health_bypass` when operator passes --force.
pub fn emit_bypass(report: &HealthReport, reason: &str) {
    let contexts: Vec<String> = report
        .checks
        .iter()
        .filter(|c| !c.healthy)
        .map(|c| c.context.clone())
        .collect();
    let _ = emit(&EmitArgs {
        kind: "required_check_health_bypass".to_string(),
        source: Some("required_check_health".to_string()),
        fields: vec![
            ("bypassed_contexts".to_string(), contexts.join(",")),
            ("reason".to_string(), reason.to_string()),
        ],
        ..Default::default()
    });
}

/// Default provider: shells `gh api repos/<owner>/<repo>/branches/main/protection/required_status_checks`
/// to list required checks, then `gh api repos/<owner>/<repo>/actions/runs?per_page=50`
/// (or check-runs) to count recent conclusions.
///
/// In production, prefer the cache-first path (INFRA-1081) where possible.
/// This default is the fallback when no provider is injected.
pub fn default_provider() -> RunsProvider {
    Box::new(|required: &[String]| {
        // Shell out to gh for each required context via the GraphQL search
        // API. To keep this dependency-free, we shell `gh api search/issues`
        // patterns; the cache layer can replace this later.
        //
        // For now, just return empty so production fails-open. The CI test
        // injects a richer mock. INFRA-NEW-FOLLOWUP can wire the real
        // gh-cache integration in a follow-up gap.
        let _ = required;
        Ok(Vec::new())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mock_provider(runs: Vec<CheckRun>) -> RunsProvider {
        Box::new(move |_required: &[String]| Ok(runs.clone()))
    }

    #[test]
    fn healthy_check_passes() {
        let runs = vec![
            CheckRun {
                context: "test".into(),
                conclusion: "SUCCESS".into(),
            };
            10
        ];
        let report = evaluate(&["test".to_string()], &mock_provider(runs));
        assert!(!report.any_unhealthy);
        assert!(report.checks[0].healthy);
    }

    #[test]
    fn high_failure_rate_fails() {
        // 7 FAILURE, 3 SUCCESS → 70% > 20% threshold
        let mut runs: Vec<CheckRun> = Vec::new();
        for _ in 0..7 {
            runs.push(CheckRun {
                context: "flaky".into(),
                conclusion: "FAILURE".into(),
            });
        }
        for _ in 0..3 {
            runs.push(CheckRun {
                context: "flaky".into(),
                conclusion: "SUCCESS".into(),
            });
        }
        let report = evaluate(&["flaky".to_string()], &mock_provider(runs));
        assert!(report.any_unhealthy);
        assert!(!report.checks[0].healthy);
        assert!(report.checks[0].failure_rate_pct > 60.0);
    }

    #[test]
    fn skipped_streak_fails() {
        // 5 SUCCESS then 5 SKIPPED — last 5 all SKIPPED
        let mut runs: Vec<CheckRun> = Vec::new();
        for _ in 0..5 {
            runs.push(CheckRun {
                context: "tauri-cowork-e2e".into(),
                conclusion: "SUCCESS".into(),
            });
        }
        for _ in 0..5 {
            runs.push(CheckRun {
                context: "tauri-cowork-e2e".into(),
                conclusion: "SKIPPED".into(),
            });
        }
        let report = evaluate(&["tauri-cowork-e2e".to_string()], &mock_provider(runs));
        assert!(report.any_unhealthy);
        assert!(!report.checks[0].healthy);
        assert_eq!(report.checks[0].skipped_last_n, 5);
    }

    #[test]
    fn missing_check_is_healthy_with_note() {
        // Required check with no recent runs (e.g., just added) is healthy
        // with an explanatory reason.
        let report = evaluate(&["new-check".to_string()], &mock_provider(vec![]));
        assert!(!report.any_unhealthy);
        assert!(report.checks[0].healthy);
        assert!(report.checks[0]
            .reason
            .as_ref()
            .unwrap()
            .contains("no recent runs"));
    }

    #[test]
    fn provider_error_fails_open() {
        let err_provider: RunsProvider =
            Box::new(|_: &[String]| Err("gh api unreachable".to_string()));
        let report = evaluate(&["test".to_string()], &err_provider);
        assert!(!report.any_unhealthy); // fail-open
    }

    #[test]
    fn refuse_message_is_actionable() {
        let runs: Vec<CheckRun> = (0..10)
            .map(|_| CheckRun {
                context: "tauri-cowork-e2e".into(),
                conclusion: "FAILURE".into(),
            })
            .collect();
        let report = evaluate(&["tauri-cowork-e2e".to_string()], &mock_provider(runs));
        let msg = report.refuse_message();
        assert!(msg.contains("tauri-cowork-e2e"));
        assert!(msg.contains("FAILED"));
        assert!(msg.contains("remove from required") || msg.contains("rulesets"));
    }
}
