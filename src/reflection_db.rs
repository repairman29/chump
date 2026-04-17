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
         );",
    )?;
    Ok(conn)
}

/// Whether the reflection store is reachable. Mirrors `episode_db::episode_available()`.
pub fn reflection_available() -> bool {
    open_db().is_ok()
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
/// `scope_filter`: when Some, prefer targets whose `scope` matches OR is NULL.
/// NULL scopes are universally applicable (no tool/subsystem tag) so we keep them.
/// When None, return without scope filtering.
///
/// Order: priority DESC (high → medium), then created_at DESC (freshest wins).
/// Low-priority targets are never returned — they exist for analytics only.
pub fn load_recent_high_priority_targets(
    limit: usize,
    scope_filter: Option<&str>,
) -> Result<Vec<ImprovementTarget>> {
    let conn = open_db()?;
    let limit = limit.min(20);
    // Sort: high before medium, then newest first. Scope match (or NULL) when filter given.
    let (sql, rows): (String, Vec<ImprovementTarget>) = if let Some(scope) = scope_filter {
        let q = "SELECT directive, priority, scope, actioned_as
                 FROM chump_improvement_targets
                 WHERE priority IN ('high', 'medium')
                   AND (scope IS NULL OR scope = '' OR scope = ?1)
                 ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                          created_at DESC
                 LIMIT ?2";
        let mut stmt = conn.prepare(q)?;
        let iter = stmt.query_map(rusqlite::params![scope, limit as i64], row_from_target)?;
        let mut out = Vec::new();
        for r in iter {
            out.push(r?);
        }
        (q.to_string(), out)
    } else {
        let q = "SELECT directive, priority, scope, actioned_as
                 FROM chump_improvement_targets
                 WHERE priority IN ('high', 'medium')
                 ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                          created_at DESC
                 LIMIT ?1";
        let mut stmt = conn.prepare(q)?;
        let iter = stmt.query_map(rusqlite::params![limit as i64], row_from_target)?;
        let mut out = Vec::new();
        for r in iter {
            out.push(r?);
        }
        (q.to_string(), out)
    };
    let _ = sql; // future: tracing::trace
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
    let mut out = String::from(
        "## Lessons from prior episodes\n\
         The following directives came from structured reflections on previous tasks. \
         Apply them when relevant; do not narrate that you are applying them.\n",
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
    fn format_lessons_block_empty_returns_empty_string() {
        // Pure function — no DB needed. Cheap regression guard so the
        // assembler can `if !block.is_empty()` without surprise newlines.
        let s = format_lessons_block(&[]);
        assert!(s.is_empty());
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
}
