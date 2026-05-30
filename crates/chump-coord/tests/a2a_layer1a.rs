// crates/chump-coord/tests/a2a_layer1a.rs — INFRA-1118
//
// Integration tests for A2A Layer 1a (NATS-primary delivery, file-fallback).
//
// Test structure:
//   Unit tests (no NATS): wire types, filter logic, feature gate (AC#7)
//   NATS tests (skipped if no server): subscribe→publish→receive round-trip,
//     latency p99 < 50ms, backpressure detection (AC#1, AC#2, AC#4)
//
// All NATS tests guard with nats_url_if_available() which returns None and
// prints "skip — no NATS" when the server is unreachable. Never fails the
// build due to missing NATS.

use chump_coord::events::{subscribe_events_with_session, CoordEvent, EventFilter};
use chump_coord::{CoordClient, CoordEvent as LibCoordEvent};
use serde_json::json;
use std::time::{Duration, Instant};

// ── Wire-type and filter tests (no NATS) ────────────────────────────────────

#[test]
fn event_filter_variants_exhaustive() {
    // Compile-time: ensure all EventFilter variants still exist.
    let _ = EventFilter::All;
    let _ = EventFilter::Kind("k".to_string());
    let _ = EventFilter::Session("s".to_string());
    let _ = EventFilter::Kinds(vec![]);
}

#[test]
fn coord_event_round_trip() {
    let e = CoordEvent {
        ts: "2026-05-24T01:02:03Z".to_string(),
        kind: "gap_claimed".to_string(),
        session_id: Some("claim-infra-1118-49539-1779636943".to_string()),
        payload: json!({"gap_id": "INFRA-1118"}),
    };
    let j = serde_json::to_string(&e).expect("serialize");
    let back: CoordEvent = serde_json::from_str(&j).expect("deserialize");
    assert_eq!(e, back, "round-trip lossless");
    assert!(j.contains("\"ts\":\""));
    assert!(j.contains("\"kind\":\"gap_claimed\""));
}

#[test]
fn coord_event_missing_session_id_omitted_in_json() {
    let e = CoordEvent {
        ts: "2026-05-24T00:00:00Z".to_string(),
        kind: "ambient_only_no_session".to_string(),
        session_id: None,
        payload: json!({}),
    };
    let j = serde_json::to_string(&e).expect("serialize");
    assert!(
        !j.contains("session_id"),
        "None session_id should be omitted in JSON: {j}"
    );
}

#[test]
fn filter_matches_logic() {
    let e = CoordEvent {
        ts: "t".to_string(),
        kind: "gap_claimed".to_string(),
        session_id: Some("opus-1".to_string()),
        payload: json!({}),
    };
    assert!(EventFilter::All.matches(&e));
    assert!(EventFilter::Kind("gap_claimed".to_string()).matches(&e));
    assert!(!EventFilter::Kind("gap_resumed".to_string()).matches(&e));
    assert!(EventFilter::Session("opus-1".to_string()).matches(&e));
    assert!(!EventFilter::Session("opus-2".to_string()).matches(&e));
    assert!(EventFilter::Kinds(vec!["gap_claimed".to_string(), "x".to_string()]).matches(&e));
    assert!(!EventFilter::Kinds(vec!["x".to_string(), "y".to_string()]).matches(&e));
}

/// AC#7: CHUMP_A2A_LAYER=0 (default) must return a stream with no NATS required.
#[tokio::test]
async fn layer0_default_no_nats_required() {
    std::env::remove_var("CHUMP_A2A_LAYER");
    let result =
        subscribe_events_with_session(EventFilter::All, Some("test-layer0".to_string())).await;
    assert!(
        result.is_ok(),
        "layer 0 subscribe must succeed without NATS, got: {:?}",
        result.err().map(|e| e.to_string())
    );
}

/// AC#7: CHUMP_A2A_LAYER=1 with no NATS must still return Ok (fallback path).
#[tokio::test]
async fn layer1_no_nats_returns_stream_not_error() {
    std::env::set_var("CHUMP_A2A_LAYER", "1");
    std::env::set_var("CHUMP_NATS_TIMEOUT_MS", "150");
    std::env::set_var("CHUMP_NATS_URL", "nats://127.0.0.1:19999");
    let result =
        subscribe_events_with_session(EventFilter::All, Some("test-layer1-no-nats".to_string()))
            .await;
    assert!(
        result.is_ok(),
        "layer 1 subscribe must return Ok even with NATS unreachable"
    );
    std::env::remove_var("CHUMP_A2A_LAYER");
    std::env::remove_var("CHUMP_NATS_TIMEOUT_MS");
    std::env::remove_var("CHUMP_NATS_URL");
}

