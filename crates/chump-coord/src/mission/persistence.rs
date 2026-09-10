//! Mission persistence types and `MissionStore` trait.
//!
//! This module models a long-running, multi-step **mission** as a sequence
//! of typed objectives that can be checkpointed to disk and resumed across
//! agent restarts. Derived from established Rust mission-execution prior
//! art, adapted for the agent-fleet semantics used elsewhere in
//! `chump-coord` (token-budget cost instead of energy, HITL approval targets
//! instead of physical targets).
//!
//! ## Surface
//!
//! - [`Mission`] / [`Objective`] — declarative plan handed to an orchestrator.
//! - [`ObjectiveState`] / [`MissionCheckpoint`] — per-objective progress markers.
//! - [`ObjectiveDependency`] / [`DependencyCondition`] — DAG edges between
//!   objectives (gated on completion / start / skip).
//! - [`PersistentMission`] — a [`Mission`] plus its checkpoint history.
//! - [`MissionStore`] — abstract load/save/list interface.
//! - [`FileBackedMissionStore`] — default impl at `~/.chump/missions/<id>.json`.
//! - [`FallbackMode`] — what the orchestrator does when no objective is runnable.
//!
//! Replanning lives in the sibling [`super::replanning`] module.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

// ── Core types ───────────────────────────────────────────────────────────────

/// What the orchestrator should do when no objective is currently runnable
/// (all remaining objectives are blocked on a denied / failed predecessor,
/// the mission TTL has expired, etc.).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FallbackMode {
    /// Stop cleanly, release leases, exit zero.
    SafeShutdown,
    /// Roll back any in-flight work and surface the mission as resumable.
    ReturnToBase,
    /// Pause and wait for an operator decision via the inbox.
    QueryAuthority,
    /// Keep doing whatever the last running objective was doing.
    ContinueLastTask,
    /// Mark the current objective skipped and try the next one.
    SkipAndContinue,
}

/// A single unit of work inside a mission.
///
/// `resource_cost` is the token-budget estimate for this objective
/// (aligns with the INFRA-2090 budget enforcement path). `target`
/// is an optional reference used by the HITL approval gate
/// (aligns with INFRA-1813 — the approver checks `target` for
/// scope before unblocking).
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Objective {
    pub id: String,
    pub description: String,
    /// Token-budget estimate for this objective.
    pub resource_cost: u32,
    /// Soft time bound (seconds). Orchestrator may surface a WARN past this.
    pub duration_secs: u32,
    /// Optional reference for the HITL approval gate; `None` skips approval.
    pub target: Option<String>,
    /// Ordering hint. Ties broken by `id` lexicographic order.
    pub sequence: u32,
}

/// Top-level mission shape — the plan handed to an orchestrator.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Mission {
    pub id: String,
    pub name: String,
    pub objectives: Vec<Objective>,
    pub fallback_behavior: FallbackMode,
    /// RFC3339 timestamp of when the plan was issued.
    pub timestamp_issued: String,
    /// Soft deadline (seconds from issue). Past this, replanners may abort.
    pub ttl_seconds: u32,
    /// Plan version — bumped when the mission is replanned in place.
    pub version: u32,
}

// ── State machine ────────────────────────────────────────────────────────────

/// Per-objective state. State transitions are append-only in
/// [`MissionCheckpoint`] history; the *current* state of an objective is
/// the most recent checkpoint for that `objective_id`.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ObjectiveState {
    Pending,
    InProgress,
    Completed,
    Failed,
    Skipped,
}

