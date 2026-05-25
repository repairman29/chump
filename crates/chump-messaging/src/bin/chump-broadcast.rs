//! `chump-broadcast` — Rust port of `scripts/coord/broadcast.sh`
//! (INFRA-1998 Phase 1).
//!
//! Argument surface mirrors the bash callsite:
//!
//! ```text
//! chump-broadcast [--to <SESSION>] [--corr <ID>] [--urgency now|hours|digest] \
//!                 <LEVEL> [<level-specific positional args...>]
//! ```
//!
//! Where `<LEVEL>` is one of:
//!   INTENT  <gap-id> [files]
//!   HANDOFF <gap-id> <to-session>
//!   STUCK   <gap-id> "<reason>"
//!   DONE    <gap-id> [commit-sha]
//!   WARN    "<message>"
//!   ALERT   kind=<kind> "<message>"
//!   FEEDBACK <defect|proposal|preference|retro> <subject> [rationale]
//!
//! The legacy bash hook at `scripts/coord/broadcast.sh` exec's this
//! binary when `CHUMP_MESSAGING_RUST=1` is set in the environment.
//! Otherwise the bash body runs unchanged.
//!
//! ## Phase 1 scope
//!
//! - Writes to `<lock_dir>/inbox/<to>.jsonl` via [`FileBroker`].
//! - Does NOT mirror to ambient.jsonl, NATS, or the feedback.jsonl
//!   stream (those are bash-callsite-only in Phase 1). When
//!   `CHUMP_MESSAGING_RUST=1` is set, the operator opts into the
//!   inbox-only path for that invocation.
//! - Does NOT emit any new ambient event kinds.

use std::borrow::Cow;
use std::env;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use chump_messaging::{Broker, FileBroker, MessageLevel, OutboundMessage, Urgency};

fn usage_and_exit(reason: &str) -> ! {
    eprintln!("[chump-broadcast] {reason}");
    eprintln!();
    eprintln!("Usage: chump-broadcast [--to <SESSION>] [--corr <ID>] [--urgency now|hours|digest]");
    eprintln!("                        INTENT|HANDOFF|STUCK|DONE|WARN|ALERT|FEEDBACK [args...]");
    std::process::exit(2);
}

fn resolve_session_id(lock_dir: &Path) -> String {
    if let Ok(v) = env::var("CHUMP_SESSION_ID") {
        if !v.is_empty() {
            return v;
        }
    }
    if let Ok(v) = env::var("CLAUDE_SESSION_ID") {
        if !v.is_empty() {
            return v;
        }
    }
    let wt_cache = lock_dir.join(".wt-session-id");
    if let Ok(v) = std::fs::read_to_string(&wt_cache) {
        let trimmed = v.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    if let Some(home) = env::var_os("HOME") {
        let session_path = PathBuf::from(home).join(".chump/session_id");
        if let Ok(v) = std::fs::read_to_string(&session_path) {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
    }
    format!("broadcast-{}", std::process::id())
}

fn resolve_lock_dir() -> PathBuf {
    // Use `git rev-parse --git-common-dir` to find the main repo (matches
    // the bash callsite). If we're not in a worktree, fall back to cwd.
    let common = std::process::Command::new("git")
        .args(["rev-parse", "--git-common-dir"])
        .output();
    if let Ok(out) = common {
        if out.status.success() {
            let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
            // The .git common dir; main repo is its parent.
            let main_repo = PathBuf::from(&raw)
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| PathBuf::from("."));
            return main_repo.join(".chump-locks");
        }
    }
    PathBuf::from(".chump-locks")
}

fn main() -> ExitCode {
    // Tokio one-shot runtime for the async Broker call.
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            eprintln!("[chump-broadcast] failed to start runtime: {err}");
            return ExitCode::from(1);
        }
    };
    rt.block_on(run())
}

