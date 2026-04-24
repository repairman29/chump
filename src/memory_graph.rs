//! Associative memory graph: entity-relation-entity triples extracted from memories
//! and episodes, with PageRank-inspired traversal for multi-hop recall.
//!
//! Inspired by HippoRAG 2: structures memory as a knowledge graph and uses
//! Personalized PageRank to find causally/associatively connected memories
//! that share no keywords with the query.
//!
//! Part of the Synthetic Consciousness Framework, Phase 2.

use anyhow::Result;
use std::collections::{HashMap, HashSet};

/// A single entity-relation-entity triple in the knowledge graph.
#[derive(Debug, Clone)]
pub struct Triple {
    pub id: i64,
    pub subject: String,
    pub relation: String,
    pub object: String,
    pub source_memory_id: Option<i64>,
    pub source_episode_id: Option<i64>,
    pub weight: f64,
}

/// Extract entity-relation-entity triples from a text string.
///
/// Uses pattern-based extraction for common relation types.
/// The LLM-assisted extraction path can be layered on top in a future iteration;
/// this regex/heuristic approach is fast and deterministic for testing.
pub fn extract_triples(text: &str) -> Vec<(String, String, String)> {
    let mut triples = Vec::new();

    let relation_patterns: &[(&str, &str)] = &[
        (" is ", "is"),
        (" are ", "is"),
        (" was ", "was"),
        (" has ", "has"),
        (" have ", "has"),
        (" uses ", "uses"),
        (" used ", "uses"),
        (" runs ", "runs"),
        (" runs on ", "runs_on"),
        (" depends on ", "depends_on"),
        (" requires ", "requires"),
        (" created ", "created"),
        (" built ", "built"),
        (" fixed ", "fixed"),
        (" broke ", "broke"),
        (" caused ", "caused"),
        (" caused by ", "caused_by"),
        (" prefers ", "prefers"),
        (" likes ", "prefers"),
        (" wants ", "wants"),
        (" needs ", "needs"),
        (" works with ", "works_with"),
        (" connects to ", "connects_to"),
        (" deployed to ", "deployed_to"),
        (" failed ", "failed"),
        (" succeeded ", "succeeded"),
    ];

    for sentence in text.split(['.', '!', '\n']) {
        let sentence = sentence.trim();
        if sentence.len() < 5 || sentence.len() > 200 {
            continue;
        }
        let sentence_lower = sentence.to_lowercase();

        for (pattern, relation) in relation_patterns {
            if let Some(pos) = sentence_lower.find(pattern) {
                let subject = clean_entity(&sentence[..pos]);
                let object = clean_entity(&sentence[pos + pattern.len()..]);
                if is_valid_entity(&subject) && is_valid_entity(&object) {
                    triples.push((subject, relation.to_string(), object));
                }
            }
        }
    }

    triples
}

fn clean_entity(s: &str) -> String {
    let s = s.trim();
    let s = s.trim_start_matches(|c: char| !c.is_alphanumeric());
    let s = s.trim_end_matches(|c: char| !c.is_alphanumeric());
    let lower = s.to_lowercase();
    let lower = lower
        .trim_start_matches("the ")
        .trim_start_matches("a ")
        .trim_start_matches("an ");
    lower.to_string()
}

fn is_valid_entity(s: &str) -> bool {
    let len = s.len();
    (2..=80).contains(&len) && s.chars().any(|c| c.is_alphabetic())
}

/// Store extracted triples in the graph database.
pub fn store_triples(
    triples: &[(String, String, String)],
    source_memory_id: Option<i64>,
    source_episode_id: Option<i64>,
) -> Result<usize> {
    if triples.is_empty() {
        return Ok(0);
    }
    let conn = crate::db_pool::get()?;
    let mut count = 0;
    for (subject, relation, object) in triples {
        let existing: i64 = conn.query_row(
            "SELECT COUNT(*) FROM chump_memory_graph \
             WHERE subject = ?1 AND relation = ?2 AND object = ?3",
            rusqlite::params![subject, relation, object],
            |r| r.get(0),
        )?;
        if existing > 0 {
            conn.execute(
                "UPDATE chump_memory_graph SET weight = weight + 0.5 \
                 WHERE subject = ?1 AND relation = ?2 AND object = ?3",
                rusqlite::params![subject, relation, object],
            )?;
        } else {
            conn.execute(
                "INSERT INTO chump_memory_graph (subject, relation, object, source_memory_id, source_episode_id) \
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![
                    subject,
                    relation,
                    object,
                    source_memory_id,
                    source_episode_id,
                ],
            )?;
            count += 1;
        }
    }
    Ok(count)
}