impl ObjectiveState {
    /// Returns `true` if `next` is a legal follow-on from `self`.
    ///
    /// Allowed edges:
    /// ```text
    /// Pending      → InProgress | Skipped | Failed
    /// InProgress   → Completed  | Failed  | Skipped
    /// Completed    → (terminal)
    /// Failed       → (terminal, but Pending on replan is allowed)
    /// Skipped      → (terminal)
    /// ```
    /// Replanning a failed objective back to `Pending` is allowed so a
    /// `RetryWithBackoff` replanner can re-arm the objective without
    /// constructing a fresh `Mission`.
    pub fn can_transition_to(self, next: ObjectiveState) -> bool {
        use ObjectiveState::*;
        match (self, next) {
            (Pending, InProgress) | (Pending, Skipped) | (Pending, Failed) => true,
            (InProgress, Completed) | (InProgress, Failed) | (InProgress, Skipped) => true,
            (Failed, Pending) => true, // replan re-arm
            _ => false,
        }
    }
}

/// Single checkpoint record — appended to a [`PersistentMission`] every time
/// an objective changes state.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct MissionCheckpoint {
    pub mission_id: String,
    pub objective_id: String,
    pub state: ObjectiveState,
    /// RFC3339 timestamp of the transition.
    pub ts: String,
}

// ── Dependencies ─────────────────────────────────────────────────────────────

/// When is the edge `from → to` satisfied?
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyCondition {
    /// `to` is runnable after `from` reaches [`ObjectiveState::Completed`].
    Completed,
    /// `to` is runnable once `from` has reached [`ObjectiveState::InProgress`].
    Started,
    /// `to` is runnable if `from` was [`ObjectiveState::Skipped`].
    Skipped,
}

/// A single DAG edge between two objectives in the same mission.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ObjectiveDependency {
    pub from: String,
    pub to: String,
    pub condition: DependencyCondition,
}

// ── Persistent envelope ──────────────────────────────────────────────────────

/// A [`Mission`] plus its append-only checkpoint history. This is the unit
/// the [`MissionStore`] persists.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PersistentMission {
    pub mission: Mission,
    pub checkpoints: Vec<MissionCheckpoint>,
}

impl PersistentMission {
    /// Construct an empty persistent envelope around a mission. No
    /// checkpoints are emitted at construction time — callers are
    /// expected to push the initial `Pending` checkpoints once they
    /// commit to running the plan.
    pub fn new(mission: Mission) -> Self {
        Self {
            mission,
            checkpoints: Vec::new(),
        }
    }

    /// Append a checkpoint, validating the state transition first.
    pub fn checkpoint(&mut self, objective_id: &str, next: ObjectiveState, ts: &str) -> Result<()> {
        // Validate the objective exists in this mission.
        if !self.mission.objectives.iter().any(|o| o.id == objective_id) {
            return Err(anyhow!(
                "objective {} is not part of mission {}",
                objective_id,
                self.mission.id
            ));
        }
        let current = self
            .current_state(objective_id)
            .unwrap_or(ObjectiveState::Pending);
        if !current.can_transition_to(next) {
            return Err(anyhow!(
                "illegal transition for {}: {:?} -> {:?}",
                objective_id,
                current,
                next
            ));
        }
        self.checkpoints.push(MissionCheckpoint {
            mission_id: self.mission.id.clone(),
            objective_id: objective_id.to_string(),
            state: next,
            ts: ts.to_string(),
        });
        Ok(())
    }

    /// Returns the most recent checkpointed state for `objective_id`,
    /// or `None` if it has no checkpoints yet.
    pub fn current_state(&self, objective_id: &str) -> Option<ObjectiveState> {
        self.checkpoints
            .iter()
            .rev()
            .find(|c| c.objective_id == objective_id)
            .map(|c| c.state)
    }
}

// ── Store trait + file impl ──────────────────────────────────────────────────

/// Abstract persistence for [`PersistentMission`] envelopes.
pub trait MissionStore {
    fn save(&self, m: &PersistentMission) -> Result<()>;
    fn load(&self, id: &str) -> Result<PersistentMission>;
    fn list(&self) -> Result<Vec<String>>;
}

/// Default [`MissionStore`] impl — one JSON file per mission under a root
/// directory. The conventional location is `~/.chump/missions/<id>.json`.
#[derive(Clone, Debug)]
pub struct FileBackedMissionStore {
    root: PathBuf,
}

