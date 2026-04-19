//! Persistence + retrieval for structured reflections (GEPA, COG-006).
//!
//! Two tables (schema lives in `db_pool::init_schema`):
//!
//! - `chump_reflections`: one row per completed task / episode, with the
//!   typed fields from `reflection::Reflection` minus the improvements list
//!   (which is normalized into the next table).
//! - `chump_improvement_targets`: one row per directive, FK to parent
//!   reflection. Indexed on (priority, created_at) so the prompt assembler
//!   can pull the freshest high-priority targets cheaply.
//!
//! The "feedback flywheel" closes here:
//!
//! 1. Autonomy loop completes a task → `save_reflection()` (autonomy_loop.rs)
//! 2. Next task starts → `load_recent_high_priority_targets()` (prompt_assembler)
//! 3. Targets render into the system prompt as a "Lessons" block.
//!
//! Without persistence, `reflection.rs`'s typed analysis was throwaway. With
//! it, the agent gets to read its own postmortems.

#[cfg(test)]
use crate::reflection::{ErrorPattern, OutcomeClass};
use crate::reflection::{ImprovementTarget, Priority, Reflection};
use anyhow::Result;
#[cfg(test)]
use rusqlite::Connection;

#[cfg(not(test))]
fn open_db() -> Result<r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>> {
    crate::db_pool::get()
}

#[cfg(test)]
thread_local! {
    static TEST_DB_ROOT: std::cell::RefCell<Option<std::path::PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn set_test_db_root(path: Option<std::path::PathBuf>) {
    TEST_DB_ROOT.with(|cell| *cell.borrow_mut() = path);
}

#[cfg(test)]
fn open_db() -> Result<Connection> {
    let base = TEST_DB_ROOT
        .with(|cell| cell.borrow().clone())
        .unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        });
    let path = base.join("sessions/chump_memory.db");
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let conn = Connection::open(&path)?;
    // Mirror schema from db_pool::init_schema for isolated tests.
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chump_reflections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_id INTEGER,
            intended_goal TEXT NOT NULL DEFAULT '',
            observed_outcome TEXT NOT NULL DEFAULT '',
            outcome_class TEXT NOT NULL DEFAULT 'failure',
            error_pattern TEXT,
            hypothesis TEXT NOT NULL DEFAULT '',
            surprisal_at_reflect REAL,
            confidence_at_reflect REAL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );
         CREATE TABLE IF NOT EXISTS chump_improvement_targets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            reflection_id INTEGER NOT NULL,
            directive TEXT NOT NULL,
            priority TEXT NOT NULL DEFAULT 'medium',
            scope TEXT,
            actioned_as TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );
         CREATE TABLE IF NOT EXISTS chump_causal_lessons (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_type TEXT,
            action_taken TEXT NOT NULL,
            alternative TEXT,
            lesson TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.5,
            times_applied INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );",
    )?;
    Ok(conn)
}

/// Whether the reflection store is reachable. Mirrors `episode_db::episode_available()`.
pub fn reflection_available() -> bool {
    open_db().is_ok()
}

/// COG-011 gate: whether the "Lessons from prior episodes" block should be
/// injected into assembled prompts. Default on. Set `CHUMP_REFLECTION_INJECTION=0`
/// (also accepts "false" or "off") to run a baseline-prompt A/B without
/// recompiling. The gap test rig flips this flag across 20 tasks to measure
/// whether lesson injection actually improves task success.
pub fn reflection_injection_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_REFLECTION_INJECTION").as_deref(),
        Ok("0") | Ok("false") | Ok("off")
    )
}

// ---------------------------------------------------------------------------
// COG-016: model-tier-aware lessons injection
//
// The n=100 sweep (PRs #80 + #82, results in docs/CONSCIOUSNESS_AB_RESULTS.md)
// established statistically (p<0.05 across 3 fixtures, 10.7× A/A noise floor)
// that injecting the lessons block triggers fake-tool-call emission by mean
// +0.14 percentage points on weak agent models (haiku-4-5). The Llama-3.3-70B
// probe (2026-04-19) showed the failure mode is Anthropic-pretrain-specific;
// Llama doesn't exhibit it. Production should gate injection on agent
// capability + add an explicit anti-hallucination guardrail to the lessons
// content itself.
// ---------------------------------------------------------------------------

