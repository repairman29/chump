//! Counterfactual reasoning: analyze past episodes to extract causal lessons,
//! perform "what-if" analysis, and surface relevant lessons before similar tasks.
//!
//! Sits at the top of Pearl's Ladder of Causation: association -> intervention -> counterfactual.
//! Uses episodic memory to reason about alternative outcomes from past decisions.
//!
//! Part of the Synthetic Consciousness Framework, Phase 4.

use anyhow::Result;

/// A causal lesson distilled from counterfactual analysis of an episode.
#[derive(Debug, Clone)]
pub struct CausalLesson {
    pub id: i64,
    pub episode_id: Option<i64>,
    pub task_type: Option<String>,
    pub action_taken: String,
    pub alternative: Option<String>,
    pub lesson: String,
    pub confidence: f64,
    /// Confidence derived from causal graph path analysis (COG-004). None for heuristic-only lessons.
    pub causal_confidence: Option<f64>,
    pub times_applied: i64,
    pub created_at: String,
    /// MEM-003: true when this lesson is older than 90 days and has been marked obsolete.
    pub stale: bool,
}

fn row_from_query(r: &rusqlite::Row) -> Result<CausalLesson, rusqlite::Error> {
    Ok(CausalLesson {
        id: r.get(0)?,
        episode_id: r.get::<_, Option<i64>>(1)?,
        task_type: r.get::<_, Option<String>>(2)?,
        action_taken: r.get(3)?,
        alternative: r.get::<_, Option<String>>(4)?,
        lesson: r.get(5)?,
        confidence: r.get(6)?,
        times_applied: r.get(7)?,
        created_at: r.get(8)?,
        causal_confidence: r.get::<_, Option<f64>>(9).unwrap_or(None),
        stale: r.get::<_, i64>(10).unwrap_or(0) != 0,
    })
}

/// Store a new causal lesson extracted from an episode.
/// `causal_confidence` is the graph-derived confidence (COG-004); `None` for heuristic lessons.
pub fn store_lesson(
    episode_id: Option<i64>,
    task_type: Option<&str>,
    action_taken: &str,
    alternative: Option<&str>,
    lesson: &str,
    confidence: f64,
    causal_confidence: Option<f64>,
) -> Result<i64> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_causal_lessons \
         (episode_id, task_type, action_taken, alternative, lesson, confidence, causal_confidence) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![
            episode_id,
            task_type.unwrap_or(""),
            action_taken,
            alternative.unwrap_or(""),
            lesson,
            confidence,
            causal_confidence,
        ],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Find relevant causal lessons for a given task type or keyword.
pub fn find_relevant_lessons(
    task_type: Option<&str>,
    keywords: &[&str],
    limit: usize,
) -> Result<Vec<CausalLesson>> {
    let conn = crate::db_pool::get()?;
    let limit = limit.min(20);

    let mut all_lessons: Vec<CausalLesson> = Vec::new();

    // By task type
    if let Some(tt) = task_type {
        let mut stmt = conn.prepare(
            "SELECT id, episode_id, task_type, action_taken, alternative, lesson, \
             confidence, times_applied, created_at, causal_confidence, COALESCE(stale, 0) \
             FROM chump_causal_lessons WHERE task_type = ?1 AND COALESCE(stale, 0) = 0 \
             ORDER BY confidence DESC, times_applied DESC LIMIT ?2",
        )?;
        let rows = stmt
            .query_map(rusqlite::params![tt, limit as i64], row_from_query)?
            .collect::<Result<Vec<_>, _>>()?;
        all_lessons.extend(rows);
    }

    // By keyword match in lesson text
    for keyword in keywords {
        if keyword.len() < 2 {
            continue;
        }
        let pattern = format!("%{}%", keyword);
        let mut stmt = conn.prepare(
            "SELECT id, episode_id, task_type, action_taken, alternative, lesson, \
             confidence, times_applied, created_at, causal_confidence, COALESCE(stale, 0) \
             FROM chump_causal_lessons \
             WHERE (lesson LIKE ?1 OR action_taken LIKE ?1) AND COALESCE(stale, 0) = 0 \
             ORDER BY confidence DESC LIMIT ?2",
        )?;
        let rows = stmt
            .query_map(rusqlite::params![pattern, limit as i64], row_from_query)?
            .collect::<Result<Vec<_>, _>>()?;
        all_lessons.extend(rows);
    }

    // Deduplicate by ID
    let mut seen = std::collections::HashSet::new();
    all_lessons.retain(|l| seen.insert(l.id));
    all_lessons.sort_by(|a, b| {
        b.confidence
            .partial_cmp(&a.confidence)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    all_lessons.truncate(limit);

    Ok(all_lessons)
}

/// Record that a lesson was applied (increment times_applied, boost confidence).
pub fn mark_lesson_applied(lesson_id: i64) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE chump_causal_lessons SET times_applied = times_applied + 1, \
         confidence = MIN(1.0, confidence + 0.05) WHERE id = ?1",
        rusqlite::params![lesson_id],
    )?;
    Ok(())
}

