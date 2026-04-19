//! Per-dispatch reflection writes — AUTO-013 MVP step 4.
//!
//! Every terminal `DispatchOutcome` from the [`crate::monitor::MonitorLoop`]
//! produces one [`DispatchReflection`] row that flows into the same
//! `chump_reflections` + `chump_improvement_targets` tables PRODUCT-006
//! reads from. The rows are tagged with `error_pattern =
//! 'orchestrator_dispatch'` so the synthesis layer can filter them out from
//! task-level reflections and treat them as a separate signal class.
//!
//! Writers are behind a trait so unit/integration tests can capture rows in
//! memory without needing a temp SQLite DB; the production
//! [`SqliteReflectionWriter`] writes to `<repo_root>/sessions/chump_memory.db`
//! using the same schema as `src/reflection_db.rs` (kept in sync —
//! bin schema is derived from the workspace canonical schema in
//! `src/db_pool.rs`).

use crate::monitor::DispatchOutcome;
use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// One dispatch outcome ready to be written. Built by
/// [`crate::monitor::MonitorLoop::record_reflection`] from a
/// [`crate::monitor::WatchEntry`] + the terminal outcome.
#[derive(Debug, Clone)]
pub struct DispatchReflection {
    pub gap_id: String,
    /// Original gap effort (`"s"` / `"m"` / `"l"` / `"xl"`).
    pub effort: String,
    /// Coarse domain prefix from the gap id (`"auto"`, `"eval"`, `"product"`,
    /// `"infra"`, …). Used by the synthesis layer to bucket lessons.
    pub gap_domain: String,
    /// One of `"shipped"`, `"ci_failed"`, `"stalled"`, `"killed"`.
    pub outcome: String,
    pub duration_s: u64,
    /// Other dispatched siblings still in flight when this one terminated.
    pub parallel_siblings: usize,
    pub pr_number: Option<u32>,
    /// Best-effort tail of WARN/ERROR/FAIL/PANIC lines from the subagent's
    /// stderr. Empty when no buffer was attached (e.g. test spawners).
    pub notes: String,
}

impl DispatchReflection {
    /// Render the structured directive PRODUCT-006 / MEM-006 read. The exact
    /// shape is the contract — keep new fields appended with `key=value`.
    pub fn directive(&self) -> String {
        format!(
            "dispatched gap={gap} effort={effort} domain={domain} outcome={outcome} \
duration_s={dur} parallel_siblings={sib} pr_number={pr:?} notes={notes_first_line}",
            gap = self.gap_id,
            effort = self.effort,
            domain = self.gap_domain,
            outcome = self.outcome,
            dur = self.duration_s,
            sib = self.parallel_siblings,
            pr = self.pr_number,
            // Only the first line of notes — the rest is in the dedicated
            // notes column on the parent reflection row.
            notes_first_line = self.notes.lines().next().unwrap_or("").trim(),
        )
    }
}

/// Map a [`DispatchOutcome`] to the canonical short string the synthesis
/// layer matches on. Stable across releases — adding new variants requires
/// extending this table, not changing existing strings.
pub fn outcome_str(outcome: &DispatchOutcome) -> &'static str {
    match outcome {
        DispatchOutcome::Shipped(_) => "shipped",
        DispatchOutcome::CiFailed(_) => "ci_failed",
        DispatchOutcome::Stalled => "stalled",
        DispatchOutcome::Killed(_) => "killed",
    }
}

/// Pull the PR number out of an outcome if one was attached.
pub fn pr_number_of(outcome: &DispatchOutcome) -> Option<u32> {
    match outcome {
        DispatchOutcome::Shipped(n) | DispatchOutcome::CiFailed(n) => Some(*n),
        DispatchOutcome::Stalled | DispatchOutcome::Killed(_) => None,
    }
}

/// Coarse domain bucket from a gap id like `"AUTO-013"` → `"auto"`. Lowercases
/// the prefix; falls back to `"unknown"` when the id has no `-`.
pub fn gap_domain(gap_id: &str) -> String {
    match gap_id.split_once('-') {
        Some((prefix, _)) if !prefix.is_empty() => prefix.to_ascii_lowercase(),
        _ => "unknown".to_string(),
    }
}