impl FileBackedMissionStore {
    /// Construct a store rooted at `root`. The directory is created on
    /// first save if it does not already exist.
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Construct a store rooted at `~/.chump/missions`. Falls back to
    /// `./.chump/missions` if `HOME` is unset.
    pub fn default_root() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        Self::new(Path::new(&home).join(".chump").join("missions"))
    }

    fn path_for(&self, id: &str) -> PathBuf {
        self.root.join(format!("{}.json", id))
    }
}

impl MissionStore for FileBackedMissionStore {
    fn save(&self, m: &PersistentMission) -> Result<()> {
        fs::create_dir_all(&self.root)
            .with_context(|| format!("create mission root {}", self.root.display()))?;
        let path = self.path_for(&m.mission.id);
        let json = serde_json::to_vec_pretty(m).context("serialize mission")?;
        fs::write(&path, json).with_context(|| format!("write {}", path.display()))?;
        Ok(())
    }

    fn load(&self, id: &str) -> Result<PersistentMission> {
        let path = self.path_for(id);
        let bytes = fs::read(&path).with_context(|| format!("read {}", path.display()))?;
        let m: PersistentMission = serde_json::from_slice(&bytes).context("deserialize mission")?;
        Ok(m)
    }

    fn list(&self) -> Result<Vec<String>> {
        let mut out = Vec::new();
        let dir = match fs::read_dir(&self.root) {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
            Err(e) => return Err(anyhow!("read_dir {}: {}", self.root.display(), e)),
        };
        for entry in dir {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) == Some("json") {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    out.push(stem.to_string());
                }
            }
        }
        out.sort();
        Ok(out)
    }
}

/// Classification of failure severity for retry logic.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum FailureClass {
    /// Transient failures that may succeed on retry (e.g., network timeouts, rate limits).
    Transient,
    /// Permanent failures that require operator intervention (e.g., validation errors, not found).
    Permanent,
    /// Unknown failure class; defaults to transient for safety.
    Unknown,
}

impl FailureClass {
    /// Returns true if the failure class is transient.
    pub fn is_transient(self) -> bool {
        matches!(self, FailureClass::Transient)
    }

    /// Returns true if the failure class is permanent.
    pub fn is_permanent(self) -> bool {
        matches!(self, FailureClass::Permanent)
    }

    /// String representation for logging and events.
    pub fn as_str(self) -> &'static str {
        match self {
            FailureClass::Transient => "transient",
            FailureClass::Permanent => "permanent",
            FailureClass::Unknown => "unknown",
        }
    }
}

