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
        "run ",
        "create ",
        "make ",
        "task ",
        "schedule ",
        "read ",
        "write ",
        "list ",
        "show ",
        "file ",
        "git ",
        "cargo ",
        "commit",
        "push",
        "deploy",
        "install",
        "build",
        "test ",
        "check ",
        "fix ",
        "update ",
        "delete",
        "search ",
        "find ",
        "open ",
        "edit ",
        "patch",
        "review",
        "reboot",
        "notify",
        "remind",
        "calculate",
        "status",
        "what time",
        "what date",
        "how many",
        "how much",
        "look up",
        "look at",
        "save ",
        "generate ",
        "add ",
        "remove ",
        "set up",
        "setup",
        "configure",
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

/// Determine if a message likely needs tools. Biased toward YES — only skip for
/// clearly trivial messages (greetings, single words, short chitchat). A 7B model
/// with tools available is better than a 7B without tools guessing.
///
/// Neuromod influence: serotonin adjusts the "trivial" length threshold.
fn message_likely_needs_tools_neuromod(msg: &str) -> bool {
    let trimmed = msg.trim();
    let lower = trimmed.to_lowercase();

    // Action keywords always trigger tools.
    let action_words = [
        "run ",
        "create ",
        "make ",
        "task ",
        "schedule ",
        "read ",
        "write ",
        "list ",
        "show ",
        "file ",
        "git ",
        "cargo ",
        "commit",
        "push",
        "deploy",
        "install",
        "build",
        "test ",
        "check ",
        "fix ",
        "update ",
        "delete",
        "search ",
        "find ",
        "open ",
        "edit ",
        "patch",
        "review",
        "reboot",
        "notify",
        "remind",
        "calculate",
        "status",
        "what time",
        "what date",
        "how many",
        "how much",
        "look up",
        "look at",
        "save ",
        "generate ",
        "add ",
        "remove ",
        "set up",
        "setup",
        "configure",
        "remember",
        "tell me",
        "give me",
        "get ",
        "fetch",
        "start ",
        "stop ",
        "do ",
        "help me",
        "can you",
        "please ",
        "work on",
        "switch to",
        "close ",
        "complete ",
        "finish ",
        "done ",
        "mark ",
        "write a ",
        "create a ",
        "make a ",
        "save a ",
        "put ",
    ];
    if action_words.iter().any(|w| lower.contains(w)) {
        return true;
    }

    // Questions almost always need tools — lower the bar significantly.
    if trimmed.contains('?') && trimmed.len() > 10 {
        return true;
    }

    // Any message with more than 2 words gets tools — only skip single-word
    // greetings like "hi", "hello", "ok", "thanks", "test", "hey".
    // Previous threshold of 30-60 chars was too aggressive and caused 7B models
    // to narrate actions instead of calling tools.
    let word_count = trimmed.split_whitespace().count();
    if word_count > 2 {
        return true;
    }

    // Even short messages: if they look like a command, give tools.
    // "list tasks", "show tasks", "close 5", etc.
    if word_count == 2 {
        return true;
    }

    // Single word without action keywords — likely a greeting.
    false
}

/// Detect when a tool-free response indicates the model wanted to use tools
/// but couldn't (e.g. "I'll list your tasks", "Let me check", "listing tasks").
/// Returns true if the response should be discarded and retried with tools.
fn response_wanted_tools(text: &str) -> bool {
    let lower = text.to_lowercase();
    let narration_signals = [
        // Intent narration — model says what it would do instead of doing it
        "i'll ",
        "i will ",
        "let me ",
        "i'm going to ",
        // Action narration — model claims actions were performed
        "listing ",
        "checking ",
        "searching ",
        "looking up",
        "reading ",
        "running ",
        "creating ",
        "generating ",
        "writing ",
        "saving ",
        "saved as ",
        "saved in ",
        "saved to ",
        "the file path is",
        "open it to view",
        "here is the file",
        // Offers instead of actions
        "i can help",
        "i can list",
        "i can show",
        "i can check",
        "i can create",
        "i can make",
        "i can write",
        "here are your",
        "here's your",
        "let me find",
        // Inability signals
        "i'd need to",
        "i would need to",
        "i don't have access",
        "i can't access",
        "i cannot access",
        // False completion claims
        "done!",
        "all set",
        "file has been created",
        "has been saved",
        "successfully created",
        "i've created",
        "i've saved",
        "i've written",
        // 7B-specific hallucination patterns
        "would you like me to",
        "shall i ",
        "should i ",
        "to do this, i",
        "to accomplish this",
        "unfortunately, i",
        "unfortunately i",
        "i need to use",
        "i need access to",
        "using the ",
        "by using ",
        "with the tool",
        "call the ",
        "calling the ",
        "executing ",
        "executed the ",
    ];
    narration_signals.iter().any(|s| lower.contains(s))
}

