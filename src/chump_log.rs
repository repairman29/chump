//! Append-only log for Chump: messages, replies, CLI runs. Written to logs/chump.log.
//! With CHUMP_LOG_STRUCTURED=1, each line is JSON. Optional request_id ties log lines to one turn.

use std::cell::RefCell;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;

thread_local! {
    static REQUEST_ID: RefCell<Option<String>> = const { RefCell::new(None) };
    /// Pending DM to send to CHUMP_READY_DM_USER_ID after this turn (set by notify tool, consumed by Discord handler).
    static PENDING_NOTIFY: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn log_path() -> PathBuf {
    let base = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let log_dir = base.join("logs");
    let _ = std::fs::create_dir_all(&log_dir);
    log_dir.join("chump.log")
}

/// Append-only log path (same file as [`append_line`]). Uses process **current directory** + `logs/`, not `CHUMP_HOME`.
pub fn log_file_path() -> PathBuf {
    log_path()
}

fn structured_log() -> bool {
    std::env::var("CHUMP_LOG_STRUCTURED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

pub fn get_request_id() -> Option<String> {
    REQUEST_ID.with(|r| r.borrow().clone())
}

/// Set the current turn's request_id so log_cli and other logs in this turn can include it. Clear with set_request_id(None).
pub fn set_request_id(id: Option<String>) {
    REQUEST_ID.with(|r| *r.borrow_mut() = id);
}

/// Set a message to DM to CHUMP_READY_DM_USER_ID after this turn. Used by the notify tool; Discord handler calls take_pending_notify and sends it.
/// When `CHUMP_INTERRUPT_NOTIFY_POLICY=restrict` and `CHUMP_HEARTBEAT_TYPE` is set, only high-signal messages pass (see `interrupt_notify` and docs/COS_DECISION_LOG.md).
pub fn set_pending_notify(message: String) {
    if !crate::interrupt_notify::allow_user_notify(&message) {
        eprintln!(
            "[chump] notify suppressed (interrupt policy): message did not match allowed interrupt patterns"
        );
        return;
    }
    PENDING_NOTIFY.with(|r| *r.borrow_mut() = Some(message));
}

/// Same as [`set_pending_notify`] but ignores heartbeat interrupt policy (e.g. git auth failure DM).
pub fn set_pending_notify_unfiltered(message: String) {
    PENDING_NOTIFY.with(|r| *r.borrow_mut() = Some(message));
}

/// Take and clear the pending notify message, if any. Call after agent.run() in Discord mode to send the DM.
pub fn take_pending_notify() -> Option<String> {
    PENDING_NOTIFY.with(|r| r.borrow_mut().take())
}

/// Generate a short request_id for one turn (e.g. grep in logs).
pub fn gen_request_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let n = t.as_nanos() as u64;
    format!("{:08x}", n % 0xffff_ffff)
}

/// True if Chump should not run the agent (kill switch): file logs/pause exists or CHUMP_PAUSED=1.
pub fn paused() -> bool {
    if std::env::var("CHUMP_PAUSED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        return true;
    }
    let base = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    base.join("logs").join("pause").exists()
}

const REDACTED: &str = "[REDACTED]";

/// Redact known secret env values from a string so they never appear in logs or stderr.
/// Single-pass build to avoid multiple allocations from repeated replace().
pub fn redact(s: &str) -> String {
    let secrets: Vec<String> = [
        "DISCORD_TOKEN",
        "TAVILY_API_KEY",
        "OPENAI_API_KEY",
        "GITHUB_TOKEN",
        "HF_TOKEN",
        "CHUMP_WEB_TOKEN",
        "ANTHROPIC_API_KEY",
        "CURSOR_API_KEY",
    ]
    .into_iter()
    .filter_map(|var| std::env::var(var).ok())
    .filter(|v| !v.is_empty())
    .collect();
    if secrets.is_empty() || !secrets.iter().any(|v| s.contains(v.as_str())) {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len().saturating_add(64));
    let mut i = 0;
    let s_bytes = s.as_bytes();
    while i < s_bytes.len() {
        let mut replaced = false;
        for secret in &secrets {
            let b = secret.as_bytes();
            if i + b.len() <= s_bytes.len() && s_bytes[i..i + b.len()] == *b {
                out.push_str(REDACTED);
                i += b.len();
                replaced = true;
                break;
            }
        }
        if !replaced {
            out.push(s_bytes[i] as char);
            i += 1;
        }
    }
    out
}

fn append_line(line: &str) {
    let path = log_path();
    let line = redact(line);
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{}", line);
        let _ = f.flush();
    }
}

fn ts_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}", t.as_secs(), t.subsec_millis())
}