/// Personalized PageRank: iterative power method over the knowledge graph.
///
/// The true PPR algorithm:
/// 1. Build the adjacency list from the DB for the connected component.
/// 2. Initialize personalization vector to uniform over seed entities.
/// 3. Iterate: r = alpha * M * r + (1 - alpha) * personalization
///    where M is the row-stochastic transition matrix (weighted by edge weight).
/// 4. Converge when L1 change < epsilon.
/// 5. Return top-k non-seed entities by PPR score.
pub fn associative_recall(
    seed_entities: &[String],
    max_hops: usize,
    top_k: usize,
) -> Result<Vec<(String, f64)>> {
    if seed_entities.is_empty() {
        return Ok(Vec::new());
    }

    let conn = crate::db_pool::get()?;
    let alpha = 0.85; // teleport probability back to seed
    let epsilon = 1e-6;
    let max_iterations = max_hops.max(20);

    // Load the full adjacency list within the connected component (bounded BFS first)
    let mut adjacency: HashMap<String, Vec<(String, f64)>> = HashMap::new();
    let mut frontier: Vec<String> = seed_entities.iter().map(|s| s.to_lowercase()).collect();
    let mut discovered: HashSet<String> = frontier.iter().cloned().collect();
    let hop_limit = max_hops.max(3);

    let mut fwd_stmt =
        conn.prepare("SELECT object, weight FROM chump_memory_graph WHERE subject = ?1")?;
    let mut bwd_stmt =
        conn.prepare("SELECT subject, weight FROM chump_memory_graph WHERE object = ?1")?;

    for _hop in 0..hop_limit {
        let mut next_frontier = Vec::new();
        for entity in &frontier {
            let forward: Vec<(String, f64)> = fwd_stmt
                .query_map(rusqlite::params![entity], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;

            let backward: Vec<(String, f64)> = bwd_stmt
                .query_map(rusqlite::params![entity], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;

            let mut neighbors: Vec<(String, f64)> = Vec::new();
            for (n, w) in forward.into_iter().chain(backward) {
                if !discovered.contains(&n) {
                    discovered.insert(n.clone());
                    next_frontier.push(n.clone());
                }
                neighbors.push((n, w));
            }
            adjacency
                .entry(entity.clone())
                .or_default()
                .extend(neighbors);
        }
        frontier = next_frontier;
        if frontier.is_empty() {
            break;
        }
    }

    if adjacency.is_empty() {
        return Ok(Vec::new());
    }

    // Build node list and index
    let nodes: Vec<String> = discovered.into_iter().collect();
    let node_idx: HashMap<&str, usize> = nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.as_str(), i))
        .collect();
    let n = nodes.len();

    // Personalization vector: uniform over seeds
    let seed_set: HashSet<String> = seed_entities.iter().map(|s| s.to_lowercase()).collect();
    let mut personalization = vec![0.0f64; n];
    let seed_count = seed_set
        .iter()
        .filter(|s| node_idx.contains_key(s.as_str()))
        .count();
    if seed_count == 0 {
        return Ok(Vec::new());
    }
    for seed in &seed_set {
        if let Some(&idx) = node_idx.get(seed.as_str()) {
            personalization[idx] = 1.0 / seed_count as f64;
        }
    }

    // Build row-stochastic transition matrix as adjacency lists
    let mut transition: Vec<Vec<(usize, f64)>> = vec![Vec::new(); n];
    for (src, neighbors) in &adjacency {
        if let Some(&src_idx) = node_idx.get(src.as_str()) {
            let total_w: f64 = neighbors.iter().map(|(_, w)| w).sum();
            if total_w > 0.0 {
                for (dst, w) in neighbors {
                    if let Some(&dst_idx) = node_idx.get(dst.as_str()) {
                        transition[src_idx].push((dst_idx, w / total_w));
                    }
                }
            }
        }
    }

    // Power iteration
    let mut scores = personalization.clone();
    for _ in 0..max_iterations {
        let mut new_scores = vec![0.0f64; n];
        for (i, neighbors) in transition.iter().enumerate() {
            for &(j, w) in neighbors {
                new_scores[j] += alpha * scores[i] * w;
            }
        }
        for i in 0..n {
            new_scores[i] += (1.0 - alpha) * personalization[i];
        }

        let diff: f64 = scores
            .iter()
            .zip(new_scores.iter())
            .map(|(a, b)| (a - b).abs())
            .sum();
        scores = new_scores;
        if diff < epsilon {
            break;
        }
    }

    // Rank non-seed entities
    let mut ranked: Vec<(String, f64)> = nodes
        .iter()
        .enumerate()
        .filter(|(_, name)| !seed_set.contains(name.as_str()))
        .map(|(i, name)| (name.clone(), scores[i]))
        .collect();

    // Sort first by raw score to guarantee determinism in tie-breaks during MMR
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    // Apply Maximum Marginal Relevance (MMR) for diversity
    let mmr_ranked = apply_entity_mmr(&ranked, &adjacency, top_k);
    Ok(mmr_ranked)
}

