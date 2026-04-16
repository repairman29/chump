//! Cross-session memory search: agent can query past web-chat conversations and get
//! LLM-summarized results. Backed by the `web_messages_fts` FTS5 virtual table over
//! `chump_web_messages`. Optionally summarized via [`crate::delegate_tool`].

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

const DEFAULT_LIMIT: usize = 10;
const MAX_LIMIT: usize = 50;
const MAX_MSG_CHARS: usize = 500;

/// Escape a free-form query for FTS5 MATCH: wrap each whitespace-delimited token in
/// double quotes (escaping internal quotes) so punctuation is treated as literal.
/// Mirrors the pattern used in `memory_db::escape_fts5_query`.
fn escape_fts5_query(s: &str) -> String {
    s.split_whitespace()
        .map(|t| {
            let escaped = t.replace('"', "\"\"");
            format!("\"{}\"", escaped)
        })
        .collect::<Vec<_>>()
        .join(" OR ")
}

fn truncate_for_output(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max_chars.saturating_sub(1)).collect();
    out.push('…');
    out
}

#[derive(Debug, Clone)]
struct SessionMessageHit {
    id: i64,
    session_id: String,
    role: String,
    content: String,
    created_at: String,
}

/// Run the FTS5 query against `web_messages_fts` joined with `chump_web_messages`.
/// Returns Ok(None) if the FTS table doesn't exist yet (no web chats stored).
fn fts_search(query: &str, limit: usize) -> Result<Option<Vec<SessionMessageHit>>> {
    let conn = match crate::db_pool::get() {
        Ok(c) => c,
        Err(e) => return Err(anyhow!("db unavailable: {}", e)),
    };
    let fts_exists: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='web_messages_fts'",
        [],
        |r| r.get(0),
    )?;
    if fts_exists == 0 {
        return Ok(None);
    }

    let pattern = escape_fts5_query(query);
    let limit = limit.min(MAX_LIMIT);

    let map_row = |r: &rusqlite::Row<'_>| -> rusqlite::Result<SessionMessageHit> {
        Ok(SessionMessageHit {
            id: r.get(0)?,
            session_id: r.get(1)?,
            role: r.get(2)?,
            content: r.get(3)?,
            created_at: r.get(4)?,
        })
    };
    let rows: Vec<SessionMessageHit> = if pattern.is_empty() {
        let mut stmt = conn.prepare(
            "SELECT m.id, m.session_id, m.role, m.content, m.created_at \
             FROM chump_web_messages m \
             ORDER BY m.id DESC LIMIT ?1",
        )?;
        let collected: Vec<SessionMessageHit> = stmt
            .query_map([limit], map_row)?
            .collect::<Result<Vec<_>, _>>()?;
        collected
    } else {
        let mut stmt = conn.prepare(
            "SELECT m.id, m.session_id, m.role, m.content, m.created_at \
             FROM chump_web_messages m \
             INNER JOIN web_messages_fts f ON f.rowid = m.id \
             WHERE web_messages_fts MATCH ?1 \
             ORDER BY m.id DESC LIMIT ?2",
        )?;
        let collected: Vec<SessionMessageHit> = stmt
            .query_map(rusqlite::params![pattern, limit], map_row)?
            .collect::<Result<Vec<_>, _>>()?;
        collected
    };
    Ok(Some(rows))
}

fn format_raw_results(query: &str, hits: &[SessionMessageHit]) -> String {
    let mut out = format!(
        "Found {} past message(s) matching \"{}\":\n",
        hits.len(),
        query
    );
    for (i, h) in hits.iter().enumerate() {
        let body = truncate_for_output(&h.content, MAX_MSG_CHARS);
        out.push_str(&format!(
            "\n{}. [session={} role={} at={} id={}]\n{}\n",
            i + 1,
            h.session_id,
            h.role,
            h.created_at,
            h.id,
            body,
        ));
    }
    out
}

fn build_summarize_input(query: &str, hits: &[SessionMessageHit]) -> String {
    let mut s = format!(
        "Past conversation excerpts relevant to query: {}\n\n",
        query
    );
    for h in hits.iter() {
        let body = truncate_for_output(&h.content, MAX_MSG_CHARS);
        s.push_str(&format!(
            "[session={} role={} at={}]\n{}\n\n",
            h.session_id, h.role, h.created_at, body
        ));
    }
    s.push_str(&format!(
        "\nSummarize these past conversations relevant to: {}. Return 3-5 bullet points and cite the relevant session ids in brackets like [session=...].",
        query
    ));
    s
}