/// Log an incoming message (channel, user, content preview). Uses current request_id if set.
#[allow(dead_code)]
pub fn log_message(channel_id: u64, user: &str, content: &str) {
    log_message_with_request_id(channel_id, user, content, get_request_id().as_deref());
}

/// Same as log_message but with explicit request_id (e.g. from Discord spawn).
pub fn log_message_with_request_id(
    channel_id: u64,
    user: &str,
    content: &str,
    request_id: Option<&str>,
) {
    let preview = if content.len() > 200 {
        format!("{}…", &content[..200])
    } else {
        content.to_string()
    };
    let preview = preview.replace('\n', " ");
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "msg",
            "channel_id": channel_id,
            "user": sanitize(user),
            "content_preview": preview,
        });
        if let Some(rid) = request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | msg | ch={} | user={} | {}{}",
            ts_iso(),
            channel_id,
            sanitize(user),
            preview,
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log a reply sent (channel, reply length, optional content preview). Uses current request_id if set.
#[allow(dead_code)]
pub fn log_reply(channel_id: u64, reply_len: usize, reply_preview: Option<&str>) {
    log_reply_with_request_id(
        channel_id,
        reply_len,
        reply_preview,
        get_request_id().as_deref(),
    );
}

/// Same as log_reply but with explicit request_id.
pub fn log_reply_with_request_id(
    channel_id: u64,
    reply_len: usize,
    reply_preview: Option<&str>,
    request_id: Option<&str>,
) {
    let preview = reply_preview
        .map(|s| {
            let p = if s.len() > 300 {
                format!("{}…", &s[..300])
            } else {
                s.to_string()
            };
            p.replace('\n', " ")
        })
        .unwrap_or_default();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "reply",
            "channel_id": channel_id,
            "reply_len": reply_len,
            "reply_preview": preview,
        });
        if let Some(rid) = request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | reply | ch={} | len={} | {}{}",
            ts_iso(),
            channel_id,
            reply_len,
            preview,
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log config validation summary (enabled features and warnings) to chump.log. Called at startup.
pub fn log_config_summary(enabled: &[String], warnings: &[String]) {
    if structured_log() {
        let obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "config",
            "enabled": enabled,
            "warnings": warnings,
        });
        append_line(&obj.to_string());
    } else {
        let line = format!(
            "{} | config | enabled=[{}] | warnings=[{}]",
            ts_iso(),
            enabled.join(", "),
            warnings.join("; ")
        );
        append_line(&line);
    }
}

