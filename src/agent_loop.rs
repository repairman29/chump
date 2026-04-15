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

/// Heuristic: does this user message look like it needs tool calls?
/// Short conversational messages (greetings, simple questions) don't need tools.
/// Returns false for messages that are clearly just chat.
fn message_likely_needs_tools(msg: &str) -> bool {
    let trimmed = msg.trim();
    let lower = trimmed.to_lowercase();

    // Check for action keywords that signal tool use, regardless of length.
    let action_words = [
        "run ", "create ", "make ", "task ", "schedule ", "read ", "write ", "list ",
        "show ", "file ", "git ", "cargo ", "commit", "push", "deploy",
        "install", "build", "test ", "check ", "fix ", "update ", "delete",
        "search ", "find ", "open ", "edit ", "patch", "review", "reboot",
        "notify", "remind", "calculate", "status", "what time", "what date",
        "how many", "how much", "look up", "look at", "save ", "generate ",
        "add ", "remove ", "set up", "setup", "configure",
    ];
    if action_words.iter().any(|w| lower.contains(w)) {
        return true;
    }

    // Question marks in longer messages often mean the user wants info that
    // might need tools (file reads, searches, etc.), but short questions
    // ("how are you?", "what's up?") usually don't.
    if trimmed.len() > 80 && trimmed.contains('?') {
        return true;
    }

    false
}

/// Neuromodulation-aware wrapper around [`message_likely_needs_tools`].
///
/// When serotonin is low (impulsive), the agent is biased toward quick responses —
/// the question-mark length threshold for "needs tools" is raised (more messages
/// skip tools). When serotonin is high (patient), the threshold is lowered (more
/// messages get tools). This wires neuromodulation directly into the agent loop's
/// fastest decision point.
fn message_likely_needs_tools_neuromod(msg: &str) -> bool {
    // First check: action keywords always trigger tools regardless of neuromod state.
    let trimmed = msg.trim();
    let lower = trimmed.to_lowercase();
    let action_words = [
        "run ", "create ", "make ", "task ", "schedule ", "read ", "write ", "list ",
        "show ", "file ", "git ", "cargo ", "commit", "push", "deploy",
        "install", "build", "test ", "check ", "fix ", "update ", "delete",
        "search ", "find ", "open ", "edit ", "patch", "review", "reboot",
        "notify", "remind", "calculate", "status", "what time", "what date",
        "how many", "how much", "look up", "look at", "save ", "generate ",
        "add ", "remove ", "set up", "setup", "configure",
    ];
    if action_words.iter().any(|w| lower.contains(w)) {
        return true;
    }

    // Neuromod-adjusted question threshold: base=80 chars.
    // Low serotonin (impulsive, <0.7) → threshold up to 120 (skip more).
    // High serotonin (patient, >1.3) → threshold down to 50 (use tools more).
    let sero = crate::neuromodulation::levels().serotonin;
    let q_threshold = (80.0 + (1.0 - sero) * 50.0).clamp(40.0, 150.0) as usize;
    if trimmed.len() > q_threshold && trimmed.contains('?') {
        return true;
    }

    false
}

/// Detect when a tool-free response indicates the model wanted to use tools
/// but couldn't (e.g. "I'll list your tasks", "Let me check", "listing tasks").
/// Returns true if the response should be discarded and retried with tools.
fn response_wanted_tools(text: &str) -> bool {
    let lower = text.to_lowercase();
    let narration_signals = [
        // Intent narration — model says what it would do instead of doing it
        "i'll ", "i will ", "let me ", "i'm going to ",
        // Action narration — model claims actions were performed
        "listing ", "checking ", "searching ", "looking up", "reading ",
        "running ", "creating ", "generating ", "writing ", "saving ",
        "saved as ", "saved in ", "saved to ", "the file path is",
        "open it to view", "here is the file",
        // Offers instead of actions
        "i can help", "i can list", "i can show", "i can check",
        "i can create", "i can make", "i can write",
        "here are your", "here's your", "let me find",
        // Inability signals
        "i'd need to", "i would need to", "i don't have access",
        "i can't access", "i cannot access",
        // False completion claims
        "done!", "all set", "file has been created", "has been saved",
        "successfully created", "i've created", "i've saved", "i've written",
    ];
    narration_signals.iter().any(|s| lower.contains(s))
}

