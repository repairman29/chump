//! Long-term memory for Chump: store and recall facts across sessions.
//! Prefers SQLite (sessions/chump_memory.db) with FTS5 when available; falls back to
//! sessions/chump_memory.json. Optional semantic recall via local embed server and
//! sessions/chump_memory_embeddings.json. When DB + embed server are both available,
//! recall uses RRF (reciprocal rank fusion) to merge keyword and semantic results.

use anyhow::{anyhow, Result};
use crate::memory_db;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;

const RRF_K: u32 = 60;

const MEMORY_PATH: &str = "sessions/chump_memory.json";
const EMBEDDINGS_PATH: &str = "sessions/chump_memory_embeddings.json";
const MAX_RECALL: usize = 20;
const MAX_STORED_LEN: usize = 500;
/// Max texts per embed request to avoid overloading the Python embed server (OOM/crashes).
const EMBED_BATCH_MAX: usize = 32;

fn embed_server_url() -> Option<String> {
    std::env::var("CHUMP_EMBED_URL").ok().filter(|u| !u.is_empty())
        .or_else(|| Some("http://127.0.0.1:18765".to_string()))
}

/// When `inprocess-embed` feature is on and CHUMP_EMBED_URL is not set, use in-process embedding.
fn use_inprocess_embed() -> bool {
    #[cfg(feature = "inprocess-embed")]
    {
        std::env::var("CHUMP_EMBED_URL").ok().filter(|u| !u.is_empty()).is_none()
            || std::env::var("CHUMP_EMBED_INPROCESS").as_deref() == Ok("1")
    }
    #[cfg(not(feature = "inprocess-embed"))]
    {
        false
    }
}

async fn embed_text_any(text: &str) -> Result<Vec<f32>> {
    if use_inprocess_embed() {
        #[cfg(feature = "inprocess-embed")]
        {
            let text = text.to_string();
            return tokio::task::spawn_blocking(move || crate::embed_inprocess::embed_text_sync(&text))
                .await
                .map_err(|e| anyhow::anyhow!("spawn_blocking: {}", e))?;
        }
        #[cfg(not(feature = "inprocess-embed"))]
        unreachable!()
    }
    let base = match embed_server_url() {
        Some(u) => u,
        None => return Err(anyhow!("no embed source")),
    };
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| anyhow!("reqwest client build failed: {}", e))?;
    embed_text(&client, &base, text).await
}

async fn embed_texts_any(texts: &[String]) -> Result<Vec<Vec<f32>>> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    if use_inprocess_embed() {
        #[cfg(feature = "inprocess-embed")]
        {
            let texts = texts.to_vec();
            return tokio::task::spawn_blocking(move || crate::embed_inprocess::embed_texts_sync(&texts))
                .await
                .map_err(|e| anyhow::anyhow!("spawn_blocking: {}", e))?;
        }
        #[cfg(not(feature = "inprocess-embed"))]
        unreachable!()
    }
    let base = match embed_server_url() {
        Some(u) => u,
        None => return Err(anyhow!("no embed source")),
    };
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| anyhow!("reqwest client build failed: {}", e))?;
    embed_texts(&client, &base, texts).await
}

/// Embed many texts in batches of EMBED_BATCH_MAX to avoid overloading the embed server.
async fn embed_texts_chunked(texts: &[String]) -> Result<Vec<Vec<f32>>> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    let mut all = Vec::with_capacity(texts.len());
    for chunk in texts.chunks(EMBED_BATCH_MAX) {
        let v = embed_texts_any(chunk).await?;
        all.extend(v);
    }
    Ok(all)
}

/// Keyword-based recall (no embed server). Used as fallback when semantic fails or is disabled.
fn keyword_recall(entries: &[MemoryEntry], query: Option<&str>, limit: usize) -> String {
    if entries.is_empty() {
        return String::new();
    }
    let limit = limit.min(MAX_RECALL);
    let mut out: Vec<&MemoryEntry> = entries.iter().rev().take(limit * 2).collect();
    if let Some(q) = query {
        let q = q.trim().to_lowercase();
        if !q.is_empty() {
            let words: Vec<&str> = q.split_ascii_whitespace().filter(|w| w.len() > 1).collect();
            if !words.is_empty() {
                out = out
                    .into_iter()
                    .filter(|e| {
                        let c = e.content.to_lowercase();
                        words.iter().any(|w| c.contains(*w))
                    })
                    .take(limit)
                    .collect();
            }
        }
    }
    if out.is_empty() && query.is_some() {
        out = entries.iter().rev().take(limit).collect();
    } else if out.len() > limit {
        out.truncate(limit);
    }
    out.reverse();
    out.iter()
        .enumerate()
        .map(|(i, e)| format!("{}. {}", i + 1, e.content))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Cosine similarity between two unit-length vectors (embed server returns normalized vectors for many models).
fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let na: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let nb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if na <= 0.0 || nb <= 0.0 {
        return 0.0;
    }
    dot / (na * nb)
}