pub struct SessionSearchTool;

impl Default for SessionSearchTool {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionSearchTool {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Tool for SessionSearchTool {
    fn name(&self) -> String {
        "session_search".to_string()
    }

    fn description(&self) -> String {
        "Search past web-chat sessions for messages matching a query. Returns top N \
         matches (with session_id, role, timestamp, and content). When summarize=true \
         (default), an LLM worker condenses results into a few bullet points with \
         session-id citations; falls back to raw results if the worker is unavailable."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "What to search for in past conversations"
                },
                "limit": {
                    "type": "number",
                    "description": "Max results to return (default 10, max 50)"
                },
                "summarize": {
                    "type": "boolean",
                    "description": "If true (default), summarize results via the delegate worker"
                }
            },
            "required": ["query"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let query = input
            .get("query")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        if query.is_empty() {
            return Err(anyhow!("missing or empty query"));
        }
        let limit = input
            .get("limit")
            .and_then(|v| v.as_u64().or_else(|| v.as_i64().map(|i| i as u64)))
            .map(|n| n as usize)
            .unwrap_or(DEFAULT_LIMIT)
            .min(MAX_LIMIT)
            .max(1);
        let summarize = input
            .get("summarize")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);

        let hits = match fts_search(&query, limit) {
            Ok(Some(h)) => h,
            Ok(None) => {
                return Ok(
                    "No past sessions to search yet (web_messages_fts not initialized)."
                        .to_string(),
                );
            }
            Err(e) => return Err(anyhow!("session search failed: {}", e)),
        };

        if hits.is_empty() {
            return Ok(format!("No past messages matched \"{}\".", query));
        }

        let raw = format_raw_results(&query, &hits);

        if !summarize {
            return Ok(raw);
        }

        // Try LLM summarization via the delegate worker; fall back to raw on any error.
        let prompt_text = build_summarize_input(&query, &hits);
        match crate::delegate_tool::run_delegate_summarize(&prompt_text, 6).await {
            Ok(summary) if !summary.trim().is_empty() => Ok(format!(
                "Summary of {} past message(s) matching \"{}\":\n{}\n\n--- raw matches ---\n{}",
                hits.len(),
                query,
                summary.trim(),
                raw,
            )),
            _ => Ok(raw),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn schema_advertises_query_required() {
        let tool = SessionSearchTool::new();
        let schema = tool.input_schema();
        assert_eq!(tool.name(), "session_search");
        assert_eq!(
            schema
                .get("required")
                .and_then(|v| v.as_array())
                .map(|a| a.iter().any(|x| x.as_str() == Some("query")))
                .unwrap_or(false),
            true,
            "query should be required: {schema}"
        );
        let props = schema.get("properties").unwrap();
        assert!(props.get("query").is_some());
        assert!(props.get("limit").is_some());
        assert!(props.get("summarize").is_some());
    }

    #[tokio::test]
    async fn empty_query_returns_error() {
        let tool = SessionSearchTool::new();
        let err = tool.execute(json!({ "query": "   " })).await;
        assert!(err.is_err(), "expected error for empty query");
        let msg = err.unwrap_err().to_string();
        assert!(msg.contains("query"), "unexpected error msg: {msg}");

        let err = tool.execute(json!({})).await;
        assert!(err.is_err(), "expected error when query missing");
    }

    #[test]
    fn fts5_escape_treats_punctuation_as_literal() {
        // No tokens -> empty string (caller treats as "latest" branch).
        assert_eq!(escape_fts5_query(""), "");
        assert_eq!(escape_fts5_query("   \t  "), "");

        // Single token with punctuation should get quoted.
        let out = escape_fts5_query("key:value");
        assert_eq!(out, "\"key:value\"");

        // Multiple tokens joined with OR.
        let out = escape_fts5_query("hello world");
        assert_eq!(out, "\"hello\" OR \"world\"");

        // Embedded double quotes are doubled per FTS5 escape rules.
        let out = escape_fts5_query("he said \"hi\"");
        assert!(out.contains("\"\""), "should escape inner quotes: {out}");
    }

    #[test]
    fn truncate_caps_long_messages() {
        let long: String = "a".repeat(2000);
        let out = truncate_for_output(&long, MAX_MSG_CHARS);
        assert!(out.chars().count() <= MAX_MSG_CHARS);
        assert!(out.ends_with('…'));
        // Short strings pass through unchanged.
        assert_eq!(truncate_for_output("short", MAX_MSG_CHARS), "short");
    }
}