/// Coarse capability tier for the agent model the lessons block would be
/// injected into. Used by [`lessons_enabled_for_model`] to gate injection.
///
/// Ordering is meaningful: `Frontier` > `Capable` > `Small` > `Unknown`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ModelTier {
    /// Unrecognized model id — safest default is to NOT inject (avoid
    /// surprising any environment running a model we haven't classified).
    Unknown,
    /// Sub-14B local models (qwen2.5:7b, llama3.2:3b, etc.).
    Small,
    /// 14B-32B local mid-tier models (qwen2.5:14b, gpt-oss:20b).
    Capable,
    /// Frontier-class: claude-haiku-4-5+, sonnet-4-5+, opus-4-5+, gpt-4*,
    /// gemini-1.5-pro+, llama-3.x-70B+.
    Frontier,
}

/// Map a model id (from `OPENAI_MODEL`, the agent backend, etc.) to a coarse
/// capability tier. Returns [`ModelTier::Unknown`] for unrecognized strings.
///
/// Matching is **case-insensitive substring** so it survives provider
/// variations like `claude-haiku-4-5-20251001` and
/// `meta-llama/Llama-3.3-70B-Instruct-Turbo`.
pub fn model_tier(model_id: &str) -> ModelTier {
    let m = model_id.to_lowercase();

    // Frontier: cloud APIs + flagship locals
    let frontier_markers: &[&str] = &[
        "claude-haiku-4",
        "claude-sonnet-4",
        "claude-opus-4",
        "claude-3-5-sonnet",
        "claude-3-5-haiku",
        "claude-3-7",
        "claude-3-haiku",
        "gpt-4",
        "gpt-5",
        "o1",
        "o3",
        "gemini-1.5-pro",
        "gemini-2",
        "llama-3.3-70b",
        "llama-3.1-70b",
        "llama-3.1-405b",
        "qwen2.5-72b",
        "qwen2.5:72b",
    ];
    if frontier_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Frontier;
    }

    // Capable: 14B-32B local mid-tier
    let capable_markers: &[&str] = &[
        "qwen2.5:14b",
        "qwen2.5-14b",
        "qwen3:14b",
        "qwen3-14b",
        "qwen3:32b",
        "qwen3-32b",
        "qwen2.5:32b",
        "qwen2.5-32b",
        "llama-3.1-8b",
        "gpt-oss:20b",
        "gpt-oss-20b",
        "gemini-1.5-flash",
    ];
    if capable_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Capable;
    }

    // Small: sub-14B
    let small_markers: &[&str] = &[
        "llama-3.2-1b",
        "llama-3.2-3b",
        "llama3.2:1b",
        "llama3.2:3b",
        "qwen2.5:7b",
        "qwen2.5-7b",
        "qwen3:8b",
        "qwen3-8b",
        "qwen3:7b",
        "qwen3-7b",
    ];
    if small_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Small;
    }

    ModelTier::Unknown
}

/// Read `CHUMP_LESSONS_MIN_TIER` env var to determine the minimum agent tier
/// at which the lessons block should be injected.
///
/// Accepted values (case-insensitive): `frontier`, `capable`, `small`, `none`.
/// `none` disables tier gating entirely (preserves pre-COG-016 behavior of
/// injecting whenever [`reflection_injection_enabled`] is true).
///
/// **Default: `frontier`** — only models classified as Frontier get the
/// lessons block. Conservative production default per the n=100 sweep
/// evidence.
pub fn min_tier_for_lessons() -> Option<ModelTier> {
    let raw = std::env::var("CHUMP_LESSONS_MIN_TIER").ok();
    let normalized = raw.as_deref().map(|s| s.trim().to_lowercase());
    match normalized.as_deref() {
        Some("none") | Some("off") | Some("disabled") => None,
        Some("small") => Some(ModelTier::Small),
        Some("capable") => Some(ModelTier::Capable),
        Some("frontier") => Some(ModelTier::Frontier),
        Some(_) => Some(ModelTier::Frontier),
        None => Some(ModelTier::Frontier),
    }
}

/// Resolve the agent model id from environment. Tries `CHUMP_AGENT_MODEL`
/// first (explicit chump-side override), then `OPENAI_MODEL` (the standard
/// OpenAI-compat backend env var).
pub fn current_agent_model() -> String {
    std::env::var("CHUMP_AGENT_MODEL")
        .or_else(|_| std::env::var("OPENAI_MODEL"))
        .unwrap_or_default()
}

