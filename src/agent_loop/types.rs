use crate::stream_events::{AgentEvent, EventSender};
use crate::thinking_strip;
use axonerai::executor::ToolResult;
use axonerai::provider::{Tool, ToolCall};
use axonerai::session::Session;
use std::time::Instant;

/// Typed session: in this codebase, we use axonerai::session::Session.
pub type AgentSession = Session;

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

pub struct AgentLoopContext {
    pub request_id: String,
    pub turn_start: Instant,
    pub session: AgentSession,
    pub event_tx: Option<EventSender>,
    pub light: bool,
}

impl AgentLoopContext {
    pub fn send(&self, event: AgentEvent) {
        if let Some(ref tx) = self.event_tx {
            let _ = tx.send(event);
        }
    }
}

pub fn joined_thinking_option(segments: &[String]) -> Option<String> {
    if segments.is_empty() {
        None
    } else {
        Some(segments.join("\n---\n"))
    }
}

pub fn push_thinking_segment(segments: &mut Vec<String>, mono: Option<String>) {
    if let Some(s) = mono {
        if !s.trim().is_empty() {
            segments.push(s);
        }
    }
}

pub fn log_thinking_extracted(context: &'static str, m: &str) {
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

/// Heuristic: determine if a message likely needs tools. Biased toward YES — only skip for
/// clearly trivial messages (greetings, single words, short chitchat).
pub fn message_likely_needs_tools_neuromod(msg: &str) -> bool {
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

    // Questions almost always need tools.
    if trimmed.contains('?') && trimmed.len() > 10 {
        return true;
    }

    // Any message with more than 2 words gets tools.
    let word_count = trimmed.split_whitespace().count();
    if word_count > 2 {
        return true;
    }
    if word_count == 2 {
        return true;
    }

    false
}

/// Detect when a tool-free response indicates the model wanted to use tools but couldn't.
pub fn response_wanted_tools(text: &str) -> bool {
    let lower = text.to_lowercase();
    let narration_signals = [
        "i'll ",
        "i will ",
        "let me ",
        "i'm going to ",
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
        "i'd need to",
        "i would need to",
        "i don't have access",
        "i can't access",
        "i cannot access",
        "done!",
        "all set",
        "file has been created",
        "has been saved",
        "successfully created",
        "i've created",
        "i've saved",
        "i've written",
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

pub fn compact_tools_for_light(tools: Vec<Tool>) -> Vec<Tool> {
    tools
        .into_iter()
        .map(|mut t| {
            if let Some(pos) = t.description.find(". ") {
                if let Some(pos2) = t.description[pos + 2..].find(". ") {
                    t.description.truncate(pos + 2 + pos2 + 1);
                }
                if t.description.len() > 200 {
                    t.description.truncate(200);
                }
            } else if t.description.len() > 200 {
                t.description.truncate(200);
            }
            t
        })
        .collect()
}

pub fn parse_text_tool_calls(text: &str, tools: &[Tool]) -> Option<Vec<ToolCall>> {
    let known: std::collections::HashSet<&str> = tools.iter().map(|t| t.name.as_str()).collect();
    let mut calls = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        let (name, tail) = if let Some(rest) = strip_prefix_caseless(line, "using tool ")
            .or_else(|| strip_prefix_caseless(line, "calling tool "))
            .or_else(|| strip_prefix_caseless(line, "call tool "))
        {
            extract_tool_name_and_tail(rest)
        } else if let Some(rest) = strip_prefix_caseless(line, "tool: ") {
            extract_tool_name_and_tail(rest)
        } else if let Some(rest) = strip_prefix_caseless(line, "call ") {
            extract_tool_name_and_tail(rest)
        } else {
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
            } else {
                continue;
            }
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
                let action = v.split_whitespace().next().unwrap_or("list");
                serde_json::json!({ "action": action })
            };
            calls.push(ToolCall {
                id: format!("txt_{}", uuid::Uuid::new_v4().simple()),
                name: name.to_string(),
                input,
            });
        } else {
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
    }
    if calls.is_empty() {
        None
    } else {
        Some(calls)
    }
}

fn strip_prefix_caseless<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    if s.len() >= prefix.len() && s[..prefix.len()].eq_ignore_ascii_case(prefix) {
        Some(&s[prefix.len()..])
    } else {
        None
    }
}

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