/// Audit log for tool approval: tool name, args preview, risk level, result (allowed/denied/timeout).
/// No PII; args_preview should be short and redaction is applied to the written line.
pub fn log_tool_approval_audit(
    tool_name: &str,
    args_preview: &str,
    risk_level: &str,
    result: &str,
    request_id: Option<&str>,
) {
    let preview = args_preview
        .replace('\n', " ")
        .chars()
        .take(200)
        .collect::<String>();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "tool_approval_audit",
            "tool": tool_name,
            "args_preview": preview,
            "risk_level": risk_level,
            "result": result,
        });
        if let Some(rid) = request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | tool_approval_audit | tool={} | risk={} | result={} | {}{}",
            ts_iso(),
            sanitize(tool_name),
            risk_level,
            result,
            preview,
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log an error that was sent as the Discord reply (so you can see the full error in logs/chump.log).
pub fn log_error_response(channel_id: u64, error_message: &str, request_id: Option<&str>) {
    let safe = redact(error_message).replace('\n', " ");
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "error_response",
            "channel_id": channel_id,
            "error": safe,
        });
        if let Some(rid) = request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | error_response | ch={} | {}{}",
            ts_iso(),
            channel_id,
            safe,
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log a CLI run (command, args preview, exit code, output length). Uses current request_id if set (same turn).
/// When executive is true, log includes executive=1 for audit (full host authority).
#[allow(dead_code)]
pub fn log_cli(command: &str, args: &[String], exit_code: Option<i32>, output_len: usize) {
    log_cli_with_executive(command, args, exit_code, output_len, false)
}

/// Log a CLI run with optional executive flag for audit.
pub fn log_cli_with_executive(
    command: &str,
    args: &[String],
    exit_code: Option<i32>,
    output_len: usize,
    executive: bool,
) {
    let args_preview = args.join(" ").chars().take(80).collect::<String>();
    let request_id = get_request_id();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "cli",
            "command": command,
            "args_preview": args_preview,
            "exit_code": exit_code,
            "output_len": output_len,
        });
        if let Some(rid) = &request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        if executive {
            obj["executive"] = serde_json::json!(1);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let exec_suffix = if executive { " | executive=1" } else { "" };
        let line = format!(
            "{} | cli | cmd={} {} | exit={:?} | out_len={}{}{}",
            ts_iso(),
            command,
            args_preview,
            exit_code,
            output_len,
            rid_suffix,
            exec_suffix
        );
        append_line(&line);
    }
}

/// Log session end (called by context_assembly::close_session). One line per session wrap-up.
pub fn log_session_end() {
    if structured_log() {
        let obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "session_end",
        });
        append_line(&obj.to_string());
    } else {
        let line = format!("{} | session_end", ts_iso());
        append_line(&line);
    }
}

/// Log an ADB command execution.
pub fn log_adb(cmd: &str, exit_code: Option<i32>, output_len: usize) {
    let preview = if cmd.len() > 200 {
        format!("{}…", &cmd[..200])
    } else {
        cmd.to_string()
    };
    let request_id = get_request_id();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "adb",
            "cmd": preview,
            "exit": exit_code,
            "out_len": output_len,
        });
        if let Some(rid) = &request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | adb | {} | exit={} | out_len={}{}",
            ts_iso(),
            preview,
            exit_code.unwrap_or(-1),
            output_len,
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log a write_file (path, content length, mode) for audit.
pub fn log_write_file(path: String, content_len: usize, mode: &str) {
    let request_id = get_request_id();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "write_file",
            "path": path,
            "content_len": content_len,
            "mode": mode,
        });
        if let Some(rid) = &request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | write_file | path={} | len={} | mode={}{}",
            ts_iso(),
            path,
            content_len,
            mode,
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log patch_file for audit (path, diff size, outcome label).
pub fn log_patch_file(path: &str, diff_len: usize, outcome: &str) {
    let request_id = get_request_id();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "patch_file",
            "path": path,
            "diff_len": diff_len,
            "outcome": outcome,
        });
        if let Some(rid) = &request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | patch_file | path={} | diff_len={} | outcome={}{}",
            ts_iso(),
            path,
            diff_len,
            outcome,
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log git_commit for audit (repo, message).
pub fn log_git_commit(repo: &str, message: &str) {
    let request_id = get_request_id();
    let msg_preview = message
        .replace('\n', " ")
        .chars()
        .take(80)
        .collect::<String>();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "git_commit",
            "repo": repo,
            "message": msg_preview,
        });
        if let Some(rid) = &request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | git_commit | repo={} | msg={}{}",
            ts_iso(),
            repo,
            msg_preview,
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log git_push for audit (repo, branch).
pub fn log_git_push(repo: &str, branch: &str) {
    let request_id = get_request_id();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "git_push",
            "repo": repo,
            "branch": branch,
        });
        if let Some(rid) = &request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | git_push | repo={} | branch={}{}",
            ts_iso(),
            repo,
            branch,
            rid_suffix
        );
        append_line(&line);
    }
}

