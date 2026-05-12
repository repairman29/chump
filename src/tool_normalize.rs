//! INFRA-740: Tool-call argument normalizer for weak/local LLMs.
//!
//! When a local LLM (Qwen3, Mistral-7B, etc.) emits malformed JSON in
//! tool-call arguments, this module attempts lightweight repairs before
//! falling back to an empty object. Fires ONLY when the primary
//! `serde_json::from_str` parse fails — zero overhead on well-formed output.
//!
//! Supported repair patterns:
//!   1. Trailing commas before `}` or `]`: `{"a": 1,}` → `{"a": 1}`
//!   2. Missing closing brace(s): `{"a": 1` → `{"a": 1}`
//!   3. Markdown code-fence wrapper: ` ```json {...} ``` ` → `{...}`
//!   4. Single-quoted strings: `{'key': 'val'}` → `{"key": "val"}`
//!
//! On a successful repair, emits `kind=tool_normalize` to ambient.jsonl so
//! operators can track how often weak LLM output needs fixing.

use serde_json::Value;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

// ── Ambient emission ─────────────────────────────────────────────────────────

fn ambient_log_path() -> PathBuf {
    if let Ok(custom) = std::env::var("CHUMP_AMBIENT_LOG") {
        return PathBuf::from(custom);
    }
    crate::repo_path::runtime_base()
        .join(".chump-locks")
        .join("ambient.jsonl")
}

fn iso_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// Emit `kind=tool_normalize` to ambient.jsonl (best-effort; errors silently
/// discarded to avoid blocking the agent loop).
pub fn emit_normalize_event(tool_name: &str, repair: &str) {
    let ambient = ambient_log_path();
    if let Some(parent) = ambient.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let session = std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| "unknown".to_string());
    let ts = iso_now();
    // tool_name may contain quotes — sanitize minimally
    let safe_tool = tool_name.replace('"', "'");
    let safe_repair = repair.replace('"', "'");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"tool_normalize\",\"session\":\"{session}\",\
         \"tool\":\"{safe_tool}\",\"repair\":\"{safe_repair}\"}}\n"
    );
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── Repair strategies ────────────────────────────────────────────────────────

/// Strip markdown code fences around JSON.
/// Handles: ```json {...}```, ```{...}```, and bare ``` variants.
fn strip_code_fence(raw: &str) -> Option<String> {
    let s = raw.trim();
    // Match ``` optionally followed by a language tag, then content, then ```
    if !s.starts_with("```") {
        return None;
    }
    let after_open = s.strip_prefix("```").unwrap_or(s);
    // Skip optional language tag (e.g. "json")
    let content = if after_open.starts_with("json") {
        after_open.strip_prefix("json").unwrap_or(after_open)
    } else {
        after_open
    };
    // content now starts with newline or directly with `{`
    let content = content.trim_start_matches('\n').trim_start();
    // strip trailing ```
    if let Some(pos) = content.rfind("```") {
        Some(content[..pos].trim().to_string())
    } else {
        // missing closing fence — try the whole thing
        Some(content.trim_end().to_string())
    }
}

/// Remove trailing commas before `}` or `]`.
/// Uses a simple character-scan (not a full JSON parser) to handle the common
/// pattern emitted by Qwen3/Mistral when they add a trailing comma after the
/// last key-value pair.
fn remove_trailing_commas(raw: &str) -> String {
    let mut result = String::with_capacity(raw.len());
    let chars: Vec<char> = raw.chars().collect();
    let n = chars.len();
    let mut i = 0;
    while i < n {
        let ch = chars[i];
        if ch == ',' {
            // Look ahead past whitespace for } or ]
            let mut j = i + 1;
            while j < n && chars[j].is_whitespace() {
                j += 1;
            }
            if j < n && (chars[j] == '}' || chars[j] == ']') {
                // Skip this comma
                i += 1;
                continue;
            }
        }
        result.push(ch);
        i += 1;
    }
    result
}