/// Compact tool definitions for light interactive mode.
/// Truncate tool descriptions for light mode. Keeps parameter descriptions intact
/// so 7B models can understand what each parameter does.
fn compact_tools_for_light(tools: Vec<axonerai::provider::Tool>) -> Vec<axonerai::provider::Tool> {
    tools
        .into_iter()
        .map(|mut t| {
            // Truncate description to first two sentences (up to ~200 chars).
            // Keep enough for the model to understand when to use each tool.
            if let Some(pos) = t.description.find(". ") {
                // Look for a second sentence boundary for slightly more context.
                if let Some(pos2) = t.description[pos + 2..].find(". ") {
                    t.description.truncate(pos + 2 + pos2 + 1);
                }
                // Still cap at 200 chars to avoid bloat.
                if t.description.len() > 200 {
                    t.description.truncate(200);
                }
            } else if t.description.len() > 200 {
                t.description.truncate(200);
            }

            // Keep parameter descriptions — 7B models need them to construct valid calls.

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
/// Also matches common 7B variations: lowercase, backtick-quoted names, "calling tool",
/// and bare `tool_name({json})` function-call syntax.
/// Returns `Some(calls)` if any are found and all match registered tool names; `None` otherwise.
fn parse_text_tool_calls(text: &str, tools: &[axonerai::provider::Tool]) -> Option<Vec<ToolCall>> {
    tracing::debug!(len = text.len(), "parse_text_tool_calls");
    let known: std::collections::HashSet<&str> = tools.iter().map(|t| t.name.as_str()).collect();
    let mut calls = Vec::new();
    for raw_line in text.lines() {
        // 7B models sometimes jam multiple calls on one line with ";"
        // e.g. "call X with {...}; call Y with {...}"
        // Split on "; call " to handle this.
        let segments: Vec<&str> = raw_line.split("; call ").collect();
        for (i, seg) in segments.iter().enumerate() {
            // Re-prepend "call " for segments after the first split
            let owned;
            let line: &str = if i > 0 {
                owned = format!("call {seg}");
                owned.trim()
            } else {
                seg.trim()
            };
            // Try multiple prefix patterns that 7B models commonly emit:
            // "Using tool 'X'", "Calling tool 'X'", "call X", "tool: X"
            let (name, tail) = if let Some(rest) = strip_prefix_caseless(line, "using tool ")
                .or_else(|| strip_prefix_caseless(line, "calling tool "))
                .or_else(|| strip_prefix_caseless(line, "call tool "))
                .or_else(|| strip_prefix_caseless(line, "call "))
            {
                extract_tool_name_and_tail(rest)
            } else if let Some(rest) = strip_prefix_caseless(line, "tool: ") {
                extract_tool_name_and_tail(rest)
            } else {
                // Bare function-call syntax: tool_name({"key": "val"})
                if let Some(paren) = line.find('(') {
                    let candidate = line[..paren].trim();
                    if known.contains(candidate) {
                        let args_str = line[paren + 1..].trim_end_matches(')').trim();
                        if let Ok(input) = serde_json::from_str::<serde_json::Value>(args_str) {
                            calls.push(ToolCall {
                                id: format!("txt_{}", uuid::Uuid::new_v4().simple()),
                                name: candidate.to_string(),
                                input,
                            });
                        }
                    }
                    continue;
                }
                // Bare name + space + JSON: `read_file {"path": "x"}`
                if let Some(space) = line.find(' ') {
                    let candidate = line[..space].trim();
                    let rest = line[space + 1..].trim();
                    if known.contains(candidate) && rest.starts_with('{') {
                        if let Ok(input) = serde_json::from_str::<serde_json::Value>(rest) {
                            calls.push(ToolCall {
                                id: format!("txt_{}", uuid::Uuid::new_v4().simple()),
                                name: candidate.to_string(),
                                input,
                            });
                        }
                    }
                }
                continue;
            };

            let Some((name, tail)) = name.zip(Some(tail)) else {
                continue;
            };
            if !known.contains(name) {
                continue;
            }
            let tail = tail.trim_start();
            if let Some(json_part) = strip_prefix_caseless(tail, "with input:")
                .or_else(|| strip_prefix_caseless(tail, "with:"))
                .or_else(|| strip_prefix_caseless(tail, "input:"))
                .or_else(|| {
                    // "with {json}" — bare "with" followed by JSON object
                    strip_prefix_caseless(tail, "with ").filter(|r| r.trim_start().starts_with('{'))
                })
            {
                let json_part = json_part.trim();
                if let Ok(input) = serde_json::from_str::<serde_json::Value>(json_part) {
                    calls.push(ToolCall {
                        id: format!("txt_{}", uuid::Uuid::new_v4().simple()),
                        name: name.to_string(),
                        input,
                    });
                }
            } else if let Some(action_tail) = strip_prefix_caseless(tail, "with action:")
                .or_else(|| strip_prefix_caseless(tail, "action:"))
            {
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
            } else {
                // Tail might be bare JSON: Using tool 'run_cli' {"command": "ls"}
                let tail = tail.trim();
                if tail.starts_with('{') {
                    if let Ok(input) = serde_json::from_str::<serde_json::Value>(tail) {
                        calls.push(ToolCall {
                            id: format!("txt_{}", uuid::Uuid::new_v4().simple()),
                            name: name.to_string(),
                            input,
                        });
                    }
                }
            }
        } // end segments loop
    } // end lines loop
    if calls.is_empty() {
        None
    } else {
        Some(calls)
    }
}

/// Case-insensitive prefix strip. Returns the remainder after the prefix.
fn strip_prefix_caseless<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    if s.len() >= prefix.len() && s[..prefix.len()].eq_ignore_ascii_case(prefix) {
        Some(&s[prefix.len()..])
    } else {
        None
    }
}

/// Extract tool name from various quoting styles: 'name', `name`, "name", or bare word.
/// Returns (Some(name_str), rest_after_name) or (None, "").
fn extract_tool_name_and_tail(s: &str) -> (Option<&str>, &str) {
    let s = s.trim_start();
    let (name, rest) = if s.starts_with('\'') || s.starts_with('`') || s.starts_with('"') {
        let quote = s.as_bytes()[0] as char;
        let inner = &s[1..];
        if let Some(end) = inner.find(quote) {
            (&inner[..end], inner[end + 1..].trim_start())
        } else {
            return (None, "");
        }
    } else {
        // Bare word: take until whitespace or punctuation
        let end = s
            .find(|c: char| c.is_whitespace() || c == '(' || c == ':')
            .unwrap_or(s.len());
        (&s[..end], s[end..].trim_start())
    };
    if name.is_empty() {
        (None, "")
    } else {
        (Some(name), rest)
    }
}

/// Detect raw unified diff in model output and wrap it as a synthetic `patch_file` call.
/// 7B models sometimes dump a diff as plain text instead of calling `patch_file`.
/// We look for `--- a/path` + `+++ b/path` + `@@` hunk headers.
fn rescue_raw_diff_as_patch(text: &str) -> Option<ToolCall> {
    // Quick reject: must contain diff markers
    if !text.contains("@@") {
        return None;
    }
    let lines: Vec<&str> = text.lines().collect();
    // Find first `--- a/` line
    let minus_idx = lines.iter().position(|l| {
        let t = l.trim();
        t.starts_with("--- a/") || t.starts_with("--- ")
    })?;
    // Must be followed by `+++ b/`
    let plus_idx = minus_idx + 1;
    if plus_idx >= lines.len() {
        return None;
    }
    let plus_line = lines[plus_idx].trim();
    if !plus_line.starts_with("+++ b/") && !plus_line.starts_with("+++ ") {
        return None;
    }
    // Must have at least one `@@` hunk header after
    let has_hunk = lines[plus_idx + 1..]
        .iter()
        .any(|l| l.trim().starts_with("@@"));
    if !has_hunk {
        return None;
    }

    // Extract file path from `--- a/path` or `+++ b/path`
    let path = plus_line
        .strip_prefix("+++ b/")
        .or_else(|| plus_line.strip_prefix("+++ "))
        .unwrap_or("")
        .trim();
    if path.is_empty() || path == "/dev/null" {
        return None;
    }

    // Collect the diff text starting from the `---` line
    let diff: String = lines[minus_idx..].join("\n");

    tracing::debug!(path, diff_len = diff.len(), "rescue_raw_diff_as_patch");
    Some(ToolCall {
        id: format!("rescue_{}", uuid::Uuid::new_v4().simple()),
        name: "patch_file".to_string(),
        input: serde_json::json!({ "path": path, "diff": diff }),
    })
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
                let guard = "\n\nCRITICAL: No tools available right now. Rules:\n\
                    1. NEVER say \"Creating...\", \"Saved as...\", \"Checking...\", or claim you did something.\n\
                    2. NEVER pretend to create files, run commands, list tasks, or take actions.\n\
                    3. Just chat naturally. Answer questions from your knowledge.\n\
                    4. If they want you to DO something (create, check, list, run), say: \
                       \"Sure, let me do that for you\" — the system will give me tools on the next turn.\n\
                    VIOLATION = saying you did something you didn't. That is lying. Don't lie.";
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

                    // First: check if the model wrote a text-format tool call
                    // (e.g. "call task with {...}"). If parseable, execute it
                    // immediately — don't waste LLM calls retrying.
                    if let Some(synthetic_calls) = parse_text_tool_calls(payload, &tools) {
                        if !synthetic_calls.is_empty() {
                            tracing::info!(
                                "text-format tool call detected ({}), executing",
                                synthetic_calls
                                    .iter()
                                    .map(|c| c.name.as_str())
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            );
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

                    // Diff auto-fixer: if the model dumped a raw unified diff
                    // instead of calling patch_file, wrap it into a synthetic call.
                    if let Some(synthetic_patch) = rescue_raw_diff_as_patch(payload) {
                        tracing::info!("raw diff rescued as patch_file call");
                        self.run_synthetic_tool_batch(
                            vec![synthetic_patch],
                            &mut session,
                            &executor,
                            &mut tool_calls_count,
                        )
                        .await?;
                        continue;
                    }

                    // Auto-retry: if the model narrated an action instead of calling
                    // a tool (and it wasn't a parseable text-format call), discard
                    // this response and retry with tools enabled.
                    // Only retry when tools were withheld (first call) or model is
                    // still learning — cap at 2 retries to limit latency.
                    // Skip retry if tools were already used this turn — the model
                    // is responding to tool results, not hallucinating actions.
                    if model_calls_count <= 2
                        && tool_calls_count == 0
                        && response_wanted_tools(payload)
                    {
                        tracing::info!(
                            "narration detected (calls={}): retrying with tools",
                            model_calls_count
                        );
                        continue;
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
                    // When tools ran but the final reply is empty (model wrapped
                    // everything in <thinking> or just stopped), synthesize a
                    // summary so the sanity check doesn't reject completed work.
                    let display_text = if display_text.trim().is_empty() && tool_calls_count > 0 {
                        format!("Executed {} tool call(s).", tool_calls_count)
                    } else {
                        display_text
                    };
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
                            &tc.name,
                            outcome,
                            per_tool_ms,
                            expected_lat,
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

    #[test]
    fn call_task_with_json() {
        let tools = tools_task_only();
        let text = "call task with {\"action\": \"create\", \"title\": \"battle-test-probe\"}";
        let calls = parse_text_tool_calls(text, &tools).expect("parsed");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].name, "task");
        assert_eq!(
            calls[0].input.get("action").and_then(|v| v.as_str()),
            Some("create")
        );
    }

    fn tools_read_file() -> Vec<Tool> {
        vec![Tool {
            name: "read_file".to_string(),
            description: "r".to_string(),
            input_schema: json!({}),
        }]
    }

    #[test]
    fn call_tool_with_json_pattern() {
        let tools = tools_read_file();
        let text = "call read_file with {\"path\":\"src/policy_override.rs\"}";
        let calls = parse_text_tool_calls(text, &tools).expect("parsed");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].name, "read_file");
        assert_eq!(
            calls[0].input.get("path").and_then(|v| v.as_str()),
            Some("src/policy_override.rs")
        );
    }

    #[test]
    fn semicolon_separated_multi_call() {
        let tools = vec![
            Tool {
                name: "run_cli".to_string(),
                description: "r".to_string(),
                input_schema: json!({}),
            },
            Tool {
                name: "write_file".to_string(),
                description: "w".to_string(),
                input_schema: json!({}),
            },
        ];
        let text = r#"call run_cli with {"command":"cargo test"}; call write_file with {"path":"foo.rs","content":"fn main(){}"}"#;
        let calls = parse_text_tool_calls(text, &tools).expect("parsed");
        assert_eq!(calls.len(), 2, "should parse both calls: {calls:?}");
        assert_eq!(calls[0].name, "run_cli");
        assert_eq!(
            calls[0].input.get("command").and_then(|v| v.as_str()),
            Some("cargo test")
        );
        assert_eq!(calls[1].name, "write_file");
        assert_eq!(
            calls[1].input.get("path").and_then(|v| v.as_str()),
            Some("foo.rs")
        );
    }

    #[test]
    fn bare_tool_name_space_json() {
        let tools = tools_read_file();
        let text = r#"read_file {"path": "src/policy_override.rs"}"#;
        let calls = parse_text_tool_calls(text, &tools).expect("parsed");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].name, "read_file");
        assert_eq!(
            calls[0].input.get("path").and_then(|v| v.as_str()),
            Some("src/policy_override.rs")
        );
    }
}