/// Maps an error type and optional status code to a failure class.
///
/// This helper centralizes the logic for determining whether an error is
/// transient or permanent based on common patterns.
pub fn map_error_to_failure_class(
    err: &dyn std::error::Error,
    status_code: Option<u16>,
) -> FailureClass {
    // First, check if we have a status code (HTTP-like errors)
    if let Some(code) = status_code {
        match code {
            408 | 429 | 500 | 502 | 503 | 504 => return FailureClass::Transient,
            400 | 401 | 403 | 404 | 409 | 422 => return FailureClass::Permanent,
            _ => return FailureClass::Unknown,
        }
    }

    // Fallback to error type inspection
    let err_str = err.to_string().to_lowercase();
    if err_str.contains("timeout")
        || err_str.contains("network")
        || err_str.contains("connection")
        || err_str.contains("rate limit")
        || err_str.contains("temporarily unavailable")
    {
        return FailureClass::Transient;
    }
    if err_str.contains("not found")
        || err_str.contains("invalid")
        || err_str.contains("validation")
        || err_str.contains("unauthorized")
        || err_str.contains("forbidden")
    {
        return FailureClass::Permanent;
    }
    FailureClass::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_failure_class_as_str() {
        assert_eq!(FailureClass::Transient.as_str(), "transient");
        assert_eq!(FailureClass::Permanent.as_str(), "permanent");
        assert_eq!(FailureClass::Unknown.as_str(), "unknown");
    }

    #[test]
    fn test_map_error_to_failure_class_status_codes() {
        // Mock error type
        let err = std::io::Error::new(std::io::ErrorKind::Other, "mock");

        // Transient status codes
        assert_eq!(
            map_error_to_failure_class(&err, Some(408)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(429)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(500)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(502)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(503)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(504)),
            FailureClass::Transient
        );

        // Permanent status codes
        assert_eq!(
            map_error_to_failure_class(&err, Some(400)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(401)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(403)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(404)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(409)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(422)),
            FailureClass::Permanent
        );

        // Unknown status code
        assert_eq!(
            map_error_to_failure_class(&err, Some(418)),
            FailureClass::Unknown
        );
    }

    #[test]
    fn test_map_error_to_failure_class_error_strings() {
        let err_timeout = std::io::Error::new(std::io::ErrorKind::TimedOut, "timeout");
        assert_eq!(
            map_error_to_failure_class(&err_timeout, None),
            FailureClass::Transient
        );

        let err_network =
            std::io::Error::new(std::io::ErrorKind::NotConnected, "network unreachable");
        assert_eq!(
            map_error_to_failure_class(&err_network, None),
            FailureClass::Transient
        );

        let err_rate_limit = std::io::Error::new(std::io::ErrorKind::Other, "rate limit exceeded");
        assert_eq!(
            map_error_to_failure_class(&err_rate_limit, None),
            FailureClass::Transient
        );

        let err_not_found = std::io::Error::new(std::io::ErrorKind::NotFound, "not found");
        assert_eq!(
            map_error_to_failure_class(&err_not_found, None),
            FailureClass::Permanent
        );

        let err_invalid = std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid input");
        assert_eq!(
            map_error_to_failure_class(&err_invalid, None),
            FailureClass::Permanent
        );

        let err_validation = std::io::Error::new(std::io::ErrorKind::Other, "validation failed");
        assert_eq!(
            map_error_to_failure_class(&err_validation, None),
            FailureClass::Permanent
        );

        let err_unauthorized =
            std::io::Error::new(std::io::ErrorKind::PermissionDenied, "unauthorized");
        assert_eq!(
            map_error_to_failure_class(&err_unauthorized, None),
            FailureClass::Permanent
        );

        let err_forbidden = std::io::Error::new(std::io::ErrorKind::Other, "forbidden");
        assert_eq!(
            map_error_to_failure_class(&err_forbidden, None),
            FailureClass::Permanent
        );

        let err_unknown = std::io::Error::new(std::io::ErrorKind::Other, "some random error");
        assert_eq!(
            map_error_to_failure_class(&err_unknown, None),
            FailureClass::Unknown
        );
    }
}

/// Classification of failure severity for retry logic.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum FailureClass {
    /// Transient failures that may succeed on retry (e.g., network timeouts, rate limits).
    Transient,
    /// Permanent failures that require operator intervention (e.g., validation errors, not found).
    Permanent,
    /// Unknown failure class; defaults to transient for safety.
    Unknown,
}

impl FailureClass {
    /// Returns true if the failure class is transient.
    pub fn is_transient(self) -> bool {
        matches!(self, FailureClass::Transient)
    }

    /// Returns true if the failure class is permanent.
    pub fn is_permanent(self) -> bool {
        matches!(self, FailureClass::Permanent)
    }

    /// String representation for logging and events.
    pub fn as_str(self) -> &'static str {
        match self {
            FailureClass::Transient => "transient",
            FailureClass::Permanent => "permanent",
            FailureClass::Unknown => "unknown",
        }
    }
}

