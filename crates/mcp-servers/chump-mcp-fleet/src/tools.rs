//! Tool handlers for chump-mcp-fleet.
//!
//! Each `handle_*` function maps to one MCP tool. All are async, take a
//! `serde_json::Value` params blob, and return `anyhow::Result<Value>`.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::process::Command;

// ── helpers ───────────────────────────────────────────────────────────────────

fn repo_dir() -> Result<PathBuf> {
    let path = std::env::var("CHUMP_REPO")
        .or_else(|_| std::env::var("CHUMP_HOME"))
        .map_err(|_| {
            anyhow!("CHUMP_REPO or CHUMP_HOME must be set to the Chump repository root")
        })?;
    let p = PathBuf::from(path.trim());
    if !p.is_dir() {
        return Err(anyhow!("CHUMP_REPO is not a directory: {}", p.display()));
    }
    Ok(p)
}

fn lock_dir() -> Result<PathBuf> {
    let repo = repo_dir()?;
    Ok(std::env::var("CHUMP_LOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo.join(".chump-locks")))
}

/// Reject parameters that look like they reference secrets.
fn reject_secret_leak(s: &str) -> Result<()> {
    if s.to_lowercase().contains(".env") {
        return Err(anyhow!(
            "refusing parameters that reference .env (keep secrets out of MCP tools)"
        ));
    }
    Ok(())
}

/// Safe single-token validator: alphanumeric + `-_/.` only.
fn safe_token(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_/.".contains(c))
}

async fn run_chump(args: &[&str]) -> Result<Value> {
    let mut cmd = Command::new("chump");
    for a in args {
        cmd.arg(a);
    }
    let out = cmd
        .output()
        .await
        .with_context(|| format!("run chump {}", args.join(" ")))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    Ok(json!({
        "success": out.status.success(),
        "exit_code": out.status.code(),
        "stdout": stdout,
        "stderr": stderr,
    }))
}

async fn run_script(script_rel: &str, args: &[String]) -> Result<Value> {
    let repo = repo_dir()?;
    let script = repo.join("scripts").join(script_rel);
    if !script.is_file() {
        return Err(anyhow!(
            "script not found: {} (check CHUMP_REPO)",
            script.display()
        ));
    }
    for a in args {
        reject_secret_leak(a)?;
    }
    let mut cmd = Command::new("bash");
    cmd.arg(&script);
    for a in args {
        cmd.arg(a);
    }
    cmd.current_dir(&repo);
    cmd.env("CHUMP_LOCK_DIR", lock_dir()?.to_string_lossy().as_ref());
    let out = cmd
        .output()
        .await
        .with_context(|| format!("run script {}", script_rel))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    Ok(json!({
        "success": out.status.success(),
        "exit_code": out.status.code(),
        "stdout": stdout,
        "stderr": stderr,
    }))
}

// ── tool: inbox_drain ─────────────────────────────────────────────────────────

/// Read new messages from `.chump-locks/inbox/<session_id>.jsonl` since cursor.
///
/// Params:
/// - `session_id` (required): caller session ID
/// - `advance_cursor` (optional bool, default true): advance the cursor file
///   after reading so the next call only surfaces new messages
pub async fn handle_inbox_drain(params: &Value) -> Result<Value> {
    let session_id = params
        .get("session_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing session_id"))?
        .trim()
        .to_string();
    reject_secret_leak(&session_id)?;
    if !safe_token(&session_id) {
        return Err(anyhow!("invalid session_id: must be alphanumeric + -_/."));
    }

    let advance = params
        .get("advance_cursor")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);

    let lock = lock_dir()?;
    let inbox_dir = lock.join("inbox");
    let inbox_file = inbox_dir.join(format!("{}.jsonl", session_id));
    let cursor_file = inbox_dir.join(format!("{}.cursor", session_id));

    if !inbox_file.is_file() {
        return Ok(json!({
            "success": true,
            "session_id": session_id,
            "messages": [],
            "new_offset": 0,
            "note": "inbox file does not exist yet"
        }));
    }

    // Read cursor offset
    let cursor_offset: u64 = if cursor_file.is_file() {
        std::fs::read_to_string(&cursor_file)
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0)
    } else {
        0
    };

    // Read from offset onward
    let content = std::fs::read_to_string(&inbox_file)
        .with_context(|| format!("read inbox for {}", session_id))?;
    let bytes = content.as_bytes();
    let from = (cursor_offset as usize).min(bytes.len());
    let tail = &bytes[from..];
    let tail_str = String::from_utf8_lossy(tail);

    let mut messages: Vec<Value> = Vec::new();
    for line in tail_str.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(line) {
            Ok(v) => messages.push(v),
            Err(_) => messages.push(json!({ "raw": line })),
        }
    }

    let new_offset = bytes.len() as u64;

    if advance && new_offset > cursor_offset {
        // Write new cursor (best-effort: don't fail the call on cursor write error)
        let _ = std::fs::create_dir_all(&inbox_dir);
        let _ = std::fs::write(&cursor_file, new_offset.to_string());
    }

    Ok(json!({
        "success": true,
        "session_id": session_id,
        "messages": messages,
        "messages_read": messages.len(),
        "previous_offset": cursor_offset,
        "new_offset": new_offset,
    }))
}

