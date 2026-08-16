//! `chump-disk-inventory-daemon` — META-128/C2 (INFRA-2193)
//!
//! Polls `df` for the checkout/tmp/`~/.chump` filesystems and `du` for known
//! disk-hog consumer paths every `CHUMP_DISK_POLL_S` seconds (default 30),
//! writes an atomic-rename snapshot to `~/.chump/disk-inventory.json`, and
//! publishes to NATS subject `chump.disk.inventory.<node-id>` when
//! `CHUMP_NATS_URL` is set (file-only otherwise, and on publish failure).
//!
//! Complements INFRA-2125 (cargo-target-reaper) and INFRA-2181 (reaper
//! post-ship trigger) by giving both a structural, always-on view of what's
//! actually consuming disk — including the cargo-runner cache leak class
//! from INFRA-2188.
//!
//! ## Observability contract (INFRA-2359)
//!
//! - **Events**: `disk_inventory_updated` on every successful poll cycle,
//!   `disk_critical` when free space crosses `CHUMP_DISK_THRESHOLD_GB`, and
//!   `disk_inventory_poll_failed` when a poll cycle errors (carries
//!   `failure_class`, see [`chump_disk_inventory::classify_poll_failure`]).
//!   All three are registered in `docs/observability/EVENT_REGISTRY.yaml`.
//! - **Cost**: none tracked. This daemon only spawns local `df`/`du`
//!   processes and (optionally) publishes to a self-hosted NATS broker —
//!   there is no metered/external API call, so unlike LLM-driven daemons
//!   (e.g. `ci_lesson_captured`'s `cost_usd`) there is nothing to report.
//! - **Failure taxonomy**: `transient_io` (df/du spawn or I/O failure — the
//!   next poll cycle, `CHUMP_DISK_POLL_S` later, is expected to self-heal)
//!   vs `config_or_parse` (unexpected output shape / no watch path resolved
//!   — needs a code/config fix, won't self-heal on retry).
//! - **Smoke test**: `scripts/ci/test-disk-inventory-daemon.sh`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::Result;
use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use chump_disk_inventory::{
    attempt_publish, build_snapshot, default_chump_dir, nats_subject, parse_df_line,
    parse_du_multi, resolve_node_id, resolve_poll_interval_s, resolve_threshold_gb, Consumer,
    DiskSnapshot,
};
use glob::glob;
use tracing::{error, info, warn};

/// Filesystems we poll with `df` (deduped by mount, but pass the raw paths —
/// `df` resolves each to its containing filesystem).
fn df_watch_paths() -> Vec<PathBuf> {
    vec![
        PathBuf::from("/tmp"),
        default_chump_dir(),
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    ]
}

/// Glob patterns for known disk-hog consumer paths (INFRA-2188 cargo-runner
/// cache leak, worktree build dirs, NATS store, etc).
fn du_watch_globs() -> Vec<String> {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    vec![
        "/tmp/chump-*".to_string(),
        format!("{home}/.cache/chump-runner"),
        format!("{home}/.chump/nats"),
        "/tmp/chump-coord-linux-build*".to_string(),
        format!("{home}/.cargo/registry"),
    ]
}

/// Run `df -kP <path>` and return `(total_kb, used_kb, free_kb)`.
fn df_stat(path: &Path) -> Result<(u64, u64, u64)> {
    let out = std::process::Command::new("df")
        .args(["-kP", &path.to_string_lossy()])
        .output()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let data_line = text.lines().nth(1).unwrap_or("");
    parse_df_line(data_line)
        .ok_or_else(|| anyhow::anyhow!("could not parse df output for {}", path.display()))
}

/// Cap on how many glob matches feed one `du` batch call — a `/tmp/chump-*`
/// pattern can expand to thousands of stale worktree/test dirs on a busy
/// fleet box, and even one `du` process per PATH ARGUMENT stays cheap while
/// one PROCESS SPAWN per match does not (observed: 1300+ matches turned a
/// 30s poll cycle into a multi-minute stall). Matches beyond the cap are
/// dropped with a warn log, not silently.
const DU_BATCH_CAP: usize = 500;

/// `du -sk <p1> <p2> ...` in a single process for every matched path in one
/// glob pattern — one fork/exec instead of one per match.
fn du_stat_batch(paths: &[PathBuf]) -> Vec<(u64, String)> {
    if paths.is_empty() {
        return Vec::new();
    }
    let args: Vec<String> = paths
        .iter()
        .map(|p| p.to_string_lossy().to_string())
        .collect();
    let out = match std::process::Command::new("du")
        .arg("-sk")
        .args(&args)
        .output()
    {
        Ok(o) => o,
        Err(e) => {
            warn!(error = %e, "du batch spawn failed");
            return Vec::new();
        }
    };
    let text = String::from_utf8_lossy(&out.stdout);
    parse_du_multi(&text)
}

fn mtime_iso8601(path: &Path) -> String {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .map(chrono::DateTime::<chrono::Utc>::from)
        .map(|dt| dt.to_rfc3339())
        .unwrap_or_default()
}

/// Expand glob patterns and batch-`du` each pattern's matches into `Consumer`s.
fn gather_consumers() -> Vec<Consumer> {
    let mut consumers = Vec::new();
    for pattern in du_watch_globs() {
        let entries = match glob(&pattern) {
            Ok(e) => e,
            Err(e) => {
                warn!(pattern = %pattern, error = %e, "invalid glob pattern");
                continue;
            }
        };
        let mut matches: Vec<PathBuf> = entries.flatten().collect();
        let total = matches.len();
        if total > DU_BATCH_CAP {
            warn!(
                pattern = %pattern,
                total,
                cap = DU_BATCH_CAP,
                "glob match count exceeds du batch cap, truncating"
            );
            matches.truncate(DU_BATCH_CAP);
        }
        let mtimes: std::collections::HashMap<String, String> = matches
            .iter()
            .map(|p| (p.to_string_lossy().to_string(), mtime_iso8601(p)))
            .collect();
        for (kb, path) in du_stat_batch(&matches) {
            let mtime = mtimes.get(&path).cloned().unwrap_or_default();
            consumers.push(Consumer {
                path,
                size_gb: chump_disk_inventory::kb_to_gb(kb),
                mtime,
            });
        }
    }
    consumers
}