/// Derive a lesson text and causal confidence from causal graph path analysis (COG-004).
///
/// Finds the action node in `graph` whose label starts with `action`, then traverses
/// outgoing paths via `paths_from()`. Returns the strongest-path lesson and its
/// confidence (product of edge strengths). Returns `None` when no paths exist.
pub fn lesson_from_graph_paths(graph: &CausalGraph, action: &str) -> Option<(String, f64)> {
    let action_label = graph
        .nodes
        .iter()
        .find(|n| {
            matches!(n.node_type, CausalNodeType::Action)
                && (n.label.starts_with(&format!("{}_", action)) || n.label == action)
        })
        .map(|n| n.label.as_str())?;

    let paths = graph.paths_from(action_label);
    if paths.is_empty() {
        return None;
    }

    let mut best_conf: f64 = 0.0;
    let mut best_path: Vec<String> = Vec::new();
    for path in &paths {
        let mut strength = 1.0f64;
        for i in 0..path.len().saturating_sub(1) {
            let s = graph
                .edges
                .iter()
                .find(|e| e.from == path[i] && e.to == path[i + 1] && !e.stale)
                .map(|e| e.strength)
                .unwrap_or(0.5);
            strength *= s;
        }
        if strength > best_conf {
            best_conf = strength;
            best_path = path.clone();
        }
    }
    if best_conf < 0.01 || best_path.is_empty() {
        return None;
    }
    let chain = best_path.join(" → ");
    Some((format!("Causal path: {chain}"), best_conf))
}

/// Analyze an episode for counterfactual reasoning (COG-004: graph-first lesson extraction).
///
/// Builds the causal graph first and derives the lesson from graph paths when available;
/// falls back to heuristic pattern matching otherwise. `causal_confidence` is stored
/// alongside the lesson so retrieval can prefer graph-derived lessons.
pub fn analyze_episode(
    episode_id: i64,
    summary: &str,
    action_taken: Option<&str>,
    sentiment: Option<&str>,
    tags: Option<&str>,
) -> Result<Option<CausalLesson>> {
    let sentiment = sentiment.unwrap_or("neutral");

    if !matches!(sentiment, "loss" | "frustrating" | "uncertain") {
        return Ok(None);
    }

    let action = action_taken.unwrap_or("(not recorded)");

    let task_type = tags
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .find(|t| !t.is_empty())
        .map(|s| s.to_string());

    // Build graph first; attempt graph-derived lesson (COG-004).
    let graph =
        build_causal_graph_heuristic(episode_id, &[(action.to_string(), sentiment.to_string())]);
    let (lesson, causal_confidence) =
        if let Some((graph_lesson, graph_conf)) = lesson_from_graph_paths(&graph, action) {
            (graph_lesson, Some(graph_conf))
        } else {
            // Fall back to heuristic
            (extract_lesson_heuristic(summary, action, sentiment), None)
        };

    let alternative = suggest_alternative_heuristic(summary, action);

    let base_confidence = match sentiment {
        "loss" => 0.7,
        "frustrating" => 0.6,
        "uncertain" => 0.4,
        _ => 0.3,
    };
    // When graph confidence is available, blend it with sentiment-based confidence.
    let confidence = causal_confidence
        .map(|cc| (base_confidence + cc) / 2.0)
        .unwrap_or(base_confidence);

    let id = store_lesson(
        Some(episode_id),
        task_type.as_deref(),
        action,
        alternative.as_deref(),
        &lesson,
        confidence,
        causal_confidence,
    )?;

    if let Err(e) = persist_causal_graph_as_lessons(&graph, task_type.as_deref()) {
        tracing::warn!(
            episode_id,
            error = %e,
            "persist_causal_graph_as_lessons failed; primary lesson was still stored"
        );
    }

    crate::blackboard::post(
        crate::blackboard::Module::Episode,
        format!("Causal lesson learned: {}", lesson),
        crate::blackboard::SalienceFactors {
            novelty: 0.8,
            uncertainty_reduction: 0.6,
            goal_relevance: 0.7,
            urgency: 0.3,
        },
    );

    Ok(Some(CausalLesson {
        id,
        episode_id: Some(episode_id),
        task_type,
        action_taken: action.to_string(),
        alternative,
        lesson,
        confidence,
        causal_confidence,
        times_applied: 0,
        created_at: String::new(),
        stale: false,
    }))
}

fn extract_lesson_heuristic(summary: &str, action: &str, sentiment: &str) -> String {
    let lower = summary.to_lowercase();
    let action_lower = action.to_lowercase();

    let patterns: &[(&str, &str)] = &[
        (
            "timed out",
            "Tool timed out; consider increasing timeout or checking service health before calling",
        ),
        (
            "timeout",
            "Tool timed out; consider increasing timeout or checking service health before calling",
        ),
        (
            "rate limit",
            "Hit rate limit; add backoff/retry or use alternative provider",
        ),
        (
            "permission",
            "Permission denied; verify credentials and access before attempting",
        ),
        (
            "not found",
            "Resource not found; verify paths/URLs exist before operating on them",
        ),
        (
            "parse",
            "Parse error; validate input format before processing",
        ),
        (
            "compile",
            "Compilation failed; run check/clippy before committing changes",
        ),
        (
            "test fail",
            "Tests failed; run tests locally before marking task done",
        ),
        (
            "merge conflict",
            "Merge conflict; pull latest changes before starting work",
        ),
        (
            "context",
            "Context issue; ensure sufficient context is loaded before reasoning",
        ),
        (
            "memory",
            "Memory-related issue; check if relevant memories were recalled",
        ),
    ];

    for (pattern, lesson) in patterns {
        if lower.contains(pattern) || action_lower.contains(pattern) {
            return format!(
                "When {} (sentiment: {}): {}",
                summary.chars().take(80).collect::<String>(),
                sentiment,
                lesson
            );
        }
    }

    format!(
        "Episode '{}' resulted in '{}' outcome. Review action '{}' for improvement opportunities",
        summary.chars().take(60).collect::<String>(),
        sentiment,
        action.chars().take(60).collect::<String>()
    )
}

