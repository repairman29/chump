//! Pluggable tool execution: local in-process vs swarm (cluster) routing.
//! `CHUMP_CLUSTER_MODE=0` (default / unset): [`LocalExecutor`]. `CHUMP_CLUSTER_MODE=1`: [`SwarmExecutor`]
//! (stub — logs and falls back to the same sequential pipeline as local).
//! [`crate::agent_loop::ChumpAgent`] holds `Arc<dyn TaskExecutor>` so the loop does not depend on *where*
//! tools run, only on this trait.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::executor::{ToolExecutor, ToolResult};
use axonerai::provider::ToolCall;
use std::sync::Arc;
use tracing::instrument;

use crate::approval_resolver::{self, approval_timeout_secs};
use crate::chump_log;
use crate::cli_tool::{heuristic_risk, CliRiskLevel};
use crate::pending_peer_approval;
use crate::policy_override;
use crate::precision_controller;
use crate::stream_events::{AgentEvent, EventSender};
use crate::tool_input_validate;
use crate::tool_policy;

/// High-level batch executor: approval gates + sequential `ToolExecutor` runs.
/// Distinct from [`ToolExecutor`] (axonerai), which runs one tool at a time after approval.
#[async_trait]
pub trait TaskExecutor: Send + Sync {
    async fn execute_all<'a>(
        &self,
        event_tx: Option<&EventSender>,
        tool_executor: &ToolExecutor<'a>,
        tool_calls: &[ToolCall],
    ) -> Result<Vec<ToolResult>>;
}

/// Pick [`LocalExecutor`] vs [`SwarmExecutor`] from [`crate::env_flags::chump_cluster_mode`] (`CHUMP_CLUSTER_MODE`).
pub fn default_task_executor() -> Arc<dyn TaskExecutor + Send + Sync> {
    if crate::env_flags::chump_cluster_mode() {
        Arc::new(SwarmExecutor)
    } else {
        Arc::new(LocalExecutor)
    }
}

fn send_event(event_tx: Option<&EventSender>, ev: AgentEvent) {
    if let Some(tx) = event_tx {
        let _ = tx.send(ev);
    }
}

/// Surfaces used for approval UI + `log_tool_approval_audit`: risk tier, human reason, short args preview.
/// `patch_file` is treated like `run_cli` for audit (path + diff size, high risk).
fn approval_audit_fields(tc: &ToolCall) -> (Option<CliRiskLevel>, String, String, String) {
    let name = tc.name.as_str();
    if name == "run_cli" {
        let cmd_str = tc
            .input
            .get("command")
            .or_else(|| tc.input.get("cmd"))
            .and_then(|c| c.as_str())
            .unwrap_or("");
        let (level, r) = heuristic_risk(cmd_str);
        let args_preview = cmd_str.to_string();
        return (Some(level), level.as_str().to_string(), r, args_preview);
    }
    if name == "patch_file" {
        let path = tc
            .input
            .get("path")
            .or_else(|| tc.input.get("file_path"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let diff_len = tc
            .input
            .get("diff")
            .and_then(|v| v.as_str())
            .map(|s| s.len())
            .unwrap_or(0);
        let args_preview = format!("path={} diff_len={}", path, diff_len);
        return (
            None,
            "high".to_string(),
            "patch_file modifies workspace files (unified diff)".to_string(),
            args_preview,
        );
    }
    let args_preview = serde_json::to_string(&tc.input)
        .unwrap_or_else(|_| "...".to_string())
        .chars()
        .take(150)
        .collect::<String>();
    (
        None,
        "medium".to_string(),
        "tool requires approval".to_string(),
        args_preview,
    )
}

/// Default M4 path: sequential tools, approval gates, in-process `ToolExecutor`.
pub struct LocalExecutor;

#[async_trait]
impl TaskExecutor for LocalExecutor {
    #[instrument(
        skip(self, tool_executor, tool_calls, event_tx),
        fields(tool_call_count = tool_calls.len())
    )]
    async fn execute_all<'a>(
        &self,
        event_tx: Option<&EventSender>,
        tool_executor: &ToolExecutor<'a>,
        tool_calls: &[ToolCall],
    ) -> Result<Vec<ToolResult>> {
        execute_tool_calls_sequential(event_tx, tool_executor, tool_calls).await
    }
}

/// Cluster / farm path: reserved for distributed routing. Today logs and delegates to local execution.
pub struct SwarmExecutor;

