//! chump-xml-adapter — EFFECTIVE-003
//!
//! Detects <tool_call> / <function_call> XML tags in LLM output and
//! converts them to native OpenAI-compatible ToolCall format.
//! Enabled per-model via xml_tool_tags: true in model config.

use serde::{Deserialize, Serialize};

/// Native tool call format (OpenAI-compatible).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub input: serde_json::Value,
}

/// Result of adapting a model response.
#[derive(Debug, Clone)]
pub struct AdapterOutput {
    /// Tool calls extracted from XML (may be empty if text-only response).
    pub tool_calls: Vec<ToolCall>,
    /// Remaining text content after stripping XML tool blocks.
    pub text: String,
}

/// Extract content between open/close tag pair, returning the inner content
/// and the byte range of the full match (open tag through close tag inclusive).
///
/// Returns None if neither tag is found or the close tag comes before the open tag.
fn extract_tag_block<'a>(
    haystack: &'a str,
    open: &str,
    close: &str,
) -> Option<(&'a str, usize, usize)> {
    let start = haystack.find(open)?;
    let inner_start = start + open.len();
    let end = haystack[inner_start..].find(close)?;
    let inner = &haystack[inner_start..inner_start + end];
    let block_end = inner_start + end + close.len();
    Some((inner, start, block_end))
}

/// Parse a `<tool_call>...</tool_call>` block.
///
/// Expected JSON shapes:
///   {"name": "fn_name", "arguments": {...}}
///   {"name": "fn_name", "input": {...}}
///   {"name": "fn_name", "parameters": {...}}
///
/// Returns (name, input) or None on malformed JSON / missing name.
fn parse_tool_call_block(json: &str) -> Option<(String, serde_json::Value)> {
    let v: serde_json::Value = serde_json::from_str(json.trim()).ok()?;
    let name = v.get("name")?.as_str()?.to_string();
    // Accept "arguments", "input", or "parameters" as the argument container.
    let input = v
        .get("arguments")
        .or_else(|| v.get("input"))
        .or_else(|| v.get("parameters"))
        .cloned()
        .unwrap_or(serde_json::Value::Object(Default::default()));
    Some((name, input))
}

/// Parse a `<function_call name="X">...</function_call>` block.
///
/// The name is taken from the `name` attribute of the opening tag.
/// The body is parsed as a JSON object and used directly as `input`.
///
/// Returns (name, input) or None on malformed content.
fn parse_function_call_block(open_tag: &str, body: &str) -> Option<(String, serde_json::Value)> {
    // Extract name="..." from open_tag, e.g. `<function_call name="bash">`
    let attr_prefix = "name=\"";
    let attr_start = open_tag.find(attr_prefix)? + attr_prefix.len();
    let attr_end = open_tag[attr_start..].find('"')?;
    let name = open_tag[attr_start..attr_start + attr_end].to_string();
    let input: serde_json::Value = serde_json::from_str(body.trim()).ok()?;
    Some((name, input))
}