/// Maps an error type and optional status code to a failure class.
///
/// This helper centralizes the logic for determining whether an error is
/// transient or permanent based on common patterns.
pub fn map_error_to_failure_class(
    err: &dyn std::error::Error,
    status_code: Option<u16>,
) -> FailureClass {
    // First, check if we have a status code (HTTP-like errors)
    if let Some(code) = status_code {
        match code {
            408 | 429 | 500 | 502 | 503 | 504 => return FailureClass::Transient,
            400 | 401 | 403 | 404 | 409 | 422 => return FailureClass::Permanent,
            _ => return FailureClass::Unknown,
        }
    }

    // Fallback to error type inspection
    let err_str = err.to_string().to_lowercase();
    if err_str.contains("timeout")
        || err_str.contains("network")
        || err_str.contains("connection")
        || err_str.contains("rate limit")
        || err_str.contains("temporarily unavailable")
    {
        return FailureClass::Transient;
    }
    if err_str.contains("not found")
        || err_str.contains("invalid")
        || err_str.contains("validation")
        || err_str.contains("unauthorized")
        || err_str.contains("forbidden")
    {
        return FailureClass::Permanent;
    }
    FailureClass::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_failure_class_as_str() {
        assert_eq!(FailureClass::Transient.as_str(), "transient");
        assert_eq!(FailureClass::Permanent.as_str(), "permanent");
        assert_eq!(FailureClass::Unknown.as_str(), "unknown");
    }

    #[test]
    fn test_map_error_to_failure_class_status_codes() {
        // Mock error type
        let err = std::io::Error::new(std::io::ErrorKind::Other, "mock");

        // Transient status codes
        assert_eq!(
            map_error_to_failure_class(&err, Some(408)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(429)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(500)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(502)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(503)),
            FailureClass::Transient
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(504)),
            FailureClass::Transient
        );

        // Permanent status codes
        assert_eq!(
            map_error_to_failure_class(&err, Some(400)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(401)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(403)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(404)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(409)),
            FailureClass::Permanent
        );
        assert_eq!(
            map_error_to_failure_class(&err, Some(422)),
            FailureClass::Permanent
        );

        // Unknown status code
        assert_eq!(
            map_error_to_failure_class(&err, Some(418)),
            FailureClass::Unknown
        );
    }

    #[test]
    fn test_map_error_to_failure_class_error_strings() {
        let err_timeout = std::io::Error::new(std::io::ErrorKind::TimedOut, "timeout");
        assert_eq!(
            map_error_to_failure_class(&err_timeout, None),
            FailureClass::Transient
        );

        let err_network =
            std::io::Error::new(std::io::ErrorKind::NotConnected, "network unreachable");
        assert_eq!(
            map_error_to_failure_class(&err_network, None),
            FailureClass::Transient
        );

        let err_rate_limit = std::io::Error::new(std::io::ErrorKind::Other, "rate limit exceeded");
        assert_eq!(
            map_error_to_failure_class(&err_rate_limit, None),
            FailureClass::Transient
        );

        let err_not_found = std::io::Error::new(std::io::ErrorKind::NotFound, "not found");
        assert_eq!(
            map_error_to_failure_class(&err_not_found, None),
            FailureClass::Permanent
        );

        let err_invalid = std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid input");
        assert_eq!(
            map_error_to_failure_class(&err_invalid, None),
            FailureClass::Permanent
        );

        let err_validation = std::io::Error::new(std::io::ErrorKind::Other, "validation failed");
        assert_eq!(
            map_error_to_failure_class(&err_validation, None),
            FailureClass::Permanent
        );

        let err_unauthorized =
            std::io::Error::new(std::io::ErrorKind::PermissionDenied, "unauthorized");
        assert_eq!(
            map_error_to_failure_class(&err_unauthorized, None),
            FailureClass::Permanent
        );

        let err_forbidden = std::io::Error::new(std::io::ErrorKind::Other, "forbidden");
        assert_eq!(
            map_error_to_failure_class(&err_forbidden, None),
            FailureClass::Permanent
        );

        let err_unknown = std::io::Error::new(std::io::ErrorKind::Other, "some random error");
        assert_eq!(
            map_error_to_failure_class(&err_unknown, None),
            FailureClass::Unknown
        );
    }
}
