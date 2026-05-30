//! META-159: `chump vote <corr_id> <+1|-1|0> --reason <text>` — emit a
//! FEEDBACK kind=vote event via the broadcast.sh FEEDBACK pathway.
//!
//! Gated behind `CHUMP_FLEET_RECV_SIDE_V0=1`. When the flag is unset,
//! prints "feature flag off, vote not emitted" and exits 0.
//!
//! Shells out to `scripts/coord/broadcast.sh FEEDBACK preference <subject>
//! <reason> <vote>` which emits the FEEDBACK event (ambient.jsonl +
//! NATS) with `kind=preference`, `corr_id=<corr_id>`, `vote=<+1|-1|0>`,
//! and `rationale=<reason>`.
//!
//! NOTE: broadcast.sh maps `preference` kind + `vote` field to structured
//! voting semantics. The tally side reads `kind=vote` from ambient events
//! written by this command. To keep backward compat with broadcast.sh's
//! existing `preference` kind while having the tally side filter on
//! `kind=vote`, this command wraps the emission and emits a secondary
//! ambient line with `kind=vote` after the broadcast call.
//!
//! Acceptance criteria satisfied:
//!   AC1 — vote.rs implements `chump vote <corr_id> <+1|-1|0> --reason <text>`
//!   AC4 — registered in src/main.rs
//!   AC5 — test-chump-vote.sh asserts ambient line has event=FEEDBACK,
//!          kind=vote, vote=<N>, corr_id=<corr_id>, rationale=<reason>
//!   AC7 — feature-flag gated; prints message when unset

use std::path::PathBuf;
use std::process::Command;

/// Parse vote value from string: "+1" → 1, "-1" → -1, "0" → 0.
fn parse_vote(s: &str) -> Option<i32> {
    match s {
        "+1" | "1" => Some(1),
        "-1" => Some(-1),
        "0" => Some(0),
        _ => None,
    }
}

/// Find the repo root (walk up from current dir looking for Cargo.toml at root).
fn repo_root() -> PathBuf {
    // Use CHUMP_REPO_ROOT env override first (set by test harnesses).
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    // Walk up from cwd until we find a Cargo.toml that contains [workspace].
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(content) = std::fs::read_to_string(&cargo) {
                if content.contains("[workspace]") {
                    return dir;
                }
            }
        }
        if !dir.pop() {
            break;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Emit a vote event directly to ambient.jsonl with `kind=vote`.
/// This is the canonical event the consensus-tally side reads.
fn emit_vote_event(
    ambient_path: &std::path::Path,
    corr_id: &str,
    vote: i32,
    reason: &str,
    session_id: &str,
) -> anyhow::Result<()> {
    use std::io::Write;
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    // Escape strings for JSON: replace backslash then double-quote.
    let escaped_reason = reason.replace('\\', "\\\\").replace('"', "\\\"");
    let escaped_corr = corr_id.replace('\\', "\\\\").replace('"', "\\\"");
    let escaped_session = session_id.replace('\\', "\\\\").replace('"', "\\\"");
    let line = format!(
        r#"{{"ts":"{ts}","event":"FEEDBACK","kind":"vote","corr_id":"{escaped_corr}","vote":{vote},"rationale":"{escaped_reason}","session":"{escaped_session}"}}"#,
    );
    // Append to ambient.jsonl; create parent dirs if needed.
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)?;
    writeln!(f, "{line}")?;
    Ok(())
}

pub fn run(args: &[String]) -> i32 {
    // Feature flag gate (AC7).
    if std::env::var("CHUMP_FLEET_RECV_SIDE_V0").as_deref() != Ok("1") {
        println!("feature flag off, vote not emitted");
        return 0;
    }

    // Usage: chump vote <corr_id> <+1|-1|0> --reason <text> [--deadline <ts>]
    if args.len() < 2 {
        eprintln!("Usage: chump vote <corr_id> <+1|-1|0> --reason <text> [--deadline <ts>]");
        return 2;
    }

    let corr_id = &args[0];
    let vote_str = &args[1];
    let vote = match parse_vote(vote_str) {
        Some(v) => v,
        None => {
            eprintln!("vote must be +1, -1, or 0 (got {:?})", vote_str);
            return 2;
        }
    };

    // Parse --reason <text> and optional --deadline <ts>.
    let mut reason = String::new();
    let mut _deadline: Option<String> = None;
    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--reason" => {
                i += 1;
                if i < args.len() {
                    reason = args[i].clone();
                }
            }
            "--deadline" => {
                i += 1;
                if i < args.len() {
                    _deadline = Some(args[i].clone());
                }
            }
            _ => {}
        }
        i += 1;
    }

    if reason.is_empty() {
        eprintln!("--reason <text> is required");
        return 2;
    }

    let root = repo_root();
    let broadcast = root.join("scripts/coord/broadcast.sh");

    // Call broadcast.sh FEEDBACK preference <subject> <reason> <vote>
    // This emits to ambient.jsonl with kind=preference + vote field.
    let vote_str_broadcast = vote.to_string();
    let status = Command::new("bash")
        .arg(&broadcast)
        .arg("FEEDBACK")
        .arg("preference")
        .arg(corr_id)
        .arg(&reason)
        .arg(&vote_str_broadcast)
        .current_dir(&root)
        .status();

    match status {
        Ok(s) if !s.success() => {
            eprintln!("broadcast.sh exited with status {:?}", s.code());
            return 1;
        }
        Err(e) => {
            eprintln!("failed to run broadcast.sh: {e}");
            return 1;
        }
        Ok(_) => {}
    }

    // Also emit a kind=vote line directly to ambient.jsonl so consensus-tally
    // can read it without parsing the preference kind.
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join(".chump-locks/ambient.jsonl"));

    let session_id = std::env::var("CHUMP_SESSION_ID").unwrap_or_else(|_| "unknown".to_string());

    if let Err(e) = emit_vote_event(&ambient_path, corr_id, vote, &reason, &session_id) {
        eprintln!("warn: failed to emit kind=vote event: {e}");
        // Non-fatal: broadcast.sh already emitted the preference event.
    }

    println!("[vote] recorded: corr_id={corr_id} vote={vote:+} reason={reason}");
    0
}