// ── tool: broadcast ───────────────────────────────────────────────────────────

/// Emit a structured broadcast event via `scripts/coord/broadcast.sh`.
///
/// Params:
/// - `event_type` (required): one of INTENT | HANDOFF | STUCK | DONE | WARN | ALERT | FEEDBACK
/// - `kind` (required for FEEDBACK/ALERT): sub-type string
/// - `subject` (required): free-text subject / message
/// - `rationale` (optional): reason string
/// - `vote` (optional): vote value for FEEDBACK events
/// - `to` (optional): recipient session ID (for targeted delivery)
/// - `urgency` (optional): INFO | WARN | CRIT | EMERGENCY (default INFO)
pub async fn handle_broadcast(params: &Value) -> Result<Value> {
    let event_type = params
        .get("event_type")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing event_type"))?
        .trim()
        .to_uppercase();

    let valid_types = [
        "INTENT", "HANDOFF", "STUCK", "DONE", "WARN", "ALERT", "FEEDBACK",
    ];
    if !valid_types.contains(&event_type.as_str()) {
        return Err(anyhow!(
            "invalid event_type '{}'; must be one of: {}",
            event_type,
            valid_types.join(", ")
        ));
    }

    let subject = params
        .get("subject")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing subject"))?
        .trim()
        .to_string();
    reject_secret_leak(&subject)?;

    let kind = params
        .get("kind")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if !kind.is_empty() {
        reject_secret_leak(&kind)?;
    }

    let rationale = params
        .get("rationale")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if !rationale.is_empty() {
        reject_secret_leak(&rationale)?;
    }

    let vote_str = params
        .get("vote")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    let to = params
        .get("to")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    let urgency = params
        .get("urgency")
        .and_then(|v| v.as_str())
        .unwrap_or("INFO")
        .trim()
        .to_uppercase();
    let valid_urgencies = ["INFO", "WARN", "CRIT", "EMERGENCY"];
    if !valid_urgencies.contains(&urgency.as_str()) {
        return Err(anyhow!(
            "invalid urgency '{}'; must be one of: INFO, WARN, CRIT, EMERGENCY",
            urgency
        ));
    }

    // Build args for broadcast.sh
    // Usage: broadcast.sh [--to <recipient>] [--urgency <level>] <EVENT_TYPE> [args...]
    let mut args: Vec<String> = Vec::new();

    if !to.is_empty() {
        if !safe_token(&to) {
            return Err(anyhow!("invalid to: must be alphanumeric + -_/."));
        }
        args.push("--to".to_string());
        args.push(to.clone());
    }

    if urgency != "INFO" {
        args.push("--urgency".to_string());
        args.push(urgency.clone());
    }

    args.push(event_type.clone());

    // FEEDBACK and ALERT need kind= prefix or kind arg
    match event_type.as_str() {
        "FEEDBACK" | "ALERT" => {
            if !kind.is_empty() {
                args.push(format!("kind={}", kind));
            }
            args.push(subject.clone());
            if !rationale.is_empty() {
                args.push(rationale.clone());
            }
            if !vote_str.is_empty() {
                args.push(vote_str.clone());
            }
        }
        "WARN" => {
            args.push(subject.clone());
        }
        _ => {
            // INTENT, STUCK, DONE, HANDOFF — subject is positional
            args.push(subject.clone());
            if !rationale.is_empty() {
                args.push(rationale.clone());
            }
        }
    }

    run_script("coord/broadcast.sh", &args).await
}

// ── tool: vote ────────────────────────────────────────────────────────────────