async fn embed_text(client: &reqwest::Client, base: &str, text: &str) -> Result<Vec<f32>> {
    let url = format!("{}/embed", base.trim_end_matches('/'));
    let res = client
        .post(&url)
        .json(&json!({ "text": text }))
        .send()
        .await?;
    let status = res.status();
    let body: Value = res.json().await?;
    let vec = body
        .get("vector")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("embed response missing 'vector'"))?;
    let v: Vec<f32> = vec
        .iter()
        .filter_map(|x| x.as_f64().map(|f| f as f32))
        .collect();
    if v.is_empty() {
        return Err(anyhow!("empty vector"));
    }
    if !status.is_success() {
        return Err(anyhow!("embed failed: {}", status));
    }
    Ok(v)
}

async fn embed_texts(client: &reqwest::Client, base: &str, texts: &[String]) -> Result<Vec<Vec<f32>>> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    let url = format!("{}/embed", base.trim_end_matches('/'));
    let res = client
        .post(&url)
        .json(&json!({ "texts": texts }))
        .send()
        .await?;
    let status = res.status();
    let body: Value = res.json().await?;
    let vecs = body
        .get("vectors")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("embed response missing 'vectors'"))?;
    let out: Vec<Vec<f32>> = vecs
        .iter()
        .filter_map(|arr| {
            arr.as_array().map(|a| {
                a.iter()
                    .filter_map(|x| x.as_f64().map(|f| f as f32))
                    .collect()
            })
        })
        .collect();
    if !status.is_success() {
        return Err(anyhow!("embed failed: {}", status));
    }
    Ok(out)
}

/// RRF (reciprocal rank fusion): merge keyword and semantic ranked lists by id.
/// score(id) = sum 1/(k + rank) for each list that contains id; k=60.
fn rrf_merge(
    keyword_rank: &HashMap<i64, u32>,
    semantic_rank: &HashMap<i64, u32>,
    limit: usize,
) -> Vec<i64> {
    let k = f64::from(RRF_K);
    let mut scores: HashMap<i64, f64> = HashMap::new();
    for (&id, &rank) in keyword_rank.iter() {
        *scores.entry(id).or_default() += 1.0 / (k + f64::from(rank));
    }
    for (&id, &rank) in semantic_rank.iter() {
        *scores.entry(id).or_default() += 1.0 / (k + f64::from(rank));
    }
    let mut order: Vec<(i64, f64)> = scores.into_iter().collect();
    order.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    order.into_iter().take(limit).map(|(id, _)| id).collect()
}

