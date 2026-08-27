//! INFRA-1645 (re-do of INFRA-1597): integration test for the paramedic
//! daemon's LLM-model resilience behavior — classify 404 as transient,
//! retry with backoff, recover once the model comes back, and emit
//! structured `model_unavailable` / `paramedic_healthy` events along the
//! way (AC §2).

use chump_paramedic::paramedic::{run_llm_resilience_check, LlmResilienceOutcome};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// Mock LLM endpoint: returns 404 on the first `fail_count` requests, then
/// 200 forever — simulates a model briefly unavailable then recovering.
fn spawn_mock_llm(fail_count: usize) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock LLM listener");
    let addr = listener.local_addr().expect("local_addr");
    let hits = Arc::new(AtomicUsize::new(0));
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let n = hits.fetch_add(1, Ordering::SeqCst);
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let status_line = if n < fail_count {
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            };
            let _ = stream.write_all(status_line.as_bytes());
            let _ = stream.flush();
        }
    });
    format!("http://{addr}")
}

/// AC §2: `cargo test --test resilience` — daemon retries a 404 with
/// backoff, then recovers to `paramedic_healthy` once the mock endpoint
/// starts returning 200. Asserts the ambient log contains
/// `model_unavailable` followed by `paramedic_healthy` within 30 seconds.
#[test]
fn simulate_404_and_recovery() {
    let repo_root = tempfile::tempdir().expect("tempdir");
    // Keep backoff short so the test doesn't burn the 30s budget on sleeps.
    std::env::set_var("PARAMEDIC_BACKOFF_BASE_MS", "10");
    std::env::set_var("PARAMEDIC_BACKOFF_MAX_MS", "50");
    std::env::set_var("PARAMEDIC_BACKOFF_JITTER", "0.1");

    let base_url = spawn_mock_llm(2); // fail twice, then recover

    let start = std::time::Instant::now();
    let outcome = run_llm_resilience_check(&base_url, repo_root.path(), 5, false);
    assert!(
        start.elapsed() < Duration::from_secs(30),
        "resilience check exceeded the 30s AC budget"
    );
    assert_eq!(outcome, LlmResilienceOutcome::Healthy);

    let ambient_path = repo_root.path().join(".chump-locks").join("ambient.jsonl");
    let log = std::fs::read_to_string(&ambient_path).expect("ambient.jsonl written");
    let kinds: Vec<String> = log
        .lines()
        .filter_map(|line| {
            let v: serde_json::Value = serde_json::from_str(line).ok()?;
            v.get("kind")?.as_str().map(|s| s.to_string())
        })
        .collect();

    let first_unavailable = kinds.iter().position(|k| k == "model_unavailable");
    let first_healthy = kinds.iter().position(|k| k == "paramedic_healthy");

    assert!(
        first_unavailable.is_some(),
        "expected model_unavailable in ambient log, got kinds: {kinds:?}"
    );
    assert!(
        first_healthy.is_some(),
        "expected paramedic_healthy in ambient log, got kinds: {kinds:?}"
    );
    assert!(
        first_unavailable.unwrap() < first_healthy.unwrap(),
        "expected model_unavailable BEFORE paramedic_healthy, got kinds: {kinds:?}"
    );
}

/// A non-404 4xx (e.g. 401) should short-circuit as permanent — no retry
/// loop, no eventual paramedic_healthy.
#[test]
fn permanent_4xx_short_circuits() {
    let repo_root = tempfile::tempdir().expect("tempdir");
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("local_addr");
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let _ = stream.write_all(
                b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
        }
    });

    let outcome = run_llm_resilience_check(&format!("http://{addr}"), repo_root.path(), 5, false);
    assert_eq!(outcome, LlmResilienceOutcome::PermanentFailure);

    let ambient_path = repo_root.path().join(".chump-locks").join("ambient.jsonl");
    let log = std::fs::read_to_string(&ambient_path).expect("ambient.jsonl written");
    assert!(log.contains("\"kind\":\"permanent_failure\""));
    assert!(!log.contains("\"kind\":\"paramedic_healthy\""));
}
