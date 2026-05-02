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
    /// PR number from `closed_pr:` in YAML. None if absent or unset.
    /// Pairs with the INFRA-107 closed_pr integrity guard: a gap with
    /// `status: done` MUST have a numeric `closed_pr`. Stored as INTEGER
    /// in SQLite; serialized to YAML only when present and `status: done`.
    /// INFRA-156 added the column + CLI `--closed-pr` flag plumbing.
    #[serde(default)]
    pub closed_pr: Option<i64>,
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
        // INFRA-156: closed_pr (PR number that landed the closure). Nullable
        // because (a) open gaps haven't shipped yet, (b) historical done
        // rows imported before this column existed should keep loading
        // without losing their YAML closed_pr value (round-tripped via
        // import_from_yaml on next regen).
        let _ = self
            .conn
            .execute("ALTER TABLE gaps ADD COLUMN closed_pr INTEGER", []);
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
        // INFRA-112: drop any pre-existing rows with NULL/empty/whitespace id.
        // Such rows survive `INSERT OR IGNORE` (PRIMARY KEY on TEXT permits empty
        // strings in legacy SQLite) but vanish from the YAML mirror because
        // `serde_yaml` round-trips `- id: ` as a list entry whose `id` is null,
        // and downstream consumers (CI guards, gap-preflight) treat that as
        // missing. Cheap one-shot cleanup; the trigger below prevents future
        // regressions.
        let _ = self.conn.execute(
            "DELETE FROM gaps WHERE id IS NULL
               OR LENGTH(REPLACE(REPLACE(REPLACE(REPLACE(id, ' ', ''),
                  char(9), ''), char(10), ''), char(13), '')) = 0",
            [],
        );
        // INFRA-112: trigger-enforced non-empty id. SQLite cannot add CHECK
        // constraints via ALTER TABLE, so we attach BEFORE INSERT/UPDATE
        // triggers that RAISE(ABORT) on empty/whitespace ids. CREATE TRIGGER
        // IF NOT EXISTS makes this idempotent across reopens.
        self.conn.execute_batch(
            "
            CREATE TRIGGER IF NOT EXISTS gaps_id_nonempty_insert
            BEFORE INSERT ON gaps
            FOR EACH ROW
            WHEN NEW.id IS NULL OR LENGTH(REPLACE(REPLACE(REPLACE(REPLACE(NEW.id, ' ', ''), char(9), ''), char(10), ''), char(13), '')) = 0
            BEGIN
                SELECT RAISE(ABORT, 'gap id must be non-empty');
            END;

            CREATE TRIGGER IF NOT EXISTS gaps_id_nonempty_update
            BEFORE UPDATE OF id ON gaps
            FOR EACH ROW
            WHEN NEW.id IS NULL OR LENGTH(REPLACE(REPLACE(REPLACE(REPLACE(NEW.id, ' ', ''), char(9), ''), char(10), ''), char(13), '')) = 0
            BEGIN
                SELECT RAISE(ABORT, 'gap id must be non-empty');
            END;
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
                opened_date: row.get(13)?,
                closed_date: row.get(14)?,
                closed_pr: row.get(15)?,
            })
        };
        if let Some(s) = status_filter {
            let mut stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                        acceptance_criteria,depends_on,notes,source_doc,created_at,closed_at,
                        opened_date,closed_date,closed_pr
                 FROM gaps WHERE status=?1 ORDER BY id",
            )?;
            let rows = stmt.query_map(params![s], make_row)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
        } else {
            let mut stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                        acceptance_criteria,depends_on,notes,source_doc,created_at,closed_at,
                        opened_date,closed_date,closed_pr
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
                    opened_date,closed_date,closed_pr
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
                    closed_pr: row.get(15)?,
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
        if let Some(v) = fields.closed_pr {
            sets.push("closed_pr=?");
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
    ///
    /// Picks an ID free across all four collision sources: state.db (already
    /// in counter logic), docs/gaps.yaml (via [`Self::import_from_yaml`]),
    /// open-PR titles, and live `pending_new_gap` leases on disk. The two
    /// extra sources are gathered by [`Self::external_pending_ids`] and
    /// passed into [`Self::reserve_with_external`]. Together with the
    /// per-domain `flock` in `scripts/coord/gap-reserve.sh`, this prevents
    /// the 4-way INFRA-087..090 collision pattern (PRs #565/#566/#568/#569,
    /// 2026-04-26).
    pub fn reserve(
        &self,
        domain: &str,
        title: &str,
        priority: &str,
        effort: &str,
    ) -> Result<String> {
        let extra = self
            .external_pending_ids(domain)
            .unwrap_or_else(|_| Vec::new());
        self.reserve_with_external(domain, title, priority, effort, &extra)
    }

    /// Same as [`Self::reserve`] but with an explicit list of in-use ID
    /// numbers from sources outside the DB (open PRs, in-flight leases).
    /// Used by tests to inject collision scenarios deterministically without
    /// shelling out to `gh` or fabricating lease files.
    pub fn reserve_with_external(
        &self,
        domain: &str,
        title: &str,
        priority: &str,
        effort: &str,
        extra_used: &[i64],
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
            // INFRA-100: also bump past any IDs that exist in open PRs or
            // pending leases (sources the DB cannot see). The counter must
            // start above the max of (DB max, external max).
            let extra_max = extra_used.iter().copied().max().unwrap_or(0);
            let combined_max = std::cmp::max(existing_max, extra_max);
            self.conn.execute(
                "INSERT INTO gap_counters(domain, next_num) VALUES(?1, ?2)
                 ON CONFLICT(domain) DO UPDATE SET next_num = MAX(next_num, excluded.next_num)",
                params![domain_upper, combined_max + 1],
            )?;
            // INFRA-100: walk past any extra-used IDs that fall above the
            // counter's current value too (defense-in-depth: a stale counter
            // row could be ahead of `existing_max` but behind `extra_max`).
            // Atomic UPDATE with arithmetic ensures concurrent reserves still
            // get distinct numbers.
            for &n in extra_used {
                self.conn.execute(
                    "UPDATE gap_counters SET next_num = MAX(next_num, ?1 + 1) WHERE domain=?2",
                    params![n, domain_upper],
                )?;
            }
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

    /// INFRA-100: gather gap-ID numbers from sources the DB can't see —
    /// `.chump-locks/*.json` `pending_new_gap.id` entries (in-flight reserves
    /// from sibling sessions) and, when `CHUMP_RESERVE_SCAN_OPEN_PRS=1` is
    /// set, open-PR titles via `gh pr list --state open --json title`.
    ///
    /// The PR scan defaults OFF because (a) `scripts/coord/gap-reserve.sh`
    /// already runs `gh pr diff` against open PRs touching docs/gaps.yaml
    /// and (b) shelling out to `gh` is a network/auth dependency that
    /// would slow `cargo test` and break offline runs. Production
    /// invocations through the shell wrapper get full coverage; the env
    /// var lets a future Rust-only path enable it explicitly.
    ///
    /// Stale leases (expired or heartbeat older than 15 min) are skipped —
    /// their pending IDs are unlikely to land and continuing to reserve
    /// past them would inflate the next number indefinitely.
    pub fn external_pending_ids(&self, domain: &str) -> Result<Vec<i64>> {
        let mut out = Vec::new();
        let domain_upper = domain.to_uppercase();
        let prefix = format!("{}-", domain_upper);

        // Lease scan
        let locks_dir = self.repo_root.join(".chump-locks");
        if let Ok(entries) = std::fs::read_dir(&locks_dir) {
            let now = unix_now();
            for ent in entries.flatten() {
                let path = ent.path();
                let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if !name.ends_with(".json") || name.starts_with('.') || name == "ambient.jsonl" {
                    continue;
                }
                let txt = match std::fs::read_to_string(&path) {
                    Ok(t) => t,
                    Err(_) => continue,
                };
                let v: serde_json::Value = match serde_json::from_str(&txt) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                // Skip stale: heartbeat older than 15 min OR expired more than 30 s ago.
                let heartbeat = v
                    .get("heartbeat_at")
                    .and_then(|s| s.as_str())
                    .and_then(parse_iso_to_unix);
                let expires = v
                    .get("expires_at")
                    .and_then(|s| s.as_str())
                    .and_then(parse_iso_to_unix);
                if let Some(h) = heartbeat {
                    if now - h > 900 {
                        continue;
                    }
                }
                if let Some(e) = expires {
                    if now - e > 30 {
                        continue;
                    }
                }
                if let Some(p) = v.get("pending_new_gap").and_then(|p| p.as_object()) {
                    if let Some(id) = p.get("id").and_then(|i| i.as_str()) {
                        if let Some(rest) = id.strip_prefix(&prefix) {
                            if let Ok(n) = rest.parse::<i64>() {
                                out.push(n);
                            }
                        }
                    }
                }
            }
        }

        // Open-PR scan (INFRA-100: default ON since 2026-05-02). On 2026-05-01
        // we shipped 8 collision pairs (INFRA-202..215 cluster) because this
        // scan was opt-in via CHUMP_RESERVE_SCAN_OPEN_PRS=1 and nobody had it
        // enabled. Open-PR titles are the most direct evidence of "an ID is
        // already claimed by a sibling session about to push" — there's no
        // good reason to default it off. Opt out via CHUMP_RESERVE_SCAN_OPEN_PRS=0
        // for offline / no-gh-CLI scenarios.
        //
        // Network failure is non-fatal: print a one-line warning and continue
        // with lease+DB+YAML coverage. Bricking reserve on a flaky network
        // would be worse than tolerating a slightly higher residual race risk.
        if std::env::var("CHUMP_RESERVE_SCAN_OPEN_PRS").as_deref() != Ok("0") {
            match list_open_pr_titles() {
                Ok(pr_titles) => {
                    let pat = regex_lite_for_domain(&domain_upper);
                    for title in pr_titles {
                        for n in pat.find_numbers(&title) {
                            out.push(n);
                        }
                    }
                }
                Err(e) => {
                    eprintln!(
                        "[gap reserve] WARN: open-PR scan failed ({e}). Continuing \
                         with lease+DB coverage only — slight collision risk against \
                         in-flight PRs from sibling sessions. Set \
                         CHUMP_RESERVE_SCAN_OPEN_PRS=0 to silence."
                    );
                }
            }
        }

        Ok(out)
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
    /// `closed_date` (ISO yyyy-mm-dd, matching YAML convention). When
    /// `closed_pr` is `Some(n)`, also sets the closed_pr column — this
    /// is what the INFRA-107 closed_pr integrity guard requires for any
    /// status:done flip in YAML, so passing it here keeps the canonical
    /// state.db and the YAML mirror in agreement (INFRA-156).
    pub fn ship(&self, gap_id: &str, session_id: &str, closed_pr: Option<i64>) -> Result<()> {
        let now = unix_now();
        let iso = unix_to_iso_date(now);
        let changed = if let Some(pr) = closed_pr {
            self.conn.execute(
                "UPDATE gaps SET status='done', closed_at=?1, closed_date=?2, closed_pr=?3
                 WHERE id=?4 AND status='open'",
                params![now, iso, pr, gap_id],
            )?
        } else {
            self.conn.execute(
                "UPDATE gaps SET status='done', closed_at=?1, closed_date=?2
                 WHERE id=?3 AND status='open'",
                params![now, iso, gap_id],
            )?
        };
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
        // INFRA-112: self-validating round-trip — re-parse what we just emitted
        // and confirm the entry count matches the source. Catches future
        // regressions in `format_gap_yaml` (e.g. an emitter change that drops a
        // row when a field contains an unescaped colon) or in the upstream YAML
        // parser. Cheap: parses ~half a megabyte once per dump.
        let parsed: YamlGapsFile = serde_yaml::from_str(&out)
            .with_context(|| "dump_yaml emitted YAML that fails to parse")?;
        if parsed.gaps.len() != gaps.len() {
            bail!(
                "dump_yaml is lossy: DB has {} gaps, YAML round-trip has {} \
                 (delta={}). Likely cause: a row with an empty/whitespace id \
                 or a field that breaks YAML scalar quoting.",
                gaps.len(),
                parsed.gaps.len(),
                gaps.len() as i64 - parsed.gaps.len() as i64,
            );
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

    /// INFRA-188 v0 (2026-05-02): dump every gap as a SEPARATE YAML file at
    /// `<out_dir>/<ID>.yaml`. Each file contains a single block-list entry
    /// in the same format as `dump_yaml` produces — i.e.
    /// `- id: INFRA-180\n  domain: ...\n` — so reaggregating into the
    /// legacy monolithic `docs/gaps.yaml` is just
    /// `(echo "gaps:"; cat <out_dir>/*.yaml) > docs/gaps.yaml`.
    ///
    /// Returns `(written, skipped)`. Skipped means the existing file's
    /// content was byte-identical, so no write happened (file mtime
    /// stable for INFRA-148 staleness checks). Creates `out_dir` if
    /// missing.
    ///
    /// This v0 ONLY writes files. The full INFRA-188 cutover (remove
    /// monolithic gaps.yaml, update 5 pre-commit guards to read directory,
    /// update 3 coord scripts, update 2 GitHub workflows, add the CI guard
    /// against re-adding monolithic) is the follow-up work tracked in
    /// INFRA-188 itself. Both layouts coexist until cutover.
    pub fn dump_per_file(&self, out_dir: &std::path::Path) -> Result<(usize, usize)> {
        let gaps = self.list(None)?;
        std::fs::create_dir_all(out_dir)
            .with_context(|| format!("creating {}", out_dir.display()))?;

        let mut written = 0usize;
        let mut skipped = 0usize;
        for g in &gaps {
            if g.id.trim().is_empty() {
                continue; // defense against any INFRA-112-class empty-id rows
            }
            let path = out_dir.join(format!("{}.yaml", g.id));
            let content = format_gap_yaml(g);
            let needs_write = match std::fs::read_to_string(&path) {
                Ok(existing) => existing != content,
                Err(_) => true,
            };
            if needs_write {
                std::fs::write(&path, &content)
                    .with_context(|| format!("writing {}", path.display()))?;
                written += 1;
            } else {
                skipped += 1;
            }
        }
        Ok((written, skipped))
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
    /// PR number for closure (INFRA-156). `None` leaves the column unchanged;
    /// pass `Some(n)` to set or update. Pairs with `--closed-pr` on
    /// `chump gap set` and `chump gap ship`.
    pub closed_pr: Option<i64>,
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
    // INFRA-156: emit closed_pr as an integer when set. Position right after
    // closed_date matches the prevailing convention in docs/gaps.yaml. The
    // INFRA-107 integrity guard rejects status:done without a numeric
    // closed_pr, so closure PRs that go through `chump gap ship --closed-pr N`
    // produce a YAML diff this guard accepts.
    if let Some(pr) = g.closed_pr {
        s.push_str(&format!("  closed_pr: {}\n", pr));
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
    /// INFRA-156: PR number that landed the closure. YAML may carry this as
    /// a bare integer (`closed_pr: 598`) or, in legacy files, as a string —
    /// we accept both via `serde_yaml::Value` and coerce in
    /// `import_from_yaml`.
    #[serde(default)]
    closed_pr: Option<serde_yaml::Value>,
}

#[derive(Deserialize)]
struct YamlGapsFile {
    #[serde(default)]
    gaps: Vec<YamlGap>,
}

impl GapStore {
    /// Import from the gap registry into the DB. Idempotent — existing rows are skipped.
    ///
    /// INFRA-188: reads from per-file `docs/gaps/*.yaml` directory if it exists,
    /// otherwise falls back to monolithic `docs/gaps.yaml`. Both layouts are
    /// accepted for backward compatibility during the transition period.
    ///
    /// Missing-file/directory is treated as a no-op (returns `Ok((0, 0))`) so
    /// fresh tempdir callers and bootstrap paths don't have to special-case it.
    /// A YAML file that *exists* but is unreadable / malformed propagates the
    /// error so callers like `reserve()` can fail loud (INFRA-143).
    pub fn import_from_yaml(&self, repo_root: &Path) -> Result<(usize, usize)> {
        // INFRA-188: prefer per-file directory if it exists and is non-empty.
        let per_file_dir = repo_root.join("docs").join("gaps");
        let text = if per_file_dir.is_dir() {
            // Aggregate all per-file YAML into one monolithic string.
            let mut parts = Vec::new();
            let mut dir_entries: Vec<_> = std::fs::read_dir(&per_file_dir)
                .with_context(|| format!("reading {}", per_file_dir.display()))?
                .flatten()
                .filter(|e| {
                    e.path()
                        .extension()
                        .and_then(|s| s.to_str())
                        .map(|s| s == "yaml")
                        .unwrap_or(false)
                })
                .collect();
            dir_entries.sort_by_key(|e| e.file_name());
            for entry in &dir_entries {
                let content = std::fs::read_to_string(entry.path())
                    .with_context(|| format!("reading {}", entry.path().display()))?;
                parts.push(content);
            }
            if parts.is_empty() {
                // Empty directory — fall through to monolithic check
                let yaml_path = repo_root.join("docs").join("gaps.yaml");
                match std::fs::read_to_string(&yaml_path) {
                    Ok(t) => t,
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((0, 0)),
                    Err(e) => {
                        return Err(anyhow::Error::from(e))
                            .with_context(|| format!("reading {}", yaml_path.display()));
                    }
                }
            } else {
                // Wrap entries as a monolithic `gaps:` list for uniform parsing.
                format!("gaps:\n{}", parts.join(""))
            }
        } else {
            let yaml_path = repo_root.join("docs").join("gaps.yaml");
            match std::fs::read_to_string(&yaml_path) {
                Ok(t) => t,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((0, 0)),
                Err(e) => {
                    return Err(anyhow::Error::from(e))
                        .with_context(|| format!("reading {}", yaml_path.display()));
                }
            }
        };
        let file: YamlGapsFile = serde_yaml::from_str(&text)
            .with_context(|| "parsing gap registry (per-file or monolithic)")?;

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
            // INFRA-156: coerce closed_pr to Option<i64>. YAML integers come
            // through as serde_yaml::Value::Number; legacy `TBD` strings (now
            // blocked at commit by the INFRA-107 guard) are rejected as None
            // rather than fabricated to a number.
            let closed_pr = g.closed_pr.as_ref().and_then(yaml_value_to_i64);
            let created_at = unix_now();

            let changed = self.conn.execute(
                "INSERT OR IGNORE INTO gaps(id,domain,title,description,priority,effort,status,
                    acceptance_criteria,depends_on,notes,source_doc,created_at,
                    opened_date,closed_date,closed_pr)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
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
                    closed_pr,
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

/// INFRA-100: parse `2026-04-28T22:30:00Z` style ISO-8601 (lease files use
/// this) into a unix timestamp. Returns None on parse failure rather than
/// panicking — leases that don't carry a heartbeat / expiry are simply not
/// staleness-checked. Implementation is a tiny zero-dep parser since chrono
/// isn't already in this crate's hot path and we don't need the full feature
/// set; just yyyy-mm-ddThh:mm:ssZ.
fn parse_iso_to_unix(s: &str) -> Option<i64> {
    let bytes = s.as_bytes();
    if bytes.len() < 19 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    let year: i64 = std::str::from_utf8(&bytes[0..4]).ok()?.parse().ok()?;
    let month: u32 = std::str::from_utf8(&bytes[5..7]).ok()?.parse().ok()?;
    let day: u32 = std::str::from_utf8(&bytes[8..10]).ok()?.parse().ok()?;
    let hour: u32 = std::str::from_utf8(&bytes[11..13]).ok()?.parse().ok()?;
    let minute: u32 = std::str::from_utf8(&bytes[14..16]).ok()?.parse().ok()?;
    let second: u32 = std::str::from_utf8(&bytes[17..19]).ok()?.parse().ok()?;
    // Days-since-epoch via the standard cumulative-days-per-month dance,
    // adjusted for leap years. Sufficient precision for 15-min staleness checks.
    let is_leap = |y: i64| (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let mut days: i64 = 0;
    for y in 1970..year {
        days += if is_leap(y) { 366 } else { 365 };
    }
    let dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for m in 1..month {
        days += dim[(m - 1) as usize] as i64;
        if m == 2 && is_leap(year) {
            days += 1;
        }
    }
    days += day as i64 - 1;
    Some(days * 86400 + hour as i64 * 3600 + minute as i64 * 60 + second as i64)
}

/// INFRA-100: shell out to `gh pr list --state open --json title --jq '.[].title'`
/// and return the titles. Returns Err on any failure (gh missing, no auth,
/// network down) so the caller can degrade gracefully.
fn list_open_pr_titles() -> Result<Vec<String>> {
    let output = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--json",
            "title",
            "--jq",
            ".[].title",
            "--limit",
            "200",
        ])
        .output()
        .with_context(|| "spawning gh pr list")?;
    if !output.status.success() {
        bail!(
            "gh pr list failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.to_string())
        .collect())
}

/// INFRA-100: lightweight matcher for `<DOMAIN>-NNN` substrings in a string.
/// Avoids pulling in the `regex` crate just for this since it's not already
/// a dep of chump's bin target. Domain is uppercase; NNN is one-or-more
/// digits (we want to catch zero-padded `INFRA-080` *and* unpadded `INFRA-9`).
struct DomainPattern {
    prefix: String,
}
impl DomainPattern {
    fn find_numbers(&self, hay: &str) -> Vec<i64> {
        let mut out = Vec::new();
        let mut idx = 0;
        let bytes = hay.as_bytes();
        while let Some(rel) = hay[idx..].find(&self.prefix) {
            let start = idx + rel + self.prefix.len();
            // Boundary: char before prefix should be non-alphanumeric or BOL.
            let pre_ok = idx + rel == 0 || {
                let b = bytes[idx + rel - 1];
                !(b.is_ascii_alphanumeric())
            };
            if !pre_ok {
                idx = start;
                continue;
            }
            // Read digits.
            let mut end = start;
            while end < bytes.len() && bytes[end].is_ascii_digit() {
                end += 1;
            }
            if end > start {
                if let Ok(n) = hay[start..end].parse::<i64>() {
                    out.push(n);
                }
            }
            idx = if end == start { start + 1 } else { end };
        }
        out
    }
}
fn regex_lite_for_domain(domain_upper: &str) -> DomainPattern {
    DomainPattern {
        prefix: format!("{}-", domain_upper),
    }
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
    // INFRA-112: normalize trailing newlines before splitting. YAML's bare
    // `|` block scalar preserves a single final `\n`, so a dump → re-parse
    // cycle silently appends `\n` to the stored value. Without normalization
    // here, the next emit splits on that trailing `\n` into a phantom empty
    // line and renders an indented blank, breaking byte-stable round-trip
    // (test_dump_yaml_byte_stable_round_trip). Trimming at emit time keeps
    // the existing visual format (bare `|`, no `|-` suffix everywhere) and
    // makes the first dump and every subsequent re-dump produce identical
    // bytes regardless of how many round-trips the value has been through.
    let trimmed = s.trim_end_matches('\n');
    let mut out = String::from("|\n");
    for line in trimmed.split('\n') {
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

/// INFRA-156: Convert a YAML value to `Option<i64>` for `closed_pr`. Accepts
/// numeric YAML scalars (`closed_pr: 598`) and numeric strings; everything
/// else (TBD, null, missing) becomes `None`. The INFRA-107 commit-time
/// guard rejects non-numeric closed_pr values, so a clean import shouldn't
/// see strings here — but we coerce defensively rather than crash if a
/// pre-guard YAML is being re-imported on a fresh DB.
fn yaml_value_to_i64(v: &serde_yaml::Value) -> Option<i64> {
    match v {
        serde_yaml::Value::Number(n) => n.as_i64(),
        serde_yaml::Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
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
        // INFRA-100: open-PR scan is default-ON in production but tests must
        // not hit the live `gh pr list` (would pick up real PR titles like
        // INFRA-200, INFRA-222 and pollute the deterministic fixtures).
        // Set the opt-out for the duration of every test that uses this
        // helper. SAFETY: tests in this file share the same process so an
        // env-var set is visible across them — that's exactly what we want
        // because every test in this module operates on synthetic fixtures.
        unsafe {
            std::env::set_var("CHUMP_RESERVE_SCAN_OPEN_PRS", "0");
        }
        let dir = TempDir::new().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        (store, dir)
    }

    // ── INFRA-100: cross-source picker tests ──────────────────────────

    #[test]
    fn reserve_with_external_bumps_past_open_pr_collisions() {
        // Reproduces the INFRA-087..090 4-way collision pattern: 4 sibling
        // sessions each have an in-flight ID for the same domain. The DB
        // counter only knows about its own row, but reserve() must not
        // hand back any of {87, 88, 89, 90} — should jump to 91.
        let (store, _dir) = test_store();
        // Seed the DB with one existing INFRA-086 so existing_max=86.
        store.reserve("INFRA", "first", "P2", "s").unwrap();
        // Manually set the DB's counter to next=87 (matches sibling reality:
        // siblings each reserved 87..90 but those rows aren't in *this* DB).
        store
            .conn
            .execute(
                "INSERT OR REPLACE INTO gaps(id,domain,title,priority,effort,status,created_at)
             VALUES('INFRA-086','INFRA','seed','P2','s','open',?1)",
                params![unix_now()],
            )
            .unwrap();
        // Reserve with external IDs claimed by siblings.
        let extras = vec![87i64, 88, 89, 90];
        let id = store
            .reserve_with_external("INFRA", "mine", "P1", "s", &extras)
            .unwrap();
        assert!(
            !extras.iter().any(|n| id == format!("INFRA-{:03}", n)),
            "reserve picked a collision: {id} (extras: {extras:?})"
        );
        // Specifically: should be the next free above 90 (since DB has 086
        // pre-existing and externals are 87..90, first free is 91).
        assert_eq!(id, "INFRA-091", "expected INFRA-091, got {id}");
    }

    #[test]
    fn external_pending_ids_reads_lease_files() {
        let (store, dir) = test_store();
        // Write a fresh lease with a pending_new_gap.
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let now = unix_now();
        let exp = now + 3600;
        let now_iso = chrono_like_iso(now).to_string();
        let exp_iso = chrono_like_iso(exp).to_string();
        let lease = serde_json::json!({
            "session_id": "test-session",
            "pending_new_gap": { "id": "INFRA-099", "title": "x", "domain": "INFRA" },
            "heartbeat_at": now_iso,
            "expires_at": exp_iso,
        });
        std::fs::write(
            locks.join("test-session.json"),
            serde_json::to_string(&lease).unwrap(),
        )
        .unwrap();
        let ids = store.external_pending_ids("INFRA").unwrap();
        assert!(ids.contains(&99), "expected 99 in {ids:?}");
    }

    #[test]
    fn external_pending_ids_skips_stale_lease() {
        let (store, dir) = test_store();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // Heartbeat 30 minutes ago — past the 15-minute staleness window.
        let stale = unix_now() - 30 * 60;
        let stale_iso = chrono_like_iso(stale);
        let exp_iso = chrono_like_iso(stale + 3600);
        let lease = serde_json::json!({
            "session_id": "stale-session",
            "pending_new_gap": { "id": "INFRA-200", "title": "stale", "domain": "INFRA" },
            "heartbeat_at": stale_iso,
            "expires_at": exp_iso,
        });
        std::fs::write(
            locks.join("stale-session.json"),
            serde_json::to_string(&lease).unwrap(),
        )
        .unwrap();
        let ids = store.external_pending_ids("INFRA").unwrap();
        assert!(
            !ids.contains(&200),
            "stale lease should be skipped: {ids:?}"
        );
    }

    #[test]
    fn domain_pattern_finds_padded_and_unpadded_ids() {
        let pat = regex_lite_for_domain("INFRA");
        let titles =
            "INFRA-100: foo, INFRA-99: bar, INFRA-080 baz, EVAL-100 (skip), prefixINFRA-7 (skip)";
        let nums = pat.find_numbers(titles);
        assert!(nums.contains(&100));
        assert!(nums.contains(&99));
        assert!(nums.contains(&80));
        // Reject non-boundary matches.
        assert!(
            !nums.contains(&7),
            "should reject prefixINFRA-7 (no word boundary): {nums:?}"
        );
    }

    #[test]
    fn parse_iso_to_unix_handles_z_suffix() {
        // 2026-04-28T22:30:00Z = 1777629000
        let ts = parse_iso_to_unix("2026-04-28T22:30:00Z").unwrap();
        // Sanity: value should be in 2026 range (>= 2026-01-01, < 2027-01-01).
        let jan1 = parse_iso_to_unix("2026-01-01T00:00:00Z").unwrap();
        let jan1_next = parse_iso_to_unix("2027-01-01T00:00:00Z").unwrap();
        assert!(ts > jan1 && ts < jan1_next, "ts={ts} jan1={jan1}");
    }

    /// Tiny helper: format a unix ts as `YYYY-MM-DDTHH:MM:SSZ` without
    /// pulling chrono. Round-trips with `parse_iso_to_unix` for tests.
    fn chrono_like_iso(ts: i64) -> String {
        let mut secs = ts;
        let s = secs.rem_euclid(60);
        secs = secs.div_euclid(60);
        let m = secs.rem_euclid(60);
        secs = secs.div_euclid(60);
        let h = secs.rem_euclid(24);
        let mut days = secs.div_euclid(24);
        let mut year = 1970i64;
        let is_leap = |y: i64| (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        loop {
            let dy = if is_leap(year) { 366 } else { 365 };
            if days < dy {
                break;
            }
            days -= dy;
            year += 1;
        }
        let dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        let mut month = 1u32;
        for (i, d) in dim.iter().enumerate() {
            let mut dd = *d as i64;
            if i == 1 && is_leap(year) {
                dd += 1;
            }
            if days < dd {
                month = (i + 1) as u32;
                break;
            }
            days -= dd;
        }
        let day = days + 1;
        format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
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
        store.ship(&id, "session-xyz", None).unwrap();

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
        store.ship(&id2, "s", None).unwrap();

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
        store.ship(&id, "s", None).unwrap();
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

    /// INFRA-112: empty/whitespace gap ids must be rejected at the SQL layer
    /// so they can never enter the store via `INSERT OR IGNORE` paths
    /// (`import_from_yaml`, hand-issued sqlite3, future codepaths). Without
    /// the trigger, such rows survive in the DB but vanish from the YAML
    /// mirror — silently shrinking the visible gap registry.
    #[test]
    fn test_migrate_rejects_empty_id_at_insert() {
        let (store, _dir) = test_store();
        for bad in ["", "   ", "\t", "\n"] {
            let r = store.conn.execute(
                "INSERT INTO gaps(id,domain,title,status,created_at)
                 VALUES(?1,'INFRA','x','open',0)",
                params![bad],
            );
            assert!(r.is_err(), "trigger must reject id={:?}", bad);
        }
        let r = store.conn.execute(
            "INSERT OR IGNORE INTO gaps(id,domain,title,status,created_at)
             VALUES('','INFRA','x','open',0)",
            [],
        );
        assert!(
            r.is_err(),
            "trigger must reject empty id even with OR IGNORE"
        );
    }

    /// INFRA-112: pre-existing empty-id rows (from before the trigger) must
    /// be cleaned up on reopen, and dump_yaml's self-validation must see the
    /// DB and YAML counts agree afterward.
    #[test]
    fn test_migrate_cleans_existing_empty_id_rows_and_dump_self_validates() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        {
            let store = GapStore::open(&repo_root).unwrap();
            // Drop the trigger, insert a bad row, then close. Simulates a DB
            // written by an older binary that lacked the constraint.
            store
                .conn
                .execute_batch("DROP TRIGGER IF EXISTS gaps_id_nonempty_insert;")
                .unwrap();
            store
                .conn
                .execute(
                    "INSERT INTO gaps(id,domain,title,status,created_at)
                     VALUES('','INFRA','orphan','open',0)",
                    [],
                )
                .unwrap();
            store
                .conn
                .execute(
                    "INSERT INTO gaps(id,domain,title,status,created_at)
                     VALUES('GOOD-001','INFRA','keeper','open',0)",
                    [],
                )
                .unwrap();
        }
        // Reopen — migrate() must DELETE the empty-id row and recreate the
        // trigger. dump_yaml then self-validates round-trip count.
        let store = GapStore::open(&repo_root).unwrap();
        let count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM gaps", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1, "empty-id row must be cleaned up on reopen");
        let yaml = store
            .dump_yaml()
            .expect("dump_yaml must succeed and self-validate after cleanup");
        assert!(yaml.contains("GOOD-001"));
        assert!(
            !yaml.contains("\n- id: \n"),
            "no empty-id list entry should remain"
        );
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

    /// INFRA-112 (acceptance #4): byte-stable round-trip — dump → fresh DB →
    /// import that dump → dump again. Both YAML strings must be byte-equal.
    /// Catches non-determinism in the emitter (HashMap iteration order,
    /// timestamp drift, locale-dependent formatting) that count- and
    /// field-equality tests miss. The earlier test_dump_yaml_round_trip
    /// proves the dump is *parseable*; this proves it is *idempotent*.
    #[test]
    fn test_dump_yaml_byte_stable_round_trip() {
        // Seed store A with a representative variety of fields.
        let (store_a, _dir_a) = test_store();
        let id1 = store_a.reserve("INFRA", "First gap", "P1", "s").unwrap();
        store_a
            .set_fields(
                &id1,
                GapFieldUpdate {
                    description: Some("Multi-line\ndescription with: a colon".to_string()),
                    acceptance_criteria: Some(
                        serde_json::to_string(&["AC one", "AC two: with colon"]).unwrap(),
                    ),
                    depends_on: Some(serde_json::to_string(&["INFRA-000", "EVAL-001"]).unwrap()),
                    notes: Some("Note text\nwith newline".to_string()),
                    source_doc: Some("docs/process/foo.md".to_string()),
                    opened_date: Some("2026-04-25".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        let id2 = store_a
            .reserve("EVAL", "Second: with colon in title", "P0", "m")
            .unwrap();
        store_a
            .set_fields(
                &id2,
                GapFieldUpdate {
                    description: Some("Plain description".to_string()),
                    status: Some("done".to_string()),
                    closed_date: Some("2026-04-26".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        let _ = store_a.reserve("META", "Minimal gap", "P2", "xs").unwrap();

        let dump1 = store_a.dump_yaml().expect("dump A");

        // Import into a fresh DB and dump again. The two YAML strings must
        // be byte-equal — any drift indicates the emitter is non-deterministic
        // or the importer mutates fields it should preserve.
        let dir_b = TempDir::new().unwrap();
        let store_b = GapStore::open(dir_b.path()).unwrap();
        // import_from_yaml takes the *repo root* and reads docs/gaps.yaml
        // beneath it. Stage dump1 at that conventional path.
        let yaml_path = dir_b.path().join("docs").join("gaps.yaml");
        std::fs::create_dir_all(yaml_path.parent().unwrap()).unwrap();
        std::fs::write(&yaml_path, &dump1).unwrap();
        store_b
            .import_from_yaml(dir_b.path())
            .expect("import dump1 into store B");

        let dump2 = store_b.dump_yaml().expect("dump B");

        assert_eq!(
            dump1,
            dump2,
            "dump → import → dump must be byte-stable; emitter is non-deterministic\n\
             --- first dump ({} bytes) ---\n{}\n--- second dump ({} bytes) ---\n{}",
            dump1.len(),
            dump1,
            dump2.len(),
            dump2,
        );
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

    /// INFRA-188 v0: dump_per_file emits one file per gap; reaggregating
    /// with `cat` produces the same content as the monolithic dump_yaml
    /// (modulo the leading `gaps:\n`).
    #[test]
    fn test_dump_per_file_writes_one_file_per_gap() {
        let (store, dir) = test_store();
        let id1 = store.reserve("INFRA", "first", "P1", "s").unwrap();
        let id2 = store.reserve("EVAL", "second", "P0", "m").unwrap();
        let _id3 = store.reserve("META", "third", "P2", "xs").unwrap();

        let out_dir = dir.path().join("docs/gaps");
        let (written, skipped) = store.dump_per_file(&out_dir).unwrap();

        assert_eq!(written, 3, "expected 3 files written");
        assert_eq!(skipped, 0, "no files should be skipped on first run");

        // Each file exists at <ID>.yaml and contains the gap's id
        for id in &[&id1, &id2] {
            let path = out_dir.join(format!("{}.yaml", id));
            assert!(path.exists(), "file {} missing", path.display());
            let content = std::fs::read_to_string(&path).unwrap();
            assert!(
                content.contains(&format!("- id: {}", id)),
                "file should contain id line; got: {content}"
            );
        }

        // Idempotency: a second dump with no DB changes should write 0 files
        // (all skipped because byte-identical).
        let (written2, skipped2) = store.dump_per_file(&out_dir).unwrap();
        assert_eq!(written2, 0, "second dump should write 0 files");
        assert_eq!(skipped2, 3, "second dump should skip all 3");
    }

    /// INFRA-188 v0: per-file dump's content is byte-equal to what the
    /// monolithic dump produces for the same gap. Roundtrip: dump_yaml
    /// with all gaps  ==  "gaps:\n" + cat(per-file files).
    #[test]
    fn test_dump_per_file_reaggregates_to_monolithic() {
        let (store, dir) = test_store();
        let _id1 = store.reserve("INFRA", "alpha", "P1", "s").unwrap();
        let _id2 = store
            .reserve("EVAL", "beta with: a colon", "P0", "m")
            .unwrap();

        let out_dir = dir.path().join("docs/gaps");
        store.dump_per_file(&out_dir).unwrap();

        // Reaggregate
        let mut entries: Vec<_> = std::fs::read_dir(&out_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .collect();
        entries.sort();
        let mut reagg = String::from("gaps:\n");
        for p in &entries {
            reagg.push_str(&std::fs::read_to_string(p).unwrap());
        }

        // Compare against monolithic dump
        let mono = store.dump_yaml().unwrap();
        assert_eq!(
            reagg.trim_end(),
            mono.trim_end(),
            "reaggregated per-file output should byte-equal monolithic dump"
        );
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

    // ── INFRA-156: closed_pr round-trip ─────────────────────────────────

    #[test]
    fn test_set_closed_pr_persists_and_emits_to_yaml() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "x", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        // First close via set_fields (the `chump gap set --closed-pr` path).
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_date: Some("2026-04-28".into()),
                    closed_pr: Some(598),
                    ..Default::default()
                },
            )
            .unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.status, "done");
        assert_eq!(row.closed_pr, Some(598));
        // YAML emit must include the integer scalar (no quotes, no TBD).
        let yaml = store.dump_yaml().unwrap();
        assert!(
            yaml.contains("  closed_pr: 598\n"),
            "yaml missing closed_pr line: {}",
            yaml
        );
    }

    #[test]
    fn test_ship_with_closed_pr_stamps_pr_number() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "y", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        // The `chump gap ship --closed-pr N` path: ship() takes the option
        // directly so callers don't have to do a follow-up set_fields call.
        store.ship(&id, "s", Some(631)).unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.status, "done");
        assert_eq!(row.closed_pr, Some(631));
        // ship() without a closed_pr (legacy callers) must leave it None.
        let id2 = store.reserve("INFRA", "z", "P1", "s").unwrap();
        store.claim(&id2, "s", "/wt", 3600).unwrap();
        store.ship(&id2, "s", None).unwrap();
        let row2 = store.get(&id2).unwrap().expect("row");
        assert_eq!(row2.status, "done");
        assert_eq!(row2.closed_pr, None);
    }

    #[test]
    fn test_yaml_import_coerces_closed_pr_integer() {
        // Round-trip: dump → re-import should preserve closed_pr through the
        // YAML mirror without losing the value or fabricating a string.
        let (store, dir) = test_store();
        let id = store.reserve("INFRA", "import test", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        store.ship(&id, "s", Some(598)).unwrap();
        let yaml = store.dump_yaml().unwrap();
        // Persist YAML and re-import into a fresh store rooted at the same dir.
        let yaml_dir = dir.path().join("docs");
        std::fs::create_dir_all(&yaml_dir).unwrap();
        std::fs::write(yaml_dir.join("gaps.yaml"), &yaml).unwrap();
        let store2 = GapStore::open(dir.path()).unwrap();
        // Existing row already in DB; round-trip via a deleted+reimported row
        // is the more interesting test — drop it and re-import.
        store2
            .conn
            .execute("DELETE FROM gaps WHERE id=?1", params![id])
            .unwrap();
        let (ins, _skip) = store2.import_from_yaml(dir.path()).unwrap();
        assert!(ins >= 1, "expected at least one inserted row, got {}", ins);
        let reimported = store2.get(&id).unwrap().expect("row reimported");
        assert_eq!(reimported.closed_pr, Some(598));
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
