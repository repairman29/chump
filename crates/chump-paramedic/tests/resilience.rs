//! INFRA-1645: resilience integration test for the paramedic daemon's LLM
//! health probe — a mock endpoint returns 404 first, then 200, and the
//! daemon must classify the 404 as transient (retry w/ backoff), then
//! recover, logging `model_unavailable` followed by `paramedic_healthy`.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Spawns a tiny HTTP/1.1 mock server that returns 404 for the first
/// `fail_count` requests, then 200 for every request after that.
fn spawn_mock_llm_server(fail_count: usize) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
    let addr = listener.local_addr().expect("local_addr");
    let counter = Arc::new(AtomicUsize::new(0));

    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let n = counter.fetch_add(1, Ordering::SeqCst);
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
        }
    });

    format!("http://{addr}")
}

/// Wait up to `timeout` for `path` to contain an ambient line for
/// `first_kind` followed (later in the file) by one for `second_kind`.
/// Returns true if both appear in that order within the timeout.
fn ambient_has_kind_in_order(
    path: &std::path::Path,
    first_kind: &str,
    second_kind: &str,
    timeout: Duration,
) -> bool {
    let start = Instant::now();
    loop {
        if let Ok(content) = std::fs::read_to_string(path) {
            let first_idx = content.find(&format!("\"kind\":\"{first_kind}\""));
            let second_idx = content.find(&format!("\"kind\":\"{second_kind}\""));
            if let (Some(f), Some(s)) = (first_idx, second_idx) {
                if f < s {
                    return true;
                }
            }
        }
        if start.elapsed() > timeout {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn simulate_404_and_recovery() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let repo_root = tmp.path().to_path_buf();
    std::fs::create_dir_all(repo_root.join(".chump-locks")).expect("mkdir .chump-locks");
    std::fs::create_dir_all(repo_root.join(".chump")).expect("mkdir .chump");

    // Empty (but present) github_cache.db so the daemon's unrelated PR-triage
    // cycle reads a real cache instead of shelling out to `gh` (no network in
    // this test sandbox) — see read_pr_state's cache-first fallback rule.
    {
        let conn = rusqlite::Connection::open(repo_root.join(".chump").join("github_cache.db"))
            .expect("open github_cache.db");
        conn.execute_batch(
            "CREATE TABLE pr_state (
                number              INTEGER PRIMARY KEY,
                head_ref            TEXT,
                head_sha            TEXT,
                mergeable_state     TEXT,
                merge_state_status  TEXT,
                raw_payload_json    TEXT,
                merged_at           TEXT
            );",
        )
        .expect("create pr_state table");
    }

    let url = spawn_mock_llm_server(1);

    // SAFETY (test-only): std::env::set_var is unsafe in edition 2024's
    // signature but this test runs single-threaded w.r.t. these vars and
    // sets them before spawning the daemon thread that reads them.
    unsafe {
        std::env::set_var("PARAMEDIC_LLM_HEALTH_URL", &url);
        std::env::set_var("PARAMEDIC_LLM_MAX_ATTEMPTS", "5");
        std::env::set_var("PARAMEDIC_BACKOFF_BASE_MS", "100");
        std::env::set_var("PARAMEDIC_BACKOFF_MAX_MS", "1000");
        std::env::set_var("CHUMP_PARAMEDIC_FORCE_LEADER", "1");
    }

    let daemon_repo_root = repo_root.clone();
    std::thread::spawn(move || {
        // dry_run=false so the LLM probe (which is independent of PR
        // triage/execute) actually runs; interval is short so the daemon
        // doesn't block for long between cycles.
        let _ = chump_paramedic::paramedic::daemon(1, &daemon_repo_root, false);
    });

    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ok = ambient_has_kind_in_order(
        &ambient_path,
        "model_unavailable",
        "paramedic_healthy",
        Duration::from_secs(30),
    );

    assert!(
        ok,
        "expected ambient.jsonl to contain model_unavailable followed by paramedic_healthy within 30s; content: {:?}",
        std::fs::read_to_string(&ambient_path)
    );
}

#[test]
fn classifies_404_and_429_as_transient_other_4xx_as_permanent() {
    use chump_paramedic::paramedic::classify_llm_status;

    assert!(matches!(
        classify_llm_status(404),
        chump_paramedic::paramedic::LlmProbeOutcome::Transient
    ));
    assert!(matches!(
        classify_llm_status(429),
        chump_paramedic::paramedic::LlmProbeOutcome::Transient
    ));
    assert!(matches!(
        classify_llm_status(401),
        chump_paramedic::paramedic::LlmProbeOutcome::Permanent
    ));
    assert!(matches!(
        classify_llm_status(200),
        chump_paramedic::paramedic::LlmProbeOutcome::Healthy
    ));
}
