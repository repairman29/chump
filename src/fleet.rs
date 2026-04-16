//! Fleet coordination — multi-agent peer registry and work dispatch.
//!
//! V1: SQLite-backed peer registry with role declarations. Peers register themselves
//! at startup via fleet_register, query each other's status, and dispatch work via
//! the existing a2a/message_peer or HTTP endpoints.
//!
//! V2 (future): shared SQLite via litefs/WAL replication, workspace merge protocol
//! with state transfer, dynamic role negotiation, N-key approval for sensitive actions.

use anyhow::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetPeer {
    pub peer_id: String,           // unique, e.g. "mac-studio-1", "pixel-mabel"
    pub role: String,              // "builder", "sentinel", "specialist", etc.
    pub capabilities: Vec<String>, // e.g. ["rust", "git", "docker", "termux"]
    pub endpoint: Option<String>,  // optional HTTP endpoint for direct dispatch
    pub status: PeerStatus,
    pub last_seen_unix: u64,
    pub metadata_json: String, // free-form additional data
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PeerStatus {
    Online,
    Busy,
    Offline,
    Unknown,
}

impl PeerStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            PeerStatus::Online => "online",
            PeerStatus::Busy => "busy",
            PeerStatus::Offline => "offline",
            PeerStatus::Unknown => "unknown",
        }
    }

    pub fn from_str(s: &str) -> PeerStatus {
        match s.to_ascii_lowercase().as_str() {
            "online" => PeerStatus::Online,
            "busy" => PeerStatus::Busy,
            "offline" => PeerStatus::Offline,
            _ => PeerStatus::Unknown,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetDispatchRequest {
    pub from_peer: String,
    pub to_peer: Option<String>, // None = any peer matching role/capability
    pub required_role: Option<String>,
    pub required_capabilities: Vec<String>,
    pub task_description: String,
    pub priority: u32,
    pub deadline_unix: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceMergeProposal {
    pub merge_id: String,
    pub initiator: String,
    pub participants: Vec<String>,
    pub shared_objective: String,
    pub duration_turns: u32,
    pub memory_attribution: MemoryAttribution, // who keeps memories after merge
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum MemoryAttribution {
    AllParticipants, // each participant remembers everything
    Initiator,       // only initiator persists shared memories
    None,            // all transient, no persistence
}

/// Current Unix epoch in seconds. Saturates to 0 on clock skew before epoch.
fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Best-effort hostname for peer-id default.
fn hostname_default() -> String {
    // hostname crate isn't a dep — read $HOSTNAME, then `uname -n` via env, fallback.
    if let Ok(h) = std::env::var("HOSTNAME") {
        if !h.trim().is_empty() {
            return h.trim().to_string();
        }
    }
    if let Ok(h) = std::env::var("HOST") {
        if !h.trim().is_empty() {
            return h.trim().to_string();
        }
    }
    // Try `hostname` command (macOS / Linux).
    if let Ok(out) = std::process::Command::new("hostname").output() {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    "chump-peer".to_string()
}

/// Resolve the current peer id. Uses CHUMP_FLEET_PEER_ID env var if set, otherwise hostname.
pub fn current_peer_id() -> String {
    if let Ok(id) = std::env::var("CHUMP_FLEET_PEER_ID") {
        let trimmed = id.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    hostname_default()
}

/// Register (or replace) a peer in the registry. Uses INSERT OR REPLACE for idempotency.
pub fn register_peer(peer: FleetPeer) -> Result<()> {
    crate::fleet_db::upsert_peer(&peer)
}

/// Remove a peer from the registry.
pub fn unregister_peer(peer_id: &str) -> Result<()> {
    crate::fleet_db::delete_peer(peer_id)
}

/// Update the status field for an existing peer.
pub fn update_peer_status(peer_id: &str, status: PeerStatus) -> Result<()> {
    crate::fleet_db::update_status(peer_id, status, now_unix())
}

/// Update last_seen_unix for a peer (typically called by the peer itself).
pub fn heartbeat(peer_id: &str) -> Result<()> {
    crate::fleet_db::touch_last_seen(peer_id, now_unix())
}

/// Return all peers currently in the registry, ordered by peer_id.
pub fn list_peers() -> Result<Vec<FleetPeer>> {
    crate::fleet_db::list_all_peers()
}

/// Get a single peer by id.
pub fn get_peer(peer_id: &str) -> Result<Option<FleetPeer>> {
    crate::fleet_db::get_peer(peer_id)
}

/// Find a peer that satisfies the dispatch request. Matching rules (V1, in priority order):
///   1. If `to_peer` is set, return that peer iff it exists.
///   2. Filter by `required_role` (if set).
///   3. Filter by `required_capabilities` (every cap must be present).
///   4. Prefer peers with status Online over Busy/Unknown; ignore Offline.
///   5. Among ties, return the one with the most recent `last_seen_unix`.
pub fn find_peer_for_task(req: &FleetDispatchRequest) -> Result<Option<FleetPeer>> {
    if let Some(target) = &req.to_peer {
        return crate::fleet_db::get_peer(target);
    }
    let candidates = crate::fleet_db::list_all_peers()?;
    let mut filtered: Vec<FleetPeer> = candidates
        .into_iter()
        .filter(|p| p.status != PeerStatus::Offline)
        .filter(|p| match &req.required_role {
            Some(r) => p.role.eq_ignore_ascii_case(r),
            None => true,
        })
        .filter(|p| {
            req.required_capabilities
                .iter()
                .all(|c| p.capabilities.iter().any(|pc| pc.eq_ignore_ascii_case(c)))
        })
        .collect();
    // status priority: Online (0), Busy/Unknown (1), Offline already filtered out.
    filtered.sort_by(|a, b| {
        let ra = match a.status {
            PeerStatus::Online => 0,
            _ => 1,
        };
        let rb = match b.status {
            PeerStatus::Online => 0,
            _ => 1,
        };
        ra.cmp(&rb)
            .then_with(|| b.last_seen_unix.cmp(&a.last_seen_unix))
    });
    Ok(filtered.into_iter().next())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_peer_id_uses_env_when_set() {
        std::env::set_var("CHUMP_FLEET_PEER_ID", "test-fleet-peer-xyz");
        assert_eq!(current_peer_id(), "test-fleet-peer-xyz");
        std::env::remove_var("CHUMP_FLEET_PEER_ID");
    }

    #[test]
    fn current_peer_id_falls_back_to_hostname() {
        std::env::remove_var("CHUMP_FLEET_PEER_ID");
        let id = current_peer_id();
        assert!(!id.is_empty(), "hostname fallback should be non-empty");
    }

    #[test]
    fn peer_status_roundtrip() {
        for s in [
            PeerStatus::Online,
            PeerStatus::Busy,
            PeerStatus::Offline,
            PeerStatus::Unknown,
        ] {
            assert_eq!(PeerStatus::from_str(s.as_str()), s);
        }
        assert_eq!(PeerStatus::from_str("garbage"), PeerStatus::Unknown);
    }
}