const GIT_PUSH_FAIL_OUT_MAX: usize = 500;

/// Log git_push failure so chump.log shows why push failed (auth, protection, etc.).
pub fn log_git_push_failed(repo: &str, branch: &str, out: &str) {
    let out_trunc: String = if out.chars().count() > GIT_PUSH_FAIL_OUT_MAX {
        format!(
            "{}...",
            out.chars().take(GIT_PUSH_FAIL_OUT_MAX).collect::<String>()
        )
    } else {
        out.to_string()
    };
    let request_id = get_request_id();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "git_push_fail",
            "repo": repo,
            "branch": branch,
            "out": out_trunc,
        });
        if let Some(rid) = &request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | git_push_fail | repo={} | branch={} | out={}{}",
            ts_iso(),
            repo,
            branch,
            out_trunc.replace('\n', " "),
            rid_suffix
        );
        append_line(&line);
    }
}

/// Log github_clone_or_pull for audit (repo, action clone|pull, local path, success).
pub fn log_git_clone_pull(repo: &str, action: &str, path: &str, success: bool) {
    let request_id = get_request_id();
    if structured_log() {
        let mut obj = serde_json::json!({
            "ts": ts_iso(),
            "event": "git_clone_pull",
            "repo": repo,
            "action": action,
            "path": path,
            "success": success,
        });
        if let Some(rid) = &request_id {
            obj["request_id"] = serde_json::json!(rid);
        }
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id
            .map(|r| format!(" | req={}", r))
            .unwrap_or_default();
        let line = format!(
            "{} | git_clone_pull | repo={} | action={} | path={} | ok={}{}",
            ts_iso(),
            repo,
            action,
            path,
            success,
            rid_suffix
        );
        append_line(&line);
    }
}

fn sanitize(s: &str) -> String {
    s.replace('\n', " ").chars().take(64).collect()
}

