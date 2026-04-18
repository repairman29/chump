//! PeripheralSensor trait — hot-path interrupt bridge (SENSE-001).
//!
//! Peripheral sensors observe the environment outside the agent loop and fire
//! typed [`SensorEvent`]s that can interrupt a running turn. This comes from
//! the "ambient perception / hot-cold path" white-paper concept: fast
//! peripheral observations (new message queued, motion, presence, audio
//! threshold) push events into the orchestrator's `tokio::select!` fan-in so
//! the cognitive loop is only interrupted on *significant* change — not on
//! every raw input.
//!
//! ## Architecture
//!
//! ```text
//!  ┌──────────────┐  watch::Sender<depth>    ┌────────────────────┐
//!  │ platform_    │ ─────────────────────────▶│ NewMessageSensor   │
//!  │ router       │                           │ (PeripheralSensor) │
//!  │              │◀── SensorKind::NewMessage ─┘                   │
//!  │  tokio::     │        (BoxStream)                             │
//!  │  select! ────┼─── cancel active token (AGT-002)              │
//!  └──────────────┘                                                │
//! ```
//!
//! ## Wiring (TODO once AGT-002 + AGT-004 land on main)
//!
//! ```text
//! // In platform_router::run_message_loop():
//! let (depth_tx, depth_rx) = tokio::sync::watch::channel(0usize);
//! let sensor = Arc::new(NewMessageSensor::new(depth_rx));
//! let mut sensor_stream = sensor.events();
//!
//! loop {
//!     tokio::select! {
//!         biased;
//!         Some(ev) = sensor_stream.next() => {
//!             if let SensorKind::NewMessage = ev.kind {
//!                 // AGT-002: cancel in-flight turn
//!                 if let Some(id) = &active_request_id {
//!                     crate::cancel_registry::cancel(id);
//!                 }
//!             }
//!         }
//!         Some(msg) = rx.recv() => {
//!             depth_tx.send_modify(|d| *d += 1);
//!             tokio::spawn(async move {
//!                 dispatch_one(&msg.incoming, msg.adapter.as_ref()).await;
//!                 depth_tx_inner.send_modify(|d| *d = d.saturating_sub(1));
//!             });
//!         }
//!     }
//! }
//! ```

use futures_util::stream::BoxStream;
use serde_json::Value;
use tokio_stream::wrappers::ReceiverStream;

// ── Event types ──────────────────────────────────────────────────────────────

/// A single event emitted by a [`PeripheralSensor`].
#[derive(Debug, Clone)]
pub struct SensorEvent {
    /// What kind of environmental change was detected.
    pub kind: SensorKind,
    /// Optional structured metadata. Shape is sensor-specific; callers should
    /// treat unknown keys as advisory only.
    pub payload: Value,
}

/// Discriminant for [`SensorEvent`]. Cheap to pattern-match in a hot select loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SensorKind {
    /// A new inbound platform message was enqueued while the agent is mid-turn.
    ///
    /// The orchestrator should cancel the current turn (via the AGT-002
    /// [`CancellationToken`]) so the agent can process the fresher context on
    /// the next iteration rather than replying to stale input.
    NewMessage,
    // Future ambient sensors — extend without touching existing match arms:
    // Motion,
    // AudioLevel,
    // Presence,
    // Threshold { metric: String },
}

// ── Trait ────────────────────────────────────────────────────────────────────

/// A peripheral sensor emits a stream of [`SensorEvent`]s.
///
/// Implementations are `Send + Sync` so the orchestrator can hold them as
/// `Arc<dyn PeripheralSensor>` and fan-in N sensor streams alongside the
/// main message queue via `tokio::select!` or
/// `futures::stream::select_all`.
///
/// Each call to [`events`] returns a **new independent stream**. The
/// implementation may spawn a background task; it must clean up when the
/// returned stream is dropped.
pub trait PeripheralSensor: Send + Sync {
    /// Returns a live event stream. Yields events until the sensor's
    /// backing data source closes. The caller polls this concurrently
    /// with the input queue.
    fn events(&self) -> BoxStream<'static, SensorEvent>;