/// Sink for [`DispatchReflection`] rows. Implementations MUST be cheap and
/// MUST NOT panic — the monitor logs and continues on errors so a locked DB
/// can't lose a whole batch's outcomes.
pub trait ReflectionWriter: Send + Sync {
    fn write(&self, reflection: &DispatchReflection) -> Result<()>;
}

/// Drop-on-the-floor writer. Default for back-compat callers and `--no-reflect`.
pub struct NoopReflectionWriter;

impl ReflectionWriter for NoopReflectionWriter {
    fn write(&self, _reflection: &DispatchReflection) -> Result<()> {
        Ok(())
    }
}

/// In-memory writer for tests. Cheaply clonable via `Arc`.
#[derive(Default)]
pub struct MemoryReflectionWriter {
    rows: Mutex<Vec<DispatchReflection>>,
}

impl MemoryReflectionWriter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn snapshot(&self) -> Vec<DispatchReflection> {
        self.rows.lock().map(|g| g.clone()).unwrap_or_default()
    }

    pub fn len(&self) -> usize {
        self.rows.lock().map(|g| g.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl ReflectionWriter for MemoryReflectionWriter {
    fn write(&self, reflection: &DispatchReflection) -> Result<()> {
        if let Ok(mut g) = self.rows.lock() {
            g.push(reflection.clone());
        }
        Ok(())
    }
}

/// Production writer: persists each reflection to
/// `<repo_root>/sessions/chump_memory.db` in the canonical schema. Each row
/// is tagged `error_pattern = 'orchestrator_dispatch'` for downstream filtering.
pub struct SqliteReflectionWriter {
    db_path: PathBuf,
}

impl SqliteReflectionWriter {
    /// Build a writer rooted at `<repo_root>/sessions/chump_memory.db`. Does
    /// NOT touch the disk until the first `write()` — the test path
    /// (in-memory writer) is preferred for unit tests.
    pub fn for_repo(repo_root: &Path) -> Self {
        let db_path = repo_root.join("sessions").join("chump_memory.db");
        Self { db_path }
    }

    /// Direct constructor (mostly for the e2e test that points at a temp DB).
    pub fn at_path(db_path: PathBuf) -> Self {
        Self { db_path }
    }

    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    fn ensure_schema(conn: &Connection) -> Result<()> {
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
        )
        .context("ensuring chump_reflections / chump_improvement_targets schema")?;
        Ok(())
    }
}

impl ReflectionWriter for SqliteReflectionWriter {
    fn write(&self, reflection: &DispatchReflection) -> Result<()> {
        if let Some(parent) = self.db_path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("creating parent dir {} for reflection DB", parent.display())
            })?;
        }
        let conn = Connection::open(&self.db_path)
            .with_context(|| format!("opening reflection DB at {}", self.db_path.display()))?;
        Self::ensure_schema(&conn)?;

        // outcome_class is the coarse success/failure bucket the synthesis
        // layer keys off. Only "shipped" counts as success; everything else
        // (stalled, killed, ci_failed) is a learnable failure.
        let outcome_class = if reflection.outcome == "shipped" {
            "success"
        } else {
            "failure"
        };

        conn.execute(
            "INSERT INTO chump_reflections (
                intended_goal, observed_outcome, outcome_class, error_pattern,
                hypothesis
             ) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                format!("ship gap {}", reflection.gap_id),
                format!(
                    "outcome={} duration_s={} pr={:?}",
                    reflection.outcome, reflection.duration_s, reflection.pr_number
                ),
                outcome_class,
                "orchestrator_dispatch",
                reflection.notes,
            ],
        )
        .context("inserting chump_reflections row")?;

        let reflection_id = conn.last_insert_rowid();
        // Priority bumps for failure modes so the synthesis layer surfaces
        // them first in the next assembled prompt.
        let priority = match reflection.outcome.as_str() {
            "killed" | "ci_failed" => "high",
            "stalled" => "medium",
            _ => "low",
        };
        conn.execute(
            "INSERT INTO chump_improvement_targets (
                reflection_id, directive, priority, scope
             ) VALUES (?1, ?2, ?3, ?4)",
            params![
                reflection_id,
                reflection.directive(),
                priority,
                reflection.gap_domain,
            ],
        )
        .context("inserting chump_improvement_targets row")?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refl(gap: &str, outcome: &str, pr: Option<u32>) -> DispatchReflection {
        DispatchReflection {
            gap_id: gap.into(),
            effort: "m".into(),
            gap_domain: gap_domain(gap),
            outcome: outcome.into(),
            duration_s: 12,
            parallel_siblings: 1,
            pr_number: pr,
            notes: String::new(),
        }
    }

    #[test]
    fn outcome_str_table() {
        assert_eq!(outcome_str(&DispatchOutcome::Shipped(1)), "shipped");
        assert_eq!(outcome_str(&DispatchOutcome::CiFailed(2)), "ci_failed");
        assert_eq!(outcome_str(&DispatchOutcome::Stalled), "stalled");
        assert_eq!(outcome_str(&DispatchOutcome::Killed("x".into())), "killed");
    }

    #[test]
    fn pr_number_of_extracts_from_terminal_states() {
        assert_eq!(pr_number_of(&DispatchOutcome::Shipped(7)), Some(7));
        assert_eq!(pr_number_of(&DispatchOutcome::CiFailed(8)), Some(8));
        assert_eq!(pr_number_of(&DispatchOutcome::Stalled), None);
        assert_eq!(pr_number_of(&DispatchOutcome::Killed("x".into())), None);
    }

    #[test]
    fn gap_domain_strips_prefix() {
        assert_eq!(gap_domain("AUTO-013"), "auto");
        assert_eq!(gap_domain("EVAL-027c"), "eval");
        assert_eq!(gap_domain("PRODUCT-006"), "product");
        assert_eq!(gap_domain("noprefix"), "unknown");
    }

    #[test]
    fn directive_contains_all_fields() {
        let r = refl("AUTO-1", "shipped", Some(42));
        let d = r.directive();
        assert!(d.contains("gap=AUTO-1"));
        assert!(d.contains("effort=m"));
        assert!(d.contains("domain=auto"));
        assert!(d.contains("outcome=shipped"));
        assert!(d.contains("duration_s=12"));
        assert!(d.contains("parallel_siblings=1"));
        assert!(d.contains("pr_number=Some(42)"));
    }

    #[test]
    fn memory_writer_captures_rows() {
        let w = MemoryReflectionWriter::new();
        assert!(w.is_empty());
        w.write(&refl("A-1", "shipped", Some(1))).unwrap();
        w.write(&refl("B-2", "killed", None)).unwrap();
        let snap = w.snapshot();
        assert_eq!(snap.len(), 2);
        assert_eq!(snap[0].gap_id, "A-1");
        assert_eq!(snap[1].outcome, "killed");
    }

    #[test]
    fn noop_writer_succeeds_silently() {
        let w = NoopReflectionWriter;
        w.write(&refl("X", "shipped", None)).unwrap();
    }

    #[test]
    fn sqlite_writer_persists_to_temp_db() {
        let tmp = std::env::temp_dir().join(format!(
            "chump-orch-reflect-{}-{}.db",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = std::fs::remove_file(&tmp);
        let w = SqliteReflectionWriter::at_path(tmp.clone());
        w.write(&refl("AUTO-1", "shipped", Some(101))).unwrap();
        w.write(&refl("EVAL-9", "killed", None)).unwrap();

        let conn = rusqlite::Connection::open(&tmp).unwrap();
        let n: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM chump_reflections WHERE error_pattern = 'orchestrator_dispatch'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 2);
        let m: i64 = conn
            .query_row("SELECT COUNT(*) FROM chump_improvement_targets", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(m, 2);
        let _ = std::fs::remove_file(&tmp);
    }
}
