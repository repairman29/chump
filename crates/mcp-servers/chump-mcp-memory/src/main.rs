//! MCP server: Chump session memory — search, recall, and episode logging via JSON-RPC 2.0 over stdio.
//!
//! Environment:
//!   CHUMP_REPO or CHUMP_HOME — repo root (DB lives at <root>/sessions/chump_memory.db)
//!   CHUMP_MEMORY_DB          — override absolute path to the SQLite DB
//!
//! Tools:
//!   memory_search  { query, limit? }           — FTS5 keyword search over semantic memory
//!   memory_recall  { entity }                  — LIKE-search for a named entity/topic
//!   episode_save   { content, tags?, sentiment?, repo? } — append episodic event
//!   episode_search { query, limit? }           — search episode history

use anyhow::{anyhow, Result};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, BufReader};

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

#[cfg(test)]
thread_local! {
    static TEST_DB_PATH: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn set_test_db(path: Option<PathBuf>) {
    TEST_DB_PATH.with(|c| *c.borrow_mut() = path);
}

fn db_path() -> Result<PathBuf> {
    #[cfg(test)]
    if let Some(p) = TEST_DB_PATH.with(|c| c.borrow().clone()) {
        return Ok(p);
    }
    if let Ok(p) = std::env::var("CHUMP_MEMORY_DB") {
        return Ok(PathBuf::from(p.trim()));
    }
    let root = std::env::var("CHUMP_REPO")
        .or_else(|_| std::env::var("CHUMP_HOME"))
        .map(|p| PathBuf::from(p.trim()))
        .unwrap_or_else(|_| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    Ok(root.join("sessions").join("chump_memory.db"))
}

fn open_db() -> Result<Connection> {
    let path = db_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| anyhow!("cannot create sessions dir: {}", e))?;
    }
    let conn =
        Connection::open(&path).map_err(|e| anyhow!("cannot open {}: {}", path.display(), e))?;
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS chump_memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            ts TEXT NOT NULL DEFAULT (datetime('now')),
            source TEXT NOT NULL DEFAULT 'mcp',
            confidence REAL DEFAULT 1.0,
            verified INTEGER DEFAULT 0,
            sensitivity TEXT DEFAULT 'internal',
            expires_at TEXT,
            memory_type TEXT DEFAULT 'semantic_fact'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            content, content='chump_memory', content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON chump_memory BEGIN
            INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_fts_delete AFTER DELETE ON chump_memory BEGIN
            INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_fts_update AFTER UPDATE ON chump_memory BEGIN
            INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
            INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TABLE IF NOT EXISTS chump_episodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            happened_at TEXT NOT NULL DEFAULT (datetime('now')),
            summary TEXT NOT NULL,
            detail TEXT,
            tags TEXT,
            repo TEXT,
            sentiment TEXT CHECK(sentiment IN ('win','loss','neutral','frustrating','uncertain')),
            pr_number INTEGER,
            issue_number INTEGER
        );
        ",
    )?;
    Ok(conn)
}

async fn handle_memory_search(params: &Value) -> Result<Value> {
    let query = params
        .get("query")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing query"))?
        .trim()
        .to_string();
    let limit = params
        .get("limit")
        .and_then(|v| v.as_u64())
        .unwrap_or(10)
        .min(50) as usize;

    let conn = open_db()?;

    // Try FTS5 first; fall back to LIKE if FTS table isn't populated or query is ill-formed.
    let rows = fts_search(&conn, &query, limit).or_else(|_| like_search(&conn, &query, limit))?;

    Ok(json!({ "success": true, "count": rows.len(), "results": rows }))
}