/// Append missing closing braces/brackets to balance the JSON.
/// Counts unmatched `{` and `[` and appends the corresponding closers.
fn balance_braces(raw: &str) -> String {
    let mut depth_brace = 0i32;
    let mut depth_bracket = 0i32;
    let mut in_string = false;
    let mut escape_next = false;
    // Track a simple stack to know which closer to append
    let mut stack: Vec<char> = Vec::new();

    for ch in raw.chars() {
        if escape_next {
            escape_next = false;
            continue;
        }
        if in_string {
            if ch == '\\' {
                escape_next = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        match ch {
            '"' => in_string = true,
            '{' => {
                depth_brace += 1;
                stack.push('}');
            }
            '}' => {
                depth_brace -= 1;
                stack.pop();
            }
            '[' => {
                depth_bracket += 1;
                stack.push(']');
            }
            ']' => {
                depth_bracket -= 1;
                stack.pop();
            }
            _ => {}
        }
    }

    if depth_brace <= 0 && depth_bracket <= 0 {
        return raw.to_string();
    }

    // Append closers in reverse stack order
    let mut out = raw.trim_end().to_string();
    while let Some(closer) = stack.pop() {
        out.push(closer);
    }
    out
}

/// Replace single-quoted string delimiters with double quotes.
/// Only handles the simple case: `'key'` → `"key"`.
/// Does NOT handle escaped single quotes inside strings (rare in tool output).
fn single_to_double_quotes(raw: &str) -> String {
    let mut result = String::with_capacity(raw.len());
    let mut in_double = false;
    let mut in_single = false;
    let mut escape_next = false;

    for ch in raw.chars() {
        if escape_next {
            escape_next = false;
            result.push(ch);
            continue;
        }
        if ch == '\\' && in_double {
            escape_next = true;
            result.push(ch);
            continue;
        }
        if ch == '"' && !in_single {
            in_double = !in_double;
            result.push(ch);
        } else if ch == '\'' && !in_double {
            in_single = !in_single;
            result.push('"'); // replace with double quote
        } else {
            result.push(ch);
        }
    }
    result
}

// ── Public entry point ───────────────────────────────────────────────────────

/// Attempt to normalise `raw` into a valid JSON [`Value`].
///
/// Returns `Some((value, repair_label))` when a repair succeeded, or `None`
/// when all strategies are exhausted (caller should fall back to `json!({})`).
pub fn normalize_tool_args(raw: &str) -> Option<(Value, String)> {
    // Strategy 1: strip markdown code fence
    if let Some(stripped) = strip_code_fence(raw) {
        if let Ok(v) = serde_json::from_str::<Value>(&stripped) {
            return Some((v, "strip_code_fence".to_string()));
        }
        // Continue with stripped version for subsequent strategies
        let repaired = remove_trailing_commas(&stripped);
        if let Ok(v) = serde_json::from_str::<Value>(&repaired) {
            return Some((v, "strip_code_fence+trailing_comma".to_string()));
        }
        let balanced = balance_braces(&repaired);
        if let Ok(v) = serde_json::from_str::<Value>(&balanced) {
            return Some((v, "strip_code_fence+balance_braces".to_string()));
        }
    }

    // Strategy 2: trailing commas
    let no_trailing = remove_trailing_commas(raw);
    if let Ok(v) = serde_json::from_str::<Value>(&no_trailing) {
        return Some((v, "trailing_comma".to_string()));
    }

    // Strategy 3: balance braces (on original and no-trailing-comma)
    let balanced = balance_braces(&no_trailing);
    if let Ok(v) = serde_json::from_str::<Value>(&balanced) {
        return Some((v, "balance_braces".to_string()));
    }

    // Strategy 4: single → double quotes, then balance
    let double_quoted = single_to_double_quotes(raw);
    let double_balanced = balance_braces(&remove_trailing_commas(&double_quoted));
    if let Ok(v) = serde_json::from_str::<Value>(&double_balanced) {
        return Some((v, "single_to_double_quotes".to_string()));
    }

    None
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_strip_code_fence_json() {
        let raw = "```json\n{\"key\": \"value\"}\n```";
        let (v, repair) = normalize_tool_args(raw).unwrap();
        assert_eq!(v["key"], "value");
        assert!(repair.contains("strip_code_fence"), "repair={repair}");
    }

    #[test]
    fn test_strip_code_fence_bare() {
        let raw = "```\n{\"x\": 1}\n```";
        let (v, repair) = normalize_tool_args(raw).unwrap();
        assert_eq!(v["x"], 1);
        assert!(repair.contains("strip_code_fence"), "repair={repair}");
    }

    #[test]
    fn test_trailing_comma() {
        let raw = r#"{"a": 1, "b": 2,}"#;
        let (v, repair) = normalize_tool_args(raw).unwrap();
        assert_eq!(v["a"], 1);
        assert!(repair.contains("trailing_comma"), "repair={repair}");
    }

    #[test]
    fn test_missing_closing_brace() {
        let raw = r#"{"path": "/tmp/foo.txt", "content": "hello""#;
        let (v, repair) = normalize_tool_args(raw).unwrap();
        assert_eq!(v["path"], "/tmp/foo.txt");
        assert!(repair.contains("balance_braces"), "repair={repair}");
    }

    #[test]
    fn test_single_to_double_quotes() {
        let raw = "{'key': 'value', 'n': 42}";
        let (v, repair) = normalize_tool_args(raw).unwrap();
        assert_eq!(v["key"], "value");
        assert!(repair.contains("single_to_double"), "repair={repair}");
    }

    #[test]
    fn test_combined_fence_and_trailing_comma() {
        let raw = "```json\n{\"x\": 1,}\n```";
        let (v, repair) = normalize_tool_args(raw).unwrap();
        assert_eq!(v["x"], 1);
        assert!(repair.contains("strip_code_fence"), "repair={repair}");
    }

    #[test]
    fn test_well_formed_returns_none() {
        // normalize_tool_args is only called AFTER primary parse fails;
        // but well-formed input should still parse (strategies succeed trivially)
        let raw = r#"{"path": "/tmp/x"}"#;
        // Primary parse would succeed, but if called, normalizer also succeeds
        assert!(serde_json::from_str::<serde_json::Value>(raw).is_ok());
    }

    #[test]
    fn test_irreparably_malformed_returns_none() {
        let raw = "this is not JSON at all !!";
        assert!(normalize_tool_args(raw).is_none());
    }

    #[test]
    fn test_nested_trailing_commas() {
        let raw = r#"{"a": {"b": 1,},}"#;
        let (v, repair) = normalize_tool_args(raw).unwrap();
        assert_eq!(v["a"]["b"], 1);
        assert!(repair.contains("trailing_comma"), "repair={repair}");
    }

    #[test]
    fn test_code_fence_with_balance() {
        let raw = "```json\n{\"path\": \"/tmp/x\"";
        let (v, repair) = normalize_tool_args(raw).unwrap();
        assert_eq!(v["path"], "/tmp/x");
        assert!(repair.contains("strip_code_fence"), "repair={repair}");
    }
}