/// Cast a vote on a correlation ID via `chump vote`.
///
/// Params:
/// - `corr_id` (required): correlation ID for the vote round
/// - `vote` (required): vote value (e.g. "yes", "no", "abstain", "+1", "-1")
/// - `reason` (optional): free-text reason
pub async fn handle_vote(params: &Value) -> Result<Value> {
    let corr_id = params
        .get("corr_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing corr_id"))?
        .trim()
        .to_string();
    reject_secret_leak(&corr_id)?;
    if !safe_token(&corr_id) {
        return Err(anyhow!("invalid corr_id: must be alphanumeric + -_/."));
    }

    let vote = params
        .get("vote")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing vote"))?
        .trim()
        .to_string();
    reject_secret_leak(&vote)?;
    if !safe_token(&vote) {
        return Err(anyhow!("invalid vote: must be alphanumeric + -_/."));
    }

    let reason = params
        .get("reason")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if !reason.is_empty() {
        reject_secret_leak(&reason)?;
    }

    let mut args: Vec<&str> = vec!["vote", &corr_id, &vote];
    let reason_owned;
    if !reason.is_empty() {
        reason_owned = reason.clone();
        args.push("--reason");
        args.push(&reason_owned);
    }

    run_chump(&args).await
}

// ── tool: consensus_status ────────────────────────────────────────────────────

/// Query the consensus tally via `chump consensus-tally`.
///
/// Params (all optional — at least one of corr_id or all must be set):
/// - `corr_id` (optional): filter to a specific correlation ID
/// - `all` (optional bool): show all active rounds
/// - `since` (optional): ISO-8601 timestamp filter (if supported by tally CLI)
pub async fn handle_consensus_status(params: &Value) -> Result<Value> {
    let corr_id = params
        .get("corr_id")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string());
    let all = params.get("all").and_then(|v| v.as_bool()).unwrap_or(false);
    let since = params
        .get("since")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string());

    if corr_id.is_none() && !all {
        return Err(anyhow!(
            "provide corr_id or set all=true to list all rounds"
        ));
    }

    let mut args: Vec<String> = vec!["consensus-tally".to_string()];

    if let Some(ref cid) = corr_id {
        reject_secret_leak(cid)?;
        if !safe_token(cid) {
            return Err(anyhow!("invalid corr_id: must be alphanumeric + -_/."));
        }
        args.push("--corr-id".to_string());
        args.push(cid.clone());
    }

    if all {
        args.push("--all".to_string());
    }

    if let Some(ref ts) = since {
        reject_secret_leak(ts)?;
        args.push("--since".to_string());
        args.push(ts.clone());
    }

    let args_ref: Vec<&str> = args.iter().map(String::as_str).collect();
    run_chump(&args_ref).await
}

// ── tool: capabilities ────────────────────────────────────────────────────────

/// List online curators / sessions from the NATS KV `chump_capabilities` bucket.
///
/// Falls back to globbing `.chump-locks/.curator-opus-*.lock` when NATS is
/// unavailable (offline mode).
///
/// Params: none required.
/// - `include_stale` (optional bool, default false): include sessions whose
///   heartbeat_at is older than their ttl_seconds
pub async fn handle_capabilities(params: &Value) -> Result<Value> {
    let include_stale = params
        .get("include_stale")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Try `chump capabilities` (NATS-backed, META-061 slice)
    let nats_result = run_chump(&["capabilities", "--json"]).await;

    if let Ok(ref v) = nats_result {
        if v.get("success").and_then(|s| s.as_bool()).unwrap_or(false) {
            return Ok(json!({
                "success": true,
                "source": "nats_kv",
                "include_stale": include_stale,
                "capabilities": v,
            }));
        }
    }

    // Offline fallback: glob .curator-opus-*.lock files in lock dir
    let lock = lock_dir()?;
    let mut sessions: Vec<Value> = Vec::new();

    if lock.is_dir() {
        for entry in
            std::fs::read_dir(&lock).with_context(|| format!("read_dir {}", lock.display()))?
        {
            let entry = entry.map_err(|e| anyhow!("read_dir entry: {}", e))?;
            let name = entry.file_name().to_string_lossy().into_owned();
            // Include .curator-opus-*.lock and claim-*.json (active workers)
            if name.starts_with('.') && name.contains("curator") && name.ends_with(".lock") {
                sessions.push(json!({
                    "session_id": name.trim_start_matches('.').trim_end_matches(".lock"),
                    "source": "lock_file",
                    "file": name,
                }));
            } else if name.starts_with("claim-") && name.ends_with(".json") {
                if let Ok(text) = std::fs::read_to_string(entry.path()) {
                    if let Ok(v) = serde_json::from_str::<Value>(&text) {
                        sessions.push(json!({
                            "session_id": v.get("session_id"),
                            "gap_id": v.get("gap_id"),
                            "expires_at": v.get("expires_at"),
                            "heartbeat_at": v.get("heartbeat_at"),
                            "source": "claim_lease",
                        }));
                    }
                }
            }
        }
    }

    Ok(json!({
        "success": true,
        "source": "offline_glob",
        "include_stale": include_stale,
        "sessions": sessions,
        "count": sessions.len(),
        "note": "NATS unavailable; using offline lock-file scan",
    }))
}