/// Called before each turn to inject relevant memories. Tries semantic recall (local embed server);
/// when DB + embed server are available, uses RRF to merge keyword (FTS5) and semantic results.
/// Falls back to keyword matching if server is down or embeddings missing.
pub async fn recall_for_context(query: Option<&str>, limit: usize) -> Result<String> {
    let entries = load_memory()?;
    if entries.is_empty() {
        return Ok(String::new());
    }
    let limit = limit.min(MAX_RECALL);

    let has_embed = use_inprocess_embed() || embed_server_url().is_some();
    if !has_embed {
        return Ok(keyword_recall(&entries, query, limit));
    }

    // When !use_inprocess_embed() and has_embed, embed_server_url() is Some; fallback to keyword-only if not (defensive).
    if !use_inprocess_embed() {
        if let Some(base) = embed_server_url() {
            let client = match reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
            {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("chump: reqwest client build failed, using keyword-only recall: {}", e);
                    return Ok(keyword_recall(&entries, query, limit));
                }
            };
            if client.get(format!("{}/health", base.trim_end_matches('/'))).send().await.is_err() {
                return Ok(keyword_recall(&entries, query, limit));
            }
        } else {
            return Ok(keyword_recall(&entries, query, limit));
        }
    }

    let query = match query {
        Some(q) if !q.trim().is_empty() => q.trim(),
        _ => return Ok(keyword_recall(&entries, query, limit)),
    };

    // Hybrid path: DB + embed (server or in-process) + query -> RRF merge keyword and semantic
    if memory_db::db_available() {
        let keyword_rows = memory_db::keyword_search(query, limit * 2).unwrap_or_default();
        let keyword_rank: HashMap<i64, u32> = keyword_rows
            .iter()
            .enumerate()
            .map(|(i, r)| (r.id, (i + 1) as u32))
            .collect();

        let query_vec = match embed_text_any(query).await {
            Ok(v) => v,
            Err(_) => return Ok(keyword_recall(&entries, Some(query), limit)),
        };

        let mut embeddings = load_embeddings().unwrap_or_default();
        if embeddings.len() < entries.len() {
            let to_embed: Vec<String> = entries[embeddings.len()..]
                .iter()
                .map(|e| e.content.clone())
                .collect();
            if let Ok(new_vecs) = embed_texts_chunked(&to_embed).await {
                embeddings.extend(new_vecs);
                let _ = save_embeddings(&embeddings);
            }
        }
        if embeddings.len() < entries.len() {
            return Ok(keyword_recall(&entries, Some(query), limit));
        }

        let mut semantic_scored: Vec<(i64, f32)> = entries
            .iter()
            .enumerate()
            .filter_map(|(i, e)| e.id.map(|id| (id, cosine_similarity(&embeddings[i], &query_vec))))
            .collect();
        semantic_scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let semantic_rank: HashMap<i64, u32> = semantic_scored
            .into_iter()
            .take(limit * 2)
            .enumerate()
            .map(|(i, (id, _))| (id, (i + 1) as u32))
            .collect();

        let top_ids = rrf_merge(&keyword_rank, &semantic_rank, limit);
        if top_ids.is_empty() {
            return Ok(keyword_recall(&entries, Some(query), limit));
        }
        let id_to_entry: HashMap<i64, &MemoryEntry> = entries.iter().filter_map(|e| e.id.map(|id| (id, e))).collect();
        let lines: String = top_ids
            .iter()
            .filter_map(|id| id_to_entry.get(id))
            .enumerate()
            .map(|(i, e)| format!("{}. {}", i + 1, e.content))
            .collect::<Vec<_>>()
            .join("\n");
        return Ok(lines);
    }

    // Non-DB path: semantic-only (existing behavior)
    let query_vec = match embed_text_any(query).await {
        Ok(v) => v,
        Err(_) => return Ok(keyword_recall(&entries, Some(query), limit)),
    };

    let mut embeddings = load_embeddings().unwrap_or_default();
    if embeddings.len() < entries.len() {
        let to_embed: Vec<String> = entries[embeddings.len()..]
            .iter()
            .map(|e| e.content.clone())
            .collect();
        if let Ok(new_vecs) = embed_texts_chunked(&to_embed).await {
            embeddings.extend(new_vecs);
            let _ = save_embeddings(&embeddings);
        }
    }
    if embeddings.len() < entries.len() {
        return Ok(keyword_recall(&entries, Some(query), limit));
    }

    let mut scored: Vec<(usize, f32)> = entries
        .iter()
        .enumerate()
        .map(|(i, _)| (i, cosine_similarity(&embeddings[i], &query_vec)))
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let top: Vec<&MemoryEntry> = scored
        .into_iter()
        .take(limit)
        .map(|(i, _)| &entries[i])
        .collect();
    let lines: String = top
        .iter()
        .enumerate()
        .map(|(i, e)| format!("{}. {}", i + 1, e.content))
        .collect::<Vec<_>>()
        .join("\n");
    Ok(lines)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MemoryEntry {
    #[serde(default)]
    id: Option<i64>,
    content: String,
    ts: String,
    source: String,
}

fn memory_path() -> PathBuf {
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(MEMORY_PATH)
}

fn embeddings_path() -> PathBuf {
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(EMBEDDINGS_PATH)
}

fn load_memory() -> Result<Vec<MemoryEntry>> {
    if memory_db::db_available() {
        let rows = memory_db::load_all()?;
        return Ok(rows
            .into_iter()
            .map(|r| MemoryEntry {
                id: Some(r.id),
                content: r.content,
                ts: r.ts,
                source: r.source,
            })
            .collect());
    }
    let path = memory_path();
    if !path.exists() {
        return Ok(Vec::new());
    }
    let s = std::fs::read_to_string(&path)?;
    let v: Vec<MemoryEntry> = serde_json::from_str(&s).unwrap_or_default();
    Ok(v)
}