/// One `tool_approval_audit` row from `logs/chump.log` (structured JSON or legacy pipe line).
#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
pub struct ToolApprovalAuditRow {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ts: Option<String>,
    pub tool: String,
    pub risk_level: String,
    pub result: String,
    #[serde(default)]
    pub args_preview: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

const AUDIT_TAIL_MAX_BYTES: u64 = 768 * 1024;

/// Read up to `max_entries` most recent `tool_approval_audit` lines from the log tail (best-effort parse).
pub fn recent_tool_approval_audits(max_entries: usize) -> Vec<ToolApprovalAuditRow> {
    let max_entries = max_entries.clamp(1, 500);
    let path = log_file_path();
    let Ok(meta) = std::fs::metadata(&path) else {
        return Vec::new();
    };
    let len = meta.len();
    let read_len = len.min(AUDIT_TAIL_MAX_BYTES);
    let Ok(mut f) = std::fs::File::open(&path) else {
        return Vec::new();
    };
    use std::io::{Read, Seek, SeekFrom};
    let start = len.saturating_sub(read_len);
    if f.seek(SeekFrom::Start(start)).is_err() {
        return Vec::new();
    }
    let mut buf = vec![0u8; read_len as usize];
    if f.read_exact(&mut buf).is_err() {
        return Vec::new();
    }
    let Ok(text) = String::from_utf8(buf) else {
        return Vec::new();
    };
    let mut out: Vec<ToolApprovalAuditRow> = Vec::new();
    for line in text.lines().rev() {
        let line = line.trim();
        if line.is_empty() || !line.contains("tool_approval_audit") {
            continue;
        }
        if let Some(row) = parse_tool_approval_audit_line(line) {
            out.push(row);
            if out.len() >= max_entries {
                break;
            }
        }
    }
    out
}

fn parse_tool_approval_audit_line(line: &str) -> Option<ToolApprovalAuditRow> {
    let t = line.trim_start();
    if t.starts_with('{') {
        let v: serde_json::Value = serde_json::from_str(t).ok()?;
        if v.get("event").and_then(|e| e.as_str()) != Some("tool_approval_audit") {
            return None;
        }
        return Some(ToolApprovalAuditRow {
            ts: v.get("ts").and_then(|x| x.as_str()).map(|s| s.to_string()),
            tool: v
                .get("tool")
                .and_then(|x| x.as_str())
                .unwrap_or("?")
                .to_string(),
            risk_level: v
                .get("risk_level")
                .and_then(|x| x.as_str())
                .unwrap_or("?")
                .to_string(),
            result: v
                .get("result")
                .and_then(|x| x.as_str())
                .unwrap_or("?")
                .to_string(),
            args_preview: v
                .get("args_preview")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string(),
            request_id: v
                .get("request_id")
                .and_then(|x| x.as_str())
                .map(|s| s.to_string()),
        });
    }
    parse_legacy_tool_approval_audit_line(line)
}

fn parse_legacy_tool_approval_audit_line(line: &str) -> Option<ToolApprovalAuditRow> {
    if !line.contains("tool_approval_audit") {
        return None;
    }
    let ts = line
        .split(" | ")
        .next()
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty());
    let tool = extract_kv_field(line, "tool")?;
    let risk_level = extract_kv_field(line, "risk").unwrap_or_else(|| "?".to_string());
    let (result, args_preview, request_id) = extract_result_args_and_req(line)?;
    Some(ToolApprovalAuditRow {
        ts,
        tool,
        risk_level,
        result,
        args_preview,
        request_id,
    })
}

fn extract_kv_field(line: &str, key: &str) -> Option<String> {
    let needle = format!("{}=", key);
    let i = line.find(&needle)?;
    let rest = &line[i + needle.len()..];
    Some(rest.split(" | ").next().unwrap_or("").trim().to_string())
}

fn extract_result_args_and_req(line: &str) -> Option<(String, String, Option<String>)> {
    let needle = "| result=";
    let i = line.find(needle)?;
    let mut tail = line[i + needle.len()..].trim_start();
    let mut request_id = None;
    if let Some(pos) = tail.rfind(" | req=") {
        request_id = Some(tail[pos + " | req=".len()..].trim().to_string());
        tail = tail[..pos].trim_end();
    }
    let (result, args_preview) = if let Some(pos) = tail.find(" | ") {
        (
            tail[..pos].trim().to_string(),
            tail[pos + 3..].trim().to_string(),
        )
    } else {
        (tail.to_string(), String::new())
    };
    if result.is_empty() {
        return None;
    }
    Some((result, args_preview, request_id))
}

#[cfg(test)]
mod audit_parse_tests {
    use super::*;

    #[test]
    fn parses_legacy_line() {
        let line =
            "123.456 | tool_approval_audit | tool=run_cli | risk=low | result=allowed | cargo test";
        let r = parse_tool_approval_audit_line(line).expect("parse");
        assert_eq!(r.tool, "run_cli");
        assert_eq!(r.risk_level, "low");
        assert_eq!(r.result, "allowed");
        assert_eq!(r.args_preview, "cargo test");
    }

    #[test]
    fn parses_legacy_with_req() {
        let line = "1.0 | tool_approval_audit | tool=x | risk=high | result=denied | rm -rf | req=abc-uuid";
        let r = parse_tool_approval_audit_line(line).expect("parse");
        assert_eq!(r.result, "denied");
        assert_eq!(r.args_preview, "rm -rf");
        assert_eq!(r.request_id.as_deref(), Some("abc-uuid"));
    }
}
