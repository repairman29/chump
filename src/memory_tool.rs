//! Long-term memory for Chump: store and recall facts across sessions.
//! Prefers SQLite (sessions/chump_memory.db) with FTS5 when available; falls back to
//! sessions/chump_memory.json. Optional semantic recall via local embed server and
//! sessions/chump_memory_embeddings.json. When DB + embed server are both available,
//! recall uses RRF (reciprocal rank fusion) to merge keyword and semantic results.

use crate::memory_db;
use anyhow::{anyhow, Result};
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
    std::env::var("CHUMP_EMBED_URL")
        .ok()
        .filter(|u| !u.is_empty())
        .or_else(|| Some("http://127.0.0.1:18765".to_string()))
}

/// When `inprocess-embed` feature is on and CHUMP_EMBED_URL is not set, use in-process embedding.
fn use_inprocess_embed() -> bool {
    #[cfg(feature = "inprocess-embed")]
    {
        std::env::var("CHUMP_EMBED_URL")
            .ok()
            .filter(|u| !u.is_empty())
            .is_none()
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
            return tokio::task::spawn_blocking(move || {
                crate::embed_inprocess::embed_text_sync(&text)
            })
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
            return tokio::task::spawn_blocking(move || {
                crate::embed_inprocess::embed_texts_sync(&texts)
            })
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

async fn embed_texts(
    client: &reqwest::Client,
    base: &str,
    texts: &[String],
) -> Result<Vec<Vec<f32>>> {
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

/// RRF (reciprocal rank fusion): merge keyword, semantic, and graph ranked lists by id.
/// score(id) = sum 1/(k + rank) for each list; weighted by freshness and confidence.
/// k=60. Freshness decays at 0.01/day. Confidence multiplies the score directly.
fn rrf_merge_3way(
    keyword_rank: &HashMap<i64, u32>,
    semantic_rank: &HashMap<i64, u32>,
    graph_rank: &HashMap<i64, u32>,
    id_meta: &HashMap<i64, (String, f64)>, // id -> (ts_unix_str, confidence)
    limit: usize,
) -> Vec<i64> {
    let k = f64::from(RRF_K);
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as f64;

    let mut scores: HashMap<i64, f64> = HashMap::new();
    for (&id, &rank) in keyword_rank.iter() {
        *scores.entry(id).or_default() += 1.0 / (k + f64::from(rank));
    }
    for (&id, &rank) in semantic_rank.iter() {
        *scores.entry(id).or_default() += 1.0 / (k + f64::from(rank));
    }
    for (&id, &rank) in graph_rank.iter() {
        *scores.entry(id).or_default() += 1.0 / (k + f64::from(rank));
    }
    // Apply freshness decay and confidence weighting
    for (id, score) in scores.iter_mut() {
        if let Some((ts_str, confidence)) = id_meta.get(id) {
            if let Ok(ts) = ts_str.parse::<f64>() {
                let days_since = (now_secs - ts) / 86400.0;
                let freshness = 1.0 / (1.0 + days_since.max(0.0) * 0.01);
                *score *= freshness;
            }
            *score *= confidence;
        }
    }
    let mut order: Vec<(i64, f64)> = scores.into_iter().collect();
    order.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    order.into_iter().take(limit).map(|(id, _)| id).collect()
}

/// Same as `rrf_merge_3way` but returns `(id, score)` pairs so downstream MMR can
/// reuse the relevance scores without re-computing.
fn rrf_merge_3way_with_scores(
    keyword_rank: &HashMap<i64, u32>,
    semantic_rank: &HashMap<i64, u32>,
    graph_rank: &HashMap<i64, u32>,
    id_meta: &HashMap<i64, (String, f64)>,
    limit: usize,
) -> Vec<(i64, f64)> {
    let k = f64::from(RRF_K);
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as f64;

    let mut scores: HashMap<i64, f64> = HashMap::new();
    for (&id, &rank) in keyword_rank.iter() {
        *scores.entry(id).or_default() += 1.0 / (k + f64::from(rank));
    }
    for (&id, &rank) in semantic_rank.iter() {
        *scores.entry(id).or_default() += 1.0 / (k + f64::from(rank));
    }
    for (&id, &rank) in graph_rank.iter() {
        *scores.entry(id).or_default() += 1.0 / (k + f64::from(rank));
    }
    for (id, score) in scores.iter_mut() {
        if let Some((ts_str, confidence)) = id_meta.get(id) {
            if let Ok(ts) = ts_str.parse::<f64>() {
                let days_since = (now_secs - ts) / 86400.0;
                let freshness = 1.0 / (1.0 + days_since.max(0.0) * 0.01);
                *score *= freshness;
            }
            *score *= confidence;
        }
    }
    let mut order: Vec<(i64, f64)> = scores.into_iter().collect();
    order.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    order.into_iter().take(limit).collect()
}

/// Sprint C4: Maximal Marginal Relevance for memory-text-level diversification.
///
/// After RRF picks the top-N candidate memories, two memories saying nearly the
/// same thing both rank highly. MMR re-orders so the final K returned to the agent
/// are both relevant (high RRF score) AND diverse (low overlap with already-selected).
///
/// Formula: MMR(m) = λ·rrf_score(m) - (1-λ)·max_sim(m, already_selected)
///
/// λ defaults to 0.7 (favor relevance over diversity); override via
/// `CHUMP_MEMORY_MMR_LAMBDA`. Set λ=1.0 to disable diversity (pure top-k).
///
/// Similarity uses Jaccard over normalized 3-shingles (token trigrams). This works
/// without embeddings — important for our default deployment where embed server
/// may be optional.
fn apply_memory_mmr(
    candidates: &[(i64, f64)],
    id_to_entry: &HashMap<i64, &MemoryEntry>,
    limit: usize,
) -> Vec<i64> {
    if candidates.is_empty() {
        return Vec::new();
    }
    let lambda = std::env::var("CHUMP_MEMORY_MMR_LAMBDA")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.7)
        .clamp(0.0, 1.0);

    let cap = limit.min(candidates.len());
    if (lambda - 1.0).abs() < 1e-9 {
        // Pure top-k mode — short-circuit
        return candidates.iter().take(cap).map(|(id, _)| *id).collect();
    }

    // Normalize RRF scores to [0, 1] so they're comparable to similarity
    let max_score = candidates.iter().map(|(_, s)| *s).fold(0.0f64, f64::max);
    let norm = if max_score > 0.0 { max_score } else { 1.0 };

    // Pre-compute token-trigram sets per candidate
    let shingles: HashMap<i64, std::collections::HashSet<String>> = candidates
        .iter()
        .map(|(id, _)| {
            let content = id_to_entry
                .get(id)
                .map(|e| e.content.as_str())
                .unwrap_or("");
            (*id, token_trigram_shingles(content))
        })
        .collect();
    let empty: std::collections::HashSet<String> = std::collections::HashSet::new();
    let jaccard = |a: i64, b: i64| -> f64 {
        let sa = shingles.get(&a).unwrap_or(&empty);
        let sb = shingles.get(&b).unwrap_or(&empty);
        if sa.is_empty() && sb.is_empty() {
            return 0.0;
        }
        let intersect = sa.intersection(sb).count() as f64;
        let union = sa.union(sb).count() as f64;
        if union == 0.0 {
            0.0
        } else {
            intersect / union
        }
    };

    let mut selected: Vec<i64> = Vec::with_capacity(cap);
    let mut remaining: Vec<(i64, f64)> = candidates.to_vec();

    while selected.len() < cap && !remaining.is_empty() {
        let mut best_idx = 0;
        let mut best_mmr = f64::NEG_INFINITY;
        for (i, (id, score)) in remaining.iter().enumerate() {
            let max_sim = if selected.is_empty() {
                0.0
            } else {
                selected
                    .iter()
                    .map(|s| jaccard(*id, *s))
                    .fold(0.0f64, f64::max)
            };
            let normalized_score = score / norm;
            let mmr = lambda * normalized_score - (1.0 - lambda) * max_sim;
            if mmr > best_mmr {
                best_mmr = mmr;
                best_idx = i;
            }
        }
        let (id, _) = remaining.remove(best_idx);
        selected.push(id);
    }
    selected
}

/// Build normalized 3-token shingles for Jaccard similarity. Lowercases and tokenizes
/// on whitespace + punctuation. For short content (< 3 tokens), returns single-token
/// shingles instead of empty so very short memories still compare meaningfully.
fn token_trigram_shingles(content: &str) -> std::collections::HashSet<String> {
    let tokens: Vec<String> = content
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty() && s.len() > 1)
        .map(|s| s.to_string())
        .collect();
    let mut set = std::collections::HashSet::new();
    if tokens.len() < 3 {
        for t in tokens {
            set.insert(t);
        }
    } else {
        for window in tokens.windows(3) {
            set.insert(window.join(" "));
        }
    }
    set
}

/// Maximum characters of memory context to inject into prompts.
const MEMORY_CONTEXT_CHAR_BUDGET: usize = 4000;

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
                    eprintln!(
                        "chump: reqwest client build failed, using keyword-only recall: {}",
                        e
                    );
                    return Ok(keyword_recall(&entries, query, limit));
                }
            };
            if client
                .get(format!("{}/health", base.trim_end_matches('/')))
                .send()
                .await
                .is_err()
            {
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
        // Query expansion: add related entities from memory graph
        let query_entities = crate::memory_graph::extract_query_entities(query);
        let expanded_query = if !query_entities.is_empty() {
            let related =
                crate::memory_graph::associative_recall(&query_entities, 1, 3).unwrap_or_default();
            if related.is_empty() {
                query.to_string()
            } else {
                let extra: Vec<&str> = related.iter().map(|(e, _)| e.as_str()).collect();
                format!("{} {}", query, extra.join(" "))
            }
        } else {
            query.to_string()
        };
        let keyword_rows =
            memory_db::keyword_search(&expanded_query, limit * 2).unwrap_or_default();
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
            .filter_map(|(i, e)| {
                e.id.map(|id| (id, cosine_similarity(&embeddings[i], &query_vec)))
            })
            .collect();
        semantic_scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let semantic_rank: HashMap<i64, u32> = semantic_scored
            .into_iter()
            .take(limit * 2)
            .enumerate()
            .map(|(i, (id, _))| (id, (i + 1) as u32))
            .collect();

        // Phase 2: build graph rank from associative recall
        let graph_rank: HashMap<i64, u32> = {
            let query_entities = crate::memory_graph::extract_query_entities(query);
            let graph_max_hops = std::env::var("CHUMP_GRAPH_MAX_HOPS")
                .ok()
                .and_then(|v| v.trim().parse::<usize>().ok())
                .unwrap_or(2);
            let associated =
                crate::memory_graph::associative_recall(&query_entities, graph_max_hops, limit * 2)
                    .unwrap_or_default();
            let entity_names: Vec<String> = associated.iter().map(|(e, _)| e.clone()).collect();
            let mem_ids =
                crate::memory_graph::memory_ids_for_entities(&entity_names).unwrap_or_default();
            mem_ids
                .into_iter()
                .enumerate()
                .map(|(i, (id, _))| (id, (i + 1) as u32))
                .collect()
        };

        // Build metadata map for freshness/confidence weighting
        let id_meta: HashMap<i64, (String, f64)> = {
            let conf_map = memory_db::load_id_confidence_map().unwrap_or_default();
            entries
                .iter()
                .filter_map(|e| {
                    e.id.map(|id| {
                        let conf = conf_map.get(&id).copied().unwrap_or(1.0);
                        (id, (e.ts.clone(), conf))
                    })
                })
                .collect()
        };
        // Sprint C4: Pull 2x more candidates than needed, then MMR-diversify down to `limit`
        // so we don't return 5 nearly-identical memories. Set CHUMP_MEMORY_MMR_LAMBDA=1.0 to
        // disable diversity (pure top-k by score).
        let candidates_with_scores = rrf_merge_3way_with_scores(
            &keyword_rank,
            &semantic_rank,
            &graph_rank,
            &id_meta,
            limit * 2,
        );
        if candidates_with_scores.is_empty() {
            return Ok(keyword_recall(&entries, Some(query), limit));
        }
        let id_to_entry: HashMap<i64, &MemoryEntry> = entries
            .iter()
            .filter_map(|e| e.id.map(|id| (id, e)))
            .collect();
        let top_ids = apply_memory_mmr(&candidates_with_scores, &id_to_entry, limit);
        let lines: String = top_ids
            .iter()
            .filter_map(|id| id_to_entry.get(id))
            .enumerate()
            .map(|(i, e)| format!("{}. {}", i + 1, e.content))
            .collect::<Vec<_>>()
            .join("\n");
        // Context compression: truncate to char budget if too large
        let lines = if lines.len() > MEMORY_CONTEXT_CHAR_BUDGET {
            let mut budget_lines = Vec::new();
            let mut total = 0;
            for line in lines.lines() {
                if total + line.len() + 1 > MEMORY_CONTEXT_CHAR_BUDGET {
                    break;
                }
                budget_lines.push(line);
                total += line.len() + 1;
            }
            budget_lines.join("\n")
        } else {
            lines
        };
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
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
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
                },
                "confidence": {
                    "type": "number",
                    "description": "For store: reliability of this memory 0.0-1.0 (default 1.0). Use lower values for uncertain or inferred facts."
                },
                "memory_type": {
                    "type": "string",
                    "enum": ["semantic_fact", "episodic_event", "user_preference", "summary", "procedural_pattern"],
                    "description": "For store: category of memory (default: semantic_fact)"
                },
                "expires_after_hours": {
                    "type": "number",
                    "description": "For store: auto-expire this memory after N hours (optional, for transient info)"
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
            _ => {
                return Ok("Memory tool needs an object with action (store or recall).".to_string())
            }
        };
        let raw_action = obj
            .get("action")
            .and_then(|a| a.as_str())
            .unwrap_or("")
            .trim()
            .to_lowercase();
        let content = obj
            .get("content")
            .and_then(|c| c.as_str())
            .unwrap_or("")
            .trim();
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
                // Build enrichment from optional tool params
                let enrichment = {
                    let conf = obj.get("confidence").and_then(|v| v.as_f64());
                    let mt = obj
                        .get("memory_type")
                        .and_then(|v| v.as_str())
                        .map(String::from);
                    let exp =
                        obj.get("expires_after_hours")
                            .and_then(|v| v.as_f64())
                            .map(|hours| {
                                let secs = (hours * 3600.0) as u64;
                                let now = std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_secs();
                                format!("{}", now + secs)
                            });
                    if conf.is_some() || mt.is_some() || exp.is_some() {
                        Some(memory_db::MemoryEnrichment {
                            confidence: conf,
                            memory_type: mt,
                            expires_at: exp,
                            ..Default::default()
                        })
                    } else {
                        None
                    }
                };
                if memory_db::db_available() {
                    memory_db::insert_one(&truncated, &ts, &self.source_hint, enrichment.as_ref())?;
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

                // Extract and store knowledge graph triples for associative recall
                let triples = crate::memory_graph::extract_triples(&truncated);
                if !triples.is_empty() {
                    let mem_id = if memory_db::db_available() {
                        memory_db::keyword_search(&truncated, 1)
                            .ok()
                            .and_then(|rows| rows.first().map(|r| r.id))
                    } else {
                        None
                    };
                    let _ = crate::memory_graph::store_triples(&triples, mem_id, None);
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
            MemoryEntry {
                id: None,
                content: "first".into(),
                ts: "1".into(),
                source: "t".into(),
            },
            MemoryEntry {
                id: None,
                content: "second".into(),
                ts: "2".into(),
                source: "t".into(),
            },
            MemoryEntry {
                id: None,
                content: "third".into(),
                ts: "3".into(),
                source: "t".into(),
            },
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
            MemoryEntry {
                id: None,
                content: "hello world".into(),
                ts: "1".into(),
                source: "t".into(),
            },
            MemoryEntry {
                id: None,
                content: "goodbye".into(),
                ts: "2".into(),
                source: "t".into(),
            },
        ];
        let out = keyword_recall(&entries, Some("hello"), 10);
        assert!(!out.is_empty());
        assert!(out.contains("hello world"));
    }

    #[test]
    fn keyword_recall_with_query_not_matching() {
        let entries = vec![MemoryEntry {
            id: None,
            content: "hello world".into(),
            ts: "1".into(),
            source: "t".into(),
        }];
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

        // Before inserting our specific content, it should not be present.
        // (DB pool is process-global so other tests may have pre-populated entries.)
        let out = recall_for_context(Some("stored fact for recall"), 10).await.unwrap();
        assert!(
            !out.contains("stored fact for recall"),
            "content should not exist before we insert it"
        );

        // Insert one entry (DB was created above), then recall
        memory_db::insert_one("stored fact for recall", "123", "test", None).unwrap();
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

    // ── Sprint C4: MMR diversity tests ──────────────────────────────

    fn make_entry(id: i64, ts: &str, content: &str) -> MemoryEntry {
        MemoryEntry {
            id: Some(id),
            content: content.to_string(),
            ts: ts.to_string(),
            source: "test".to_string(),
        }
    }

    #[test]
    fn mmr_avoids_near_duplicate_in_favor_of_diverse_memory() {
        // e1 and e2 are near-identical (high trigram overlap)
        let e1 = make_entry(
            1,
            "1",
            "the database migration is complete and ready to ship",
        );
        let e2 = make_entry(
            2,
            "1",
            "the database migration is complete and ready to ship",
        );
        // e3 is unrelated (zero trigram overlap with e1)
        let e3 = make_entry(
            3,
            "1",
            "user prefers dark mode in the editor for late night work",
        );

        let entries = [&e1, &e2, &e3];
        let id_to_entry: HashMap<i64, &MemoryEntry> =
            entries.iter().map(|e| (e.id.unwrap(), *e)).collect();

        // e1 is highest, e2 is a true near-duplicate, e3 is lower-scoring but diverse.
        let candidates = vec![(1, 0.9), (2, 0.85), (3, 0.5)];

        std::env::remove_var("CHUMP_MEMORY_MMR_LAMBDA");
        let result = apply_memory_mmr(&candidates, &id_to_entry, 2);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0], 1, "highest-scoring should come first");
        assert_eq!(
            result[1], 3,
            "second pick should be the diverse memory (e3), not the duplicate (e2). \
             With lambda=0.7: mmr(e2) = 0.7*0.94 - 0.3*~1.0 ≈ 0.36; mmr(e3) = 0.7*0.55 - 0.3*0 ≈ 0.39. \
             Diverse wins."
        );
    }

    #[test]
    fn mmr_does_not_diversify_when_no_overlap() {
        // All three memories are mutually distinct — MMR should preserve score order.
        let e1 = make_entry(1, "1", "alpha bravo charlie delta echo");
        let e2 = make_entry(2, "1", "foxtrot golf hotel india juliet");
        let e3 = make_entry(3, "1", "kilo lima mike november oscar");
        let id_to_entry: HashMap<i64, &MemoryEntry> =
            [(1, &e1), (2, &e2), (3, &e3)].into_iter().collect();
        let candidates = vec![(1, 0.9), (2, 0.6), (3, 0.3)];
        std::env::remove_var("CHUMP_MEMORY_MMR_LAMBDA");
        let result = apply_memory_mmr(&candidates, &id_to_entry, 3);
        assert_eq!(result, vec![1, 2, 3]);
    }

    #[test]
    fn mmr_lambda_one_disables_diversity() {
        let e1 = make_entry(1, "1", "topic alpha");
        let e2 = make_entry(2, "1", "topic alpha");
        let e3 = make_entry(3, "1", "topic alpha");
        let id_to_entry: HashMap<i64, &MemoryEntry> =
            [(1, &e1), (2, &e2), (3, &e3)].into_iter().collect();
        let candidates = vec![(1, 0.9), (2, 0.8), (3, 0.7)];

        std::env::set_var("CHUMP_MEMORY_MMR_LAMBDA", "1.0");
        let result = apply_memory_mmr(&candidates, &id_to_entry, 3);
        std::env::remove_var("CHUMP_MEMORY_MMR_LAMBDA");

        // With λ=1.0 (pure top-k), order = score order
        assert_eq!(result, vec![1, 2, 3]);
    }

    #[test]
    fn mmr_handles_empty_candidates() {
        let id_to_entry: HashMap<i64, &MemoryEntry> = HashMap::new();
        let result = apply_memory_mmr(&[], &id_to_entry, 5);
        assert!(result.is_empty());
    }

    #[test]
    fn mmr_caps_to_limit() {
        let e1 = make_entry(1, "1", "alpha beta gamma delta");
        let e2 = make_entry(2, "1", "epsilon zeta eta theta");
        let id_to_entry: HashMap<i64, &MemoryEntry> = [(1, &e1), (2, &e2)].into_iter().collect();
        let candidates = vec![(1, 0.5), (2, 0.5)];
        let result = apply_memory_mmr(&candidates, &id_to_entry, 1);
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn token_trigram_shingles_basic() {
        let s = token_trigram_shingles("the quick brown fox jumps over");
        // Tokens: [the, quick, brown, fox, jumps, over] (length filter > 1 = "the" still kept since len 3)
        // 4 trigrams: (the quick brown), (quick brown fox), (brown fox jumps), (fox jumps over)
        assert_eq!(s.len(), 4);
        assert!(s.contains("the quick brown"));
        assert!(s.contains("fox jumps over"));
    }

    #[test]
    fn token_trigram_shingles_short_content() {
        // Less than 3 tokens — fall back to single-token
        let s = token_trigram_shingles("hello world");
        assert_eq!(s.len(), 2);
        assert!(s.contains("hello"));
        assert!(s.contains("world"));
    }

    #[test]
    fn token_trigram_shingles_filters_short_tokens() {
        // Single-character tokens are filtered (len > 1 requirement)
        let s = token_trigram_shingles("a b c");
        assert!(s.is_empty());
    }
}