/// AC#5 (file-fallback): write an event to ambient.jsonl, subscribe with filter,
/// assert receipt within 500ms. CHUMP_A2A_LAYER=0 (default file-only path).
#[tokio::test]
async fn file_fallback_receives_event_within_500ms() {
    use std::io::Write;

    // Use a temp file so this test never touches the live ambient.jsonl
    let tmp = tempfile::NamedTempFile::new().expect("tempfile");
    let tmp_path = tmp.path().to_str().unwrap().to_string();

    std::env::remove_var("CHUMP_A2A_LAYER"); // layer 0 — file only
    std::env::set_var("CHUMP_AMBIENT_LOG", &tmp_path);

    // Subscribe BEFORE writing — tail-poll starts at EOF, only sees new lines
    let mut stream = subscribe_events_with_session(
        EventFilter::Kind("test_file_fallback".to_string()),
        Some("test-ff-session".to_string()),
    )
    .await
    .expect("subscribe must succeed in layer-0 mode");

    // Small delay so the tokio task positions at EOF before we write
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Write a matching event directly to the ambient log
    let ts = chrono::Utc::now().to_rfc3339();
    let event_line = format!(
        r#"{{"ts":"{ts}","kind":"test_file_fallback","session_id":"test-ff-session","payload":{{}}}}"#
    );
    {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&tmp_path)
            .expect("open tmp log for write");
        writeln!(f, "{event_line}").expect("write event line");
    }

    // Assert receipt within 500ms (file-fallback p99 budget from INFRA-1118 scope)
    let start = Instant::now();
    let received = tokio::time::timeout(Duration::from_millis(500), stream.next())
        .await
        .expect("event not received within 500ms — file-fallback latency budget exceeded")
        .expect("stream ended unexpectedly");

    let elapsed = start.elapsed();
    assert_eq!(
        received.kind, "test_file_fallback",
        "wrong kind: expected test_file_fallback, got {}",
        received.kind
    );
    eprintln!("file-fallback receipt latency: {}ms", elapsed.as_millis());

    std::env::remove_var("CHUMP_AMBIENT_LOG");
}

// ── NATS integration tests (skipped if no server) ───────────────────────────

/// Check if NATS is reachable. Returns the URL if yes, None if should skip.
async fn nats_url_if_available() -> Option<String> {
    let url =
        std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| "nats://127.0.0.1:4222".to_string());
    match tokio::time::timeout(Duration::from_millis(500), async_nats::connect(&url)).await {
        Ok(Ok(_)) => Some(url),
        _ => None,
    }
}

/// AC#1 + AC#2: subscribe → publish → receive round-trip with p99 < 50ms.
///
/// Subscribes on a per-test durable consumer, publishes 20 events through
/// JetStream, measures end-to-end latency from publish call to receipt on the
/// subscriber stream. All 20 must arrive; p99 must be under 50ms.
#[tokio::test]
async fn subscribe_publish_receive_roundtrip_p99_under_50ms() {
    let Some(nats_url) = nats_url_if_available().await else {
        eprintln!(
            "skip — no NATS on {}",
            std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| "nats://127.0.0.1:4222".to_string())
        );
        return;
    };

    std::env::set_var("CHUMP_A2A_LAYER", "1");
    std::env::set_var("CHUMP_NATS_URL", &nats_url);

    let session_id = format!("test-rt-{}", uuid::Uuid::new_v4().simple());
    // Isolate from live fleet state
    let bucket = format!("chump_gaps_rt_{}", uuid::Uuid::new_v4().simple());
    std::env::set_var("CHUMP_NATS_GAP_BUCKET", &bucket);

    // Subscribe first — consumer must exist before we publish
    let mut stream = subscribe_events_with_session(
        EventFilter::Kind("test_roundtrip".to_string()),
        Some(session_id.clone()),
    )
    .await
    .expect("subscribe must succeed with NATS available");

    // Allow subscriber task to establish the JetStream consumer
    tokio::time::sleep(Duration::from_millis(200)).await;

    let client = CoordClient::connect().await.expect("CoordClient connect");

    const N: usize = 20;
    let mut send_times = Vec::with_capacity(N);

    for i in 0..N {
        send_times.push(Instant::now());
        client
            .emit(LibCoordEvent {
                event: "test_roundtrip".to_string(),
                session: session_id.clone(),
                ts: chrono::Utc::now().to_rfc3339(),
                kind: Some("test_roundtrip".to_string()),
                ..Default::default()
            })
            .await
            .unwrap_or_else(|e| panic!("emit {i} failed: {e}"));
    }

    let mut latencies_ms = Vec::with_capacity(N);
    for (i, send_time) in send_times.iter().enumerate() {
        let event = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .unwrap_or_else(|_| panic!("timeout waiting for event {i}"))
            .unwrap_or_else(|| panic!("stream ended before event {i}"));
        let elapsed = send_time.elapsed().as_millis() as u64;
        latencies_ms.push(elapsed);
        assert_eq!(event.kind, "test_roundtrip", "wrong kind at event {i}");
    }

    latencies_ms.sort_unstable();
    let p99_idx = ((N as f64 * 0.99) as usize).min(N - 1);
    let p99_ms = latencies_ms[p99_idx];

    eprintln!(
        "roundtrip latencies (ms): min={} median={} p99={} max={}",
        latencies_ms[0],
        latencies_ms[N / 2],
        p99_ms,
        latencies_ms[N - 1]
    );

    assert!(
        p99_ms < 50,
        "p99 latency {p99_ms}ms exceeds 50ms budget (AC#1)"
    );

    std::env::remove_var("CHUMP_A2A_LAYER");
    std::env::remove_var("CHUMP_NATS_URL");
    std::env::remove_var("CHUMP_NATS_GAP_BUCKET");
}

