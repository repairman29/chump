//! SQLite-backed gap store — INFRA-023.
//!
//! Wraps `gaps`, `leases`, and `intents` tables in `.chump/state.db`.
//! All mutations are single-transaction so concurrent agents get atomic IDs.
//!
//! DATABASE: `<repo_root>/.chump/state.db`
//!
//! MIGRATION from docs/gaps.yaml + .chump-locks/ JSON:
//!   `GapStore::import_from_yaml(&repo_root)` is idempotent — safe to re-run.
//!   Existing DB rows are NOT overwritten; only new gaps are inserted.

use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

// ────────────────────────── Data types ──────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GapRow {
    pub id: String,
    pub domain: String,
    pub title: String,
    pub description: String,
    pub priority: String,
    pub effort: String,
    pub status: String,
    pub acceptance_criteria: String,
    pub depends_on: String,
    pub notes: String,
    pub source_doc: String,
    pub created_at: i64,
    pub closed_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LeaseRow {
    pub session_id: String,
    pub gap_id: String,
    pub worktree: String,
    pub expires_at: i64,
}

// ────────────────────────── DB open/migrate ──────────────────────────

pub struct GapStore {
    conn: Connection,
}

impl GapStore {
    pub fn db_path(repo_root: &Path) -> PathBuf {
        repo_root.join(".chump").join("state.db")
    }

    pub fn open(repo_root: &Path) -> Result<Self> {
        let path = Self::db_path(repo_root);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating .chump/ at {}", parent.display()))?;
        }
        let conn =
            Connection::open(&path).with_context(|| format!("opening {}", path.display()))?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        self.conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS gaps (
                id                  TEXT PRIMARY KEY,
                domain              TEXT NOT NULL DEFAULT '',
                title               TEXT NOT NULL DEFAULT '',
                description         TEXT NOT NULL DEFAULT '',
                priority            TEXT NOT NULL DEFAULT '',
                effort              TEXT NOT NULL DEFAULT '',
                status              TEXT NOT NULL DEFAULT 'open',
                acceptance_criteria TEXT NOT NULL DEFAULT '',
                depends_on          TEXT NOT NULL DEFAULT '',
                notes               TEXT NOT NULL DEFAULT '',
                source_doc          TEXT NOT NULL DEFAULT '',
                created_at          INTEGER NOT NULL DEFAULT 0,
                closed_at           INTEGER
            );

            -- Atomic per-domain sequence counter. Each reserve increments next_num.
            CREATE TABLE IF NOT EXISTS gap_counters (
                domain      TEXT PRIMARY KEY,
                next_num    INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS leases (
                session_id  TEXT PRIMARY KEY,
                gap_id      TEXT NOT NULL,
                worktree    TEXT NOT NULL DEFAULT '',
                expires_at  INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS intents (
                ts          INTEGER NOT NULL,
                session_id  TEXT NOT NULL,
                gap_id      TEXT NOT NULL,
                files       TEXT NOT NULL DEFAULT ''
            );

            CREATE INDEX IF NOT EXISTS leases_gap ON leases(gap_id);
            CREATE INDEX IF NOT EXISTS gaps_status ON gaps(status);
            CREATE INDEX IF NOT EXISTS gaps_domain ON gaps(domain);
        ",
        )?;
        Ok(())
    }
}

// ────────────────────────── gap commands ──────────────────────────

