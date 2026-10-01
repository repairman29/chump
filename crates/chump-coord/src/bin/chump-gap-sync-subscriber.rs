//! `chump-gap-sync-subscriber` — MISSION-054.
//!
//! Persistent Rust binary that subscribes to the gap-lifecycle events
//! already published on `chump.events.*` (`gap_reserved` / `gap_claimed` /
//! `gap_shipped` / `gap_triage_closed` — see `emit_lifecycle_nats` in
//! `crates/chump-gap-store/src/lib.rs`) and applies each one to this node's
//! local `.chump/state.db` via `GapStore::apply_remote_lifecycle_event`.
//!
//! This closes the real-time backlog-coherence loop (MISSION-010): when node
//! A reserves/claims/ships a gap, node B's local state.db reflects that
//! transition within one tick, without either node polling the other's
//! filesystem or waiting for a `git pull` of `docs/gaps/*.yaml`.
//!
//! ## Why this is safe to replay
//!
//! `apply_remote_lifecycle_event` never re-runs ID allocation, proof-of-merge,
//! or lease-conflict checks — those already happened on the publishing node.
//! It is a pure idempotent projection (`INSERT OR IGNORE` / upsert / guarded
//! `UPDATE`), so replaying the same event twice, or a race between this
//! subscriber and a locally-initiated identical mutation, converges to the
//! same row either way. A node that was offline when an event fired will
//! simply never see it over NATS — `docs/gaps/*.yaml` + `chump gap sync`
//! remain the cold-recovery path; this subscriber is the *hot* path.
//!
//! ## Emitted events (ambient.jsonl kinds — see docs/observability/EVENT_REGISTRY.yaml)
//!
//! - `gap_sync_subscriber_started`      — once, at startup
//! - `gap_sync_subscriber_applied`      — per event successfully applied
//! - `gap_sync_subscriber_apply_failed` — per event whose apply errored
//! - `gap_sync_subscriber_heartbeat`    — periodic cumulative counts

// scanner-anchor: "kind":"gap_sync_subscriber_started"
// scanner-anchor: "kind":"gap_sync_subscriber_applied"
// scanner-anchor: "kind":"gap_sync_subscriber_apply_failed"
// scanner-anchor: "kind":"gap_sync_subscriber_heartbeat"

use std::env;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use chump_coord::events::{subscribe_events, CoordEvent, EventFilter};
use chump_gap_store::GapStore;

const LIFECYCLE_KINDS: &[&str] = &[
    "gap_reserved",
    "gap_claimed",
    "gap_shipped",
    "gap_triage_closed",
];
const DEFAULT_HEARTBEAT_INTERVAL_S: u64 = 300;

struct CliArgs {
    repo_root: PathBuf,
    once: bool,
    heartbeat_interval_s: u64,
    help: bool,
}

