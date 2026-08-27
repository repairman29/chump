//! INFRA-1645: integration test for the paramedic LLM-resilience wiring.
//!
//! Runs `call_llm_with_resilience` against a tiny hand-rolled mock HTTP
//! server (no external mocking crate needed) that returns 404 on the first
//! request and 200 on the second, and asserts the ambient log records
//! `model_unavailable` followed by `paramedic_healthy`.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use chump_paramedic::paramedic::call_llm_with_resilience;

fn handle_conn(mut stream: TcpStream, request_count: &Arc<AtomicUsize>) {
    let mut buf = [0u8; 4096];
    let _ = stream.read(&mut buf);
    let n = request_count.fetch_add(1, Ordering::SeqCst);
    let response = if n == 0 {
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string()
    } else {
        let body = "{\"ok\":true}";
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
    };
    let _ = stream.write_all(response.as_bytes());
}

#[test]
fn simulate_404_and_recovery() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock LLM server");
    let addr = listener.local_addr().expect("mock server addr");
    let request_count = Arc::new(AtomicUsize::new(0));
    let rc = request_count.clone();
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            handle_conn(stream, &rc);
        }
    });

    unsafe {
        std::env::set_var("PARAMEDIC_BACKOFF_BASE_MS", "10");
        std::env::set_var("PARAMEDIC_BACKOFF_MAX_MS", "50");
        std::env::set_var("PARAMEDIC_BACKOFF_JITTER", "0.1");
    }

    let repo_root = tempfile::tempdir().expect("tempdir");
    std::fs::create_dir_all(repo_root.path().join(".chump-locks")).expect("mkdir .chump-locks");

    let url = format!("http://{addr}/v1/chat");
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .expect("build client");

    let result = call_llm_with_resilience(&client, &url, repo_root.path(), 5);
    assert!(result.is_ok(), "expected eventual success: {result:?}");

    let ambient_path = repo_root.path().join(".chump-locks").join("ambient.jsonl");
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut contents = String::new();
    while Instant::now() < deadline {
        contents = std::fs::read_to_string(&ambient_path).unwrap_or_default();
        if contents.contains("model_unavailable") && contents.contains("paramedic_healthy") {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }

    let unavailable_idx = contents
        .find("model_unavailable")
        .expect("model_unavailable event present");
    let healthy_idx = contents
        .find("paramedic_healthy")
        .expect("paramedic_healthy event present");
    assert!(
        unavailable_idx < healthy_idx,
        "expected model_unavailable before paramedic_healthy, got: {contents}"
    );
}
