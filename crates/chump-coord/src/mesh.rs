// crates/chump-coord/src/mesh.rs — INFRA-1802 / INFRA-1815 / INFRA-2248
//
// Mesh pub/sub transport abstraction for cross-Opus / cross-machine
// coordination. The trait shape originates from the internal sibling repo's
// crates/coord/src/mesh/abstract_impl.rs (MIT-licensed); ported and
// adapted from the multi-robot swarm domain to LLM-agent fleet:
//   - "robot" → "agent" / "session" in operator-facing strings
//   - channel namespace adapted: gap_issued, gap_claimed, gap_shipped,
//     pr_state, curator_heartbeat, session_heartbeat, opus_dm, fleet_consensus
//   - signature field reserved for META-061 Layer 5/6 signed provenance
//   - BandwidthBudget + MessageQueue lifted verbatim (INFRA-1804 fold-in;
//     that gap closes on this ship)
//
// INFRA-1815 mesh-bridge migration path:
// Once the internal sibling repo's `coord-mesh` crate ships (Side A,
// tracked in INFRA-1815-sideA), activating the `mesh-bridge` feature flag
// in chump-coord causes the types here to be replaced by re-exports from
// `coord-mesh`. The current hand-rolled types and the eventual coord-mesh
// types are wire-compatible (same serde shapes, additive-only evolution
// rule documented in CP-008).
//
// Without `mesh-bridge`: this file's types are the canonical source.
// With `mesh-bridge`:    coord-mesh types take precedence via re-export
//                        in lib.rs; this file is still compiled but
//                        consumers should prefer `chump_coord::mesh_bridge::*`.
//
// This file ships the trait + Message/Channel/AckMessage types, a stub
// impl (NotImplemented placeholder), and `LocalProcessTransport` — an
// in-memory single-node pub-sub default impl backed by
// `tokio::sync::broadcast` that satisfies the trait completely with no
// external dependencies (INFRA-2248). The real NATS-backed implementation
// lands as INFRA-1758 slice 2/4; LoRa- and NATS-specific tuning stay in
// the internal sibling repo (no internal IP copied here — see AC7).

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

/// A message that transits the mesh. Wire-format-compatible with the
/// canonical ambient.jsonl line shape so consumers can swap NATS subscribe
/// and file tail without struct changes.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Message {
    /// Unique identifier for ack tracking.
    pub id: String,
    /// When the message was created (ISO 8601).
    pub timestamp: String,
    /// Channel (topic) for this message.
    pub channel: String,
    /// Message payload (opaque bytes from the mesh perspective; typically
    /// JSON-encoded application data).
    pub payload: Vec<u8>,
    /// Source agent session_id.
    pub source: String,
    /// Reserved for META-061 Layer 5/6 signed-provenance work
    /// (Ed25519 signature over id+timestamp+channel+payload+source).
    pub signature: Option<Vec<u8>>,
}

/// Acknowledgment for a delivered message.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AckMessage {
    /// Which message this acks.
    pub message_id: String,
    /// When the ack was sent.
    pub timestamp: String,
    /// Who is acking (session_id).
    pub source: String,
}

/// Channel identifier (namespace for routing). Implementations map this
/// to NATS subjects, file inboxes, or in-memory broadcast channels.
#[derive(Clone, Debug, Serialize, Deserialize, Hash, PartialEq, Eq)]
pub struct Channel {
    pub name: String,
}

impl Channel {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
        }
    }
}

/// Channel namespace helpers — adapted for chump's LLM-agent fleet from
/// the proprietary swarm-coord namespace (mission/issued, robot/heartbeat,
/// swarm/consensus).
pub mod channels {
    use super::Channel;

    /// Per-gap issuance stream. Fired when a gap is filed/reserved.
    pub fn gap_issued(gap_id: &str) -> Channel {
        Channel::new(&format!("gap/issued/{}", gap_id))
    }

    /// Per-gap claim-state stream. Used by sessions that want to react
    /// when a gap they care about is claimed/released.
    pub fn gap_claimed(gap_id: &str) -> Channel {
        Channel::new(&format!("gap/claimed/{}", gap_id))
    }

    /// Per-gap ship stream. Fired when a gap's PR merges and the gap closes.
    pub fn gap_shipped(gap_id: &str) -> Channel {
        Channel::new(&format!("gap/shipped/{}", gap_id))
    }

    /// Per-PR state-transition stream (open/behind/mergeable/merged).
    pub fn pr_state(pr_number: u64) -> Channel {
        Channel::new(&format!("pr/state/{}", pr_number))
    }

