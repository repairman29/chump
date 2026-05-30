//! Integration tests for chump-mcp-fleet.
//!
//! Spawns the server binary in stdio mode and exercises each of the 5 tools,
//! asserting the structured response shape defined in AC 7 of META-174.
//!
//! Each test sends a JSON-RPC request over stdin and reads the response line
//! from stdout. The binary path is resolved via `CARGO_BIN_EXE_chump-mcp-fleet`
//! (set automatically by cargo test).

use serde_json::{json, Value};
use std::io::Write;
use std::process::{Command, Stdio};

/// Path to the server binary under test.
fn server_bin() -> std::path::PathBuf {
    // CARGO_BIN_EXE_<name> is set by `cargo test` for workspace binaries.
    if let Ok(p) = std::env::var("CARGO_BIN_EXE_chump-mcp-fleet") {
        return std::path::PathBuf::from(p);
    }
    // Fallback: find it relative to the manifest.
    let mut p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../../target/debug/chump-mcp-fleet");
    p
}

/// Send one JSON-RPC request line to the server (with CHUMP_FLEET_WIRE_V1=1)
/// and return the parsed response.
fn call_server(request: &Value) -> Value {
    let bin = server_bin();

    // Use a temp dir for CHUMP_REPO so repo_dir() doesn't fail on missing env.
    let tmp = tempfile::tempdir().expect("tempdir");
    // Create a minimal .chump-locks/inbox directory inside tmp so inbox_drain
    // works without erroring on a missing repo.
    let lock_dir = tmp.path().join(".chump-locks");
    let inbox_dir = lock_dir.join("inbox");
    std::fs::create_dir_all(&inbox_dir).expect("create inbox dir");

    let mut child = Command::new(&bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("CHUMP_FLEET_WIRE_V1", "1")
        .env("CHUMP_REPO", tmp.path())
        .env("CHUMP_LOCK_DIR", &lock_dir)
        .spawn()
        .unwrap_or_else(|e| panic!("spawn {}: {}", bin.display(), e));

    let stdin = child.stdin.as_mut().expect("stdin");
    let req_str = format!("{}\n", serde_json::to_string(request).unwrap());
    stdin.write_all(req_str.as_bytes()).expect("write request");
    drop(child.stdin.take());

    let output = child.wait_with_output().expect("wait_with_output");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let first_line = stdout.lines().next().unwrap_or("");
    serde_json::from_str(first_line)
        .unwrap_or_else(|e| panic!("parse response JSON: {e}\nraw: {first_line}"))
}

// ── helper: assert a response has jsonrpc=2.0 and result (not error) ─────────

fn assert_ok_response(resp: &Value, context: &str) {
    assert_eq!(
        resp.get("jsonrpc").and_then(|v| v.as_str()),
        Some("2.0"),
        "{}: jsonrpc field",
        context
    );
    assert!(
        resp.get("error").is_none() || resp["error"].is_null(),
        "{}: unexpected error: {:?}",
        context,
        resp.get("error")
    );
    assert!(
        resp.get("result").is_some(),
        "{}: missing result field",
        context
    );
}

// ── test: feature flag off exits with informational message ──────────────────

#[test]
fn feature_flag_off_exits_zero() {
    let bin = server_bin();
    let tmp = tempfile::tempdir().expect("tempdir");
    let status = Command::new(&bin)
        .env_remove("CHUMP_FLEET_WIRE_V1")
        .env("CHUMP_REPO", tmp.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("spawn");
    assert!(
        status.success(),
        "binary should exit 0 when CHUMP_FLEET_WIRE_V1 is unset"
    );
}

// ── test: tools/list returns exactly 5 tools ─────────────────────────────────

#[test]
fn tools_list_returns_five_tools() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "tools/list",
        "params": {},
        "id": 1
    }));
    assert_ok_response(&resp, "tools/list");
    let tools = resp["result"]["tools"].as_array().expect("tools array");
    assert_eq!(tools.len(), 5, "expected exactly 5 tools");

    let names: Vec<&str> = tools
        .iter()
        .filter_map(|t| t.get("name").and_then(|v| v.as_str()))
        .collect();
    assert!(
        names.contains(&"mcp__chump_fleet__inbox_drain"),
        "missing inbox_drain"
    );
    assert!(
        names.contains(&"mcp__chump_fleet__broadcast"),
        "missing broadcast"
    );
    assert!(names.contains(&"mcp__chump_fleet__vote"), "missing vote");
    assert!(
        names.contains(&"mcp__chump_fleet__consensus_status"),
        "missing consensus_status"
    );
    assert!(
        names.contains(&"mcp__chump_fleet__capabilities"),
        "missing capabilities"
    );
}

// ── test: inbox_drain — non-existent inbox returns empty messages ─────────────