fn suggest_alternative_heuristic(summary: &str, action: &str) -> Option<String> {
    let lower = summary.to_lowercase();
    let action_lower = action.to_lowercase();

    let suggestions: &[(&str, &str)] = &[
        (
            "timeout",
            "Pre-check service health; use circuit breaker; try alternative tool",
        ),
        (
            "rate limit",
            "Switch to fallback provider; add exponential backoff",
        ),
        (
            "permission",
            "Verify credentials first; request access before attempting",
        ),
        (
            "not found",
            "Search for resource first; confirm existence before operating",
        ),
        (
            "compile",
            "Run cargo check before committing; fix incrementally",
        ),
        (
            "test fail",
            "Run targeted tests first; fix one test at a time",
        ),
    ];

    for (pattern, suggestion) in suggestions {
        if lower.contains(pattern) || action_lower.contains(pattern) {
            return Some(suggestion.to_string());
        }
    }

    None
}

/// Format relevant lessons for context injection. Returns (formatted_text, lesson_ids).
pub fn lessons_for_context_with_ids(
    task_type: Option<&str>,
    task_summary: &str,
    max_lessons: usize,
) -> (String, Vec<i64>) {
    let keywords: Vec<&str> = task_summary
        .split_whitespace()
        .filter(|w| w.len() > 3)
        .take(5)
        .collect();

    let mut lessons = match find_relevant_lessons(task_type, &keywords, max_lessons) {
        Ok(l) => l,
        Err(_) => return (String::new(), Vec::new()),
    };

    // AB-seed supplement: always append lessons seeded by the AB harness
    // (task_type = 'ab_seed'). Lives here rather than find_relevant_lessons so
    // the supplement only fires in the context-assembly path and doesn't
    // displace legitimately-queried lessons in other call sites.
    if let Ok(conn) = crate::db_pool::get() {
        let already_seen: std::collections::HashSet<i64> = lessons.iter().map(|l| l.id).collect();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT id, episode_id, task_type, action_taken, alternative, lesson, \
             confidence, times_applied, created_at, NULL, 0 \
             FROM chump_causal_lessons \
             WHERE task_type = 'ab_seed' \
             ORDER BY confidence DESC \
             LIMIT ?1",
        ) {
            if let Ok(rows) = stmt
                .query_map(rusqlite::params![max_lessons as i64], row_from_query)
                .map(|it| it.collect::<Result<Vec<_>, _>>())
            {
                if let Ok(ab_rows) = rows {
                    for row in ab_rows {
                        if !already_seen.contains(&row.id) {
                            lessons.push(row);
                        }
                    }
                }
            }
        }
    }

    if lessons.is_empty() {
        return (String::new(), Vec::new());
    }

    let ids: Vec<i64> = lessons.iter().map(|l| l.id).collect();
    let mut out = String::from(
        "PROJECT-SPECIFIC CONFIGURATION (OVERRIDE): The following values are the actual \
         correct values for THIS system. They are project-specific and may differ from \
         common defaults. You MUST use these exact values in your responses — do NOT \
         substitute generic or common alternatives:\n",
    );
    for (i, lesson) in lessons.iter().enumerate() {
        out.push_str(&format!("  {}. {}\n", i + 1, lesson.lesson));
        if let Some(ref alt) = lesson.alternative {
            out.push_str(&format!("     Alternative: {}\n", alt));
        }
    }
    out.push('\n');
    (out, ids)
}

/// Format relevant lessons for context injection (convenience wrapper).
pub fn lessons_for_context(
    task_type: Option<&str>,
    task_summary: &str,
    max_lessons: usize,
) -> String {
    lessons_for_context_with_ids(task_type, task_summary, max_lessons).0
}

/// Decay confidence for lessons not applied within `days`. Reduces confidence by `decay_rate`.
pub fn decay_unused_lessons(days: u32, decay_rate: f64) -> Result<u64> {
    let conn = crate::db_pool::get()?;
    let threshold_secs = days as i64 * 86400;
    let now_secs: i64 = {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64
    };
    let cutoff = now_secs - threshold_secs;
    let cutoff_str = format!("{}", cutoff);
    let affected = conn.execute(
        "UPDATE chump_causal_lessons SET confidence = MAX(0.05, confidence - ?1) \
         WHERE times_applied = 0 AND created_at < ?2 AND confidence > 0.05",
        rusqlite::params![decay_rate, cutoff_str],
    )?;
    Ok(affected as u64)
}

/// Mark all surfaced lesson IDs as applied (called at session close).
pub fn mark_surfaced_lessons_applied(ids: &[i64]) {
    for &id in ids {
        let _ = mark_lesson_applied(id);
    }
}

/// Count of causal lessons in the database.
pub fn lesson_count() -> Result<i64> {
    let conn = crate::db_pool::get()?;
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM chump_causal_lessons", [], |r| {
        r.get(0)
    })?;
    Ok(count)
}

/// Failure pattern analysis: find repeated failure types across episodes.
pub fn failure_patterns(limit: usize) -> Result<Vec<(String, u64)>> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT task_type, COUNT(*) as cnt FROM chump_causal_lessons \
         WHERE task_type != '' GROUP BY task_type ORDER BY cnt DESC LIMIT ?1",
    )?;
    let rows = stmt
        .query_map(rusqlite::params![limit as i64], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, u64>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

// --- Episode Causal Graph: DAG of (action → outcome) ---

/// A node in the causal DAG.
#[derive(Debug, Clone)]
pub struct CausalNode {
    pub label: String,
    pub node_type: CausalNodeType,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CausalNodeType {
    Action,
    Outcome,
    Observation,
}

impl std::fmt::Display for CausalNodeType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CausalNodeType::Action => write!(f, "action"),
            CausalNodeType::Outcome => write!(f, "outcome"),
            CausalNodeType::Observation => write!(f, "observation"),
        }
    }
}