    /// Per-curator heartbeat. Subscribers detect silent-curator transitions
    /// when this channel goes quiet past the manifest TTL.
    pub fn curator_heartbeat(curator_name: &str) -> Channel {
        Channel::new(&format!("curator/heartbeat/{}", curator_name))
    }

    /// Per-session heartbeat. Subscribers detect silent-agent transitions
    /// when this channel goes quiet past the manifest TTL.
    pub fn session_heartbeat(session_id: &str) -> Channel {
        Channel::new(&format!("session/heartbeat/{}", session_id))
    }

    /// Direct-message channel for INFRA-1115 addressed-async DMs.
    /// `recipient_session_id` is the inbox owner.
    pub fn opus_dm(recipient_session_id: &str) -> Channel {
        Channel::new(&format!("dm/{}", recipient_session_id))
    }

    /// Fleet-wide consensus voting channel (META-061 Layer 4, INFRA-1803).
    pub fn fleet_consensus(topic: &str) -> Channel {
        Channel::new(&format!("fleet/consensus/{}", topic))
    }

    /// Per-PR auto-merge progress stream for cross-session visibility.
    pub fn pr_progress(pr_number: u64) -> Channel {
        Channel::new(&format!("pr/progress/{}", pr_number))
    }

    /// Ambient broadcast — every event landing in .chump-locks/ambient.jsonl
    /// re-publishes here so NATS subscribers see it without polling the
    /// file.
    pub fn ambient_broadcast() -> Channel {
        Channel::new("ambient/broadcast")
    }
}

/// Bandwidth budget tracking — ported from the internal sibling repo's
/// crates/coord/src/mesh/abstract_impl.rs (MIT-licensed); 'bytes' framing
/// kept as-is (INFRA-1804 fold-in), callers may treat units as tokens.
#[derive(Clone, Debug)]
pub struct BandwidthBudget {
    /// Bytes remaining in current window.
    pub remaining: usize,
    /// Total bytes available per window.
    pub total: usize,
    /// Window duration (seconds).
    pub window_seconds: u32,
    /// When current window started.
    pub window_start: String,
}

impl BandwidthBudget {
    /// Create a new bandwidth budget.
    pub fn new(total_bytes: usize, window_seconds: u32) -> Self {
        Self {
            remaining: total_bytes,
            total: total_bytes,
            window_seconds,
            window_start: chrono::Utc::now().to_rfc3339(),
        }
    }

    /// Check if there's enough budget for a message.
    pub fn can_send(&self, message_size: usize) -> bool {
        self.remaining >= message_size
    }

    /// Deduct from budget after sending.
    pub fn deduct(&mut self, message_size: usize) {
        if self.remaining >= message_size {
            self.remaining -= message_size;
        }
    }

    /// Reset budget for new window.
    pub fn reset(&mut self) {
        self.remaining = self.total;
        self.window_start = chrono::Utc::now().to_rfc3339();
    }
}

/// Mesh message queue (simulates local queuing for offline operation) —
/// ported from the internal sibling repo's crates/coord/src/mesh/abstract_impl.rs.
#[derive(Clone, Debug)]
pub struct MessageQueue {
    /// Queued messages waiting for transmission.
    pub pending: Vec<Message>,
    /// Maximum queue size before dropping.
    pub max_size: usize,
}

impl MessageQueue {
    /// Create new message queue.
    pub fn new(max_size: usize) -> Self {
        Self {
            pending: Vec::new(),
            max_size,
        }
    }

    /// Enqueue a message. Returns false (drop) if the queue is full.
    pub fn enqueue(&mut self, message: Message) -> bool {
        if self.pending.len() < self.max_size {
            self.pending.push(message);
            true
        } else {
            false
        }
    }

    /// Dequeue next message.
    pub fn dequeue(&mut self) -> Option<Message> {
        if self.pending.is_empty() {
            None
        } else {
            Some(self.pending.remove(0))
        }
    }

    /// Get queue size.
    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// Check if queue is empty.
    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

/// Mesh pub/sub interface. Real impls: NATS-backed (slice 2/4), file-only
/// fallback (slice 3/4), in-memory simulator (test only).
#[async_trait::async_trait]
pub trait MeshTransport: Send + Sync {
    /// Publish a message to a channel.
    async fn publish(&self, channel: &Channel, message: &Message) -> Result<(), MeshError>;

    /// Subscribe to a channel. Returns a receiver that delivers messages
    /// as they arrive.
    async fn subscribe(&self, channel: &Channel)
        -> Result<broadcast::Receiver<Message>, MeshError>;

