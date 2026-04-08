//! Autonomy loop: pick a task, execute, verify, and update state deterministically.
//!
//! Design goal: maximize real-world success by keeping the loop:
//! - single-task-per-run (cron/supervisor friendly)
//! - deterministic (task notes contract, explicit verification)
//! - safe by default (respects existing tool approval gates)

use anyhow::{anyhow, Result};

use axonerai::tool::Tool;
use crate::discord;
use crate::episode_db;
use crate::repo_path;
use crate::run_test_tool;
use crate::task_contract;
use crate::task_db;

#[cfg(test)]

#[derive(Debug, Clone)]
pub struct AutonomyOutcome {
    pub task_id: Option<i64>,
    pub status: String,
    pub detail: String,
}

fn pick_next_task(assignee: &str) -> Result<Option<task_db::TaskRow>> {
    // Highest priority first (task_db order), prefer "open" over "in_progress", never pick blocked.
    let mut tasks = task_db::task_list_for_assignee(assignee)?;
    tasks.retain(|t| t.status != "blocked" && t.status != "done" && t.status != "abandoned");
    if tasks.is_empty() {
        return Ok(None);
    }
    // Prefer open tasks first.
    if let Some(t) = tasks.iter().find(|t| t.status == "open") {
        return Ok(Some(t.clone()));
    }
    Ok(Some(tasks[0].clone()))
}

fn autonomy_owner() -> String {
    std::env::var("CHUMP_AUTONOMY_OWNER")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "chump".to_string())
}

fn ensure_task_contract(t: &task_db::TaskRow) -> Result<String> {
    let title = t.title.as_str();
    let repo = t.repo.as_deref();
    let notes = task_contract::ensure_contract(t.notes.as_deref(), title, repo);
    Ok(notes)
}

fn contract_has_acceptance_and_verify(notes: &str) -> bool {
    task_contract::acceptance(notes).is_some() && task_contract::verify(notes).is_some()
}

fn now_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}", t.as_secs(), t.subsec_millis())
}

fn append_progress(notes: &str, line: &str) -> String {
    // Append to Progress section if present; else append a new Progress section.
    let mut out = notes.trim().to_string();
    let stamp = now_iso();
    let entry = format!("- [{}] {}\n", stamp, line.trim());

    if out.contains("## Progress") {
        // naive but deterministic: append at end
        out.push('\n');
        out.push_str(&entry);
        return out;
    }
    out.push_str("\n\n## Progress\n");
    out.push_str(&entry);
    out
}

#[derive(Debug, Clone)]
struct VerifyResult {
    passed: u32,
    failed: u32,
    ignored: u32,
    raw: String,
}

fn parse_run_test_summary(s: &str) -> Option<VerifyResult> {
    // run_test returns: "passed=X failed=Y ignored=Z. Failing: [...]"
    let s = s.trim();
    let mut passed: Option<u32> = None;
    let mut failed: Option<u32> = None;
    let mut ignored: Option<u32> = None;
    for part in s.split_whitespace() {
        if let Some(v) = part.strip_prefix("passed=") {
            passed = v.trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok();
        } else if let Some(v) = part.strip_prefix("failed=") {
            failed = v.trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok();
        } else if let Some(v) = part.strip_prefix("ignored=") {
            ignored = v.trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok();
        }
    }
    Some(VerifyResult {
        passed: passed?,
        failed: failed?,
        ignored: ignored.unwrap_or(0),
        raw: s.to_string(),
    })
}

fn infer_verify_runner(verify_section: &str) -> Option<String> {
    let v = verify_section.to_lowercase();
    if v.contains("pnpm test") {
        return Some("pnpm".to_string());
    }
    if v.contains("npm test") {
        return Some("npm".to_string());
    }
    if v.contains("cargo test") || v.contains("run_test") || v.contains("cargo") {
        return Some("cargo".to_string());
    }
    None
}