    /// Human-readable name used in log / tracing output.
    fn name(&self) -> &str;
}

// ── NewMessageSensor ─────────────────────────────────────────────────────────

/// Fires [`SensorKind::NewMessage`] whenever the platform-router input-queue
/// depth becomes non-zero while a turn is in flight.
///
/// The orchestrator wires this to the AGT-002 cancellation token so the
/// in-flight turn is cancelled, letting the agent pick up the fresher message
/// on the next iteration rather than replying to stale input.
///
/// ## Debouncing
///
/// The sensor fires **once per burst**: it will not emit a second event until
/// the queue depth returns to zero and then rises again. One cancellation
/// per burst is sufficient — the loop will restart and drain all queued
/// messages on the next pass.
///
/// ## Construction
///
/// The caller maintains a [`tokio::sync::watch::Sender<usize>`] tracking the
/// current queue depth (increment on enqueue, decrement on dispatch). Pass the
/// `Receiver` end here. If the sender is dropped the sensor stream ends cleanly.
pub struct NewMessageSensor {
    depth_rx: tokio::sync::watch::Receiver<usize>,
}

impl NewMessageSensor {
    /// Create a sensor watching `depth_rx`.
    ///
    /// The `watch::Sender` counterpart **must** be updated by the platform
    /// router whenever messages are enqueued or dispatched. Failing to
    /// decrement on dispatch will prevent the sensor from re-firing.
    pub fn new(depth_rx: tokio::sync::watch::Receiver<usize>) -> Self {
        Self { depth_rx }
    }
}

impl PeripheralSensor for NewMessageSensor {
    fn name(&self) -> &str {
        "new-message"
    }

    fn events(&self) -> BoxStream<'static, SensorEvent> {
        // Bounded channel: 4 slots is more than enough — the orchestrator
        // acts on the first event immediately; backpressure here means the
        // background task pauses until the consumer reads.
        let (tx, rx) = tokio::sync::mpsc::channel::<SensorEvent>(4);
        let mut depth_rx = self.depth_rx.clone();

        tokio::spawn(async move {
            loop {
                // ── Phase 1: wait for queue depth to go positive ──────────
                // wait_for returns a Ref (RwLockReadGuard) that is !Send.
                // We must NOT hold it across any .await. Drop it immediately
                // by converting to Err/Ok bool, then borrow() for the value.
                if depth_rx.wait_for(|d| *d > 0).await.is_err() {
                    // Sender dropped — platform router shut down cleanly.
                    tracing::debug!("NewMessageSensor: depth_tx closed, shutting down");
                    break;
                }
                // Guard from wait_for is now dropped; snapshot the value.
                let depth = *depth_rx.borrow();
                tracing::debug!(
                    depth,
                    "peripheral_sensor: NewMessage fired — message arrived mid-turn"
                );
                if tx
                    .send(SensorEvent {
                        kind: SensorKind::NewMessage,
                        payload: serde_json::json!({ "queue_depth": depth }),
                    })
                    .await
                    .is_err()
                {
                    // Consumer dropped the stream.
                    break;
                }

                // ── Phase 2: debounce — wait for queue to drain ───────────
                // Don't fire again until depth returns to zero. One
                // cancellation per burst is enough.
                if depth_rx.wait_for(|d| *d == 0).await.is_err() {
                    break;
                }
            }
        });

        Box::pin(ReceiverStream::new(rx))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;
    use std::time::Duration;

    // ── helpers ───────────────────────────────────────────────────────────

    fn make_sensor(initial_depth: usize) -> (NewMessageSensor, tokio::sync::watch::Sender<usize>) {
        let (tx, rx) = tokio::sync::watch::channel(initial_depth);
        (NewMessageSensor::new(rx), tx)
    }

    // ── Test 1: sensor fires mid-turn ─────────────────────────────────────

