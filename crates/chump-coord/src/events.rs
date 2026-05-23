// crates/chump-coord/src/events.rs — INFRA-1758
//
// A2A Layer 1a foundation slice (1/4) — pub/sub event delivery API.
//
// This file ships ONLY the wire types + the `subscribe_events()` stub
// signature. Real implementation (NATS JetStream durable consumer + file
// fallback when NATS unreachable + chaos test + backpressure event) lands
// in subsequent INFRA-1118 follow-up slices.
//
// Why the stub-first approach: nailing the wire shape early lets Layer 2b
// RPC (INFRA-1759) + Layer 2c manifest publish (INFRA-1760 follow-ups) +
// Layer 3d scratchpad (INFRA-1761) all type-check against a stable surface
// before any of them have real impl. The stub returns NotImplemented at
// runtime; only the compile-time contract is binding here.

use serde::{Deserialize, Serialize};

/// Event filter passed to `subscribe_events`. Determines which events the
/// caller wants to see on the returned stream.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EventFilter {
    /// All events the broker delivers to this session.
    All,
    /// Only events with this exact `kind`.
    Kind(String),
    /// Only events from this exact `session_id`.
    Session(String),
    /// Any event whose `kind` is in this set.
    Kinds(Vec<String>),
}

impl EventFilter {
    /// Whether this filter accepts the given event. Useful in the file
    /// fallback path where we can't push the filter down to NATS.
    pub fn matches(&self, event: &CoordEvent) -> bool {
        match self {
            EventFilter::All => true,
            EventFilter::Kind(k) => event.kind == *k,
            EventFilter::Session(s) => event.session_id.as_deref() == Some(s.as_str()),
            EventFilter::Kinds(set) => set.iter().any(|k| k == &event.kind),
        }
    }
}

/// Wire-format event delivered via the pub/sub stream. Compatible with the
/// `.chump-locks/ambient.jsonl` line shape so consumers can swap between
/// NATS subscribe and file tail without struct changes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoordEvent {
    /// ISO-8601 timestamp.
    pub ts: String,
    /// Event kind (e.g. "gap_claimed", "fleet_auth_verified").
    pub kind: String,
    /// Source session ID, if known. Many ambient events do not carry one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Payload as free-form JSON. Keeps wire shape forward-compat with new
    /// event kinds that add fields.
    pub payload: serde_json::Value,
}

/// Error type for the pub/sub layer. Stub returns NotImplemented; real
/// impl will add NatsUnavailable + DeserializeFailed + SubscriberDropped.
#[derive(Debug)]
pub enum SubscribeError {
    /// Stub-only — real impl lands in INFRA-1118 slice 2/4.
    NotImplemented,
    /// Wire-format decode error.
    Deserialize(serde_json::Error),
}

impl std::fmt::Display for SubscribeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SubscribeError::NotImplemented => {
                write!(
                    f,
                    "subscribe_events stub — real impl ships in INFRA-1118 slice 2/4"
                )
            }
            SubscribeError::Deserialize(e) => write!(f, "deserialize failed: {e}"),
        }
    }
}

impl std::error::Error for SubscribeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            SubscribeError::NotImplemented => None,
            SubscribeError::Deserialize(e) => Some(e),
        }
    }
}

impl From<serde_json::Error> for SubscribeError {
    fn from(e: serde_json::Error) -> Self {
        SubscribeError::Deserialize(e)
    }
}

/// Subscribe to coordination events. Returns a stream of `CoordEvent` items
/// matching the filter.
///
/// **This is a stub.** It emits `a2a_subscribe_stub_invoked` to ambient
/// and returns `NotImplemented`. The real implementation lands in INFRA-1118
/// slice 2/4 (NATS JetStream durable consumer + file fallback within 5s on
/// broker drop + reconnect with offset preserved).
///
/// Callers can type-check against this signature today; downstream layers
/// (Layer 2b RPC, Layer 2c manifest publish, Layer 3d scratchpad) all
/// depend on the EventFilter + CoordEvent types being stable, not on the
/// real delivery semantics existing yet.
pub async fn subscribe_events(filter: EventFilter) -> Result<EventStream, SubscribeError> {
    // Emit ambient event so the audit log shows the stub is being invoked
    // (signals which sites need wiring to the real impl in slice 2/4).
    let ts = chrono::Utc::now().to_rfc3339();
    let line = format!(
        r#"{{"ts":"{ts}","kind":"a2a_subscribe_stub_invoked","filter":"{}"}}"#,
        filter_label(&filter)
    );
    let _ = append_ambient(&line);
    let _ = filter; // accept but ignore for stub
    Err(SubscribeError::NotImplemented)
}