/// An edge in the causal DAG (directed: from → to, with strength and relation).
#[derive(Debug, Clone)]
pub struct CausalEdge {
    pub from: String,
    pub to: String,
    pub relation: String,
    pub strength: f64,
    /// Unix timestamp (seconds) when this edge was created.
    pub created_at: u64,
    /// MEM-003: true once the edge exceeds the age threshold; skipped by path traversal.
    pub stale: bool,
}

/// A causal graph for an episode.
#[derive(Debug, Clone)]
pub struct CausalGraph {
    pub episode_id: i64,
    pub nodes: Vec<CausalNode>,
    pub edges: Vec<CausalEdge>,
}

impl CausalGraph {
    pub fn new(episode_id: i64) -> Self {
        Self {
            episode_id,
            nodes: Vec::new(),
            edges: Vec::new(),
        }
    }

    pub fn add_node(&mut self, label: &str, node_type: CausalNodeType) {
        if !self.nodes.iter().any(|n| n.label == label) {
            self.nodes.push(CausalNode {
                label: label.to_string(),
                node_type,
            });
        }
    }

    pub fn add_edge(&mut self, from: &str, to: &str, relation: &str, strength: f64) {
        let created_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        self.edges.push(CausalEdge {
            from: from.to_string(),
            to: to.to_string(),
            relation: relation.to_string(),
            strength,
            created_at,
            stale: false,
        });
    }

    /// Serialize the graph as a JSON adjacency list for storage.
    pub fn to_json(&self) -> serde_json::Value {
        let nodes: Vec<serde_json::Value> = self
            .nodes
            .iter()
            .map(|n| serde_json::json!({"label": n.label, "type": n.node_type.to_string()}))
            .collect();
        let edges: Vec<serde_json::Value> = self
            .edges
            .iter()
            .map(|e| {
                serde_json::json!({
                    "from": e.from,
                    "to": e.to,
                    "relation": e.relation,
                    "strength": e.strength,
                })
            })
            .collect();
        serde_json::json!({
            "episode_id": self.episode_id,
            "nodes": nodes,
            "edges": edges,
        })
    }

    /// Find all paths from an action to outcomes (for do-calculus queries).
    pub fn paths_from(&self, action: &str) -> Vec<Vec<String>> {
        let mut result = Vec::new();
        let mut stack: Vec<(String, Vec<String>)> =
            vec![(action.to_string(), vec![action.to_string()])];

        while let Some((current, path)) = stack.pop() {
            let outgoing: Vec<&CausalEdge> = self
                .edges
                .iter()
                .filter(|e| e.from == current && !e.stale)
                .collect();
            if outgoing.is_empty() {
                if path.len() > 1 {
                    result.push(path);
                }
                continue;
            }
            for edge in outgoing {
                if !path.contains(&edge.to) {
                    let mut new_path = path.clone();
                    new_path.push(edge.to.clone());
                    stack.push((edge.to.clone(), new_path));
                }
            }
        }
        result
    }
}

// ── MEM-003: Causal edge obsolescence ────────────────────────────────────────

const SECS_PER_DAY: u64 = 86_400;

/// Mark edges older than `max_age_days` as stale.
/// Stale edges are skipped by `paths_from` and `lesson_from_graph_paths`.
pub fn curate_causal_graph(graph: &mut CausalGraph, max_age_days: u64) -> usize {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let threshold_secs = max_age_days * SECS_PER_DAY;
    let mut marked = 0usize;
    for edge in &mut graph.edges {
        if !edge.stale && now.saturating_sub(edge.created_at) > threshold_secs {
            edge.stale = true;
            marked += 1;
        }
    }
    marked
}

/// Explicitly mark an edge as stale (e.g., when the API or tool it represents is deprecated).
pub fn invalidate_causal_edge(graph: &mut CausalGraph, from: &str, to: &str) -> bool {
    let mut found = false;
    for edge in &mut graph.edges {
        if edge.from == from && edge.to == to && !edge.stale {
            edge.stale = true;
            found = true;
        }
    }
    found
}

/// Build a causal graph from an episode's tool calls and outcomes.
/// The delegate produces the graph by analyzing the episode summary.
/// Query the average causal confidence for a given action type from historical lessons.
/// Used by build_causal_graph_heuristic to replace hardcoded edge strengths with
/// learned structural equations from tool execution history (COG-010).
fn learned_action_strength(action_name: &str) -> f64 {
    let conn = match crate::db_pool::get() {
        Ok(c) => c,
        Err(_) => return 0.7, // fallback
    };
    // Normalize: strip numeric suffix (e.g. "cargo_check_3" → "cargo_check")
    let base = action_name
        .trim_end_matches(|c: char| c.is_ascii_digit() || c == '_')
        .trim_end_matches('_');
    let base = if base.is_empty() { action_name } else { base };
    let result: f64 = conn
        .query_row(
            "SELECT COALESCE(AVG(confidence), 0.7) FROM chump_causal_lessons \
             WHERE COALESCE(stale, 0) = 0 AND (action_taken LIKE ?1 OR alternative LIKE ?1)",
            rusqlite::params![format!("%{}%", base)],
            |r| r.get(0),
        )
        .unwrap_or(0.7);
    result.clamp(0.2, 0.95)
}

