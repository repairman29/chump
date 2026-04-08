//! Autonomy loop: pick a task, execute, verify, and update state deterministically.
//!
//! Design goal: maximize real-world success by keeping the loop:
//! - single-task-per-run (cron/supervisor friendly)
//! - deterministic (task notes contract, explicit verification)
//! - safe by default (respects existing tool approval gates)

use anyhow::{anyhow, Result};

use crate::episode_db;
use crate::repo_path;
use crate::task_contract;
use crate::task_db;

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

fn ensure_task_contract(t: &task_db::TaskRow) -> Result<String> {
    let title = t.title.as_str();
    let repo = t.repo.as_deref();
    let notes = task_contract::ensure_contract(t.notes.as_deref(), title, repo);
    Ok(notes)
}

fn contract_has_acceptance_and_verify(notes: &str) -> bool {
    let sections = task_contract::extract_sections(notes);
    let a = sections
        .get(&task_contract::SECTION_ACCEPTANCE.to_lowercase())
        .map(|s| s.trim())
        .unwrap_or("");
    let v = sections
        .get(&task_contract::SECTION_VERIFY.to_lowercase())
        .map(|s| s.trim())
        .unwrap_or("");
    !a.is_empty() && !v.is_empty()
}

/// Run one autonomy loop iteration:
/// - pick next task for assignee
/// - ensure contract exists in notes
/// - mark in_progress
/// - (placeholder) execute via agent prompt
/// - verify via contract "Verify" section (placeholder in this commit)
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

    // Ensure notes have the contract.
    let ensured = ensure_task_contract(&task)?;
    if task.notes.as_deref().unwrap_or("") != ensured {
        let _ = task_db::task_update_notes(task.id, Some(&ensured));
        task.notes = Some(ensured.clone());
    }
    let notes = task.notes.as_deref().unwrap_or("");
    if !contract_has_acceptance_and_verify(notes) {
        let _ = task_db::task_update_status(task.id, "blocked", Some(notes));
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

    // Execution and verification will be implemented next:
    // - build a deterministic agent prompt from contract sections
    // - run via ChumpAgent and capture tool events
    // - parse Verify section for run_test hints and/or explicit commands
    //
    // For now, we stop after claiming the task + ensuring contract so the system is safe.
    if episode_db::episode_available() {
        let _ = episode_db::episode_log(
            &format!("Autonomy claimed task #{}", task.id),
            Some("Marked in_progress and ensured task contract template exists. Execution/verify loop not yet implemented."),
            Some("autonomy,task,in_progress"),
            task.repo.as_deref(),
            Some("neutral"),
            None,
            task.issue_number,
        );
    }

    Ok(AutonomyOutcome {
        task_id: Some(task.id),
        status: "in_progress".to_string(),
        detail: format!(
            "Claimed task #{} for {}. Repo root explicit={}.",
            task.id,
            assignee,
            repo_path::repo_root_is_explicit()
        ),
    })
}

