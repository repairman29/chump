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

    for sentence in text.split(|c: char| c == '.' || c == '!' || c == '\n') {
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
    len >= 2 && len <= 80 && s.chars().any(|c| c.is_alphabetic())
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

/// Personalized PageRank-inspired traversal: given seed entities, spread activation
/// through the graph up to `max_hops` and return the top-ranked connected entities.
///
/// The algorithm:
/// 1. Start with seed entities (extracted from the query) with score 1.0
/// 2. For each hop, spread activation to neighbors (weighted by edge weight)
/// 3. Apply damping factor to prevent runaway activation
/// 4. Return entities sorted by final activation score
pub fn associative_recall(
    seed_entities: &[String],
    max_hops: usize,
    top_k: usize,
) -> Result<Vec<(String, f64)>> {
    if seed_entities.is_empty() {
        return Ok(Vec::new());
    }

    let conn = crate::db_pool::get()?;
    let damping = 0.85;

    // Pre-prepare statements outside the loop
    let mut fwd_stmt = conn.prepare(
        "SELECT object, weight FROM chump_memory_graph WHERE subject = ?1",
    )?;
    let mut bwd_stmt = conn.prepare(
        "SELECT subject, weight FROM chump_memory_graph WHERE object = ?1",
    )?;

    let mut scores: HashMap<String, f64> = HashMap::new();
    for entity in seed_entities {
        let e = entity.to_lowercase();
        *scores.entry(e).or_default() = 1.0;
    }

    // Track visited entities per hop to prevent cycles from causing runaway activation
    let mut visited: HashSet<String> = HashSet::new();

    for _hop in 0..max_hops {
        let mut new_scores: HashMap<String, f64> = HashMap::new();
        let current_entities: Vec<(String, f64)> = scores.iter()
            .filter(|(e, _)| !visited.contains(*e))
            .map(|(e, &s)| (e.clone(), s))
            .collect();

        for (entity, score) in &current_entities {
            visited.insert(entity.clone());

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

            let neighbors: Vec<(String, f64)> = forward.into_iter().chain(backward).collect();
            let total_weight: f64 = neighbors.iter().map(|(_, w)| w).sum();
            if total_weight <= 0.0 {
                continue;
            }

            for (neighbor, weight) in &neighbors {
                let spread = score * damping * (weight / total_weight);
                *new_scores.entry(neighbor.clone()).or_default() += spread;
            }
        }

        for (entity, new_score) in new_scores {
            *scores.entry(entity).or_default() += new_score;
        }
    }

    let seed_set: HashSet<String> = seed_entities.iter().map(|s| s.to_lowercase()).collect();
    let mut ranked: Vec<(String, f64)> = scores
        .into_iter()
        .filter(|(e, _)| !seed_set.contains(e))
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
    Ok(ranked)
}

/// Extract entities from a query string (for seeding PageRank).
/// Splits on whitespace, filters stop words and short tokens.
pub fn extract_query_entities(query: &str) -> Vec<String> {
    let stop_words: HashSet<&str> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "have", "has",
        "had", "do", "does", "did", "will", "would", "could", "should", "may", "might", "shall",
        "can", "need", "dare", "ought", "used", "to", "of", "in", "for", "on", "with", "at",
        "by", "from", "as", "into", "through", "during", "before", "after", "above", "below",
        "between", "out", "off", "over", "under", "again", "further", "then", "once", "here",
        "there", "when", "where", "why", "how", "all", "both", "each", "few", "more", "most",
        "other", "some", "such", "no", "nor", "not", "only", "own", "same", "so", "than",
        "too", "very", "just", "because", "but", "and", "or", "if", "while", "about", "what",
        "which", "who", "whom", "this", "that", "these", "those", "i", "me", "my", "myself",
        "we", "our", "you", "your", "he", "him", "his", "she", "her", "it", "its", "they",
        "them", "their",
    ]
    .iter()
    .copied()
    .collect();

    query
        .split_whitespace()
        .map(|w| clean_entity(w))
        .filter(|w| w.len() >= 2 && !stop_words.contains(w.as_str()))
        .collect()
}

pub fn graph_available() -> bool {
    crate::db_pool::get().is_ok()
}

/// Count of triples in the graph.
pub fn triple_count() -> Result<i64> {
    let conn = crate::db_pool::get()?;
    let count: i64 =
        conn.query_row("SELECT COUNT(*) FROM chump_memory_graph", [], |r| r.get(0))?;
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
}
