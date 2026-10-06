//! MCP server: symbol search over the tree-sitter code index, JSON-RPC 2.0 over
//! stdio (same shape as `chump-mcp-gaps`). Set CHUMP_REPO (or CHUMP_HOME) to the
//! repo root.
//!
//! CLI:
//!   chump-mcp-code                 serve on stdio (alias: `serve`)
//!   chump-mcp-code index --all     (re)index the whole repo
//!   chump-mcp-code index --head    index only the files changed by HEAD (post-commit hook)
//!   chump-mcp-code index --files <rel-path>...
//!
//! Methods: tools/list, search_symbols, file_symbols, index_stats, reindex, plus the
//! Phase-1 existence queries code.find_symbol, code.callers_of, code.gap_history.

use anyhow::{anyhow, Result};
use chump_mcp_code as code;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::path::PathBuf;

#[derive(Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    method: String,
    #[serde(default)]
    params: Value,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcResponse {
    jsonrpc: String,
    result: Option<Value>,
    error: Option<JsonRpcError>,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcError {
    code: i32,
    message: String,
}

fn repo_dir() -> Result<PathBuf> {
    let path = std::env::var("CHUMP_REPO")
        .or_else(|_| std::env::var("CHUMP_HOME"))
        .map_err(|_| anyhow!("CHUMP_REPO or CHUMP_HOME must be set"))?;
    let p = PathBuf::from(path.trim());
    if !p.is_dir() {
        return Err(anyhow!("CHUMP_REPO is not a directory: {}", p.display()));
    }
    Ok(p)
}

fn open_index() -> Result<(PathBuf, rusqlite::Connection)> {
    let root = repo_dir()?;
    let conn = code::open_db(&code::db_path(&root))?;
    Ok((root, conn))
}

fn str_param<'a>(params: &'a Value, key: &str) -> Result<&'a str> {
    params
        .get(key)
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| anyhow!("missing required parameter: {key}"))
}

fn tools_list() -> Value {
    json!({"tools": [
        {
            "name": "search_symbols",
            "description": "Search indexed symbols (Rust, bash, Python) by name substring; exact matches first.",
            "inputSchema": {"type": "object", "properties": {
                "query": {"type": "string", "description": "Substring of the symbol name"},
                "kind": {"type": "string", "description": "Optional kind filter, e.g. fn, struct, class"},
                "limit": {"type": "integer", "description": "Max results (default 25)"}
            }, "required": ["query"]}
        },
        {
            "name": "file_symbols",
            "description": "List the symbols indexed for one repo-relative file, in line order.",
            "inputSchema": {"type": "object", "properties": {
                "path": {"type": "string", "description": "Repo-relative path, e.g. src/main.rs"}
            }, "required": ["path"]}
        },
        {
            "name": "index_stats",
            "description": "File and symbol counts, with a per-language breakdown.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "code.find_symbol",
            "description": "Does a symbol exist? Exact-name lookup in the index. Returns { symbol, exists, count, matches[] } — never an ambiguous empty list.",
            "inputSchema": {"type": "object", "properties": {
                "name": {"type": "string", "description": "Exact symbol name"},
                "kind": {"type": "string", "description": "Optional kind filter, e.g. fn, struct, class"}
            }, "required": ["name"]}
        },
        {
            "name": "code.callers_of",
            "description": "Call sites of a symbol in the indexed files (definitions and comments excluded). Returns { symbol, defined, count, truncated, callers[{path,line,text,in_symbol}] }.",
            "inputSchema": {"type": "object", "properties": {
                "symbol": {"type": "string", "description": "Symbol name"},
                "limit": {"type": "integer", "description": "Max call sites (default 50)"}
            }, "required": ["symbol"]}
        },
        {
            "name": "code.gap_history",
            "description": "Status of a gap id: open | done | reaped | never_existed, with shipped_pr and closed/reaped dates. 'reaped' = no registry row but git history proves the gap existed.",
            "inputSchema": {"type": "object", "properties": {
                "gap_id": {"type": "string", "description": "Gap id, e.g. INFRA-1575"}
            }, "required": ["gap_id"]}
        },
        {
            "name": "reindex",
            "description": "Re-index the given repo-relative paths (default: the whole repo). Unchanged files are skipped.",
            "inputSchema": {"type": "object", "properties": {
                "paths": {"type": "array", "items": {"type": "string"}, "description": "Repo-relative paths"}
            }}
        }
    ]})
}

fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "tools/list" => Ok(tools_list()),
        "search_symbols" => {
            let query = str_param(params, "query")?;
            let kind = params
                .get("kind")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty());
            let limit = params
                .get("limit")
                .and_then(|v| v.as_u64())
                .unwrap_or(25)
                .clamp(1, 500) as usize;
            let (_, conn) = open_index()?;
            let rows = code::search_symbols(&conn, query, kind, limit)?;
            Ok(json!({"count": rows.len(), "symbols": rows}))
        }
        "file_symbols" => {
            let path = str_param(params, "path")?;
            let (_, conn) = open_index()?;
            let rows = code::file_symbols(&conn, path)?;
            Ok(json!({"path": path, "count": rows.len(), "symbols": rows}))
        }
        "index_stats" => {
            let (_, conn) = open_index()?;
            code::index_summary(&conn)
        }
        "code.find_symbol" | "find_symbol" => {
            let name = str_param(params, "name")?;
            let kind = params
                .get("kind")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty());
            let (_, conn) = open_index()?;
            code::phase1::find_symbol(&conn, name, kind)
        }
        "code.callers_of" | "callers_of" => {
            let symbol = str_param(params, "symbol")?;
            let limit = params
                .get("limit")
                .and_then(|v| v.as_u64())
                .unwrap_or(50)
                .clamp(1, 500) as usize;
            let (root, conn) = open_index()?;
            code::phase1::callers_of(&conn, &root, symbol, limit)
        }
        "code.gap_history" | "gap_history" => {
            let gap_id = str_param(params, "gap_id")?;
            code::phase1::gap_history(&repo_dir()?, gap_id)
        }
        "reindex" => {
            let (root, conn) = open_index()?;
            let stats = match params.get("paths").and_then(|v| v.as_array()) {
                Some(arr) => {
                    let paths: Vec<String> = arr
                        .iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect();
                    code::index_files(&conn, &root, &paths)?
                }
                None => code::index_repo(&conn, &root)?,
            };
            Ok(serde_json::to_value(stats)?)
        }
        other => Err(anyhow!("unknown method: {other}")),
    }
}

fn serve() -> i32 {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let resp = match serde_json::from_str::<JsonRpcRequest>(line) {
            Err(e) => JsonRpcResponse {
                jsonrpc: "2.0".into(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32700,
                    message: format!("Parse error: {e}"),
                }),
                id: Value::Null,
            },
            Ok(req) if req.jsonrpc != "2.0" => JsonRpcResponse {
                jsonrpc: "2.0".into(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32600,
                    message: "Invalid Request: jsonrpc must be \"2.0\"".into(),
                }),
                id: req.id,
            },
            Ok(req) => match handle_method(&req.method, &req.params) {
                Ok(result) => JsonRpcResponse {
                    jsonrpc: "2.0".into(),
                    result: Some(result),
                    error: None,
                    id: req.id,
                },
                Err(e) => JsonRpcResponse {
                    jsonrpc: "2.0".into(),
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32603,
                        message: e.to_string(),
                    }),
                    id: req.id,
                },
            },
        };
        let _ = writeln!(
            out,
            "{}",
            serde_json::to_string(&resp).expect("response serializes")
        );
        let _ = out.flush();
    }
    0
}

fn run_index(args: &[String]) -> i32 {
    let result = (|| -> Result<code::IndexStats> {
        let (root, conn) = open_index()?;
        if args.iter().any(|a| a == "--head") {
            code::index_files(&conn, &root, &code::changed_files_in_head(&root))
        } else if let Some(pos) = args.iter().position(|a| a == "--files") {
            let files: Vec<String> = args[pos + 1..]
                .iter()
                .take_while(|a| !a.starts_with("--"))
                .cloned()
                .collect();
            if files.is_empty() {
                return Err(anyhow!("--files needs at least one repo-relative path"));
            }
            code::index_files(&conn, &root, &files)
        } else if args.iter().any(|a| a == "--all") {
            code::index_repo(&conn, &root)
        } else {
            Err(anyhow!(
                "usage: chump-mcp-code index (--all | --head | --files <path>...)"
            ))
        }
    })();
    match result {
        Ok(stats) => {
            println!("{}", serde_json::to_string(&stats).unwrap_or_default());
            0
        }
        Err(e) => {
            eprintln!("chump-mcp-code index: {e}");
            1
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        None | Some("serve") => serve(),
        Some("index") => run_index(&args[1..]),
        Some("--help") | Some("-h") => {
            println!("chump-mcp-code [serve | index (--all | --head | --files <path>...)]");
            0
        }
        Some(other) => {
            eprintln!("chump-mcp-code: unknown argument '{other}' (try --help)");
            2
        }
    };
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tools_list_has_the_expected_tools() {
        let tools = handle_method("tools/list", &json!({})).unwrap();
        let names: Vec<&str> = tools["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            [
                "search_symbols",
                "file_symbols",
                "index_stats",
                "code.find_symbol",
                "code.callers_of",
                "code.gap_history",
                "reindex"
            ]
        );
    }

    #[test]
    fn missing_params_and_unknown_methods_error() {
        assert!(handle_method("search_symbols", &json!({}))
            .unwrap_err()
            .to_string()
            .contains("query"));
        assert!(handle_method("file_symbols", &json!({"path": " "}))
            .unwrap_err()
            .to_string()
            .contains("path"));
        assert!(handle_method("code.find_symbol", &json!({}))
            .unwrap_err()
            .to_string()
            .contains("name"));
        assert!(handle_method("code.callers_of", &json!({}))
            .unwrap_err()
            .to_string()
            .contains("symbol"));
        assert!(handle_method("code.gap_history", &json!({}))
            .unwrap_err()
            .to_string()
            .contains("gap_id"));
        assert!(handle_method("does_not_exist", &json!({}))
            .unwrap_err()
            .to_string()
            .contains("unknown method"));
    }
}
