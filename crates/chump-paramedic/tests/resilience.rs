//! INFRA-1645: integration test for the LLM-call resilience module.
//!
//! `simulate_404_and_recovery` starts a tiny mock HTTP server that returns
//! 404 on its first two requests, then 200. It drives
//! `call_llm_with_resilience` (the same retry/backoff/event path the
//! paramedic daemon uses for its per-cycle LLM health-check) against that
//! mock server and asserts the ambient log records `model_unavailable`
//! followed by `paramedic_healthy` within 30 seconds.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Spawn a mock LLM endpoint on 127.0.0.1 that 404s `fail_count` times, then
/// returns 200. Returns the "http://host:port" base URL.
fn spawn_mock_llm(fail_count: u32) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
    let addr = listener.local_addr().expect("local_addr");

    std::thread::spawn(move || {
        let mut served = 0u32;
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);

            let response = if served < fail_count {
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            };
            served += 1;
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();

            if served > fail_count {
                break;
            }
        }
    });

    format!("http://{addr}")
}

fn unique_tmp_repo(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "chump-paramedic-resilience-test-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join(".chump-locks")).expect("create tmp repo dirs");
    dir
}

#[test]
fn simulate_404_and_recovery() {
    // Fast, deterministic backoff for the test.
    std::env::set_var("PARAMEDIC_BACKOFF_BASE_MS", "10");
    std::env::set_var("PARAMEDIC_BACKOFF_MAX_MS", "50");
    std::env::set_var("PARAMEDIC_BACKOFF_JITTER", "0.0");

    let repo_root = unique_tmp_repo("simulate-404");
    let url = spawn_mock_llm(2);

    let deadline = Instant::now() + Duration::from_secs(30);
    let outcome = chump_paramedic::llm_resilience::call_llm_with_resilience(&repo_root, &url, 10);
    assert!(
        Instant::now() < deadline,
        "call_llm_with_resilience took longer than the 30s budget"
    );
    let outcome = outcome.expect("resilient call should eventually succeed");
    assert_eq!(outcome.status, 200);
    assert!(
        outcome.attempts >= 3,
        "expected at least 2 retries + 1 success"
    );

    let ambient = std::fs::read_to_string(repo_root.join(".chump-locks").join("ambient.jsonl"))
        .expect("ambient.jsonl should have been written");
    let lines: Vec<&str> = ambient.lines().collect();

    let first_unavailable = lines
        .iter()
        .position(|l| l.contains("\"kind\":\"model_unavailable\""))
        .expect("expected a model_unavailable event");
    let healthy = lines
        .iter()
        .position(|l| l.contains("\"kind\":\"paramedic_healthy\""))
        .expect("expected a paramedic_healthy event");

    assert!(
        first_unavailable < healthy,
        "model_unavailable should precede paramedic_healthy in the log"
    );

    let _ = std::fs::remove_dir_all(&repo_root);
}

#[test]
fn permanent_4xx_is_not_retried_as_transient() {
    std::env::set_var("PARAMEDIC_BACKOFF_BASE_MS", "5");
    std::env::set_var("PARAMEDIC_BACKOFF_MAX_MS", "20");
    std::env::set_var("PARAMEDIC_BACKOFF_JITTER", "0.0");

    let repo_root = unique_tmp_repo("permanent-403");
    let url = spawn_mock_llm_permanent(403);

    let result = chump_paramedic::llm_resilience::call_llm_with_resilience(&repo_root, &url, 10);
    assert!(
        result.is_err(),
        "a 403 should be classified permanent and bail"
    );

    let ambient = std::fs::read_to_string(repo_root.join(".chump-locks").join("ambient.jsonl"))
        .expect("ambient.jsonl should have been written");
    assert!(
        ambient.contains("\"kind\":\"permanent_failure\""),
        "expected a permanent_failure event, got: {ambient}"
    );
    assert!(
        !ambient.contains("\"kind\":\"model_unavailable\""),
        "403 must not be classified as model_unavailable (that's 404-only)"
    );

    let _ = std::fs::remove_dir_all(&repo_root);
}

fn spawn_mock_llm_permanent(status: u16) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
    let addr = listener.local_addr().expect("local_addr");
    std::thread::spawn(move || {
        if let Some(Ok(mut stream)) = listener.incoming().next() {
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let response = format!(
                "HTTP/1.1 {status} Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });
    format!("http://{addr}")
}