pub fn rescue_raw_diff_as_patch(text: &str) -> Option<ToolCall> {
    if !text.contains("@@") {
        return None;
    }
    let lines: Vec<&str> = text.lines().collect();
    let minus_idx = lines.iter().position(|l| {
        let t = l.trim();
        t.starts_with("--- a/") || t.starts_with("--- ")
    })?;
    let plus_idx = minus_idx + 1;
    if plus_idx >= lines.len() {
        return None;
    }
    let plus_line = lines[plus_idx].trim();
    if !plus_line.starts_with("+++ b/") && !plus_line.starts_with("+++ ") {
        return None;
    }
    let has_hunk = lines[plus_idx + 1..]
        .iter()
        .any(|l| l.trim().starts_with("@@"));
    if !has_hunk {
        return None;
    }
    let path = plus_line
        .strip_prefix("+++ b/")
        .or_else(|| plus_line.strip_prefix("+++ "))
        .unwrap_or("")
        .trim();
    if path.is_empty() || path == "/dev/null" {
        return None;
    }
    let diff: String = lines[minus_idx..].join("\n");
    Some(ToolCall {
        id: format!("rescue_{}", uuid::Uuid::new_v4().simple()),
        name: "patch_file".to_string(),
        input: serde_json::json!({ "path": path, "diff": diff }),
    })
}

pub fn efe_order_tool_calls(calls: &[ToolCall]) -> Vec<ToolCall> {
    if calls.len() <= 1 {
        return calls.to_vec();
    }
    let names: Vec<&str> = calls.iter().map(|c| c.name.as_str()).collect();
    let scores = crate::belief_state::score_tools(&names);
    if scores.is_empty() {
        return calls.to_vec();
    }
    let mut ordered: Vec<ToolCall> = scores
        .iter()
        .filter_map(|s| calls.iter().find(|c| c.name == s.tool_name))
        .cloned()
        .collect();
    if ordered.len() > 1 {
        let selected = crate::precision_controller::epsilon_greedy_select(ordered.len());
        if selected != 0 {
            ordered.swap(0, selected);
        }
    }
    ordered
}

pub fn speculative_batch_enabled() -> bool {
    !crate::env_flags::env_trim_eq("CHUMP_SPECULATIVE_BATCH", "0")
}