impl GapStore {
    /// List gaps, optionally filtered by status.
    pub fn list(&self, status_filter: Option<&str>) -> Result<Vec<GapRow>> {
        let make_row = |row: &rusqlite::Row<'_>| {
            Ok(GapRow {
                id: row.get(0)?,
                domain: row.get(1)?,
                title: row.get(2)?,
                description: row.get(3)?,
                priority: row.get(4)?,
                effort: row.get(5)?,
                status: row.get(6)?,
                acceptance_criteria: row.get(7)?,
                depends_on: row.get(8)?,
                notes: row.get(9)?,
                source_doc: row.get(10)?,
                created_at: row.get(11)?,
                closed_at: row.get(12)?,
            })
        };
        if let Some(s) = status_filter {
            let mut stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                        acceptance_criteria,depends_on,notes,source_doc,created_at,closed_at
                 FROM gaps WHERE status=?1 ORDER BY priority,effort",
            )?;
            let rows = stmt.query_map(params![s], make_row)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
        } else {
            let mut stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                        acceptance_criteria,depends_on,notes,source_doc,created_at,closed_at
                 FROM gaps ORDER BY priority,effort",
            )?;
            let rows = stmt.query_map([], make_row)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
        }
    }

    /// Reserve a new gap ID atomically using a per-domain counter row.
    /// The counter upsert + gap insert runs under an exclusive transaction,
    /// so concurrent callers get distinct IDs with no retries.
    pub fn reserve(
        &self,
        domain: &str,
        title: &str,
        priority: &str,
        effort: &str,
    ) -> Result<String> {
        let domain_upper = domain.to_uppercase();
        let now = unix_now();

        // Seed the counter from existing gaps if this is the first reserve for the domain.
        // Then atomically bump it and insert the new gap row — all under one exclusive lock.
        self.conn.execute_batch("BEGIN EXCLUSIVE")?;
        let result = (|| -> Result<String> {
            // Ensure counter row exists, seeded from max existing ID for this domain.
            let prefix = format!("{}-", domain_upper);
            let existing_max: i64 = self.conn.query_row(
                "SELECT COALESCE(MAX(CAST(SUBSTR(id, LENGTH(?1)+1) AS INTEGER)), 0) FROM gaps WHERE id LIKE ?2",
                params![prefix, format!("{}%", prefix)],
                |r| r.get(0),
            )?;
            self.conn.execute(
                "INSERT INTO gap_counters(domain, next_num) VALUES(?1, ?2)
                 ON CONFLICT(domain) DO NOTHING",
                params![domain_upper, existing_max + 1],
            )?;
            // Atomically bump the counter and read the assigned number.
            self.conn.execute(
                "UPDATE gap_counters SET next_num = next_num + 1 WHERE domain=?1",
                params![domain_upper],
            )?;
            let num: i64 = self.conn.query_row(
                "SELECT next_num - 1 FROM gap_counters WHERE domain=?1",
                params![domain_upper],
                |r| r.get(0),
            )?;
            let new_id = format!("{}{:03}", prefix, num);
            self.conn.execute(
                "INSERT INTO gaps(id,domain,title,priority,effort,status,created_at)
                 VALUES(?1,?2,?3,?4,?5,'open',?6)",
                params![new_id, domain_upper, title, priority, effort, now],
            )?;
            Ok(new_id)
        })();
        match result {
            Ok(id) => {
                self.conn.execute_batch("COMMIT")?;
                Ok(id)
            }
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }

    /// Claim a gap for a session (write lease row).
    pub fn claim(
        &self,
        gap_id: &str,
        session_id: &str,
        worktree: &str,
        ttl_secs: i64,
    ) -> Result<()> {
        let expires_at = unix_now() + ttl_secs;
        // Verify gap exists and is open
        let status: String = self
            .conn
            .query_row(
                "SELECT status FROM gaps WHERE id=?1",
                params![gap_id],
                |r| r.get(0),
            )
            .with_context(|| format!("gap {} not found in state.db", gap_id))?;
        if status == "done" {
            bail!("gap {} is already done", gap_id);
        }
        // Check for live conflicting claim
        let live_claim: Option<String> = self.conn.query_row(
            "SELECT session_id FROM leases WHERE gap_id=?1 AND expires_at>?2 AND session_id!=?3",
            params![gap_id, unix_now(), session_id],
            |r| r.get(0),
        ).optional()?;
        if let Some(other) = live_claim {
            bail!("gap {} is live-claimed by session {}", gap_id, other);
        }
        self.conn.execute(
            "INSERT INTO leases(session_id,gap_id,worktree,expires_at)
             VALUES(?1,?2,?3,?4)
             ON CONFLICT(session_id) DO UPDATE SET gap_id=excluded.gap_id,
                 worktree=excluded.worktree, expires_at=excluded.expires_at",
            params![session_id, gap_id, worktree, expires_at],
        )?;
        Ok(())
    }

    /// Preflight check: is the gap open and unclaimed?
    pub fn preflight(&self, gap_id: &str) -> Result<PreflightResult> {
        let row = self
            .conn
            .query_row(
                "SELECT status FROM gaps WHERE id=?1",
                params![gap_id],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        match row {
            None => return Ok(PreflightResult::NotFound),
            Some(s) if s == "done" => return Ok(PreflightResult::Done),
            _ => {}
        }
        let live_claim: Option<String> = self
            .conn
            .query_row(
                "SELECT session_id FROM leases WHERE gap_id=?1 AND expires_at>?2",
                params![gap_id, unix_now()],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(s) = live_claim {
            return Ok(PreflightResult::Claimed(s));
        }
        Ok(PreflightResult::Available)
    }

    /// Mark a gap as done.
    pub fn ship(&self, gap_id: &str, session_id: &str) -> Result<()> {
        let now = unix_now();
        let changed = self.conn.execute(
            "UPDATE gaps SET status='done', closed_at=?1 WHERE id=?2 AND status='open'",
            params![now, gap_id],
        )?;
        if changed == 0 {
            bail!("gap {} not found or already done", gap_id);
        }
        // Release the lease
        let _ = self.conn.execute(
            "DELETE FROM leases WHERE session_id=?1 AND gap_id=?2",
            params![session_id, gap_id],
        );
        Ok(())
    }

    /// Dump gaps as YAML-compatible text (for git-diff review).
    pub fn dump_yaml(&self) -> Result<String> {
        let gaps = self.list(None)?;
        let mut out = String::from("---\ngaps:\n");
        for g in &gaps {
            out.push_str(&format!("- id: {}\n", g.id));
            out.push_str(&format!("  title: {}\n", yaml_quote(&g.title)));
            out.push_str(&format!("  domain: {}\n", g.domain.to_lowercase()));
            out.push_str(&format!("  priority: {}\n", g.priority));
            out.push_str(&format!("  effort: {}\n", g.effort));
            out.push_str(&format!("  status: {}\n", g.status));
            if !g.depends_on.is_empty() && g.depends_on != "[]" {
                out.push_str(&format!("  depends_on: {}\n", g.depends_on));
            }
            if !g.notes.is_empty() {
                out.push_str(&format!("  notes: {}\n", yaml_quote(&g.notes)));
            }
        }
        Ok(out)
    }
}

// ────────────────────────── one-shot importer ──────────────────────────

#[derive(Debug, Deserialize)]
struct YamlGap {
    id: String,
    #[serde(default)]
    domain: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    priority: String,
    #[serde(default)]
    effort: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    acceptance_criteria: Option<serde_json::Value>,
    #[serde(default)]
    depends_on: Option<Vec<String>>,
    #[serde(default)]
    notes: Option<String>,
    #[serde(default)]
    source_doc: Option<String>,
}

#[derive(Deserialize)]
struct YamlGapsFile {
    #[serde(default)]
    gaps: Vec<YamlGap>,
}

impl GapStore {
    /// Import from docs/gaps.yaml into the DB. Idempotent — existing rows are skipped.
    pub fn import_from_yaml(&self, repo_root: &Path) -> Result<(usize, usize)> {
        let yaml_path = repo_root.join("docs").join("gaps.yaml");
        let text = std::fs::read_to_string(&yaml_path)
            .with_context(|| format!("reading {}", yaml_path.display()))?;
        let file: YamlGapsFile = serde_yaml::from_str(&text)?;

        let mut inserted = 0usize;
        let mut skipped = 0usize;

        for g in &file.gaps {
            let ac = g
                .acceptance_criteria
                .as_ref()
                .map(|v| v.to_string())
                .unwrap_or_default();
            let deps = g
                .depends_on
                .as_ref()
                .map(|v| serde_json::to_string(v).unwrap_or_default())
                .unwrap_or_default();
            let notes = g.notes.clone().unwrap_or_default();
            let source_doc = g.source_doc.clone().unwrap_or_default();
            let created_at = unix_now();

            let changed = self.conn.execute(
                "INSERT OR IGNORE INTO gaps(id,domain,title,description,priority,effort,status,
                    acceptance_criteria,depends_on,notes,source_doc,created_at)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                params![
                    g.id,
                    g.domain,
                    g.title,
                    g.description,
                    g.priority,
                    g.effort,
                    g.status,
                    ac,
                    deps,
                    notes,
                    source_doc,
                    created_at
                ],
            )?;
            if changed > 0 {
                inserted += 1;
            } else {
                skipped += 1;
            }
        }
        Ok((inserted, skipped))
    }
}

// ────────────────────────── helpers ──────────────────────────

#[derive(Debug)]
pub enum PreflightResult {
    Available,
    NotFound,
    Done,
    Claimed(String),
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn yaml_quote(s: &str) -> String {
    if s.contains(':') || s.contains('#') || s.contains('\'') {
        format!("\"{}\"", s.replace('"', "\\\""))
    } else {
        s.to_string()
    }
}

trait OptionalExt<T> {
    fn optional(self) -> Result<Option<T>, rusqlite::Error>;
}
impl<T> OptionalExt<T> for Result<T, rusqlite::Error> {
    fn optional(self) -> Result<Option<T>, rusqlite::Error> {
        match self {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

// ────────────────────────── tests ──────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn test_store() -> (GapStore, TempDir) {
        let dir = TempDir::new().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        (store, dir)
    }

    #[test]
    fn test_reserve_sequential() {
        let (store, _dir) = test_store();
        let id1 = store.reserve("INFRA", "First gap", "P1", "s").unwrap();
        let id2 = store.reserve("INFRA", "Second gap", "P1", "s").unwrap();
        assert_eq!(id1, "INFRA-001");
        assert_eq!(id2, "INFRA-002");
    }

    #[test]
    fn test_reserve_concurrent() {
        // Spawn 10 threads, each reserving one INFRA gap.
        // All 10 should get distinct IDs with no errors.
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();

        let results: Vec<_> = (0..10)
            .map(|_| {
                let root = repo_root.clone();
                std::thread::spawn(move || {
                    let store = GapStore::open(&root).unwrap();
                    store.reserve("INFRA", "concurrent gap", "P1", "s")
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect();

        let ids: Vec<String> = results.into_iter().map(|r| r.unwrap()).collect();
        let mut sorted = ids.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), 10, "expected 10 distinct IDs, got: {:?}", ids);
    }

    #[test]
    fn test_claim_and_preflight() {
        let (store, _dir) = test_store();
        let id = store.reserve("EVAL", "Test gap", "P1", "s").unwrap();

        match store.preflight(&id).unwrap() {
            PreflightResult::Available => {}
            other => panic!("expected Available, got {:?}", other),
        }

        store
            .claim(&id, "session-abc", "/worktrees/test", 3600)
            .unwrap();

        match store.preflight(&id).unwrap() {
            PreflightResult::Claimed(s) => assert_eq!(s, "session-abc"),
            other => panic!("expected Claimed, got {:?}", other),
        }
    }

    #[test]
    fn test_ship() {
        let (store, _dir) = test_store();
        let id = store.reserve("MEM", "Test gap", "P1", "s").unwrap();
        store
            .claim(&id, "session-xyz", "/worktrees/test", 3600)
            .unwrap();
        store.ship(&id, "session-xyz").unwrap();

        match store.preflight(&id).unwrap() {
            PreflightResult::Done => {}
            other => panic!("expected Done, got {:?}", other),
        }
    }

    #[test]
    fn test_list_filter() {
        let (store, _dir) = test_store();
        store.reserve("COG", "open gap", "P1", "s").unwrap();
        let id2 = store.reserve("COG", "to close", "P1", "s").unwrap();
        store.claim(&id2, "s", "/wt", 3600).unwrap();
        store.ship(&id2, "s").unwrap();

        let open = store.list(Some("open")).unwrap();
        assert_eq!(open.len(), 1);
        let all = store.list(None).unwrap();
        assert_eq!(all.len(), 2);
    }
}
