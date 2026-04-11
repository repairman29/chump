//! Own agent run loop with optional event streaming. Replaces axonerai Agent::run when we need
//! SSE (web) or a single place to add keepalive/streaming. Uses Session + FileSessionManager
//! and the same message format (format_tool_use / format_tool_results) as axonerai.
//! When CHUMP_TOOLS_ASK is set, tools in that set require approval before execution.

use anyhow::Result;
use axonerai::executor::{ToolExecutor, ToolResult};
use axonerai::file_session_manager::FileSessionManager;
use axonerai::provider::{Message, Provider, StopReason, ToolCall};
use axonerai::session::Session;
use std::time::Instant;
use tracing::instrument;

use crate::approval_resolver::{self, approval_timeout_secs};
use crate::chump_log;
use crate::cli_tool::{heuristic_risk, CliRiskLevel};
use crate::pending_peer_approval;
use crate::stream_events::{AgentEvent, EventSender};
use crate::tool_policy;

/// Detect text-format tool calls emitted by models that don't use native function calling.
/// Matches lines like: `Using tool 'name' with input: {json}`
/// Returns `Some(calls)` if any are found and all match registered tool names; `None` otherwise.
fn parse_text_tool_calls(text: &str, tools: &[axonerai::provider::Tool]) -> Option<Vec<ToolCall>> {
    let known: std::collections::HashSet<&str> = tools.iter().map(|t| t.name.as_str()).collect();
    let mut calls = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Using tool '") {
            if let Some(name_end) = rest.find("' with input:") {
                let name = &rest[..name_end];
                if !known.contains(name) {
                    continue;
                }
                let json_part = rest[name_end + "' with input:".len()..].trim();
                if let Ok(input) = serde_json::from_str::<serde_json::Value>(json_part) {
                    calls.push(ToolCall {
                        id: format!("txt_{}", uuid::Uuid::new_v4().simple()),
                        name: name.to_string(),
                        input,
                    });
                }
            }
        }
    }
    if calls.is_empty() {
        None
    } else {
        Some(calls)
    }
}

/// Multi-tool batch snapshot/evaluate path (`speculative_execution`). Set `CHUMP_SPECULATIVE_BATCH=0` to disable.
fn speculative_batch_enabled() -> bool {
    !crate::env_flags::env_trim_eq("CHUMP_SPECULATIVE_BATCH", "0")
}

/// Remove "Using tool 'X' with input: {json}" lines from a reply so they don't surface in the UI.
fn strip_text_tool_call_lines(text: &str) -> String {
    let cleaned: Vec<&str> = text
        .lines()
        .filter(|l| {
            let t = l.trim();
            !(t.starts_with("Using tool '") && t.contains("' with input:"))
        })
        .collect();
    cleaned.join("\n").trim().to_string()
}

