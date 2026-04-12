//! Strip model "thinking" / plan blocks from text shown to users (Discord, web TurnComplete, etc.).

/// Default max characters for [`preview_for_log`] when `CHUMP_THINKING_LOG_MAX_CHARS` is unset.
pub const DEFAULT_THINKING_LOG_MAX_CHARS: usize = 2048;

/// Preview string for tracing: full string if short, otherwise first N chars (Unicode-safe) plus ellipsis.
/// `full_len` is character count of `s`. Max length from `CHUMP_THINKING_LOG_MAX_CHARS` or [`DEFAULT_THINKING_LOG_MAX_CHARS`].
pub fn preview_for_log(s: &str) -> LogStringPreview {
    let max_c = std::env::var("CHUMP_THINKING_LOG_MAX_CHARS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(DEFAULT_THINKING_LOG_MAX_CHARS);
    let full_len = s.chars().count();
    if full_len <= max_c {
        LogStringPreview {
            preview: s.to_string(),
            full_len,
            truncated: false,
        }
    } else {
        let p: String = s.chars().take(max_c).collect();
        LogStringPreview {
            preview: format!("{p}…"),
            full_len,
            truncated: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct LogStringPreview {
    pub preview: String,
    pub full_len: usize,
    pub truncated: bool,
}

/// Case-insensitive find of ASCII `needle` in `haystack`.
fn find_ci(haystack: &str, needle: &str) -> Option<usize> {
    let h = haystack.as_bytes();
    let n = needle.as_bytes();
    if n.is_empty() || h.len() < n.len() {
        return None;
    }
    'outer: for i in 0..=h.len() - n.len() {
        for j in 0..n.len() {
            if !h[i + j].eq_ignore_ascii_case(&n[j]) {
                continue 'outer;
            }
        }
        return Some(i);
    }
    None
}

/// Remove all well-formed blocks `<thinking ...> ... </thinking>` (case-insensitive).
fn strip_tag_blocks(mut s: String, open_prefix: &str, close_tag: &str) -> String {
    let close_lower = close_tag.to_lowercase();
    loop {
        let Some(start) = find_ci(&s, open_prefix) else {
            break;
        };
        let Some(gt_rel) = s[start..].find('>') else {
            s = format!("{}{}", &s[..start], &s[start + 1..]);
            continue;
        };
        let content_start = start + gt_rel + 1;
        let tail_lower = s[content_start..].to_lowercase();
        let Some(rel) = tail_lower.find(&close_lower) else {
            s = s[..start].to_string();
            break;
        };
        let remove_end = content_start + rel + close_tag.len();
        s = format!("{}{}", &s[..start], &s[remove_end..]);
    }
    s
}

/// Remove legacy `think>` lines and trim.
fn strip_think_lines(s: &str) -> String {
    s.lines()
        .filter(|line| !line.trim_start().to_lowercase().starts_with("think>"))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

/// If the first non-whitespace content is a well-formed `<plan>...</plan>` block (case-insensitive),
/// returns `(Some(inner), remainder_after_closing_tag)`. Otherwise `(None, text)`.
pub fn split_leading_plan_block(text: &str) -> (Option<String>, &str) {
    let trim_start = text
        .char_indices()
        .find(|(_, c)| !c.is_whitespace())
        .map(|(i, _)| i)
        .unwrap_or(text.len());
    let tail = &text[trim_start..];
    if find_ci(tail, "<plan") != Some(0) {
        return (None, text);
    }
    let gt_rel = match tail.find('>') {
        Some(g) => g,
        None => return (None, text),
    };
    let content_start = gt_rel + 1;
    let rest_after_gt = &tail[content_start..];
    let close_tag = "</plan>";
    let tail_lower = rest_after_gt.to_lowercase();
    let rel = match tail_lower.find(&close_tag.to_lowercase()) {
        Some(r) => r,
        None => return (None, text),
    };
    let inner = rest_after_gt[..rel].trim().to_string();
    let after_close = trim_start + content_start + rel + close_tag.len();
    let remainder = text.get(after_close..).unwrap_or("").trim_start();
    (Some(inner), remainder)
}

/// Strips an optional leading `<plan>` block, then parses [`split_thinking_payload`].
/// Returns `(plan_inner, thinking_inner, remainder)` for tool / `Using tool` parsing.
pub fn peel_plan_and_thinking_for_tools(text: &str) -> (Option<String>, Option<String>, &str) {
    let (plan_opt, after_plan) = split_leading_plan_block(text);
    let (think_opt, rest) = split_thinking_payload(after_plan);
    (plan_opt, think_opt, rest)
}

/// If `text` contains a well-formed `<thinking>...</thinking>` block (case-insensitive tags),
/// returns `(Some(inner), remainder_after_closing_tag)`. Otherwise `(None, text)` so callers
/// can keep parsing tool JSON from the full string.
pub fn split_thinking_payload(text: &str) -> (Option<String>, &str) {
    let start_idx = match find_ci(text, "<thinking") {
        Some(i) => i,
        None => return (None, text),
    };
    let after_open = &text[start_idx..];
    let gt_rel = match after_open.find('>') {
        Some(g) => g,
        None => return (None, text),
    };
    let content_start = start_idx + gt_rel + 1;
    let tail = &text[content_start..];
    let close_tag = "</thinking>";
    let tail_lower = tail.to_lowercase();
    let rel = match tail_lower.find(&close_tag.to_lowercase()) {
        Some(r) => r,
        None => return (None, text),
    };
    let inner = tail[..rel].trim().to_string();
    let after_close = content_start + rel + close_tag.len();
    let rest = text.get(after_close..).unwrap_or("").trim_start();
    (Some(inner), rest)
}

/// Remove `Using tool 'X' with input: {json}` lines so they do not appear in chat UIs.
pub fn strip_text_tool_call_lines(text: &str) -> String {
    let cleaned: Vec<&str> = text
        .lines()
        .filter(|l| {
            let t = l.trim();
            !(t.starts_with("Using tool '") && t.contains("' with input:"))
        })
        .collect();
    cleaned.join("\n").trim().to_string()
}

/// Assistant text safe for incremental streaming bubbles (tool lines and thinking blocks removed).
pub fn strip_for_streaming_preview(text: &str) -> String {
    strip_for_public_reply(&strip_text_tool_call_lines(text))
}

/// Strip `<thinking>`, `<plan>`, `<think>`, and `think>` lines for user-visible surfaces.
pub fn strip_for_public_reply(reply: &str) -> String {
    let mut out = reply.to_string();
    out = strip_tag_blocks(
        out,
        "<redacted_thinking",
        concat!("</", "redacted", "_", "thinking", ">"),
    );
    out = strip_tag_blocks(out, "<thinking", "</thinking>");
    out = strip_tag_blocks(out, "<plan", "</plan>");
    strip_think_lines(&out)
}

#[cfg(test)]
mod tests {
    use super::{peel_plan_and_thinking_for_tools, split_thinking_payload, strip_for_public_reply};

    #[test]
    fn split_thinking_then_tool_lines() {
        let s = "<thinking>\nplan\n</thinking>\nUsing tool 'memory' with input: {}\n";
        let (mono, rest) = split_thinking_payload(s);
        assert_eq!(mono.as_deref(), Some("plan"));
        assert!(rest.contains("Using tool"));
    }

    #[test]
    fn peel_plan_then_thinking_then_tools() {
        let s = "<plan>1. a\n2. b</plan>\n<thinking>why</thinking>\nUsing tool 'memory' with input: {}\n";
        let (p, t, rest) = peel_plan_and_thinking_for_tools(s);
        assert_eq!(p.as_deref(), Some("1. a\n2. b"));
        assert_eq!(t.as_deref(), Some("why"));
        assert!(rest.contains("Using tool"));
    }

    #[test]
    fn split_leading_plan_only() {
        let s = "  <plan>x</plan> tail";
        let (p, rest) = super::split_leading_plan_block(s);
        assert_eq!(p.as_deref(), Some("x"));
        assert_eq!(rest, "tail");
    }

    #[test]
    fn split_thinking_missing_close_yields_none() {
        let s = "<thinking>oops no close";
        let (mono, rest) = split_thinking_payload(s);
        assert!(mono.is_none());
        assert_eq!(rest, s);
    }

    #[test]
    fn split_thinking_case_insensitive() {
        let s = "<THINKING mode=\"x\">hi</thinking>tail";
        let (mono, rest) = split_thinking_payload(s);
        assert_eq!(mono.as_deref(), Some("hi"));
        assert_eq!(rest, "tail");
    }

    #[test]
    fn streaming_preview_strips_thinking_and_tool_lines() {
        let s = "<thinking>x</thinking>\nUsing tool 'memory' with input: {}\nhello";
        assert_eq!(super::strip_for_streaming_preview(s), "hello");
    }

    #[test]
    #[serial_test::serial]
    fn preview_for_log_truncates_by_chars() {
        let s = "α".repeat(10);
        let p = super::preview_for_log(&s);
        assert!(!p.truncated);
        assert_eq!(p.full_len, 10);
        std::env::set_var("CHUMP_THINKING_LOG_MAX_CHARS", "4");
        let p2 = super::preview_for_log(&s);
        std::env::remove_var("CHUMP_THINKING_LOG_MAX_CHARS");
        assert!(p2.truncated);
        assert_eq!(p2.full_len, 10);
        assert!(p2.preview.contains('…'));
    }

    #[test]
    fn strips_thinking_block_compact() {
        let s = "Hello\n<thinking>\nsecret\n</thinking>\nWorld";
        assert_eq!(strip_for_public_reply(s), "Hello\n\nWorld");
    }

    #[test]
    fn strips_plan_with_attr() {
        let s = "X <Plan mode=\"draft\">steps</Plan> Y";
        assert_eq!(strip_for_public_reply(s), "X  Y");
    }

    #[test]
    fn strips_redacted_thinking() {
        let s = "A <Redacted_Thinking>x</Redacted_Thinking> B";
        assert_eq!(strip_for_public_reply(s), "A  B");
    }
}