/// AC#4: Backpressure event (fleet_a2a_backpressure) emitted when pending
/// count exceeds max_ack_pending.
///
/// Sets max_ack_pending=8, publishes 10 events rapidly without draining the
/// consumer, then asserts the ambient log contains fleet_a2a_backpressure.
#[tokio::test]
async fn backpressure_event_emitted_on_slow_consumer() {
    let Some(nats_url) = nats_url_if_available().await else {
        eprintln!("skip — no NATS available");
        return;
    };

    std::env::set_var("CHUMP_A2A_LAYER", "1");
    std::env::set_var("CHUMP_NATS_URL", &nats_url);
    std::env::set_var("CHUMP_A2A_MAX_ACK_PENDING", "8");

    let tmp_log = format!("/tmp/a2a-bp-test-{}.jsonl", uuid::Uuid::new_v4().simple());
    std::env::set_var("CHUMP_AMBIENT_LOG", &tmp_log);

    let session_id = format!("test-bp-{}", uuid::Uuid::new_v4().simple());
    let bucket = format!("chump_gaps_bp_{}", uuid::Uuid::new_v4().simple());
    std::env::set_var("CHUMP_NATS_GAP_BUCKET", &bucket);

    // Subscribe but intentionally do NOT drain — creating slow consumer
    let _stream = subscribe_events_with_session(
        EventFilter::Kind("test_backpressure".to_string()),
        Some(session_id.clone()),
    )
    .await
    .expect("subscribe");

    tokio::time::sleep(Duration::from_millis(200)).await;

    let client = CoordClient::connect().await.expect("CoordClient connect");

    // Publish 10 events fast — exceeds max_ack_pending=8
    for i in 0..10u32 {
        client
            .emit(LibCoordEvent {
                event: "test_backpressure".to_string(),
                session: session_id.clone(),
                ts: chrono::Utc::now().to_rfc3339(),
                kind: Some("test_backpressure".to_string()),
                ..Default::default()
            })
            .await
            .unwrap_or_else(|e| panic!("emit {i}: {e}"));
    }

    // Give subscriber task time to detect and emit backpressure event
    tokio::time::sleep(Duration::from_millis(600)).await;

    let log_contents = std::fs::read_to_string(&tmp_log).unwrap_or_default();
    assert!(
        log_contents.contains("fleet_a2a_backpressure"),
        "expected fleet_a2a_backpressure in ambient log;\nlog contents:\n{log_contents}"
    );

    let _ = std::fs::remove_file(&tmp_log);
    std::env::remove_var("CHUMP_A2A_LAYER");
    std::env::remove_var("CHUMP_NATS_URL");
    std::env::remove_var("CHUMP_A2A_MAX_ACK_PENDING");
    std::env::remove_var("CHUMP_AMBIENT_LOG");
    std::env::remove_var("CHUMP_NATS_GAP_BUCKET");
}