/// Compact tool definitions for light interactive mode.
/// Strips property-level "description" fields from schemas and truncates tool descriptions
/// to reduce prompt token count in Ollama's chat template expansion.
fn compact_tools_for_light(tools: Vec<axonerai::provider::Tool>) -> Vec<axonerai::provider::Tool> {
    tools
        .into_iter()
        .map(|mut t| {
            // Truncate description to first sentence (up to ~120 chars).
            if let Some(pos) = t.description.find(". ") {
                t.description.truncate(pos + 1);
            } else if t.description.len() > 120 {
                t.description.truncate(120);
            }

            // Strip "description" from each property in the schema to save tokens.
            if let Some(props) = t.input_schema.get_mut("properties") {
                if let Some(obj) = props.as_object_mut() {
                    for (_key, val) in obj.iter_mut() {
                        if let Some(prop_obj) = val.as_object_mut() {
                            prop_obj.remove("description");
                        }
                    }
                }
            }

            t
        })
        .collect()
}

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
/// Matches lines like: `Using tool 'name' with input: {json}` or the common shorthand
/// `Using tool 'name' with action: list` (maps to `{"action":"list"}`).
/// Returns `Some(calls)` if any are found and all match registered tool names; `None` otherwise.
fn parse_text_tool_calls(text: &str, tools: &[axonerai::provider::Tool]) -> Option<Vec<ToolCall>> {
    tracing::debug!(len = text.len(), "parse_text_tool_calls");
    let known: std::collections::HashSet<&str> = tools.iter().map(|t| t.name.as_str()).collect();
    let mut calls = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("Using tool '") else {
            continue;
        };
        let Some(name_end) = rest.find('\'') else {
            continue;
        };
        let name = &rest[..name_end];
        if !known.contains(name) {
            continue;
        }
        let tail = rest[name_end + 1..].trim_start();
        if let Some(json_part) = tail.strip_prefix("with input:") {
            let json_part = json_part.trim();
            if let Ok(input) = serde_json::from_str::<serde_json::Value>(json_part) {
                calls.push(ToolCall {
                    id: format!("txt_{}", uuid::Uuid::new_v4().simple()),
                    name: name.to_string(),
                    input,
                });
            }
        } else if let Some(action_tail) = tail.strip_prefix("with action:") {
            let mut v = action_tail.trim();
            v = v.trim_end_matches(['.', '…', '`', '"', ')']);
            let input = if v.starts_with('{') {
                serde_json::from_str::<serde_json::Value>(v).unwrap_or_else(|_| {
                    serde_json::json!({ "action": v.split_whitespace().next().unwrap_or("list") })
                })
            } else {
                let action = v
                    .split_whitespace()
                    .next()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("list");
                serde_json::json!({ "action": action })
            };
            calls.push(ToolCall {
                id: format!("txt_{}", uuid::Uuid::new_v4().simple()),
                name: name.to_string(),
                input,
            });
        }
    }
    if calls.is_empty() {
        None
    } else {
        Some(calls)
    }
}

