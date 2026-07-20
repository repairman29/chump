// crates/chump-coord/tests/mesh_local.rs — INFRA-2248
//
// Integration test for `LocalProcessTransport`, the in-memory single-node
// pub-sub default impl of `MeshTransport`. Covers: publish/subscribe
// delivery on a named channel, and `await_ack` timing out cleanly when
// no ack is ever recorded.

use chump_coord::mesh::{channels, AckMessage, Channel, LocalProcessTransport, Message, MeshError};
use chump_coord::mesh::MeshTransport;

fn sample_message(id: &str, channel: &str) -> Message {
    Message {
        id: id.to_string(),
        timestamp: "2026-07-19T00:00:00Z".to_string(),
        channel: channel.to_string(),
        payload: b"payload".to_vec(),
        source: "test-session".to_string(),
        signature: None,
    }
}

#[tokio::test]
async fn publish_then_subscriber_receives() {
    let transport = LocalProcessTransport::default();
    let ch = channels::gap_claimed("INFRA-2248");

    let mut rx = transport.subscribe(&ch).await.expect("subscribe should succeed");

    let msg = sample_message("msg-1", &ch.name);
    transport
        .publish(&ch, &msg)
        .await
        .expect("publish should succeed");

    let received = rx.recv().await.expect("subscriber should receive message");
    assert_eq!(received.id, "msg-1");
    assert_eq!(received.channel, ch.name);
}

#[tokio::test]
async fn multiple_subscribers_on_same_channel_all_receive() {
    let transport = LocalProcessTransport::default();
    let ch = Channel::new("test/fanout");

    let mut rx_a = transport.subscribe(&ch).await.unwrap();
    let mut rx_b = transport.subscribe(&ch).await.unwrap();

    let msg = sample_message("msg-fanout", &ch.name);
    transport.publish(&ch, &msg).await.unwrap();

    assert_eq!(rx_a.recv().await.unwrap().id, "msg-fanout");
    assert_eq!(rx_b.recv().await.unwrap().id, "msg-fanout");
}

#[tokio::test]
async fn await_ack_times_out_cleanly_when_no_ack_expected() {
    let transport = LocalProcessTransport::default();

    let result = transport.await_ack("never-acked", 25).await;

    match result {
        Err(MeshError::AckTimeout { message_id, timeout_ms }) => {
            assert_eq!(message_id, "never-acked");
            assert_eq!(timeout_ms, 25);
        }
        other => panic!("expected AckTimeout, got {other:?}"),
    }
}

#[tokio::test]
async fn await_ack_resolves_once_recorded() {
    let transport = LocalProcessTransport::default();

    transport.record_ack(AckMessage {
        message_id: "msg-2".to_string(),
        timestamp: "2026-07-19T00:00:01Z".to_string(),
        source: "subscriber-session".to_string(),
    });

    let ack = transport
        .await_ack("msg-2", 200)
        .await
        .expect("ack should resolve immediately since it's pre-recorded");
    assert_eq!(ack.message_id, "msg-2");
}