async fn run() -> ExitCode {
    let raw_args: Vec<String> = env::args().skip(1).collect();
    if raw_args.is_empty() {
        usage_and_exit("missing arguments");
    }

    // Parse leading optional flags.
    let mut to: Option<String> = None;
    let mut corr: Option<String> = None;
    let mut urgency: Option<Urgency> = None;
    let mut i = 0;
    while i < raw_args.len() {
        match raw_args[i].as_str() {
            "--to" => {
                let v = raw_args
                    .get(i + 1)
                    .cloned()
                    .unwrap_or_else(|| usage_and_exit("--to requires a value"));
                to = Some(v);
                i += 2;
            }
            "--corr" => {
                let v = raw_args
                    .get(i + 1)
                    .cloned()
                    .unwrap_or_else(|| usage_and_exit("--corr requires a value"));
                corr = Some(v);
                i += 2;
            }
            "--urgency" => {
                let v = raw_args
                    .get(i + 1)
                    .cloned()
                    .unwrap_or_else(|| usage_and_exit("--urgency requires a value"));
                urgency =
                    Some(Urgency::parse(&v).unwrap_or_else(|| usage_and_exit("invalid --urgency")));
                i += 2;
            }
            _ => break,
        }
    }
    let pos: Vec<String> = raw_args[i..].to_vec();
    if pos.is_empty() {
        usage_and_exit("missing event level");
    }
    let level = match MessageLevel::parse(&pos[0]) {
        Ok(l) => l,
        Err(_) => usage_and_exit(&format!("unknown level: {}", pos[0])),
    };

    let lock_dir = resolve_lock_dir();
    let inbox_dir = lock_dir.join("inbox");
    let from = resolve_session_id(&lock_dir);

    // Build OutboundMessage per level — mirror the bash positional argv.
    let mut kind = String::new();
    let mut gap: Option<String> = None;
    let mut body = serde_json::Map::new();

    match level {
        MessageLevel::Intent => {
            let g = pos.get(1).cloned().unwrap_or_default();
            let files = pos.get(2).cloned().unwrap_or_default();
            if g.is_empty() {
                usage_and_exit("INTENT requires <gap-id> [files]");
            }
            gap = Some(g.clone());
            body.insert("files".to_string(), serde_json::Value::String(files));
        }
        MessageLevel::Handoff => {
            let g = pos.get(1).cloned().unwrap_or_default();
            let pos_to = pos.get(2).cloned().unwrap_or_default();
            let effective_to = to.clone().unwrap_or(pos_to);
            if g.is_empty() || effective_to.is_empty() {
                usage_and_exit("HANDOFF requires <gap-id> [<to-session>]");
            }
            gap = Some(g.clone());
            to = Some(effective_to);
        }
        MessageLevel::Stuck => {
            let g = pos.get(1).cloned().unwrap_or_default();
            let reason = pos
                .get(2)
                .cloned()
                .unwrap_or_else(|| "unspecified".to_string());
            if g.is_empty() {
                usage_and_exit("STUCK requires <gap-id> \"<reason>\"");
            }
            gap = Some(g.clone());
            body.insert("reason".to_string(), serde_json::Value::String(reason));
        }
        MessageLevel::Done => {
            let g = pos.get(1).cloned().unwrap_or_default();
            let commit = pos.get(2).cloned().unwrap_or_default();
            if g.is_empty() {
                usage_and_exit("DONE requires <gap-id> [commit-sha]");
            }
            gap = Some(g.clone());
            body.insert("commit".to_string(), serde_json::Value::String(commit));
        }
        MessageLevel::Warn => {
            let msg = pos.get(1).cloned().unwrap_or_default();
            if msg.is_empty() {
                usage_and_exit("WARN requires \"<message>\"");
            }
            body.insert("reason".to_string(), serde_json::Value::String(msg));
        }
        MessageLevel::Alert => {
            let kind_arg = pos.get(1).cloned().unwrap_or_default();
            let msg = pos.get(2).cloned().unwrap_or_default();
            let k = kind_arg
                .strip_prefix("kind=")
                .unwrap_or(&kind_arg)
                .to_string();
            if k.is_empty() {
                usage_and_exit("ALERT requires kind=<kind> \"<message>\"");
            }
            kind = k;
            body.insert("reason".to_string(), serde_json::Value::String(msg));
        }
        MessageLevel::Feedback => {
            let fb_kind = pos.get(1).cloned().unwrap_or_default();
            let subject = pos.get(2).cloned().unwrap_or_default();
            let rationale = pos.get(3).cloned().unwrap_or_default();
            if fb_kind.is_empty() || subject.is_empty() {
                usage_and_exit("FEEDBACK requires <kind> <subject> [rationale]");
            }
            kind = fb_kind;
            body.insert("subject".to_string(), serde_json::Value::String(subject));
            body.insert(
                "rationale".to_string(),
                serde_json::Value::String(rationale),
            );
        }
    }

    // Pick the effective corr_id: --corr > CHUMP_CORR_ID env > gap.
    let resolved_corr: Option<String> = corr
        .or_else(|| env::var("CHUMP_CORR_ID").ok().filter(|s| !s.is_empty()))
        .or_else(|| gap.clone());

    let to_str = to.clone().unwrap_or_default();
    if to_str.is_empty() {
        // Phase 1: file-broker writes inbox-only. Without --to there's no
        // inbox to target. Print a hint and exit 2 (matching bash where
        // ambient-only writes also continue, but the operator opting into
        // the Rust path implies they want inbox routing).
        eprintln!("[chump-broadcast] WARN: no --to recipient; Phase 1 FileBroker requires --to.");
        eprintln!(
            "[chump-broadcast] HINT: unset CHUMP_MESSAGING_RUST to use legacy bash callsite for ambient-only emits."
        );
        return ExitCode::from(2);
    }

    let msg = OutboundMessage {
        from: Cow::Owned(from.clone()),
        to: Cow::Owned(to_str.clone()),
        level,
        kind: Cow::Owned(kind),
        urgency,
        corr_id: resolved_corr.map(Cow::Owned),
        gap: gap.clone().map(Cow::Owned),
        body: serde_json::Value::Object(body),
    };

    let broker = FileBroker::new(inbox_dir);
    match broker.send(msg).await {
        Ok(_id) => {
            println!(
                "[chump-broadcast] {} session={} to={}",
                level.as_str(),
                from,
                to_str
            );
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("[chump-broadcast] send failed: {err}");
            ExitCode::from(1)
        }
    }
}