/// Mirror of axonerai agent format for assistant tool-use message.
fn format_tool_use(tool_calls: &[ToolCall]) -> String {
    tool_calls
        .iter()
        .map(|call| {
            format!(
                "Using tool '{}' with input: {}",
                call.name,
                serde_json::to_string(&call.input).unwrap_or_default()
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Mirror of axonerai agent format for tool results fed back to the LLM.
fn format_tool_results(results: &[ToolResult]) -> String {
    results
        .iter()
        .map(|r| format!("Tool '{}' returned: {}", r.tool_name, r.result))
        .collect::<Vec<_>>()
        .join("\n")
}

pub struct ChumpAgent {
    provider: Box<dyn Provider + Send + Sync>,
    registry: axonerai::tool::ToolRegistry,
    system_prompt: Option<String>,
    file_session_manager: Option<FileSessionManager>,
    event_tx: Option<EventSender>,
    max_iterations: usize,
}

impl ChumpAgent {
    pub fn new(
        provider: Box<dyn Provider + Send + Sync>,
        registry: axonerai::tool::ToolRegistry,
        system_prompt: Option<String>,
        file_session_manager: Option<FileSessionManager>,
        event_tx: Option<EventSender>,
        max_iterations: usize,
    ) -> Self {
        Self {
            provider,
            registry,
            system_prompt,
            file_session_manager,
            event_tx,
            max_iterations: max_iterations.clamp(1, 50),
        }
    }

    fn send(&self, event: AgentEvent) {
        if let Some(ref tx) = self.event_tx {
            let _ = tx.send(event);
        }
    }

    /// Execute tool calls one-by-one. When a tool is in CHUMP_TOOLS_ASK, request approval first; on deny/timeout inject a denied result.
    #[instrument(skip(self, executor, tool_calls), fields(tool_call_count = tool_calls.len()))]
    async fn execute_tool_calls_with_approval<'a>(
        &self,
        executor: &ToolExecutor<'a>,
        tool_calls: &[ToolCall],
    ) -> Result<Vec<ToolResult>> {
        let mut results = Vec::with_capacity(tool_calls.len());
        let timeout_secs = approval_timeout_secs();
        let auto_tools = tool_policy::auto_approve_tools_set();
        for tc in tool_calls {
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
                    if pending_peer_approval::peer_approve_tools().contains(&tc.name.to_lowercase())
                    {
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
                    self.send(AgentEvent::ToolApprovalRequest {
                        request_id: request_id.clone(),
                        tool_name: tc.name.clone(),
                        tool_input: tc.input.clone(),
                        risk_level: risk_level.clone(),
                        reason: reason.clone(),
                        expires_at_secs,
                    });
                    let approval_result =
                        tokio::time::timeout(std::time::Duration::from_secs(timeout_secs), rx)
                            .await;
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
                Ok(batch_results) => results.extend(batch_results),
                Err(e) => {
                    // Tool returned a hard Err (e.g. ambiguous edit_file old_str).
                    // Feed the error back as a tool result so the model can retry
                    // rather than crashing the whole agent run.
                    results.push(ToolResult {
                        tool_call_id: tc.id.clone(),
                        tool_name: tc.name.clone(),
                        result: format!("Tool error: {}", e),
                    });
                }
            }
        }
        Ok(results)
    }

    /// Run one user turn; load session, append user message, loop complete/tools, save, return final text.
    #[instrument(skip(self, user_prompt), fields(prompt_len = user_prompt.len()))]
    pub async fn run(&self, user_prompt: &str) -> Result<String> {
        let request_id = uuid::Uuid::new_v4().to_string();
        tracing::info!(request_id = %request_id, "agent_turn started");
        let turn_start = Instant::now();

        let mut session = if let Some(ref sm) = self.file_session_manager {
            if sm.exists() {
                sm.load()?
            } else {
                Session::new(sm.get_session().to_string())
            }
        } else {
            Session::new("stateless".to_string())
        };

        session.add_message(Message {
            role: "user".to_string(),
            content: user_prompt.to_string(),
        });

        self.send(AgentEvent::TurnStart {
            request_id: request_id.clone(),
            timestamp: format!(
                "{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs()
            ),
        });

        let executor = ToolExecutor::new(&self.registry);
        let tools = self.registry.get_all_for_llm();
        let mut model_calls_count: u32 = 0;
        let mut tool_calls_count: u32 = 0;
        let mut continuations: u32 = 0;
        const MAX_CONTINUATIONS: u32 = 1; // One extra batch per turn so user doesn't have to click "Keep going" as often

        loop {
            for _iter in 1..=self.max_iterations {
                let response = self
                    .provider
                    .complete(
                        session.get_messages().to_vec(),
                        Some(tools.clone()),
                        None,
                        self.system_prompt.clone(),
                    )
                    .await?;

                model_calls_count += 1;

                match response.stop_reason {
                    StopReason::EndTurn => {
                        let text = response
                            .text
                            .clone()
                            .unwrap_or_else(|| "(No response from agent)".to_string());

                        // Some models fall back to text-format tool calls on EndTurn instead of
                        // native function calls. Detect "Using tool 'X' with input: {json}" and
                        // execute them so the action isn't silently dropped.
                        if let Some(synthetic_calls) = parse_text_tool_calls(&text, &tools) {
                            if !synthetic_calls.is_empty() {
                                // Clear the raw tool-call text from the PWA bubble immediately.
                                self.send(AgentEvent::TextComplete {
                                    text: String::new(),
                                });
                                for tc in &synthetic_calls {
                                    self.send(AgentEvent::ToolCallStart {
                                        tool_name: tc.name.clone(),
                                        tool_input: tc.input.clone(),
                                        call_id: tc.id.clone(),
                                    });
                                }
                                let exec_start = Instant::now();
                                let tool_results = self
                                    .execute_tool_calls_with_approval(&executor, &synthetic_calls)
                                    .await?;
                                let exec_ms = exec_start.elapsed().as_millis() as u64;
                                tool_calls_count += tool_results.len() as u32;
                                for tr in &tool_results {
                                    let ok = !tr.result.starts_with("DENIED:")
                                        && !tr.result.starts_with("Tool error:");
                                    self.send(AgentEvent::ToolCallResult {
                                        call_id: tr.tool_call_id.clone(),
                                        tool_name: tr.tool_name.clone(),
                                        result: tr.result.clone(),
                                        duration_ms: exec_ms / tool_results.len().max(1) as u64,
                                        success: ok,
                                    });
                                }
                                session.add_message(Message {
                                    role: "assistant".to_string(),
                                    content: format_tool_use(&synthetic_calls),
                                });
                                session.add_message(Message {
                                    role: "user".to_string(),
                                    content: format_tool_results(&tool_results),
                                });
                                let sub = crate::consciousness_traits::substrate();
                                if sub.belief.should_escalate() {
                                    crate::blackboard::post(
                                    crate::blackboard::Module::Custom("belief_state".to_string()),
                                    "Epistemic uncertainty is critically high after synthetic tool calls. \
                                     Consider asking the user for guidance.".to_string(),
                                    crate::blackboard::SalienceFactors {
                                        novelty: 0.7,
                                        uncertainty_reduction: 0.8,
                                        goal_relevance: 0.9,
                                        urgency: 0.8,
                                    },
                                );
                                }
                                continue;
                            }
                        }

                        session.add_message(Message {
                            role: "assistant".to_string(),
                            content: text.clone(),
                        });
                        if let Some(ref sm) = self.file_session_manager {
                            sm.save(&session).map_err(anyhow::Error::from)?;
                        }
                        // Strip any residual text-format tool call lines from the displayed reply.
                        let display_text = strip_text_tool_call_lines(&text);
                        let turn_duration_ms = turn_start.elapsed().as_millis() as u64;
                        crate::precision_controller::record_turn_metrics(
                            tool_calls_count,
                            0,
                            turn_duration_ms,
                        );
                        self.send(AgentEvent::TurnComplete {
                            request_id: request_id.clone(),
                            full_text: display_text.clone(),
                            duration_ms: turn_duration_ms,
                            tool_calls_count,
                            model_calls_count,
                        });
                        return Ok(display_text);
                    }

                    StopReason::ToolUse => {
                        if let Some(ref t) = response.text {
                            if !t.is_empty() {
                                // Optional thinking text
                            }
                        }
                        if response.tool_calls.is_empty() {
                            let msg =
                                "Agent wanted to use tools but didn't specify any".to_string();
                            self.send(AgentEvent::TurnError {
                                request_id: request_id.clone(),
                                error: msg.clone(),
                            });
                            return Ok(msg);
                        }

                        for tc in &response.tool_calls {
                            self.send(AgentEvent::ToolCallStart {
                                tool_name: tc.name.clone(),
                                tool_input: tc.input.clone(),
                                call_id: tc.id.clone(),
                            });
                        }

                        let use_speculative =
                            speculative_batch_enabled() && response.tool_calls.len() >= 3;
                        let spec_snapshot = if use_speculative {
                            Some(crate::speculative_execution::fork())
                        } else {
                            None
                        };

                        let exec_start = Instant::now();
                        let tool_results = self
                            .execute_tool_calls_with_approval(&executor, &response.tool_calls)
                            .await?;
                        let exec_ms = exec_start.elapsed().as_millis() as u64;
                        tracing::info!(
                            duration_ms = exec_ms,
                            count = tool_results.len(),
                            "tools completed"
                        );
                        tool_calls_count += tool_results.len() as u32;

                        let mut spec_failures = Vec::new();
                        for tr in &tool_results {
                            let ok = !tr.result.starts_with("DENIED:")
                                && !tr.result.starts_with("Tool error:");
                            if !ok {
                                spec_failures.push(tr.tool_name.clone());
                            }
                            self.send(AgentEvent::ToolCallResult {
                                call_id: tr.tool_call_id.clone(),
                                tool_name: tr.tool_name.clone(),
                                result: tr.result.clone(),
                                duration_ms: exec_ms / tool_results.len().max(1) as u64,
                                success: ok,
                            });
                        }

                        if let Some(snapshot) = spec_snapshot {
                            let result = crate::speculative_execution::evaluate(
                                &snapshot,
                                tool_results.len() as u32,
                                &spec_failures,
                            );
                            let resolution = if result.success {
                                crate::speculative_execution::commit(snapshot);
                                tracing::info!(
                                    confidence_delta = result.confidence_delta,
                                    surprisal_ema_delta = result.surprisal_ema_delta,
                                    "speculative execution committed"
                                );
                                crate::speculative_execution::Resolution::Committed
                            } else {
                                crate::speculative_execution::rollback(snapshot);
                                tracing::warn!(
                                    failures = spec_failures.len(),
                                    confidence_delta = result.confidence_delta,
                                    surprisal_ema_delta = result.surprisal_ema_delta,
                                    "speculative execution rolled back"
                                );
                                crate::blackboard::post(
                                crate::blackboard::Module::Custom("speculative_execution".to_string()),
                                format!(
                                    "Multi-tool plan rolled back ({} failures out of {} tools, confidence delta {:.2}, surprisal EMA delta {:.3}). \
                                     Consider a different approach.",
                                    spec_failures.len(),
                                    tool_results.len(),
                                    result.confidence_delta,
                                    result.surprisal_ema_delta
                                ),
                                crate::blackboard::SalienceFactors {
                                    novelty: 0.8,
                                    uncertainty_reduction: 0.7,
                                    goal_relevance: 0.9,
                                    urgency: 0.7,
                                },
                            );
                                crate::speculative_execution::Resolution::RolledBack
                            };
                            crate::speculative_execution::record_last_speculative_batch(
                                resolution, result,
                            );
                        }

                        session.add_message(Message {
                            role: "assistant".to_string(),
                            content: format_tool_use(&response.tool_calls),
                        });
                        session.add_message(Message {
                            role: "user".to_string(),
                            content: format_tool_results(&tool_results),
                        });

                        let sub = crate::consciousness_traits::substrate();
                        sub.neuromod.update_from_turn();

                        if sub.belief.should_escalate() {
                            crate::blackboard::post(
                            crate::blackboard::Module::Custom("belief_state".to_string()),
                            format!(
                                "Epistemic uncertainty is critically high (task uncertainty={:.2}). \
                                 Consider asking the user to clarify the goal or confirm the approach \
                                 before continuing.",
                                sub.belief.task_uncertainty()
                            ),
                            crate::blackboard::SalienceFactors {
                                novelty: 0.7,
                                uncertainty_reduction: 0.8,
                                goal_relevance: 0.9,
                                urgency: 0.8,
                            },
                        );
                        }
                    }

                    StopReason::MaxTokens => {
                        let msg = "Agent hit max tokens limit".to_string();
                        self.send(AgentEvent::TurnError {
                            request_id: request_id.clone(),
                            error: msg.clone(),
                        });
                        return Ok(msg);
                    }

                    _ => {
                        let msg = format!("Agent stopped with reason: {:?}", response.stop_reason);
                        self.send(AgentEvent::TurnError {
                            request_id: request_id.clone(),
                            error: msg.clone(),
                        });
                        return Ok(msg);
                    }
                }
            }

            if let Some(ref sm) = self.file_session_manager {
                sm.save(&session).map_err(anyhow::Error::from)?;
            }
            if continuations >= MAX_CONTINUATIONS {
                break;
            }
            continuations += 1;
            session.add_message(Message {
                role: "user".to_string(),
                content: "Continue. Summarize progress in one sentence and do the next steps."
                    .to_string(),
            });
            self.send(AgentEvent::TextComplete {
                text: "(continuing…)".to_string(),
            });
        }

        let msg = format!("Agent reached max iterations ({})", self.max_iterations);
        self.send(AgentEvent::TurnComplete {
            request_id,
            full_text: msg.clone(),
            duration_ms: turn_start.elapsed().as_millis() as u64,
            tool_calls_count,
            model_calls_count,
        });
        Ok(msg)
    }
}
