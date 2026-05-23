// crates/chump-coord/src/mesh.rs — INFRA-1802
//
// Mesh pub/sub transport abstraction for cross-Opus / cross-machine
// coordination. The trait shape originates from chump-proprietary's
// crates/coord/src/mesh/abstract_impl.rs (MIT-licensed); ported and
// adapted from the multi-robot swarm domain to LLM-agent fleet:
//   - "robot" → "agent" / "session" in operator-facing strings
//   - channel namespace adapted: gap_claimed, session_heartbeat,
//     opus_dm, fleet_consensus
//   - signature field reserved for META-061 Layer 5/6 signed provenance
//
// This file ships the trait + Message/Channel/AckMessage types + a stub
// impl that returns NotImplemented. Real NATS-backed implementation lands
// as INFRA-1758 slice 2/4 (the foundation's existing follow-up). Cargo
// build for chump-coord stays standalone — no extra deps; tokio::sync is
// already in the crate's deps from existing modules.

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

    /// Per-gap claim-state stream. Used by sessions that want to react
    /// when a gap they care about is claimed/released.
    pub fn gap_claimed(gap_id: &str) -> Channel {
        Channel::new(&format!("gap/claimed/{}", gap_id))
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
}
