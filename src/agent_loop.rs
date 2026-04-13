//! Own agent run loop with optional event streaming. Replaces axonerai Agent::run when we need
//! SSE (web) or a single place to add keepalive/streaming. Uses Session + FileSessionManager
//! and the same message format (format_tool_use / format_tool_results) as axonerai.
//! When CHUMP_TOOLS_ASK is set, tools in that set require approval before execution.

use anyhow::Result;
use axonerai::executor::{ToolExecutor, ToolResult};
use axonerai::file_session_manager::FileSessionManager;
use axonerai::provider::{Message, Provider, StopReason, ToolCall};
use axonerai::session::Session;
use std::sync::Arc;
use std::time::Instant;
use tracing::instrument;

use crate::agent_session;
use crate::agent_turn;
use crate::cluster_mesh;
use crate::stream_events::{AgentEvent, EventSender};
use crate::task_db;
use crate::task_executor;
use crate::thinking_strip;

struct ClearWebSessionOnDrop;
impl Drop for ClearWebSessionOnDrop {
    fn drop(&mut self) {
        agent_session::set_active_session_id(None);
    }
}

/// Result of [`ChumpAgent::run`]: user-visible `reply` plus optional `<thinking>` extracts per model round.
#[derive(Debug, Clone)]
pub struct AgentRunOutcome {
    pub reply: String,
    pub thinking_segments: Vec<String>,
}

impl AgentRunOutcome {
    /// Join segments with a delimiter suitable for DB / SSE.
    pub fn thinking_joined(&self) -> Option<String> {
        joined_thinking_option(&self.thinking_segments)
    }
}

fn joined_thinking_option(segments: &[String]) -> Option<String> {
    if segments.is_empty() {
        None
    } else {
        Some(segments.join("\n---\n"))
    }
}

fn push_thinking_segment(segments: &mut Vec<String>, mono: Option<String>) {
    if let Some(s) = mono {
        if !s.trim().is_empty() {
            segments.push(s);
        }
    }
}

fn log_thinking_extracted(context: &'static str, m: &str) {
    if m.trim().is_empty() {
        return;
    }
    let pv = thinking_strip::preview_for_log(m);
    tracing::info!(
        context,
        chars = pv.full_len,
        truncated = pv.truncated,
        thinking = %pv.preview,
        "extracted thinking block"
    );
}