/// Apply Maximum Marginal Relevance (MMR) to diversify returned entities based on Jaccard
/// similarity of their local neighborhoods in the graph.
fn apply_entity_mmr(
    candidates: &[(String, f64)],
    adjacency: &HashMap<String, Vec<(String, f64)>>,
    top_k: usize,
) -> Vec<(String, f64)> {
    if candidates.is_empty() {
        return Vec::new();
    }
    let lambda = 0.7; // 1.0 = purely highest score, 0.0 = purely most diverse
    let limit = top_k.min(candidates.len());
    let mut selected: Vec<(String, f64)> = Vec::with_capacity(limit);
    let mut remaining = candidates.to_vec();

    // Cache neighborhood sets for fast similarity comparison
    let mut neighbor_sets: HashMap<String, HashSet<String>> = HashMap::new();
    for (ent, _) in candidates {
        let set = adjacency
            .get(ent)
            .map(|n| n.iter().map(|(s, _)| s.clone()).collect())
            .unwrap_or_default();
        neighbor_sets.insert(ent.clone(), set);
    }

    let empty_set: HashSet<String> = HashSet::new();
    let similarity = |a: &str, b: &str| -> f64 {
        let sa = neighbor_sets.get(a).unwrap_or(&empty_set);
        let sb = neighbor_sets.get(b).unwrap_or(&empty_set);
        if sa.is_empty() && sb.is_empty() {
            return 0.0;
        }
        let intersect = sa.intersection(sb).count() as f64;
        let union = sa.union(sb).count() as f64;
        intersect / union
    };

    while selected.len() < limit && !remaining.is_empty() {
        let mut best_idx = 0;
        let mut best_score = f64::NEG_INFINITY;

        for (i, (entity, ppr_score)) in remaining.iter().enumerate() {
            let max_sim = if selected.is_empty() {
                0.0
            } else {
                selected
                    .iter()
                    .map(|(s_ent, _)| similarity(entity, s_ent))
                    .fold(0.0f64, |a, b| a.max(b))
            };

            let mmr_score = lambda * ppr_score - (1.0 - lambda) * max_sim;
            if mmr_score > best_score {
                best_score = mmr_score;
                best_idx = i;
            }
        }
        selected.push(remaining.remove(best_idx));
    }
    selected
}