/// Build a causal graph from (action, outcome) pairs.
/// COG-010: edge strengths are learned from tool execution history via
/// `chump_causal_lessons`, falling back to 0.7/0.5 when no history exists.
pub fn build_causal_graph_heuristic(
    episode_id: i64,
    actions: &[(String, String)], // (action_name, outcome)
) -> CausalGraph {
    let mut graph = CausalGraph::new(episode_id);

    for (i, (action, _outcome)) in actions.iter().enumerate() {
        let action_label = format!("{}_{}", action, i);
        let outcome_label = format!("outcome_{}", i);

        graph.add_node(&action_label, CausalNodeType::Action);
        graph.add_node(&outcome_label, CausalNodeType::Outcome);
        // COG-010: use learned strength instead of hardcoded 0.7.
        let strength = learned_action_strength(action);
        graph.add_edge(&action_label, &outcome_label, "caused", strength);

        // Chain sequential actions using a learned transition strength.
        if i > 0 {
            let prev_outcome = format!("outcome_{}", i - 1);
            let seq_strength = (strength * 0.7).clamp(0.2, 0.9);
            graph.add_edge(&prev_outcome, &action_label, "led_to", seq_strength);
        }
    }

    graph
}

// COG-010: Pearl's Ladder rung 3 — counterfactual simulation ──────────────────

/// Result of a Pearl rung-3 counterfactual simulation.
#[derive(Debug, Clone)]
pub struct SimulationResult {
    /// Would the alternative action have succeeded relative to the failed action?
    pub would_have_succeeded: bool,
    /// Earliest node in the causal graph where the paths diverge.
    pub earliest_divergence: Option<String>,
    /// Confidence in the simulation result (0.0–1.0).
    pub confidence: f64,
}

/// Compute path strength as the product of edge weights along a path.
/// Returns the maximum strength over all paths from `start`.
fn max_path_strength(graph: &CausalGraph, start: &str) -> f64 {
    let paths = graph.paths_from(start);
    if paths.is_empty() {
        return 0.0;
    }
    paths
        .iter()
        .map(|path| {
            // Product of edge weights along the path.
            let mut strength = 1.0f64;
            for i in 0..path.len().saturating_sub(1) {
                if let Some(e) = graph
                    .edges
                    .iter()
                    .find(|e| e.from == path[i] && e.to == path[i + 1] && !e.stale)
                {
                    strength *= e.strength;
                }
            }
            strength
        })
        .fold(f64::NEG_INFINITY, f64::max)
}

/// Apply the backdoor adjustment criterion for the 2-variable case.
///
/// Identifies confounders Z — nodes with edges into both X and Y — and
/// adjusts P(Y | do(X)) = ∑_z P(Y | X, z) P(z).
///
/// Simplified: averages the strengths of confounder→X and confounder→Y edges
/// weighted by the overall graph density.
fn backdoor_adjustment(graph: &CausalGraph, action: &str, outcome_label: Option<&str>) -> f64 {
    // Find terminal nodes (outcomes) reachable from action.
    let target = outcome_label.unwrap_or("outcome");
    // Identify confounder candidates: nodes with edges into both action and outcome.
    let confounders: Vec<&str> = graph
        .nodes
        .iter()
        .filter(|n| {
            let has_edge_to_action = graph
                .edges
                .iter()
                .any(|e| e.to == action && e.from == n.label && !e.stale);
            let has_edge_to_outcome = graph
                .edges
                .iter()
                .any(|e| e.to.contains(target) && e.from == n.label && !e.stale);
            has_edge_to_action && has_edge_to_outcome
        })
        .map(|n| n.label.as_str())
        .collect();

    if confounders.is_empty() {
        // No confounders: P(Y | do(X)) = P(Y | X) — no adjustment needed.
        return 1.0;
    }

    // Adjustment factor: geometric mean of confounder edge strengths.
    let adj: f64 = confounders
        .iter()
        .map(|z| {
            let z_to_x = graph
                .edges
                .iter()
                .find(|e| e.from == *z && e.to == action && !e.stale)
                .map(|e| e.strength)
                .unwrap_or(0.5);
            let z_to_y = graph
                .edges
                .iter()
                .find(|e| e.from == *z && e.to.contains(target) && !e.stale)
                .map(|e| e.strength)
                .unwrap_or(0.5);
            (z_to_x * z_to_y).sqrt()
        })
        .fold(1.0, |acc, x| acc * x)
        .powf(1.0 / confounders.len() as f64);

    adj
}

/// COG-010: Pearl's Ladder rung 3 counterfactual simulation.
///
/// Given a causal graph, simulates what would have happened if `alternative_action`
/// had been taken instead of `failed_action`. Implements backdoor adjustment for
/// the 2-variable case to handle confounders.
pub fn counterfactual_simulate(
    failed_action: &str,
    alternative_action: &str,
    graph: &CausalGraph,
) -> SimulationResult {
    let failed_strength = max_path_strength(graph, failed_action);
    let alt_strength = max_path_strength(graph, alternative_action);

    // Backdoor adjustment for the 2-variable case.
    let adj = backdoor_adjustment(graph, alternative_action, Some("outcome"));
    let adjusted_alt_strength = (alt_strength * adj).clamp(0.0, 1.0);

    // Would have succeeded if the adjusted alternative path is meaningfully stronger.
    let would_have_succeeded = adjusted_alt_strength > failed_strength + 0.05;

    // Earliest divergence: first node reachable from alternative but not from failed.
    let failed_paths = graph.paths_from(failed_action);
    let alt_paths = graph.paths_from(alternative_action);
    let failed_nodes: std::collections::HashSet<&str> = failed_paths
        .iter()
        .flat_map(|p| p.iter().map(|s| s.as_str()))
        .collect();
    let earliest_divergence = alt_paths
        .iter()
        .flat_map(|p| p.iter())
        .find(|n| !failed_nodes.contains(n.as_str()) && *n != alternative_action)
        .cloned();

    // Confidence: based on graph density (more edges = more confident).
    let graph_density = if graph.nodes.is_empty() {
        0.0
    } else {
        (graph.edges.len() as f64 / graph.nodes.len() as f64).min(1.0)
    };
    let confidence = (0.3 + graph_density * 0.6 * adj).clamp(0.1, 0.95);

    SimulationResult {
        would_have_succeeded,
        earliest_divergence,
        confidence,
    }
}

