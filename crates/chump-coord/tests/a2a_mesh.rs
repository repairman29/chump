// crates/chump-coord/tests/a2a_mesh.rs — INFRA-1802
//
// Integration test for the mesh transport abstraction ported from
// chump-proprietary. Validates the trait shape compiles, channel
// namespaces match the documented paths, Message/Channel JSON
// round-trip, and the stub returns NotImplemented across the surface.

use chump_coord::mesh::{
    channels, AckMessage, Channel, MeshError, MeshTransport, Message, StubMesh,
};

#[test]
fn channel_construction() {
    let c = Channel::new("test/channel");
    assert_eq!(c.name, "test/channel");
}

#[test]
fn channel_namespace_helpers_pinned() {
    // If any of these change, downstream subscribers need migration.
    let pairs: Vec<(Channel, &'static str)> = vec![
        (
            channels::gap_claimed("INFRA-9999"),
            "gap/claimed/INFRA-9999",
        ),
        (
            channels::session_heartbeat("opus-x"),
            "session/heartbeat/opus-x",
        ),
        (channels::opus_dm("recipient-1"), "dm/recipient-1"),
        (
            channels::fleet_consensus("scale-up"),
            "fleet/consensus/scale-up",
        ),
        (channels::pr_progress(2406), "pr/progress/2406"),
        (channels::ambient_broadcast(), "ambient/broadcast"),
    ];
    for (chan, expected) in pairs {
        assert_eq!(chan.name, expected, "channel namespace drift: {expected}");
    }
}

#[test]
fn message_json_round_trip() {
    let m = Message {
        id: "msg-abc".to_string(),
        timestamp: "2026-05-23T15:00:00Z".to_string(),
        channel: "dm/curator-opus-ci-audit-2026-05-23".to_string(),
        payload: serde_json::to_vec(&serde_json::json!({"body": "test"})).unwrap(),
        source: "orchestrator-opus-2026-05-23".to_string(),
        signature: None,
    };
    let j = serde_json::to_string(&m).expect("serialize");
    let back: Message = serde_json::from_str(&j).expect("deserialize");
    assert_eq!(back.id, m.id);
    assert_eq!(back.channel, m.channel);
    assert_eq!(back.payload, m.payload);
    assert_eq!(back.source, m.source);
}

#[test]
fn ack_message_json_round_trip() {
    let ack = AckMessage {
        message_id: "msg-abc".to_string(),
        timestamp: "2026-05-23T15:00:05Z".to_string(),
        source: "curator-opus-ci-audit-2026-05-23".to_string(),
    };
    let j = serde_json::to_string(&ack).unwrap();
    let back: AckMessage = serde_json::from_str(&j).unwrap();
    assert_eq!(back.message_id, "msg-abc");
}

#[test]
fn message_with_signature_round_trip() {
    // Reserved field for META-061 Layer 5/6 — must serialize when present.
    let m = Message {
        id: "msg-signed".to_string(),
        timestamp: "2026-05-23T15:00:00Z".to_string(),
        channel: "ambient/broadcast".to_string(),
        payload: vec![1, 2, 3],
        source: "opus-1".to_string(),
        signature: Some(vec![0xde, 0xad, 0xbe, 0xef]),
    };
    let j = serde_json::to_string(&m).unwrap();
    assert!(
        j.contains("\"signature\""),
        "signature must round-trip when Some"
    );
    let back: Message = serde_json::from_str(&j).unwrap();
    assert_eq!(back.signature.unwrap(), vec![0xde, 0xad, 0xbe, 0xef]);
}

#[tokio::test]
async fn stub_publish_returns_not_implemented() {
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
        Err(other) => panic!("expected NotImplemented, got: {}", other),
        Ok(_) => panic!("stub must not return Ok before slice 2/4"),
    }
}

#[tokio::test]
async fn stub_subscribe_returns_not_implemented() {
    let m = StubMesh;
    let ch = Channel::new("ambient/broadcast");
    match m.subscribe(&ch).await {
        Err(MeshError::NotImplemented) => {}
        Err(other) => panic!("expected NotImplemented, got: {}", other),
        Ok(_) => panic!("stub must not return Ok before slice 2/4"),
    }
}

#[tokio::test]
async fn stub_await_ack_returns_not_implemented() {
    let m = StubMesh;
    match m.await_ack("x", 100).await {
        Err(MeshError::NotImplemented) => {}
        Err(other) => panic!("expected NotImplemented, got: {}", other),
        Ok(_) => panic!("stub must not return Ok before slice 2/4"),
    }
}

#[test]
fn mesh_error_display_references_slice() {
    let e = MeshError::NotImplemented;
    let s = format!("{e}");
    assert!(
        s.contains("INFRA-1758"),
        "stub error should reference slice 2/4 gap"
    );
}

#[test]
fn ack_timeout_error_carries_context() {
    let e = MeshError::AckTimeout {
        message_id: "msg-1".to_string(),
        timeout_ms: 5000,
    };
    let s = format!("{e}");
    assert!(
        s.contains("msg-1") && s.contains("5000"),
        "AckTimeout should carry id + ms in Display"
    );
}
