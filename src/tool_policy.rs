//! Tool policy: which tools require human approval before execution.
//! Set CHUMP_TOOLS_ASK to a comma-separated list of tool names (e.g. run_cli,write_file).
//!
//! Optional autonomy helpers (explicit opt-in; see docs/OPERATIONS.md):
//! - `CHUMP_AUTO_APPROVE_LOW_RISK=1` — when `run_cli` is in `CHUMP_TOOLS_ASK`, skip the approval
//!   prompt if `cli_tool::heuristic_risk` is **Low**. Also auto-approves any non-CLI tool whose
//!   static risk tier (from `classify_tool_risk`) is Low.
//! - `CHUMP_AUTO_APPROVE_TOOLS=read_file,calc` — skip approval for those tool names when they
//!   also appear in `CHUMP_TOOLS_ASK`.

use std::collections::HashSet;
use std::sync::OnceLock;

static TOOLS_ASK: OnceLock<HashSet<String>> = OnceLock::new();

fn parse_tools_ask() -> HashSet<String> {
    std::env::var("CHUMP_TOOLS_ASK")
        .ok()
        .map(|s| {
            s.split(',')
                .map(|x| x.trim().to_lowercase())
                .filter(|x| !x.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// Set of tool names that require approval before execution. Empty when CHUMP_TOOLS_ASK is unset.
pub fn tools_requiring_approval() -> &'static HashSet<String> {
    TOOLS_ASK.get_or_init(parse_tools_ask)
}

/// True if the named tool requires approval.
pub fn requires_approval(tool_name: &str) -> bool {
    tools_requiring_approval().contains(&tool_name.to_lowercase())
}

fn parse_comma_tool_names(s: &str) -> HashSet<String> {
    s.split(',')
        .map(|x| x.trim().to_lowercase())
        .filter(|x| !x.is_empty())
        .collect()
}

/// Tools listed in `CHUMP_AUTO_APPROVE_TOOLS` (comma-separated, case-insensitive). Read on each
/// call so cron/autonomy can change `.env` without relying on process-global caches.
pub fn auto_approve_tools_set() -> HashSet<String> {
    std::env::var("CHUMP_AUTO_APPROVE_TOOLS")
        .ok()
        .map(|s| parse_comma_tool_names(&s))
        .unwrap_or_default()
}

/// When true, `run_cli` calls that heuristic-risk as **Low** skip the approval wait (if `run_cli`
/// is in `CHUMP_TOOLS_ASK`). Must set `CHUMP_AUTO_APPROVE_LOW_RISK=1` or `true` explicitly.
pub fn auto_approve_low_risk_cli() -> bool {
    std::env::var("CHUMP_AUTO_APPROVE_LOW_RISK")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Static risk tier for a tool name, independent of its inputs.
/// Returns ("low"|"medium"|"high", human-readable reason).
///
/// `run_cli` always returns "medium" here — callers should use
/// `cli_tool::heuristic_risk(command)` for input-dependent CLI classification.
pub fn classify_tool_risk(tool_name: &str) -> (&'static str, &'static str) {
    match tool_name.to_lowercase().as_str() {
        // Read-only: no side effects, safe to auto-approve
        "read_file" | "read_url" | "fetch_url" | "browse_url" | "list_files" | "glob_search"
        | "search_code" | "grep_search" | "memory_search" | "memory_get" | "memory_list"
        | "memory_query" | "session_search" | "search_sessions" | "introspect" | "calc"
        | "calculate" | "get_time" | "get_date" | "task_list" | "task_get" | "task_search"
        | "knowledge_search" | "knowledge_get" | "read_spreadsheet" | "read_csv" | "list_tasks"
        | "get_task" | "search_tasks" | "diff_file" | "stat_file" | "check_file" => {
            ("low", "read-only operation")
        }

        // Moderate impact: reversible writes or limited scope
        "write_file" | "patch_file" | "create_file" | "memory_store" | "memory_update"
        | "memory_delete" | "task_create" | "task_update" | "task_complete" | "task_cancel"
        | "notify" | "send_notification" | "append_file" => {
            ("medium", "reversible write operation")
        }

        // High impact: destructive, network, or system-level
        "delete_file" | "remove_file" | "rm_file" | "run_cli" | "shell" | "bash" | "exec"
        | "http_post" | "http_put" | "http_delete" | "http_patch" | "send_email"
        | "send_message" | "send_discord" | "deploy" | "restart_service" | "kill_process"
        | "drop_table" | "delete_rows" | "truncate_table" | "git_push" | "git_force_push"
        | "git_reset" => ("high", "destructive or network operation"),

        // Default: treat unknown tools as medium — require explicit approval
        _ => ("medium", "unknown tool — defaulting to medium risk"),
    }
}

/// True when `CHUMP_AUTO_APPROVE_LOW_RISK=1` and the tool's static risk tier is Low.
/// Does NOT apply to `run_cli` (use `cli_tool::heuristic_risk` for that).
pub fn auto_approve_static_low_risk(tool_name: &str) -> bool {
    if tool_name.eq_ignore_ascii_case("run_cli") {
        return false;
    }
    let (tier, _) = classify_tool_risk(tool_name);
    tier == "low" && auto_approve_low_risk_cli()
}

/// Snapshot for `/api/stack-status` (PWA settings / diagnostics).
pub fn tool_policy_for_stack_status() -> serde_json::Value {
    let mut ask: Vec<String> = tools_requiring_approval().iter().cloned().collect();
    ask.sort();
    let mut auto_tools: Vec<String> = auto_approve_tools_set().into_iter().collect();
    auto_tools.sort();
    serde_json::json!({
        "tools_ask": ask,
        "tools_ask_active": !tools_requiring_approval().is_empty(),
        "auto_approve_low_risk_cli": auto_approve_low_risk_cli(),
        "auto_approve_tools": auto_tools,
        "policy_override_api": crate::policy_override::policy_override_api_enabled(),
        "approval_stats": crate::approval_stats::approval_stats_for_stack_status(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_comma_tool_names_trims_and_lowercases() {
        let h = parse_comma_tool_names(" run_cli , Write_File,");
        assert!(h.contains("run_cli"));
        assert!(h.contains("write_file"));
        assert_eq!(h.len(), 2);
    }

    #[test]
    fn classify_tool_risk_read_only_tools_are_low() {
        for tool in &[
            "read_file",
            "glob_search",
            "memory_search",
            "calc",
            "task_get",
        ] {
            let (tier, _) = classify_tool_risk(tool);
            assert_eq!(tier, "low", "{tool} should be low risk");
        }
    }

    #[test]
    fn classify_tool_risk_write_tools_are_medium() {
        for tool in &["write_file", "patch_file", "memory_store", "task_create"] {
            let (tier, _) = classify_tool_risk(tool);
            assert_eq!(tier, "medium", "{tool} should be medium risk");
        }
    }

    #[test]
    fn classify_tool_risk_destructive_tools_are_high() {
        for tool in &["delete_file", "run_cli", "send_email", "drop_table"] {
            let (tier, _) = classify_tool_risk(tool);
            assert_eq!(tier, "high", "{tool} should be high risk");
        }
    }

    #[test]
    fn classify_tool_risk_unknown_tool_is_medium() {
        let (tier, _) = classify_tool_risk("some_exotic_tool_xyz");
        assert_eq!(tier, "medium");
    }

    #[test]
    fn auto_approve_static_low_risk_excludes_run_cli() {
        // run_cli must always go through heuristic_risk, not static tier
        std::env::set_var("CHUMP_AUTO_APPROVE_LOW_RISK", "1");
        assert!(!auto_approve_static_low_risk("run_cli"));
        std::env::remove_var("CHUMP_AUTO_APPROVE_LOW_RISK");
    }
}
