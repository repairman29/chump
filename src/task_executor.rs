//! Pluggable tool execution strategy: local in-process vs swarm (cluster) routing.
//! Today both paths use the same sequential approval + `ToolExecutor` pipeline; swarm-specific
//! fan-out can grow behind [`SwarmExecutor`] without changing [`crate::agent_loop::ChumpAgent::run`]
//! (returns [`crate::agent_loop::AgentRunOutcome`]).

use anyhow::Result;
use async_trait::async_trait;
use axonerai::executor::{ToolExecutor, ToolResult};
use axonerai::provider::ToolCall;
use tracing::instrument;

use crate::approval_resolver::{self, approval_timeout_secs};
use crate::chump_log;
use crate::precision_controller;
use crate::cli_tool::{heuristic_risk, CliRiskLevel};
use crate::pending_peer_approval;
use crate::stream_events::{AgentEvent, EventSender};
use crate::tool_input_validate;
use crate::tool_policy;

/// Which executor strategy is active for this turn (after mesh probe + cluster flag).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutorKind {
    Local,
    Swarm,
}

#[inline]
pub fn current_executor_kind() -> ExecutorKind {
    if crate::cluster_mesh::force_local_primary_execution() {
        ExecutorKind::Local
    } else {
        ExecutorKind::Swarm
    }
}

#[async_trait]
pub trait AgentTaskExecutor: Send + Sync {
    async fn execute_tool_calls_with_approval<'a>(
        &self,
        event_tx: Option<&EventSender>,
        executor: &ToolExecutor<'a>,
        tool_calls: &[ToolCall],
    ) -> Result<Vec<ToolResult>>;
}

fn send_event(event_tx: Option<&EventSender>, ev: AgentEvent) {
    if let Some(tx) = event_tx {
        let _ = tx.send(ev);
    }
}

/// Default M4 path: sequential tools, approval gates, in-process `ToolExecutor`.
pub struct LocalExecutor;

#[async_trait]
impl AgentTaskExecutor for LocalExecutor {
    #[instrument(skip(self, executor, tool_calls, event_tx), fields(tool_call_count = tool_calls.len()))]
    async fn execute_tool_calls_with_approval<'a>(
        &self,
        event_tx: Option<&EventSender>,
        executor: &ToolExecutor<'a>,
        tool_calls: &[ToolCall],
    ) -> Result<Vec<ToolResult>> {
        execute_tool_calls_sequential(event_tx, executor, tool_calls).await
    }
}

/// Cluster path: today delegates to the same sequential executor; reserved for distributed routing.
pub struct SwarmExecutor;

#[async_trait]
impl AgentTaskExecutor for SwarmExecutor {
    #[instrument(skip(self, executor, tool_calls, event_tx), fields(tool_call_count = tool_calls.len()))]
    async fn execute_tool_calls_with_approval<'a>(
        &self,
        event_tx: Option<&EventSender>,
        executor: &ToolExecutor<'a>,
        tool_calls: &[ToolCall],
    ) -> Result<Vec<ToolResult>> {
        LocalExecutor
            .execute_tool_calls_with_approval(event_tx, executor, tool_calls)
            .await
    }
}

pub async fn dispatch_tool_execution<'a>(
    kind: ExecutorKind,
    event_tx: Option<&EventSender>,
    executor: &ToolExecutor<'a>,
    tool_calls: &[ToolCall],
) -> Result<Vec<ToolResult>> {
    match kind {
        ExecutorKind::Local => {
            LocalExecutor
                .execute_tool_calls_with_approval(event_tx, executor, tool_calls)
                .await
        }
        ExecutorKind::Swarm => {
            SwarmExecutor
                .execute_tool_calls_with_approval(event_tx, executor, tool_calls)
                .await
        }
    }
}

/// Core implementation shared by local and swarm strategies.
pub async fn execute_tool_calls_sequential<'a>(
    event_tx: Option<&EventSender>,
    executor: &ToolExecutor<'a>,
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
            let cmd_str = if tc.name == "run_cli" {
                tc.input
                    .get("command")
                    .or_else(|| tc.input.get("cmd"))
                    .and_then(|c| c.as_str())
                    .unwrap_or("")
            } else {
                ""
            };
            let (cli_risk, risk_level, reason) = if tc.name == "run_cli" {
                let (level, r) = heuristic_risk(cmd_str);
                (Some(level), level.as_str().to_string(), r)
            } else {
                (
                    None,
                    "medium".to_string(),
                    "tool requires approval".to_string(),
                )
            };
            let args_preview = if tc.name == "run_cli" {
                cmd_str.to_string()
            } else {
                serde_json::to_string(&tc.input)
                    .unwrap_or_else(|_| "...".to_string())
                    .chars()
                    .take(150)
                    .collect::<String>()
            };

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
                        result: "DENIED: User denied the tool (or approval timed out)."
                            .to_string(),
                    });
                    continue;
                }
            }
        }
        let batch = vec![tc.clone()];
        match executor.execute_all(&batch).await {
            Ok(batch_results) => {
                for tr in &batch_results {
                    precision_controller::battle_note_tool_result(&tr.tool_name, &tr.result);
                }
                results.extend(batch_results);
            }
            Err(e) => {
                let tr = ToolResult {
                    tool_call_id: tc.id.clone(),
                    tool_name: tc.name.clone(),
                    result: format!("Tool error: {}", e),
                };
                precision_controller::battle_note_tool_result(&tc.name, &tr.result);
                results.push(tr);
            }
        }
    }
    Ok(results)
}
