//! `chump ship plan` and `chump ship execute` CLI modes.

use crate::*;
use anyhow::Result;

// ──────────────────────────────────────────────────────────────────────
// INFRA-1229 slice 1 — `chump ship plan` CLI wrapper around the pure
// planner in the chump-ship crate. Gathers PR + repo snapshots via gh + git,
// calls chump_ship::plan(), emits JSON (default) or a human summary.
// ──────────────────────────────────────────────────────────────────────

pub(crate) async fn ship_plan_cli(args: &[String]) -> Result<()> {
    let mut gap_id: Option<String> = None;
    let mut pr_num: Option<u64> = None;
    let mut branch: Option<String> = None;
    let mut json_out = true;
    let mut dry_run = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--gap" => {
                gap_id = args.get(i + 1).cloned();
                i += 2;
            }
            "--pr" => {
                pr_num = args.get(i + 1).and_then(|s| s.parse().ok());
                i += 2;
            }
            "--branch" => {
                branch = args.get(i + 1).cloned();
                i += 2;
            }
            "--json" => {
                json_out = true;
                i += 1;
            }
            "--human" => {
                json_out = false;
                i += 1;
            }
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            other => {
                eprintln!("chump ship plan: unknown flag {other:?}");
                eprintln!("Run `chump ship plan --help` for usage.");
                std::process::exit(2);
            }
        }
    }

    // Branch: explicit > current symbolic-ref > "HEAD" sentinel.
    tracing::debug!(?gap_id, ?pr_num, dry_run, "chump ship plan dispatch");
    let branch_name = match branch {
        Some(b) => b,
        None => std::process::Command::new("git")
            .args(["symbolic-ref", "--short", "HEAD"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "HEAD".to_string()),
    };

    // Repo snapshot — via git rev-list.
    let stale_threshold: u32 = std::env::var("CHUMP_BOT_MERGE_STALE_THRESHOLD")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(15);
    let (behind_main, ahead_main) = if dry_run {
        (0u32, 0u32)
    } else {
        ship_plan_count_behind_ahead("HEAD", "origin/main").unwrap_or((0, 0))
    };
    let has_uncommitted = if dry_run {
        false
    } else {
        !std::process::Command::new("git")
            .args(["status", "--porcelain"])
            .output()
            .ok()
            .map(|o| o.stdout.is_empty())
            .unwrap_or(true)
    };
    let repo = chump_ship::RepoSnapshot {
        branch: branch_name.clone(),
        behind_main,
        ahead_main,
        has_uncommitted,
        stale_threshold,
    };

    // PR snapshot — via gh api (REST), unless --dry-run.
    let pr = if dry_run {
        chump_ship::PrSnapshot {
            number: pr_num,
            state: if pr_num.is_some() {
                chump_ship::PrState::Open
            } else {
                chump_ship::PrState::None
            },
            mergeable: None,
            mergeable_state: chump_ship::MergeableState::Unknown,
            auto_merge_set: false,
            head_sha: String::new(),
            base_sha: String::new(),
            checks: chump_ship::ChecksSummary::default(),
        }
    } else {
        match ship_plan_fetch_pr_snapshot(pr_num, &branch_name) {
            Ok(snapshot) => snapshot,
            Err(e) => {
                eprintln!(
                    "chump ship plan: could not fetch PR snapshot ({e}); falling back to no-PR."
                );
                chump_ship::PrSnapshot {
                    number: None,
                    state: chump_ship::PrState::None,
                    mergeable: None,
                    mergeable_state: chump_ship::MergeableState::Unknown,
                    auto_merge_set: false,
                    head_sha: String::new(),
                    base_sha: String::new(),
                    checks: chump_ship::ChecksSummary::default(),
                }
            }
        }
    };

    let decision = chump_ship::plan(&pr, &repo);
    let payload = serde_json::json!({
        "gap": gap_id,
        "branch": branch_name,
        "behind_main": behind_main,
        "ahead_main": ahead_main,
        "pr": pr,
        "plan": decision,
    });

    if json_out {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        ship_plan_print_human(&decision, gap_id.as_deref(), &branch_name);
    }
    Ok(())
}

