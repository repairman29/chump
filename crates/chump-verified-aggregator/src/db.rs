//! SQLite storage for per-lane CI status updates.
//!
//! Non-gating slice (META-135): this store only records what each lane
//! reported. No aggregation or pass/fail decision is computed here — that
//! logic is a separate future gap (see `docs/design/CI_VERIFIED_AGGREGATOR.md`,
//! META-134).

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Mutex;

/// One reported status update for a single CI lane on a single PR/sha.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaneStatus {
    pub id: i64,
    pub pr: i64,
    pub sha: String,
    pub lane: String,
    pub conclusion: String,
    pub received_at_ms: i64,
}

/// Payload accepted by `POST /api/lane-status`.
#[derive(Debug, Clone, Deserialize)]
pub struct LaneStatusUpdate {
    pub pr: i64,
    pub sha: String,
    pub lane: String,
    pub conclusion: String,
}

pub struct AggregatorStore {
    conn: Mutex<Connection>,
}

impl AggregatorStore {
    /// Open (or create) the aggregator DB, ensuring the `lane_status` table
    /// exists.
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)
            .with_context(|| format!("opening verified-aggregator db at {}", path.display()))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS lane_status (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                pr             INTEGER NOT NULL,
                sha            TEXT NOT NULL,
                lane           TEXT NOT NULL,
                conclusion     TEXT NOT NULL,
                received_at_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_lane_status_pr_sha
                ON lane_status(pr, sha);",
        )
        .context("creating lane_status schema")?;

        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// In-memory store, for tests.
    #[cfg(test)]
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().context("opening in-memory db")?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS lane_status (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                pr             INTEGER NOT NULL,
                sha            TEXT NOT NULL,
                lane           TEXT NOT NULL,
                conclusion     TEXT NOT NULL,
                received_at_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_lane_status_pr_sha
                ON lane_status(pr, sha);",
        )
        .context("creating lane_status schema")?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// Store one lane status update. Returns the inserted row.
    pub fn record(&self, update: &LaneStatusUpdate, received_at_ms: i64) -> Result<LaneStatus> {
        let conn = self.conn.lock().expect("lane_status db mutex poisoned");
        conn.execute(
            "INSERT INTO lane_status (pr, sha, lane, conclusion, received_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                update.pr,
                update.sha,
                update.lane,
                update.conclusion,
                received_at_ms
            ],
        )
        .context("inserting lane_status row")?;
        let id = conn.last_insert_rowid();
        Ok(LaneStatus {
            id,
            pr: update.pr,
            sha: update.sha.clone(),
            lane: update.lane.clone(),
            conclusion: update.conclusion.clone(),
            received_at_ms,
        })
    }

    /// Return all recorded lane statuses for a given PR + sha, most recent
    /// first. No aggregation/decision — raw records only.
    pub fn lanes_for(&self, pr: i64, sha: &str) -> Result<Vec<LaneStatus>> {
        let conn = self.conn.lock().expect("lane_status db mutex poisoned");
        let mut stmt = conn.prepare(
            "SELECT id, pr, sha, lane, conclusion, received_at_ms
             FROM lane_status
             WHERE pr = ?1 AND sha = ?2
             ORDER BY received_at_ms DESC",
        )?;
        let rows = stmt
            .query_map(params![pr, sha], |row| {
                Ok(LaneStatus {
                    id: row.get(0)?,
                    pr: row.get(1)?,
                    sha: row.get(2)?,
                    lane: row.get(3)?,
                    conclusion: row.get(4)?,
                    received_at_ms: row.get(5)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }
}

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
    fn records_and_reads_back_lane_status() {
        let store = AggregatorStore::open_in_memory().unwrap();
        let update = LaneStatusUpdate {
            pr: 42,
            sha: "abc123".to_string(),
            lane: "cargo-test".to_string(),
            conclusion: "success".to_string(),
        };
        let recorded = store.record(&update, 1000).unwrap();
        assert_eq!(recorded.pr, 42);
        assert_eq!(recorded.lane, "cargo-test");

        let lanes = store.lanes_for(42, "abc123").unwrap();
        assert_eq!(lanes.len(), 1);
        assert_eq!(lanes[0].conclusion, "success");
    }

    #[test]
    fn does_not_mix_up_different_shas() {
        let store = AggregatorStore::open_in_memory().unwrap();
        store
            .record(
                &LaneStatusUpdate {
                    pr: 1,
                    sha: "sha-a".to_string(),
                    lane: "clippy".to_string(),
                    conclusion: "success".to_string(),
                },
                1,
            )
            .unwrap();
        store
            .record(
                &LaneStatusUpdate {
                    pr: 1,
                    sha: "sha-b".to_string(),
                    lane: "clippy".to_string(),
                    conclusion: "failure".to_string(),
                },
                2,
            )
            .unwrap();

        let lanes_a = store.lanes_for(1, "sha-a").unwrap();
        assert_eq!(lanes_a.len(), 1);
        assert_eq!(lanes_a[0].conclusion, "success");

        let lanes_b = store.lanes_for(1, "sha-b").unwrap();
        assert_eq!(lanes_b.len(), 1);
        assert_eq!(lanes_b[0].conclusion, "failure");
    }
}
