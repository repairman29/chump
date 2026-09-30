//! `PersistentMission<MergeRequest>` store integration (INFRA-2252 slice).
//!
//! [`INFRA-2252`](../../../docs/gaps/INFRA-2252.yaml)'s local merge queue
//! needs pending merges to survive a node restart (Pi-mesh / airplane
//! scenarios). Rather than invent a parallel persistence layer, this module
//! wraps a single-objective [`Mission`] around a [`MergeRequest`] and drives
//! it through the existing [`FileBackedMissionStore`] from INFRA-2247 —
//! `local-merge-queue.sh` gets crash-safe, ordered persistence for free.

use super::persistence::{
    FallbackMode, FileBackedMissionStore, Mission, MissionStore, Objective, ObjectiveState,
    PersistentMission,
};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// One PR waiting to land on local main via `scripts/coord/local-merge-queue.sh`.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct MergeRequest {
    /// Unique id for this queue entry (also the mission id in the store).
    pub id: String,
    pub pr_number: u64,
    pub branch: String,
    pub sha: String,
    /// Queue order — lower merges first. Preserved across restarts because
    /// it's stored inside the persisted `Objective`, not derived from
    /// directory-listing order.
    pub sequence: u32,
    /// RFC3339 timestamp of when this entry was queued.
    pub queued_at: String,
}

const OBJECTIVE_ID: &str = "merge";

impl MergeRequest {
    fn into_mission(self) -> Result<Mission> {
        let payload = serde_json::to_string(&self).context("serialize MergeRequest")?;
        Ok(Mission {
            id: self.id.clone(),
            name: format!("merge-request:{}", self.pr_number),
            objectives: vec![Objective {
                id: OBJECTIVE_ID.to_string(),
                description: payload,
                resource_cost: 0,
                duration_secs: 0,
                target: Some(self.branch.clone()),
                sequence: self.sequence,
            }],
            fallback_behavior: FallbackMode::QueryAuthority,
            timestamp_issued: self.queued_at.clone(),
            ttl_seconds: 0,
            version: 1,
        })
    }

    fn from_persistent(pm: &PersistentMission) -> Result<Self> {
        let objective = pm
            .mission
            .objectives
            .iter()
            .find(|o| o.id == OBJECTIVE_ID)
            .with_context(|| format!("mission {} has no merge objective", pm.mission.id))?;
        serde_json::from_str(&objective.description)
            .with_context(|| format!("deserialize MergeRequest from mission {}", pm.mission.id))
    }
}

/// `addMission` / `listPendingMissions` / `markCompleted` API over a
/// [`FileBackedMissionStore`], specialized to [`MergeRequest`] payloads.
#[derive(Clone, Debug)]
pub struct MergeQueueStore {
    store: FileBackedMissionStore,
}

impl MergeQueueStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            store: FileBackedMissionStore::new(root),
        }
    }

    /// Persist `mr` as a fresh, pending `PersistentMission<MergeRequest>`.
    pub fn add_mission(&self, mr: MergeRequest) -> Result<()> {
        let mission = mr.into_mission()?;
        let pm = PersistentMission::new(mission);
        self.store.save(&pm)
    }

    /// All queued merges that have not yet reached `Completed`, ordered by
    /// `MergeRequest::sequence` ascending (queue order), regardless of
    /// on-disk file-listing order.
    pub fn list_pending_missions(&self) -> Result<Vec<MergeRequest>> {
        let ids = self.store.list()?;
        let mut pending = Vec::new();
        for id in ids {
            let pm = self.store.load(&id)?;
            let is_completed = pm.current_state(OBJECTIVE_ID) == Some(ObjectiveState::Completed);
            if !is_completed {
                pending.push(MergeRequest::from_persistent(&pm)?);
            }
        }
        pending.sort_by_key(|mr| mr.sequence);
        Ok(pending)
    }

    /// Mark the merge request `id` as completed, checkpointing through
    /// `InProgress` first if it hasn't been started yet.
    pub fn mark_completed(&self, id: &str, ts: &str) -> Result<()> {
        let mut pm = self.store.load(id)?;
        if pm
            .current_state(OBJECTIVE_ID)
            .unwrap_or(ObjectiveState::Pending)
            == ObjectiveState::Pending
        {
            pm.checkpoint(OBJECTIVE_ID, ObjectiveState::InProgress, ts)?;
        }
        pm.checkpoint(OBJECTIVE_ID, ObjectiveState::Completed, ts)?;
        self.store.save(&pm)
    }
}