// ── tools/list descriptor ─────────────────────────────────────────────────────

pub fn tools_list_json() -> Value {
    json!({
        "tools": [
            {
                "name": "mcp__chump_fleet__inbox_drain",
                "description": "Read pending fleet messages for a session from .chump-locks/inbox/<session_id>.jsonl since the last cursor position. Returns new messages as parsed JSON objects.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "session_id": {
                            "type": "string",
                            "description": "Session ID whose inbox to drain (e.g. 'claim-infra-1234-56789-1780000000')"
                        },
                        "advance_cursor": {
                            "type": "boolean",
                            "description": "Whether to advance the cursor after reading (default true)"
                        }
                    },
                    "required": ["session_id"]
                }
            },
            {
                "name": "mcp__chump_fleet__broadcast",
                "description": "Emit a structured broadcast event via scripts/coord/broadcast.sh. Use event_type=FEEDBACK for peer feedback; WARN for fleet alerts; INTENT/DONE for gap lifecycle signals.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "event_type": {
                            "type": "string",
                            "enum": ["INTENT", "HANDOFF", "STUCK", "DONE", "WARN", "ALERT", "FEEDBACK"],
                            "description": "Broadcast event type"
                        },
                        "subject": {
                            "type": "string",
                            "description": "Main message / subject text"
                        },
                        "kind": {
                            "type": "string",
                            "description": "Sub-type for FEEDBACK/ALERT events (e.g. 'lesson', 'upgrade')"
                        },
                        "rationale": {
                            "type": "string",
                            "description": "Reason or supporting detail (optional)"
                        },
                        "vote": {
                            "type": "string",
                            "description": "Vote value for FEEDBACK events (optional)"
                        },
                        "to": {
                            "type": "string",
                            "description": "Recipient session ID for targeted delivery (optional)"
                        },
                        "urgency": {
                            "type": "string",
                            "enum": ["INFO", "WARN", "CRIT", "EMERGENCY"],
                            "description": "Urgency tier (default INFO)"
                        }
                    },
                    "required": ["event_type", "subject"]
                }
            },
            {
                "name": "mcp__chump_fleet__vote",
                "description": "Cast a vote on a fleet consensus round via `chump vote`. Used when another agent broadcasts a FEEDBACK/vote request with a corr_id.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "corr_id": {
                            "type": "string",
                            "description": "Correlation ID for the vote round"
                        },
                        "vote": {
                            "type": "string",
                            "description": "Vote value (e.g. 'yes', 'no', 'abstain', '+1', '-1')"
                        },
                        "reason": {
                            "type": "string",
                            "description": "Optional reason for the vote"
                        }
                    },
                    "required": ["corr_id", "vote"]
                }
            },
            {
                "name": "mcp__chump_fleet__consensus_status",
                "description": "Query the current consensus tally for a vote round or all active rounds via `chump consensus-tally`.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "corr_id": {
                            "type": "string",
                            "description": "Filter to this specific correlation ID (optional)"
                        },
                        "all": {
                            "type": "boolean",
                            "description": "Show all active rounds (set to true when corr_id not specified)"
                        },
                        "since": {
                            "type": "string",
                            "description": "ISO-8601 timestamp — only rounds started after this (optional)"
                        }
                    }
                }
            },
            {
                "name": "mcp__chump_fleet__capabilities",
                "description": "List online Chump fleet sessions and their capabilities. Reads from NATS KV chump_capabilities bucket; falls back to scanning .chump-locks/ when NATS is unavailable.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "include_stale": {
                            "type": "boolean",
                            "description": "Include sessions whose heartbeat is older than their TTL (default false)"
                        }
                    }
                }
            }
        ]
    })
}