/// COG-016 unified gate: should the lessons block be injected for the
/// current agent model?
///
/// Combines (a) the [`reflection_injection_enabled`] kill-switch with (b) the
/// [`min_tier_for_lessons`] capability gate. Both must allow injection for
/// this to return true. `Unknown` model tiers are NEVER injected (safer
/// default — don't surprise an unknown environment with extra prompt content).
pub fn lessons_enabled_for_model(model_id: &str) -> bool {
    if !reflection_injection_enabled() {
        return false;
    }
    let min = match min_tier_for_lessons() {
        None => return true, // tier gating disabled — preserve legacy behavior
        Some(t) => t,
    };
    let tier = model_tier(model_id);
    if tier == ModelTier::Unknown {
        return false;
    }
    tier >= min
}

/// COG-011d variant (b): when ON, only inject lessons whose `scope` exactly
/// matches the current `tool_hint`. Excludes the universal (NULL-scope)
/// lessons that get returned by default. Tests the hypothesis that
/// "irrelevant lessons act as noise" — if true, strict-scope mode should
/// recover some of the -0.30 gotcha penalty seen in COG-011b.
///
/// Default OFF (current behavior — universal lessons surface for every prompt).
pub fn reflection_strict_scope_enabled() -> bool {
    matches!(
        std::env::var("CHUMP_REFLECTION_STRICT_SCOPE").as_deref(),
        Ok("1") | Ok("true") | Ok("on")
    )
}

/// Persist a Reflection plus its improvement targets in a single transaction.
/// Returns the new reflection_id. On any error, the whole insert rolls back.
pub fn save_reflection(reflection: &Reflection, task_id: Option<i64>) -> Result<i64> {
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO chump_reflections (
            episode_id, task_id, intended_goal, observed_outcome,
            outcome_class, error_pattern, hypothesis,
            surprisal_at_reflect, confidence_at_reflect
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![
            reflection.episode_id,
            task_id,
            reflection.intended_goal,
            reflection.observed_outcome,
            reflection.outcome_class.as_str(),
            reflection.error_pattern.map(|p| p.as_str()),
            reflection.hypothesis,
            reflection.surprisal_at_reflect,
            reflection.confidence_at_reflect,
        ],
    )?;
    let reflection_id = tx.last_insert_rowid();
    for target in &reflection.improvements {
        tx.execute(
            "INSERT INTO chump_improvement_targets (
                reflection_id, directive, priority, scope, actioned_as
             ) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                reflection_id,
                target.directive,
                target.priority.as_str(),
                target.scope,
                target.actioned_as,
            ],
        )?;
    }
    tx.commit()?;
    Ok(reflection_id)
}