fn parse_args(argv: &[String]) -> CliArgs {
    let mut repo_root = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let mut once = false;
    let mut heartbeat_interval_s = DEFAULT_HEARTBEAT_INTERVAL_S;
    let mut help = false;
    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "--repo-root" => {
                if let Some(v) = argv.get(i + 1) {
                    repo_root = PathBuf::from(v);
                }
                i += 2;
            }
            "--once" => {
                once = true;
                i += 1;
            }
            "--heartbeat-interval-s" => {
                if let Some(v) = argv.get(i + 1).and_then(|s| s.parse().ok()) {
                    heartbeat_interval_s = v;
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
        repo_root,
        once,
        heartbeat_interval_s,
        help,
    }
}

fn print_help() {
    eprintln!(
        "chump-gap-sync-subscriber — real-time backlog-coherence subscriber (MISSION-054)\n\n\
         USAGE:\n\
         \x20   chump-gap-sync-subscriber [OPTIONS]\n\n\
         FLAGS:\n\
         \x20   --repo-root PATH          repo root containing .chump/state.db (default: cwd)\n\
         \x20   --once                    apply at most one event then exit (test/CI use)\n\
         \x20   --heartbeat-interval-s S  cumulative-count heartbeat cadence (default 300)\n\
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
        eprintln!("[chump-gap-sync-subscriber] failed to emit kind={kind}: {e}");
    }
}

/// Pull `gap=<id>` and the JSON-encoded `reason=<detail>` back out of the
/// wire-format `CoordEvent.payload` produced by `emit_lifecycle_nats`
/// (`crates/chump-gap-store/src/lib.rs`). `reason` is double-encoded: the
/// outer envelope carries it as an opaque string, so it needs a second
/// `serde_json::from_str` to recover the structured detail object.
fn extract_gap_and_detail(event: &CoordEvent) -> (Option<String>, serde_json::Value) {
    let gap_id = event
        .payload
        .get("gap")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let detail = event
        .payload
        .get("reason")
        .and_then(|v| v.as_str())
        .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
        .unwrap_or(serde_json::Value::Null);
    (gap_id, detail)
}

#[derive(Default)]
struct Counters {
    applied: u64,
    failed: u64,
}

fn handle_event(
    repo_root: &Path,
    event: &CoordEvent,
    ambient_override: Option<&PathBuf>,
    counters: &mut Counters,
) {
    let (gap_id, detail) = extract_gap_and_detail(event);
    let Some(gap_id) = gap_id else {
        return;
    };

    let apply_result = GapStore::open(repo_root)
        .and_then(|store| store.apply_remote_lifecycle_event(&event.kind, &gap_id, &detail));

    match apply_result {
        Ok(()) => {
            counters.applied += 1;
            emit_event(
                ambient_override,
                "gap_sync_subscriber_applied",
                vec![
                    ("gap_id".into(), gap_id),
                    ("event_kind".into(), event.kind.clone()),
                ],
            );
        }
        Err(e) => {
            counters.failed += 1;
            emit_event(
                ambient_override,
                "gap_sync_subscriber_apply_failed",
                vec![
                    ("gap_id".into(), gap_id),
                    ("event_kind".into(), event.kind.clone()),
                    ("error".into(), format!("{e:#}")),
                ],
            );
        }
    }
}

fn emit_heartbeat(counters: &Counters, ambient_override: Option<&PathBuf>) {
    emit_event(
        ambient_override,
        "gap_sync_subscriber_heartbeat",
        vec![
            ("applied_total".into(), counters.applied.to_string()),
            ("failed_total".into(), counters.failed.to_string()),
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

    let ambient_override = env::var("CHUMP_AMBIENT_LOG").ok().map(PathBuf::from);
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
        "[chump-gap-sync-subscriber] starting repo_root={:?} mode={mode} once={}",
        cli.repo_root, cli.once
    );
    emit_event(
        ambient_override.as_ref(),
        "gap_sync_subscriber_started",
        vec![("mode".into(), mode.into())],
    );

    let kinds: Vec<String> = LIFECYCLE_KINDS.iter().map(|s| s.to_string()).collect();
    let mut stream = match subscribe_events(EventFilter::Kinds(kinds)).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[chump-gap-sync-subscriber] subscribe failed: {e}");
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
                    &cli.repo_root,
                    &event,
                    ambient_override.as_ref(),
                    &mut counters,
                );
                if cli.once {
                    emit_heartbeat(&counters, ambient_override.as_ref());
                    return ExitCode::SUCCESS;
                }
            }
            Ok(None) => {
                eprintln!("[chump-gap-sync-subscriber] event stream closed");
                return ExitCode::from(1);
            }
            Err(_) => {
                // No event this tick.
                if cli.once && started_at.elapsed() >= ONCE_GRACE {
                    return ExitCode::SUCCESS;
                }
            }
        }

        if last_heartbeat.elapsed() >= heartbeat_interval {
            emit_heartbeat(&counters, ambient_override.as_ref());
            last_heartbeat = Instant::now();
        }
    }
}
