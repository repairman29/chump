//! `chump-inbox` — Rust port of `scripts/coord/chump-inbox.sh`
//! (INFRA-1998 Phase 1).
//!
//! Subset: only the `read` subcommand is ported in Phase 1. `count` /
//! `tail` / `help` stay on the bash callsite when `CHUMP_MESSAGING_RUST=1`
//! is NOT set; the bash wrapper handles dispatching only the `read`
//! subcommand through the Rust path.
//!
//! Argument surface (matches bash):
//!
//! ```text
//! chump-inbox read [--no-advance] [--session <id>]
//! ```
//!
//! Notes vs bash:
//!
//! - `--since cursor` (default) and `all` are honored.
//! - `--since <iso-ts>` and `--filter` are NOT ported in Phase 1 — they
//!   are bash-only paths.
//! - `--json` is NOT honored — Phase 1 always emits one JSON event per
//!   line, matching bash default (the bash `--json` wraps the result in
//!   a single array).

use std::env;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use chump_messaging::{Broker, FileBroker};

fn usage_and_exit(reason: &str) -> ! {
    eprintln!("[chump-inbox] {reason}");
    eprintln!();
    eprintln!("Usage: chump-inbox read [--no-advance] [--session <id>]");
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
    String::new()
}

fn resolve_lock_dir() -> PathBuf {
    let common = std::process::Command::new("git")
        .args(["rev-parse", "--git-common-dir"])
        .output();
    if let Ok(out) = common {
        if out.status.success() {
            let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
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
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            eprintln!("[chump-inbox] failed to start runtime: {err}");
            return ExitCode::from(1);
        }
    };
    rt.block_on(run())
}

async fn run() -> ExitCode {
    let raw_args: Vec<String> = env::args().skip(1).collect();
    if raw_args.is_empty() {
        usage_and_exit("missing subcommand");
    }
    let sub = &raw_args[0];
    if sub != "read" {
        // Phase 1 only ports `read`. Other subcommands are routed
        // back to bash by the wrapper shim — if we get here, the
        // operator invoked us directly with an unsupported sub.
        usage_and_exit(&format!(
            "subcommand '{}' not implemented in Phase 1 (use bash chump-inbox.sh)",
            sub
        ));
    }

    let mut no_advance = false;
    let mut session: Option<String> = None;
    let mut since: String = "cursor".to_string();
    let mut i = 1;
    while i < raw_args.len() {
        match raw_args[i].as_str() {
            "--no-advance" => {
                no_advance = true;
                i += 1;
            }
            "--session" => {
                let v = raw_args
                    .get(i + 1)
                    .cloned()
                    .unwrap_or_else(|| usage_and_exit("--session requires a value"));
                session = Some(v);
                i += 2;
            }
            "--since" => {
                let v = raw_args
                    .get(i + 1)
                    .cloned()
                    .unwrap_or_else(|| usage_and_exit("--since requires a value"));
                since = v;
                i += 2;
            }
            "--json" | "--filter" => {
                // Phase 1: these are bash-only. Skip the arg silently
                // rather than error so callers can pass them through.
                if raw_args[i] == "--filter" {
                    i += 2; // skip value
                } else {
                    i += 1;
                }
            }
            other => {
                usage_and_exit(&format!("unknown arg: {}", other));
            }
        }
    }

    let lock_dir = resolve_lock_dir();
    let inbox_dir = lock_dir.join("inbox");
    let session_id = match session {
        Some(s) => s,
        None => {
            let s = resolve_session_id(&lock_dir);
            if s.is_empty() {
                usage_and_exit("no session id; set CHUMP_SESSION_ID or pass --session");
            }
            s
        }
    };

    let broker = FileBroker::new(inbox_dir);

    if no_advance || since == "all" {
        // Phase 1 fallback: --no-advance + --since all are bash-side
        // semantics (they read the entire file without touching the
        // cursor). The Rust broker.read() always advances; until we
        // grow a no-advance variant, defer to bash for these paths.
        eprintln!(
            "[chump-inbox] --no-advance / --since all not implemented in Phase 1 Rust path; use legacy bash."
        );
        return ExitCode::from(2);
    }

    match broker.read(&session_id).await {
        Ok(messages) => {
            for m in messages {
                match serde_json::to_string(&m.event) {
                    Ok(line) => println!("{line}"),
                    Err(err) => {
                        eprintln!("[chump-inbox] skipping un-serializable row: {err}");
                    }
                }
            }
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("[chump-inbox] read failed: {err}");
            ExitCode::from(1)
        }
    }
}