fn snapshot_path() -> PathBuf {
    default_chump_dir().join("disk-inventory.json")
}

fn emit_ambient(kind: &str, fields: Vec<(String, String)>) {
    let args = EmitArgs {
        kind: kind.to_string(),
        source: Some("chump-disk-inventory-daemon".to_string()),
        fields,
        ..Default::default()
    };
    if let Err(e) = emit(&args) {
        warn!(kind, error = %e, "ambient emit failed");
    }
}

async fn publish_nats(nats_url: &str, subject: &str, snapshot: &DiskSnapshot) -> Result<()> {
    let client = async_nats::connect(nats_url).await?;
    let payload = serde_json::to_vec(snapshot)?;
    client.publish(subject.to_string(), payload.into()).await?;
    client.flush().await?;
    Ok(())
}

/// Poll `df` across every watched filesystem (`/tmp`, `~/.chump`, the main
/// checkout) and pick the one with the least free space as the canonical
/// `(total_kb, used_kb, free_kb)` triple — the tightest constraint is the
/// actionable one for headroom monitoring, and on a single-volume box every
/// watch path resolves to the same filesystem anyway.
fn df_worst_case() -> Result<(u64, u64, u64)> {
    let mut worst: Option<(u64, u64, u64)> = None;
    let mut last_err = None;
    for path in df_watch_paths() {
        match df_stat(&path) {
            Ok(stat @ (_, _, avail)) => {
                if worst.map(|(_, _, w)| avail < w).unwrap_or(true) {
                    worst = Some(stat);
                }
            }
            Err(e) => last_err = Some(e),
        }
    }
    worst.ok_or_else(|| last_err.unwrap_or_else(|| anyhow::anyhow!("no df watch paths resolved")))
}

async fn poll_once(chump_dir: &Path, threshold_gb: f64) -> Result<DiskSnapshot> {
    let node_id = resolve_node_id(chump_dir);
    let ts = chrono::Utc::now().to_rfc3339();

    let (total_kb, used_kb, free_kb) = match df_worst_case() {
        Ok(v) => v,
        Err(e) => {
            // scanner-anchor: "kind":"disk_inventory_poll_failed" (registered in docs/observability/EVENT_REGISTRY.yaml, INFRA-2359)
            emit_ambient(
                "disk_inventory_poll_failed",
                vec![
                    ("node_id".to_string(), node_id.clone()),
                    ("stage".to_string(), "df".to_string()),
                    (
                        "failure_class".to_string(),
                        chump_disk_inventory::classify_poll_failure(&e).to_string(),
                    ),
                    ("error".to_string(), e.to_string()),
                ],
            );
            return Err(e);
        }
    };
    let consumers = gather_consumers();

    let snapshot = build_snapshot(
        ts,
        node_id,
        total_kb,
        used_kb,
        free_kb,
        threshold_gb,
        consumers,
    );

    write_snapshot(&snapshot)?;

    // scanner-anchor: "kind":"disk_inventory_updated" (registered in docs/observability/EVENT_REGISTRY.yaml, INFRA-2359)
    emit_ambient(
        "disk_inventory_updated",
        vec![
            ("node_id".to_string(), snapshot.node_id.clone()),
            ("free_gb".to_string(), format!("{:.2}", snapshot.free_gb)),
            (
                "headroom_gb".to_string(),
                format!("{:.2}", snapshot.headroom_gb),
            ),
        ],
    );

    if chump_disk_inventory::is_critical(snapshot.free_gb, snapshot.threshold_gb) {
        emit_ambient(
            "disk_critical",
            vec![
                ("node_id".to_string(), snapshot.node_id.clone()),
                ("free_gb".to_string(), format!("{:.2}", snapshot.free_gb)),
                (
                    "threshold_gb".to_string(),
                    format!("{:.2}", snapshot.threshold_gb),
                ),
            ],
        );
    }

    if let Ok(nats_url) = std::env::var("CHUMP_NATS_URL") {
        if !nats_url.is_empty() {
            let subject = nats_subject(&snapshot.node_id);
            let ok = attempt_publish(|| publish_nats(&nats_url, &subject, &snapshot)).await;
            if !ok {
                warn!(nats_url = %nats_url, "NATS publish failed, snapshot file is authoritative");
            }
        }
    }

    Ok(snapshot)
}

fn write_snapshot(snapshot: &DiskSnapshot) -> Result<()> {
    chump_disk_inventory::write_snapshot_atomic(&snapshot_path(), snapshot)
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let chump_dir = default_chump_dir();
    std::fs::create_dir_all(&chump_dir).ok();
    let threshold_gb = resolve_threshold_gb();
    let poll_s = resolve_poll_interval_s();

    info!(poll_s, threshold_gb, "chump-disk-inventory-daemon starting");

    loop {
        match poll_once(&chump_dir, threshold_gb).await {
            Ok(snap) => info!(
                node_id = %snap.node_id,
                free_gb = %format!("{:.2}", snap.free_gb),
                headroom_gb = %format!("{:.2}", snap.headroom_gb),
                "poll cycle complete"
            ),
            Err(e) => error!(error = %e, "poll cycle failed"),
        }
        tokio::time::sleep(Duration::from_secs(poll_s)).await;
    }
}