pub(crate) fn ship_plan_count_behind_ahead(head: &str, base: &str) -> std::io::Result<(u32, u32)> {
    let spec = format!("{head}...{base}");
    let out = std::process::Command::new("git")
        .args(["rev-list", "--left-right", "--count", &spec])
        .output()?;
    if !out.status.success() {
        return Ok((0, 0));
    }
    let s = String::from_utf8_lossy(&out.stdout);
    let mut parts = s.split_whitespace();
    let ahead: u32 = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    let behind: u32 = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    Ok((behind, ahead))
}

pub(crate) fn ship_plan_fetch_pr_snapshot(
    pr_num: Option<u64>,
    branch: &str,
) -> anyhow::Result<chump_ship::PrSnapshot> {
    // Resolve owner/repo from origin remote — `gh api repos/{owner}/{repo}/...`
    let nwo_out = std::process::Command::new("gh")
        .args([
            "repo",
            "view",
            "--json",
            "nameWithOwner",
            "--jq",
            ".nameWithOwner",
        ])
        .output()?;
    if !nwo_out.status.success() {
        anyhow::bail!(
            "gh repo view failed: {}",
            String::from_utf8_lossy(&nwo_out.stderr)
        );
    }
    let nwo = String::from_utf8_lossy(&nwo_out.stdout).trim().to_string();

    // Resolve PR number: explicit --pr > look up by head branch.
    let pr = match pr_num {
        Some(n) => n,
        None => {
            let owner = nwo.split('/').next().unwrap_or("");
            let list = std::process::Command::new("gh")
                .args([
                    "api",
                    &format!("repos/{nwo}/pulls?head={owner}:{branch}&state=open"),
                    "--jq",
                    ".[0].number // empty",
                ])
                .output()?;
            let s = String::from_utf8_lossy(&list.stdout).trim().to_string();
            if s.is_empty() {
                // No PR for this branch — return synthetic "no PR" snapshot.
                return Ok(chump_ship::PrSnapshot {
                    number: None,
                    state: chump_ship::PrState::None,
                    mergeable: None,
                    mergeable_state: chump_ship::MergeableState::Unknown,
                    auto_merge_set: false,
                    head_sha: String::new(),
                    base_sha: String::new(),
                    checks: chump_ship::ChecksSummary::default(),
                });
            }
            s.parse()?
        }
    };

    // Fetch PR detail.
    let pr_json = std::process::Command::new("gh")
        .args(["api", &format!("repos/{nwo}/pulls/{pr}")])
        .output()?;
    if !pr_json.status.success() {
        anyhow::bail!(
            "gh api pulls/{pr} failed: {}",
            String::from_utf8_lossy(&pr_json.stderr)
        );
    }
    let v: serde_json::Value = serde_json::from_slice(&pr_json.stdout)?;
    let state = match v.get("state").and_then(|x| x.as_str()) {
        Some("open") => chump_ship::PrState::Open,
        Some("closed") if v.get("merged").and_then(|x| x.as_bool()) == Some(true) => {
            chump_ship::PrState::Merged
        }
        Some("closed") => chump_ship::PrState::Closed,
        _ => chump_ship::PrState::Open,
    };
    let mergeable = v.get("mergeable").and_then(|x| x.as_bool());
    let mergeable_state = match v.get("mergeable_state").and_then(|x| x.as_str()) {
        Some("clean") => chump_ship::MergeableState::Clean,
        Some("behind") => chump_ship::MergeableState::Behind,
        Some("blocked") => chump_ship::MergeableState::Blocked,
        Some("dirty") => chump_ship::MergeableState::Dirty,
        Some("unstable") => chump_ship::MergeableState::Unstable,
        Some("has_hooks") => chump_ship::MergeableState::HasHooks,
        _ => chump_ship::MergeableState::Unknown,
    };
    let auto_merge_set = v.get("auto_merge").map(|x| !x.is_null()).unwrap_or(false);
    let head_sha = v
        .get("head")
        .and_then(|h| h.get("sha"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let base_sha = v
        .get("base")
        .and_then(|b| b.get("sha"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();

    // Fetch checks summary for the head sha.
    let checks = if head_sha.is_empty() {
        chump_ship::ChecksSummary::default()
    } else {
        ship_plan_fetch_checks(&nwo, &head_sha).unwrap_or_default()
    };

    Ok(chump_ship::PrSnapshot {
        number: Some(pr),
        state,
        mergeable,
        mergeable_state,
        auto_merge_set,
        head_sha,
        base_sha,
        checks,
    })
}

pub(crate) fn ship_plan_fetch_checks(
    nwo: &str,
    sha: &str,
) -> anyhow::Result<chump_ship::ChecksSummary> {
    let out = std::process::Command::new("gh")
        .args([
            "api",
            &format!("repos/{nwo}/commits/{sha}/check-runs"),
            "--paginate",
        ])
        .output()?;
    if !out.status.success() {
        anyhow::bail!(
            "gh api check-runs failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or(serde_json::json!({}));
    let runs = v
        .get("check_runs")
        .and_then(|x| x.as_array())
        .cloned()
        .unwrap_or_default();
    let mut s = chump_ship::ChecksSummary::default();
    for c in &runs {
        let status = c.get("status").and_then(|x| x.as_str()).unwrap_or("");
        let conclusion = c.get("conclusion").and_then(|x| x.as_str()).unwrap_or("");
        let neutral_kind = matches!(conclusion, "skipped" | "neutral" | "cancelled");
        if neutral_kind {
            s.neutral_or_skipped += 1;
            continue;
        }
        s.total += 1;
        if status != "completed" {
            s.incomplete += 1;
        } else if conclusion != "success" {
            s.completed_failure += 1;
        } else {
            s.completed_success += 1;
        }
    }
    Ok(s)
}

pub(crate) fn ship_plan_print_human(plan: &chump_ship::ShipPlan, gap: Option<&str>, branch: &str) {
    println!(
        "[ship plan] branch={branch} gap={}",
        gap.unwrap_or("(none)")
    );
    match plan {
        chump_ship::ShipPlan::AlreadyDone {
            pr,
            state,
            recovery_hint,
        } => {
            println!("  action: ALREADY_DONE  pr=#{pr} state={state:?}");
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::CreatePr { branch, ahead } => {
            println!("  action: CREATE_PR  branch={branch} ahead_main={ahead}");
        }
        chump_ship::ShipPlan::RebaseAndPush { behind_count } => {
            println!("  action: REBASE_AND_PUSH  behind_main={behind_count}");
        }
        chump_ship::ShipPlan::RestDirectMerge {
            pr,
            head_sha,
            checks_verified,
        } => {
            println!(
                "  action: REST_DIRECT_MERGE  pr=#{pr} head={} checks_green={checks_verified}",
                &head_sha[..head_sha.len().min(8)]
            );
        }
        chump_ship::ShipPlan::ArmAutoMerge { pr, reason } => {
            println!("  action: ARM_AUTO_MERGE  pr=#{pr}");
            println!("  reason: {reason}");
        }
        chump_ship::ShipPlan::WaitForChecks {
            pr,
            incomplete,
            reason,
        } => {
            println!("  action: WAIT_FOR_CHECKS  pr=#{pr} incomplete={incomplete}");
            println!("  reason: {reason}");
        }
        chump_ship::ShipPlan::StaleBranch {
            pr,
            behind,
            threshold,
            recovery_hint,
        } => {
            println!(
                "  action: STALE_BRANCH  pr={} behind={behind} threshold={threshold}",
                pr.map(|n| format!("#{n}"))
                    .unwrap_or_else(|| "(none)".to_string())
            );
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::ConflictRecover { pr, recovery_hint } => {
            println!("  action: CONFLICT_RECOVER  pr=#{pr}");
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::OperatorAction {
            reason,
            recovery_hint,
        } => {
            println!("  action: OPERATOR_ACTION");
            println!("  reason: {reason}");
            println!("  hint:   {recovery_hint}");
        }
    }
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-1229 slice 2 — `chump ship execute` CLI wrapper around the
// chump-ship executor decision (decide_steps). Reads a ShipPlan from a
// file or stdin, derives the ExecutorStep list, runs each step via
// std::process::Command, and emits an ExecuteResult JSON.
// ──────────────────────────────────────────────────────────────────────

pub(crate) async fn ship_execute_cli(args: &[String]) -> Result<()> {
    let mut plan_path: Option<String> = None;
    let mut from_stdin = false;
    let mut dry_run = false;
    // INFRA-1229 slice 3: bounded retry on push --force-with-lease races.
    let mut max_rebase_retries: u32 = std::env::var("CHUMP_BOT_MERGE_RETRY_MAX")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3);
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--plan" => {
                plan_path = args.get(i + 1).cloned();
                i += 2;
            }
            "--stdin" => {
                from_stdin = true;
                i += 1;
            }
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            "--max-rebase-retries" => {
                max_rebase_retries = args
                    .get(i + 1)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(max_rebase_retries);
                i += 2;
            }
            "--json" => {
                i += 1; // default, but accepted
            }
            other => {
                eprintln!("chump ship execute: unknown flag {other:?}");
                eprintln!("Run `chump ship execute --help` for usage.");
                std::process::exit(2);
            }
        }
    }

    if plan_path.is_none() && !from_stdin {
        eprintln!("chump ship execute: one of --plan PATH or --stdin is required.");
        std::process::exit(2);
    }

    // Read the plan envelope. `chump ship plan` emits a top-level object
    // with a `.plan` field; accept both that shape and a bare ShipPlan.
    let plan_json = if let Some(p) = plan_path {
        std::fs::read_to_string(&p).map_err(|e| anyhow::anyhow!("read --plan {p}: {e}"))?
    } else {
        use std::io::Read;
        let mut buf = String::new();
        std::io::stdin()
            .read_to_string(&mut buf)
            .map_err(|e| anyhow::anyhow!("read stdin: {e}"))?;
        buf
    };

    let value: serde_json::Value =
        serde_json::from_str(&plan_json).map_err(|e| anyhow::anyhow!("parse plan JSON: {e}"))?;
    let plan_obj = value.get("plan").unwrap_or(&value).clone();
    let plan: chump_ship::ShipPlan =
        serde_json::from_value(plan_obj).map_err(|e| anyhow::anyhow!("decode ShipPlan: {e}"))?;

    let steps = chump_ship::decide_steps(&plan);
    let plan_action = match &plan {
        chump_ship::ShipPlan::AlreadyDone { .. } => "AlreadyDone",
        chump_ship::ShipPlan::CreatePr { .. } => "CreatePr",
        chump_ship::ShipPlan::RebaseAndPush { .. } => "RebaseAndPush",
        chump_ship::ShipPlan::RestDirectMerge { .. } => "RestDirectMerge",
        chump_ship::ShipPlan::ArmAutoMerge { .. } => "ArmAutoMerge",
        chump_ship::ShipPlan::WaitForChecks { .. } => "WaitForChecks",
        chump_ship::ShipPlan::StaleBranch { .. } => "StaleBranch",
        chump_ship::ShipPlan::ConflictRecover { .. } => "ConflictRecover",
        chump_ship::ShipPlan::OperatorAction { .. } => "OperatorAction",
    };

    if steps.is_empty() {
        let payload = serde_json::json!({
            "plan_action": plan_action,
            "executed": false,
            "steps": [],
            "any_failure": false,
            "note": "No executor action needed for this ShipPlan variant.",
        });
        println!("{}", serde_json::to_string_pretty(&payload)?);
        return Ok(());
    }

    // Resolve the `{OWNER_REPO}` placeholder used by RestDirectMerge before
    // executing — only one `gh repo view` per invocation.
    let owner_repo = if dry_run {
        "{OWNER_REPO}".to_string()
    } else {
        std::process::Command::new("gh")
            .args([
                "repo",
                "view",
                "--json",
                "nameWithOwner",
                "--jq",
                ".nameWithOwner",
            ])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "{OWNER_REPO}".to_string())
    };

    // INFRA-8221: the one arm policy gates every PR-touching step (arm, REST
    // merge, rebase+force-push). Logic lives in chump_ship::gate_plan.
    if !dry_run {
        let branch = chump_ship::current_branch_name();
        let repo = if owner_repo.starts_with('{') {
            ""
        } else {
            owner_repo.as_str()
        };
        if let Err(held) = chump_ship::gate_plan(&plan, &branch, repo, "chump ship execute") {
            let payload = serde_json::json!({
                "plan_action": plan_action, "executed": false, "steps": [],
                "any_failure": false, "held": true, "note": held.to_string(),
            });
            println!("{}", serde_json::to_string_pretty(&payload)?);
            return Ok(());
        }
    }

    let mut step_results: Vec<serde_json::Value> = Vec::new();
    let mut any_failure = false;
    let mut retry_attempts: u32 = 0;
    let mut final_action: String = "Success".to_string();

    // INFRA-1229 slice 3: RebaseAndPush gets a retry loop driven by
    // chump_ship::classify_step_failure. Other plan variants use a single
    // pass.
    let is_rebase_and_push = matches!(plan, chump_ship::ShipPlan::RebaseAndPush { .. });

    'attempt: for attempt in 0..=max_rebase_retries {
        if attempt > 0 {
            retry_attempts = attempt;
            eprintln!(
                "[ship execute] push lost a race; retry {}/{}",
                attempt, max_rebase_retries
            );
        }
        for step in &steps {
            let resolved_args: Vec<String> = step
                .args
                .iter()
                .map(|a| a.replace("{OWNER_REPO}", &owner_repo))
                .collect();
            if dry_run {
                step_results.push(serde_json::json!({
                    "program": step.program,
                    "args": resolved_args,
                    "rc": 0,
                    "stderr_tail": "",
                    "duration_ms": 0,
                    "dry_run": true,
                    "note": step.note,
                    "attempt": attempt,
                }));
                continue;
            }
            let started = std::time::Instant::now();
            let out = std::process::Command::new(&step.program)
                .args(&resolved_args)
                .output();
            let elapsed_ms = started.elapsed().as_millis() as u64;
            let (rc, stderr_tail) = match out {
                Ok(o) => {
                    let tail = String::from_utf8_lossy(&o.stderr);
                    let tail: String = tail
                        .lines()
                        .rev()
                        .take(3)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect::<Vec<_>>()
                        .join("\n");
                    (o.status.code().unwrap_or(-1), tail)
                }
                Err(e) => (-1, format!("exec error: {e}")),
            };
            let success = rc == 0;
            step_results.push(serde_json::json!({
                "program": step.program,
                "args": resolved_args,
                "rc": rc,
                "stderr_tail": stderr_tail,
                "duration_ms": elapsed_ms,
                "expect_success": step.expect_success,
                "success": success,
                "note": step.note,
                "attempt": attempt,
            }));
            if !success && step.expect_success {
                any_failure = true;

                if is_rebase_and_push {
                    // Classify the failure: retry, abort-as-conflict, or hard-fail.
                    let action = chump_ship::classify_step_failure(
                        &step.program,
                        &resolved_args,
                        rc,
                        &stderr_tail,
                        attempt,
                        max_rebase_retries,
                    );
                    match action {
                        chump_ship::RetryAction::RetryRebaseAndPush { .. } => {
                            // Restart from the top of the step list on next attempt.
                            final_action = "RetryRebaseAndPush".to_string();
                            continue 'attempt;
                        }
                        chump_ship::RetryAction::AbortAsConflict { reason } => {
                            final_action = "ConflictRecover".to_string();
                            eprintln!("[ship execute] {reason}");
                            // Best-effort: leave the rebase abort to the operator
                            // — the conflict markers in the working tree are the
                            // evidence they need.
                            break 'attempt;
                        }
                        chump_ship::RetryAction::Fail { reason } => {
                            final_action = "Fail".to_string();
                            eprintln!("[ship execute] {reason}");
                            break 'attempt;
                        }
                        chump_ship::RetryAction::Continue
                        | chump_ship::RetryAction::AbortAsStaleBranch { .. } => {
                            // AbortAsStaleBranch isn't emitted by this classifier
                            // (it's a pre-push check); Continue shouldn't happen
                            // on a failed step.
                            final_action = "Fail".to_string();
                            break 'attempt;
                        }
                    }
                } else {
                    // Non-rebase variants: keep the existing single-pass behavior.
                    final_action = "Fail".to_string();
                    break 'attempt;
                }
            }
        }
        // Loop finished without a step-failure → all steps succeeded on this attempt.
        // (Overwrite final_action even if a previous attempt failed and we
        // retried successfully — the final state IS success.)
        final_action = "Success".to_string();
        // Once the chain succeeds via retry, the earlier failures are
        // recorded in step_results but don't bubble out as any_failure.
        any_failure = false;
        break 'attempt;
        // Note: if a step failed, control always reaches `break 'attempt` or
        // `continue 'attempt` above and never falls through to here.
    }

    let payload = serde_json::json!({
        "plan_action": plan_action,
        "executed": !dry_run,
        "dry_run": dry_run,
        "steps": step_results,
        "any_failure": any_failure,
        "retry_attempts": retry_attempts,
        "final_action": final_action,
        "max_rebase_retries": max_rebase_retries,
    });
    println!("{}", serde_json::to_string_pretty(&payload)?);
    if any_failure && final_action != "Success" {
        std::process::exit(1);
    }
    Ok(())
}