/// Detect and extract XML tool calls from model output.
///
/// Supports two tag styles:
///   `<tool_call>{"name": "read_file", "arguments": {"path": "foo.rs"}}</tool_call>`
///   `<function_call name="read_file">{"path": "foo.rs"}</function_call>`
///
/// Returns `AdapterOutput` with extracted `tool_calls` and remaining `text`.
/// Malformed JSON inside tags is skipped (not panicked on); the raw block
/// is left in `text` so the caller can inspect it.
pub fn adapt(raw: &str) -> AdapterOutput {
    let mut tool_calls: Vec<ToolCall> = Vec::new();
    let mut remaining = raw.to_string();
    let mut call_index: usize = 0;

    // Process <tool_call>...</tool_call> blocks until none remain.
    loop {
        match extract_tag_block(&remaining, "<tool_call>", "</tool_call>") {
            None => break,
            Some((inner, start, end)) => {
                let inner = inner.to_string();
                match parse_tool_call_block(&inner) {
                    Some((name, input)) => {
                        tool_calls.push(ToolCall {
                            id: format!("call_{call_index}"),
                            name,
                            input,
                        });
                        call_index += 1;
                        // Remove the matched block from remaining text.
                        remaining.replace_range(start..end, "");
                    }
                    None => {
                        // Malformed: leave the block in place but advance past it to
                        // avoid an infinite loop.  We mark it with a sentinel so we
                        // don't re-match it (just remove the closing tag so we won't
                        // re-find the same block, and keep raw text as-is).
                        //
                        // Strategy: replace just the opening tag so this block won't
                        // match again, then let the outer loop continue.
                        remaining.replace_range(start..start + "<tool_call>".len(), "\x00tool_call\x00");
                    }
                }
            }
        }
    }
    // Restore the sentinel markers we placed for malformed blocks.
    remaining = remaining.replace("\x00tool_call\x00", "<tool_call>");

    // Process <function_call name="X">...</function_call> blocks.
    loop {
        // Find the start of a <function_call ...> open tag.
        let fc_start = match remaining.find("<function_call") {
            None => break,
            Some(pos) => pos,
        };
        // Find the end of the open tag (closing `>`).
        let tag_end = match remaining[fc_start..].find('>') {
            None => break,
            Some(rel) => fc_start + rel + 1,
        };
        let open_tag = &remaining[fc_start..tag_end];

        // Find the closing tag.
        let close_tag = "</function_call>";
        let body_start = tag_end;
        let close_pos = match remaining[body_start..].find(close_tag) {
            None => break,
            Some(rel) => body_start + rel,
        };
        let body = &remaining[body_start..close_pos];
        let block_end = close_pos + close_tag.len();

        match parse_function_call_block(open_tag, body) {
            Some((name, input)) => {
                tool_calls.push(ToolCall {
                    id: format!("call_{call_index}"),
                    name,
                    input,
                });
                call_index += 1;
                remaining.replace_range(fc_start..block_end, "");
            }
            None => {
                // Malformed: advance past this block to avoid infinite loop.
                remaining.replace_range(fc_start..fc_start + "<function_call".len(), "\x00function_call\x00");
            }
        }
    }
    // Restore sentinels.
    remaining = remaining.replace("\x00function_call\x00", "<function_call");

    AdapterOutput {
        tool_calls,
        text: remaining,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1. Empty string — nothing extracted.
    #[test]
    fn test_empty_response() {
        let out = adapt("");
        assert!(out.tool_calls.is_empty());
        assert_eq!(out.text, "");
    }

    /// 2. Plain text — passed through unchanged.
    #[test]
    fn test_plain_text() {
        let out = adapt("hello world");
        assert!(out.tool_calls.is_empty());
        assert_eq!(out.text, "hello world");
    }

    /// 3. Single <tool_call> block.
    #[test]
    fn test_tool_call_style() {
        let raw = r#"<tool_call>{"name":"read_file","arguments":{"path":"src/main.rs"}}</tool_call>"#;
        let out = adapt(raw);
        assert_eq!(out.tool_calls.len(), 1);
        let tc = &out.tool_calls[0];
        assert_eq!(tc.name, "read_file");
        assert_eq!(tc.input["path"], "src/main.rs");
        // Text should be empty (or just whitespace) after stripping.
        assert!(out.text.trim().is_empty());
    }

    /// 4. Single <function_call name="X"> block.
    #[test]
    fn test_function_call_style() {
        let raw = r#"<function_call name="bash">{"cmd":"ls"}</function_call>"#;
        let out = adapt(raw);
        assert_eq!(out.tool_calls.len(), 1);
        let tc = &out.tool_calls[0];
        assert_eq!(tc.name, "bash");
        assert_eq!(tc.input["cmd"], "ls");
    }

    /// 5. Multiple <tool_call> blocks produce multiple ToolCalls.
    #[test]
    fn test_multiple_tool_calls() {
        let raw = concat!(
            r#"<tool_call>{"name":"read_file","arguments":{"path":"a.rs"}}</tool_call>"#,
            r#"<tool_call>{"name":"write_file","arguments":{"path":"b.rs","content":"hello"}}</tool_call>"#,
        );
        let out = adapt(raw);
        assert_eq!(out.tool_calls.len(), 2);
        assert_eq!(out.tool_calls[0].name, "read_file");
        assert_eq!(out.tool_calls[1].name, "write_file");
        // IDs should be sequential.
        assert_eq!(out.tool_calls[0].id, "call_0");
        assert_eq!(out.tool_calls[1].id, "call_1");
    }

    /// 6. Tool call embedded in surrounding text.
    #[test]
    fn test_tool_call_with_surrounding_text() {
        let raw = r#"Here is the result: <tool_call>{"name":"grep","arguments":{"pattern":"foo"}}</tool_call> Done."#;
        let out = adapt(raw);
        assert_eq!(out.tool_calls.len(), 1);
        assert_eq!(out.tool_calls[0].name, "grep");
        assert!(out.text.contains("Here is the result:"));
        assert!(out.text.contains("Done."));
    }

    /// 7. Malformed JSON inside <tool_call> is skipped; raw block stays in text.
    #[test]
    fn test_malformed_json_skipped() {
        let raw = "<tool_call>not json</tool_call>";
        let out = adapt(raw);
        assert!(out.tool_calls.is_empty(), "malformed block should produce no tool calls");
        // The raw block should still be present in the text output.
        assert!(out.text.contains("not json"), "raw content should remain in text");
    }

    /// 8. Round-trip: ToolCall can be serialized and fields are preserved.
    #[test]
    fn test_round_trip() {
        let tc = ToolCall {
            id: "call_0".to_string(),
            name: "my_tool".to_string(),
            input: serde_json::json!({"key": "value"}),
        };
        let serialized = serde_json::to_string(&tc).expect("serialization failed");
        let deserialized: ToolCall =
            serde_json::from_str(&serialized).expect("deserialization failed");
        assert_eq!(deserialized.id, "call_0");
        assert_eq!(deserialized.name, "my_tool");
        assert_eq!(deserialized.input["key"], "value");
        assert_eq!(tc, deserialized);
    }
}