fn fts_search(conn: &Connection, query: &str, limit: usize) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare(
        "SELECT m.id, m.content, m.ts, m.source, m.memory_type \
         FROM chump_memory m \
         JOIN memory_fts ON memory_fts.rowid = m.id \
         WHERE memory_fts MATCH ?1 \
         ORDER BY rank LIMIT ?2",
    )?;
    let rows = stmt
        .query_map(rusqlite::params![query, limit], |r| {
            Ok(json!({
                "id": r.get::<_,i64>(0)?,
                "content": r.get::<_,String>(1)?,
                "ts": r.get::<_,String>(2)?,
                "source": r.get::<_,String>(3)?,
                "memory_type": r.get::<_,String>(4)?,
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

fn like_search(conn: &Connection, query: &str, limit: usize) -> Result<Vec<Value>> {
    let pattern = format!("%{}%", query);
    let mut stmt = conn.prepare(
        "SELECT id, content, ts, source, memory_type \
         FROM chump_memory WHERE content LIKE ?1 ORDER BY id DESC LIMIT ?2",
    )?;
    let rows = stmt
        .query_map(rusqlite::params![pattern, limit], |r| {
            Ok(json!({
                "id": r.get::<_,i64>(0)?,
                "content": r.get::<_,String>(1)?,
                "ts": r.get::<_,String>(2)?,
                "source": r.get::<_,String>(3)?,
                "memory_type": r.get::<_,String>(4)?,
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

async fn handle_memory_recall(params: &Value) -> Result<Value> {
    let entity = params
        .get("entity")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing entity"))?
        .trim()
        .to_string();
    if entity.is_empty() {
        return Err(anyhow!("entity must not be empty"));
    }
    let conn = open_db()?;
    let rows = like_search(&conn, &entity, 20)?;
    Ok(json!({ "success": true, "entity": entity, "count": rows.len(), "results": rows }))
}

async fn handle_episode_save(params: &Value) -> Result<Value> {
    let content = params
        .get("content")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing content"))?
        .trim()
        .to_string();
    if content.is_empty() {
        return Err(anyhow!("content must not be empty"));
    }
    let tags = params
        .get("tags")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    let sentiment = params
        .get("sentiment")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_lowercase())
        .filter(|s| ["win", "loss", "neutral", "frustrating", "uncertain"].contains(&s.as_str()))
        .unwrap_or_else(|| "neutral".to_string());
    let repo = params
        .get("repo")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    let conn = open_db()?;
    conn.execute(
        "INSERT INTO chump_episodes (summary, tags, repo, sentiment) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![content, tags, repo, sentiment],
    )?;
    let id = conn.last_insert_rowid();
    Ok(json!({ "success": true, "id": id, "sentiment": sentiment }))
}

async fn handle_episode_search(params: &Value) -> Result<Value> {
    let query = params
        .get("query")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing query"))?
        .trim()
        .to_string();
    let limit = params
        .get("limit")
        .and_then(|v| v.as_u64())
        .unwrap_or(10)
        .min(50) as usize;
    let repo_filter = params
        .get("repo")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let conn = open_db()?;
    let pattern = format!("%{}%", query);
    let rows: Vec<Value> = if let Some(repo) = repo_filter {
        let mut stmt = conn.prepare(
            "SELECT id, happened_at, summary, tags, repo, sentiment \
             FROM chump_episodes \
             WHERE (summary LIKE ?1 OR detail LIKE ?1 OR tags LIKE ?1) AND repo = ?2 \
             ORDER BY id DESC LIMIT ?3",
        )?;
        let r = stmt
            .query_map(rusqlite::params![pattern, repo, limit], episode_row)?
            .collect::<Result<Vec<_>, _>>()?;
        r
    } else {
        let mut stmt = conn.prepare(
            "SELECT id, happened_at, summary, tags, repo, sentiment \
             FROM chump_episodes \
             WHERE summary LIKE ?1 OR detail LIKE ?1 OR tags LIKE ?1 \
             ORDER BY id DESC LIMIT ?2",
        )?;
        let r = stmt
            .query_map(rusqlite::params![pattern, limit], episode_row)?
            .collect::<Result<Vec<_>, _>>()?;
        r
    };
    Ok(json!({ "success": true, "count": rows.len(), "results": rows }))
}

fn episode_row(r: &rusqlite::Row) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_,i64>(0)?,
        "happened_at": r.get::<_,String>(1)?,
        "summary": r.get::<_,String>(2)?,
        "tags": r.get::<_,Option<String>>(3)?,
        "repo": r.get::<_,Option<String>>(4)?,
        "sentiment": r.get::<_,Option<String>>(5)?,
    }))
}

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "memory_search" => handle_memory_search(params).await,
        "memory_recall" => handle_memory_recall(params).await,
        "episode_save" => handle_episode_save(params).await,
        "episode_search" => handle_episode_search(params).await,
        "tools/list" => Ok(json!({
            "tools": [
                {
                    "name": "memory_search",
                    "description": "Full-text search over Chump's semantic memory store (chump_memory table). Returns matching memory entries ranked by relevance. Per-repo isolation via CHUMP_REPO.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "query": { "type": "string", "description": "Search query (FTS5 or LIKE fallback)" },
                            "limit": { "type": "integer", "description": "Max results (default 10, max 50)" }
                        },
                        "required": ["query"]
                    }
                },
                {
                    "name": "memory_recall",
                    "description": "Recall memory entries mentioning a specific entity or topic. Uses LIKE search. Good for retrieving everything known about a named concept.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "entity": { "type": "string", "description": "Entity or topic name to look up" }
                        },
                        "required": ["entity"]
                    }
                },
                {
                    "name": "episode_save",
                    "description": "Save an episodic event to session memory. Episodes are searchable across sessions within the same repo store.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "content": { "type": "string", "description": "Summary of what happened" },
                            "tags": { "type": "string", "description": "Space or comma-separated tags" },
                            "sentiment": { "type": "string", "description": "One of: win, loss, neutral, frustrating, uncertain" },
                            "repo": { "type": "string", "description": "Repo slug (e.g. owner/repo) for per-repo filtering" }
                        },
                        "required": ["content"]
                    }
                },
                {
                    "name": "episode_search",
                    "description": "Search episode history by keyword. Episodes saved in previous sessions are findable here. Optional repo filter for per-repo isolation.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "query": { "type": "string", "description": "Keyword to search in episode summaries, details, and tags" },
                            "limit": { "type": "integer", "description": "Max results (default 10, max 50)" },
                            "repo": { "type": "string", "description": "Optional repo filter (e.g. owner/repo)" }
                        },
                        "required": ["query"]
                    }
                }
            ]
        })),
        _ => Err(anyhow!("unknown method: {}", method)),
    }
}

