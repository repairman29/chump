//! AUTO-010: HITL permission negotiation.
//!
//! Escalates blocked or high-risk tool calls to the operator via `notify`, transitions
//! the task to `awaiting_approval`, and records a counterfactual lesson on denial.

/// Escalation payload posted to the owner via notify.
#[derive(Debug, Clone, serde::Serialize)]
pub struct EscalationRequest {
    pub tool: String,
    pub reason: String,
    pub command_preview: String,
    pub rollback_plan: String,
    pub task_id: Option<i64>,
}

/// Return true if a tool result string indicates permission was denied.
pub fn result_is_permission_denied(result: &str) -> bool {
    let lower = result.to_lowercase();
    lower.contains("permission denied")
        || lower.contains("operation not permitted")
        || lower.contains("access denied")
        || lower.contains("eacces")
        || lower.contains("denied: user denied")
}

/// Return true if we should escalate proactively based on approval history.
/// Triggers when `auto_approve_rate_7d < 0.3` (operator has been denying a lot).
pub fn low_approval_rate() -> bool {
    let (_, _, rate) = crate::tool_policy::auto_approve_rate(7);
    rate < 0.3
}

/// Build and emit an escalation: notify the operator, set task to awaiting_approval,
/// post to blackboard. Returns Ok(true) if escalation was sent.
pub fn escalate(req: &EscalationRequest) -> anyhow::Result<bool> {
    let task_label = req
        .task_id
        .map(|id| id.to_string())
        .unwrap_or_else(|| "none".to_string());

    let msg = format!(
        "[interrupt:approval_needed] HITL escalation required\n\
         Tool: {}\n\
         Reason: {}\n\
         Command: {}\n\
         Rollback: {}\n\
         Task: {}\n\
         Reply APPROVE or DENY.",
        req.tool, req.reason, req.command_preview, req.rollback_plan, task_label,
    );
    crate::chump_log::set_pending_notify(msg);

    if let Some(id) = req.task_id {
        let note = format!("awaiting_approval: {}", req.reason);
        let _ = crate::task_db::task_update_status(id, "awaiting_approval", Some(&note));
    }

    crate::blackboard::post(
        crate::blackboard::Module::Autonomy,
        format!("HITL escalation for '{}': {}", req.tool, req.reason),
        crate::blackboard::SalienceFactors {
            novelty: 0.6,
            uncertainty_reduction: 0.4,
            goal_relevance: 0.9,
            urgency: 0.9,
        },
    );

    tracing::warn!(
        tool = %req.tool,
        task_id = ?req.task_id,
        reason = %req.reason,
        "AUTO-010: HITL escalation triggered"
    );

    Ok(true)
}

/// Record a counterfactual lesson when an escalation is denied by the operator.
pub fn record_denial_lesson(tool: &str, reason: &str, task_id: Option<i64>) {
    let action = format!(
        "used tool '{}' without explicit operator pre-approval",
        tool
    );
    let alternative = Some("request operator approval before invoking high-risk tools");
    let lesson = format!(
        "Operator denied escalation for '{}': {}. Avoid this tool in similar future contexts \
         or request approval earlier in the task.",
        tool, reason
    );
    let _ = crate::counterfactual::store_lesson(
        task_id,
        Some("autonomy"),
        &action,
        alternative,
        &lesson,
        0.85,
        Some(0.8),
    );
}

/// Infer a rollback plan from the tool name and command.
pub fn infer_rollback_plan(tool_name: &str, command_preview: &str) -> String {
    if tool_name == "patch_file" || tool_name == "write_file" {
        "Restore previous file version: git checkout -- <path>".to_string()
    } else if tool_name == "run_cli" {
        if command_preview.contains("git push") || command_preview.contains("git commit") {
            "Revert with: git reset HEAD~1 (local) or coordinate with team for remote".to_string()
        } else if command_preview.contains("rm ") || command_preview.contains("delete") {
            "File deletion cannot be automatically rolled back — check git or recycle bin"
                .to_string()
        } else {
            "Verify system state manually; no automatic rollback available for this command"
                .to_string()
        }
    } else {
        format!(
            "No automatic rollback for '{}' — review output and revert manually if needed",
            tool_name
        )
    }
}

/// Check exec_reply text for permission-denied markers, escalate if found.
/// Called after an executor run in the autonomy loop. Returns true if escalated.
pub fn maybe_escalate_from_reply(exec_reply: &str, task_id: Option<i64>) -> bool {
    if !result_is_permission_denied(exec_reply) {
        return false;
    }
    let req = EscalationRequest {
        tool: "unknown".to_string(),
        reason: "Executor reply indicates a permission-denied error during task execution"
            .to_string(),
        command_preview: exec_reply.chars().take(200).collect(),
        rollback_plan: "Review executor output; restore files via git if writes were attempted"
            .to_string(),
        task_id,
    };
    let _ = escalate(&req);
    true
}

/// Proactive check: if auto-approve rate is low, escalate before execution.
/// `task_title` is used to build the command preview in the escalation notice.
/// Set `CHUMP_HITL_PROACTIVE_DISABLED=1` to suppress in tests.
pub fn maybe_escalate_proactive(task_title: &str, task_id: Option<i64>) -> bool {
    if std::env::var("CHUMP_HITL_PROACTIVE_DISABLED").as_deref() == Ok("1") {
        return false;
    }
    if !low_approval_rate() {
        return false;
    }
    let req = EscalationRequest {
        tool: "autonomy_exec".to_string(),
        reason: format!(
            "Auto-approve rate is below 30% over the last 7 days — human review required \
             before executing task: '{}'",
            task_title
        ),
        command_preview: format!("autonomy execute: {}", task_title),
        rollback_plan: "No execution has occurred yet; simply DENY to skip this task".to_string(),
        task_id,
    };
    let _ = escalate(&req);
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn result_is_permission_denied_matches_variants() {
        assert!(result_is_permission_denied(
            "permission denied: /etc/shadow"
        ));
        assert!(result_is_permission_denied(
            "DENIED: User denied the tool (or approval timed out)."
        ));
        assert!(result_is_permission_denied(
            "Operation not permitted (os error 1)"
        ));
        assert!(result_is_permission_denied("access denied to resource"));
        assert!(result_is_permission_denied("EACCES when opening file"));
        assert!(!result_is_permission_denied("task completed successfully"));
    }

    #[test]
    fn infer_rollback_plan_run_cli_git_push() {
        let plan = infer_rollback_plan("run_cli", "git push origin main");
        assert!(plan.contains("git reset") || plan.contains("revert"));
    }

    #[test]
    fn infer_rollback_plan_patch_file() {
        let plan = infer_rollback_plan("patch_file", "src/main.rs");
        assert!(plan.contains("git checkout"));
    }

    #[test]
    fn record_denial_lesson_noop_without_db() {
        // DB unavailable in unit tests — must not panic.
        record_denial_lesson("run_cli", "test denial", None);
    }

    #[test]
    fn maybe_escalate_from_reply_no_trigger_on_normal_output() {
        let triggered = maybe_escalate_from_reply("task completed ok", None);
        assert!(!triggered);
    }

    #[test]
    fn maybe_escalate_from_reply_triggers_on_permission_denied() {
        // Does not panic; DB unavailable so task_update_status silently no-ops.
        let triggered =
            maybe_escalate_from_reply("Error: permission denied when writing file", Some(42));
        assert!(triggered);
    }
}
