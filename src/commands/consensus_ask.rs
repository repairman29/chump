//! INFRA-2156 (META-125/C5): `chump consensus ask <question> --reason <text>
//! [--block] [--timeout <secs>] [--id <consensus_id>]` — publish a fleet
//! decision question onto the existing FEEDBACK kind=proposal channel
//! (META-157) and hand back a `consensus_id` (the proposal's `corr_id`)
//! the caller can later look up with `chump consensus-tally --corr-id
//! <id>` or wait on inline with `--block`.
//!
//! This is a thin front door onto machinery that already exists:
//!   - publish  → scripts/coord/broadcast.sh FEEDBACK proposal <id> <question>
//!   - vote     → chump vote <id> +1|-1|0 --reason "..."   (src/commands/vote.rs)
//!   - tally    → deliberator-loop.sh emits kind=consensus_result for <id>
//!                (also readable via `chump consensus-tally --corr-id <id>`)
//!
//! `ask` doesn't reimplement any of that — it gives the question a
//! `consensus_id` up front and, with `--block`, polls ambient.jsonl for the
//! `consensus_result` the deliberator eventually writes.
//!
//! ## Events emitted (AC1 — success/failure/timeout)
//!   - `consensus_ask_published` — question handed to the FEEDBACK channel.
//!     Always emitted on a successful publish; this IS the "success" event
//!     for the non-blocking path (fire-and-forget, matches `chump vote`'s
//!     posture — publish is durable once this event lands).
//!   - `consensus_ask_resolved`  — `--block` only: a `consensus_result` for
//!     this `consensus_id` was observed before the timeout. Carries the
//!     verdict so a caller re-reading ambient.jsonl doesn't have to
//!     re-derive it.
//!   - `consensus_ask_timeout`   — `--block` only: no `consensus_result`
//!     landed inside `--timeout` seconds. `failure_class=transient` (see
//!     below) — the proposal is still live, a later `--block` re-attempt or
//!     `chump consensus-tally` can still resolve it.
//!   - `consensus_ask_failed`    — the publish step itself failed (broadcast.sh
//!     missing/non-zero exit, or bad args). `failure_class` distinguishes
//!     `permanent` (bad input — retrying with the same args won't help) from
//!     `transient` (broadcast.sh/tooling hiccup — retry may succeed).
//!
//! ## Cost tracking (AC2)
//!   `ask` makes zero LLM/API calls itself — the only "cost" is the local
//!   poll loop when `--block` is set (an fs read of ambient.jsonl every
//!   `CHUMP_CONSENSUS_ASK_POLL_SECS`, default 2s). Every terminal event
//!   above carries `poll_count` and `elapsed_secs` so the operator can see
//!   exactly how much local polling a blocked ask burned; there is no
//!   token/dollar cost to report because this path never calls a model.
//!
//! ## Failure-class taxonomy (AC3)
//!   `permanent` — caller error: empty question, malformed `--timeout`,
//!                 missing `--reason`. Retrying identical args always fails
//!                 the same way; fix the invocation.
//!   `transient` — environment/timing: `broadcast.sh` missing or non-zero
//!                 exit, or (block mode) quorum not reached before timeout.
//!                 Retry (or a longer `--timeout` / re-run of `--block`)
//!                 can still succeed without any code change.
//!
//! ## Smoke test (AC4)
//!   scripts/ci/test-chump-consensus-ask.sh — publishes a question with a
//!   fake broadcast.sh, asserts the `consensus_ask_published` event lands
//!   with a `consensus_id`, then seeds a `consensus_result` line and
//!   asserts `--block` returns 0 with `consensus_ask_resolved`, and
//!   separately asserts a `--block --timeout 1` against an unresolved id
//!   returns exit 3 with `consensus_ask_timeout`.
//!
//! Enabled by default (CREDIBLE-179), same flag as `chump vote`. Set
//! `CHUMP_FLEET_RECV_SIDE_V0=0` to opt out: prints "feature flag off,
//! consensus ask not published" and exits 0.
//!
//! ## INFRA-2162 (META-125/C3) note
//! `consensus_ask_published` above is the real event for the umbrella's
//! originally-named `consensus_ask_started` kind — no separate "started"
//! moment exists in this implementation. See
//! docs/observability/EVENT_REGISTRY.yaml's `consensus_ask_started` entry.
// scanner-anchor: "kind":"consensus_ask_started"