#[cfg(test)]
mod rescue_diff_tests {
    use super::rescue_raw_diff_as_patch;

    #[test]
    fn rescues_standard_unified_diff() {
        let text = "Here's the fix:\n\
                     --- a/src/foo.rs\n\
                     +++ b/src/foo.rs\n\
                     @@ -5,3 +5,3 @@\n\
                     -    old_line()\n\
                     +    new_line()";
        let call = rescue_raw_diff_as_patch(text).expect("should rescue");
        assert_eq!(call.name, "patch_file");
        assert_eq!(
            call.input.get("path").and_then(|v| v.as_str()),
            Some("src/foo.rs")
        );
        assert!(call
            .input
            .get("diff")
            .and_then(|v| v.as_str())
            .unwrap()
            .contains("@@ -5,3 +5,3 @@"));
    }

    #[test]
    fn ignores_text_without_diff_markers() {
        assert!(rescue_raw_diff_as_patch("just some text about diffs").is_none());
    }

    #[test]
    fn ignores_partial_diff_no_hunk() {
        let text = "--- a/foo.rs\n+++ b/foo.rs\nno hunk header here";
        assert!(rescue_raw_diff_as_patch(text).is_none());
    }
}

#[cfg(test)]
mod heuristic_tests {
    use super::{message_likely_needs_tools_neuromod, response_wanted_tools};