/// Detect text-format tool calls emitted by models that don't use native function calling.
/// Matches lines like: `Using tool 'name' with input: {json}`
/// Returns `Some(calls)` if any are found and all match registered tool names; `None` otherwise.
fn parse_text_tool_calls(text: &str, tools: &[axonerai::provider::Tool]) -> Option<Vec<ToolCall>> {
    tracing::debug!(len = text.len(), "parse_text_tool_calls");
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
    executor: Arc<dyn task_executor::TaskExecutor + Send + Sync>,
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
            executor: task_executor::default_task_executor(),
        }
    }

    fn send(&self, event: AgentEvent) {
        if let Some(ref tx) = self.event_tx {
            let _ = tx.send(event);
        }
    }

    /// Text-format tool lines after optional `<thinking>` — same execution path as `EndTurn` synthetic tools.
    async fn run_synthetic_tool_batch(
        &self,
        synthetic_calls: Vec<ToolCall>,
        session: &mut Session,
        executor: &ToolExecutor<'_>,
        tool_calls_count: &mut u32,
    ) -> Result<()> {
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
            .executor
            .execute_all(self.event_tx.as_ref(), executor, &synthetic_calls)
            .await?;
        let exec_ms = exec_start.elapsed().as_millis() as u64;
        *tool_calls_count += tool_results.len() as u32;
        for tr in &tool_results {
            let ok = !tr.result.starts_with("DENIED:") && !tr.result.starts_with("Tool error:");
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
                 Consider asking the user for guidance."
                    .to_string(),
                crate::blackboard::SalienceFactors {
                    novelty: 0.7,
                    uncertainty_reduction: 0.8,
                    goal_relevance: 0.9,
                    urgency: 0.8,
                },
            );
        }
        Ok(())
    }

    /// Run one user turn; load session, append user message, loop complete/tools, save, return final text and thinking.
    #[instrument(skip(self, user_prompt), fields(prompt_len = user_prompt.len()))]
    pub async fn run(&self, user_prompt: &str) -> Result<AgentRunOutcome> {
        cluster_mesh::ensure_probed_once().await;
        let _clear_web_session = ClearWebSessionOnDrop;
        let _turn_id = agent_turn::begin_turn();
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

        if let Some(ref sm) = self.file_session_manager {
            agent_session::set_active_session_id(Some(sm.get_session()));
        } else {
            agent_session::set_active_session_id(None);
        }

        let mut effective_system = self.system_prompt.clone();
        if task_db::task_available() {
            if let Ok(Some(block)) = task_db::planner_active_prompt_block() {
                effective_system = match effective_system {
                    Some(s) if !s.trim().is_empty() => Some(format!("{}\n\n{}", s, block)),
                    _ => Some(block),
                };
            }
        }

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
        let mut thinking_segments: Vec<String> = Vec::new();

        for _iter in 1..=self.max_iterations {
            let response = self
                .provider
                .complete(
                    session.get_messages().to_vec(),
                    Some(tools.clone()),
                    None,
                    effective_system.clone(),
                )
                .await?;

            model_calls_count += 1;

            match response.stop_reason {
                StopReason::EndTurn => {
                    let text = response
                        .text
                        .clone()
                        .unwrap_or_else(|| "(No response from agent)".to_string());

                    let (plan_opt, thinking_opt, payload) =
                        thinking_strip::peel_plan_and_thinking_for_tools(&text);
                    if let Some(m) = &plan_opt {
                        log_thinking_extracted("EndTurn-plan", m);
                    }
                    push_thinking_segment(&mut thinking_segments, plan_opt);
                    if let Some(m) = &thinking_opt {
                        log_thinking_extracted("EndTurn", m);
                    }
                    push_thinking_segment(&mut thinking_segments, thinking_opt);

                    // Some models fall back to text-format tool calls on EndTurn instead of
                    // native function calls. Detect "Using tool 'X' with input: {json}" and
                    // execute them so the action isn't silently dropped.
                    if let Some(synthetic_calls) = parse_text_tool_calls(payload, &tools) {
                        if !synthetic_calls.is_empty() {
                            self.run_synthetic_tool_batch(
                                synthetic_calls,
                                &mut session,
                                &executor,
                                &mut tool_calls_count,
                            )
                            .await?;
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
                    let display_text = thinking_strip::strip_for_streaming_preview(&text);
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
                        thinking_monologue: joined_thinking_option(&thinking_segments),
                    });
                    return Ok(AgentRunOutcome {
                        reply: display_text,
                        thinking_segments,
                    });
                }

                StopReason::ToolUse => {
                    let text_content = response.text.clone().unwrap_or_default();
                    let (plan_opt, thinking_opt, payload) =
                        thinking_strip::peel_plan_and_thinking_for_tools(&text_content);
                    if let Some(m) = &plan_opt {
                        log_thinking_extracted("ToolUse-plan", m);
                    }
                    push_thinking_segment(&mut thinking_segments, plan_opt);
                    if let Some(m) = &thinking_opt {
                        log_thinking_extracted("ToolUse", m);
                    }
                    push_thinking_segment(&mut thinking_segments, thinking_opt);

                    if response.tool_calls.is_empty() {
                        let parse_src = if payload.is_empty() {
                            text_content.as_str()
                        } else {
                            payload
                        };
                        if let Some(synthetic_calls) = parse_text_tool_calls(parse_src, &tools) {
                            if !synthetic_calls.is_empty() {
                                self.run_synthetic_tool_batch(
                                    synthetic_calls,
                                    &mut session,
                                    &executor,
                                    &mut tool_calls_count,
                                )
                                .await?;
                                continue;
                            }
                        }
                        let msg = crate::user_error_hints::append_agent_error_hints(
                            "Agent wanted to use tools but didn't specify any — the model may need a smaller prompt or a model that follows native tool calling reliably.",
                        );
                        self.send(AgentEvent::TurnError {
                            request_id: request_id.clone(),
                            error: msg.clone(),
                        });
                        return Ok(AgentRunOutcome {
                            reply: msg,
                            thinking_segments,
                        });
                    }

                    if !payload.trim().is_empty() {
                        let pv = thinking_strip::preview_for_log(payload);
                        tracing::debug!(
                            tail_chars = pv.full_len,
                            truncated = pv.truncated,
                            tail = %pv.preview,
                            "ToolUse assistant text after thinking (native tool_calls present; not executed as extra tools)"
                        );
                    }

                    for tc in &response.tool_calls {
                        self.send(AgentEvent::ToolCallStart {
                            tool_name: tc.name.clone(),
                            tool_input: tc.input.clone(),
                            call_id: tc.id.clone(),
                        });
                    }

                    let schema_failures =
                        crate::tool_input_schema_validate::collect_schema_validation_failures(
                            &self.registry,
                            &response.tool_calls,
                        );
                    if !schema_failures.is_empty() {
                        if std::env::var("CHUMP_VECTOR6_VERIFY").ok().as_deref() == Some("1") {
                            tracing::warn!(
                                    "VECTOR6_MARK_A: schema pre-flight blocked native tool batch (synthetic ToolResult emitted)"
                                );
                        }
                        tracing::warn!(
                                count = schema_failures.len(),
                                "schema pre-flight: tool executor skipped (batch blocked before execution)"
                            );
                        for tc in &response.tool_calls {
                            let input_json = serde_json::to_string(&tc.input)
                                .unwrap_or_else(|_| "<non-serializable input>".into());
                            tracing::warn!(
                                tool = %tc.name,
                                call_id = %tc.id,
                                input = %input_json,
                                "schema pre-flight: model ToolCall input (rejected batch; not executed)"
                            );
                        }
                        let tool_results =
                                crate::tool_input_schema_validate::synthetic_tool_results_for_schema_failures(
                                    &response.tool_calls,
                                    &schema_failures,
                                );
                        tracing::warn!(
                                count = schema_failures.len(),
                                "tool batch failed JSON schema pre-flight; feeding synthetic errors to model"
                            );
                        tool_calls_count += tool_results.len() as u32;
                        for tr in &tool_results {
                            tracing::warn!(
                                tool = %tr.tool_name,
                                call_id = %tr.tool_call_id,
                                result = %tr.result,
                                "schema pre-flight: synthetic ToolResult for model retry"
                            );
                            self.send(AgentEvent::ToolCallResult {
                                call_id: tr.tool_call_id.clone(),
                                tool_name: tr.tool_name.clone(),
                                result: tr.result.clone(),
                                duration_ms: 0,
                                success: false,
                            });
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
                        tracing::info!(
                                "schema pre-flight: continuing same user turn (next provider.complete for self-correction; <thinking> if model emits it)"
                            );
                        continue;
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
                        .executor
                        .execute_all(self.event_tx.as_ref(), &executor, &response.tool_calls)
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
                    let msg = crate::user_error_hints::append_agent_error_hints(
                        "Agent hit max tokens limit for this completion.",
                    );
                    self.send(AgentEvent::TurnError {
                        request_id: request_id.clone(),
                        error: msg.clone(),
                    });
                    return Ok(AgentRunOutcome {
                        reply: msg,
                        thinking_segments,
                    });
                }

                _ => {
                    let msg = crate::user_error_hints::append_agent_error_hints(&format!(
                        "Agent stopped with reason: {:?}",
                        response.stop_reason
                    ));
                    self.send(AgentEvent::TurnError {
                        request_id: request_id.clone(),
                        error: msg.clone(),
                    });
                    return Ok(AgentRunOutcome {
                        reply: msg,
                        thinking_segments,
                    });
                }
            }
        }

        if let Some(ref sm) = self.file_session_manager {
            sm.save(&session).map_err(anyhow::Error::from)?;
        }

        let msg = format!("Agent reached max iterations ({})", self.max_iterations);
        self.send(AgentEvent::TurnComplete {
            request_id,
            full_text: msg.clone(),
            duration_ms: turn_start.elapsed().as_millis() as u64,
            tool_calls_count,
            model_calls_count,
            thinking_monologue: joined_thinking_option(&thinking_segments),
        });
        Ok(AgentRunOutcome {
            reply: msg,
            thinking_segments,
        })
    }
}