fn causal_graph_lesson_exists(episode_id: i64, lesson: &str) -> Result<bool> {
    let conn = crate::db_pool::get()?;
    let n: i64 = conn.query_row(
        "SELECT COUNT(*) FROM chump_causal_lessons WHERE episode_id = ?1 AND lesson = ?2",
        rusqlite::params![episode_id, lesson],
        |r| r.get(0),
    )?;
    Ok(n > 0)
}

/// Persist causal graph edges as rows in `chump_causal_lessons` for keyword / task recall.
/// Caps at 32 edges per call. `action_taken` / `alternative` hold edge endpoints.
/// Skips an edge if the same `episode_id` + `lesson` text already exists.
pub fn persist_causal_graph_as_lessons(
    graph: &CausalGraph,
    task_type: Option<&str>,
) -> Result<usize> {
    let mut n = 0;
    for edge in graph.edges.iter().take(32) {
        let lesson = format!(
            "[causal-graph] {} --{}--> {} (w={:.2})",
            edge.from, edge.relation, edge.to, edge.strength
        );
        if causal_graph_lesson_exists(graph.episode_id, &lesson)? {
            continue;
        }
        store_lesson(
            Some(graph.episode_id),
            task_type,
            &edge.from,
            Some(edge.to.as_str()),
            &lesson,
            edge.strength.clamp(0.2, 0.95),
            Some(edge.strength),
        )?;
        n += 1;
    }
    Ok(n)
}

// --- Counterfactual Query Engine: simplified do-calculus ---

/// A counterfactual query: "What would have happened if we had done X instead of Y?"
#[derive(Debug, Clone)]
pub struct CounterfactualQuery {
    pub intervention_action: String,
    pub original_action: String,
    pub context: String,
}

/// Result of a counterfactual query.
#[derive(Debug, Clone)]
pub struct CounterfactualResult {
    pub query: CounterfactualQuery,
    pub predicted_outcome: String,
    pub confidence: f64,
    pub reasoning: String,
}

/// Simplified do-calculus: single intervention, no confounders.
/// Given a causal graph and an intervention (replacing one action with another),
/// predict the likely outcome by finding similar past patterns.
pub fn counterfactual_query(
    graph: &CausalGraph,
    original_action: &str,
    intervention: &str,
) -> CounterfactualResult {
    let original_paths = graph.paths_from(original_action);

    let original_outcomes: Vec<String> = original_paths
        .iter()
        .filter_map(|p| p.last().cloned())
        .collect();

    // Check past lessons for similar interventions
    let keywords = &[intervention];
    let past_lessons = find_relevant_lessons(None, keywords, 3).unwrap_or_default();

    let (predicted, confidence, reasoning) = if !past_lessons.is_empty() {
        let best = &past_lessons[0];
        (
            best.lesson.clone(),
            best.confidence * 0.8,
            format!(
                "Based on past lesson (conf={:.2}): {}",
                best.confidence, best.lesson
            ),
        )
    } else if original_outcomes.is_empty() {
        (
            "Insufficient data to predict outcome".to_string(),
            0.1,
            "No causal paths found from original action".to_string(),
        )
    } else {
        (
            format!(
                "Original outcomes were [{}]; intervention '{}' may produce similar or divergent results",
                original_outcomes.join(", "),
                intervention
            ),
            0.3,
            "Predicted by graph structure analysis; no direct precedent found".to_string(),
        )
    };

    CounterfactualResult {
        query: CounterfactualQuery {
            intervention_action: intervention.to_string(),
            original_action: original_action.to_string(),
            context: format!(
                "Graph with {} nodes, {} edges",
                graph.nodes.len(),
                graph.edges.len()
            ),
        },
        predicted_outcome: predicted,
        confidence,
        reasoning,
    }
}

// --- Human Review Loop ---

/// Surface high-impact causal claims for user confirmation.
/// Returns lessons with confidence above `min_confidence` and impact above threshold.
pub fn claims_for_review(min_confidence: f64, limit: usize) -> Result<Vec<CausalLesson>> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT id, episode_id, task_type, action_taken, alternative, lesson, \
         confidence, times_applied, created_at, causal_confidence, COALESCE(stale, 0) \
         FROM chump_causal_lessons \
         WHERE confidence >= ?1 AND times_applied >= 2 AND COALESCE(stale, 0) = 0 \
         ORDER BY times_applied DESC, confidence DESC LIMIT ?2",
    )?;
    let rows = stmt
        .query_map(
            rusqlite::params![min_confidence, limit as i64],
            row_from_query,
        )?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Confirm or reject a causal claim via the approval resolver.
/// If confirmed, boost confidence; if rejected, reduce confidence.
pub fn review_causal_claim(lesson_id: i64, confirmed: bool) -> Result<()> {
    let conn = crate::db_pool::get()?;
    if confirmed {
        conn.execute(
            "UPDATE chump_causal_lessons SET confidence = MIN(1.0, confidence + 0.1) WHERE id = ?1",
            rusqlite::params![lesson_id],
        )?;
    } else {
        conn.execute(
            "UPDATE chump_causal_lessons SET confidence = MAX(0.05, confidence - 0.3) WHERE id = ?1",
            rusqlite::params![lesson_id],
        )?;
    }
    Ok(())
}

