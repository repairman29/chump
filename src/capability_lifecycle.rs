//! CREDIBLE-299: per-capability lifecycle gauge —
//! `built -> merged -> deployed -> wired -> running -> doing-its-job`.
//!
//! This slice (CREDIBLE-563) lands only the `built` stage: recording that a
//! capability's build step completed and persisting that fact in the
//! lifecycle state store. Later slices (CREDIBLE-564..567) add the
//! remaining stage transitions on top of the same store.
//!
//! State store: a JSON file at `.chump-locks/capability_lifecycle.json`,
//! keyed by capability id, holding the highest stage reached plus a
//! timestamped history. Mirrors the JSON-file-backed state pattern used by
//! other small gauges in this crate (e.g. `cost_ledger`).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// A stage in the capability lifecycle. Only `Built` is used by this slice;
/// the remaining variants exist so later slices (CREDIBLE-564..567) can
/// extend the same enum without a breaking store-format change.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LifecycleStage {
    Built,
    Merged,
    Deployed,
    Wired,
    Running,
    DoingItsJob,
}

impl LifecycleStage {
    pub fn as_str(&self) -> &'static str {
        match self {
            LifecycleStage::Built => "built",
            LifecycleStage::Merged => "merged",
            LifecycleStage::Deployed => "deployed",
            LifecycleStage::Wired => "wired",
            LifecycleStage::Running => "running",
            LifecycleStage::DoingItsJob => "doing_its_job",
        }
    }
}

/// One recorded stage transition for a capability.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StageEntry {
    pub stage: LifecycleStage,
    /// RFC3339 timestamp of when the stage was recorded.
    pub recorded_at: String,
}

/// Per-capability lifecycle record: the full history of recorded stages.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CapabilityRecord {
    pub history: Vec<StageEntry>,
}

impl CapabilityRecord {
    /// The most recently recorded stage, if any.
    pub fn latest_stage(&self) -> Option<LifecycleStage> {
        self.history.last().map(|e| e.stage)
    }
}

/// JSON-file-backed store mapping capability id -> lifecycle record.
pub struct CapabilityLifecycleStore {
    path: PathBuf,
}

impl CapabilityLifecycleStore {
    /// Store rooted at `.chump-locks/capability_lifecycle.json` under `repo_root`.
    pub fn at_repo_root(repo_root: &Path) -> Self {
        Self {
            path: repo_root
                .join(".chump-locks")
                .join("capability_lifecycle.json"),
        }
    }

    /// Store backed by an explicit path — used by tests to avoid touching a
    /// real repo's `.chump-locks`.
    pub fn at_path(path: PathBuf) -> Self {
        Self { path }
    }

    fn load(&self) -> Result<HashMap<String, CapabilityRecord>> {
        if !self.path.exists() {
            return Ok(HashMap::new());
        }
        let content = std::fs::read_to_string(&self.path)
            .with_context(|| format!("reading {}", self.path.display()))?;
        if content.trim().is_empty() {
            return Ok(HashMap::new());
        }
        serde_json::from_str(&content)
            .with_context(|| format!("parsing {}", self.path.display()))
    }

    fn save(&self, records: &HashMap<String, CapabilityRecord>) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        let content = serde_json::to_string_pretty(records)?;
        std::fs::write(&self.path, content)
            .with_context(|| format!("writing {}", self.path.display()))
    }

    /// Record that `capability_id` has reached `stage`. Appends to history —
    /// callers that only care about the latest stage should use
    /// `CapabilityRecord::latest_stage`.
    pub fn record_stage(&self, capability_id: &str, stage: LifecycleStage) -> Result<()> {
        let mut records = self.load()?;
        let record = records.entry(capability_id.to_string()).or_default();
        record.history.push(StageEntry {
            stage,
            recorded_at: chrono::Utc::now().to_rfc3339(),
        });
        self.save(&records)
    }

    /// Convenience for the "built" stage (CREDIBLE-563 AC1): call this when
    /// a capability's build step completes.
    pub fn record_built(&self, capability_id: &str) -> Result<()> {
        self.record_stage(capability_id, LifecycleStage::Built)
    }

    /// Look up the current record for a capability, if any stage has been recorded.
    pub fn get(&self, capability_id: &str) -> Result<Option<CapabilityRecord>> {
        Ok(self.load()?.remove(capability_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_built_creates_built_gauge_entry() {
        let dir = tempfile::tempdir().unwrap();
        let store = CapabilityLifecycleStore::at_path(dir.path().join("lifecycle.json"));

        store.record_built("acp-server").unwrap();

        let record = store
            .get("acp-server")
            .unwrap()
            .expect("capability record should exist after record_built");
        assert_eq!(record.history.len(), 1);
        assert_eq!(record.latest_stage(), Some(LifecycleStage::Built));
        assert_eq!(record.history[0].stage.as_str(), "built");
        assert!(!record.history[0].recorded_at.is_empty());
    }

    #[test]
    fn unknown_capability_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        let store = CapabilityLifecycleStore::at_path(dir.path().join("lifecycle.json"));
        assert!(store.get("nope").unwrap().is_none());
    }

    #[test]
    fn record_persists_across_store_instances() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("lifecycle.json");

        CapabilityLifecycleStore::at_path(path.clone())
            .record_built("chump-gap-store")
            .unwrap();

        let reopened = CapabilityLifecycleStore::at_path(path);
        let record = reopened.get("chump-gap-store").unwrap().unwrap();
        assert_eq!(record.latest_stage(), Some(LifecycleStage::Built));
    }
}