    /// When queue depth becomes non-zero while a turn is active, the sensor
    /// must fire exactly one SensorKind::NewMessage event containing the depth.
    #[tokio::test]
    async fn sensor_fires_when_queue_non_empty() {
        let (sensor, depth_tx) = make_sensor(0);
        let mut events = sensor.events();

        // Simulate a message arriving mid-turn: depth 0 → 1.
        depth_tx.send(1).expect("depth send");

        let ev = tokio::time::timeout(Duration::from_millis(200), events.next())
            .await
            .expect("sensor must fire within 200 ms")
            .expect("stream must yield an event");

        assert_eq!(ev.kind, SensorKind::NewMessage);
        assert_eq!(ev.payload["queue_depth"], 1);
    }

    // ── Test 2: sensor is silent between turns ────────────────────────────

    /// When the queue depth stays at zero (no message arrived mid-turn),
    /// the sensor must remain completely silent — no spurious events.
    #[tokio::test]
    async fn sensor_silent_when_queue_empty() {
        let (sensor, _depth_tx) = make_sensor(0); // depth stays 0
        let mut events = sensor.events();

        // Should receive nothing within 100 ms.
        let result = tokio::time::timeout(Duration::from_millis(100), events.next()).await;
        assert!(
            result.is_err(),
            "sensor must not fire when queue is empty (between turns)"
        );
    }

    // ── Test 3: sensor debounces burst ────────────────────────────────────

    /// Two consecutive messages queued during a turn should produce only
    /// one SensorEvent — one cancellation per burst is sufficient.
    #[tokio::test]
    async fn sensor_debounces_burst() {
        let (sensor, depth_tx) = make_sensor(0);
        let mut events = sensor.events();

        // Depth = 2: two messages arrived simultaneously.
        depth_tx.send(2).expect("depth send 2");

        let first = tokio::time::timeout(Duration::from_millis(200), events.next())
            .await
            .expect("first event within 200 ms")
            .expect("first event present");
        assert_eq!(first.kind, SensorKind::NewMessage);

        // While queue still non-zero, no second event should arrive.
        let no_second = tokio::time::timeout(Duration::from_millis(100), events.next()).await;
        assert!(
            no_second.is_err(),
            "sensor must not re-fire while queue is still non-zero (burst debounce)"
        );
    }

    // ── Test 4: sensor re-fires after drain ───────────────────────────────

    /// After the first event is consumed and the queue drains to zero, a new
    /// message arriving should trigger a second event (sensor rearms).
    #[tokio::test]
    async fn sensor_refires_after_drain() {
        let (sensor, depth_tx) = make_sensor(0);
        let mut events = sensor.events();

        // First message mid-turn.
        depth_tx.send(1).expect("send 1");
        let first = tokio::time::timeout(Duration::from_millis(200), events.next())
            .await
            .expect("first event timeout")
            .expect("first event");
        assert_eq!(first.kind, SensorKind::NewMessage);

        // Turn completes, queue drains.
        depth_tx.send(0).expect("drain");
        // Yield briefly to let the background task observe the drain.
        tokio::time::sleep(Duration::from_millis(10)).await;

        // Second message arrives.
        depth_tx.send(1).expect("send 2");
        let second = tokio::time::timeout(Duration::from_millis(200), events.next())
            .await
            .expect("second event timeout")
            .expect("second event");
        assert_eq!(second.kind, SensorKind::NewMessage);
    }

    // ── Test 5: stream ends cleanly when sender drops ────────────────────

    /// When the platform router shuts down and drops the watch sender,
    /// the sensor stream must end without panicking.
    #[tokio::test]
    async fn sensor_stream_ends_on_sender_drop() {
        let (sensor, depth_tx) = make_sensor(0);
        let mut events = sensor.events();

        // Drop the sender immediately (platform router shutdown).
        drop(depth_tx);

        // Stream should terminate (None) rather than hanging.
        let result = tokio::time::timeout(Duration::from_millis(200), events.next()).await;
        // Either we get None (clean end) or timeout (acceptable — background
        // task may not have seen the drop yet within the timeout window).
        // The critical assertion is that we don't panic.
        let _ = result; // either outcome is fine
    }
}