/// Load the most-recent high+medium priority improvement targets, capped at `limit`.
///
/// `scope_filter`:
///   - `Some(scope)` + `CHUMP_REFLECTION_STRICT_SCOPE=1` → exact scope matches only
///     (no NULL-scope universal lessons). The COG-011d variant (b) test path.
///   - `Some(scope)` + default → exact match OR NULL/empty scope (universal lessons
///     ride along). Original COG-007 behavior.
///   - `None` + `CHUMP_REFLECTION_STRICT_SCOPE=1` → return empty (no signal to
///     filter on, strict mode refuses to inject noise).
///   - `None` + default → all high+medium-priority targets regardless of scope.
///
/// Order: priority DESC (high → medium), then created_at DESC (freshest wins).
/// Low-priority targets are never returned — they exist for analytics only.
pub fn load_recent_high_priority_targets(
    limit: usize,
    scope_filter: Option<&str>,
) -> Result<Vec<ImprovementTarget>> {
    let conn = open_db()?;
    let limit = limit.min(20);
    let strict = reflection_strict_scope_enabled();

    let rows: Vec<ImprovementTarget> = match (scope_filter, strict) {
        (Some(scope), true) => {
            // Strict: exact scope match only. No NULL/empty scope catch-all.
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND scope = ?1
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?2";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![scope, limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
        (Some(scope), false) => {
            // Default: exact scope match OR NULL/empty (universal).
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND (scope IS NULL OR scope = '' OR scope = ?1)
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?2";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![scope, limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
        (None, true) => {
            // Strict + no signal → return empty. Caller's lesson block stays empty,
            // matching the COG-011b "lessons hurt when injected indiscriminately" finding.
            Vec::new()
        }
        (None, false) => {
            // No filter: all high/medium targets.
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?1";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
    };
    Ok(rows)
}

fn row_from_target(r: &rusqlite::Row) -> Result<ImprovementTarget, rusqlite::Error> {
    let priority_str: String = r.get(1)?;
    let priority = match priority_str.as_str() {
        "high" => Priority::High,
        "low" => Priority::Low,
        _ => Priority::Medium,
    };
    Ok(ImprovementTarget {
        directive: r.get(0)?,
        priority,
        scope: r.get::<_, Option<String>>(2)?.filter(|s| !s.is_empty()),
        actioned_as: r.get::<_, Option<String>>(3)?.filter(|s| !s.is_empty()),
    })
}

/// Render a list of improvement targets as a system-prompt block. Returns
/// empty string when input is empty so callers can `if !block.is_empty()` cheaply.
///
/// Format chosen for low-distraction injection: short header, bullet list,
/// priority and scope inlined when present. Designed to be appended to the
/// existing system prompt, not to replace any task-planner block.
pub fn format_lessons_block(targets: &[ImprovementTarget]) -> String {
    if targets.is_empty() {
        return String::new();
    }
    // COG-016: explicit anti-hallucination guardrail prepended to the lessons
    // header. The n=100 sweep showed the original block (without this line)
    // reliably increased fake-tool-call emission by +0.14 on weak agents
    // (haiku-4-5, n=600 trials, p<0.05 across 3 fixtures). The directive
    // tells the model NOT to emit fake tool-call markup when it has no
    // actual tool access — addressing the failure mode observed in the
    // forensic in docs/CONSCIOUSNESS_AB_RESULTS.md.
    let mut out = String::from(
        "## Lessons from prior episodes\n\
         The following directives came from structured reflections on previous tasks. \
         Apply them when relevant; do not narrate that you are applying them.\n\
         \n\
         IMPORTANT: if you do not have actual tool access in this context, do NOT \
         emit `<function_calls>`, `<tool_call>`, `<tool_use>`, or similar markup. \
         Instead, describe in plain prose what you would do if tools were available, \
         and acknowledge that you cannot execute commands directly.\n",
    );
    for t in targets {
        let scope = match &t.scope {
            Some(s) if !s.is_empty() => format!(" [{}]", s),
            _ => String::new(),
        };
        out.push_str(&format!(
            "- ({}){} {}\n",
            t.priority.as_str(),
            scope,
            t.directive
        ));
    }
    out
}

// ---------------------------------------------------------------------------
// COG-014: AB harness lesson seeding
// ---------------------------------------------------------------------------

/// A single authored directive for AB harness seeding.
#[derive(Debug, serde::Deserialize)]
pub struct SeedDirective {
    pub directive: String,
    /// "high" | "medium" | "low"
    pub priority: String,
    pub scope: Option<String>,
}

/// JSON structure for a domain lesson seed file.
#[derive(Debug, serde::Deserialize)]
pub struct LessonSeedFile {
    pub domain: String,
    pub directives: Vec<SeedDirective>,
}

/// Tag written to `error_pattern` for AB-seeded reflections so they can be
/// deleted cleanly without touching real reflections.
const AB_SEED_TAG_PREFIX: &str = "ab_seed:";

/// Remove all AB-seeded reflections and their associated improvement targets,
/// and also remove causal lessons seeded for AB testing.
/// Returns the number of rows deleted from `chump_reflections`.
///
/// Explicitly deletes from `chump_improvement_targets` first because SQLite
/// FK enforcement (`PRAGMA foreign_keys`) is off by default, so `ON DELETE
/// CASCADE` does not fire automatically.
pub fn clear_ab_seed_lessons() -> Result<usize> {
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    // Delete orphaned targets first — FK cascade may not be active.
    tx.execute(
        "DELETE FROM chump_improvement_targets \
         WHERE reflection_id IN ( \
             SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%' \
         )",
        [],
    )?;
    let deleted = tx.execute(
        "DELETE FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'",
        [],
    )?;
    // Also clear causal lessons seeded for AB testing (task_type = 'ab_seed').
    tx.execute(
        "DELETE FROM chump_causal_lessons WHERE task_type = 'ab_seed'",
        [],
    )?;
    tx.commit()?;
    Ok(deleted)
}

/// Seed domain-specific lessons into `chump_reflections` + `chump_improvement_targets`
/// AND into `chump_causal_lessons` for use by the A/B harness.
///
/// The improvement-targets path is gated only by reflection injection (not consciousness).
/// The causal-lessons path (`task_type = 'ab_seed'`) is the consciousness-gated path
/// used by `find_relevant_lessons` as a fallback when keyword matching returns nothing.
/// Creates a single parent reflection tagged with `error_pattern = 'ab_seed:<domain>'`
/// so it can be cleared later.
///
/// Returns the number of directives inserted.
pub fn seed_ab_lessons(domain: &str, directives: &[SeedDirective]) -> Result<usize> {
    if directives.is_empty() {
        return Ok(0);
    }
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO chump_reflections (
            intended_goal, observed_outcome, outcome_class, error_pattern, hypothesis
         ) VALUES (?1, 'seeded', 'ab_seed', ?2, ?3)",
        rusqlite::params![
            format!("AB harness seed — {domain}"),
            format!("{AB_SEED_TAG_PREFIX}{domain}"),
            format!("Task-specific lessons for {domain} domain A/B testing"),
        ],
    )?;
    let reflection_id = tx.last_insert_rowid();

    let mut count = 0usize;
    for d in directives {
        tx.execute(
            "INSERT INTO chump_improvement_targets (reflection_id, directive, priority, scope)
             VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![reflection_id, d.directive, d.priority, d.scope],
        )?;
        // Also seed into chump_causal_lessons so the consciousness-gated
        // lessons_for_context_with_ids() path can find them via the ab_seed fallback.
        tx.execute(
            "INSERT INTO chump_causal_lessons (task_type, action_taken, lesson, confidence)
             VALUES ('ab_seed', ?1, ?2, 0.95)",
            rusqlite::params![d.scope.as_deref().unwrap_or(""), d.directive],
        )?;
        count += 1;
    }
    tx.commit()?;
    Ok(count)
}

/// Load a [`LessonSeedFile`] from a JSON path and seed it into the DB.
/// Convenience wrapper used by the `--seed-ab-lessons` CLI.
pub fn seed_ab_lessons_from_file(path: &std::path::Path) -> Result<usize> {
    let content = std::fs::read_to_string(path)?;
    let seed: LessonSeedFile = serde_json::from_str(&content)?;
    seed_ab_lessons(&seed.domain, &seed.directives)
}

#[cfg(test)]
mod tests {
    //! Tests use a temp DB root so they never touch the user's real chump_memory.db.
    //! `serial(reflection_db)` because all tests share the same TEST_DB_ROOT
    //! thread-local — running them in parallel would interleave inserts.

    use super::*;
    use serial_test::serial;

    /// Per-test fresh DB root. Uses uuid like episode_db tests so concurrent
    /// runs (or repeated runs after failure) never collide.
    fn fresh_test_root() {
        let dir = std::env::temp_dir().join(format!(
            "chump_reflection_db_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        set_test_db_root(Some(dir));
    }

    fn sample_reflection(directive: &str, priority: Priority, scope: Option<&str>) -> Reflection {
        Reflection {
            id: None,
            episode_id: None,
            intended_goal: "test goal".into(),
            observed_outcome: "test outcome".into(),
            outcome_class: OutcomeClass::Failure,
            error_pattern: Some(ErrorPattern::ToolMisuse),
            improvements: vec![ImprovementTarget {
                directive: directive.into(),
                priority,
                scope: scope.map(String::from),
                actioned_as: None,
            }],
            hypothesis: "test hypothesis".into(),
            surprisal_at_reflect: Some(0.5),
            confidence_at_reflect: Some(0.7),
            created_at: "2026-04-17T00:00:00Z".into(),
        }
    }

    #[test]
    #[serial(reflection_db)]
    fn save_then_load_returns_high_priority_first() {
        fresh_test_root();
        let mut low = sample_reflection("low priority lesson", Priority::Low, None);
        // Tag a low-priority target — it must NOT appear in load.
        low.improvements[0].priority = Priority::Low;
        save_reflection(&low, Some(1)).unwrap();

        let med = sample_reflection("medium lesson", Priority::Medium, None);
        save_reflection(&med, Some(2)).unwrap();

        let high = sample_reflection("HIGH urgency lesson", Priority::High, None);
        save_reflection(&high, Some(3)).unwrap();

        let targets = load_recent_high_priority_targets(10, None).unwrap();
        assert_eq!(targets.len(), 2, "low-priority must be filtered out");
        assert_eq!(targets[0].directive, "HIGH urgency lesson");
        assert_eq!(targets[0].priority, Priority::High);
        assert_eq!(targets[1].directive, "medium lesson");
    }

    #[test]
    #[serial(reflection_db)]
    fn scope_filter_includes_null_scope_targets() {
        fresh_test_root();
        // Universal lesson (no scope) — must always surface.
        save_reflection(
            &sample_reflection("universal lesson", Priority::High, None),
            None,
        )
        .unwrap();
        // Tool-scoped lesson — surfaces only when scope matches.
        save_reflection(
            &sample_reflection("patch-specific lesson", Priority::High, Some("patch_file")),
            None,
        )
        .unwrap();
        // Different-tool lesson — must NOT surface for patch_file scope.
        save_reflection(
            &sample_reflection("git-specific lesson", Priority::High, Some("git_commit")),
            None,
        )
        .unwrap();

        let targets = load_recent_high_priority_targets(10, Some("patch_file")).unwrap();
        let directives: Vec<_> = targets.iter().map(|t| t.directive.as_str()).collect();
        assert!(directives.contains(&"universal lesson"));
        assert!(directives.contains(&"patch-specific lesson"));
        assert!(
            !directives.contains(&"git-specific lesson"),
            "scope filter must exclude other tools' lessons"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn save_persists_all_typed_fields_roundtrip() {
        fresh_test_root();
        let r = sample_reflection(
            "verify file exists before patch",
            Priority::High,
            Some("patch_file"),
        );
        let id = save_reflection(&r, Some(42)).unwrap();
        assert!(id > 0);

        let targets = load_recent_high_priority_targets(10, None).unwrap();
        assert_eq!(targets.len(), 1);
        let t = &targets[0];
        assert_eq!(t.directive, "verify file exists before patch");
        assert_eq!(t.priority, Priority::High);
        assert_eq!(t.scope.as_deref(), Some("patch_file"));
    }

    #[test]
    #[serial(reflection_db)]
    fn load_with_no_data_returns_empty() {
        fresh_test_root();
        let targets = load_recent_high_priority_targets(10, None).unwrap();
        assert!(targets.is_empty());
    }

    #[test]
    #[serial(reflection_db)]
    fn limit_respected() {
        fresh_test_root();
        for i in 0..5 {
            save_reflection(
                &sample_reflection(&format!("lesson {}", i), Priority::High, None),
                None,
            )
            .unwrap();
        }
        let targets = load_recent_high_priority_targets(3, None).unwrap();
        assert_eq!(targets.len(), 3);
    }

    #[test]
    #[serial(reflection_db)]
    fn reflection_injection_default_on() {
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        assert!(reflection_injection_enabled());
    }

    #[test]
    #[serial(reflection_db)]
    fn reflection_injection_off_via_env() {
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "0");
        assert!(!reflection_injection_enabled());
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "false");
        assert!(!reflection_injection_enabled());
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "off");
        assert!(!reflection_injection_enabled());
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
    }

    // ── COG-011d variant (b): strict-scope mode ──────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_default_off() {
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
        assert!(!reflection_strict_scope_enabled());
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_on_via_env() {
        for v in ["1", "true", "on"] {
            std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", v);
            assert!(reflection_strict_scope_enabled(), "expected on for {v}");
        }
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_excludes_universal_lessons() {
        // Default (non-strict) returns BOTH a NULL-scope lesson and a
        // patch_file-scoped one when filter is "patch_file". Strict mode
        // returns ONLY the exact match.
        fresh_test_root();
        save_reflection(
            &sample_reflection("universal directive", Priority::High, None),
            None,
        )
        .unwrap();
        save_reflection(
            &sample_reflection(
                "patch-specific directive",
                Priority::High,
                Some("patch_file"),
            ),
            None,
        )
        .unwrap();
        save_reflection(
            &sample_reflection("git-specific directive", Priority::High, Some("git_commit")),
            None,
        )
        .unwrap();

        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
        let lax = load_recent_high_priority_targets(10, Some("patch_file")).unwrap();
        let lax_directives: Vec<_> = lax.iter().map(|t| t.directive.as_str()).collect();
        assert!(lax_directives.contains(&"universal directive"));
        assert!(lax_directives.contains(&"patch-specific directive"));
        assert!(!lax_directives.contains(&"git-specific directive"));

        std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", "1");
        let strict = load_recent_high_priority_targets(10, Some("patch_file")).unwrap();
        let strict_directives: Vec<_> = strict.iter().map(|t| t.directive.as_str()).collect();
        assert_eq!(
            strict_directives,
            vec!["patch-specific directive"],
            "strict mode must exclude universal AND off-scope lessons"
        );
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_with_no_filter_returns_empty() {
        // Strict mode + no scope hint → nothing to filter on, so refuse to
        // inject. The "noise reduction" hypothesis behind COG-011d (b).
        fresh_test_root();
        save_reflection(&sample_reflection("any lesson", Priority::High, None), None).unwrap();
        save_reflection(
            &sample_reflection("scoped lesson", Priority::High, Some("patch_file")),
            None,
        )
        .unwrap();

        std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", "1");
        let targets = load_recent_high_priority_targets(10, None).unwrap();
        assert!(
            targets.is_empty(),
            "strict mode + None filter should return []"
        );
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn format_lessons_block_empty_returns_empty_string() {
        // Pure function — no DB needed. Cheap regression guard so the
        // assembler can `if !block.is_empty()` without surprise newlines.
        let s = format_lessons_block(&[]);
        assert!(s.is_empty());
    }

    // ── COG-014: AB seed helpers ────────────��─────────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn seed_ab_lessons_inserts_and_clears() {
        fresh_test_root();
        let directives = vec![
            SeedDirective {
                directive: "entity lesson one".into(),
                priority: "high".into(),
                scope: Some("perception".into()),
            },
            SeedDirective {
                directive: "entity lesson two".into(),
                priority: "medium".into(),
                scope: Some("perception".into()),
            },
        ];
        let count = seed_ab_lessons("perception", &directives).unwrap();
        assert_eq!(count, 2);

        // Seeded rows land in chump_improvement_targets, but are intentionally
        // excluded from the prompt-assembly path — load_recent_high_priority_targets
        // filters out reflection_ids tagged `ab_seed:*`.  Verify presence via a
        // direct count rather than going through the prompt-assembly query.
        {
            let conn = open_db().unwrap();
            let it_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM chump_improvement_targets WHERE scope = 'perception'",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(
                it_count, 2,
                "two directives stored in chump_improvement_targets"
            );

            // The consciousness-gated path (chump_causal_lessons) also gets them.
            let cl_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM chump_causal_lessons WHERE task_type = 'ab_seed'",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(cl_count, 2, "two lessons stored in chump_causal_lessons");
        }
        // Confirm ab_seed rows do NOT bleed through to prompt assembly.
        let visible = load_recent_high_priority_targets(10, Some("perception")).unwrap();
        assert!(
            visible.is_empty(),
            "ab_seed rows must be excluded from prompt-assembly path"
        );

        // Clearing removes them without touching other data.
        let deleted = clear_ab_seed_lessons().unwrap();
        assert_eq!(deleted, 1, "one parent reflection row deleted");

        let after = load_recent_high_priority_targets(10, None).unwrap();
        assert!(after.is_empty(), "all seeded targets gone after clear");
    }

    #[test]
    #[serial(reflection_db)]
    fn seed_ab_lessons_empty_slice_is_noop() {
        fresh_test_root();
        let count = seed_ab_lessons("perception", &[]).unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    #[serial(reflection_db)]
    fn clear_ab_seed_lessons_zero_when_nothing_seeded() {
        fresh_test_root();
        let deleted = clear_ab_seed_lessons().unwrap();
        assert_eq!(deleted, 0);
    }

    #[test]
    #[serial(reflection_db)]
    fn clear_does_not_remove_real_reflections() {
        fresh_test_root();
        // Save a real reflection.
        save_reflection(
            &sample_reflection("real lesson", Priority::High, None),
            None,
        )
        .unwrap();
        // Seed an AB lesson.
        seed_ab_lessons(
            "neuromod",
            &[SeedDirective {
                directive: "calibrate confidence".into(),
                priority: "high".into(),
                scope: Some("neuromod".into()),
            }],
        )
        .unwrap();

        // Clearing removes only the seeded one.
        let deleted = clear_ab_seed_lessons().unwrap();
        assert_eq!(deleted, 1);

        let remaining = load_recent_high_priority_targets(10, None).unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].directive, "real lesson");
    }

    #[test]
    #[serial(reflection_db)]
    fn format_lessons_block_renders_priority_and_scope() {
        let targets = vec![
            ImprovementTarget {
                directive: "verify before patch".into(),
                priority: Priority::High,
                scope: Some("patch_file".into()),
                actioned_as: None,
            },
            ImprovementTarget {
                directive: "ask clarifying questions when ambiguous".into(),
                priority: Priority::Medium,
                scope: None,
                actioned_as: None,
            },
        ];
        let s = format_lessons_block(&targets);
        assert!(s.contains("## Lessons from prior episodes"));
        assert!(s.contains("(high) [patch_file] verify before patch"));
        assert!(s.contains("(medium) ask clarifying questions"));
    }

    // ── COG-016: model-tier-aware lessons injection ──────────────────────

    #[test]
    fn model_tier_classifies_frontier_correctly() {
        for m in &[
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-sonnet-4-5",
            "claude-opus-4-5",
            "claude-3-5-sonnet-20241022",
            "claude-3-5-haiku-20241022",
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-5",
            "o1-preview",
            "o3-mini",
            "gemini-1.5-pro",
            "gemini-2.0-flash",
            "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo",
            "meta-llama/Meta-Llama-3.1-405B-Instruct",
        ] {
            assert_eq!(
                model_tier(m),
                ModelTier::Frontier,
                "expected Frontier for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_classifies_capable_correctly() {
        for m in &[
            "qwen2.5:14b",
            "ollama:qwen2.5-14b",
            "qwen3:14b",
            "qwen3:32b",
            "qwen2.5:32b",
            "gpt-oss:20b",
            "gemini-1.5-flash",
            "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo",
        ] {
            assert_eq!(
                model_tier(m),
                ModelTier::Capable,
                "expected Capable for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_classifies_small_correctly() {
        for m in &[
            "llama3.2:1b",
            "llama3.2:3b",
            "qwen2.5:7b",
            "qwen3:8b",
            "qwen3:7b",
        ] {
            assert_eq!(model_tier(m), ModelTier::Small, "expected Small for {}", m);
        }
    }

    #[test]
    fn model_tier_unknown_for_unrecognized() {
        for m in &["", "foo-bar-baz", "mistral-7b", "phi-3-mini"] {
            assert_eq!(
                model_tier(m),
                ModelTier::Unknown,
                "expected Unknown for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_ord_is_correct() {
        // Used by lessons_enabled_for_model: tier >= min_tier check.
        assert!(ModelTier::Frontier > ModelTier::Capable);
        assert!(ModelTier::Capable > ModelTier::Small);
        assert!(ModelTier::Small > ModelTier::Unknown);
        // The full chain
        assert!(ModelTier::Frontier > ModelTier::Unknown);
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_default_is_frontier() {
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Frontier));
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_none_disables_gating() {
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "none");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "off");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "disabled");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_explicit_values_parse() {
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "small");
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Small));
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Capable));
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "FRONTIER"); // case insensitive
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Frontier));
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_default_frontier_only() {
        // Default (CHUMP_LESSONS_MIN_TIER unset) = Frontier only.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");

        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(lessons_enabled_for_model("gpt-4o"));
        assert!(!lessons_enabled_for_model("qwen2.5:14b")); // Capable < Frontier
        assert!(!lessons_enabled_for_model("qwen2.5:7b")); // Small < Frontier
        assert!(!lessons_enabled_for_model("foo-unknown")); // Unknown
        assert!(!lessons_enabled_for_model("")); // empty
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_capable_min() {
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");

        assert!(lessons_enabled_for_model("claude-haiku-4-5")); // Frontier >= Capable
        assert!(lessons_enabled_for_model("qwen2.5:14b")); // Capable >= Capable
        assert!(!lessons_enabled_for_model("qwen2.5:7b")); // Small < Capable
        assert!(!lessons_enabled_for_model("foo-unknown")); // Unknown still off

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_none_preserves_legacy() {
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "none");

        // With tier gating off, only the COG-011 reflection_injection_enabled
        // kill-switch matters — and that defaults on.
        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(lessons_enabled_for_model("qwen2.5:7b"));
        assert!(lessons_enabled_for_model("foo-unknown")); // even unknown!

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_kill_switch_still_works() {
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "0");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "none");

        // Kill-switch wins over everything.
        assert!(!lessons_enabled_for_model("claude-haiku-4-5"));

        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    fn format_lessons_block_includes_anti_hallucination_directive() {
        let targets = vec![ImprovementTarget {
            directive: "do the thing".to_string(),
            priority: Priority::High,
            scope: None,
            actioned_as: None,
        }];
        let s = format_lessons_block(&targets);
        // The COG-016 anti-hallucination guardrail must appear in every
        // emitted block — it's the literal text that addresses the
        // documented hallucination failure mode.
        assert!(
            s.contains("do NOT") && s.contains("function_calls"),
            "block must contain anti-hallucination directive, got: {}",
            s
        );
    }
}
