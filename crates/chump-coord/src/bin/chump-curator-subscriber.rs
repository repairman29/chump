//! `chump-curator-subscriber` — INFRA-2154 / META-125 C4.
//!
//! Persistent Rust binary that subscribes to `chump.events.curator_dispatch_<role>`
//! (via `chump_coord::events::subscribe_events`) and hands each matching event to
//! an optional external handler, replacing shell-loop polling of ambient.jsonl /
//! the inbox for a single curator role.
//!
//! ## Routing contract
//!
//! A producer addresses a role by emitting an event with
//! `kind = "curator_dispatch_<role>"` (e.g. `curator_dispatch_shepherd`) and a
//! payload shaped `{"corr_id": "...", ...opaque}`. This binary subscribes to
//! exactly that kind for the role passed via `--role`.
//!
//! ## Handler
//!
//! `--exec <path>` is spawned once per matching event: the event's JSON line is
//! written to the child's stdin, `CURATOR_SUBSCRIBER_ROLE=<role>` is set in its
//! environment. Without `--exec`, the daemon runs in dry-run/observability mode —
//! every matching event is acknowledged as succeeded without side effects. This
//! is the safe default: standing this binary up does not, by itself, cause any
//! curator loop to execute.
//!
//! ## Emitted events (ambient.jsonl kinds — see docs/observability/EVENT_REGISTRY.yaml)
//!
//! - `curator_subscriber_started`           — once, at startup
//! - `curator_subscriber_dispatch_received`  — per matching event pulled off the stream
//! - `curator_subscriber_dispatch_succeeded` — handler exited 0 within the timeout
//! - `curator_subscriber_dispatch_failed`    — handler failed; carries `failure_class`
//! - `curator_subscriber_dispatch_timeout`   — handler exceeded `--event-timeout-s`
//! - `curator_subscriber_heartbeat`          — periodic; carries cumulative counts +
//!    `cost_proxy_ms_total` (summed handler wall-clock — the cost proxy an operator
//!    reads off `ambient tail` / `api-cost-leaderboard.sh` without per-token billing,
//!    since the spawned handler is an opaque subprocess).
//!
//! ## Failure-class taxonomy
//!
//! - `permanent` — the payload is malformed (no `corr_id`) or `--exec` names a
//!   binary that does not exist. Retrying will not help; the event is skipped.
//! - `transient` — the handler ran and exited non-zero, or was killed for
//!   exceeding `--event-timeout-s`. Retried up to `--max-retries` times
//!   (default 2) with a short backoff before being recorded as failed.

// scanner-anchor: "kind":"curator_subscriber_started"
// scanner-anchor: "kind":"curator_subscriber_dispatch_received"
// scanner-anchor: "kind":"curator_subscriber_dispatch_succeeded"
// scanner-anchor: "kind":"curator_subscriber_dispatch_failed"
// scanner-anchor: "kind":"curator_subscriber_dispatch_timeout"
// scanner-anchor: "kind":"curator_subscriber_heartbeat"

use std::env;
use std::io::Write;
use std::path::PathBuf;
use std::process::{ExitCode, Stdio};
use std::time::{Duration, Instant};

use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use chump_coord::events::{subscribe_events, CoordEvent, EventFilter};

const DEFAULT_EVENT_TIMEOUT_S: u64 = 900; // matches CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S doctrine
const DEFAULT_HEARTBEAT_INTERVAL_S: u64 = 300;
const DEFAULT_MAX_RETRIES: u32 = 2;
const RETRY_BACKOFF_MS: u64 = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FailureClass {
    Transient,
    Permanent,
}

impl FailureClass {
    fn as_str(&self) -> &'static str {
        match self {
            FailureClass::Transient => "transient",
            FailureClass::Permanent => "permanent",
        }
    }
}

struct CliArgs {
    role: Option<String>,
    exec: Option<PathBuf>,
    once: bool,
    event_timeout_s: u64,
    heartbeat_interval_s: u64,
    max_retries: u32,
    help: bool,
}