#[async_trait]
impl TaskExecutor for SwarmExecutor {
    #[instrument(
        skip(self, tool_executor, tool_calls, event_tx),
        fields(tool_call_count = tool_calls.len())
    )]
    async fn execute_all<'a>(
        &self,
        event_tx: Option<&EventSender>,
        tool_executor: &ToolExecutor<'a>,
        tool_calls: &[ToolCall],
    ) -> Result<Vec<ToolResult>> {
        tracing::warn!(
            count = tool_calls.len(),
            "SwarmExecutor is a stub, falling back to local execution ([SWARM ROUTER] batch)."
        );
        LocalExecutor
            .execute_all(event_tx, tool_executor, tool_calls)
            .await
    }
}

/// Core implementation shared by local and swarm strategies (approval + one tool at a time).
#[instrument(
    skip(event_tx, tool_executor, tool_calls),
    fields(tool_call_count = tool_calls.len())
)]
pub async fn execute_tool_calls_sequential<'a>(
    event_tx: Option<&EventSender>,
    tool_executor: &ToolExecutor<'a>,
    tool_calls: &[ToolCall],
) -> Result<Vec<ToolResult>> {
    let mut results = Vec::with_capacity(tool_calls.len());
    let timeout_secs = approval_timeout_secs();
    let auto_tools = tool_policy::auto_approve_tools_set();
    for tc in tool_calls {
        if !tool_input_validate::skip_tool_input_validate() {
            if let Some(msg) = tool_input_validate::validate_tool_input(&tc.name, &tc.input) {
                let tr = ToolResult {
                    tool_call_id: tc.id.clone(),
                    tool_name: tc.name.clone(),
                    result: format!("Tool error: {}", msg),
                };
                precision_controller::battle_note_tool_result(&tc.name, &tr.result);
                results.push(tr);
                continue;
            }
        }
        let base_ask = tool_policy::tools_requiring_approval().contains(&tc.name.to_lowercase());
        if base_ask {
            let (cli_risk, risk_level, reason, args_preview) = approval_audit_fields(tc);

            let auto_cli_low =
                cli_risk == Some(CliRiskLevel::Low) && tool_policy::auto_approve_low_risk_cli();
            let auto_static_low = tool_policy::auto_approve_static_low_risk(&tc.name);
            let auto_list = auto_tools.contains(&tc.name.to_lowercase());
            let skip_session_override = policy_override::session_relax_active_for_tool(&tc.name);

            if auto_cli_low || auto_static_low || auto_list {
                let result_label = if auto_cli_low {
                    "auto_approved_cli_low"
                } else if auto_static_low {
                    "auto_approved_static_low_risk"
                } else {
                    "auto_approved_tools_env"
                };
                tracing::info!(
                    tool = %tc.name,
                    policy = %result_label,
                    "skipping human approval (CHUMP_AUTO_APPROVE_* policy)"
                );
                chump_log::log_tool_approval_audit(
                    &tc.name,
                    &args_preview,
                    &risk_level,
                    result_label,
                    chump_log::get_request_id().as_deref(),
                );
                // AUTO-005: track in DB for auto-approve rate metric
                tool_policy::record_approval_stat(&tc.name, "auto_approved", &risk_level);
            } else if skip_session_override {
                tracing::info!(
                    tool = %tc.name,
                    "skipping human approval (session policy override)"
                );
                chump_log::log_tool_approval_audit(
                    &tc.name,
                    &args_preview,
                    &risk_level,
                    "policy_override_session",
                    chump_log::get_request_id().as_deref(),
                );
                tool_policy::record_approval_stat(&tc.name, "auto_approved", &risk_level);
            } else {
                let (request_id, rx) = approval_resolver::request_approval();
                if pending_peer_approval::peer_approve_tools().contains(&tc.name.to_lowercase()) {
                    pending_peer_approval::write_pending_peer_approval(
                        &request_id,
                        &tc.name,
                        &tc.input,
                    );
                }
                let expires_at_secs = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() + timeout_secs)
                    .unwrap_or(0);
                send_event(
                    event_tx,
                    AgentEvent::ToolApprovalRequest {
                        request_id: request_id.clone(),
                        tool_name: tc.name.clone(),
                        tool_input: tc.input.clone(),
                        risk_level: risk_level.clone(),
                        reason: reason.clone(),
                        expires_at_secs,
                    },
                );
                let approval_result =
                    tokio::time::timeout(std::time::Duration::from_secs(timeout_secs), rx).await;
                let (allowed, result_label) = match approval_result {
                    Ok(Ok(true)) => (true, "allowed"),
                    Ok(Ok(false)) => (false, "denied"),
                    Ok(Err(_)) => (false, "denied"),
                    Err(_) => (false, "timeout"),
                };
                chump_log::log_tool_approval_audit(
                    &tc.name,
                    &args_preview,
                    &risk_level,
                    result_label,
                    chump_log::get_request_id().as_deref(),
                );
                // AUTO-005: track human approval decisions in DB
                let db_decision = if allowed {
                    "human_allowed"
                } else {
                    result_label
                };
                tool_policy::record_approval_stat(&tc.name, db_decision, &risk_level);
                if !allowed {
                    results.push(ToolResult {
                        tool_call_id: tc.id.clone(),
                        tool_name: tc.name.clone(),
                        result: "DENIED: User denied the tool (or approval timed out).".to_string(),
                    });
                    continue;
                }
            }
        }
        if tc.name == "patch_file" {
            let path = tc
                .input
                .get("path")
                .or_else(|| tc.input.get("file_path"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let diff_len = tc
                .input
                .get("diff")
                .and_then(|v| v.as_str())
                .map(|s| s.len())
                .unwrap_or(0);
            chump_log::log_patch_file(path, diff_len, "pre_execute");
        }
        let batch = vec![tc.clone()];
        match tool_executor.execute_all(&batch).await {
            Ok(batch_results) => {
                for tr in &batch_results {
                    precision_controller::battle_note_tool_result(&tr.tool_name, &tr.result);
                }
                results.extend(batch_results);
            }
            Err(e) => {
                let result = crate::repo_tools::enrich_file_tool_error(&tc.name, &tc.input, &e);
                let tr = ToolResult {
                    tool_call_id: tc.id.clone(),
                    tool_name: tc.name.clone(),
                    result,
                };
                precision_controller::battle_note_tool_result(&tc.name, &tr.result);
                results.push(tr);
            }
        }
    }
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::execute_tool_calls_sequential;
    use axonerai::executor::ToolExecutor;
    use axonerai::provider::ToolCall;
    use axonerai::tool::{Tool, ToolRegistry};
    use serde_json::{json, Value};
    use serial_test::serial;

    /// Minimal Tool impl that echoes back "ok:<name>" so tests can confirm execution happened.
    struct EchoTool {
        name: String,
    }
    #[async_trait::async_trait]
    impl Tool for EchoTool {
        fn name(&self) -> String {
            self.name.clone()
        }
        fn description(&self) -> String {
            "echo tool for tests".into()
        }
        fn input_schema(&self) -> Value {
            json!({"type":"object","properties":{}})
        }
        async fn execute(&self, _input: Value) -> anyhow::Result<String> {
            Ok(format!("ok:{}", self.name))
        }
    }

    fn make_registry(names: &[&str]) -> ToolRegistry {
        let mut r = ToolRegistry::new();
        for &n in names {
            r.register(Box::new(EchoTool {
                name: n.to_string(),
            }));
        }
        r
    }

    fn tc(name: &str, input: Value) -> ToolCall {
        ToolCall {
            id: format!("tc-{name}"),
            name: name.to_string(),
            input,
        }
    }

    // ------------------------------------------------------------------
    // Scenario 1: tool input validation rejects malformed call before execution
    // Note: TOOLS_ASK uses OnceLock (initialized once per process). Tests here
    // do not rely on changing CHUMP_TOOLS_ASK mid-process; env-sensitive paths
    // are tested at the approval_resolver level instead.
    // ------------------------------------------------------------------
    #[tokio::test]
    #[serial]
    async fn validation_rejects_missing_run_cli_command() {
        std::env::remove_var("CHUMP_SKIP_TOOL_INPUT_VALIDATE");
        let registry = make_registry(&["run_cli"]);
        let executor = ToolExecutor::new(&registry);
        let calls = vec![tc("run_cli", json!({}))];
        let results = execute_tool_calls_sequential(None, &executor, &calls)
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert!(
            results[0].result.starts_with("Tool error:"),
            "expected Tool error, got: {}",
            results[0].result
        );
    }

    // ------------------------------------------------------------------
    // Scenario 2: valid tool input with no approval gate → direct execution
    // (CHUMP_TOOLS_ASK OnceLock initialised as empty if not set at process start)
    // ------------------------------------------------------------------
    #[tokio::test]
    #[serial]
    async fn unapproved_tool_executes_directly() {
        std::env::remove_var("CHUMP_AUTO_APPROVE_TOOLS");
        let registry = make_registry(&["calc"]);
        let executor = ToolExecutor::new(&registry);
        let calls = vec![tc("calc", json!({"expr": "1+1"}))];
        let results = execute_tool_calls_sequential(None, &executor, &calls)
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].result, "ok:calc");
    }

    // ------------------------------------------------------------------
    // Scenario 3: multiple tools in one batch all execute and return results
    // ------------------------------------------------------------------
    #[tokio::test]
    #[serial]
    async fn batch_of_two_tools_both_execute() {
        let registry = make_registry(&["tool_a", "tool_b"]);
        let executor = ToolExecutor::new(&registry);
        let calls = vec![tc("tool_a", json!({})), tc("tool_b", json!({}))];
        let results = execute_tool_calls_sequential(None, &executor, &calls)
            .await
            .unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].result, "ok:tool_a");
        assert_eq!(results[1].result, "ok:tool_b");
    }

    // ------------------------------------------------------------------
    // Scenario 4: CHUMP_SKIP_TOOL_INPUT_VALIDATE=1 bypasses validation
    // ------------------------------------------------------------------
    #[tokio::test]
    #[serial]
    async fn skip_validate_flag_allows_malformed_run_cli() {
        std::env::set_var("CHUMP_SKIP_TOOL_INPUT_VALIDATE", "1");
        let registry = make_registry(&["run_cli"]);
        let executor = ToolExecutor::new(&registry);
        // run_cli with no command would normally fail validation, but skip bypasses it.
        let calls = vec![tc("run_cli", json!({}))];
        let results = execute_tool_calls_sequential(None, &executor, &calls)
            .await
            .unwrap();
        std::env::remove_var("CHUMP_SKIP_TOOL_INPUT_VALIDATE");
        assert_eq!(results.len(), 1);
        // With validation skipped the echo tool runs: validation error not injected.
        assert_eq!(results[0].result, "ok:run_cli");
    }

    // ------------------------------------------------------------------
    // Scenario 5: approval_audit_fields produces correct risk for patch_file
    // ------------------------------------------------------------------
    #[test]
    fn approval_audit_fields_patch_file_is_high() {
        let tc_val = ToolCall {
            id: "x".into(),
            name: "patch_file".into(),
            input: json!({"path": "src/foo.rs", "diff": "--- a\n+++ b\n@@ @@\n+x"}),
        };
        let (cli_risk, risk_level, reason, args_preview) = super::approval_audit_fields(&tc_val);
        assert!(cli_risk.is_none(), "patch_file has no CliRiskLevel");
        assert_eq!(risk_level, "high");
        assert!(reason.contains("patch_file"));
        assert!(args_preview.contains("src/foo.rs"));
    }

    // ------------------------------------------------------------------
    // Scenario 6: approval_audit_fields for low-risk CLI command
    // ------------------------------------------------------------------
    #[test]
    fn approval_audit_fields_low_risk_cli() {
        let tc_val = ToolCall {
            id: "y".into(),
            name: "run_cli".into(),
            input: json!({"command": "ls -la"}),
        };
        let (cli_risk, risk_level, _reason, args_preview) = super::approval_audit_fields(&tc_val);
        assert!(cli_risk.is_some(), "run_cli should have CliRiskLevel");
        assert_eq!(risk_level.to_lowercase(), cli_risk.unwrap().as_str());
        assert!(args_preview.contains("ls"));
    }

    // ------------------------------------------------------------------
    // Scenario 7: approval_audit_fields for unknown tool falls back to medium
    // ------------------------------------------------------------------
    #[test]
    fn approval_audit_fields_unknown_tool_is_medium() {
        let tc_val = ToolCall {
            id: "z".into(),
            name: "some_custom_tool".into(),
            input: json!({"key": "value"}),
        };
        let (cli_risk, risk_level, reason, _args_preview) = super::approval_audit_fields(&tc_val);
        assert!(cli_risk.is_none());
        assert_eq!(risk_level, "medium");
        assert!(reason.contains("approval"));
    }

    // ------------------------------------------------------------------
    // Scenario 8: approval_resolver timeout path (tests approval_resolver directly)
    // The TOOLS_ASK OnceLock prevents reliable env-var injection; test the timeout
    // mechanism at the resolver layer to preserve CI coverage of the deny path.
    // ------------------------------------------------------------------
    #[tokio::test]
    async fn approval_resolver_timeout_produces_false() {
        let (_id, rx) = crate::approval_resolver::request_approval();
        // Don't call resolve — let the receiver time out via tokio::time::timeout.
        let result = tokio::time::timeout(std::time::Duration::from_millis(50), rx).await;
        assert!(result.is_err(), "should have timed out");
    }

    // ------------------------------------------------------------------
    // Scenario 9: approval_resolver allow path
    // ------------------------------------------------------------------
    #[tokio::test]
    async fn approval_resolver_allow_produces_true() {
        let (id, rx) = crate::approval_resolver::request_approval();
        crate::approval_resolver::resolve_approval(&id, true);
        let allowed = rx.await.unwrap();
        assert!(allowed);
    }

    // ------------------------------------------------------------------
    // Scenario 10: approval_resolver deny path
    // ------------------------------------------------------------------
    #[tokio::test]
    async fn approval_resolver_deny_produces_false() {
        let (id, rx) = crate::approval_resolver::request_approval();
        crate::approval_resolver::resolve_approval(&id, false);
        let allowed = rx.await.unwrap();
        assert!(!allowed);
    }
}
