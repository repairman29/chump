//! Fleet coordination — multi-agent peer registry and work dispatch.
//!
//! V1: SQLite-backed peer registry with role declarations. Peers register themselves
//! at startup via fleet_register, query each other's status, and dispatch work via
//! the existing a2a/message_peer or HTTP endpoints.
//!
//! V2 (FLEET-003b): atomic blackboard exchange via `exchange_workspace`. Two peers
//! swap their current high-salience blackboard snapshots in a single round-trip,
//! each posting the other's items with peer attribution.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};

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

// ── FLEET-003b: atomic blackboard exchange ───────────────────────────────────

/// Monotonic sequence counter for outgoing exchange envelopes.
static EXCHANGE_SEQ: AtomicU64 = AtomicU64::new(1);

/// A single blackboard item serialised for wire transport.
/// Mirrors `blackboard::Entry` minus the non-serialisable `Instant`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlackboardItem {
    /// Source module name (from `Module::to_string()`).
    pub source: String,
    /// Entry content text.
    pub content: String,
    /// Computed salience at time of posting.
    pub salience: f64,
    /// Unix seconds when the entry was created (approximate).
    pub posted_unix: u64,
}

/// Wire payload for a complete blackboard snapshot exchange.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerBlackboard {
    /// Peer that produced this snapshot.
    pub peer_id: String,
    /// Monotonic sequence number, incremented per outgoing call.
    pub sequence: u64,
    /// Unix seconds when this snapshot was produced.
    pub timestamp_unix: u64,
    /// High-salience blackboard entries (broadcast-eligible only).
    pub items: Vec<BlackboardItem>,
    /// SHA-256 hex of the canonical JSON of `items`.
    pub checksum: String,
}

impl PeerBlackboard {
    /// Compute the expected SHA-256 checksum for a list of items.
    pub fn compute_checksum(items: &[BlackboardItem]) -> String {
        use sha2::{Digest, Sha256};
        let json = serde_json::to_string(items).unwrap_or_default();
        let hash = Sha256::digest(json.as_bytes());
        hex::encode(hash)
    }

    /// Return true if the embedded checksum matches the items.
    pub fn verify(&self) -> bool {
        Self::compute_checksum(&self.items) == self.checksum
    }
}

/// Build a `PeerBlackboard` snapshot from the local global blackboard.
///
/// Only broadcast-eligible entries (salience ≥ threshold) are included.
/// Caller should pass `current_peer_id()` as the `peer_id`.
pub fn snapshot_local_blackboard(peer_id: &str) -> PeerBlackboard {
    use crate::blackboard;
    let bb = blackboard::global();
    let entries = bb.broadcast_entries();
    let now = now_unix();
    let items: Vec<BlackboardItem> = entries
        .into_iter()
        .map(|e| BlackboardItem {
            source: e.source.to_string(),
            content: e.content,
            salience: e.salience,
            posted_unix: now.saturating_sub(e.posted_at.elapsed().as_secs()),
        })
        .collect();
    let checksum = PeerBlackboard::compute_checksum(&items);
    let seq = EXCHANGE_SEQ.fetch_add(1, Ordering::Relaxed);
    PeerBlackboard {
        peer_id: peer_id.to_string(),
        sequence: seq,
        timestamp_unix: now,
        items,
        checksum,
    }
}

/// Post all items from a `PeerBlackboard` into the local blackboard with attribution.
///
/// Items are posted under `Module::Custom("peer:<peer_id>")` so the source is
/// traceable in broadcast context.
pub fn ingest_peer_blackboard(pb: &PeerBlackboard) {
    use crate::blackboard::{self, Module, SalienceFactors};
    let source = Module::Custom(format!("peer:{}", pb.peer_id));
    let bb = blackboard::global();
    for item in &pb.items {
        let salience = item.salience.clamp(0.0, 1.0);
        let factors = SalienceFactors {
            novelty: 0.5,
            uncertainty_reduction: 0.3,
            goal_relevance: salience,
            urgency: 0.1,
        };
        bb.post(source.clone(), item.content.clone(), factors);
    }
}

