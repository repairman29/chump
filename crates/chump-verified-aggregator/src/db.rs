//! SQLite storage for per-lane CI status updates.
//!
//! META-135: this store holds raw lane status rows only. There is
//! deliberately no aggregation/decision logic here — that's the
//! META-134 slice (see `docs/design/CI_VERIFIED_AGGREGATOR.md`).

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Mutex;

/// A single lane status update, as received from a CI job.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaneStatus {
    pub id: i64,
    pub pr: i64,
    pub sha: String,
    pub lane: String,
    pub result: String,
    pub received_at_ms: i64,
}

/// Payload accepted on `POST /api/lane-status`.
#[derive(Debug, Clone, Deserialize)]
pub struct LaneStatusUpdate {
    pub pr: i64,
    pub sha: String,
    pub lane: String,
    pub result: String,
}

pub struct AggregatorStore {
    conn: Mutex<Connection>,
}

impl AggregatorStore {
    /// Open (or create) the lane-status DB and ensure the schema exists.
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)
            .with_context(|| format!("opening aggregator db at {}", path.display()))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS lane_status (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                pr             INTEGER NOT NULL,
                sha            TEXT NOT NULL,
                lane           TEXT NOT NULL,
                result         TEXT NOT NULL,
                received_at_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_lane_status_pr_sha ON lane_status(pr, sha);
            CREATE INDEX IF NOT EXISTS idx_lane_status_lane ON lane_status(lane);",
        )
        .context("creating lane_status table")?;

        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// Store a lane status update. Each call is an insert (no upsert) — the
    /// full history of updates for a (pr, sha, lane) is retained.
    pub fn insert_lane_status(
        &self,
        update: &LaneStatusUpdate,
        received_at_ms: i64,
    ) -> Result<i64> {
        let conn = self.conn.lock().expect("aggregator db mutex poisoned");
        conn.execute(
            "INSERT INTO lane_status (pr, sha, lane, result, received_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                update.pr,
                update.sha,
                update.lane,
                update.result,
                received_at_ms
            ],
        )
        .context("inserting lane_status row")?;
        Ok(conn.last_insert_rowid())
    }

    /// Return all stored lane status rows for a given (pr, sha), ordered by
    /// insertion order (oldest first).
    pub fn query_lane_status(&self, pr: i64, sha: &str) -> Result<Vec<LaneStatus>> {
        let conn = self.conn.lock().expect("aggregator db mutex poisoned");
        let mut stmt = conn.prepare(
            "SELECT id, pr, sha, lane, result, received_at_ms
             FROM lane_status
             WHERE pr = ?1 AND sha = ?2
             ORDER BY id ASC",
        )?;
        let rows = stmt
            .query_map(params![pr, sha], |row| {
                Ok(LaneStatus {
                    id: row.get(0)?,
                    pr: row.get(1)?,
                    sha: row.get(2)?,
                    lane: row.get(3)?,
                    result: row.get(4)?,
                    received_at_ms: row.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()
            .context("collecting lane_status rows")?;
        Ok(rows)
    }
}

/// Current time in milliseconds since the Unix epoch.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_query_round_trips() {
        let store = AggregatorStore::open(Path::new(":memory:")).unwrap();
        let update = LaneStatusUpdate {
            pr: 42,
            sha: "abc123".to_string(),
            lane: "cargo-test".to_string(),
            result: "success".to_string(),
        };
        store.insert_lane_status(&update, 1_000).unwrap();

        let rows = store.query_lane_status(42, "abc123").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].lane, "cargo-test");
        assert_eq!(rows[0].result, "success");
    }

    #[test]
    fn query_returns_empty_for_unknown_pr_sha() {
        let store = AggregatorStore::open(Path::new(":memory:")).unwrap();
        let rows = store.query_lane_status(999, "nope").unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn multiple_updates_for_same_lane_are_all_retained() {
        let store = AggregatorStore::open(Path::new(":memory:")).unwrap();
        let update = LaneStatusUpdate {
            pr: 1,
            sha: "s".to_string(),
            lane: "clippy".to_string(),
            result: "in_progress".to_string(),
        };
        store.insert_lane_status(&update, 1).unwrap();
        let update2 = LaneStatusUpdate {
            pr: 1,
            sha: "s".to_string(),
            lane: "clippy".to_string(),
            result: "success".to_string(),
        };
        store.insert_lane_status(&update2, 2).unwrap();

        let rows = store.query_lane_status(1, "s").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].result, "in_progress");
        assert_eq!(rows[1].result, "success");
    }
}
