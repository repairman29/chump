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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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
    /// ISO date string from `opened_date:` in YAML. Empty if absent.
    /// Stored separately from `created_at` (unix ts) because the YAML uses
    /// human-friendly dates without time/zone, and round-trip must preserve
    /// the exact author-provided string.
    #[serde(default)]
    pub opened_date: String,
    /// ISO date string from `closed_date:` in YAML. Empty if absent.
    #[serde(default)]
    pub closed_date: String,
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
    repo_root: PathBuf,
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
        // busy_timeout: concurrent gap_store::tests::test_reserve_concurrent opens
        // multiple connections to one WAL DB; without a wait, BEGIN EXCLUSIVE races
        // surface as rusqlite "database is locked" on CI runners.
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
        )?;
        let store = Self {
            conn,
            repo_root: repo_root.to_path_buf(),
        };
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

            -- COG-036: per-dispatch outcome scoreboard. Each terminal
            -- DispatchOutcome from the orchestrator monitor writes one row
            -- so a future Thompson-sampling router (COG-037) can self-learn.
            CREATE TABLE IF NOT EXISTS routing_outcomes (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                recorded_at   TEXT NOT NULL,
                task_class    TEXT NOT NULL DEFAULT '',
                priority      TEXT NOT NULL DEFAULT '',
                effort        TEXT NOT NULL DEFAULT '',
                backend       TEXT NOT NULL,
                model         TEXT NOT NULL DEFAULT '',
                provider_pfx  TEXT NOT NULL DEFAULT '',
                gap_id        TEXT NOT NULL,
                outcome       TEXT NOT NULL,
                pr_number     INTEGER,
                duration_s    INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS routing_outcomes_lookup
                ON routing_outcomes(task_class, backend, model, provider_pfx);
            CREATE INDEX IF NOT EXISTS routing_outcomes_recent
                ON routing_outcomes(recorded_at);
        ",
        )?;
        // M1 (INFRA-059): add ISO-date columns alongside existing unix timestamps.
        // The YAML uses author-provided date strings (`opened_date: '2026-04-25'`);
        // round-trip preserves them verbatim instead of reformatting from unix ts.
        // ALTER TABLE ADD is idempotent here — duplicate-column errors are ignored.
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN opened_date TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN closed_date TEXT NOT NULL DEFAULT ''",
            [],
        );
        // Backfill closed_date for done rows that predate the column. Idempotent:
        // only touches rows where closed_date is empty AND closed_at is set, so
        // re-running is a no-op once the row is healed. UTC matches `unix_to_iso_date`.
        let _ = self.conn.execute(
            "UPDATE gaps
                SET closed_date = strftime('%Y-%m-%d', closed_at, 'unixepoch')
                WHERE status = 'done'
                  AND closed_at IS NOT NULL AND closed_at > 0
                  AND (closed_date IS NULL OR closed_date = '')",
            [],
        );
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
                opened_date: row.get(13)?,
                closed_date: row.get(14)?,
            })
        };
        if let Some(s) = status_filter {
            let mut stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                        acceptance_criteria,depends_on,notes,source_doc,created_at,closed_at,
                        opened_date,closed_date
                 FROM gaps WHERE status=?1 ORDER BY id",
            )?;
            let rows = stmt.query_map(params![s], make_row)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
        } else {
            let mut stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                        acceptance_criteria,depends_on,notes,source_doc,created_at,closed_at,
                        opened_date,closed_date
                 FROM gaps ORDER BY id",
            )?;
            let rows = stmt.query_map([], make_row)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
        }
    }

    /// Get a single gap by ID.
    pub fn get(&self, gap_id: &str) -> Result<Option<GapRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT id,domain,title,description,priority,effort,status,
                    acceptance_criteria,depends_on,notes,source_doc,created_at,closed_at,
                    opened_date,closed_date
             FROM gaps WHERE id=?1",
        )?;
        let row = stmt
            .query_row(params![gap_id], |row| {
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
                    opened_date: row.get(13)?,
                    closed_date: row.get(14)?,
                })
            })
            .optional()?;
        Ok(row)
    }

    /// Update mutable fields on an existing gap row. Pass None to leave a
    /// field unchanged. Used by `chump gap set` so agents can author
    /// description / acceptance / notes without hand-editing YAML.
    pub fn set_fields(&self, gap_id: &str, fields: GapFieldUpdate) -> Result<()> {
        let mut sets: Vec<&str> = Vec::new();
        let mut vals: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(v) = fields.title {
            sets.push("title=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.description {
            sets.push("description=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.priority {
            sets.push("priority=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.effort {
            sets.push("effort=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.status {
            sets.push("status=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.acceptance_criteria {
            sets.push("acceptance_criteria=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.depends_on {
            sets.push("depends_on=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.notes {
            sets.push("notes=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.source_doc {
            sets.push("source_doc=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.opened_date {
            sets.push("opened_date=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.closed_date {
            sets.push("closed_date=?");
            vals.push(Box::new(v));
        }
        if sets.is_empty() {
            return Ok(());
        }
        vals.push(Box::new(gap_id.to_string()));
        let sql = format!("UPDATE gaps SET {} WHERE id=?", sets.join(","));
        let params_vec: Vec<&dyn rusqlite::ToSql> = vals.iter().map(|b| b.as_ref()).collect();
        let changed = self.conn.execute(&sql, params_vec.as_slice())?;
        if changed == 0 {
            bail!("gap {} not found", gap_id);
        }
        Ok(())
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

        // INFRA-070: backfill any docs/gaps.yaml drift before reserving so the counter seed
        // can't be lower than the YAML max. import_from_yaml is INSERT OR IGNORE — idempotent
        // and safe to call on every reserve.
        //
        // INFRA-143: previously this was `let _ = self.import_from_yaml(...)` — silently
        // swallowing the error. A schema break in gaps.yaml (e.g. gap[17] writing source_doc
        // as a sequence under stale binaries) caused import to fail, the counter stayed
        // seeded from the older DB max, and reserve handed out IDs that already existed in
        // YAML — exactly the EVAL-089 (PR #558 ↔ #601) collision pattern. Fail loud so
        // operators see the drift and fix it before it accumulates.
        self.import_from_yaml(&self.repo_root.clone())
            .with_context(|| {
                format!(
                    "reserve({domain_upper}) aborted: docs/gaps.yaml is unreadable so the \
                     ID counter cannot be backfilled. Fix the YAML (or reset the binary) \
                     before retrying — reserving now would risk colliding with an ID that \
                     exists in YAML but not in the DB."
                )
            })?;

        // Seed the counter from existing gaps if this is the first reserve for the domain.
        // Then atomically bump it and insert the new gap row under IMMEDIATE (reserved write
        // lock). BEGIN EXCLUSIVE was too strong: concurrent GapStore::open + migrate on the
        // same WAL file failed CI with "database is locked" (gap_store::tests::test_reserve_concurrent).
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        let result = (|| -> Result<String> {
            // Ensure counter row exists, seeded from max existing ID for this domain.
            // INFRA-070: ON CONFLICT bumps the counter to MAX(current, gaps_max+1) so a
            // previously-low counter can't keep returning IDs that exist in YAML.
            let prefix = format!("{}-", domain_upper);
            let existing_max: i64 = self.conn.query_row(
                "SELECT COALESCE(MAX(CAST(SUBSTR(id, LENGTH(?1)+1) AS INTEGER)), 0) FROM gaps WHERE id LIKE ?2",
                params![prefix, format!("{}%", prefix)],
                |r| r.get(0),
            )?;
            self.conn.execute(
                "INSERT INTO gap_counters(domain, next_num) VALUES(?1, ?2)
                 ON CONFLICT(domain) DO UPDATE SET next_num = MAX(next_num, excluded.next_num)",
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

    /// Mark a gap as done. Stamps both `closed_at` (unix ts) and
    /// `closed_date` (ISO yyyy-mm-dd, matching YAML convention).
    pub fn ship(&self, gap_id: &str, session_id: &str) -> Result<()> {
        let now = unix_now();
        let iso = unix_to_iso_date(now);
        let changed = self.conn.execute(
            "UPDATE gaps SET status='done', closed_at=?1, closed_date=?2
             WHERE id=?3 AND status='open'",
            params![now, iso, gap_id],
        )?;
        if changed == 0 {
            bail!("gap {} not found or already done", gap_id);
        }
        let _ = self.conn.execute(
            "DELETE FROM leases WHERE session_id=?1 AND gap_id=?2",
            params![session_id, gap_id],
        );
        Ok(())
    }

    /// Dump gaps as canonical YAML, lossless across all DB columns.
    /// M1 (INFRA-059) — round-trips through `import_from_yaml` with byte
    /// stability for the `gaps:` block (the `meta:` preamble is preserved
    /// verbatim by `dump_yaml_with_meta` when given the source YAML).
    pub fn dump_yaml(&self) -> Result<String> {
        let gaps = self.list(None)?;
        let mut out = String::from("gaps:\n");
        for g in &gaps {
            out.push_str(&format_gap_yaml(g));
        }
        Ok(out)
    }

    /// Like `dump_yaml`, but reuses the `meta:` preamble from `source_yaml`
    /// (everything before the first `gaps:` line) so a file regen preserves
    /// the human-curated meta block. Falls back to bare `dump_yaml()` if no
    /// `gaps:` line is found.
    pub fn dump_yaml_with_meta(&self, source_yaml: &str) -> Result<String> {
        let body = self.dump_yaml()?;
        if let Some(gaps_idx) = source_yaml.find("\ngaps:\n") {
            // include leading newline
            let preamble = &source_yaml[..gaps_idx + 1];
            Ok(format!("{}{}", preamble, body))
        } else {
            Ok(body)
        }
    }
}

/// Mutable-field bundle for `chump gap set`. None means "leave unchanged".
/// Strings can be empty to clear a field; pass `Some("")` to do so.
#[derive(Debug, Default)]
pub struct GapFieldUpdate {
    pub title: Option<String>,
    pub description: Option<String>,
    pub priority: Option<String>,
    pub effort: Option<String>,
    pub status: Option<String>,
    pub acceptance_criteria: Option<String>,
    pub depends_on: Option<String>,
    pub notes: Option<String>,
    pub source_doc: Option<String>,
    pub opened_date: Option<String>,
    pub closed_date: Option<String>,
}

/// Render one gap as a YAML block-list entry. Field order matches the
/// hand-curated convention in `docs/gaps.yaml` (id → domain → title →
/// status → priority → effort → description → acceptance_criteria →
/// depends_on → notes → source_doc → opened_date → closed_date). Empty
/// fields are omitted (matches existing YAML practice).
fn format_gap_yaml(g: &GapRow) -> String {
    let mut s = String::new();
    s.push_str(&format!("- id: {}\n", g.id));
    if !g.domain.is_empty() {
        s.push_str(&format!("  domain: {}\n", g.domain));
    }
    if !g.title.is_empty() {
        s.push_str(&format!("  title: {}\n", yaml_scalar(&g.title)));
    }
    if !g.status.is_empty() {
        s.push_str(&format!("  status: {}\n", g.status));
    }
    if !g.priority.is_empty() {
        s.push_str(&format!("  priority: {}\n", g.priority));
    }
    if !g.effort.is_empty() {
        s.push_str(&format!("  effort: {}\n", g.effort));
    }
    if !g.description.is_empty() {
        s.push_str("  description: ");
        s.push_str(&yaml_block_scalar(&g.description, "  "));
        s.push('\n');
    }
    if let Some(items) = parse_json_string_list(&g.acceptance_criteria) {
        if !items.is_empty() {
            s.push_str("  acceptance_criteria:\n");
            for item in &items {
                s.push_str(&format!("    - {}\n", yaml_scalar(item)));
            }
        }
    }
    if let Some(items) = parse_json_string_list(&g.depends_on) {
        if !items.is_empty() {
            // Flow style for short lists matches the existing convention.
            let flow = items.join(", ");
            s.push_str(&format!("  depends_on: [{}]\n", flow));
        }
    }
    if !g.notes.is_empty() {
        s.push_str("  notes: ");
        s.push_str(&yaml_block_scalar(&g.notes, "  "));
        s.push('\n');
    }
    if !g.source_doc.is_empty() {
        s.push_str(&format!("  source_doc: {}\n", yaml_scalar(&g.source_doc)));
    }
    if !g.opened_date.is_empty() {
        s.push_str(&format!("  opened_date: {}\n", yaml_date(&g.opened_date)));
    }
    if !g.closed_date.is_empty() {
        s.push_str(&format!("  closed_date: {}\n", yaml_date(&g.closed_date)));
    }
    s.push('\n');
    s
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
    depends_on: Option<serde_json::Value>,
    #[serde(default)]
    notes: Option<serde_yaml::Value>,
    #[serde(default)]
    source_doc: Option<serde_yaml::Value>,
    #[serde(default)]
    opened_date: Option<serde_yaml::Value>,
    #[serde(default)]
    closed_date: Option<serde_yaml::Value>,
}

#[derive(Deserialize)]
struct YamlGapsFile {
    #[serde(default)]
    gaps: Vec<YamlGap>,
}

impl GapStore {
    /// Import from docs/gaps.yaml into the DB. Idempotent — existing rows are skipped.
    ///
    /// Missing-file is treated as a no-op (returns `Ok((0, 0))`) so fresh tempdir
    /// callers and bootstrap paths don't have to special-case it. A YAML file
    /// that *exists* but is unreadable / malformed propagates the error so callers
    /// like `reserve()` can fail loud (INFRA-143).
    pub fn import_from_yaml(&self, repo_root: &Path) -> Result<(usize, usize)> {
        let yaml_path = repo_root.join("docs").join("gaps.yaml");
        let text = match std::fs::read_to_string(&yaml_path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((0, 0)),
            Err(e) => {
                return Err(anyhow::Error::from(e))
                    .with_context(|| format!("reading {}", yaml_path.display()));
            }
        };
        let file: YamlGapsFile = serde_yaml::from_str(&text)
            .with_context(|| format!("parsing {}", yaml_path.display()))?;

        let mut inserted = 0usize;
        let mut skipped = 0usize;

        for g in &file.gaps {
            // Normalize acceptance_criteria to JSON-stringified array of strings.
            let ac = match &g.acceptance_criteria {
                Some(v) => normalize_string_list(v),
                None => String::new(),
            };
            // Normalize depends_on the same way (handles both ["X"] block and [X, Y] flow).
            let deps = match &g.depends_on {
                Some(v) => {
                    let json: serde_json::Value =
                        serde_json::from_str(&v.to_string()).unwrap_or(serde_json::Value::Null);
                    normalize_string_list(&json)
                }
                None => String::new(),
            };
            let notes = g
                .notes
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let source_doc = g
                .source_doc
                .as_ref()
                .map(yaml_value_to_loose_string)
                .unwrap_or_default();
            let opened_date = g
                .opened_date
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let closed_date = g
                .closed_date
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let created_at = unix_now();

            let changed = self.conn.execute(
                "INSERT OR IGNORE INTO gaps(id,domain,title,description,priority,effort,status,
                    acceptance_criteria,depends_on,notes,source_doc,created_at,
                    opened_date,closed_date)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)",
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
                    created_at,
                    opened_date,
                    closed_date,
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

/// Quote a YAML scalar for an inline value. Returns the input unchanged if
/// safe; otherwise wraps in double quotes with escapes. Multi-line strings
/// should use `yaml_block_scalar` instead.
fn yaml_scalar(s: &str) -> String {
    if s.is_empty() {
        return "\"\"".to_string();
    }
    if s.contains('\n') {
        // Caller should use yaml_block_scalar; defensive fallback to double-quoted.
        return format!(
            "\"{}\"",
            s.replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace('\n', "\\n")
        );
    }
    let needs_quoting = s.contains(':')
        || s.contains('#')
        || s.contains('"')
        || s.starts_with('\'')
        || s.starts_with('-')
        || s.starts_with('?')
        || s.starts_with('&')
        || s.starts_with('*')
        || s.starts_with('[')
        || s.starts_with('{')
        || s.starts_with('|')
        || s.starts_with('>')
        || s.starts_with('@')
        || s.starts_with('`')
        || s.trim() != s
        || matches!(s, "true" | "false" | "null" | "yes" | "no" | "~");
    if needs_quoting {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        s.to_string()
    }
}

/// Render a multi-line description/notes field as a YAML block scalar with
/// `>` (folded) for short text or literal `|` for text that already has
/// embedded newlines. `indent` is the prefix for content lines (typically
/// "  " — two spaces, matching block-list entry indentation).
fn yaml_block_scalar(s: &str, indent: &str) -> String {
    if !s.contains('\n') && s.len() < 80 && !s.contains(':') && !s.contains('#') {
        // short single line — emit inline
        return yaml_scalar(s);
    }
    // Use literal `|` to preserve newlines exactly. Followed by indented body.
    let mut out = String::from("|\n");
    for line in s.split('\n') {
        out.push_str(indent);
        out.push_str("  ");
        out.push_str(line);
        out.push('\n');
    }
    // Trim trailing newline so caller-added "\n" doesn't double.
    if out.ends_with('\n') {
        out.pop();
    }
    out
}

/// Parse a stored JSON-string-array column back to Vec<String>. Returns None
/// when the field is empty or unparseable.
fn parse_json_string_list(s: &str) -> Option<Vec<String>> {
    if s.trim().is_empty() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(s).ok()?;
    let arr = v.as_array()?;
    Some(
        arr.iter()
            .filter_map(|x| x.as_str().map(String::from))
            .collect(),
    )
}

/// Quote a YAML date scalar. Existing `docs/gaps.yaml` uses single-quoted
/// dates (`'2026-04-25'`); preserve that for round-trip. Strips any stray
/// surrounding quotes/backslashes that may have leaked in from past
/// hand-edits or escaped values.
fn yaml_date(s: &str) -> String {
    let trimmed = s
        .trim()
        .trim_matches(|c: char| c == '\'' || c == '"' || c == '\\');
    format!("'{}'", trimmed)
}

/// Convert a unix timestamp to ISO YYYY-MM-DD using local-naive UTC.
fn unix_to_iso_date(ts: i64) -> String {
    use chrono::{TimeZone, Utc};
    Utc.timestamp_opt(ts, 0)
        .single()
        .map(|dt| dt.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

/// Normalize a serde_json::Value (typically a YAML-imported list or scalar)
/// into a JSON string-array stored in the DB. Non-array inputs become `[]`.
fn normalize_string_list(v: &serde_json::Value) -> String {
    let items: Vec<String> = match v {
        serde_json::Value::Array(arr) => arr
            .iter()
            .filter_map(|x| match x {
                serde_json::Value::String(s) => Some(s.clone()),
                serde_json::Value::Number(n) => Some(n.to_string()),
                serde_json::Value::Bool(b) => Some(b.to_string()),
                _ => None,
            })
            .collect(),
        serde_json::Value::Null => Vec::new(),
        _ => Vec::new(),
    };
    serde_json::to_string(&items).unwrap_or_else(|_| "[]".to_string())
}

/// Loose string coercion that joins sequence values with `, `. Handles the
/// historical `source_doc:` field that some PRs wrote as a list instead of a
/// scalar. Non-list values fall through to `yaml_value_to_string`.
fn yaml_value_to_loose_string(v: &serde_yaml::Value) -> String {
    if let serde_yaml::Value::Sequence(seq) = v {
        return seq
            .iter()
            .map(yaml_value_to_string)
            .collect::<Vec<_>>()
            .join(", ");
    }
    yaml_value_to_string(v)
}

/// Convert a serde_yaml::Value to a string for date-like fields. YAML may
/// parse `2026-04-25` as a date type or string; we want the ISO text either way.
fn yaml_value_to_string(v: &serde_yaml::Value) -> String {
    match v {
        serde_yaml::Value::String(s) => s.clone(),
        serde_yaml::Value::Number(n) => n.to_string(),
        serde_yaml::Value::Bool(b) => b.to_string(),
        serde_yaml::Value::Null => String::new(),
        other => serde_yaml::to_string(other)
            .unwrap_or_default()
            .trim()
            .trim_end_matches('\n')
            .to_string(),
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

// ────────── routing outcomes (COG-036) ──────────

/// One row written to `routing_outcomes` per terminal dispatch outcome.
/// Consumed by `routing_scoreboard()` and (eventually) the COG-037
/// Thompson-sampling router.
#[derive(Debug, Clone, Default)]
pub struct RoutingOutcomeRow {
    /// RFC3339 UTC timestamp.
    pub recorded_at: String,
    /// `"research"`, `"dispatch"`, or `""` (unknown / generic).
    pub task_class: String,
    pub priority: String,
    pub effort: String,
    /// `"claude"` | `"chump-local"`.
    pub backend: String,
    pub model: String,
    pub provider_pfx: String,
    pub gap_id: String,
    /// `"shipped"` | `"stalled"` | `"killed"` | `"ci_failed"`.
    pub outcome: String,
    pub pr_number: Option<u32>,
    pub duration_s: i64,
}

/// One aggregated row from the `(task_class, backend, model, provider_pfx)`
/// rollup used by `chump dispatch scoreboard` and the COG-037 sampler.
#[derive(Debug, Clone)]
pub struct ScoreboardEntry {
    pub task_class: String,
    pub backend: String,
    pub model: String,
    pub provider_pfx: String,
    pub successes: u64,
    pub failures: u64,
    pub total: u64,
    pub success_rate: f64,
    pub last_seen: String,
}

impl GapStore {
    /// Append one routing-outcome row. Best-effort: callers (the orchestrator
    /// monitor) treat write errors as non-fatal because the dispatch already
    /// succeeded/failed before this row exists.
    pub fn record_routing_outcome(&self, row: &RoutingOutcomeRow) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO routing_outcomes
                    (recorded_at, task_class, priority, effort, backend, model,
                     provider_pfx, gap_id, outcome, pr_number, duration_s)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    row.recorded_at,
                    row.task_class,
                    row.priority,
                    row.effort,
                    row.backend,
                    row.model,
                    row.provider_pfx,
                    row.gap_id,
                    row.outcome,
                    row.pr_number,
                    row.duration_s,
                ],
            )
            .context("insert routing_outcomes row")?;
        Ok(())
    }

    /// Aggregate routing outcomes by `(task_class, backend, model,
    /// provider_pfx)`. `"shipped"` counts as success; everything else is a
    /// failure. Ordered by `total DESC, success_rate DESC` so the scoreboard
    /// surfaces the most-trafficked routes first.
    pub fn routing_scoreboard(&self) -> Result<Vec<ScoreboardEntry>> {
        let mut stmt = self.conn.prepare(
            "SELECT task_class, backend, model, provider_pfx,
                    SUM(CASE WHEN outcome='shipped' THEN 1 ELSE 0 END) AS successes,
                    SUM(CASE WHEN outcome='shipped' THEN 0 ELSE 1 END) AS failures,
                    COUNT(*) AS total,
                    MAX(recorded_at) AS last_seen
             FROM routing_outcomes
             GROUP BY task_class, backend, model, provider_pfx
             ORDER BY total DESC, successes DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            let task_class: String = r.get(0)?;
            let backend: String = r.get(1)?;
            let model: String = r.get(2)?;
            let provider_pfx: String = r.get(3)?;
            let successes: i64 = r.get(4)?;
            let failures: i64 = r.get(5)?;
            let total: i64 = r.get(6)?;
            let last_seen: String = r.get::<_, Option<String>>(7)?.unwrap_or_default();
            let success_rate = if total > 0 {
                successes as f64 / total as f64
            } else {
                0.0
            };
            Ok(ScoreboardEntry {
                task_class,
                backend,
                model,
                provider_pfx,
                successes: successes as u64,
                failures: failures as u64,
                total: total as u64,
                success_rate,
                last_seen,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
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

    /// INFRA-143 regression: a malformed gaps.yaml must abort reserve with a
    /// clear error, not silently fall through and risk handing out an ID that
    /// already exists in the YAML the import couldn't read. (Pre-fix: reserve
    /// returned Ok(...) and the binary on 2026-04-27 reserved EVAL-089 right
    /// over an existing PR #558 EVAL-089 row.)
    #[test]
    fn test_reserve_aborts_on_unreadable_yaml() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        std::fs::create_dir_all(repo_root.join("docs")).unwrap();
        // Not valid YAML — `gaps:` should be a list, not a scalar.
        std::fs::write(
            repo_root.join("docs").join("gaps.yaml"),
            "gaps: this is not a list\n",
        )
        .unwrap();
        let store = GapStore::open(&repo_root).unwrap();
        let err = store
            .reserve("INFRA", "new gap", "P1", "s")
            .expect_err("reserve must fail when YAML is unreadable");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("aborted") && msg.contains("ID counter cannot be backfilled"),
            "expected loud-failure message, got: {msg}"
        );
    }

    /// INFRA-070 regression: when docs/gaps.yaml has gaps the DB hasn't
    /// imported, reserve must NOT return an ID that already exists in YAML.
    #[test]
    fn test_reserve_skips_yaml_drift() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        std::fs::create_dir_all(repo_root.join("docs")).unwrap();
        std::fs::write(
            repo_root.join("docs").join("gaps.yaml"),
            "gaps:\n\
             - id: INFRA-005\n  domain: INFRA\n  title: hand-added\n  status: open\n\
             - id: INFRA-042\n  domain: INFRA\n  title: hand-added\n  status: open\n",
        )
        .unwrap();
        let store = GapStore::open(&repo_root).unwrap();
        let id = store.reserve("INFRA", "new gap", "P1", "s").unwrap();
        // Must skip past INFRA-042 — not collide with it or INFRA-005.
        assert_eq!(
            id, "INFRA-043",
            "reserve should skip past YAML max, got {id}"
        );
    }

    #[test]
    fn test_reserve_concurrent() {
        // Spawn 10 threads, each reserving one INFRA gap.
        // All 10 should get distinct IDs with no errors.
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        // Create schema once. Concurrent `migrate()` from many fresh `open()` calls
        // races on empty DB and surfaces "database is locked" on CI (WAL + parallel DDL).
        {
            let _seed = GapStore::open(&repo_root).unwrap();
        }

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

    #[test]
    fn test_ship_stamps_iso_date() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "x", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        store.ship(&id, "s").unwrap();
        let row = store.get(&id).unwrap().expect("row exists");
        assert_eq!(row.status, "done");
        // ISO YYYY-MM-DD, 10 chars, dashes at positions 4 and 7.
        assert_eq!(
            row.closed_date.len(),
            10,
            "closed_date={:?}",
            row.closed_date
        );
        assert_eq!(&row.closed_date[4..5], "-");
        assert_eq!(&row.closed_date[7..8], "-");
    }

    /// Migration backfills closed_date for done rows that predate the column
    /// (originally seen on FLEET-006, DOC-007: closed_at populated, closed_date empty).
    /// Re-opening a store should heal the row in-place; reopening again is a no-op.
    #[test]
    fn test_migrate_backfills_closed_date() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        {
            let store = GapStore::open(&repo_root).unwrap();
            // Insert a synthetic pre-migration row: status=done, closed_at set,
            // closed_date empty. Use a known timestamp (2026-04-26 18:55:22 UTC).
            store
                .conn
                .execute(
                    "INSERT INTO gaps(id,domain,title,status,created_at,closed_at,closed_date)
                     VALUES('LEGACY-001','LEGACY','old','done',?1,?2,'')",
                    params![1_777_180_000_i64, 1_777_180_000_i64],
                )
                .unwrap();
        }
        // Reopen — migrate() should heal the row.
        let store = GapStore::open(&repo_root).unwrap();
        let row = store.get("LEGACY-001").unwrap().expect("row exists");
        assert_eq!(row.closed_date, "2026-04-26", "expected backfilled date");

        // Idempotency: hand-set a different closed_date, reopen, and confirm the
        // backfill leaves it alone (only blank rows get touched).
        store
            .conn
            .execute(
                "UPDATE gaps SET closed_date='2026-04-27' WHERE id='LEGACY-001'",
                [],
            )
            .unwrap();
        drop(store);
        let store = GapStore::open(&repo_root).unwrap();
        let row = store.get("LEGACY-001").unwrap().expect("row exists");
        assert_eq!(row.closed_date, "2026-04-27", "backfill must be idempotent");
    }

    #[test]
    fn test_dump_yaml_round_trip() {
        let (store, _dir) = test_store();
        // Reserve two gaps, populate fields via set_fields.
        let id1 = store.reserve("INFRA", "First gap", "P1", "s").unwrap();
        store
            .set_fields(
                &id1,
                GapFieldUpdate {
                    description: Some("Short description".to_string()),
                    acceptance_criteria: Some(
                        serde_json::to_string(&["AC one", "AC two"]).unwrap(),
                    ),
                    depends_on: Some(serde_json::to_string(&["INFRA-000"]).unwrap()),
                    notes: Some("Note text".to_string()),
                    opened_date: Some("2026-04-25".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        let _id2 = store
            .reserve("EVAL", "Second: with colon", "P1", "s")
            .unwrap();

        // Dump → re-parse → verify gap count and key fields survived.
        let body = store.dump_yaml().unwrap();
        assert!(
            body.starts_with("gaps:\n"),
            "must start with gaps:\\n; got: {:?}",
            &body[..30]
        );
        let parsed: YamlGapsFile = serde_yaml::from_str(&body)
            .unwrap_or_else(|e| panic!("re-parse failed: {e}\n---\n{body}"));
        assert_eq!(parsed.gaps.len(), 2);
        let g1 = parsed
            .gaps
            .iter()
            .find(|g| g.id == id1)
            .expect("id1 present");
        assert_eq!(g1.title, "First gap");
        assert_eq!(g1.description, "Short description");
        assert_eq!(g1.priority, "P1");
        assert_eq!(g1.effort, "s");
        let ac = g1
            .acceptance_criteria
            .as_ref()
            .expect("ac present")
            .as_array()
            .expect("ac is array");
        assert_eq!(ac.len(), 2);
        assert_eq!(ac[0].as_str(), Some("AC one"));
    }

    /// INFRA-147: dump_yaml_with_meta must preserve everything before the
    /// `gaps:` line byte-for-byte (the hand-curated `meta:` block holds CPO
    /// priorities and update_instructions). Bare dump_yaml() drops this.
    #[test]
    fn test_dump_yaml_with_meta_preserves_preamble() {
        let (store, _dir) = test_store();
        let _id = store.reserve("INFRA", "x", "P1", "s").unwrap();

        let source = "\
meta:
  version: '1'
  generated: '2026-04-16'
  current_priorities:
    p0_now:
      - PRODUCT-015
      - PRODUCT-016
gaps:
- id: INFRA-OLD
  title: stale entry
";
        let regenerated = store.dump_yaml_with_meta(source).unwrap();
        // Preamble (everything up to and including the newline before "gaps:")
        // must be byte-identical.
        let expected_preamble = "\
meta:
  version: '1'
  generated: '2026-04-16'
  current_priorities:
    p0_now:
      - PRODUCT-015
      - PRODUCT-016
";
        assert!(
            regenerated.starts_with(expected_preamble),
            "preamble lost; got prefix: {:?}",
            &regenerated[..expected_preamble.len().min(regenerated.len())]
        );
        // gaps: block follows, populated from DB (not from source).
        assert!(regenerated.contains("\ngaps:\n- id: INFRA-001\n"));
        assert!(
            !regenerated.contains("INFRA-OLD"),
            "stale gaps from source must NOT leak through; gaps come from DB"
        );
    }

    /// Empty source (e.g. fresh export to a new file) falls back to bare dump.
    #[test]
    fn test_dump_yaml_with_meta_empty_source_falls_back() {
        let (store, _dir) = test_store();
        let _id = store.reserve("INFRA", "x", "P1", "s").unwrap();
        let regenerated = store.dump_yaml_with_meta("").unwrap();
        assert!(regenerated.starts_with("gaps:\n"));
    }

    #[test]
    fn test_set_fields_clear_and_update() {
        let (store, _dir) = test_store();
        let id = store.reserve("MEM", "Old title", "P1", "s").unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    title: Some("New title".to_string()),
                    notes: Some("Important".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.title, "New title");
        assert_eq!(row.notes, "Important");

        // None means unchanged — title should not revert.
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    notes: Some(String::new()),
                    ..Default::default()
                },
            )
            .unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.title, "New title");
        assert_eq!(row.notes, "");
    }

    // ── COG-036: routing-outcome scoreboard ─────────────────────────────

    fn outcome(
        backend: &str,
        outcome: &str,
        ts: &str,
        pr: Option<u32>,
        task_class: &str,
        model: &str,
    ) -> RoutingOutcomeRow {
        RoutingOutcomeRow {
            recorded_at: ts.into(),
            task_class: task_class.into(),
            priority: "P1".into(),
            effort: "m".into(),
            backend: backend.into(),
            model: model.into(),
            provider_pfx: if model.is_empty() { "" } else { "together" }.into(),
            gap_id: "INFRA-999".into(),
            outcome: outcome.into(),
            pr_number: pr,
            duration_s: 60,
        }
    }

    #[test]
    fn routing_outcomes_record_and_read_back() {
        let (store, _dir) = test_store();
        let row = outcome("claude", "shipped", "2026-04-27T12:00:00Z", Some(7), "", "");
        store.record_routing_outcome(&row).unwrap();
        let board = store.routing_scoreboard().unwrap();
        assert_eq!(board.len(), 1);
        assert_eq!(board[0].backend, "claude");
        assert_eq!(board[0].successes, 1);
        assert_eq!(board[0].failures, 0);
        assert_eq!(board[0].total, 1);
        assert!((board[0].success_rate - 1.0).abs() < f64::EPSILON);
        assert_eq!(board[0].last_seen, "2026-04-27T12:00:00Z");
    }

    #[test]
    fn routing_outcomes_empty_returns_empty_vec() {
        let (store, _dir) = test_store();
        let board = store.routing_scoreboard().unwrap();
        assert!(board.is_empty());
    }

    #[test]
    fn routing_outcomes_aggregates_by_route() {
        let (store, _dir) = test_store();
        // claude/research: 3 ships, 1 stall — 75% success.
        for i in 0..3 {
            store
                .record_routing_outcome(&outcome(
                    "claude",
                    "shipped",
                    &format!("2026-04-27T12:0{i}:00Z"),
                    Some(i + 1),
                    "research",
                    "",
                ))
                .unwrap();
        }
        store
            .record_routing_outcome(&outcome(
                "claude",
                "stalled",
                "2026-04-27T13:00:00Z",
                None,
                "research",
                "",
            ))
            .unwrap();
        // chump-local/research: 1 ship, 1 ci_failed — 50% success.
        store
            .record_routing_outcome(&outcome(
                "chump-local",
                "shipped",
                "2026-04-27T14:00:00Z",
                Some(99),
                "research",
                "qwen",
            ))
            .unwrap();
        store
            .record_routing_outcome(&outcome(
                "chump-local",
                "ci_failed",
                "2026-04-27T15:00:00Z",
                Some(100),
                "research",
                "qwen",
            ))
            .unwrap();

        let board = store.routing_scoreboard().unwrap();
        assert_eq!(board.len(), 2, "two distinct routes");
        // claude/research: 4 total, ships 3 — top of list because total DESC.
        assert_eq!(board[0].backend, "claude");
        assert_eq!(board[0].total, 4);
        assert_eq!(board[0].successes, 3);
        assert_eq!(board[0].failures, 1);
        assert!((board[0].success_rate - 0.75).abs() < 1e-9);
        // chump-local/research: 2 total.
        assert_eq!(board[1].backend, "chump-local");
        assert_eq!(board[1].total, 2);
        assert_eq!(board[1].successes, 1);
        assert_eq!(board[1].failures, 1);
        assert!((board[1].success_rate - 0.5).abs() < 1e-9);
    }

    #[test]
    fn routing_outcomes_writes_are_append_only() {
        let (store, _dir) = test_store();
        // Two writes for the same route should produce two rows that
        // aggregate, not overwrite.
        store
            .record_routing_outcome(&outcome(
                "claude",
                "shipped",
                "2026-04-27T10:00:00Z",
                Some(1),
                "",
                "",
            ))
            .unwrap();
        store
            .record_routing_outcome(&outcome(
                "claude",
                "killed",
                "2026-04-27T11:00:00Z",
                None,
                "",
                "",
            ))
            .unwrap();
        let board = store.routing_scoreboard().unwrap();
        assert_eq!(
            board.len(),
            1,
            "single route (same task_class+backend+model)"
        );
        assert_eq!(board[0].total, 2);
        assert_eq!(board[0].successes, 1);
        assert_eq!(board[0].failures, 1);
        // last_seen reflects the most-recent write.
        assert_eq!(board[0].last_seen, "2026-04-27T11:00:00Z");
    }
}