use std::io::Write as _;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

/// Exit codes (distinct so callers/scripts can branch on outcome).
const EXIT_OK: i32 = 0;
const EXIT_BAD_ARGS: i32 = 2;
const EXIT_PUBLISH_FAILED: i32 = 1;
const EXIT_BLOCK_TIMEOUT: i32 = 3;

fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
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

fn ambient_path(root: &std::path::Path) -> PathBuf {
    std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join(".chump-locks/ambient.jsonl"))
}

fn escape_json(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Derive a consensus_id from the question when the caller doesn't supply
/// `--id` explicitly: short, stable-ish, still human-legible in logs.
fn derive_consensus_id(question: &str) -> String {
    let ts = chrono::Utc::now().format("%Y%m%dT%H%M%S");
    let slug: String = question
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(24)
        .collect::<String>()
        .to_lowercase();
    if slug.is_empty() {
        format!("consensus-{ts}")
    } else {
        format!("consensus-{slug}-{ts}")
    }
}

fn emit_ambient(
    ambient_log: &std::path::Path,
    kind: &str,
    corr_id: &str,
    session_id: &str,
    extra_fields: &str,
) -> anyhow::Result<()> {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    if let Some(parent) = ambient_log.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut line = format!(
        r#"{{"ts":"{ts}","event":"FEEDBACK","kind":"{kind}","corr_id":"{corr}","session":"{session}""#,
        corr = escape_json(corr_id),
        session = escape_json(session_id),
    );
    if !extra_fields.is_empty() {
        line.push(',');
        line.push_str(extra_fields);
    }
    line.push('}');
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)?;
    writeln!(f, "{line}")?;
    Ok(())
}

/// Best-effort scan of ambient.jsonl for a `kind=consensus_result` line
/// carrying this corr_id; returns the raw `verdict` string if found.
/// Deliberately dumb substring matching (matches the rest of the FEEDBACK
/// tally stack, e.g. consensus_tally.rs / deliberator-loop.sh) rather than
/// a full JSON parse — ambient.jsonl lines are flat and this avoids adding
/// a JSON dependency just to read one field.
fn find_consensus_result(ambient_log: &std::path::Path, corr_id: &str) -> Option<String> {
    let content = std::fs::read_to_string(ambient_log).ok()?;
    let corr_needle = format!("\"corr_id\":\"{}\"", corr_id);
    for line in content.lines().rev() {
        if line.contains("\"kind\":\"consensus_result\"") && line.contains(&corr_needle) {
            return Some(extract_field(line, "verdict").unwrap_or_else(|| "UNKNOWN".to_string()));
        }
    }
    None
}

fn extract_field(line: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":", key);
    let pos = line.find(needle.as_str())?;
    let rest = &line[pos + needle.len()..];
    if let Some(stripped) = rest.strip_prefix('"') {
        let end = stripped.find('"')?;
        Some(stripped[..end].to_string())
    } else {
        let end = rest
            .find(|c: char| c == ',' || c == '}')
            .unwrap_or(rest.len());
        Some(rest[..end].trim().to_string())
    }
}

#[derive(Debug)]
struct Args {
    question: String,
    reason: String,
    consensus_id: Option<String>,
    block: bool,
    timeout_secs: u64,
}

fn parse_args(raw: &[String]) -> Result<Args, String> {
    if raw.is_empty() {
        return Err(
            "Usage: chump consensus ask <question> --reason <text> [--id <consensus_id>] [--block] [--timeout <secs>]"
                .to_string(),
        );
    }
    let question = raw[0].clone();
    if question.trim().is_empty() {
        return Err("question must not be empty".to_string());
    }
    let mut reason = String::new();
    let mut consensus_id = None;
    let mut block = false;
    let mut timeout_secs: u64 = 300;
    let mut i = 1;
    while i < raw.len() {
        match raw[i].as_str() {
            "--reason" => {
                i += 1;
                reason = raw.get(i).cloned().ok_or("--reason requires a value")?;
            }
            "--id" => {
                i += 1;
                consensus_id = Some(raw.get(i).cloned().ok_or("--id requires a value")?);
            }
            "--block" => block = true,
            "--timeout" => {
                i += 1;
                let v = raw.get(i).ok_or("--timeout requires a value")?;
                timeout_secs = v.parse::<u64>().map_err(|_| {
                    format!("--timeout must be an integer number of seconds (got {v:?})")
                })?;
            }
            other => return Err(format!("unrecognized argument: {other}")),
        }
        i += 1;
    }
    if reason.trim().is_empty() {
        return Err("--reason <text> is required".to_string());
    }
    Ok(Args {
        question,
        reason,
        consensus_id,
        block,
        timeout_secs,
    })
}

