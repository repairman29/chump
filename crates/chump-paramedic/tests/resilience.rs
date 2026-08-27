//! INFRA-1645: integration test for the paramedic daemon's LLM-resilience
//! path — 404 (model rollout / transient) must back off and retry rather
//! than being treated as a permanent failure. Exercises
//! `llm_health_check_with_backoff`, the same function the daemon loop calls
//! each cycle when `PARAMEDIC_LLM_HEALTH_URL` is configured.

use chump_paramedic::paramedic;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Spawn a mock LLM endpoint on 127.0.0.1 that returns 404 for the first
/// `fail_count` requests, then 200 for every request after. Returns the
/// bound port; the server thread runs for the lifetime of the test process.
fn spawn_mock_llm(fail_count: usize) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock LLM listener");
    let port = listener.local_addr().expect("local_addr").port();
    let seen = Arc::new(AtomicUsize::new(0));

    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 1024];
            // Drain the request (best-effort; we don't need to parse it).
            let _ = stream.read(&mut buf);

            let n = seen.fetch_add(1, Ordering::SeqCst);
            let resp = if n < fail_count {
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            };
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();
        }
    });

    port
}

/// AC §2: starts a health check against a mock server returning 404, then
/// 200, and asserts the daemon's event log contains `model_unavailable`
/// followed by `paramedic_healthy` within 30 seconds.
#[test]
fn simulate_404_and_recovery() {
    let tmp = std::env::temp_dir().join(format!(
        "chump-paramedic-resilience-test-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).expect("create tmp repo root");

    // Keep backoff fast + deterministic so the test doesn't need anywhere
    // near the 30s budget the AC allows.
    unsafe {
        std::env::set_var("PARAMEDIC_BACKOFF_BASE_MS", "10");
        std::env::set_var("PARAMEDIC_BACKOFF_MAX_MS", "50");
        std::env::set_var("PARAMEDIC_BACKOFF_JITTER", "0");
    }

    let port = spawn_mock_llm(1); // fail once (404), then succeed (200).
    let url = format!("http://127.0.0.1:{port}/health");

    let start = Instant::now();
    let result = paramedic::llm_health_check_with_backoff(&url, &tmp, 5);
    let elapsed = start.elapsed();

    unsafe {
        std::env::remove_var("PARAMEDIC_BACKOFF_BASE_MS");
        std::env::remove_var("PARAMEDIC_BACKOFF_MAX_MS");
        std::env::remove_var("PARAMEDIC_BACKOFF_JITTER");
    }

    assert!(result.is_ok(), "expected recovery to succeed: {result:?}");
    assert!(
        elapsed < Duration::from_secs(30),
        "recovery took {elapsed:?}, exceeds the 30s AC budget"
    );

    let ambient_path = tmp.join(".chump-locks").join("ambient.jsonl");
    let content = std::fs::read_to_string(&ambient_path).expect("read ambient.jsonl");
    let kinds: Vec<String> = content
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter_map(|v| v.get("kind").and_then(|k| k.as_str()).map(String::from))
        .collect();

    let unavailable_idx = kinds
        .iter()
        .position(|k| k == "model_unavailable")
        .expect("expected a model_unavailable event");
    let healthy_idx = kinds
        .iter()
        .position(|k| k == "paramedic_healthy")
        .expect("expected a paramedic_healthy event");

    assert!(
        unavailable_idx < healthy_idx,
        "expected model_unavailable before paramedic_healthy, got {kinds:?}"
    );

    let _ = std::fs::remove_dir_all(&tmp);
}

/// A permanent 4xx (not 404/429) must stop retrying immediately and emit
/// `permanent_failure` rather than exhausting the retry budget.
#[test]
fn permanent_failure_does_not_retry() {
    let tmp = std::env::temp_dir().join(format!(
        "chump-paramedic-resilience-test-permanent-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).expect("create tmp repo root");

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock LLM listener");
    let port = listener.local_addr().expect("local_addr").port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let _ = stream.write_all(
                b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
            let _ = stream.flush();
        }
    });

    let url = format!("http://127.0.0.1:{port}/health");
    let result = paramedic::llm_health_check_with_backoff(&url, &tmp, 5);
    assert!(result.is_err(), "expected a permanent failure to bail out");

    let ambient_path = tmp.join(".chump-locks").join("ambient.jsonl");
    let content = std::fs::read_to_string(&ambient_path).expect("read ambient.jsonl");
    assert!(
        content.contains("\"kind\":\"permanent_failure\""),
        "expected permanent_failure event, got: {content}"
    );
    assert!(
        !content.contains("\"kind\":\"paramedic_healthy\""),
        "should not have recovered from a permanent failure"
    );

    let _ = std::fs::remove_dir_all(&tmp);
}