/// BFS-based recall: ranks reachable entities by inverse hop distance + cumulative edge weight.
///
/// Simpler than PPR — useful as a baseline for recall@k benchmarks.
/// Entities closer to the seeds (fewer hops) receive higher scores.
pub fn bfs_recall(
    seed_entities: &[String],
    max_hops: usize,
    top_k: usize,
) -> Result<Vec<(String, f64)>> {
    if seed_entities.is_empty() {
        return Ok(Vec::new());
    }
    let conn = crate::db_pool::get()?;
    let seed_set: HashSet<String> = seed_entities.iter().map(|s| s.to_lowercase()).collect();

    let mut dist: HashMap<String, usize> = HashMap::new();
    let mut weight_sum: HashMap<String, f64> = HashMap::new();
    for seed in &seed_set {
        dist.insert(seed.clone(), 0);
    }
    let mut frontier: Vec<String> = seed_set.iter().cloned().collect();

    let mut fwd =
        conn.prepare("SELECT object, weight FROM chump_memory_graph WHERE subject = ?1")?;
    let mut bwd =
        conn.prepare("SELECT subject, weight FROM chump_memory_graph WHERE object = ?1")?;

    for hop in 1..=max_hops.max(1) {
        let mut next: Vec<String> = Vec::new();
        for entity in &frontier {
            let forward: Vec<(String, f64)> = fwd
                .query_map(rusqlite::params![entity], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            let backward: Vec<(String, f64)> = bwd
                .query_map(rusqlite::params![entity], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            for (neighbor, w) in forward.into_iter().chain(backward) {
                *weight_sum.entry(neighbor.clone()).or_insert(0.0) += w;
                if !dist.contains_key(&neighbor) {
                    dist.insert(neighbor.clone(), hop);
                    next.push(neighbor);
                }
            }
        }
        frontier = next;
        if frontier.is_empty() {
            break;
        }
    }

    let mut ranked: Vec<(String, f64)> = dist
        .into_iter()
        .filter(|(name, _)| !seed_set.contains(name.as_str()))
        .map(|(name, d)| {
            let w = weight_sum.get(&name).copied().unwrap_or(0.0);
            let score = 1.0 / d as f64 + w * 0.1;
            (name, score)
        })
        .collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    ranked.truncate(top_k);
    Ok(ranked)
}

/// Find memory IDs connected to a set of entities (for RRF integration).
pub fn memory_ids_for_entities(entities: &[String]) -> Result<Vec<(i64, f64)>> {
    if entities.is_empty() {
        return Ok(Vec::new());
    }
    let conn = crate::db_pool::get()?;
    let mut id_scores: HashMap<i64, f64> = HashMap::new();

    for entity in entities {
        let entity_lower = entity.to_lowercase();
        let mut stmt = conn.prepare(
            "SELECT source_memory_id, weight FROM chump_memory_graph \
             WHERE (subject = ?1 OR object = ?1) AND source_memory_id IS NOT NULL",
        )?;
        let rows: Vec<(i64, f64)> = stmt
            .query_map(rusqlite::params![entity_lower], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        for (mid, weight) in rows {
            *id_scores.entry(mid).or_default() += weight;
        }
    }

    let mut ranked: Vec<(i64, f64)> = id_scores.into_iter().collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    // Naive MMR for ID scores to scatter memory clusters
    let lambda = 0.8;
    if ranked.len() > 1 {
        let mut mmr_selected = Vec::with_capacity(ranked.len());
        let mut remaining = ranked;
        while !remaining.is_empty() {
            let mut best_idx = 0;
            let mut best_score = f64::NEG_INFINITY;
            for (i, (id, base_score)) in remaining.iter().enumerate() {
                // If ID is numerically close (contiguous block inserted same time), penalize
                let max_sim = if mmr_selected.is_empty() {
                    0.0
                } else {
                    mmr_selected
                        .iter()
                        .map(|(s_id, _)| {
                            let diff: i64 = id - s_id;
                            if diff.abs() < 5 {
                                0.5
                            } else {
                                0.0
                            }
                        })
                        .fold(0.0f64, |a, b| a.max(b))
                };
                let score = lambda * base_score - (1.0 - lambda) * max_sim;
                if score > best_score {
                    best_score = score;
                    best_idx = i;
                }
            }
            mmr_selected.push(remaining.remove(best_idx));
        }
        ranked = mmr_selected;
    }

    Ok(ranked)
}

/// Extract entities from a query string (for seeding PageRank).
/// Splits on whitespace, filters stop words and short tokens.
pub fn extract_query_entities(query: &str) -> Vec<String> {
    let stop_words: HashSet<&str> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "do", "does", "did", "will", "would", "could", "should", "may", "might", "shall", "can",
        "need", "dare", "ought", "used", "to", "of", "in", "for", "on", "with", "at", "by", "from",
        "as", "into", "through", "during", "before", "after", "above", "below", "between", "out",
        "off", "over", "under", "again", "further", "then", "once", "here", "there", "when",
        "where", "why", "how", "all", "both", "each", "few", "more", "most", "other", "some",
        "such", "no", "nor", "not", "only", "own", "same", "so", "than", "too", "very", "just",
        "because", "but", "and", "or", "if", "while", "about", "what", "which", "who", "whom",
        "this", "that", "these", "those", "i", "me", "my", "myself", "we", "our", "you", "your",
        "he", "him", "his", "she", "her", "it", "its", "they", "them", "their",
    ]
    .iter()
    .copied()
    .collect();

    query
        .split_whitespace()
        .map(clean_entity)
        .filter(|w| w.len() >= 2 && !stop_words.contains(w.as_str()))
        .collect()
}

/// LLM-assisted triple extraction: sends text to a worker model and parses structured output.
/// Returns triples with a confidence score. Falls back to regex extraction on any failure.
pub async fn extract_triples_llm(text: &str) -> Vec<(String, String, String, f64)> {
    let regex_fallback = || {
        extract_triples(text)
            .into_iter()
            .map(|(s, r, o)| (s, r, o, 0.5))
            .collect()
    };

    if text.len() < 10 {
        return regex_fallback();
    }

    let Some(provider) = llm_worker_provider() else {
        return regex_fallback();
    };
    let system = "Extract knowledge graph triples from the text. Return ONLY a JSON array \
        of objects with keys: subject, relation, object, confidence (0.0-1.0). \
        Normalize entities to lowercase. Use short relation labels (e.g. \"uses\", \"is\", \"caused\"). \
        Return [] if no meaningful triples can be extracted.".to_string();

    let messages = vec![axonerai::provider::Message {
        role: "user".to_string(),
        content: text.to_string(),
    }];

    match provider.complete(messages, None, None, Some(system)).await {
        Ok(response) => {
            if let Some(ref reply) = response.text {
                if let Some(triples) = parse_llm_triples(reply) {
                    return triples;
                }
            }
            regex_fallback()
        }
        Err(_) => regex_fallback(),
    }
}

fn llm_worker_provider() -> Option<Box<dyn axonerai::provider::Provider>> {
    let api_key = std::env::var("OPENAI_API_KEY")
        .ok()
        .filter(|k| !k.is_empty())?;
    let base = if crate::cluster_mesh::force_local_primary_execution() {
        std::env::var("OPENAI_API_BASE")
            .ok()
            .filter(|u| !u.is_empty())
    } else {
        std::env::var("CHUMP_WORKER_API_BASE")
            .ok()
            .filter(|u| !u.is_empty())
            .or_else(|| std::env::var("OPENAI_API_BASE").ok())
            .filter(|u| !u.is_empty())
    };
    let model = std::env::var("CHUMP_WORKER_MODEL")
        .ok()
        .filter(|m| !m.is_empty())
        .or_else(|| std::env::var("OPENAI_MODEL").ok())
        .unwrap_or_else(|| "qwen2.5:14b".to_string());
    if let Some(base) = base {
        let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
            .ok()
            .filter(|s| !s.is_empty());
        Some(Box::new(
            crate::local_openai::LocalOpenAIProvider::with_fallback(base, fallback, api_key, model),
        ))
    } else {
        Some(Box::new(
            axonerai::openai::OpenAIProvider::new(api_key).with_model(model),
        ))
    }
}

fn parse_llm_triples(response: &str) -> Option<Vec<(String, String, String, f64)>> {
    let trimmed = response.trim();
    let json_str = if let Some(start) = trimmed.find('[') {
        if let Some(end) = trimmed.rfind(']') {
            &trimmed[start..=end]
        } else {
            return None;
        }
    } else {
        return None;
    };

    let arr: Vec<serde_json::Value> = serde_json::from_str(json_str).ok()?;
    let mut triples = Vec::new();
    for item in &arr {
        let subject = item.get("subject")?.as_str()?.to_lowercase();
        let relation = item.get("relation")?.as_str()?.to_lowercase();
        let object = item.get("object")?.as_str()?.to_lowercase();
        let confidence = item
            .get("confidence")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.7)
            .clamp(0.0, 1.0);
        if is_valid_entity(&subject) && is_valid_entity(&object) && !relation.is_empty() {
            triples.push((subject, relation, object, confidence));
        }
    }
    if triples.is_empty() {
        None
    } else {
        Some(triples)
    }
}

/// Store triples with confidence scores. Higher confidence triples get higher weights.
pub fn store_triples_with_confidence(
    triples: &[(String, String, String, f64)],
    source_memory_id: Option<i64>,
    source_episode_id: Option<i64>,
) -> Result<usize> {
    if triples.is_empty() {
        return Ok(0);
    }
    let conn = crate::db_pool::get()?;
    let mut count = 0;
    for (subject, relation, object, confidence) in triples {
        let existing: i64 = conn.query_row(
            "SELECT COUNT(*) FROM chump_memory_graph \
             WHERE subject = ?1 AND relation = ?2 AND object = ?3",
            rusqlite::params![subject, relation, object],
            |r| r.get(0),
        )?;
        if existing > 0 {
            let weight_boost = 0.5 * confidence;
            conn.execute(
                "UPDATE chump_memory_graph SET weight = weight + ?4 \
                 WHERE subject = ?1 AND relation = ?2 AND object = ?3",
                rusqlite::params![subject, relation, object, weight_boost],
            )?;
        } else {
            conn.execute(
                "INSERT INTO chump_memory_graph (subject, relation, object, source_memory_id, source_episode_id, weight) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params![
                    subject,
                    relation,
                    object,
                    source_memory_id,
                    source_episode_id,
                    confidence,
                ],
            )?;
            count += 1;
        }
    }
    Ok(count)
}