fn save_memory(entries: &[MemoryEntry]) -> Result<()> {
    let path = memory_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, serde_json::to_string_pretty(entries)?)?;
    Ok(())
}

fn load_embeddings() -> Result<Vec<Vec<f32>>> {
    let path = embeddings_path();
    if !path.exists() {
        return Ok(Vec::new());
    }
    let s = std::fs::read_to_string(&path)?;
    let v: Vec<Vec<f32>> = serde_json::from_str(&s).unwrap_or_default();
    Ok(v)
}

fn save_embeddings(vectors: &[Vec<f32>]) -> Result<()> {
    let path = embeddings_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, serde_json::to_string(vectors)?)?;
    Ok(())
}

fn ts_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    format!("{}", t.as_secs())
}

pub struct MemoryTool {
    #[allow(dead_code)]
    source_hint: String,
}

impl MemoryTool {
    pub fn for_discord(channel_id: u64) -> Self {
        Self {
            source_hint: format!("ch_{}", channel_id),
        }
    }
}

#[async_trait]
impl Tool for MemoryTool {
    fn name(&self) -> String {
        "memory".to_string()
    }

    fn description(&self) -> String {
        "Long-term memory: store facts, preferences, and things to remember (action=store), or recall recent/specific memories (action=recall). Use store when the user tells you something important to remember; use recall to bring back context before answering.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["store", "recall"],
                    "description": "store: save a fact. recall: retrieve recent or matching memories"
                },
                "content": {
                    "type": "string",
                    "description": "For store: the fact to remember (one short sentence). For recall: optional search phrase"
                },
                "limit": {
                    "type": "number",
                    "description": "For recall: max entries to return (default 10)"
                }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(msg) = crate::limits::check_tool_input_len(&input) {
            return Ok(msg);
        }
        let obj = match &input {
            Value::Object(m) => m,
            _ => return Ok("Memory tool needs an object with action (store or recall).".to_string()),
        };
        let raw_action = obj
            .get("action")
            .and_then(|a| a.as_str())
            .unwrap_or("")
            .trim()
            .to_lowercase();
        let content = obj.get("content").and_then(|c| c.as_str()).unwrap_or("").trim();
        let action = if raw_action.contains("recall") {
            "recall".to_string()
        } else if raw_action.contains("store")
            || (!raw_action.is_empty() && raw_action != "recall")
            || (raw_action.is_empty() && !content.is_empty())
        {
            "store".to_string()
        } else if raw_action.is_empty() {
            "recall".to_string()
        } else {
            raw_action
        };
        if action != "store" && action != "recall" {
            return Ok("Memory tool needs action: store or recall.".to_string());
        }
        let limit = obj
            .get("limit")
            .and_then(|n| n.as_u64().or_else(|| n.as_i64().map(|i| i as u64)))
            .unwrap_or(10) as usize;

