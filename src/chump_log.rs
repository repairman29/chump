//! Append-only log for Chump: messages, replies, CLI runs. Written to logs/chump.log.
//! With CHUMP_LOG_STRUCTURED=1, each line is JSON. Optional request_id ties log lines to one turn.

use std::cell::RefCell;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;

thread_local! {
    static REQUEST_ID: RefCell<Option<String>> = RefCell::new(None);
}

fn log_path() -> PathBuf {
    let base = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let log_dir = base.join("logs");
    let _ = std::fs::create_dir_all(&log_dir);
    log_dir.join("chump.log")
}

fn structured_log() -> bool {
    std::env::var("CHUMP_LOG_STRUCTURED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn get_request_id() -> Option<String> {
    REQUEST_ID.with(|r| r.borrow().clone())
}

/// Set the current turn's request_id so log_cli and other logs in this turn can include it. Clear with set_request_id(None).
pub fn set_request_id(id: Option<String>) {
    REQUEST_ID.with(|r| *r.borrow_mut() = id);
}

/// Generate a short request_id for one turn (e.g. grep in logs).
pub fn gen_request_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let n = t.as_nanos() as u64;
    format!("{:08x}", n % 0xffff_ffff)
}

/// True if Chump should not run the agent (kill switch): file logs/pause exists or CHUMP_PAUSED=1.
pub fn paused() -> bool {
    if std::env::var("CHUMP_PAUSED").map(|v| v == "1" || v.eq_ignore_ascii_case("true")).unwrap_or(false) {
        return true;
    }
    let base = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    base.join("logs").join("pause").exists()
}

/// Redact known secret env values from a string so they never appear in logs or stderr.
pub fn redact(s: &str) -> String {
    let mut out = s.to_string();
    let secret_vars = [
        "DISCORD_TOKEN",
        "TAVILY_API_KEY",
        "OPENAI_API_KEY",
        "GITHUB_TOKEN",
    ];
    for var in secret_vars {
        if let Ok(v) = std::env::var(var) {
            if !v.is_empty() && out.contains(&v) {
                out = out.replace(&v, "[REDACTED]");
            }
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
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
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
        let rid_suffix = request_id.map(|r| format!(" | req={}", r)).unwrap_or_default();
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
    log_reply_with_request_id(channel_id, reply_len, reply_preview, get_request_id().as_deref());
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
            let p = if s.len() > 300 { format!("{}…", &s[..300]) } else { s.to_string() };
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
        let rid_suffix = request_id.map(|r| format!(" | req={}", r)).unwrap_or_default();
        let line = format!(
            "{} | reply | ch={} | len={} | {}{}",
            ts_iso(), channel_id, reply_len, preview, rid_suffix
        );
        append_line(&line);
    }
}

/// Log a CLI run (command, args preview, exit code, output length). Uses current request_id if set (same turn).
pub fn log_cli(command: &str, args: &[String], exit_code: Option<i32>, output_len: usize) {
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
        append_line(&obj.to_string());
    } else {
        let rid_suffix = request_id.map(|r| format!(" | req={}", r)).unwrap_or_default();
        let line = format!(
            "{} | cli | cmd={} {} | exit={:?} | out_len={}{}",
            ts_iso(), command, args_preview, exit_code, output_len, rid_suffix
        );
        append_line(&line);
    }
}

fn sanitize(s: &str) -> String {
    s.replace('\n', " ").chars().take(64).collect()
}