/// Returned type alias for the future stream. Today this is a placeholder
/// trait object that the stub never instantiates. Real impl will use
/// `futures::Stream<Item = CoordEvent>` over a tokio channel fed by the
/// NATS push consumer.
pub type EventStream = Box<dyn EventStreamPlaceholder + Send + Unpin>;

/// Sealed trait placeholder so the EventStream type exists for type-checking
/// at the call-sites of subscribe_events. The real impl in slice 2/4 will
/// remove this and use futures::Stream directly.
pub trait EventStreamPlaceholder {}

fn filter_label(f: &EventFilter) -> &'static str {
    match f {
        EventFilter::All => "all",
        EventFilter::Kind(_) => "kind",
        EventFilter::Session(_) => "session",
        EventFilter::Kinds(_) => "kinds",
    }
}

/// Best-effort ambient append. Failures are silently dropped — this is a
/// stub diagnostic, not a critical path.
fn append_ambient(line: &str) -> std::io::Result<()> {
    use std::io::Write;
    let log = std::env::var("CHUMP_AMBIENT_LOG")
        .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)?;
    writeln!(f, "{}", line)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(kind: &str, session: Option<&str>) -> CoordEvent {
        CoordEvent {
            ts: "2026-05-23T00:00:00Z".to_string(),
            kind: kind.to_string(),
            session_id: session.map(String::from),
            payload: serde_json::json!({}),
        }
    }

    #[test]
    fn filter_all_accepts_everything() {
        let f = EventFilter::All;
        assert!(f.matches(&ev("anything", None)));
        assert!(f.matches(&ev("gap_claimed", Some("session-1"))));
    }

    #[test]
    fn filter_kind_exact_match() {
        let f = EventFilter::Kind("gap_claimed".to_string());
        assert!(f.matches(&ev("gap_claimed", None)));
        assert!(!f.matches(&ev("gap_resumed", None)));
    }

    #[test]
    fn filter_session_exact_match() {
        let f = EventFilter::Session("opus-1".to_string());
        assert!(f.matches(&ev("k", Some("opus-1"))));
        assert!(!f.matches(&ev("k", Some("opus-2"))));
        assert!(!f.matches(&ev("k", None)));
    }

    #[test]
    fn filter_kinds_set_match() {
        let f = EventFilter::Kinds(vec!["a".to_string(), "b".to_string()]);
        assert!(f.matches(&ev("a", None)));
        assert!(f.matches(&ev("b", None)));
        assert!(!f.matches(&ev("c", None)));
    }

    #[test]
    fn json_round_trip_event() {
        let e = CoordEvent {
            ts: "2026-05-23T01:02:03Z".to_string(),
            kind: "test".to_string(),
            session_id: Some("s1".to_string()),
            payload: serde_json::json!({"key": "value", "n": 42}),
        };
        let j = serde_json::to_string(&e).unwrap();
        let back: CoordEvent = serde_json::from_str(&j).unwrap();
        assert_eq!(e, back);
    }

    #[test]
    fn json_round_trip_filter() {
        for f in [
            EventFilter::All,
            EventFilter::Kind("foo".to_string()),
            EventFilter::Session("s".to_string()),
            EventFilter::Kinds(vec!["a".to_string(), "b".to_string()]),
        ] {
            let j = serde_json::to_string(&f).unwrap();
            let back: EventFilter = serde_json::from_str(&j).unwrap();
            assert_eq!(f, back);
        }
    }

    #[tokio::test]
    async fn stub_returns_not_implemented() {
        let res = subscribe_events(EventFilter::All).await;
        match res {
            Err(SubscribeError::NotImplemented) => {}
            // INFRA-1832: cannot debug-print the Ok arm because the trait
            // object `dyn EventStreamPlaceholder + Send + Unpin` doesn't
            // impl Debug; split arms instead so the SubscribeError error
            // (which does impl Debug) prints when we hit a non-stub variant.
            Ok(_) => panic!("expected NotImplemented, got Ok(stream)"),
            Err(e) => panic!("expected NotImplemented, got {e:?}"),
        }
    }
}
