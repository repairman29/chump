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

/// Static risk tier for a tool name, independent of its inputs.
/// Returns ("low"|"medium"|"high", human-readable reason).
///
/// `run_cli` always returns "medium" here — callers should use
/// `cli_tool::heuristic_risk(command)` for input-dependent CLI classification.
pub fn classify_tool_risk(tool_name: &str) -> (&'static str, &'static str) {
    match tool_name.to_lowercase().as_str() {
        "read_file" | "read_url" | "fetch_url" | "browse_url" | "list_files" | "glob_search"
        | "search_code" | "grep_search" | "memory_search" | "memory_get" | "memory_list"
        | "memory_query" | "session_search" | "search_sessions" | "introspect" | "calc"
        | "calculate" | "get_time" | "get_date" | "task_list" | "task_get" | "task_search"
        | "knowledge_search" | "knowledge_get" | "read_spreadsheet" | "read_csv" | "list_tasks"
        | "get_task" | "search_tasks" | "diff_file" | "stat_file" | "check_file" => {
            ("low", "read-only operation")
        }
        "write_file" | "patch_file" | "create_file" | "memory_store" | "memory_update"
        | "memory_delete" | "task_create" | "task_update" | "task_complete" | "task_cancel"
        | "notify" | "send_notification" | "append_file" => {
            ("medium", "reversible write operation")
        }
        "delete_file" | "remove_file" | "rm_file" | "run_cli" | "shell" | "bash" | "exec"
        | "http_post" | "http_put" | "http_delete" | "http_patch" | "send_email"
        | "send_message" | "send_discord" | "deploy" | "restart_service" | "kill_process"
        | "drop_table" | "delete_rows" | "truncate_table" | "git_push" | "git_force_push"
        | "git_reset" => ("high", "destructive or network operation"),
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

/// When true, `run_cli` calls that heuristic-risk as **Low** skip the approval wait (if `run_cli`
/// is in `CHUMP_TOOLS_ASK`). Must set `CHUMP_AUTO_APPROVE_LOW_RISK=1` or `true` explicitly.
pub fn auto_approve_low_risk_cli() -> bool {
    std::env::var("CHUMP_AUTO_APPROVE_LOW_RISK")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Record a tool approval decision to `chump_approval_stats` (AUTO-005).
/// `decision` is one of: "auto_approved", "human_allowed", "denied", "timeout".
/// Silently no-ops if the DB is unavailable (approval logic must never block on metrics).
pub fn record_approval_stat(tool_name: &str, decision: &str, risk_level: &str) {
    if let Ok(conn) = crate::db_pool::get() {
        let _ = conn.execute(
            "INSERT INTO chump_approval_stats (tool_name, decision, risk_level) VALUES (?1, ?2, ?3)",
            rusqlite::params![tool_name, decision, risk_level],
        );
    }
}

/// Compute the auto-approve rate from the last `window_days` days (default 7).
/// Returns (auto_approved_count, total_count, rate_fraction).
/// Returns (0, 0, 0.0) if DB is unavailable.
pub fn auto_approve_rate(window_days: u32) -> (u64, u64, f64) {
    let conn = match crate::db_pool::get() {
        Ok(c) => c,
        Err(_) => return (0, 0, 0.0),
    };
    let days = window_days.max(1);
    // Single scan to atomically compute both counts — prevents auto > total from concurrent inserts.
    let (auto, total): (i64, i64) = conn
        .query_row(
            "SELECT \
               SUM(CASE WHEN decision = 'auto_approved' THEN 1 ELSE 0 END), \
               COUNT(*) \
             FROM chump_approval_stats \
             WHERE datetime(recorded_at) >= datetime('now', ?1)",
            rusqlite::params![format!("-{} days", days)],
            |r| {
                Ok((
                    r.get::<_, i64>(0).unwrap_or(0),
                    r.get::<_, i64>(1).unwrap_or(0),
                ))
            },
        )
        .unwrap_or((0, 0));
    let rate = if total > 0 {
        auto as f64 / total as f64
    } else {
        0.0
    };
    (auto as u64, total as u64, rate)
}

/// Snapshot for `/api/stack-status` (PWA settings / diagnostics).
pub fn tool_policy_for_stack_status() -> serde_json::Value {
    let mut ask: Vec<String> = tools_requiring_approval().iter().cloned().collect();
    ask.sort();
    let mut auto_tools: Vec<String> = auto_approve_tools_set().into_iter().collect();
    auto_tools.sort();
    let (auto_count, total_count, rate) = auto_approve_rate(7);
    serde_json::json!({
        "tools_ask": ask,
        "tools_ask_active": !tools_requiring_approval().is_empty(),
        "auto_approve_low_risk_cli": auto_approve_low_risk_cli(),
        "auto_approve_tools": auto_tools,
        "policy_override_api": crate::policy_override::policy_override_api_enabled(),
        "auto_approve_rate_7d": {
            "auto_approved": auto_count,
            "total": total_count,
            "rate": rate,
        },
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
    fn record_approval_stat_noop_without_db() {
        // DB unavailable in unit test context → silently no-ops (no panic).
        record_approval_stat("run_cli", "auto_approved", "low");
    }

    #[test]
    fn auto_approve_rate_returns_valid_shape() {
        let (auto, total, rate) = auto_approve_rate(7);
        // Rate must be a valid fraction in [0, 1]; auto ≤ total.
        assert!(
            auto <= total,
            "auto_approved <= total: {} <= {}",
            auto,
            total
        );
        assert!((0.0..=1.0).contains(&rate), "rate in [0,1]: {}", rate);
        if total == 0 {
            assert!((rate - 0.0).abs() < f64::EPSILON);
        }
    }
}