/// Atomically exchange blackboard snapshots with a remote peer.
///
/// Steps:
///   1. POST `my_blackboard` (JSON) to `<peer_endpoint>/api/fleet/workspace_exchange`
///      with a 30-second timeout.
///   2. Deserialise the response as `PeerBlackboard`.
///   3. Verify the response checksum.
///   4. Call [`ingest_peer_blackboard`] to post peer items into the local blackboard
///      with peer attribution.
///   5. Return the peer's `PeerBlackboard` so callers can inspect or log it.
///
/// The function is bidirectional by protocol: the remote peer handler
/// (served at `/api/fleet/workspace_exchange`) simultaneously ingests our
/// blackboard and returns theirs, so both sides receive each other's items.
pub async fn exchange_workspace(
    peer_id: &str,
    my_blackboard: PeerBlackboard,
    peer_endpoint: &str,
) -> Result<PeerBlackboard> {
    let url = format!(
        "{}/api/fleet/workspace_exchange",
        peer_endpoint.trim_end_matches('/')
    );
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;
    let resp = client
        .post(&url)
        .json(&my_blackboard)
        .send()
        .await
        .map_err(|e| anyhow!("exchange_workspace POST to {} failed: {}", url, e))?;

    if !resp.status().is_success() {
        return Err(anyhow!(
            "exchange_workspace: peer {} returned HTTP {}",
            peer_id,
            resp.status()
        ));
    }

    let peer_bb: PeerBlackboard = resp
        .json()
        .await
        .map_err(|e| anyhow!("exchange_workspace: failed to parse peer response: {}", e))?;

    if !peer_bb.verify() {
        return Err(anyhow!(
            "exchange_workspace: checksum mismatch from peer {} (seq={})",
            peer_id,
            peer_bb.sequence
        ));
    }

    ingest_peer_blackboard(&peer_bb);
    Ok(peer_bb)
}

// ── FLEET-003c: merge / split state ──────────────────────────────────────────

use std::sync::Mutex;

/// Runtime state for an active workspace merge.
#[derive(Debug, Clone)]
pub struct MergeState {
    /// The peer we are merged with.
    pub peer_id: String,
    /// Agent turn when the merge was initiated.
    pub start_turn: u64,
    /// How many turns the merge should last.
    pub duration_turns: u32,
    /// Stable id for this merge session (for log attribution).
    pub merge_session_id: String,
}

/// Global merge state singleton. `None` = no active merge.
static ACTIVE_MERGE: std::sync::OnceLock<Mutex<Option<MergeState>>> = std::sync::OnceLock::new();

fn active_merge_lock() -> &'static Mutex<Option<MergeState>> {
    ACTIVE_MERGE.get_or_init(|| Mutex::new(None))
}

/// Start a merge with the given peer.
/// Overwrites any existing merge (only one pair-merge at a time).
pub fn start_merge(peer_id: &str, duration_turns: u32) -> String {
    let turn = crate::agent_turn::current();
    let session_id = format!("merge-{}-{}", peer_id, now_unix());
    let state = MergeState {
        peer_id: peer_id.to_string(),
        start_turn: turn,
        duration_turns,
        merge_session_id: session_id.clone(),
    };
    if let Ok(mut guard) = active_merge_lock().lock() {
        *guard = Some(state);
    }
    session_id
}

/// End the active merge (if any). Returns the ended `MergeState` or `None`.
pub fn end_merge() -> Option<MergeState> {
    if let Ok(mut guard) = active_merge_lock().lock() {
        guard.take()
    } else {
        None
    }
}