    #[test]
    fn single_word_greetings_skip_tools() {
        assert!(!message_likely_needs_tools_neuromod("hi"));
        assert!(!message_likely_needs_tools_neuromod("hello"));
        assert!(!message_likely_needs_tools_neuromod("ok"));
        assert!(!message_likely_needs_tools_neuromod("thanks"));
    }

    #[test]
    fn two_plus_word_messages_get_tools() {
        assert!(message_likely_needs_tools_neuromod("list tasks"));
        assert!(message_likely_needs_tools_neuromod("close 5"));
        assert!(message_likely_needs_tools_neuromod("what's up"));
        assert!(message_likely_needs_tools_neuromod("are you online"));
    }

    #[test]
    fn action_messages_get_tools() {
        assert!(message_likely_needs_tools_neuromod(
            "create a marketing page"
        ));
        assert!(message_likely_needs_tools_neuromod(
            "can you make a webpage for the project"
        ));
        assert!(message_likely_needs_tools_neuromod("check all the tasks"));
        assert!(message_likely_needs_tools_neuromod("close task 5"));
        assert!(message_likely_needs_tools_neuromod(
            "what tasks do we have on deck"
        ));
    }

    #[test]
    fn narration_detected() {
        assert!(response_wanted_tools(
            "Creating a webpage to market the project."
        ));
        assert!(response_wanted_tools(
            "Saved as `chump-marketing.html`. Open it to view."
        ));
        assert!(response_wanted_tools("I'll list your tasks now."));
        assert!(response_wanted_tools("Let me check the repository status."));
        assert!(response_wanted_tools("I've created the file for you."));
    }

    #[test]
    fn clean_responses_not_flagged() {
        assert!(!response_wanted_tools("2 + 2 = 4."));
        assert!(!response_wanted_tools("Hello! How can I help?"));
        assert!(!response_wanted_tools("The answer is 42."));
    }
}
