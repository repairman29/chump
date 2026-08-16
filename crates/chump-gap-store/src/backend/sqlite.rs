//! SQLite implementation of [`super::GapBackend`] — the local-dev default.

use super::GapBackend;
use crate::GapRow;
use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::Mutex;

pub struct SqliteBackend {
    conn: Mutex<Connection>,
}

impl SqliteBackend {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating parent dir for {}", path.display()))?;
        }
        let conn = Connection::open(path)
            .with_context(|| format!("opening sqlite backend at {}", path.display()))?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        let backend = Self {
            conn: Mutex::new(conn),
        };
        backend.init_schema()?;
        Ok(backend)
    }
}

impl GapBackend for SqliteBackend {
    fn init_schema(&self) -> Result<()> {
        let conn = self.conn.lock().expect("sqlite backend mutex poisoned");
        conn.execute_batch(
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
                closed_at           INTEGER,
                opened_date         TEXT NOT NULL DEFAULT '',
                closed_date         TEXT NOT NULL DEFAULT '',
                closed_pr           INTEGER,
                skills_required     TEXT NOT NULL DEFAULT '',
                preferred_backend   TEXT NOT NULL DEFAULT 'any',
                preferred_machine   TEXT NOT NULL DEFAULT 'any',
                estimated_minutes   TEXT NOT NULL DEFAULT '',
                required_model      TEXT NOT NULL DEFAULT 'any',
                shipped_in          TEXT,
                outcome_id          TEXT,
                evidence            TEXT
            );
            CREATE INDEX IF NOT EXISTS gaps_status ON gaps(status);
            ",
        )
        .context("init_schema: create gaps table")?;
        Ok(())
    }

    fn upsert_gap(&self, gap: &GapRow) -> Result<()> {
        let conn = self.conn.lock().expect("sqlite backend mutex poisoned");
        conn.execute(
            "INSERT INTO gaps (
                id, domain, title, description, priority, effort, status,
                acceptance_criteria, depends_on, notes, source_doc, created_at,
                closed_at, opened_date, closed_date, closed_pr, skills_required,
                preferred_backend, preferred_machine, estimated_minutes,
                required_model, shipped_in, outcome_id, evidence
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24
            )
            ON CONFLICT(id) DO UPDATE SET
                domain=excluded.domain, title=excluded.title,
                description=excluded.description, priority=excluded.priority,
                effort=excluded.effort, status=excluded.status,
                acceptance_criteria=excluded.acceptance_criteria,
                depends_on=excluded.depends_on, notes=excluded.notes,
                source_doc=excluded.source_doc, created_at=excluded.created_at,
                closed_at=excluded.closed_at, opened_date=excluded.opened_date,
                closed_date=excluded.closed_date, closed_pr=excluded.closed_pr,
                skills_required=excluded.skills_required,
                preferred_backend=excluded.preferred_backend,
                preferred_machine=excluded.preferred_machine,
                estimated_minutes=excluded.estimated_minutes,
                required_model=excluded.required_model,
                shipped_in=excluded.shipped_in, outcome_id=excluded.outcome_id,
                evidence=excluded.evidence",
            params![
                gap.id,
                gap.domain,
                gap.title,
                gap.description,
                gap.priority,
                gap.effort,
                gap.status,
                gap.acceptance_criteria,
                gap.depends_on,
                gap.notes,
                gap.source_doc,
                gap.created_at,
                gap.closed_at,
                gap.opened_date,
                gap.closed_date,
                gap.closed_pr,
                gap.skills_required,
                gap.preferred_backend,
                gap.preferred_machine,
                gap.estimated_minutes,
                gap.required_model,
                gap.shipped_in,
                gap.outcome_id,
                gap.evidence,
            ],
        )
        .context("upsert_gap")?;
        Ok(())
    }

    fn get_gap(&self, id: &str) -> Result<Option<GapRow>> {
        let conn = self.conn.lock().expect("sqlite backend mutex poisoned");
        let mut stmt = conn.prepare(
            "SELECT id, domain, title, description, priority, effort, status,
                    acceptance_criteria, depends_on, notes, source_doc, created_at,
                    closed_at, opened_date, closed_date, closed_pr, skills_required,
                    preferred_backend, preferred_machine, estimated_minutes,
                    required_model, shipped_in, outcome_id, evidence
             FROM gaps WHERE id = ?1",
        )?;
        let mut rows = stmt.query(params![id])?;
        if let Some(row) = rows.next()? {
            Ok(Some(row_to_gap(row)?))
        } else {
            Ok(None)
        }
    }

    fn list_gaps_by_status(&self, status: &str) -> Result<Vec<GapRow>> {
        let conn = self.conn.lock().expect("sqlite backend mutex poisoned");
        let mut stmt = conn.prepare(
            "SELECT id, domain, title, description, priority, effort, status,
                    acceptance_criteria, depends_on, notes, source_doc, created_at,
                    closed_at, opened_date, closed_date, closed_pr, skills_required,
                    preferred_backend, preferred_machine, estimated_minutes,
                    required_model, shipped_in, outcome_id, evidence
             FROM gaps WHERE status = ?1 ORDER BY id",
        )?;
        let mut rows = stmt.query(params![status])?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            out.push(row_to_gap(row)?);
        }
        Ok(out)
    }

    fn delete_gap(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().expect("sqlite backend mutex poisoned");
        conn.execute("DELETE FROM gaps WHERE id = ?1", params![id])
            .context("delete_gap")?;
        Ok(())
    }
}

fn row_to_gap(row: &rusqlite::Row) -> Result<GapRow> {
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
        skills_required: row.get(16)?,
        preferred_backend: row.get(17)?,
        preferred_machine: row.get(18)?,
        estimated_minutes: row.get(19)?,
        required_model: row.get(20)?,
        shipped_in: row.get(21)?,
        outcome_id: row.get(22)?,
        evidence: row.get(23)?,
    })
}