    /// Wait for an ack on a previously-published message. Times out after
    /// `timeout_ms` milliseconds.
    async fn await_ack(&self, message_id: &str, timeout_ms: u32) -> Result<AckMessage, MeshError>;
}

/// Error type for mesh operations.
#[derive(Debug)]
pub enum MeshError {
    /// Stub-only — real impl lands in INFRA-1758 slice 2/4.
    NotImplemented,
    /// NATS broker is currently unreachable. Caller may retry or fall
    /// back to file inbox per INFRA-1758 fallback semantics.
    BrokerUnreachable,
    /// Wire-format decode error.
    Deserialize(serde_json::Error),
    /// Ack window expired without ack receipt.
    AckTimeout { message_id: String, timeout_ms: u32 },
}

impl std::fmt::Display for MeshError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MeshError::NotImplemented => write!(
                f,
                "mesh transport stub — real NATS impl ships in INFRA-1758 slice 2/4"
            ),
            MeshError::BrokerUnreachable => write!(f, "NATS broker unreachable"),
            MeshError::Deserialize(e) => write!(f, "deserialize failed: {e}"),
            MeshError::AckTimeout {
                message_id,
                timeout_ms,
            } => write!(
                f,
                "ack timeout for message_id={message_id} after {timeout_ms}ms"
            ),
        }
    }
}

impl std::error::Error for MeshError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            MeshError::Deserialize(e) => Some(e),
            _ => None,
        }
    }
}

impl From<serde_json::Error> for MeshError {
    fn from(e: serde_json::Error) -> Self {
        MeshError::Deserialize(e)
    }
}

/// Stub `MeshTransport` implementation — returns NotImplemented for all
/// methods. Lets downstream consumers type-check against the trait while
/// the real NATS-backed impl lands as INFRA-1758 slice 2/4.
pub struct StubMesh;

#[async_trait::async_trait]
impl MeshTransport for StubMesh {
    async fn publish(&self, _channel: &Channel, _message: &Message) -> Result<(), MeshError> {
        Err(MeshError::NotImplemented)
    }

    async fn subscribe(
        &self,
        _channel: &Channel,
    ) -> Result<broadcast::Receiver<Message>, MeshError> {
        Err(MeshError::NotImplemented)
    }

    async fn await_ack(
        &self,
        _message_id: &str,
        _timeout_ms: u32,
    ) -> Result<AckMessage, MeshError> {
        Err(MeshError::NotImplemented)
    }
}

/// In-memory, single-process `MeshTransport` default impl backed by
/// `tokio::sync::broadcast`. Satisfies the trait completely with no
/// external dependencies — the LoRa- and NATS-backed impls that mirror
/// the internal sibling repo's radio/broker layers stay internal.
pub struct LocalProcessTransport {
    channels: std::sync::Mutex<std::collections::HashMap<String, broadcast::Sender<Message>>>,
    acks: std::sync::Mutex<std::collections::HashMap<String, AckMessage>>,
    capacity: usize,
}

impl LocalProcessTransport {
    /// Create a transport with the given per-channel broadcast buffer size.
    pub fn new(capacity: usize) -> Self {
        Self {
            channels: std::sync::Mutex::new(std::collections::HashMap::new()),
            acks: std::sync::Mutex::new(std::collections::HashMap::new()),
            capacity,
        }
    }

    fn sender_for(&self, channel: &Channel) -> broadcast::Sender<Message> {
        let mut channels = self.channels.lock().unwrap();
        channels
            .entry(channel.name.clone())
            .or_insert_with(|| broadcast::channel(self.capacity).0)
            .clone()
    }

    /// Record an ack for a previously-published message. Real transports
    /// would receive this over the wire; in-process callers invoke it
    /// directly to simulate a subscriber acking.
    pub fn record_ack(&self, ack: AckMessage) {
        self.acks.lock().unwrap().insert(ack.message_id.clone(), ack);
    }
}

impl Default for LocalProcessTransport {
    fn default() -> Self {
        Self::new(64)
    }
}

#[async_trait::async_trait]
impl MeshTransport for LocalProcessTransport {
    async fn publish(&self, channel: &Channel, message: &Message) -> Result<(), MeshError> {
        // No subscribers is not an error — mirrors a NATS publish with
        // zero live subscribers.
        let _ = self.sender_for(channel).send(message.clone());
        Ok(())
    }

    async fn subscribe(
        &self,
        channel: &Channel,
    ) -> Result<broadcast::Receiver<Message>, MeshError> {
        Ok(self.sender_for(channel).subscribe())
    }