pub fn run(args: &[String]) -> i32 {
    // CREDIBLE-179: default ON, same rationale as chump vote — see
    // src/commands/vote.rs. Explicit CHUMP_FLEET_RECV_SIDE_V0=0 opts out.
    if std::env::var("CHUMP_FLEET_RECV_SIDE_V0").as_deref() == Ok("0") {
        println!("feature flag off, consensus ask not published");
        return EXIT_OK;
    }

    let parsed = match parse_args(args) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return EXIT_BAD_ARGS;
        }
    };

    let root = repo_root();
    let ambient_log = ambient_path(&root);
    let session_id = std::env::var("CHUMP_SESSION_ID").unwrap_or_else(|_| "unknown".to_string());
    let consensus_id = parsed
        .consensus_id
        .clone()
        .unwrap_or_else(|| derive_consensus_id(&parsed.question));

    // Publish onto the existing FEEDBACK kind=proposal channel (META-157) so
    // the deliberator's normal tally/quorum/escalation path picks this up
    // without any new plumbing.
    let broadcast = root.join("scripts/coord/broadcast.sh");
    let status = Command::new("bash")
        .arg(&broadcast)
        .arg("FEEDBACK")
        .arg("proposal")
        .arg(&consensus_id)
        .arg(format!("{} :: {}", parsed.question, parsed.reason))
        .current_dir(&root)
        .status();

    let publish_ok = matches!(&status, Ok(s) if s.success());
    if !publish_ok {
        let (failure_class, detail) = match &status {
            Ok(s) => (
                "transient",
                format!("broadcast.sh exited with status {:?}", s.code()),
            ),
            Err(e) => ("transient", format!("failed to run broadcast.sh: {e}")),
        };
        eprintln!("[consensus ask] publish failed: {detail}");
        let extra = format!(
            r#""failure_class":"{fc}","detail":"{d}""#,
            fc = failure_class,
            d = escape_json(&detail)
        );
        // scanner-anchor: "kind":"consensus_ask_failed"
        let _ = emit_ambient(
            &ambient_log,
            "consensus_ask_failed",
            &consensus_id,
            &session_id,
            &extra,
        );
        return EXIT_PUBLISH_FAILED;
    }

    let publish_extra = format!(
        r#""question":"{q}","reason":"{r}""#,
        q = escape_json(&parsed.question),
        r = escape_json(&parsed.reason),
    );
    // scanner-anchor: "kind":"consensus_ask_published"
    if let Err(e) = emit_ambient(
        &ambient_log,
        "consensus_ask_published",
        &consensus_id,
        &session_id,
        &publish_extra,
    ) {
        eprintln!("warn: failed to emit consensus_ask_published: {e}");
    }
    println!("[consensus ask] published consensus_id={consensus_id}");

    if !parsed.block {
        // consensus_id is the whole point of the non-blocking return value —
        // print it alone on the last line so callers can `$(chump consensus ask ... | tail -1)`.
        println!("{consensus_id}");
        return EXIT_OK;
    }

    // Block-and-wait: poll ambient.jsonl for the deliberator's consensus_result.
    let poll_interval = std::env::var("CHUMP_CONSENSUS_ASK_POLL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(2);
    let start = Instant::now();
    let deadline = Duration::from_secs(parsed.timeout_secs);
    let mut poll_count: u64 = 0;

    loop {
        poll_count += 1;
        if let Some(verdict) = find_consensus_result(&ambient_log, &consensus_id) {
            let elapsed_secs = start.elapsed().as_secs();
            let extra = format!(
                r#""verdict":"{v}","poll_count":{pc},"elapsed_secs":{es}"#,
                v = escape_json(&verdict),
                pc = poll_count,
                es = elapsed_secs,
            );
            // scanner-anchor: "kind":"consensus_ask_resolved"
            let _ = emit_ambient(
                &ambient_log,
                "consensus_ask_resolved",
                &consensus_id,
                &session_id,
                &extra,
            );
            println!("[consensus ask] resolved consensus_id={consensus_id} verdict={verdict} poll_count={poll_count} elapsed_secs={elapsed_secs}");
            println!("{consensus_id} {verdict}");
            return EXIT_OK;
        }
        if start.elapsed() >= deadline {
            let elapsed_secs = start.elapsed().as_secs();
            let extra = format!(
                r#""failure_class":"transient","poll_count":{pc},"elapsed_secs":{es}"#,
                pc = poll_count,
                es = elapsed_secs,
            );
            // scanner-anchor: "kind":"consensus_ask_timeout"
            let _ = emit_ambient(
                &ambient_log,
                "consensus_ask_timeout",
                &consensus_id,
                &session_id,
                &extra,
            );
            eprintln!("[consensus ask] timeout waiting for consensus_id={consensus_id} after {elapsed_secs}s ({poll_count} polls) — proposal is still live, re-run --block or `chump consensus-tally --corr-id {consensus_id}` later");
            return EXIT_BLOCK_TIMEOUT;
        }
        std::thread::sleep(Duration::from_secs(
            poll_interval.min(deadline.saturating_sub(start.elapsed()).as_secs().max(1)),
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_args_requires_reason() {
        let err = parse_args(&["is X ok".to_string()]).unwrap_err();
        assert!(err.contains("--reason"));
    }

    #[test]
    fn parse_args_rejects_empty_question() {
        let err =
            parse_args(&["".to_string(), "--reason".to_string(), "x".to_string()]).unwrap_err();
        assert!(err.contains("empty"));
    }

    #[test]
    fn parse_args_happy_path_defaults() {
        let a = parse_args(&[
            "should we scale up?".to_string(),
            "--reason".to_string(),
            "waste rate is low".to_string(),
        ])
        .unwrap();
        assert_eq!(a.question, "should we scale up?");
        assert!(!a.block);
        assert_eq!(a.timeout_secs, 300);
        assert!(a.consensus_id.is_none());
    }

    #[test]
    fn parse_args_block_and_timeout_and_id() {
        let a = parse_args(&[
            "q".to_string(),
            "--reason".to_string(),
            "r".to_string(),
            "--id".to_string(),
            "fixed-id".to_string(),
            "--block".to_string(),
            "--timeout".to_string(),
            "45".to_string(),
        ])
        .unwrap();
        assert!(a.block);
        assert_eq!(a.timeout_secs, 45);
        assert_eq!(a.consensus_id.as_deref(), Some("fixed-id"));
    }

    #[test]
    fn derive_consensus_id_is_slugged_and_nonempty() {
        let id = derive_consensus_id("Should we scale to 4 workers?");
        assert!(id.starts_with("consensus-"));
        assert!(!id.contains(' '));
        assert!(!id.contains('?'));
    }

    #[test]
    fn extract_field_reads_quoted_value() {
        let line = r#"{"ts":"x","kind":"consensus_result","corr_id":"abc","verdict":"PASSED"}"#;
        assert_eq!(extract_field(line, "verdict").as_deref(), Some("PASSED"));
    }

    #[test]
    fn find_consensus_result_matches_corr_id_and_picks_latest() {
        let dir = std::env::temp_dir().join(format!(
            "consensus-ask-test-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ambient.jsonl");
        std::fs::write(
            &path,
            "{\"kind\":\"consensus_result\",\"corr_id\":\"other\",\"verdict\":\"FAILED\"}\n\
             {\"kind\":\"consensus_result\",\"corr_id\":\"target\",\"verdict\":\"PASSED\"}\n",
        )
        .unwrap();
        assert_eq!(
            find_consensus_result(&path, "target"),
            Some("PASSED".to_string())
        );
        assert_eq!(find_consensus_result(&path, "missing"), None);
        std::fs::remove_dir_all(&dir).ok();
    }
}
