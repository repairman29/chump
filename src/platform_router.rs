//! Shared message queue and central dispatch loop for the platform router
//! (AGT-004). Decouples platform adapters (Telegram, future Slack, Matrix, …)
//! from the agent loop. Each adapter pushes `PlatformMessage` items into the
//! shared `InputQueue`; `run_message_loop` drains the queue and dispatches
//! each message to a `ChumpAgent` in its own tokio task.
//!
//! ## Wire-up (src/main.rs --telegram)
//! ```text
//! let (tx, rx) = platform_router::make_queue();
//! tokio::spawn(platform_router::run_message_loop(rx));
//! let adapter = TelegramAdapter::from_env().await?.with_queue(tx);
//! adapter.start().await?;
//! ```

use std::sync::Arc;
use tokio::sync::mpsc;

use crate::messaging::{IncomingMessage, MessagingAdapter, OutgoingMessage};

/// A message arriving from any platform adapter, bundled with a handle
/// back to that adapter so the reply can be routed correctly.
pub struct PlatformMessage {
    pub incoming: IncomingMessage,
    pub adapter: Arc<dyn MessagingAdapter>,
}

/// Sender side of the shared platform-message queue.
pub type InputQueue = mpsc::Sender<PlatformMessage>;

/// Receiver side of the shared platform-message queue.
pub type InputQueueRx = mpsc::Receiver<PlatformMessage>;

/// Create a bounded message queue with capacity 64.
///
/// 64 messages is intentionally modest — if the queue is full the
/// adapter logs a warning and drops the message rather than blocking
/// the long-poll loop.
pub fn make_queue() -> (InputQueue, InputQueueRx) {
    mpsc::channel(64)
}

/// Central dispatch loop: reads from `rx`, spawns a task per message,
/// and routes the reply back through the originating adapter.
///
/// Returns only when the last `InputQueue` sender is dropped (i.e.
/// all adapters have shut down).
pub async fn run_message_loop(mut rx: InputQueueRx) {
    while let Some(msg) = rx.recv().await {
        let incoming = msg.incoming;
        let adapter = msg.adapter;
        tokio::spawn(async move {
            if let Err(e) = dispatch_one(&incoming, adapter.as_ref()).await {
                tracing::warn!(
                    error = %e,
                    channel = incoming.channel_id.as_str(),
                    "platform_router: dispatch failed"
                );
            }
        });
    }
}

/// Build the agent, run one turn, and send the reply back through the adapter.
///
/// Mirrors what `TelegramAdapter::handle_incoming()` does today so there's no
/// behaviour divergence — just the coupling is removed.
async fn dispatch_one(
    incoming: &IncomingMessage,
    adapter: &dyn MessagingAdapter,
) -> anyhow::Result<()> {
    let (agent, ready_session) = crate::discord::build_chump_agent_cli()?;
    let running = ready_session.start();
    let outcome = agent.run(&incoming.content).await?;
    running.close();
    let reply = crate::thinking_strip::strip_for_public_reply(&outcome.reply);
    adapter
        .send_reply(incoming, OutgoingMessage::text(reply))
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::messaging::{ApprovalResponse, OutgoingMessage};
    use anyhow::Result;
    use async_trait::async_trait;

    // Minimal no-op adapter used in tests — avoids any real network calls.
    struct NopAdapter;

    #[async_trait]
    impl MessagingAdapter for NopAdapter {
        fn platform_name(&self) -> &str {
            "nop"
        }
        async fn start(&self) -> Result<()> {
            Ok(())
        }
        async fn send_reply(&self, _: &IncomingMessage, _: OutgoingMessage) -> Result<()> {
            Ok(())
        }
        async fn send_dm(&self, _: &str, _: OutgoingMessage) -> Result<()> {
            Ok(())
        }
        async fn request_approval(&self, _: &str, _: &str, _: u64) -> Result<ApprovalResponse> {
            Ok(ApprovalResponse::Pending)
        }
    }

    fn make_incoming() -> IncomingMessage {
        IncomingMessage {
            channel_id: "nop:chan-1".into(),
            sender_id: "user-1".into(),
            sender_display: "Tester".into(),
            content: "hello".into(),
            is_dm: false,
            attachments: vec![],
            platform_metadata: serde_json::Value::Null,
        }
    }

    /// A `PlatformMessage` pushed into the queue must be immediately
    /// retrievable via `try_recv`.
    #[test]
    fn queue_receives_platform_message() {
        let (tx, mut rx) = make_queue();
        let msg = PlatformMessage {
            incoming: make_incoming(),
            adapter: Arc::new(NopAdapter),
        };
        tx.try_send(msg)
            .expect("send should succeed on empty queue");
        let received = rx.try_recv().expect("message must be present after send");
        assert_eq!(received.incoming.channel_id, "nop:chan-1");
    }

    /// The queue must be bounded at exactly 64 slots: the 65th `try_send`
    /// must return `Err(Full(...))`.
    #[test]
    fn make_queue_is_bounded_64() {
        let (tx, _rx) = make_queue();
        for i in 0..64 {
            let msg = PlatformMessage {
                incoming: IncomingMessage {
                    channel_id: format!("nop:chan-{}", i),
                    sender_id: format!("user-{}", i),
                    sender_display: "Tester".into(),
                    content: "msg".into(),
                    is_dm: false,
                    attachments: vec![],
                    platform_metadata: serde_json::Value::Null,
                },
                adapter: Arc::new(NopAdapter),
            };
            tx.try_send(msg)
                .unwrap_or_else(|_| panic!("slot {} should be available", i));
        }
        // 65th send must fail with Full.
        let overflow = PlatformMessage {
            incoming: make_incoming(),
            adapter: Arc::new(NopAdapter),
        };
        match tx.try_send(overflow) {
            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                // expected — capacity is exactly 64
            }
            other => panic!("expected TrySendError::Full, got {:?}", other.map(|_| ())),
        }
    }
}