fn parse_args(argv: &[String]) -> CliArgs {
    let mut role = None;
    let mut exec = None;
    let mut once = false;
    let mut event_timeout_s = DEFAULT_EVENT_TIMEOUT_S;
    let mut heartbeat_interval_s = DEFAULT_HEARTBEAT_INTERVAL_S;
    let mut max_retries = DEFAULT_MAX_RETRIES;
    let mut help = false;
    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "--role" => {
                role = argv.get(i + 1).cloned();
                i += 2;
            }
            "--exec" => {
                exec = argv.get(i + 1).map(PathBuf::from);
                i += 2;
            }
            "--once" => {
                once = true;
                i += 1;
            }
            "--event-timeout-s" => {
                if let Some(v) = argv.get(i + 1).and_then(|s| s.parse().ok()) {
                    event_timeout_s = v;
                }
                i += 2;
            }
            "--heartbeat-interval-s" => {
                if let Some(v) = argv.get(i + 1).and_then(|s| s.parse().ok()) {
                    heartbeat_interval_s = v;
                }
                i += 2;
            }
            "--max-retries" => {
                if let Some(v) = argv.get(i + 1).and_then(|s| s.parse().ok()) {
                    max_retries = v;
                }
                i += 2;
            }
            "-h" | "--help" => {
                help = true;
                i += 1;
            }
            _ => i += 1,
        }
    }
    CliArgs {
        role,
        exec,
        once,
        event_timeout_s,
        heartbeat_interval_s,
        max_retries,
        help,
    }
}

fn print_help() {
    eprintln!(
        "chump-curator-subscriber — persistent NATS subscriber per curator role (INFRA-2154)\n\n\
         USAGE:\n\
         \x20   chump-curator-subscriber --role <ROLE> [OPTIONS]\n\n\
         FLAGS:\n\
         \x20   --role ROLE               curator role to subscribe as (required) — matches\n\
         \x20                             events with kind=curator_dispatch_<ROLE>\n\
         \x20   --exec PATH               handler binary/script invoked per matching event\n\
         \x20                             (event JSON on stdin). Omit for dry-run mode.\n\
         \x20   --once                    process at most one event then exit (test/CI use)\n\
         \x20   --event-timeout-s SECS    handler wall-clock budget (default 900)\n\
         \x20   --heartbeat-interval-s S  cumulative-cost heartbeat cadence (default 300)\n\
         \x20   --max-retries N           retries for transient handler failures (default 2)\n\
         \x20   -h, --help                print this message\n\n\
         ENV:\n\
         \x20   CHUMP_A2A_LAYER           1 = NATS-primary subscribe; 0 (default) = file-tail\n\
         \x20   CHUMP_AMBIENT_LOG         override ambient.jsonl path (tests)\n"
    );
}

fn emit_event(ambient_override: Option<&PathBuf>, kind: &str, fields: Vec<(String, String)>) {
    let args = EmitArgs {
        kind: kind.to_string(),
        fields,
        ambient_override: ambient_override.cloned(),
        ..Default::default()
    };
    if let Err(e) = emit(&args) {
        eprintln!("[chump-curator-subscriber] failed to emit kind={kind}: {e}");
    }
}

fn corr_id_of(event: &CoordEvent) -> String {
    event
        .payload
        .get("corr_id")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string()
}

/// Result of a single handler attempt.
enum HandlerOutcome {
    Success,
    Failed { class: FailureClass, reason: String },
    TimedOut,
}

