//! INFRA-1645: integration test for the paramedic LLM-model resilience path.
//!
//! Spins up a minimal mock HTTP server (std TcpListener — no extra
//! dependency needed) that returns 404 on its first request, then 200 on
//! every request after. Runs `check_llm_model_with_backoff` against it and
//! asserts the daemon's ambient log shows `model_unavailable` followed by
//! `paramedic_healthy` within 30 seconds.

use chump_paramedic::paramedic::check_llm_model_with_backoff;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Starts a background thread serving `http://127.0.0.1:<port>/` that
/// returns 404 for the first `fail_count` requests, then 200.
fn spawn_mock_llm_server(fail_count: usize) -> (String, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
    let addr = listener.local_addr().expect("local_addr");
    let served = Arc::new(AtomicUsize::new(0));

    let handle = std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = match stream {
                Ok(s) => s,
                Err(_) => break,
            };
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);

            let n = served.fetch_add(1, Ordering::SeqCst);
            let (status_line, body) = if n < fail_count {
                ("HTTP/1.1 404 Not Found", "model not found")
            } else {
                ("HTTP/1.1 200 OK", "ok")
            };
            let resp = format!(
                "{status_line}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();

            // Stop after enough requests to cover the retry budget used below.
            if served.load(Ordering::SeqCst) >= fail_count + 3 {
                break;
            }
        }
    });

    (format!("http://{addr}"), handle)
}

#[test]
fn simulate_404_and_recovery() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let repo_root = tmp.path();
    std::fs::create_dir_all(repo_root.join(".chump-locks")).expect("mkdir .chump-locks");

    let (url, _server) = spawn_mock_llm_server(1);

    // Bound the retry budget generously — backoff base defaults to 500ms,
    // so a couple of retries stays well inside the 30s window.
    std::env::set_var("PARAMEDIC_BACKOFF_BASE_MS", "10");
    std::env::set_var("PARAMEDIC_BACKOFF_MAX_MS", "100");

    let deadline = Instant::now() + Duration::from_secs(30);
    let result = check_llm_model_with_backoff(&url, repo_root, "test-machine", 1234, 5);
    assert!(result.is_ok(), "expected recovery, got {result:?}");
    assert!(Instant::now() < deadline, "recovery took longer than 30s");

    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient_path).expect("read ambient.jsonl");

    let unavailable_idx = contents
        .find("\"kind\":\"model_unavailable\"")
        .expect("model_unavailable event present in ambient log");
    let healthy_idx = contents
        .find("\"kind\":\"paramedic_healthy\"")
        .expect("paramedic_healthy event present in ambient log");
    assert!(
        unavailable_idx < healthy_idx,
        "expected model_unavailable to precede paramedic_healthy"
    );
}

#[test]
fn permanent_failure_stops_retrying_immediately() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let repo_root = tmp.path();
    std::fs::create_dir_all(repo_root.join(".chump-locks")).expect("mkdir .chump-locks");

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
    let addr = listener.local_addr().expect("local_addr");
    let handle = std::thread::spawn(move || {
        if let Ok(mut stream) = listener.accept().map(|(s, _)| s) {
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let body = "bad request";
            let resp = format!(
                "HTTP/1.1 400 Bad Request\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();
        }
    });
    let url = format!("http://{addr}");

    let result = check_llm_model_with_backoff(&url, repo_root, "test-machine", 1234, 5);
    assert!(result.is_err(), "expected permanent failure to return Err");
    handle.join().ok();

    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient_path).expect("read ambient.jsonl");
    assert!(
        contents.contains("\"kind\":\"permanent_failure\""),
        "expected permanent_failure event in ambient log"
    );
    assert!(
        !contents.contains("\"kind\":\"model_unavailable\""),
        "permanent failure should not have emitted model_unavailable retries"
    );
}