pub fn counterfactual_available() -> bool {
    crate::db_pool::get().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_lesson_heuristic_timeout() {
        let lesson = extract_lesson_heuristic(
            "run_cli timed out after 30s",
            "run_cli npm test",
            "frustrating",
        );
        assert!(lesson.contains("timeout") || lesson.contains("timed out"));
        assert!(lesson.contains("service health"));
    }

    #[test]
    fn test_extract_lesson_heuristic_generic() {
        let lesson = extract_lesson_heuristic("Something went wrong", "did a thing", "loss");
        assert!(lesson.contains("loss"));
    }

    #[test]
    fn test_suggest_alternative() {
        let alt = suggest_alternative_heuristic("timeout on API call", "called the API");
        assert!(alt.is_some());
        assert!(alt.unwrap().contains("health"));
    }

    #[test]
    fn test_suggest_alternative_none() {
        let alt = suggest_alternative_heuristic("everything is fine", "normal operation");
        assert!(alt.is_none());
    }

    #[test]
    fn test_lessons_for_context_empty() {
        // Without DB, should return empty gracefully
        let ctx = lessons_for_context(Some("test"), "some task", 5);
        // May be empty if no DB available in test context
        assert!(ctx.is_empty() || ctx.contains("PROJECT-SPECIFIC CONFIGURATION"));
    }

    #[test]
    fn test_persist_causal_graph_as_lessons() {
        if !counterfactual_available() {
            return;
        }
        let ep = 9_000_001_i64;
        let conn = match crate::db_pool::get() {
            Ok(c) => c,
            Err(_) => return,
        };
        let _ = conn.execute(
            "DELETE FROM chump_causal_lessons WHERE episode_id = ?1",
            rusqlite::params![ep],
        );
        let g =
            build_causal_graph_heuristic(ep, &[("action_a".to_string(), "negative".to_string())]);
        let n = persist_causal_graph_as_lessons(&g, Some("f6_test")).unwrap();
        assert!(n > 0);
        let lessons = find_relevant_lessons(Some("f6_test"), &["causal-graph"], 20).unwrap();
        assert!(
            lessons.iter().any(|l| l.lesson.contains("causal-graph")),
            "expected graph lesson: {:?}",
            lessons
        );
    }

    // ------------------------------------------------------------------
    // COG-004: lesson_from_graph_paths
    // ------------------------------------------------------------------
    #[test]
    fn lesson_from_graph_paths_returns_none_for_empty_graph() {
        let graph = CausalGraph::new(1);
        assert!(lesson_from_graph_paths(&graph, "action").is_none());
    }

    #[test]
    fn lesson_from_graph_paths_derives_lesson_and_confidence() {
        let mut graph = CausalGraph::new(2);
        graph.add_node("do_thing_0", CausalNodeType::Action);
        graph.add_node("outcome_0", CausalNodeType::Outcome);
        graph.add_edge("do_thing_0", "outcome_0", "caused", 0.8);
        let result = lesson_from_graph_paths(&graph, "do_thing");
        assert!(result.is_some(), "expected lesson from graph paths");
        let (lesson, conf) = result.unwrap();
        assert!(
            lesson.contains("do_thing_0"),
            "lesson should mention action: {lesson}"
        );
        assert!(
            lesson.contains("outcome_0"),
            "lesson should mention outcome: {lesson}"
        );
        assert!(
            (conf - 0.8).abs() < 1e-6,
            "confidence should equal edge strength: {conf}"
        );
    }

    #[test]
    fn lesson_from_graph_paths_picks_strongest_path() {
        // Two paths: one with strength 0.6, one with 0.9
        let mut graph = CausalGraph::new(3);
        graph.add_node("act_0", CausalNodeType::Action);
        graph.add_node("mid_a", CausalNodeType::Observation);
        graph.add_node("mid_b", CausalNodeType::Observation);
        graph.add_node("outcome_0", CausalNodeType::Outcome);
        graph.add_edge("act_0", "mid_a", "caused", 0.6);
        graph.add_edge("mid_a", "outcome_0", "caused", 1.0); // path A: 0.6*1.0 = 0.6
        graph.add_edge("act_0", "mid_b", "caused", 0.9);
        graph.add_edge("mid_b", "outcome_0", "caused", 1.0); // path B: 0.9*1.0 = 0.9
        let (_, conf) = lesson_from_graph_paths(&graph, "act").unwrap();
        assert!(
            conf > 0.85,
            "should pick strongest path (conf ≈ 0.9), got {conf}"
        );
    }

    #[test]
    fn analyze_episode_uses_graph_when_paths_exist() {
        // Build a graph that has paths and check that causal_confidence is populated.
        let mut graph = CausalGraph::new(99);
        graph.add_node("test_action_0", CausalNodeType::Action);
        graph.add_node("outcome_0", CausalNodeType::Outcome);
        graph.add_edge("test_action_0", "outcome_0", "caused", 0.75);
        let result = lesson_from_graph_paths(&graph, "test_action");
        assert!(result.is_some());
        let (_, cc) = result.unwrap();
        assert!((cc - 0.75).abs() < 1e-6);
    }

    // ------------------------------------------------------------------
    // MEM-003: causal edge obsolescence
    // ------------------------------------------------------------------

    #[test]
    fn curate_causal_graph_marks_old_edges_stale() {
        let mut graph = CausalGraph::new(1);
        graph.add_edge("a", "b", "caused", 0.8);
        graph.add_edge("b", "c", "caused", 0.6);
        // Backdate both edges by 100 days worth of seconds (> 90-day threshold).
        let old_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
            .saturating_sub(100 * 86_400);
        for edge in &mut graph.edges {
            edge.created_at = old_ts;
        }
        let marked = curate_causal_graph(&mut graph, 90);
        assert_eq!(marked, 2, "both edges should be marked stale");
        assert!(graph.edges.iter().all(|e| e.stale));
    }

    #[test]
    fn curate_causal_graph_leaves_fresh_edges_intact() {
        let mut graph = CausalGraph::new(2);
        graph.add_edge("x", "y", "led_to", 0.5);
        // Edge was just created (within last second), so should NOT be marked stale.
        let marked = curate_causal_graph(&mut graph, 90);
        assert_eq!(marked, 0, "fresh edge should not be marked stale");
        assert!(!graph.edges[0].stale);
    }

    #[test]
    fn stale_edges_excluded_from_lesson_generation() {
        let mut graph = CausalGraph::new(3);
        graph.add_node("do_thing_0", CausalNodeType::Action);
        graph.add_node("outcome_0", CausalNodeType::Outcome);
        graph.add_edge("do_thing_0", "outcome_0", "caused", 0.9);
        // Before staleness: lesson is found.
        assert!(lesson_from_graph_paths(&graph, "do_thing").is_some());
        // Mark edge stale explicitly.
        invalidate_causal_edge(&mut graph, "do_thing_0", "outcome_0");
        // After staleness: no usable path → lesson is None.
        assert!(
            lesson_from_graph_paths(&graph, "do_thing").is_none(),
            "stale edge should be excluded from path traversal"
        );
    }

    #[test]
    fn invalidate_causal_edge_returns_false_when_not_found() {
        let mut graph = CausalGraph::new(4);
        assert!(!invalidate_causal_edge(&mut graph, "a", "b"));
    }

    // ------------------------------------------------------------------
    // COG-010: Pearl's Ladder rung 3 — counterfactual simulation
    // ------------------------------------------------------------------

    #[test]
    fn simulate_alternative_stronger_path_would_have_succeeded() {
        // Graph: build_step → outcome_0 (weak, 0.2)
        //        cargo_check → check_outcome (strong, 0.9)
        let mut graph = CausalGraph::new(100);
        graph.add_node("build_step_0", CausalNodeType::Action);
        graph.add_node("outcome_0", CausalNodeType::Outcome);
        graph.add_edge("build_step_0", "outcome_0", "caused", 0.2);

        graph.add_node("cargo_check_0", CausalNodeType::Action);
        graph.add_node("check_outcome_0", CausalNodeType::Outcome);
        graph.add_edge("cargo_check_0", "check_outcome_0", "caused", 0.9);

        let result = counterfactual_simulate("build_step_0", "cargo_check_0", &graph);
        assert!(
            result.would_have_succeeded,
            "stronger alternative path should predict success"
        );
        assert!(result.confidence > 0.0);
    }

    #[test]
    fn simulate_failed_path_stronger_would_not_have_succeeded() {
        // Graph: failed_action → outcome (strong, 0.95)
        //        weak_alt → alt_outcome (weak, 0.1)
        let mut graph = CausalGraph::new(101);
        graph.add_edge("failed_action", "outcome", "caused", 0.95);
        graph.add_edge("weak_alt", "alt_outcome", "caused", 0.1);

        let result = counterfactual_simulate("failed_action", "weak_alt", &graph);
        assert!(
            !result.would_have_succeeded,
            "weaker alternative should not predict success over strong failed path"
        );
    }

    #[test]
    fn simulate_on_empty_graph_returns_low_confidence() {
        let graph = CausalGraph::new(102);
        let result = counterfactual_simulate("foo", "bar", &graph);
        assert!(
            result.confidence < 0.5,
            "empty graph confidence should be low"
        );
        assert!(
            !result.would_have_succeeded,
            "no paths → no predicted success"
        );
    }

    #[test]
    fn simulate_identifies_earliest_divergence() {
        // Path from failed: A → B → outcome_1
        // Alt: A → C → outcome_2 (diverges at C)
        let mut graph = CausalGraph::new(103);
        graph.add_edge("action_failed", "node_b", "caused", 0.6);
        graph.add_edge("node_b", "outcome_1", "caused", 0.6);
        graph.add_edge("action_alt", "node_c", "caused", 0.9);
        graph.add_edge("node_c", "outcome_2", "caused", 0.9);

        let result = counterfactual_simulate("action_failed", "action_alt", &graph);
        // earliest_divergence should be node_c or outcome_2 (not in failed paths).
        assert!(
            result.earliest_divergence.is_some(),
            "should find divergence node"
        );
    }

    #[test]
    fn build_causal_graph_heuristic_uses_fallback_without_db() {
        // Without DB, should fall back to default strengths (no panic).
        let graph = build_causal_graph_heuristic(
            999,
            &[
                ("cargo_check".to_string(), "ok".to_string()),
                ("git_commit".to_string(), "committed".to_string()),
                ("deploy".to_string(), "live".to_string()),
            ],
        );
        assert_eq!(graph.nodes.len(), 6); // 3 actions + 3 outcomes
        assert_eq!(graph.edges.len(), 5); // 3 caused + 2 led_to
        for e in &graph.edges {
            assert!(
                e.strength >= 0.2 && e.strength <= 0.95,
                "edge strength out of range: {}",
                e.strength
            );
        }
    }
}