/// Valence: sentiment/emotional tone for a relation (-1.0 = negative, 0.0 = neutral, +1.0 = positive).
pub fn relation_valence(relation: &str) -> f64 {
    match relation {
        "fixed" | "succeeded" | "built" | "created" | "prefers" | "works_with" => 0.6,
        "uses" | "has" | "is" | "runs" | "runs_on" | "connects_to" | "deployed_to" => 0.0,
        "failed" | "broke" | "caused" => -0.5,
        "depends_on" | "requires" | "needs" | "wants" => -0.1,
        _ => 0.0,
    }
}

/// Compute valence for an entity: weighted average of valences of its connected relations.
pub fn entity_valence(entity: &str) -> Result<f64> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT relation, weight FROM chump_memory_graph WHERE subject = ?1 OR object = ?1",
    )?;
    let rows: Vec<(String, f64)> = stmt
        .query_map(rusqlite::params![entity.to_lowercase()], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    if rows.is_empty() {
        return Ok(0.0);
    }

    let total_weight: f64 = rows.iter().map(|(_, w)| w).sum();
    if total_weight <= 0.0 {
        return Ok(0.0);
    }
    let weighted_valence: f64 = rows.iter().map(|(r, w)| relation_valence(r) * w).sum();
    Ok(weighted_valence / total_weight)
}

