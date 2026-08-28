//! INFRA-1645: integration test for the paramedic LLM-resilience path.
//!
//! Spins up a tiny raw-HTTP mock server (std::net only — no extra deps) that
//! answers 404 twice, then 200. Drives `run_llm_healthcheck_with_backoff`
//! against it via the same `CurlLlmClient` the daemon uses in production,
//! and asserts the resulting ambient.jsonl log contains a `model_unavailable`
//! event followed by a `paramedic_healthy` event within 30 seconds.

use chump_paramedic::paramedic::{run_llm_healthcheck_with_backoff, CurlLlmClient};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Serve `fail_count` 404 responses, then 200s forever, on a background
/// thread. Returns the bound local address.
fn spawn_mock_llm_server(fail_count: usize) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock LLM listener");
    let addr = listener.local_addr().expect("local_addr");
    let served = Arc::new(AtomicUsize::new(0));

    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            // Drain the request (best-effort; we don't parse it).
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);

            let n = served.fetch_add(1, Ordering::SeqCst);
            let resp = if n < fail_count {
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            };
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();
        }
    });

    addr
}

#[test]
fn simulate_404_and_recovery() {
    // Keep the backoff fast so the test finishes well under 30s.
    std::env::set_var("PARAMEDIC_BACKOFF_BASE_MS", "50");
    std::env::set_var("PARAMEDIC_BACKOFF_MAX_MS", "200");
    std::env::set_var("PARAMEDIC_BACKOFF_JITTER", "0");
    std::env::set_var("PARAMEDIC_LLM_MAX_ATTEMPTS", "10");

    let addr = spawn_mock_llm_server(2);
    let endpoint = format!("http://{addr}/v1/models/dummy");

    let repo_root = tempfile::tempdir().expect("tempdir");
    let mut client = CurlLlmClient {
        endpoint: endpoint.clone(),
    };

    let start = Instant::now();
    let result = run_llm_healthcheck_with_backoff(&mut client, repo_root.path());
    assert!(
        result.is_ok(),
        "expected eventual success after 2 transient 404s, got: {result:?}"
    );
    assert!(
        start.elapsed() < Duration::from_secs(30),
        "healthcheck took too long: {:?}",
        start.elapsed()
    );

    let ambient_path = repo_root.path().join(".chump-locks").join("ambient.jsonl");
    let log = std::fs::read_to_string(&ambient_path).expect("read ambient.jsonl");

    let first_unavailable = log.find("\"kind\":\"model_unavailable\"");
    let first_healthy = log.find("\"kind\":\"paramedic_healthy\"");

    assert!(
        first_unavailable.is_some(),
        "expected a model_unavailable event in ambient log, got:\n{log}"
    );
    assert!(
        first_healthy.is_some(),
        "expected a paramedic_healthy event in ambient log, got:\n{log}"
    );
    assert!(
        first_unavailable.unwrap() < first_healthy.unwrap(),
        "expected model_unavailable to precede paramedic_healthy, got:\n{log}"
    );
}