    async fn await_ack(&self, message_id: &str, timeout_ms: u32) -> Result<AckMessage, MeshError> {
        let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_millis(u64::from(timeout_ms));
        loop {
            if let Some(ack) = self.acks.lock().unwrap().remove(message_id) {
                return Ok(ack);
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(MeshError::AckTimeout {
                    message_id: message_id.to_string(),
                    timeout_ms,
                });
            }
            tokio::time::sleep(tokio::time::Duration::from_millis(5)).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_new_round_trip() {
        let c = Channel::new("test/channel");
        let j = serde_json::to_string(&c).unwrap();
        let back: Channel = serde_json::from_str(&j).unwrap();
        assert_eq!(c, back);
    }

    #[test]
    fn channel_helpers_match_documented_paths() {
        assert_eq!(
            channels::gap_claimed("INFRA-1802").name,
            "gap/claimed/INFRA-1802"
        );
        assert_eq!(
            channels::session_heartbeat("opus-1").name,
            "session/heartbeat/opus-1"
        );
        assert_eq!(channels::opus_dm("opus-target").name, "dm/opus-target");
        assert_eq!(
            channels::fleet_consensus("scale-up").name,
            "fleet/consensus/scale-up"
        );
        assert_eq!(channels::pr_progress(2406).name, "pr/progress/2406");
        assert_eq!(channels::ambient_broadcast().name, "ambient/broadcast");
    }

    #[test]
    fn message_round_trip() {
        let m = Message {
            id: "msg-1".to_string(),
            timestamp: "2026-05-23T01:00:00Z".to_string(),
            channel: "gap/claimed/INFRA-1802".to_string(),
            payload: b"{\"gap\":\"INFRA-1802\"}".to_vec(),
            source: "opus-1".to_string(),
            signature: None,
        };
        let j = serde_json::to_string(&m).unwrap();
        let back: Message = serde_json::from_str(&j).unwrap();
        assert_eq!(back.id, m.id);
        assert_eq!(back.payload, m.payload);
        assert!(back.signature.is_none());
    }

    #[tokio::test]
    async fn stub_returns_not_implemented_for_all_methods() {
        let m = StubMesh;
        let ch = Channel::new("test");
        let msg = Message {
            id: "x".to_string(),
            timestamp: "t".to_string(),
            channel: "test".to_string(),
            payload: vec![],
            source: "s".to_string(),
            signature: None,
        };
        match m.publish(&ch, &msg).await {
            Err(MeshError::NotImplemented) => {}
            _ => panic!("publish should NotImplemented"),
        }
        match m.subscribe(&ch).await {
            Err(MeshError::NotImplemented) => {}
            _ => panic!("subscribe should NotImplemented"),
        }
        match m.await_ack("x", 100).await {
            Err(MeshError::NotImplemented) => {}
            _ => panic!("await_ack should NotImplemented"),
        }
    }

    #[test]
    fn error_display_references_slice() {
        let e = MeshError::NotImplemented;
        assert!(format!("{e}").contains("INFRA-1758"));
    }

    #[test]
    fn bandwidth_budget_tracks_deductions() {
        let mut budget = BandwidthBudget::new(1000, 3600);
        assert!(budget.can_send(500));
        budget.deduct(500);
        assert_eq!(budget.remaining, 500);
        assert!(!budget.can_send(501));
        budget.reset();
        assert_eq!(budget.remaining, 1000);
    }

    #[test]
    fn message_queue_drops_beyond_max_size() {
        let mut queue = MessageQueue::new(2);
        let mk = |id: &str| Message {
            id: id.to_string(),
            timestamp: "t".to_string(),
            channel: "test".to_string(),
            payload: vec![],
            source: "s".to_string(),
            signature: None,
        };
        assert!(queue.enqueue(mk("1")));
        assert!(queue.enqueue(mk("2")));
        assert!(!queue.enqueue(mk("3")));
        assert_eq!(queue.len(), 2);
        assert_eq!(queue.dequeue().unwrap().id, "1");
        assert!(!queue.is_empty());
    }

    #[tokio::test]
    async fn local_process_transport_delivers_to_subscriber() {
        let transport = LocalProcessTransport::default();
        let ch = channels::gap_claimed("INFRA-2248");
        let mut rx = transport.subscribe(&ch).await.unwrap();
        let msg = Message {
            id: "msg-1".to_string(),
            timestamp: "t".to_string(),
            channel: ch.name.clone(),
            payload: b"hi".to_vec(),
            source: "test".to_string(),
            signature: None,
        };
        transport.publish(&ch, &msg).await.unwrap();
        let received = rx.recv().await.unwrap();
        assert_eq!(received.id, "msg-1");
    }

    #[tokio::test]
    async fn local_process_transport_await_ack_times_out_cleanly() {
        let transport = LocalProcessTransport::default();
        let result = transport.await_ack("never-acked", 20).await;
        match result {
            Err(MeshError::AckTimeout { message_id, .. }) => assert_eq!(message_id, "never-acked"),
            _ => panic!("expected AckTimeout"),
        }
    }
}