        match action.as_str() {
            "store" => {
                if content.is_empty() {
                    return Ok("Nothing to store (content was empty).".to_string());
                }
                let truncated = if content.len() > MAX_STORED_LEN {
                    format!("{}…", &content[..MAX_STORED_LEN - 1])
                } else {
                    content.to_string()
                };
                let ts = ts_now();
                if memory_db::db_available() {
                    memory_db::insert_one(&truncated, &ts, &self.source_hint)?;
                } else {
                    let mut entries = load_memory()?;
                    entries.push(MemoryEntry {
                        id: None,
                        content: truncated.clone(),
                        ts,
                        source: self.source_hint.clone(),
                    });
                    save_memory(&entries)?;
                }

                // Embed the new entry (in-process or local embed server)
                if use_inprocess_embed() || embed_server_url().is_some() {
                    if let Ok(vec) = embed_text_any(&truncated).await {
                        let mut embeddings = load_embeddings().unwrap_or_default();
                        embeddings.push(vec);
                        let _ = save_embeddings(&embeddings);
                    }
                }

                Ok(format!("Stored: \"{}\"", truncated))
            }
            "recall" => {
                let limit = limit.min(MAX_RECALL);
                let lines = if memory_db::db_available() {
                    let rows = memory_db::keyword_search(content, limit)?;
                    if rows.is_empty() {
                        return Ok("No matching memories.".to_string());
                    }
                    rows.iter()
                        .enumerate()
                        .map(|(i, r)| format!("{}. {}", i + 1, r.content))
                        .collect::<Vec<_>>()
                        .join("\n")
                } else {
                    let entries = load_memory()?;
                    let mut out: Vec<&MemoryEntry> = entries.iter().rev().take(limit * 2).collect();
                    if !content.is_empty() {
                        let q = content.to_lowercase();
                        out = out
                            .into_iter()
                            .filter(|e| e.content.to_lowercase().contains(&q))
                            .take(limit)
                            .collect();
                    } else {
                        out.truncate(limit);
                    }
                    out.reverse();
                    if out.is_empty() {
                        return Ok("No matching memories.".to_string());
                    }
                    out.iter()
                        .enumerate()
                        .map(|(i, e)| format!("{}. {}", i + 1, e.content))
                        .collect::<Vec<_>>()
                        .join("\n")
                };
                Ok(lines)
            }
            _ => Err(anyhow!("action must be store or recall")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use std::fs;

    #[test]
    fn keyword_recall_empty_entries() {
        let entries: Vec<MemoryEntry> = vec![];
        assert_eq!(keyword_recall(&entries, Some("x"), 10), "");
        assert_eq!(keyword_recall(&entries, None, 10), "");
    }

    #[test]
    fn keyword_recall_with_entries_no_query() {
        let entries = vec![
            MemoryEntry { id: None, content: "first".into(), ts: "1".into(), source: "t".into() },
            MemoryEntry { id: None, content: "second".into(), ts: "2".into(), source: "t".into() },
            MemoryEntry { id: None, content: "third".into(), ts: "3".into(), source: "t".into() },
        ];
        let out = keyword_recall(&entries, None, 10);
        assert!(!out.is_empty());
        assert!(out.contains("third"));
        assert!(out.contains("second"));
        assert!(out.contains("first"));
    }

    #[test]
    fn keyword_recall_with_query_matching() {
        let entries = vec![
            MemoryEntry { id: None, content: "hello world".into(), ts: "1".into(), source: "t".into() },
            MemoryEntry { id: None, content: "goodbye".into(), ts: "2".into(), source: "t".into() },
        ];
        let out = keyword_recall(&entries, Some("hello"), 10);
        assert!(!out.is_empty());
        assert!(out.contains("hello world"));
    }

    #[test]
    fn keyword_recall_with_query_not_matching() {
        let entries = vec![
            MemoryEntry { id: None, content: "hello world".into(), ts: "1".into(), source: "t".into() },
        ];
        let out = keyword_recall(&entries, Some("xyznonexistent"), 10);
        // When no match, implementation falls back to latest N entries
        assert!(!out.is_empty());
        assert!(out.contains("hello world"));
    }

    #[tokio::test]
    #[serial]
    async fn recall_for_context_keyword_only_json_fallback() {
        let dir = std::env::temp_dir().join("chump_memory_tool_recall_test");
        let _ = fs::create_dir_all(&dir).ok();
        let sessions = dir.join("sessions");
        let _ = fs::create_dir_all(&sessions).ok();
        let json_path = sessions.join("chump_memory.json");
        let db_path = sessions.join("chump_memory.db");
        let _ = fs::remove_file(&json_path);
        let _ = fs::remove_file(&db_path);
        let prev_dir = std::env::current_dir().ok();
        let prev_embed = std::env::var("CHUMP_EMBED_URL").ok();
        std::env::set_current_dir(&dir).ok();
        std::env::remove_var("CHUMP_EMBED_URL");

        // No DB/JSON yet -> first recall creates empty DB, returns empty
        let out = recall_for_context(Some("anything"), 10).await.unwrap();
        assert_eq!(out, "");

        // Insert one entry (DB was created above), then recall
        memory_db::insert_one("stored fact for recall", "123", "test").unwrap();
        let out = recall_for_context(Some("stored"), 10).await.unwrap();
        assert!(!out.is_empty());
        assert!(out.contains("stored fact for recall"));

        if let Some(p) = prev_dir {
            std::env::set_current_dir(p).ok();
        }
        if let Some(v) = prev_embed {
            std::env::set_var("CHUMP_EMBED_URL", v);
        } else {
            std::env::remove_var("CHUMP_EMBED_URL");
        }
        let _ = fs::remove_file(&json_path);
        let _ = fs::remove_file(&db_path);
    }
}