pub fn format_tool_use(tool_calls: &[ToolCall]) -> String {
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

pub fn format_tool_results(results: &[ToolResult]) -> String {
    results
        .iter()
        .map(|r| format!("Tool '{}' returned: {}", r.tool_name, r.result))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Per-batch outcome so the iteration controller can detect "fast-failing tool"
/// storms (e.g. 25 patch_file calls in a row each returning a parse error in
/// 1-3ms). Returned from `ToolRunner::run_synthetic_batch` and
/// `run_native_batch` so the caller can track consecutive failures.
#[derive(Debug, Clone, Copy, Default)]
pub struct BatchOutcome {
    pub success_count: usize,
    pub fail_count: usize,
}

impl BatchOutcome {
    /// True when the batch contained tool calls AND every one of them failed.
    /// The "tool storm" predicate the controller uses for its fast-fail circuit.
    pub fn all_failed(&self) -> bool {
        self.success_count == 0 && self.fail_count > 0
    }

    /// Total tool calls in the batch (success + failure).
    pub fn total(&self) -> usize {
        self.success_count + self.fail_count
    }
}

/// Tool error prefixes considered "this tool actually failed." Kept centrally
/// so `BatchOutcome` accounting matches the existing user-facing error format.
pub fn is_failed_tool_result(result: &str) -> bool {
    result.starts_with("DENIED:") || result.starts_with("Tool error:")
}

// ── Tests ─────────────────────────────────────────────────────────────
//
// Restored from the pre-split `agent_loop.rs` after the JetBrains refactor
// inadvertently dropped the inline test module. Coverage matches the original
// 11 cases across three logical groups: text-tool-call parsing, raw-diff
// rescue, and tool-need heuristics. These functions are the riskiest pieces
// of agent_loop because they make routing decisions on free-form text.

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
mod batch_outcome_tests {
    //! Cover the predicate the iteration controller uses to detect
    //! "fast-failing tool" storms (qwen3:8b 2026-04-15 regression).

    use super::{is_failed_tool_result, BatchOutcome};

    #[test]
    fn all_failed_true_when_only_failures() {
        let o = BatchOutcome {
            success_count: 0,
            fail_count: 3,
        };
        assert!(o.all_failed());
        assert_eq!(o.total(), 3);
    }

    #[test]
    fn all_failed_false_when_empty_batch() {
        // Empty batch is NOT a storm — there were zero tool calls, not "all failed."
        // Otherwise the controller would short-circuit on no-op iterations.
        let o = BatchOutcome::default();
        assert!(!o.all_failed());
        assert_eq!(o.total(), 0);
    }

    #[test]
    fn all_failed_false_when_any_success() {
        let o = BatchOutcome {
            success_count: 1,
            fail_count: 4,
        };
        assert!(!o.all_failed());
        assert_eq!(o.total(), 5);
    }

    #[test]
    fn is_failed_tool_result_recognizes_denied() {
        assert!(is_failed_tool_result("DENIED: user said no"));
    }

    #[test]
    fn is_failed_tool_result_recognizes_tool_error() {
        assert!(is_failed_tool_result("Tool error: parse failed at line 3"));
    }

    #[test]
    fn is_failed_tool_result_passes_through_real_output() {
        // "not found" content is reported in error text but doesn't count as
        // a hard tool failure for the storm-detection breaker — only DENIED:
        // and Tool error: prefixes do.
        assert!(!is_failed_tool_result("file not found"));
        assert!(!is_failed_tool_result("ok"));
        assert!(!is_failed_tool_result(""));
        assert!(!is_failed_tool_result("Cargo.toml\nsrc/main.rs"));
    }
}

#[cfg(test)]
mod helper_tests {
    //! Tests for the small pure helpers in this file. These weren't covered
    //! before — neither pre- nor post-refactor. Adding now since the helpers
    //! are easy to break and harder to debug from a failing integration test.

    use super::{
        compact_tools_for_light, format_tool_results, format_tool_use, joined_thinking_option,
        push_thinking_segment,
    };
    use axonerai::executor::ToolResult;
    use axonerai::provider::{Tool, ToolCall};
    use serde_json::json;

    #[test]
    fn joined_thinking_option_empty_returns_none() {
        let segs: Vec<String> = vec![];
        assert!(joined_thinking_option(&segs).is_none());
    }

    #[test]
    fn joined_thinking_option_joins_with_separator() {
        let segs = vec!["first".to_string(), "second".to_string()];
        assert_eq!(
            joined_thinking_option(&segs),
            Some("first\n---\nsecond".to_string())
        );
    }

    #[test]
    fn joined_thinking_option_single_segment_is_just_segment() {
        let segs = vec!["only".to_string()];
        assert_eq!(joined_thinking_option(&segs), Some("only".to_string()));
    }

    #[test]
    fn push_thinking_segment_skips_none() {
        let mut segs: Vec<String> = vec![];
        push_thinking_segment(&mut segs, None);
        assert!(segs.is_empty());
    }

    #[test]
    fn push_thinking_segment_skips_empty_and_whitespace() {
        let mut segs: Vec<String> = vec![];
        push_thinking_segment(&mut segs, Some("".to_string()));
        push_thinking_segment(&mut segs, Some("   \n\t".to_string()));
        assert!(segs.is_empty());
    }

    #[test]
    fn push_thinking_segment_pushes_non_empty() {
        let mut segs: Vec<String> = vec!["existing".to_string()];
        push_thinking_segment(&mut segs, Some("new content".to_string()));
        assert_eq!(
            segs,
            vec!["existing".to_string(), "new content".to_string()]
        );
    }

    fn tool_with_desc(desc: &str) -> Tool {
        Tool {
            name: "x".to_string(),
            description: desc.to_string(),
            input_schema: json!({}),
        }
    }

    #[test]
    fn compact_tools_for_light_keeps_short_descriptions() {
        let tools = vec![tool_with_desc("Quick")];
        let out = compact_tools_for_light(tools);
        assert_eq!(out[0].description, "Quick");
    }

    #[test]
    fn compact_tools_for_light_trims_long_single_sentence() {
        let long = "A".repeat(500);
        let tools = vec![tool_with_desc(&long)];
        let out = compact_tools_for_light(tools);
        assert_eq!(out[0].description.len(), 200);
    }

    #[test]
    fn compact_tools_for_light_keeps_first_two_sentences() {
        let tools = vec![tool_with_desc(
            "First sentence. Second sentence. Third sentence.",
        )];
        let out = compact_tools_for_light(tools);
        // Truncation happens at the second ". " — so we keep "First sentence. Second."
        assert!(out[0].description.contains("First sentence"));
        assert!(out[0].description.contains("Second"));
        assert!(!out[0].description.contains("Third"));
    }

    #[test]
    fn format_tool_use_renders_one_call() {
        let calls = vec![ToolCall {
            id: "id1".to_string(),
            name: "read_file".to_string(),
            input: json!({"path": "README.md"}),
        }];
        let out = format_tool_use(&calls);
        assert!(out.starts_with("Using tool 'read_file' with input: "));
        assert!(out.contains("README.md"));
    }

    #[test]
    fn format_tool_use_renders_multiple_calls_newline_separated() {
        let calls = vec![
            ToolCall {
                id: "1".into(),
                name: "a".into(),
                input: json!({}),
            },
            ToolCall {
                id: "2".into(),
                name: "b".into(),
                input: json!({}),
            },
        ];
        let out = format_tool_use(&calls);
        assert_eq!(out.lines().count(), 2);
        assert!(out.contains("'a'"));
        assert!(out.contains("'b'"));
    }

    #[test]
    fn format_tool_use_empty_returns_empty_string() {
        assert_eq!(format_tool_use(&[]), "");
    }

    #[test]
    fn format_tool_results_renders_results() {
        let results = vec![ToolResult {
            tool_call_id: "call1".to_string(),
            tool_name: "read_file".to_string(),
            result: "file contents here".to_string(),
        }];
        let out = format_tool_results(&results);
        assert_eq!(out, "Tool 'read_file' returned: file contents here");
    }

    #[test]
    fn format_tool_results_multiple_newline_separated() {
        let results = vec![
            ToolResult {
                tool_call_id: "1".into(),
                tool_name: "a".into(),
                result: "ok".into(),
            },
            ToolResult {
                tool_call_id: "2".into(),
                tool_name: "b".into(),
                result: "fail".into(),
            },
        ];
        let out = format_tool_results(&results);
        assert_eq!(out.lines().count(), 2);
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

#[cfg(test)]
mod efe_order_tests {
    //! Cover the tool-ordering helper. It delegates scoring to belief_state,
    //! so we can only test edge cases here cleanly — but those edges are
    //! where regressions bite (empty and single-element inputs).

    use super::efe_order_tool_calls;
    use axonerai::provider::ToolCall;
    use serde_json::json;

    fn tc(name: &str) -> ToolCall {
        ToolCall {
            id: format!("call_{}", name),
            name: name.to_string(),
            input: json!({}),
        }
    }

    #[test]
    fn empty_input_returns_empty() {
        let out = efe_order_tool_calls(&[]);
        assert!(out.is_empty());
    }

    #[test]
    fn single_call_returned_unchanged() {
        let calls = vec![tc("read_file")];
        let out = efe_order_tool_calls(&calls);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].name, "read_file");
    }

    #[test]
    fn output_preserves_all_unique_tools() {
        // Even if belief_state scoring yields an unusual order, every input
        // tool must appear exactly once in the output. Run the function and
        // verify set-equality on names (since positional order is
        // belief-state-dependent and not stable across runs).
        let calls = vec![tc("read_file"), tc("patch_file"), tc("run_cli")];
        let out = efe_order_tool_calls(&calls);
        use std::collections::HashSet;
        let in_names: HashSet<&str> = calls.iter().map(|c| c.name.as_str()).collect();
        let out_names: HashSet<String> = out.iter().map(|c| c.name.clone()).collect();
        let out_refs: HashSet<&str> = out_names.iter().map(|s| s.as_str()).collect();
        assert_eq!(
            in_names, out_refs,
            "efe_order_tool_calls must preserve tool set"
        );
    }
}

#[cfg(test)]
mod speculative_batch_tests {
    //! The env-var gate that lets ops disable speculative batching. Serial'd
    //! because it mutates global env state.

    use super::speculative_batch_enabled;

    #[test]
    #[serial_test::serial]
    fn enabled_by_default_when_unset() {
        std::env::remove_var("CHUMP_SPECULATIVE_BATCH");
        assert!(
            speculative_batch_enabled(),
            "speculative batching should be enabled by default"
        );
    }

    #[test]
    #[serial_test::serial]
    fn explicit_zero_disables() {
        std::env::set_var("CHUMP_SPECULATIVE_BATCH", "0");
        assert!(!speculative_batch_enabled());
        std::env::remove_var("CHUMP_SPECULATIVE_BATCH");
    }

    #[test]
    #[serial_test::serial]
    fn zero_with_surrounding_whitespace_still_disables() {
        // env_trim_eq trims whitespace, so "  0  " should also disable.
        std::env::set_var("CHUMP_SPECULATIVE_BATCH", "  0  ");
        assert!(!speculative_batch_enabled());
        std::env::remove_var("CHUMP_SPECULATIVE_BATCH");
    }

    #[test]
    #[serial_test::serial]
    fn non_zero_value_keeps_enabled() {
        // Anything other than "0" should keep speculative batching enabled
        // (the knob is an opt-out, not an opt-in).
        std::env::set_var("CHUMP_SPECULATIVE_BATCH", "1");
        assert!(speculative_batch_enabled());
        std::env::set_var("CHUMP_SPECULATIVE_BATCH", "true");
        assert!(speculative_batch_enabled());
        std::env::set_var("CHUMP_SPECULATIVE_BATCH", "");
        // Empty string is not exactly "0" — should stay enabled (default).
        assert!(speculative_batch_enabled());
        std::env::remove_var("CHUMP_SPECULATIVE_BATCH");
    }
}