fn run_handler_once(
    exec: &PathBuf,
    role: &str,
    event: &CoordEvent,
    timeout: Duration,
) -> (HandlerOutcome, Duration) {
    let started = Instant::now();
    let line = match serde_json::to_string(event) {
        Ok(l) => l,
        Err(e) => {
            return (
                HandlerOutcome::Failed {
                    class: FailureClass::Permanent,
                    reason: format!("payload serialize error: {e}"),
                },
                started.elapsed(),
            )
        }
    };

    let mut child = match std::process::Command::new(exec)
        .env("CURATOR_SUBSCRIBER_ROLE", role)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            return (
                HandlerOutcome::Failed {
                    class: FailureClass::Permanent,
                    reason: format!("spawn error: {e}"),
                },
                started.elapsed(),
            )
        }
    };

    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(line.as_bytes());
    }

    // Poll for completion so we can enforce the wall-clock budget without a
    // dependency on tokio's process reaper (this binary's I/O loop is sync).
    let poll_interval = Duration::from_millis(50);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let elapsed = started.elapsed();
                return if status.success() {
                    (HandlerOutcome::Success, elapsed)
                } else {
                    (
                        HandlerOutcome::Failed {
                            class: FailureClass::Transient,
                            reason: format!("handler exited with {status}"),
                        },
                        elapsed,
                    )
                };
            }
            Ok(None) => {
                if started.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return (HandlerOutcome::TimedOut, started.elapsed());
                }
                std::thread::sleep(poll_interval);
            }
            Err(e) => {
                return (
                    HandlerOutcome::Failed {
                        class: FailureClass::Transient,
                        reason: format!("wait error: {e}"),
                    },
                    started.elapsed(),
                )
            }
        }
    }
}

#[derive(Default)]
struct Counters {
    processed: u64,
    succeeded: u64,
    failed: u64,
    timed_out: u64,
    cost_proxy_ms_total: u128,
}

fn handle_event(
    role: &str,
    exec: Option<&PathBuf>,
    event: &CoordEvent,
    event_timeout_s: u64,
    max_retries: u32,
    ambient_override: Option<&PathBuf>,
    counters: &mut Counters,
) {
    let corr_id = corr_id_of(event);
    counters.processed += 1;
    emit_event(
        ambient_override,
        "curator_subscriber_dispatch_received",
        vec![
            ("role".into(), role.into()),
            ("corr_id".into(), corr_id.clone()),
        ],
    );

    if event
        .payload
        .get("corr_id")
        .and_then(|v| v.as_str())
        .is_none()
    {
        counters.failed += 1;
        emit_event(
            ambient_override,
            "curator_subscriber_dispatch_failed",
            vec![
                ("role".into(), role.into()),
                ("corr_id".into(), corr_id),
                (
                    "failure_class".into(),
                    FailureClass::Permanent.as_str().into(),
                ),
                ("reason".into(), "missing corr_id in payload".into()),
            ],
        );
        return;
    }

    let Some(exec) = exec else {
        // Dry-run mode: acknowledge receipt as success with zero cost.
        counters.succeeded += 1;
        emit_event(
            ambient_override,
            "curator_subscriber_dispatch_succeeded",
            vec![
                ("role".into(), role.into()),
                ("corr_id".into(), corr_id),
                ("elapsed_ms".into(), "0".into()),
                ("mode".into(), "dry_run".into()),
            ],
        );
        return;
    };

    let timeout = Duration::from_secs(event_timeout_s);
    let mut attempt = 0u32;
    loop {
        let (outcome, elapsed) = run_handler_once(exec, role, event, timeout);
        counters.cost_proxy_ms_total += elapsed.as_millis();
        match outcome {
            HandlerOutcome::Success => {
                counters.succeeded += 1;
                emit_event(
                    ambient_override,
                    "curator_subscriber_dispatch_succeeded",
                    vec![
                        ("role".into(), role.into()),
                        ("corr_id".into(), corr_id),
                        ("elapsed_ms".into(), elapsed.as_millis().to_string()),
                        ("attempt".into(), (attempt + 1).to_string()),
                    ],
                );
                return;
            }
            HandlerOutcome::TimedOut => {
                counters.timed_out += 1;
                emit_event(
                    ambient_override,
                    "curator_subscriber_dispatch_timeout",
                    vec![
                        ("role".into(), role.into()),
                        ("corr_id".into(), corr_id.clone()),
                        ("timeout_s".into(), event_timeout_s.to_string()),
                        ("attempt".into(), (attempt + 1).to_string()),
                    ],
                );
                if attempt >= max_retries {
                    counters.failed += 1;
                    return;
                }
            }
            HandlerOutcome::Failed { class, reason } => {
                if class == FailureClass::Permanent || attempt >= max_retries {
                    counters.failed += 1;
                    emit_event(
                        ambient_override,
                        "curator_subscriber_dispatch_failed",
                        vec![
                            ("role".into(), role.into()),
                            ("corr_id".into(), corr_id.clone()),
                            ("elapsed_ms".into(), elapsed.as_millis().to_string()),
                            ("failure_class".into(), class.as_str().into()),
                            ("reason".into(), reason),
                            ("attempt".into(), (attempt + 1).to_string()),
                        ],
                    );
                    return;
                }
                std::thread::sleep(Duration::from_millis(RETRY_BACKOFF_MS));
            }
        }
        attempt += 1;
    }
}