/// Generate a one-sentence gist for an entity cluster (its neighborhood in the graph).
pub fn entity_gist(entity: &str) -> Result<String> {
    let conn = crate::db_pool::get()?;
    let entity_lower = entity.to_lowercase();

    let mut stmt = conn.prepare(
        "SELECT subject, relation, object, weight FROM chump_memory_graph \
         WHERE subject = ?1 OR object = ?1 ORDER BY weight DESC LIMIT 5",
    )?;
    let rows: Vec<(String, String, String, f64)> = stmt
        .query_map(rusqlite::params![entity_lower], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, f64>(3)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    if rows.is_empty() {
        return Ok(format!("{}: no known associations.", entity));
    }

    let valence = entity_valence(entity).unwrap_or(0.0);
    let tone = if valence > 0.3 {
        "positive"
    } else if valence < -0.3 {
        "negative"
    } else {
        "neutral"
    };

    let top_relations: Vec<String> = rows
        .iter()
        .take(3)
        .map(|(s, r, o, _)| format!("{} {} {}", s, r, o))
        .collect();

    Ok(format!(
        "{} ({} tone, {} connections): {}",
        entity,
        tone,
        rows.len(),
        top_relations.join("; ")
    ))
}

pub fn graph_available() -> bool {
    crate::db_pool::get().is_ok()
}

/// Count of triples in the graph.
pub fn triple_count() -> Result<i64> {
    let conn = crate::db_pool::get()?;
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM chump_memory_graph", [], |r| r.get(0))?;
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_triples_basic() {
        let text = "Chump is a Discord bot. Jeff prefers Rust. The bot uses SQLite.";
        let triples = extract_triples(text);
        assert!(
            triples.len() >= 2,
            "should extract at least 2 triples: {:?}",
            triples
        );
        let subjects: Vec<&str> = triples.iter().map(|(s, _, _)| s.as_str()).collect();
        assert!(
            subjects.iter().any(|s| s.contains("chump")),
            "should find chump as subject: {:?}",
            subjects
        );
    }

    #[test]
    fn test_extract_triples_causal() {
        let text = "The timeout caused a failure. The fix requires updating the config.";
        let triples = extract_triples(text);
        let relations: Vec<&str> = triples.iter().map(|(_, r, _)| r.as_str()).collect();
        assert!(
            relations.contains(&"caused"),
            "should find causal relation: {:?}",
            relations
        );
    }

    #[test]
    fn test_extract_query_entities() {
        let entities = extract_query_entities("What is the Discord bot configuration for Chump?");
        assert!(entities.contains(&"discord".to_string()));
        assert!(entities.contains(&"chump".to_string()));
        assert!(!entities.contains(&"the".to_string()));
        assert!(!entities.contains(&"is".to_string()));
    }

    #[test]
    fn test_clean_entity() {
        assert_eq!(clean_entity("  The Bot  "), "bot");
        assert_eq!(clean_entity("a simple test"), "simple test");
    }

    #[test]
    fn test_is_valid_entity() {
        assert!(is_valid_entity("chump"));
        assert!(is_valid_entity("discord bot"));
        assert!(!is_valid_entity("a"));
        assert!(!is_valid_entity("12345"));
    }

    /// Run alone via `scripts/memory-graph-benchmark.sh` so `CHUMP_MEMORY_DB_PATH` applies before pool init.
    #[test]
    #[ignore = "run scripts/memory-graph-benchmark.sh"]
    fn associative_recall_benchmark() {
        let chain: Vec<(String, String, String)> = (0u32..50)
            .map(|i| {
                (
                    format!("entity_{i}"),
                    "links_to".to_string(),
                    format!("entity_{}", i + 1),
                )
            })
            .collect();
        store_triples(&chain, None, None).expect("store triples");
        let t0 = std::time::Instant::now();
        let out = associative_recall(&["entity_0".to_string()], 8, 10).expect("recall");
        let elapsed = t0.elapsed();
        eprintln!("associative_recall: {} results in {:?}", out.len(), elapsed);
        assert!(!out.is_empty(), "expected non-empty recall");

        // Curated recall@k: seed should rank a multi-hop hub in top-5.
        let curated = vec![
            (
                "mg_curated_iphone".to_string(),
                "uses".to_string(),
                "mg_curated_ios".to_string(),
            ),
            (
                "mg_curated_ipad".to_string(),
                "uses".to_string(),
                "mg_curated_ios".to_string(),
            ),
            (
                "mg_curated_ios".to_string(),
                "part_of".to_string(),
                "mg_curated_hub".to_string(),
            ),
            (
                "mg_curated_macbook".to_string(),
                "uses".to_string(),
                "mg_curated_macos".to_string(),
            ),
            (
                "mg_curated_macos".to_string(),
                "part_of".to_string(),
                "mg_curated_hub".to_string(),
            ),
        ];
        store_triples(&curated, None, None).expect("curated triples");
        let ranked =
            associative_recall(&["mg_curated_iphone".to_string()], 12, 5).expect("curated recall");
        let top: Vec<&str> = ranked.iter().map(|(s, _)| s.as_str()).collect();
        assert!(
            top.contains(&"mg_curated_hub"),
            "recall@k: expected mg_curated_hub in top {:?}, got {:?}",
            5,
            top
        );
        eprintln!(
            "curated recall@5 top: {:?} (timing chain+PPR: {:?})",
            top, elapsed
        );
    }

    /// EVAL-003 / COG-002 — recall@5 on 50 synthetic multi-hop QA fixtures.
    ///
    /// Compares BFS vs PPR recall strategies and regex vs LLM extraction.
    /// Run via `scripts/recall-benchmark.sh` which sets CHUMP_MEMORY_DB_PATH and
    /// captures stdout as markdown for docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md (archived).
    #[test]
    #[ignore = "run scripts/recall-benchmark.sh"]
    fn recall_benchmark_eval_003() {
        use std::collections::HashSet;

        // ── fixture triples ─────────────────────────────────────────────
        let fixture_triples: &[(&str, &str, &str)] = &[
            ("chump", "uses", "sqlite"),
            ("chump", "uses", "tokio"),
            ("chump", "uses", "axum"),
            ("chump", "uses", "ollama"),
            ("chump", "implements", "acp"),
            ("chump", "part_of", "fleet"),
            ("sqlite", "enables", "memory_graph"),
            ("sqlite", "enables", "fts5"),
            ("fts5", "enables", "memory_recall"),
            ("memory_graph", "uses", "ppr"),
            ("ppr", "implements", "associative_recall"),
            ("memory_recall", "uses", "fts5"),
            ("axum", "part_of", "chump"),
            ("axum", "enables", "sse"),
            ("sse", "part_of", "acp"),
            ("acp", "targets", "zed"),
            ("acp", "targets", "jetbrains"),
            ("ollama", "runs", "qwen3"),
            ("ollama", "runs", "llava"),
            ("fleet", "includes", "mabel"),
            ("fleet", "includes", "chump"),
            ("mabel", "runs_on", "pixel"),
            ("pixel", "runs", "android"),
            ("android", "uses", "adb"),
            ("adb", "enables", "termux"),
            ("termux", "part_of", "pixel"),
            ("pixel", "part_of", "fleet"),
            ("memory_graph", "part_of", "chump"),
            ("ppr", "part_of", "memory_graph"),
            ("associative_recall", "uses", "sqlite"),
            ("tokio", "enables", "axum"),
            ("zed", "uses", "acp"),
            ("jetbrains", "uses", "acp"),
            ("llava", "enables", "memory_graph"),
            ("memory_recall", "part_of", "chump"),
            ("sse", "uses", "axum"),
            ("android", "part_of", "mabel"),
            ("mabel", "part_of", "fleet"),
            ("termux", "runs_on", "android"),
            ("adb", "part_of", "android"),
            ("fts5", "part_of", "sqlite"),
            ("memory_graph", "uses", "sqlite"),
            ("tokio", "part_of", "chump"),
            ("associative_recall", "part_of", "memory_graph"),
            ("memory_recall", "uses", "memory_graph"),
        ];

        // ── QA pairs: (seeds, expected_in_top_5, hop_group) ───────────
        let qa: &[(&[&str], &[&str], &str)] = &[
            // 1-hop
            (&["chump"], &["sqlite", "tokio", "axum"], "A"),
            (&["mabel"], &["pixel", "fleet"], "A"),
            (&["sqlite"], &["memory_graph", "fts5"], "A"),
            (&["acp"], &["zed", "jetbrains"], "A"),
            (&["fleet"], &["mabel", "chump"], "A"),
            (&["ollama"], &["qwen3", "llava"], "A"),
            (&["axum"], &["chump", "sse"], "A"),
            (&["tokio"], &["axum"], "A"),
            (&["ppr"], &["memory_graph", "associative_recall"], "A"),
            (&["fts5"], &["sqlite", "memory_recall"], "A"),
            // 2-hop
            (&["chump"], &["memory_graph", "fts5"], "B"),
            (&["chump"], &["qwen3", "llava"], "B"),
            (&["mabel"], &["termux", "adb"], "B"),
            (&["fleet"], &["pixel", "android"], "B"),
            (&["fleet"], &["sqlite"], "B"),
            (&["acp"], &["chump", "sse"], "B"),
            (&["ppr"], &["sqlite"], "B"),
            (&["ollama"], &["memory_graph"], "B"),
            (&["sqlite"], &["chump", "ppr"], "B"),
            (&["zed"], &["chump"], "B"),
            (&["jetbrains"], &["chump"], "B"),
            (&["llava"], &["memory_graph"], "B"),
            (&["sse"], &["axum", "chump"], "B"),
            (&["android"], &["mabel", "fleet"], "B"),
            (&["termux"], &["mabel", "pixel"], "B"),
            (&["adb"], &["mabel", "android"], "B"),
            (&["associative_recall"], &["sqlite", "chump"], "B"),
            (&["memory_recall"], &["chump", "fts5"], "B"),
            (&["qwen3"], &["chump"], "B"),
            (&["pixel"], &["fleet"], "B"),
            // 3-hop
            (&["chump"], &["termux", "adb"], "C"),
            (&["chump"], &["pixel", "android"], "C"),
            (&["fleet"], &["qwen3", "llava"], "C"),
            (&["acp"], &["memory_graph", "fts5"], "C"),
            (&["ppr"], &["axum", "sse"], "C"),
            (&["zed"], &["sqlite"], "C"),
            (&["fts5"], &["ppr", "associative_recall"], "C"),
            (&["android"], &["chump", "sqlite"], "C"),
            (&["tokio"], &["memory_graph", "fts5"], "C"),
            (&["sse"], &["sqlite", "memory_graph"], "C"),
            (&["ollama"], &["acp", "sse"], "C"),
            (&["mabel"], &["sqlite", "fts5"], "C"),
            (&["llava"], &["acp", "zed"], "C"),
            (&["memory_recall"], &["ppr", "associative_recall"], "C"),
            (&["adb"], &["chump", "fleet"], "C"),
            (&["associative_recall"], &["axum", "acp"], "C"),
            (&["termux"], &["chump", "fleet"], "C"),
            (&["jetbrains"], &["sqlite"], "C"),
            (&["qwen3"], &["acp", "fleet"], "C"),
            (&["pixel"], &["sqlite"], "C"),
        ];

        let triples_owned: Vec<(String, String, String)> = fixture_triples
            .iter()
            .map(|(s, r, o)| (s.to_string(), r.to_string(), o.to_string()))
            .collect();
        store_triples(&triples_owned, None, None).expect("store fixture triples");

        let k = 5usize;
        let recall_at_k = |ranked: &[(String, f64)], expected: &[&str]| -> f64 {
            if expected.is_empty() {
                return 1.0;
            }
            let top: HashSet<&str> = ranked.iter().take(k).map(|(e, _)| e.as_str()).collect();
            expected.iter().filter(|&&e| top.contains(e)).count() as f64 / expected.len() as f64
        };

        let mut bfs_sum = 0.0f64;
        let mut ppr_sum = 0.0f64;
        let mut group_stats: std::collections::HashMap<&str, (f64, f64, u32)> =
            std::collections::HashMap::new();

        for (seeds, expected, group) in qa {
            let seed_v: Vec<String> = seeds.iter().map(|s| s.to_string()).collect();
            let bfs = bfs_recall(&seed_v, 4, k).unwrap_or_default();
            let ppr = associative_recall(&seed_v, 4, k).unwrap_or_default();
            let r_bfs = recall_at_k(&bfs, expected);
            let r_ppr = recall_at_k(&ppr, expected);
            bfs_sum += r_bfs;
            ppr_sum += r_ppr;
            let e = group_stats.entry(group).or_insert((0.0, 0.0, 0));
            e.0 += r_bfs;
            e.1 += r_ppr;
            e.2 += 1;
        }

        let n = qa.len() as f64;
        let overall_bfs = bfs_sum / n;
        let overall_ppr = ppr_sum / n;

        // Extraction precision (regex vs expected)
        #[allow(clippy::type_complexity)]
        let extraction_cases: &[(&str, &[(&str, &str, &str)])] = &[
            (
                "Chump uses SQLite for storage.",
                &[("chump", "uses", "sqlite")],
            ),
            ("Mabel runs on Pixel.", &[("mabel", "runs_on", "pixel")]),
            ("Ollama runs Qwen3 models.", &[("ollama", "runs", "qwen3")]),
            (
                "The ACP protocol targets Zed.",
                &[("acp", "targets", "zed")],
            ),
            (
                "PPR implements associative recall.",
                &[("ppr", "implements", "associative_recall")],
            ),
        ];
        let mut regex_prec_sum = 0.0f64;
        for (text, expected) in extraction_cases {
            let found = extract_triples(text);
            let found_set: HashSet<(String, String, String)> = found
                .iter()
                .map(|(s, r, o)| (s.to_lowercase(), r.to_lowercase(), o.to_lowercase()))
                .collect();
            let hits = expected
                .iter()
                .filter(|(s, r, o)| {
                    found_set.contains(&(s.to_lowercase(), r.to_lowercase(), o.to_lowercase()))
                })
                .count();
            regex_prec_sum += hits as f64 / expected.len() as f64;
        }
        let regex_prec = regex_prec_sum / extraction_cases.len() as f64;

        // ── Print markdown ──────────────────────────────────────────────
        println!("\n## Retrieval Pipeline Benchmark (EVAL-003 / COG-002)\n");
        println!(
            "> **Fixture:** {} QA pairs, {} triples, k={k}",
            qa.len(),
            fixture_triples.len()
        );
        println!();
        println!("### Recall@5 Summary\n");
        println!("| Strategy | Overall Recall@5 | vs BFS |");
        println!("|----------|:----------------:|:------:|");
        println!("| BFS      | {overall_bfs:.3}            | —      |");
        println!(
            "| PPR      | {overall_ppr:.3}            | {:+.3} |",
            overall_ppr - overall_bfs
        );
        println!();
        println!("### Per-Group Results\n");
        println!("| Group | Hops | BFS recall@5 | PPR recall@5 |");
        println!("|-------|:----:|:------------:|:------------:|");
        for group in &["A", "B", "C"] {
            if let Some((b, p, cnt)) = group_stats.get(group) {
                let hops = match *group {
                    "A" => "1",
                    "B" => "2",
                    _ => "3",
                };
                println!(
                    "| {group}     | {hops}    | {:.3}        | {:.3}        |",
                    b / *cnt as f64,
                    p / *cnt as f64
                );
            }
        }
        println!();
        println!("### Extraction Quality (regex)\n");
        println!("| Method | Precision on 5 sample texts |");
        println!("|--------|:---------------------------:|");
        println!("| Regex  | {regex_prec:.3}                      |");
        println!("| LLM    | — (set CHUMP_LLM_URL to enable)  |");

        // Assertion: results must be non-trivially non-zero (graph is well-connected)
        assert!(overall_bfs > 0.2, "BFS recall too low: {overall_bfs:.3}");
        assert!(overall_ppr > 0.2, "PPR recall too low: {overall_ppr:.3}");
        eprintln!("recall_benchmark: BFS={overall_bfs:.3} PPR={overall_ppr:.3} regex_prec={regex_prec:.3}");
    }
}