#[test]
fn inbox_drain_nonexistent_returns_empty() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "mcp__chump_fleet__inbox_drain",
            "arguments": {
                "session_id": "test-session-does-not-exist"
            }
        },
        "id": 2
    }));
    assert_ok_response(&resp, "inbox_drain nonexistent");
    let result = &resp["result"];
    assert_eq!(result.get("success").and_then(|v| v.as_bool()), Some(true));
    let messages = result["messages"].as_array().expect("messages array");
    assert!(
        messages.is_empty(),
        "expected empty messages for missing inbox"
    );
}

// ── test: inbox_drain — invalid session_id rejected ───────────────────────────

#[test]
fn inbox_drain_rejects_bad_session_id() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "mcp__chump_fleet__inbox_drain",
            "arguments": {
                "session_id": "bad session with spaces"
            }
        },
        "id": 3
    }));
    // Should return a JSON-RPC error or a result with success:false
    let has_error = resp.get("error").map(|e| !e.is_null()).unwrap_or(false)
        || resp["result"]
            .get("success")
            .and_then(|v| v.as_bool())
            .unwrap_or(true)
            == false;
    assert!(
        has_error,
        "expected rejection for bad session_id: {:?}",
        resp
    );
}

// ── test: broadcast — missing required field rejected ────────────────────────

#[test]
fn broadcast_rejects_missing_subject() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "mcp__chump_fleet__broadcast",
            "arguments": {
                "event_type": "WARN"
                // subject intentionally missing
            }
        },
        "id": 4
    }));
    let has_error = resp.get("error").map(|e| !e.is_null()).unwrap_or(false);
    assert!(has_error, "expected error for missing subject: {:?}", resp);
}

// ── test: broadcast — invalid event_type rejected ───────────────────────────

#[test]
fn broadcast_rejects_invalid_event_type() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "mcp__chump_fleet__broadcast",
            "arguments": {
                "event_type": "INVALID_TYPE",
                "subject": "test"
            }
        },
        "id": 5
    }));
    let has_error = resp.get("error").map(|e| !e.is_null()).unwrap_or(false);
    assert!(
        has_error,
        "expected error for invalid event_type: {:?}",
        resp
    );
}

// ── test: vote — missing required fields rejected ────────────────────────────

#[test]
fn vote_rejects_missing_corr_id() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "mcp__chump_fleet__vote",
            "arguments": {
                "vote": "yes"
                // corr_id missing
            }
        },
        "id": 6
    }));
    let has_error = resp.get("error").map(|e| !e.is_null()).unwrap_or(false);
    assert!(has_error, "expected error for missing corr_id: {:?}", resp);
}

// ── test: consensus_status — neither corr_id nor all rejected ────────────────

#[test]
fn consensus_status_rejects_empty_params() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "mcp__chump_fleet__consensus_status",
            "arguments": {}
        },
        "id": 7
    }));
    let has_error = resp.get("error").map(|e| !e.is_null()).unwrap_or(false);
    assert!(
        has_error,
        "expected error when neither corr_id nor all provided: {:?}",
        resp
    );
}

// ── test: capabilities — offline fallback returns structured response ─────────

#[test]
fn capabilities_offline_fallback() {
    // With CHUMP_REPO set to a tmp dir that has no NATS, the chump binary
    // will fail; the tool should fall back gracefully to the lock-file scan.
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "mcp__chump_fleet__capabilities",
            "arguments": {}
        },
        "id": 8
    }));
    // In offline mode we expect either:
    //  (a) success:true with source="offline_glob" (NATS unavailable)
    //  (b) success:true with source="nats_kv" (if chump binary happened to work)
    // Either way the top-level result must be present.
    assert_ok_response(&resp, "capabilities");
    let result = &resp["result"];
    assert_eq!(
        result.get("success").and_then(|v| v.as_bool()),
        Some(true),
        "capabilities result.success"
    );
    assert!(
        result.get("source").is_some(),
        "capabilities result.source missing"
    );
}

// ── test: initialize handshake ───────────────────────────────────────────────

#[test]
fn initialize_returns_server_info() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "clientInfo": {"name": "test", "version": "0.0.1"}
        },
        "id": 9
    }));
    assert_ok_response(&resp, "initialize");
    let result = &resp["result"];
    assert_eq!(
        result["serverInfo"]["name"].as_str(),
        Some("chump-mcp-fleet"),
        "serverInfo.name"
    );
    assert!(
        result.get("capabilities").is_some(),
        "initialize missing capabilities"
    );
}

// ── test: unknown method returns -32603 error ─────────────────────────────────

#[test]
fn unknown_method_returns_error() {
    let resp = call_server(&json!({
        "jsonrpc": "2.0",
        "method": "nonexistent/method",
        "params": {},
        "id": 10
    }));
    assert_eq!(resp.get("jsonrpc").and_then(|v| v.as_str()), Some("2.0"));
    assert!(
        resp.get("error").map(|e| !e.is_null()).unwrap_or(false),
        "expected error for unknown method"
    );
}
