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
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// RESILIENT-375: `almanac-mcp` occasionally wedges (embeddings search on a
/// large index that never responds) with `run_almanac_search`'s
/// `BufReader::lines()` blocking forever on the child's stdout — observed
/// hanging `chump gap reserve` (and the swe/trek dedupe path) for 90s+ with
/// no way out short of killing the whole process. Bound the wait with a
/// watchdog thread that kills the child if it hasn't produced a result in
/// time, so a hung index degrades to "no hits" instead of wedging the caller.
/// Overridable for tests / operator tuning.
fn almanac_search_timeout() -> Duration {
    std::env::var("CHUMP_ALMANAC_SEARCH_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(Duration::from_secs(20))
}

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

/// Resolve the Almanac index db: `ALMANAC_DB`, else Almanac's live registry
/// index for this repo, else the legacy single-crate snapshot.
///
/// The fallback order matters and was wrong until 2026-08-05: it pointed
/// straight at `almanac/indexes/chump-src.db`, a frozen 2026-07-26 snapshot of
/// `src/` alone (302 files). Almanac's live index for this repo lives in its
/// registry at `~/.almanac/indexes/chump.db`, is re-indexed hourly when HEAD
/// moves, and covers 6,792 files. So every fallback query hit a 10-day-old index
/// that could not see `crates/`, `docs/`, `scripts/` or `e2e/` at all — measured
/// 0/16 on a gold set of questions about those trees, where the live index
/// scores 12/16.
fn almanac_db() -> Option<String> {
    if let Ok(db) = std::env::var("ALMANAC_DB") {
        if !db.trim().is_empty() && std::path::Path::new(&db).is_file() {
            return Some(db);
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    [
        // The live, hourly-refreshed registry index. Prefer it always.
        format!("{home}/.almanac/indexes/chump.db"),
        // Legacy snapshot, kept only so an almanac checkout predating the
        // multi-repo registry still answers instead of going dark.
        format!("{home}/Projects/almanac/indexes/chump-src.db"),
    ]
    .into_iter()
    .find(|c| std::path::Path::new(c).is_file())
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

    // Watchdog: kill the child if the read loop below hasn't finished within
    // the timeout. `done_rx.recv_timeout` blocks the watchdog thread, not the
    // reader — when the reader finishes first it signals via `done_tx` and
    // the watchdog exits without touching the (by-then-exited) child.
    let child = Arc::new(Mutex::new(child));
    let watchdog_child: Arc<Mutex<Child>> = Arc::clone(&child);
    let (done_tx, done_rx) = std::sync::mpsc::channel::<()>();
    let timeout = almanac_search_timeout();
    let watchdog = std::thread::spawn(move || {
        if done_rx.recv_timeout(timeout).is_err() {
            if let Ok(mut c) = watchdog_child.lock() {
                let _ = c.kill();
            }
        }
    });

    let mut result = String::new();
    for line in BufReader::new(stdout).lines() {
        let Ok(line) = line else {
            break;
        };
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

    let _ = done_tx.send(());
    let _ = watchdog.join();
    if let Ok(mut c) = child.lock() {
        let _ = c.kill();
        let _ = c.wait();
    }
    Ok(result.trim().to_string())
}

/// ZERO-WASTE-045: run a one-shot `almanac_search` query and return the raw
/// result text. `pub(crate)` wrapper over the same plumbing `AlmanacSearchTool`
/// uses, so `chump gap reserve` can search the full Almanac-indexed
/// `docs/gaps/*.yaml` corpus (3,489+ rows, including gaps shipped long
/// enough ago to have dropped out of state.db's closed-lookback window)
/// without going through the agent tool-call surface.
pub(crate) fn search_gap_corpus(query: &str) -> Result<String> {
    let bin = almanac_mcp_bin().ok_or_else(|| anyhow!("almanac-mcp binary not found"))?;
    let db = almanac_db().ok_or_else(|| anyhow!("almanac index (ALMANAC_DB) not found"))?;
    run_almanac_search(&bin, &db, query)
}

/// ZERO-WASTE-045: pull `docs/gaps/<ID>.yaml` gap IDs out of an Almanac
/// search result. Almanac results cite `path:line` (and sometimes
/// `path:line-line`); this scans for any path segment under `docs/gaps/`
/// and lifts the `.yaml` stem as a candidate gap ID. Pure + unit-tested so
/// the extraction logic doesn't require a live almanac-mcp binary to verify.
pub(crate) fn extract_gap_ids_from_search_output(output: &str) -> Vec<String> {
    let mut ids = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for token in output.split(|c: char| c.is_whitespace() || c == '"' || c == '\'') {
        let Some(idx) = token.find("docs/gaps/") else {
            continue;
        };
        let rest = &token[idx + "docs/gaps/".len()..];
        let Some(yaml_idx) = rest.find(".yaml") else {
            continue;
        };
        let id = &rest[..yaml_idx];
        if id.is_empty() || id.contains('/') {
            continue;
        }
        if seen.insert(id.to_string()) {
            ids.push(id.to_string());
        }
    }
    ids
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

    // ZERO-WASTE-045: extract_gap_ids_from_search_output tests.
    #[test]
    fn extract_gap_ids_finds_single_hit() {
        let out = "docs/gaps/ZERO-WASTE-045.yaml:1 dedupe gaps at reserve time";
        assert_eq!(
            extract_gap_ids_from_search_output(out),
            vec!["ZERO-WASTE-045".to_string()]
        );
    }

    #[test]
    fn extract_gap_ids_finds_multiple_hits_dedups() {
        let out = "docs/gaps/INFRA-1149.yaml:3 title similarity\n\
                    docs/gaps/INFRA-1149.yaml:9 similarity_candidates\n\
                    docs/gaps/CREDIBLE-217.yaml:1 CONFIG-organ cadence sweep";
        assert_eq!(
            extract_gap_ids_from_search_output(out),
            vec!["INFRA-1149".to_string(), "CREDIBLE-217".to_string()]
        );
    }

    #[test]
    fn extract_gap_ids_ignores_non_gap_paths() {
        let out = "src/main.rs:9299 reserve-time similarity check\ndocs/process/CLAUDE_GOTCHAS.md:1 notes";
        assert!(extract_gap_ids_from_search_output(out).is_empty());
    }

    #[test]
    fn extract_gap_ids_empty_on_empty_input() {
        assert!(extract_gap_ids_from_search_output("").is_empty());
    }

    #[test]
    fn almanac_disabled_is_unavailable() {
        // CHUMP_ALMANAC_ENABLED=0 short-circuits regardless of paths.
        std::env::set_var("CHUMP_ALMANAC_ENABLED", "0");
        assert!(!almanac_available());
        std::env::remove_var("CHUMP_ALMANAC_ENABLED");
    }

    // RESILIENT-375: a hung `almanac-mcp` child (e.g. an embeddings search
    // that never returns) must not wedge `run_almanac_search` forever. Point
    // it at a fake "binary" that reads stdin then sleeps well past the
    // configured timeout without ever writing to stdout — before the fix,
    // `BufReader::lines()` blocks on that child indefinitely and this test
    // hangs; after the fix, the watchdog kills the child and the call
    // returns within the bounded timeout with an empty result.
    #[test]
    fn hung_child_is_bounded_by_timeout() {
        let dir = tempfile::tempdir().unwrap();
        let script_path = dir.path().join("hung-almanac-mcp.sh");
        std::fs::write(&script_path, "#!/bin/sh\ncat >/dev/null\nsleep 60\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script_path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script_path, perms).unwrap();
        }

        std::env::set_var("CHUMP_ALMANAC_SEARCH_TIMEOUT_MS", "300");
        let start = std::time::Instant::now();
        let result = run_almanac_search(script_path.to_str().unwrap(), "/dev/null", "test query");
        let elapsed = start.elapsed();
        std::env::remove_var("CHUMP_ALMANAC_SEARCH_TIMEOUT_MS");

        assert!(
            elapsed < Duration::from_secs(10),
            "run_almanac_search did not bound the hung child: took {elapsed:?}"
        );
        assert_eq!(result.unwrap(), "");
    }
}