/// Run one autonomy loop iteration:
/// - pick next task for assignee
/// - ensure contract exists in notes
/// - mark in_progress
/// - execute via agent prompt
/// - verify via contract "Verify" section (run_test when possible)
/// - mark done or blocked + episode log
pub async fn autonomy_once(assignee: &str) -> Result<AutonomyOutcome> {
    if !task_db::task_available() {
        return Err(anyhow!("task DB not available"));
    }

    let assignee = assignee.trim();
    let assignee = if assignee.is_empty() { "chump" } else { assignee };

    let mut task = match pick_next_task(assignee)? {
        Some(t) => t,
        None => {
            return Ok(AutonomyOutcome {
                task_id: None,
                status: "noop".to_string(),
                detail: "No actionable tasks.".to_string(),
            });
        }
    };

    // Lease/claim so multiple workers don't duplicate work.
    let owner = autonomy_owner();
    let lease = task_db::task_lease_claim(task.id, Some(&owner))?;
    let lease = match lease {
        Some(l) => l,
        None => {
            return Ok(AutonomyOutcome {
                task_id: Some(task.id),
                status: "noop".to_string(),
                detail: format!(
                    "Task #{} is already leased by another worker; skipping.",
                    task.id
                ),
            });
        }
    };

    // Ensure notes have the contract.
    let ensured = ensure_task_contract(&task)?;
    if task.notes.as_deref().unwrap_or("") != ensured {
        let _ = task_db::task_update_notes(task.id, Some(&ensured));
        task.notes = Some(ensured.clone());
    }
    let notes = task.notes.as_deref().unwrap_or("");
    if !contract_has_acceptance_and_verify(notes) {
        let _ = task_db::task_update_status(task.id, "blocked", Some(notes));
        let _ = task_db::task_lease_release(task.id, &lease.token);
        if episode_db::episode_available() {
            let _ = episode_db::episode_log(
                &format!("Blocked task #{} (missing acceptance/verify)", task.id),
                Some("Task contract missing Acceptance/Verify sections; requires human fill-in."),
                Some("autonomy,task,blocked"),
                task.repo.as_deref(),
                Some("uncertain"),
                None,
                task.issue_number,
            );
        }
        return Ok(AutonomyOutcome {
            task_id: Some(task.id),
            status: "blocked".to_string(),
            detail: "Task missing Acceptance/Verify; set to blocked.".to_string(),
        });
    }

    // Mark in_progress.
    let _ = task_db::task_update_status(task.id, "in_progress", Some(notes));

    // Execute: run one agent turn instructed to complete the task and update task notes/progress.
    let sections = task_contract::extract_sections(notes);
    let acceptance = sections
        .get(&task_contract::SECTION_ACCEPTANCE.to_lowercase())
        .cloned()
        .unwrap_or_default();
    let verify = sections
        .get(&task_contract::SECTION_VERIFY.to_lowercase())
        .cloned()
        .unwrap_or_default();
    let plan = sections
        .get(&task_contract::SECTION_PLAN.to_lowercase())
        .cloned()
        .unwrap_or_default();
    let ctx = sections
        .get(&task_contract::SECTION_CONTEXT.to_lowercase())
        .cloned()
        .unwrap_or_default();

    let exec_prompt = format!(
        "You are running an autonomy loop for task #{id}: {title}\n\n\
Context:\n{ctx}\n\n\
Plan:\n{plan}\n\n\
Acceptance (done looks like):\n{acceptance}\n\n\
Verify:\n{verify}\n\n\
Rules:\n\
- Do the work using tools as needed.\n\
- If the task is for a repo and requires repo context, ensure the correct repo is set (github_clone_or_pull + set_working_repo) before file/git/test tools.\n\
- Update the task notes Progress section with what you did and what remains (use task update notes).\n\
- Do not mark the task done yourself; the autonomy loop will verify and close.\n\
Reply with a short completion summary.",
        id = task.id,
        title = task.title,
        ctx = ctx.trim(),
        plan = plan.trim(),
        acceptance = acceptance.trim(),
        verify = verify.trim()
    );

    let (agent, _ready) = discord::build_chump_agent_cli()?;
    let exec_reply = agent.run(&exec_prompt).await.unwrap_or_else(|e| format!("Agent error: {}", e));

    // Refresh notes from DB (agent may have updated them via task tool).
    // We don't have a get-by-id helper, so re-list and find.
    let refreshed = task_db::task_list_for_assignee(assignee)?
        .into_iter()
        .find(|t| t.id == task.id);
    let mut notes_now = refreshed
        .as_ref()
        .and_then(|t| t.notes.as_deref())
        .unwrap_or(notes)
        .to_string();

    notes_now = append_progress(&notes_now, &format!("executor_summary: {}", exec_reply.trim()));
    let _ = task_db::task_update_notes(task.id, Some(&notes_now));

    // Verify (deterministic): if Verify section implies a runner and repo tools are available, run run_test.
    let verify_section = task_contract::verify(&notes_now).unwrap_or_default();
    let runner = infer_verify_runner(&verify_section);
    let mut verify_out: Option<String> = None;
    let mut verify_parsed: Option<VerifyResult> = None;

    if runner.is_some() && repo_path::repo_root_is_explicit() {
        let tool = run_test_tool::RunTestTool;
        let input = serde_json::json!({ "runner": runner.clone().unwrap_or_else(|| "cargo".to_string()) });
        if let Ok(s) = tool.execute(input).await {
            verify_parsed = parse_run_test_summary(&s);
            verify_out = Some(s);
        }
    }

    let (final_status, final_detail, sentiment) = match verify_parsed {
        Some(vr) if vr.failed == 0 => (
            "done".to_string(),
            format!("Verified ok: {}", vr.raw),
            "win",
        ),
        Some(vr) => (
            "blocked".to_string(),
            format!("Verification failed: {}", vr.raw),
            "frustrating",
        ),
        None => (
            "blocked".to_string(),
            "No runnable verification found; fill Verify section with an executable check (e.g. cargo test) and rerun.".to_string(),
            "uncertain",
        ),
    };

    let notes_final = append_progress(
        &notes_now,
        &format!(
            "verify: {}",
            verify_out.unwrap_or_else(|| final_detail.clone())
        ),
    );
    let _ = task_db::task_update_notes(task.id, Some(&notes_final));

    if final_status == "done" {
        let _ = task_db::task_complete(task.id, Some(&notes_final));
    } else {
        let _ = task_db::task_update_status(task.id, "blocked", Some(&notes_final));
        // Create a follow-up task for Jeff if verification is missing or failing.
        let follow_title = format!("Unblock task #{}: {}", task.id, task.title);
        let follow_notes = format!(
            "Task #{id} is blocked.\n\nReason:\n{reason}\n\nNext:\n- Fill Verify section with runnable commands, or fix failing tests, then rerun autonomy.\n",
            id = task.id,
            reason = final_detail
        );
        let _ = task_db::task_create(
            &follow_title,
            task.repo.as_deref(),
            task.issue_number,
            Some(5),
            Some("jeff"),
            Some(&follow_notes),
        );
    }

    let _ = task_db::task_lease_release(task.id, &lease.token);

    if episode_db::episode_available() {
        let _ = episode_db::episode_log(
            &format!("Autonomy {} task #{}", final_status, task.id),
            Some(&final_detail),
            Some("autonomy,task"),
            task.repo.as_deref(),
            Some(sentiment),
            None,
            task.issue_number,
        );
    }

    Ok(AutonomyOutcome {
        task_id: Some(task.id),
        status: final_status,
        detail: final_detail,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_run_test_summary_parses_counts() {
        let s = "passed=3 failed=1 ignored=2. Failing: [x]";
        let r = parse_run_test_summary(s).unwrap();
        assert_eq!(r.passed, 3);
        assert_eq!(r.failed, 1);
        assert_eq!(r.ignored, 2);
    }
}
