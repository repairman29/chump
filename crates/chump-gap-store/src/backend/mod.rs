//! Storage-backend abstraction — INFRA-2092.
//!
//! Smallest credible slice of INFRA-1967's C4 finding (single-node SQLite
//! ceiling breaks fleet scale): a `GapBackend` trait covering the core
//! `gaps` table CRUD, with two implementations —
//!
//! - [`sqlite::SqliteBackend`] — always compiled, wraps the same `gaps`
//!   table shape `GapStore` uses. Remains the local-dev default.
//! - [`postgres::PostgresBackend`] — compiled only under the
//!   `postgres-backend` feature; same schema, Postgres storage.
//!
//! This module is additive and does not change `GapStore`'s existing
//! rusqlite-direct code path — it exists to prove the interface can be
//! satisfied by a second storage engine without a full rewrite of the
//! (9000+ line) production store.

pub mod sqlite;

#[cfg(feature = "postgres-backend")]
pub mod postgres;

use crate::GapRow;
use anyhow::Result;

/// Core gap-registry operations any storage engine must support.
///
/// Deliberately a subset of `GapStore`'s full surface (dependency graphs,
/// lease management, YAML sync, etc. stay SQLite-only for now) — this is
/// the "same schema, swap storage" slice, not a full backend migration.
pub trait GapBackend: Send + Sync {
    /// Create the `gaps` table (and supporting indexes) if absent.
    fn init_schema(&self) -> Result<()>;

    /// Insert or fully replace a gap row, keyed by `id`.
    fn upsert_gap(&self, gap: &GapRow) -> Result<()>;

    /// Fetch a single gap by id.
    fn get_gap(&self, id: &str) -> Result<Option<GapRow>>;

    /// List all gaps with the given `status` (e.g. "open", "done").
    fn list_gaps_by_status(&self, status: &str) -> Result<Vec<GapRow>>;

    /// Delete a gap by id. No-op (Ok) if the id doesn't exist.
    fn delete_gap(&self, id: &str) -> Result<()>;
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::backend::sqlite::SqliteBackend;

    fn sample_gap(id: &str, status: &str) -> GapRow {
        GapRow {
            id: id.to_string(),
            domain: "INFRA".to_string(),
            title: "sample".to_string(),
            description: "sample gap".to_string(),
            priority: "P1".to_string(),
            effort: "s".to_string(),
            status: status.to_string(),
            acceptance_criteria: "1. do the thing".to_string(),
            depends_on: "[]".to_string(),
            notes: "".to_string(),
            source_doc: "".to_string(),
            created_at: 1_700_000_000,
            closed_at: None,
            opened_date: "".to_string(),
            closed_date: "".to_string(),
            closed_pr: None,
            skills_required: "".to_string(),
            preferred_backend: "any".to_string(),
            preferred_machine: "any".to_string(),
            estimated_minutes: "".to_string(),
            required_model: "any".to_string(),
            shipped_in: None,
            outcome_id: None,
            evidence: None,
        }
    }

    /// Runs the same scenario against any `GapBackend` impl — shared by the
    /// SQLite unit test here and the (feature-gated) Postgres test in
    /// `backend::postgres::tests`, so both engines are held to one contract.
    pub(crate) fn exercise_backend_contract(backend: &dyn GapBackend) -> Result<()> {
        backend.init_schema()?;
        backend.init_schema()?; // idempotent

        assert!(backend.get_gap("INFRA-9999")?.is_none());

        let gap = sample_gap("INFRA-9999", "open");
        backend.upsert_gap(&gap)?;
        let fetched = backend.get_gap("INFRA-9999")?.expect("just inserted");
        assert_eq!(fetched, gap);

        let mut updated = gap.clone();
        updated.status = "done".to_string();
        updated.closed_at = Some(1_700_000_100);
        backend.upsert_gap(&updated)?;
        let refetched = backend.get_gap("INFRA-9999")?.expect("still present");
        assert_eq!(refetched.status, "done");
        assert_eq!(refetched.closed_at, Some(1_700_000_100));

        let open_gap = sample_gap("INFRA-9998", "open");
        backend.upsert_gap(&open_gap)?;
        let open_list = backend.list_gaps_by_status("open")?;
        assert_eq!(open_list.len(), 1);
        assert_eq!(open_list[0].id, "INFRA-9998");

        let done_list = backend.list_gaps_by_status("done")?;
        assert_eq!(done_list.len(), 1);
        assert_eq!(done_list[0].id, "INFRA-9999");

        backend.delete_gap("INFRA-9998")?;
        assert!(backend.get_gap("INFRA-9998")?.is_none());
        // Deleting a non-existent id is a no-op, not an error.
        backend.delete_gap("INFRA-9998")?;

        Ok(())
    }

    #[test]
    fn sqlite_backend_satisfies_contract() {
        let dir = tempfile::tempdir().expect("tempdir");
        let backend =
            SqliteBackend::open(&dir.path().join("backend-test.db")).expect("open sqlite backend");
        exercise_backend_contract(&backend).expect("contract");
    }
}
