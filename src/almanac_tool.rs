//! `almanac_search` — grounded code search over the Almanac index for the
//! NATIVE agent loop (EFFECTIVE-324).
//!
//! `context_assembly.rs` already tells the agent to "call almanac_search FIRST",
//! and opencode gets the almanac_* MCP tools — but the native ChumpAgent loop
//! did NOT register them, so a free-tier worker was told to call a tool that did
//! not exist and fell back to blind `list_dir`/`read_file` (observed 2026-07-27:
//! devstral got 6 tool calls in 700s, all exploration, never reached the target).
//! This registers the tool so the agent jumps straight to the relevant file:line
//! — fewer turns = faster + cheaper. This is the OS gaining the ability to search
//! itself while constructing itself.
//!
//! Implementation: shells out to the same proven `almanac-mcp` JSON-RPC server
//! opencode uses (one-shot stdio call). Registers only `when_enabled` — absent
//! binary/index → the tool is simply not offered (no hard dependency).

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

pub struct AlmanacSearchTool;

/// Resolve the `almanac-mcp` binary: `CHUMP_ALMANAC_MCP_BIN`, then common
/// checkout locations, then `PATH`.
fn almanac_mcp_bin() -> Option<String> {
    if let Ok(b) = std::env::var("CHUMP_ALMANAC_MCP_BIN") {
        if std::path::Path::new(&b).is_file() {
            return Some(b);
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    [
        format!("{home}/Projects/almanac/target/release/almanac-mcp"),
        format!("{home}/Projects/almanac/target/debug/almanac-mcp"),
    ]
    .into_iter()
    .find(|c| std::path::Path::new(c).is_file())
}

/// Resolve the Almanac index db: `ALMANAC_DB`, else the default chump index.
fn almanac_db() -> Option<String> {
    if let Ok(db) = std::env::var("ALMANAC_DB") {
        if !db.trim().is_empty() && std::path::Path::new(&db).is_file() {
            return Some(db);
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let c = format!("{home}/Projects/almanac/indexes/chump-src.db");
    std::path::Path::new(&c).is_file().then_some(c)
}

/// True when almanac_search is usable (binary + index present, not disabled).
pub fn almanac_available() -> bool {
    if std::env::var("CHUMP_ALMANAC_ENABLED").as_deref() == Ok("0") {
        return false;
    }
    almanac_mcp_bin().is_some() && almanac_db().is_some()
}

/// Extract the human-readable text from an MCP `tools/call` JSON-RPC response
/// (`result.content[].text`, joined). Falls back to pretty-printing `result`.
/// Pure — unit-tested.
fn extract_result_text(v: &Value) -> String {
    if let Some(content) = v
        .get("result")
        .and_then(|r| r.get("content"))
        .and_then(|c| c.as_array())
    {
        let mut out = String::new();
        for item in content {
            if let Some(t) = item.get("text").and_then(|t| t.as_str()) {
                out.push_str(t);
                out.push('\n');
            }
        }
        return out.trim().to_string();
    }
    v.get("result")
        .map(|r| serde_json::to_string_pretty(r).unwrap_or_default())
        .unwrap_or_default()
        .trim()
        .to_string()
}

/// One-shot JSON-RPC `tools/call almanac_search` against the mcp server.
fn run_almanac_search(bin: &str, db: &str, query: &str) -> Result<String> {
    let mut child = Command::new(bin)
        .env("ALMANAC_DB", db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| anyhow!("spawn almanac-mcp: {e}"))?;
    let req = json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "almanac_search", "arguments": {"query": query}}
    });
    {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| anyhow!("almanac: no stdin"))?;
        writeln!(stdin, "{req}")?;
        stdin.flush()?;
    }
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("almanac: no stdout"))?;
    let mut result = String::new();
    for line in BufReader::new(stdout).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if v.get("id").and_then(|x| x.as_i64()) == Some(1) {
            result = extract_result_text(&v);
            break;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    Ok(result.trim().to_string())
}

#[async_trait]
impl Tool for AlmanacSearchTool {
    fn name(&self) -> String {
        "almanac_search".to_string()
    }

    fn description(&self) -> String {
        "Grounded semantic search over THIS codebase's Almanac index. For any \
         'where / how does X work' question, call this FIRST — it returns the \
         exact file:line locations for a concept, so you jump straight there \
         instead of guessing with list_dir/read_file. Much faster than blind \
         exploration on a large repo. Params: query (required, plain language, \
         e.g. 'where the outcome gate blocks P0 reserves')."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "What to find, in plain language"
                }
            },
            "required": ["query"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{e}"));
        }
        let query = input
            .get("query")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        if query.is_empty() {
            return Err(anyhow!("almanac_search: 'query' is required"));
        }
        let bin = almanac_mcp_bin().ok_or_else(|| anyhow!("almanac-mcp binary not found"))?;
        let db = almanac_db().ok_or_else(|| anyhow!("almanac index (ALMANAC_DB) not found"))?;
        let out = tokio::task::spawn_blocking(move || run_almanac_search(&bin, &db, &query))
            .await
            .map_err(|e| anyhow!("almanac_search task: {e}"))??;
        if out.is_empty() {
            Ok(
                "almanac_search: no grounded hits — fall back to grep_repo or list_dir."
                    .to_string(),
            )
        } else {
            Ok(out)
        }
    }
}

inventory::submit! {
    crate::tool_inventory::ToolEntry::new(|| Box::new(AlmanacSearchTool), "almanac_search")
        .when_enabled(almanac_available)
}

// EFFECTIVE-324 test coverage.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_name_and_schema_are_stable() {
        let t = AlmanacSearchTool;
        assert_eq!(t.name(), "almanac_search");
        let schema = t.input_schema();
        assert_eq!(
            schema["required"].as_array().unwrap()[0].as_str().unwrap(),
            "query"
        );
    }

    #[test]
    fn extract_result_text_joins_mcp_content() {
        let v = json!({
            "id": 1,
            "result": {"content": [{"type": "text", "text": "src/main.rs:42 outcome gate"}]}
        });
        assert_eq!(extract_result_text(&v), "src/main.rs:42 outcome gate");
    }

    #[test]
    fn extract_result_text_joins_multiple_hits() {
        let v = json!({
            "result": {"content": [
                {"text": "a.rs:1"}, {"text": "b.rs:2"}
            ]}
        });
        assert_eq!(extract_result_text(&v), "a.rs:1\nb.rs:2");
    }

    #[test]
    fn extract_result_text_empty_on_no_result() {
        assert_eq!(extract_result_text(&json!({"id": 1})), "");
    }

    #[test]
    fn almanac_disabled_is_unavailable() {
        // CHUMP_ALMANAC_ENABLED=0 short-circuits regardless of paths.
        std::env::set_var("CHUMP_ALMANAC_ENABLED", "0");
        assert!(!almanac_available());
        std::env::remove_var("CHUMP_ALMANAC_ENABLED");
    }
}