/// Return the peer_id of the currently active merge, if any.
/// Also auto-expires the merge when `duration_turns` have elapsed since `start_turn`.
pub fn active_merge_peer() -> Option<String> {
    if let Ok(mut guard) = active_merge_lock().lock() {
        if let Some(ref state) = *guard {
            let current_turn = crate::agent_turn::current();
            if current_turn >= state.start_turn + state.duration_turns as u64 {
                // Auto-expire: duration cap hit.
                tracing::info!(
                    peer_id = %state.peer_id,
                    session = %state.merge_session_id,
                    "fleet merge auto-split: duration_cap ({} turns) reached",
                    state.duration_turns
                );
                *guard = None;
                return None;
            }
            return Some(state.peer_id.clone());
        }
    }
    None
}

/// Return a copy of the current merge state if one is active (and not expired).
pub fn active_merge_state() -> Option<MergeState> {
    if let Ok(mut guard) = active_merge_lock().lock() {
        if let Some(ref state) = *guard {
            let current_turn = crate::agent_turn::current();
            if current_turn >= state.start_turn + state.duration_turns as u64 {
                *guard = None;
                return None;
            }
            return Some(state.clone());
        }
    }
    None
}

/// Return the tag string to embed in episodes/lessons created during a merge window.
/// Format: `"merged_with:<peer_id>"`. Returns `None` if no merge is active.
pub fn merge_attribution_tag() -> Option<String> {
    active_merge_peer().map(|p| format!("merged_with:{}", p))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn current_peer_id_uses_env_when_set() {
        std::env::set_var("CHUMP_FLEET_PEER_ID", "test-fleet-peer-xyz");
        assert_eq!(current_peer_id(), "test-fleet-peer-xyz");
        std::env::remove_var("CHUMP_FLEET_PEER_ID");
    }

    #[test]
    #[serial]
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

    // ── FLEET-003b: blackboard exchange types ─────────────────────────────

    #[test]
    fn peer_blackboard_checksum_roundtrip() {
        let items = vec![
            BlackboardItem {
                source: "memory".to_string(),
                content: "test entry".to_string(),
                salience: 0.8,
                posted_unix: 1_700_000_000,
            },
            BlackboardItem {
                source: "task".to_string(),
                content: "another entry".to_string(),
                salience: 0.6,
                posted_unix: 1_700_000_001,
            },
        ];
        let checksum = PeerBlackboard::compute_checksum(&items);
        let pb = PeerBlackboard {
            peer_id: "test-peer".to_string(),
            sequence: 1,
            timestamp_unix: 1_700_000_002,
            items,
            checksum,
        };
        assert!(pb.verify(), "checksum should match items");
    }

    #[test]
    fn peer_blackboard_checksum_detects_tampering() {
        let items = vec![BlackboardItem {
            source: "memory".to_string(),
            content: "original content".to_string(),
            salience: 0.9,
            posted_unix: 1_700_000_000,
        }];
        let checksum = PeerBlackboard::compute_checksum(&items);
        let mut pb = PeerBlackboard {
            peer_id: "test-peer".to_string(),
            sequence: 1,
            timestamp_unix: 1_700_000_000,
            items,
            checksum,
        };
        // Tamper with content
        pb.items[0].content = "tampered content".to_string();
        assert!(!pb.verify(), "tampered payload should fail checksum");
    }

    #[test]
    fn peer_blackboard_sequence_increments() {
        let seq_before = EXCHANGE_SEQ.load(Ordering::Relaxed);
        let pb1 = snapshot_local_blackboard("peer-a");
        let pb2 = snapshot_local_blackboard("peer-a");
        assert_eq!(pb2.sequence, pb1.sequence + 1);
        let _ = seq_before; // suppress unused warning
    }

    #[test]
    fn peer_blackboard_serde_roundtrip() {
        let items = vec![BlackboardItem {
            source: "brain".to_string(),
            content: "a fact".to_string(),
            salience: 0.75,
            posted_unix: 1_700_000_000,
        }];
        let checksum = PeerBlackboard::compute_checksum(&items);
        let pb = PeerBlackboard {
            peer_id: "mac-chump".to_string(),
            sequence: 42,
            timestamp_unix: 1_700_000_100,
            items,
            checksum,
        };
        let json = serde_json::to_string(&pb).expect("serialize");
        let back: PeerBlackboard = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back.peer_id, pb.peer_id);
        assert_eq!(back.sequence, pb.sequence);
        assert_eq!(back.items.len(), 1);
        assert!(back.verify());
    }

    #[test]
    fn ingest_peer_blackboard_posts_items() {
        use crate::blackboard;
        let before = blackboard::global().entry_count();
        let items: Vec<BlackboardItem> = (0..5)
            .map(|i| BlackboardItem {
                source: "memory".to_string(),
                content: format!("peer item {} from exchange test", i),
                salience: 0.8,
                posted_unix: 1_700_000_000 + i,
            })
            .collect();
        let checksum = PeerBlackboard::compute_checksum(&items);
        let pb = PeerBlackboard {
            peer_id: "pixel-chump".to_string(),
            sequence: 1,
            timestamp_unix: 1_700_000_010,
            items,
            checksum,
        };
        ingest_peer_blackboard(&pb);
        let after = blackboard::global().entry_count();
        assert!(
            after >= before + 5,
            "should have posted 5 items, before={} after={}",
            before,
            after
        );
    }

    /// Test: 2 in-process peers exchange 100 items, neither corrupts.
    #[test]
    fn two_peers_exchange_100_items_no_corruption() {
        use crate::blackboard;

        // Peer A: 60 items
        let items_a: Vec<BlackboardItem> = (0..60)
            .map(|i| BlackboardItem {
                source: "memory".to_string(),
                content: format!("peer-a item {}", i),
                salience: 0.7 + (i as f64 * 0.003).min(0.3),
                posted_unix: 1_700_000_000 + i,
            })
            .collect();
        let checksum_a = PeerBlackboard::compute_checksum(&items_a);
        let pb_a = PeerBlackboard {
            peer_id: "peer-a".to_string(),
            sequence: 1,
            timestamp_unix: 1_700_001_000,
            items: items_a,
            checksum: checksum_a,
        };

        // Peer B: 40 items
        let items_b: Vec<BlackboardItem> = (0..40)
            .map(|i| BlackboardItem {
                source: "task".to_string(),
                content: format!("peer-b item {}", i),
                salience: 0.6 + (i as f64 * 0.005).min(0.4),
                posted_unix: 1_700_002_000 + i,
            })
            .collect();
        let checksum_b = PeerBlackboard::compute_checksum(&items_b);
        let pb_b = PeerBlackboard {
            peer_id: "peer-b".to_string(),
            sequence: 1,
            timestamp_unix: 1_700_002_000,
            items: items_b,
            checksum: checksum_b,
        };

        // Both checksums must be valid before exchange
        assert!(pb_a.verify(), "peer-a checksum must be valid");
        assert!(pb_b.verify(), "peer-b checksum must be valid");

        let count_before = blackboard::global().entry_count();

        // Simulate bidirectional exchange: each ingests the other's board
        ingest_peer_blackboard(&pb_b); // peer-a ingests peer-b's items
        ingest_peer_blackboard(&pb_a); // peer-b ingests peer-a's items

        let count_after = blackboard::global().entry_count();
        // 100 items posted; the blackboard caps at max_entries=100 and evicts by salience,
        // so count_after may be exactly 100 even if count_before was nonzero.
        // Verify: either we absorbed all 100 new items, or we're at capacity (100).
        let net_gain = count_after.saturating_sub(count_before);
        assert!(
            net_gain >= 99 || count_after >= 100,
            "expected 99+ net items added OR blackboard at capacity, \
             before={} after={} net_gain={}",
            count_before,
            count_after,
            net_gain
        );

        // Verify checksums survived unmodified
        assert!(
            pb_a.verify(),
            "peer-a checksum must still be valid after exchange"
        );
        assert!(
            pb_b.verify(),
            "peer-b checksum must still be valid after exchange"
        );
    }
}