#[tokio::main]
async fn main() {
    let stdin = tokio::io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        let req: JsonRpcRequest = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let err_resp = JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32700,
                        message: format!("Parse error: {}", e),
                    }),
                    id: Value::Null,
                };
                println!(
                    "{}",
                    serde_json::to_string(&err_resp).expect("always serializable")
                );
                continue;
            }
        };

        if req.jsonrpc != "2.0" {
            let err_resp = JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32600,
                    message: "Invalid Request: jsonrpc must be \"2.0\"".to_string(),
                }),
                id: req.id,
            };
            println!(
                "{}",
                serde_json::to_string(&err_resp).expect("always serializable")
            );
            continue;
        }

        let resp = match handle_method(&req.method, &req.params).await {
            Ok(result) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: Some(result),
                error: None,
                id: req.id,
            },
            Err(e) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32603,
                    message: e.to_string(),
                }),
                id: req.id,
            },
        };
        println!(
            "{}",
            serde_json::to_string(&resp).expect("always serializable")
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn tools_list_has_four_tools() {
        let result = handle_method("tools/list", &json!({})).await.unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 4);
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"memory_search"));
        assert!(names.contains(&"memory_recall"));
        assert!(names.contains(&"episode_save"));
        assert!(names.contains(&"episode_search"));
    }

    #[tokio::test]
    async fn memory_search_missing_query_errors() {
        let result = handle_method("memory_search", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn memory_recall_missing_entity_errors() {
        let result = handle_method("memory_recall", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn episode_save_missing_content_errors() {
        let result = handle_method("episode_save", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn episode_search_missing_query_errors() {
        let result = handle_method("episode_search", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn unknown_method_errors() {
        let result = handle_method("does_not_exist", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn episode_roundtrip() {
        let dir = std::env::temp_dir().join(format!(
            "chump_mcp_memory_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(dir.join("sessions")).unwrap();
        set_test_db(Some(dir.join("sessions").join("chump_memory.db")));

        let save = handle_method(
            "episode_save",
            &json!({ "content": "deployed auth fix", "tags": "auth deploy", "sentiment": "win" }),
        )
        .await
        .unwrap();
        assert_eq!(save["success"], true);

        let search = handle_method("episode_search", &json!({ "query": "auth" }))
            .await
            .unwrap();
        assert_eq!(search["success"], true);
        assert!(search["count"].as_u64().unwrap() >= 1);

        set_test_db(None);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn memory_search_creates_db_and_returns_empty() {
        let dir = std::env::temp_dir().join(format!(
            "chump_mcp_memory_search_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(dir.join("sessions")).unwrap();
        set_test_db(Some(dir.join("sessions").join("chump_memory.db")));

        let result = handle_method("memory_search", &json!({ "query": "nonexistent" }))
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["count"], 0);

        set_test_db(None);
        let _ = std::fs::remove_dir_all(dir);
    }
}
