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
    pub times_applied: i64,
    pub created_at: String,
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
    })
}

/// Store a new causal lesson extracted from an episode.
pub fn store_lesson(
    episode_id: Option<i64>,
    task_type: Option<&str>,
    action_taken: &str,
    alternative: Option<&str>,
    lesson: &str,
    confidence: f64,
) -> Result<i64> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_causal_lessons \
         (episode_id, task_type, action_taken, alternative, lesson, confidence) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params![
            episode_id,
            task_type.unwrap_or(""),
            action_taken,
            alternative.unwrap_or(""),
            lesson,
            confidence,
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
             confidence, times_applied, created_at \
             FROM chump_causal_lessons WHERE task_type = ?1 \
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
             confidence, times_applied, created_at \
             FROM chump_causal_lessons WHERE lesson LIKE ?1 OR action_taken LIKE ?1 \
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

/// Analyze an episode for counterfactual reasoning.
///
/// Given an episode summary, action taken, and outcome sentiment, this function
/// determines whether counterfactual analysis is warranted and generates a
/// structured analysis. Returns a causal lesson if the episode was a failure
/// or frustration.
///
/// This is the heuristic/deterministic path. A future iteration can use the LLM
/// for richer counterfactual analysis.
pub fn analyze_episode(
    episode_id: i64,
    summary: &str,
    action_taken: Option<&str>,
    sentiment: Option<&str>,
    tags: Option<&str>,
) -> Result<Option<CausalLesson>> {
    let sentiment = sentiment.unwrap_or("neutral");

    // Only generate lessons from failures and frustrations
    if !matches!(sentiment, "loss" | "frustrating" | "uncertain") {
        return Ok(None);
    }

    let action = action_taken.unwrap_or("(not recorded)");

    // Extract task type from tags
    let task_type = tags
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .find(|t| !t.is_empty())
        .map(|s| s.to_string());

    // Heuristic lesson extraction based on common failure patterns
    let lesson = extract_lesson_heuristic(summary, action, sentiment);
    let alternative = suggest_alternative_heuristic(summary, action);

    let confidence = match sentiment {
        "loss" => 0.7,
        "frustrating" => 0.6,
        "uncertain" => 0.4,
        _ => 0.3,
    };

    let id = store_lesson(
        Some(episode_id),
        task_type.as_deref(),
        action,
        alternative.as_deref(),
        &lesson,
        confidence,
    )?;

    // Post to blackboard for immediate visibility
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
        times_applied: 0,
        created_at: String::new(),
    }))
}

fn extract_lesson_heuristic(summary: &str, action: &str, sentiment: &str) -> String {
    let lower = summary.to_lowercase();
    let action_lower = action.to_lowercase();

    let patterns: &[(&str, &str)] = &[
        ("timed out", "Tool timed out; consider increasing timeout or checking service health before calling"),
        ("timeout", "Tool timed out; consider increasing timeout or checking service health before calling"),
        ("rate limit", "Hit rate limit; add backoff/retry or use alternative provider"),
        ("permission", "Permission denied; verify credentials and access before attempting"),
        ("not found", "Resource not found; verify paths/URLs exist before operating on them"),
        ("parse", "Parse error; validate input format before processing"),
        ("compile", "Compilation failed; run check/clippy before committing changes"),
        ("test fail", "Tests failed; run tests locally before marking task done"),
        ("merge conflict", "Merge conflict; pull latest changes before starting work"),
        ("context", "Context issue; ensure sufficient context is loaded before reasoning"),
        ("memory", "Memory-related issue; check if relevant memories were recalled"),
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
        ("timeout", "Pre-check service health; use circuit breaker; try alternative tool"),
        ("rate limit", "Switch to fallback provider; add exponential backoff"),
        ("permission", "Verify credentials first; request access before attempting"),
        ("not found", "Search for resource first; confirm existence before operating"),
        ("compile", "Run cargo check before committing; fix incrementally"),
        ("test fail", "Run targeted tests first; fix one test at a time"),
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

    let lessons = match find_relevant_lessons(task_type, &keywords, max_lessons) {
        Ok(l) => l,
        Err(_) => return (String::new(), Vec::new()),
    };

    if lessons.is_empty() {
        return (String::new(), Vec::new());
    }

    let ids: Vec<i64> = lessons.iter().map(|l| l.id).collect();
    let mut out = String::from("Causal lessons from past episodes:\n");
    for (i, lesson) in lessons.iter().enumerate() {
        out.push_str(&format!(
            "  {}. [conf={:.1}] {}\n",
            i + 1,
            lesson.confidence,
            lesson.lesson
        ));
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
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64
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
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM chump_causal_lessons",
        [],
        |r| r.get(0),
    )?;
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

pub fn counterfactual_available() -> bool {
    crate::db_pool::get().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_lesson_heuristic_timeout() {
        let lesson = extract_lesson_heuristic("run_cli timed out after 30s", "run_cli npm test", "frustrating");
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
        assert!(ctx.is_empty() || ctx.contains("Causal lessons"));
    }
}