fn emit_heartbeat(role: &str, counters: &Counters, ambient_override: Option<&PathBuf>) {
    emit_event(
        ambient_override,
        "curator_subscriber_heartbeat",
        vec![
            ("role".into(), role.into()),
            ("processed_total".into(), counters.processed.to_string()),
            ("succeeded_total".into(), counters.succeeded.to_string()),
            ("failed_total".into(), counters.failed.to_string()),
            ("timeout_total".into(), counters.timed_out.to_string()),
            (
                "cost_proxy_ms_total".into(),
                counters.cost_proxy_ms_total.to_string(),
            ),
        ],
    );
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let argv: Vec<String> = env::args().collect();
    let cli = parse_args(&argv);
    if cli.help {
        print_help();
        return ExitCode::SUCCESS;
    }
    let Some(role) = cli.role else {
        eprintln!("[chump-curator-subscriber] --role is required");
        print_help();
        return ExitCode::from(2);
    };

    let ambient_override = env::var("CHUMP_AMBIENT_LOG").ok().map(PathBuf::from);
    let kind = format!("curator_dispatch_{role}");
    let mode = if env::var("CHUMP_A2A_LAYER")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(0)
        >= 1
    {
        "nats"
    } else {
        "file"
    };

    eprintln!(
        "[chump-curator-subscriber] starting role={role} kind={kind} mode={mode} exec={:?} once={}",
        cli.exec, cli.once
    );
    emit_event(
        ambient_override.as_ref(),
        "curator_subscriber_started",
        vec![("role".into(), role.clone()), ("mode".into(), mode.into())],
    );

    let mut stream = match subscribe_events(EventFilter::Kind(kind)).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[chump-curator-subscriber] subscribe failed: {e}");
            return ExitCode::from(1);
        }
    };

    let mut counters = Counters::default();
    let heartbeat_interval = Duration::from_secs(cli.heartbeat_interval_s);
    let mut last_heartbeat = Instant::now();
    let started_at = Instant::now();
    const ONCE_GRACE: Duration = Duration::from_secs(3);

    loop {
        let recv = tokio::time::timeout(Duration::from_secs(1), stream.next()).await;
        match recv {
            Ok(Some(event)) => {
                handle_event(
                    &role,
                    cli.exec.as_ref(),
                    &event,
                    cli.event_timeout_s,
                    cli.max_retries,
                    ambient_override.as_ref(),
                    &mut counters,
                );
                if cli.once {
                    emit_heartbeat(&role, &counters, ambient_override.as_ref());
                    return ExitCode::SUCCESS;
                }
            }
            Ok(None) => {
                eprintln!("[chump-curator-subscriber] event stream closed");
                return ExitCode::from(1);
            }
            Err(_) => {
                // No event this tick.
                if cli.once && started_at.elapsed() >= ONCE_GRACE {
                    // --once with nothing matching within a short grace
                    // window exits cleanly (used by smoke tests that assert
                    // "no matching event => no false success").
                    return ExitCode::SUCCESS;
                }
            }
        }

        if last_heartbeat.elapsed() >= heartbeat_interval {
            emit_heartbeat(&role, &counters, ambient_override.as_ref());
            last_heartbeat = Instant::now();
        }
    }
}