/// Reorder tool calls by Expected Free Energy score (lowest G = most valuable first).
/// Applies epsilon-greedy exploration when in Explore regime — occasionally promotes
/// a lower-ranked tool to gather information about less-known tools.
/// Only reorders when there are 2+ calls; single calls pass through unchanged.
fn efe_order_tool_calls(calls: &[ToolCall]) -> Vec<ToolCall> {
    if calls.len() <= 1 {
        return calls.to_vec();
    }
    let names: Vec<&str> = calls.iter().map(|c| c.name.as_str()).collect();
    let scores = crate::belief_state::score_tools(&names);
    if scores.is_empty() {
        return calls.to_vec();
    }

    // Build ordering from EFE scores (sorted by G ascending = best first).
    let mut ordered: Vec<ToolCall> = scores
        .iter()
        .filter_map(|s| calls.iter().find(|c| c.name == s.tool_name))
        .cloned()
        .collect();

    // Epsilon-greedy: in Explore regime, occasionally swap the first tool with a random one.
    if ordered.len() > 1 {
        let selected = crate::precision_controller::epsilon_greedy_select(ordered.len());
        if selected != 0 {
            ordered.swap(0, selected);
            tracing::debug!(
                promoted = %ordered[0].name,
                "epsilon-greedy exploration: promoted tool to first position"
            );
        }
    }

    // Log when ordering differs from the model's original order.
    if ordered.len() > 1 && ordered[0].name != calls[0].name {
        tracing::info!(
            original_first = %calls[0].name,
            efe_first = %ordered[0].name,
            "EFE reordered tool execution"
        );
    }

    ordered
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
        let light = crate::env_flags::light_interactive_active();
        let tools = {
            let raw = self.registry.get_all_for_llm();
            if light {
                compact_tools_for_light(raw)
            } else {
                raw
            }
        };
        // Tool-free fast path: in light mode, skip tools for simple chat messages.
        // Saves ~1000+ prompt tokens (Ollama XML template expansion) → sub-2s responses.
        // Neuromodulation influence: low serotonin (impulsive) widens the fast path
        // threshold — even slightly ambiguous messages skip tools for faster response.
        // High serotonin (patient) narrows it — only clearly conversational messages skip.
        let skip_tools_first_call = light && !message_likely_needs_tools_neuromod(user_prompt);
        if skip_tools_first_call {
            tracing::info!("light tool-free fast path: skipping tools for simple message");
        }
        let mut model_calls_count: u32 = 0;
        let mut tool_calls_count: u32 = 0;
        let mut thinking_segments: Vec<String> = Vec::new();

        let completion_cap = crate::env_flags::agent_completion_max_tokens();
        for _iter in 1..=self.max_iterations {
            // Decay belief freshness each iteration (models "staleness" of our environment model).
            crate::belief_state::decay_turn();

            // First call: skip tools if heuristic says message is simple chat.
            // Subsequent calls (after tool use) always include tools.
            let tools_for_call = if skip_tools_first_call && model_calls_count == 0 {
                None
            } else {
                Some(tools.clone())
            };
            // When tools are withheld, append a guard to the system prompt so the
            // LLM doesn't hallucinate actions it can't perform.
            let system_for_call = if tools_for_call.is_none() {
                let guard = "\n\nIMPORTANT: You do NOT have tools available for this message. \
                    Answer the user directly. Do NOT claim to create files, run commands, \
                    or perform any actions. Do NOT say \"Creating...\", \"Saved as...\", \
                    or narrate actions you cannot take. If the user asks you to do something \
                    that requires tools, tell them you'll need to use your tools and ask \
                    them to rephrase or confirm.";
                match &effective_system {
                    Some(s) => Some(format!("{}{}", s, guard)),
                    None => Some(guard.to_string()),
                }
            } else {
                effective_system.clone()
            };
            let response = self
                .provider
                .complete(
                    session.get_messages().to_vec(),
                    tools_for_call,
                    completion_cap,
                    system_for_call,
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

                    // Auto-retry: if the model narrated an action instead of calling
                    // a tool, discard this response and retry with tools enabled.
                    // This catches both (a) tool-free fast path where tools were
                    // withheld and (b) cases where tools were available but the LLM
                    // hallucinated actions in text instead of making tool calls.
                    // Only retry once to avoid infinite loops.
                    if model_calls_count <= 2 && response_wanted_tools(payload) {
                        tracing::info!(
                            "narration detected (calls={}): retrying with tools",
                            model_calls_count
                        );
                        continue;
                    }

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

                    // EFE-based tool ordering: score candidate tools by Expected Free Energy
                    // and reorder execution so highest-value (lowest G) tools run first.
                    // In Explore regime, epsilon-greedy may promote a lower-ranked tool.
                    let ordered_tool_calls = efe_order_tool_calls(&response.tool_calls);

                    let use_speculative =
                        speculative_batch_enabled() && ordered_tool_calls.len() >= 3;
                    let spec_snapshot = if use_speculative {
                        Some(crate::speculative_execution::fork())
                    } else {
                        None
                    };

                    let exec_start = Instant::now();
                    let tool_results = self
                        .executor
                        .execute_all(self.event_tx.as_ref(), &executor, &ordered_tool_calls)
                        .await?;
                    let exec_ms = exec_start.elapsed().as_millis() as u64;
                    tracing::info!(
                        duration_ms = exec_ms,
                        count = tool_results.len(),
                        "tools completed"
                    );
                    tool_calls_count += tool_results.len() as u32;

                    let mut spec_failures = Vec::new();
                    let per_tool_ms = exec_ms / tool_results.len().max(1) as u64;
                    for (tr, tc) in tool_results.iter().zip(ordered_tool_calls.iter()) {
                        let ok = !tr.result.starts_with("DENIED:")
                            && !tr.result.starts_with("Tool error:");
                        if !ok {
                            spec_failures.push(tr.tool_name.clone());
                        }

                        // Update belief state and surprise tracker for each tool result.
                        let outcome = if ok { "ok" } else { "error" };
                        let expected_lat = crate::belief_state::tool_belief(&tc.name)
                            .map(|b| b.latency_mean_ms as u64)
                            .unwrap_or(500);
                        crate::belief_state::update_tool_belief(&tc.name, ok, per_tool_ms);
                        crate::surprise_tracker::record_prediction(
                            &tc.name, outcome, per_tool_ms, expected_lat,
                        );

                        self.send(AgentEvent::ToolCallResult {
                            call_id: tr.tool_call_id.clone(),
                            tool_name: tr.tool_name.clone(),
                            result: tr.result.clone(),
                            duration_ms: per_tool_ms,
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
                        content: format_tool_use(&ordered_tool_calls),
                    });
                    session.add_message(Message {
                        role: "user".to_string(),
                        content: format_tool_results(&tool_results),
                    });

                    let sub = crate::consciousness_traits::substrate();
                    sub.neuromod.update_from_turn();
                    crate::precision_controller::check_regime_change();

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

#[cfg(test)]
mod parse_text_tool_call_tests {
    use super::parse_text_tool_calls;
    use axonerai::provider::Tool;
    use serde_json::json;

    fn tools_task_only() -> Vec<Tool> {
        vec![Tool {
            name: "task".to_string(),
            description: "t".to_string(),
            input_schema: json!({}),
        }]
    }

    #[test]
    fn with_action_list_yields_task_list() {
        let tools = tools_task_only();
        let text = "Sure.\nUsing tool 'task' with action: list\n";
        let calls = parse_text_tool_calls(text, &tools).expect("parsed");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].name, "task");
        assert_eq!(calls[0].input, json!({ "action": "list" }));
    }

    #[test]
    fn with_input_still_works() {
        let tools = tools_task_only();
        let text = "Using tool 'task' with input: {\"action\":\"list\"}\n";
        let calls = parse_text_tool_calls(text, &tools).expect("parsed");
        assert_eq!(
            calls[0].input.get("action").and_then(|v| v.as_str()),
            Some("list")
        );
    }
}
