//! Shared message queue and central dispatch loop for the platform router
//! (AGT-004 / AGT-006). Decouples platform adapters (Telegram, future Slack,
//! Matrix, …) from the agent loop. Each adapter pushes `PlatformMessage` items
//! into the shared `InputQueue`; `run_message_loop` drains the queue and
//! dispatches each message to a `ChumpAgent` in its own tokio task.
//!
//! ## Peripheral-sensor interrupt (AGT-006 / SENSE-001)
//!
//! `run_message_loop` now runs a [`NewMessageSensor`] alongside the input
//! queue. When a second message arrives while a turn is already in flight, the
//! sensor fires [`SensorKind::NewMessage`] and the loop cancels the stale turn
//! via its [`CancellationToken`]. The agent exits early (see AGT-002's
//! `tokio::select! biased;` in `IterationController::execute`) and the loop
//! immediately starts processing the fresher message.
//!
//! ```text
//!  Adapter  ─push─▶  InputQueue (mpsc, cap 64)
//!                        │
//!                   run_message_loop
//!                    ┌───┴──────────────────────────────────┐
//!                    │  tokio::select! biased;               │
//!                    │   sensor_stream.next() ──cancel──▶   │
//!                    │   rx.recv()  ──spawn dispatch_one──▶ │
//!                    └──────────────────────────────────────┘
//!                              ▼ (one per message)
//!                         dispatch_one(incoming, adapter, cancel)
//!                              │  ChumpAgent::run_with_cancel()
//!                              │  (AGT-002 select! inside)
//!                              ▼
//!                         send_reply back to adapter
//! ```
//!
//! ## Wire-up (src/main.rs --telegram)
//! ```text
//! let (tx, rx) = platform_router::make_queue();
//! tokio::spawn(platform_router::run_message_loop(rx));
//! let adapter = TelegramAdapter::from_env().await?.with_queue(tx);
//! adapter.start().await?;
//! ```

use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::messaging::{IncomingMessage, MessagingAdapter, OutgoingMessage};
use crate::peripheral_sensor::{NewMessageSensor, PeripheralSensor, SensorKind};

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
/// ## Peripheral-sensor interrupt (AGT-006)
///
/// A [`NewMessageSensor`] watches the queue depth. When depth > 0 while a
/// turn is in flight, the sensor fires and the loop cancels the stale turn
/// so the agent can process the fresher context.
///
/// Returns only when the last `InputQueue` sender is dropped (i.e.
/// all adapters have shut down).
pub async fn run_message_loop(mut rx: InputQueueRx) {
    use futures_util::StreamExt;

    // ── Peripheral sensor setup ────────────────────────────────────────────
    // Depth watch: incremented when a message enters dispatch, decremented
    // when dispatch finishes. NewMessageSensor fires when depth > 0 while
    // a turn is already running (i.e. a second message arrived mid-turn).
    let (depth_tx, depth_rx) = tokio::sync::watch::channel(0usize);
    let sensor = NewMessageSensor::new(depth_rx);
    let mut sensor_stream = sensor.events();

    // Cancel token for the most-recently started dispatch task.
    // Replaced on each new message; fired by the sensor handler when
    // a mid-turn interrupt is triggered.
    let active_cancel: Arc<Mutex<Option<CancellationToken>>> = Arc::new(Mutex::new(None));

    loop {
        tokio::select! {
            biased;

            // ── Branch 1: sensor event — new message arrived mid-turn ──────
            Some(ev) = sensor_stream.next() => {
                if ev.kind == SensorKind::NewMessage {
                    let token_opt = active_cancel.lock().expect("platform_router cancel lock poisoned").clone();
                    if let Some(token) = token_opt {
                        let depth = ev.payload["queue_depth"].as_u64().unwrap_or(0);
                        tracing::info!(
                            queue_depth = depth,
                            "platform_router: NewMessage interrupt — cancelling stale turn"
                        );
                        token.cancel();
                    }
                }
            }

            // ── Branch 2: normal incoming message ──────────────────────────
            Some(msg) = rx.recv() => {
                // Increment depth so the sensor can detect mid-turn arrival.
                depth_tx.send_modify(|d| *d += 1);

                let incoming = msg.incoming;
                let adapter = msg.adapter;
                let depth_tx_inner = depth_tx.clone();
                let active_cancel_inner = active_cancel.clone();

                // Fresh cancel token for this turn. Store it so the sensor
                // handler can fire it if a later message arrives mid-turn.
                let cancel = CancellationToken::new();
                *active_cancel.lock().expect("platform_router cancel lock poisoned") = Some(cancel.clone());

                tokio::spawn(async move {
                    if let Err(e) = dispatch_one(&incoming, adapter.as_ref(), cancel).await {
                        tracing::warn!(
                            error = %e,
                            channel = incoming.channel_id.as_str(),
                            "platform_router: dispatch failed"
                        );
                    }

                    // Decrement depth after dispatch (whether success, error, or cancel).
                    depth_tx_inner.send_modify(|d| *d = d.saturating_sub(1));

                    // Clear our token slot. A newer turn may have already replaced
                    // it — we only clear if it's still pointing at a cancelled token
                    // to avoid clobbering an in-flight newer turn's token.
                    let mut guard = active_cancel_inner.lock().expect("platform_router cancel lock poisoned");
                    if let Some(ref t) = *guard {
                        if t.is_cancelled() {
                            *guard = None;
                        }
                    }
                });
            }

            else => break,
        }
    }
}

/// Build the agent, run one turn with the provided cancel token, and send the
/// reply back through the adapter.
///
/// The `cancel` token is passed to [`ChumpAgent::run_with_cancel`] (AGT-006),
/// which also registers it in the global [`cancel_registry`] so `/api/stop`
/// still works during platform-router turns.
async fn dispatch_one(
    incoming: &IncomingMessage,
    adapter: &dyn MessagingAdapter,
    cancel: CancellationToken,
) -> anyhow::Result<()> {
    let (agent, ready_session) = crate::agent_factory::build_chump_agent_cli()?;
    let running = ready_session.start();
    let outcome = agent.run_with_cancel(&incoming.content, cancel).await?;
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

    /// When the sensor fires mid-turn, the active cancel token must be cancelled.
    /// This test drives the sensor watch directly without spinning up a real agent.
    #[tokio::test]
    async fn sensor_cancels_active_token_on_new_message() {
        use crate::peripheral_sensor::{NewMessageSensor, PeripheralSensor, SensorKind};
        use futures_util::StreamExt;

        // Simulate: depth goes 0 → 1 (new message arrived mid-turn)
        let (depth_tx, depth_rx) = tokio::sync::watch::channel(0usize);
        let sensor = NewMessageSensor::new(depth_rx);
        let mut stream = sensor.events();

        // Register a token as the "active turn"
        let token = CancellationToken::new();
        let active: Arc<Mutex<Option<CancellationToken>>> =
            Arc::new(Mutex::new(Some(token.clone())));

        // Trigger the sensor
        depth_tx.send(1).unwrap();

        // Drain one sensor event
        let ev = tokio::time::timeout(std::time::Duration::from_millis(200), stream.next())
            .await
            .expect("sensor must fire within 200ms")
            .expect("stream has event");

        assert_eq!(ev.kind, SensorKind::NewMessage);

        // Simulate what run_message_loop does on sensor event
        if ev.kind == SensorKind::NewMessage {
            if let Some(t) = active.lock().unwrap().clone() {
                t.cancel();
            }
        }

        assert!(token.is_cancelled(), "active token must be cancelled");
    }
}
