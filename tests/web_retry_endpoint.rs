//! INFRA-1013: source-level assertions for error recovery retry endpoints.
//!
//! Verifies that retry counter, log reader, and new route handlers are
//! wired in src/web_server.rs — no binary build needed for source checks.

use std::path::PathBuf;

fn web_server_src() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    std::fs::read_to_string(PathBuf::from(manifest).join("src/web_server.rs"))
        .unwrap_or_else(|e| panic!("cannot read src/web_server.rs: {e}"))
}

fn workflow_timeline_src() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    std::fs::read_to_string(PathBuf::from(manifest).join("web/v2/workflow-timeline.js"))
        .unwrap_or_else(|e| panic!("cannot read web/v2/workflow-timeline.js: {e}"))
}

#[test]
fn retry_counter_statics_present() {
    let src = web_server_src();
    assert!(
        src.contains("RETRY_COUNTER"),
        "RETRY_COUNTER static not found in web_server.rs"
    );
    assert!(
        src.contains("fn get_retry_count"),
        "get_retry_count not found in web_server.rs"
    );
    assert!(
        src.contains("fn inc_retry_count"),
        "inc_retry_count not found in web_server.rs"
    );
    assert!(
        src.contains("fn reset_retry_count"),
        "reset_retry_count not found in web_server.rs"
    );
}

#[test]
fn log_endpoint_handler_present() {
    let src = web_server_src();
    assert!(
        src.contains("async fn handle_get_logs"),
        "handle_get_logs not found in web_server.rs"
    );
    assert!(
        src.contains("fn read_pwa_log_for_request"),
        "read_pwa_log_for_request not found in web_server.rs"
    );
}

#[test]
fn retry_endpoint_handler_present() {
    let src = web_server_src();
    assert!(
        src.contains("async fn handle_gap_work_retry"),
        "handle_gap_work_retry not found in web_server.rs"
    );
}

#[test]
fn retry_route_registered() {
    let src = web_server_src();
    assert!(
        src.contains(r#"/api/gap/work/{id}/retry"#),
        "retry route not registered in router"
    );
}

#[test]
fn log_route_registered() {
    let src = web_server_src();
    assert!(
        src.contains(r#"/api/logs/{request_id}"#),
        "logs route not registered in router"
    );
}

#[test]
fn max_retries_limit_enforced() {
    let src = web_server_src();
    assert!(
        src.contains("MAX_RETRIES") && src.contains("max_retries_exceeded"),
        "MAX_RETRIES limit or max_retries_exceeded response not found"
    );
}

#[test]
fn stdout_tail_captured_for_failures() {
    let src = web_server_src();
    assert!(
        src.contains("run_subprocess_with_output"),
        "run_subprocess_with_output not found — stdout not captured for failures"
    );
    assert!(
        src.contains("fn last_n_lines"),
        "last_n_lines helper not found in web_server.rs"
    );
}

#[test]
fn emit_pwa_log_full_with_tail() {
    let src = web_server_src();
    assert!(
        src.contains("fn emit_pwa_log_full"),
        "emit_pwa_log_full not found in web_server.rs"
    );
    assert!(
        src.contains("stdout_tail"),
        "stdout_tail field not found in emit_pwa_log_full"
    );
}

#[test]
fn frontend_retry_button_present() {
    let src = workflow_timeline_src();
    assert!(
        src.contains("wf-retry"),
        ".wf-retry class not found in workflow-timeline.js"
    );
    assert!(
        src.contains("retryPhase"),
        "retryPhase method not found in workflow-timeline.js"
    );
}

#[test]
fn frontend_max_retries_constant() {
    let src = workflow_timeline_src();
    assert!(
        src.contains("MAX_RETRIES"),
        "MAX_RETRIES constant not found in workflow-timeline.js"
    );
}

#[test]
fn frontend_log_link_present() {
    let src = workflow_timeline_src();
    assert!(
        src.contains("/api/logs/"),
        "/api/logs/ link not found in workflow-timeline.js"
    );
}
