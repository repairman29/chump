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
        tracing::info!(
            count = tool_calls.len(),
            "[SWARM ROUTER] Triggered for batch. Network offline. Falling back to local."
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
        if tool_policy::requires_approval(&tc.name) {
            let (cli_risk, risk_level, reason, args_preview) = approval_audit_fields(tc);

            let auto_cli_low =
                cli_risk == Some(CliRiskLevel::Low) && tool_policy::auto_approve_low_risk_cli();
            let auto_list = auto_tools.contains(&tc.name.to_lowercase());

            if auto_cli_low || auto_list {
                let result_label = if auto_cli_low {
                    "auto_approved_cli_low"
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
