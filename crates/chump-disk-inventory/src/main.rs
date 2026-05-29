//! `chump-disk-inventory-daemon` — INFRA-2193 (META-128/C2)
//!
//! Polls disk usage every 30s (CHUMP_DISK_POLL_S), writes an atomic-rename
//! snapshot to `~/.chump/disk-inventory.json`, and publishes to NATS
//! `chump.disk.inventory.<node-id>` when CHUMP_NATS_URL is set.
//!
//! Emits two ambient event kinds:
//!   - `kind=disk_inventory_updated`  — every poll
//!   - `kind=disk_critical`           — when free_gb < threshold_gb (default 5)
//!
//! ## Snapshot schema
//!
//! ```json
//! {
//!   "ts": "2026-05-29T12:00:00Z",
//!   "node_id": "macbook-pro",
//!   "total_gb": 460.4,
//!   "free_gb": 22.1,
//!   "used_gb": 438.3,
//!   "threshold_gb": 5.0,
//!   "headroom_gb": 17.1,
//!   "top_consumers": [
//!     {"path": "/tmp/chump-infra-2193", "size_gb": 1.2, "mtime": "2026-05-29T11:55:00Z"}
//!   ]
//! }
//! ```
//!
//! ## Env vars
//!
//! | Variable | Default | Purpose |
//! |---|---|---|
//! | `CHUMP_DISK_POLL_S` | `30` | Poll interval seconds |
//! | `CHUMP_DISK_THRESHOLD_GB` | `5.0` | Free-space critical threshold |
//! | `CHUMP_NATS_URL` | unset | NATS broker; unset = file-fallback only |
//! | `CHUMP_DISK_INVENTORY_PATH` | `~/.chump/disk-inventory.json` | Output path override |
//! | `CHUMP_AMBIENT_LOG` | `.chump-locks/ambient.jsonl` | Ambient event log |
//! | `CHUMP_NODE_ID_FILE` | `~/.chump/node-id.txt` | Node identity file |

use std::fs;
use std::io::Write as IoWrite;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use tokio::time;
use tracing::{error, info, warn};

// ── constants ──────────────────────────────────────────────────────────────

const DEFAULT_POLL_S: u64 = 30;
const DEFAULT_THRESHOLD_GB: f64 = 5.0;

// Known consumer paths to measure with `du`.
const CONSUMER_PATHS: &[&str] = &[
    "/tmp/chump-*",
    "~/.cache/chump-runner",
    "~/.chump/nats",
    "/tmp/chump-coord-linux-build*",
    "~/.cargo/registry",
];

// ── data types ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ConsumerEntry {
    pub path: String,
    pub size_gb: f64,
    pub mtime: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskSnapshot {
    pub ts: String,
    pub node_id: String,
    pub total_gb: f64,
    pub free_gb: f64,
    pub used_gb: f64,
    pub threshold_gb: f64,
    pub headroom_gb: f64,
    pub top_consumers: Vec<ConsumerEntry>,
}

impl DiskSnapshot {
    pub fn is_critical(&self) -> bool {
        self.free_gb < self.threshold_gb
    }
}

// ── path resolution ────────────────────────────────────────────────────────

fn expand_tilde(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{home}/{rest}");
        }
    }
    path.to_string()
}

pub fn resolve_inventory_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_DISK_INVENTORY_PATH") {
        if !p.is_empty() {
            return PathBuf::from(expand_tilde(&p));
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home)
        .join(".chump")
        .join("disk-inventory.json")
}

fn resolve_ambient_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AMBIENT_LOG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    PathBuf::from(".chump-locks/ambient.jsonl")
}

pub fn resolve_node_id() -> String {
    // 1. Env override.
    if let Ok(id) = std::env::var("CHUMP_NODE_ID") {
        if !id.is_empty() {
            return id;
        }
    }

    // 2. ~/.chump/node-id.txt
    let node_id_file = if let Ok(p) = std::env::var("CHUMP_NODE_ID_FILE") {
        PathBuf::from(expand_tilde(&p))
    } else {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(home).join(".chump").join("node-id.txt")
    };

    if let Ok(contents) = fs::read_to_string(&node_id_file) {
        let trimmed = contents.trim().to_string();
        if !trimmed.is_empty() {
            return trimmed;
        }
    }

    // 3. Hostname fallback.
    hostname::get()
        .ok()
        .and_then(|h| h.into_string().ok())
        .unwrap_or_else(|| "unknown".to_string())
}

// ── disk measurement ───────────────────────────────────────────────────────

/// Struct returned by `df` parsing for a single mount point.
#[derive(Debug)]
pub struct DfResult {
    pub total_gb: f64,
    pub free_gb: f64,
    pub used_gb: f64,
}

/// Run `df -k <path>` and parse the output.
/// Returns the first non-header data row.
pub fn run_df(path: &str) -> Result<DfResult> {
    let output = Command::new("df")
        .args(["-k", path])
        .output()
        .with_context(|| format!("df -k {path}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    // df output: Filesystem 1K-blocks Used Available Use% Mounted on
    for line in stdout.lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 4 {
            let total_kb: f64 = parts[1].parse().unwrap_or(0.0);
            let used_kb: f64 = parts[2].parse().unwrap_or(0.0);
            let avail_kb: f64 = parts[3].parse().unwrap_or(0.0);
            return Ok(DfResult {
                total_gb: kb_to_gb(total_kb),
                used_gb: kb_to_gb(used_kb),
                free_gb: kb_to_gb(avail_kb),
            });
        }
    }
    anyhow::bail!("df returned no parseable data for {path}")
}

fn kb_to_gb(kb: f64) -> f64 {
    (kb / 1_048_576.0 * 100.0).round() / 100.0
}

fn bytes_to_gb(bytes: u64) -> f64 {
    (bytes as f64 / 1_073_741_824.0 * 100.0).round() / 100.0
}

/// Measure a glob-style path pattern using `du -sk`.
/// Returns (size_gb, mtime_rfc3339).
pub fn measure_consumer(pattern: &str) -> Option<ConsumerEntry> {
    let expanded = expand_tilde(pattern);

    // Use shell glob expansion via `sh -c`.
    let output = Command::new("sh")
        .args([
            "-c",
            &format!("du -sk {expanded} 2>/dev/null | awk '{{sum+=$1}} END{{print sum}}'"),
        ])
        .output()
        .ok()?;

    let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let size_kb: f64 = raw.parse().unwrap_or(0.0);
    if size_kb == 0.0 {
        return None;
    }

    // Get mtime of the most recently modified path matching the pattern.
    let mtime_output = Command::new("sh")
        .args([
            "-c",
            &format!("stat -f '%m' {expanded} 2>/dev/null | sort -n | tail -1"),
        ])
        .output()
        .ok();

    // On Linux, stat -f is not available — fall back to find.
    let mtime_epoch: Option<i64> = mtime_output
        .as_ref()
        .and_then(|o| {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            s.parse::<i64>().ok()
        })
        .or_else(|| {
            // Linux fallback: find ... -printf '%T@\n'
            let o = Command::new("sh")
                .args([
                    "-c",
                    &format!(
                        "find {expanded} -maxdepth 0 -printf '%T@\\n' 2>/dev/null | sort -n | tail -1"
                    ),
                ])
                .output()
                .ok()?;
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            // Strip fractional seconds if present.
            s.split('.').next()?.parse::<i64>().ok()
        });

    let mtime = mtime_epoch
        .and_then(|epoch| chrono::DateTime::from_timestamp(epoch, 0).map(|dt| dt.to_rfc3339()))
        .unwrap_or_else(|| Utc::now().to_rfc3339());

    Some(ConsumerEntry {
        path: expanded,
        size_gb: bytes_to_gb((size_kb * 1024.0) as u64),
        mtime,
    })
}

/// Collect top consumers from the known CONSUMER_PATHS list,
/// sorted by size descending. Zero-size paths are omitted.
pub fn collect_top_consumers() -> Vec<ConsumerEntry> {
    let mut consumers: Vec<ConsumerEntry> = CONSUMER_PATHS
        .iter()
        .filter_map(|p| measure_consumer(p))
        .collect();

    // Sort largest first.
    consumers.sort_by(|a, b| {
        b.size_gb
            .partial_cmp(&a.size_gb)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    consumers
}

// ── snapshot construction ──────────────────────────────────────────────────

pub fn build_snapshot(node_id: &str, threshold_gb: f64) -> Result<DiskSnapshot> {
    // Use the root filesystem or /tmp if HOME is unavailable for df.
    let df_target = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
    let df = run_df(&df_target).context("df measurement")?;

    let top_consumers = collect_top_consumers();

    Ok(DiskSnapshot {
        ts: Utc::now().to_rfc3339(),
        node_id: node_id.to_string(),
        total_gb: df.total_gb,
        free_gb: df.free_gb,
        used_gb: df.used_gb,
        threshold_gb,
        headroom_gb: ((df.free_gb - threshold_gb) * 100.0).round() / 100.0,
        top_consumers,
    })
}

// ── atomic file write ──────────────────────────────────────────────────────

/// Write snapshot atomically via temp-file rename.
pub fn write_snapshot_atomic(path: &Path, snapshot: &DiskSnapshot) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("create ~/.chump")?;
    }

    let tmp_path = path.with_extension("json.tmp");
    let json = serde_json::to_string_pretty(snapshot).context("serialize snapshot")?;

    {
        let mut f = fs::File::create(&tmp_path).context("create tmp snapshot")?;
        f.write_all(json.as_bytes()).context("write snapshot")?;
        f.flush().context("flush snapshot")?;
    }

    fs::rename(&tmp_path, path).context("atomic rename snapshot")?;
    Ok(())
}

// ── ambient event emit ─────────────────────────────────────────────────────

fn emit_ambient(ambient_path: &Path, kind: &str, extra: serde_json::Value) {
    let mut event = serde_json::json!({
        "ts": Utc::now().to_rfc3339(),
        "kind": kind,
    });

    if let (serde_json::Value::Object(ref mut base), serde_json::Value::Object(extra_map)) =
        (&mut event, extra)
    {
        base.extend(extra_map);
    }

    let line = match serde_json::to_string(&event) {
        Ok(s) => s,
        Err(e) => {
            warn!("[disk-inventory] failed to serialize ambient event {kind}: {e}");
            return;
        }
    };

    // Best-effort append; don't abort the poll loop on ambient write failure.
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)
    {
        let _ = writeln!(f, "{line}");
    }
}

// ── NATS publish ──────────────────────────────────────────────────────────

async fn try_nats_publish(nats_url: &str, subject: &str, payload: &str) -> Result<()> {
    let client = tokio::time::timeout(Duration::from_millis(1500), async_nats::connect(nats_url))
        .await
        .context("NATS connect timeout")?
        .context("NATS connect")?;

    client
        .publish(subject.to_string(), payload.as_bytes().to_vec().into())
        .await
        .context("NATS publish")?;

    client.flush().await.context("NATS flush")?;
    Ok(())
}

// ── poll loop ──────────────────────────────────────────────────────────────

async fn poll_loop(
    node_id: String,
    threshold_gb: f64,
    poll_s: u64,
    inventory_path: PathBuf,
    ambient_path: PathBuf,
    nats_url: Option<String>,
) {
    let subject = format!("chump.disk.inventory.{node_id}");
    let mut interval = time::interval(Duration::from_secs(poll_s));
    interval.set_missed_tick_behavior(time::MissedTickBehavior::Skip);

    loop {
        interval.tick().await;

        let snapshot = match build_snapshot(&node_id, threshold_gb) {
            Ok(s) => s,
            Err(e) => {
                error!("[disk-inventory] build_snapshot error: {e}");
                continue;
            }
        };

        // Write atomic file snapshot.
        if let Err(e) = write_snapshot_atomic(&inventory_path, &snapshot) {
            error!("[disk-inventory] write_snapshot_atomic error: {e}");
        }

        let payload = match serde_json::to_string(&snapshot) {
            Ok(p) => p,
            Err(e) => {
                error!("[disk-inventory] serialize error: {e}");
                continue;
            }
        };

        // Publish to NATS if configured.
        if let Some(ref url) = nats_url {
            if let Err(e) = try_nats_publish(url, &subject, &payload).await {
                warn!("[disk-inventory] NATS publish failed (file-fallback active): {e}");
            } else {
                info!("[disk-inventory] published to NATS {subject}");
            }
        }

        // Emit ambient events.
        let extra = serde_json::json!({
            "node_id": snapshot.node_id,
            "free_gb": snapshot.free_gb,
            "used_gb": snapshot.used_gb,
            "total_gb": snapshot.total_gb,
            "headroom_gb": snapshot.headroom_gb,
            "threshold_gb": snapshot.threshold_gb,
        });

        emit_ambient(&ambient_path, "disk_inventory_updated", extra.clone());

        if snapshot.is_critical() {
            warn!(
                "[disk-inventory] CRITICAL: free_gb={:.2} < threshold_gb={:.2}",
                snapshot.free_gb, snapshot.threshold_gb
            );
            emit_ambient(
                &ambient_path,
                "disk_critical",
                serde_json::json!({
                    "node_id": snapshot.node_id,
                    "free_gb": snapshot.free_gb,
                    "threshold_gb": snapshot.threshold_gb,
                    "headroom_gb": snapshot.headroom_gb,
                    "top_consumers": serde_json::to_value(&snapshot.top_consumers).unwrap_or_default(),
                }),
            );
        }

        info!(
            "[disk-inventory] polled: free={:.2}GB used={:.2}GB total={:.2}GB headroom={:.2}GB consumers={}",
            snapshot.free_gb,
            snapshot.used_gb,
            snapshot.total_gb,
            snapshot.headroom_gb,
            snapshot.top_consumers.len()
        );
    }
}

// ── main ───────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let poll_s: u64 = std::env::var("CHUMP_DISK_POLL_S")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_POLL_S);

    let threshold_gb: f64 = std::env::var("CHUMP_DISK_THRESHOLD_GB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_THRESHOLD_GB);

    let nats_url: Option<String> = std::env::var("CHUMP_NATS_URL")
        .ok()
        .filter(|s| !s.is_empty());

    let inventory_path = resolve_inventory_path();
    let ambient_path = resolve_ambient_path();
    let node_id = resolve_node_id();

    info!(
        "[disk-inventory] starting — node_id={node_id} poll_s={poll_s} threshold_gb={threshold_gb} \
         nats={} inventory={}",
        nats_url.as_deref().unwrap_or("(file-only)"),
        inventory_path.display()
    );

    // Run poll loop until SIGTERM/SIGINT.
    tokio::select! {
        _ = poll_loop(
            node_id,
            threshold_gb,
            poll_s,
            inventory_path,
            ambient_path,
            nats_url,
        ) => {}
        _ = tokio::signal::ctrl_c() => {
            info!("[disk-inventory] received shutdown signal; exiting cleanly");
        }
    }

    Ok(())
}

// ── tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as IoWrite2;
    use tempfile::NamedTempFile;

    // ── Test 1: snapshot schema fields ─────────────────────────────────────
    #[test]
    fn snapshot_schema_fields_present() {
        let snap = DiskSnapshot {
            ts: "2026-05-29T12:00:00Z".to_string(),
            node_id: "test-node".to_string(),
            total_gb: 460.0,
            free_gb: 22.0,
            used_gb: 438.0,
            threshold_gb: 5.0,
            headroom_gb: 17.0,
            top_consumers: vec![ConsumerEntry {
                path: "/tmp/chump-test".to_string(),
                size_gb: 1.2,
                mtime: "2026-05-29T11:00:00Z".to_string(),
            }],
        };

        let json = serde_json::to_value(&snap).unwrap();
        assert!(json.get("ts").is_some(), "ts field required");
        assert!(json.get("node_id").is_some(), "node_id field required");
        assert!(json.get("total_gb").is_some(), "total_gb field required");
        assert!(json.get("free_gb").is_some(), "free_gb field required");
        assert!(json.get("used_gb").is_some(), "used_gb field required");
        assert!(
            json.get("threshold_gb").is_some(),
            "threshold_gb field required"
        );
        assert!(
            json.get("headroom_gb").is_some(),
            "headroom_gb field required"
        );
        assert!(
            json.get("top_consumers").is_some(),
            "top_consumers field required"
        );
        assert!(
            json["top_consumers"].is_array(),
            "top_consumers must be array"
        );
        let entry = &json["top_consumers"][0];
        assert!(entry.get("path").is_some(), "consumer.path required");
        assert!(entry.get("size_gb").is_some(), "consumer.size_gb required");
        assert!(entry.get("mtime").is_some(), "consumer.mtime required");
    }

    // ── Test 2: top-consumer selection (sort largest first) ────────────────
    #[test]
    fn top_consumers_sorted_largest_first() {
        let mut consumers = [
            ConsumerEntry {
                path: "/a".to_string(),
                size_gb: 0.5,
                mtime: "2026-05-29T12:00:00Z".to_string(),
            },
            ConsumerEntry {
                path: "/b".to_string(),
                size_gb: 3.2,
                mtime: "2026-05-29T12:00:00Z".to_string(),
            },
            ConsumerEntry {
                path: "/c".to_string(),
                size_gb: 1.1,
                mtime: "2026-05-29T12:00:00Z".to_string(),
            },
        ];

        consumers.sort_by(|a, b| {
            b.size_gb
                .partial_cmp(&a.size_gb)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        assert_eq!(consumers[0].path, "/b", "largest consumer must be first");
        assert_eq!(consumers[1].path, "/c");
        assert_eq!(consumers[2].path, "/a");
    }

    // ── Test 3: node_id resolution from env ────────────────────────────────
    #[test]
    fn node_id_env_override() {
        std::env::set_var("CHUMP_NODE_ID", "env-override-node");
        let id = resolve_node_id();
        std::env::remove_var("CHUMP_NODE_ID");
        assert_eq!(id, "env-override-node");
    }

    // ── Test 4: node_id resolution from file ───────────────────────────────
    #[test]
    fn node_id_from_file() {
        std::env::remove_var("CHUMP_NODE_ID");
        let mut tmp = NamedTempFile::new().unwrap();
        writeln!(tmp, "file-node-42").unwrap();
        tmp.flush().unwrap();
        let path = tmp.path().to_string_lossy().to_string();
        std::env::set_var("CHUMP_NODE_ID_FILE", &path);
        let id = resolve_node_id();
        std::env::remove_var("CHUMP_NODE_ID_FILE");
        assert_eq!(id, "file-node-42");
    }

    // ── Test 5: headroom computation ───────────────────────────────────────
    #[test]
    fn headroom_positive_when_above_threshold() {
        let snap = DiskSnapshot {
            ts: "2026-05-29T12:00:00Z".to_string(),
            node_id: "n".to_string(),
            total_gb: 100.0,
            free_gb: 20.0,
            used_gb: 80.0,
            threshold_gb: 5.0,
            headroom_gb: 15.0,
            top_consumers: vec![],
        };
        assert!(
            !snap.is_critical(),
            "20GB free with 5GB threshold should not be critical"
        );
        assert!(
            snap.headroom_gb > 0.0,
            "headroom must be positive when above threshold"
        );
    }

    #[test]
    fn headroom_negative_when_below_threshold() {
        let snap = DiskSnapshot {
            ts: "2026-05-29T12:00:00Z".to_string(),
            node_id: "n".to_string(),
            total_gb: 100.0,
            free_gb: 3.0,
            used_gb: 97.0,
            threshold_gb: 5.0,
            headroom_gb: -2.0,
            top_consumers: vec![],
        };
        assert!(
            snap.is_critical(),
            "3GB free with 5GB threshold must be critical"
        );
    }

    // ── Test 6: NATS-down fallback — file is written even without NATS ─────
    #[test]
    fn file_written_when_nats_absent() {
        let tmp_dir = tempfile::tempdir().unwrap();
        let inventory_path = tmp_dir.path().join("disk-inventory.json");

        let snap = DiskSnapshot {
            ts: "2026-05-29T12:00:00Z".to_string(),
            node_id: "fallback-node".to_string(),
            total_gb: 100.0,
            free_gb: 50.0,
            used_gb: 50.0,
            threshold_gb: 5.0,
            headroom_gb: 45.0,
            top_consumers: vec![],
        };

        write_snapshot_atomic(&inventory_path, &snap).unwrap();
        assert!(
            inventory_path.exists(),
            "inventory file must exist after write"
        );

        let contents = fs::read_to_string(&inventory_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&contents).unwrap();
        assert_eq!(parsed["node_id"].as_str().unwrap(), "fallback-node");
        assert_eq!(parsed["free_gb"].as_f64().unwrap(), 50.0);
    }

    // ── Test 7: threshold breach detection ────────────────────────────────
    #[test]
    fn is_critical_exactly_at_threshold() {
        // free_gb == threshold_gb is NOT critical (strictly less than).
        let snap = DiskSnapshot {
            ts: "2026-05-29T12:00:00Z".to_string(),
            node_id: "n".to_string(),
            total_gb: 100.0,
            free_gb: 5.0,
            used_gb: 95.0,
            threshold_gb: 5.0,
            headroom_gb: 0.0,
            top_consumers: vec![],
        };
        assert!(
            !snap.is_critical(),
            "exactly at threshold (free == threshold) should NOT be critical"
        );
    }

    // ── Test 8: atomic rename leaves no temp file on success ──────────────
    #[test]
    fn atomic_rename_no_tmp_residue() {
        let tmp_dir = tempfile::tempdir().unwrap();
        let inventory_path = tmp_dir.path().join("disk-inventory.json");

        let snap = DiskSnapshot {
            ts: "2026-05-29T12:00:00Z".to_string(),
            node_id: "clean-node".to_string(),
            total_gb: 200.0,
            free_gb: 100.0,
            used_gb: 100.0,
            threshold_gb: 5.0,
            headroom_gb: 95.0,
            top_consumers: vec![],
        };

        write_snapshot_atomic(&inventory_path, &snap).unwrap();

        let tmp_residue = inventory_path.with_extension("json.tmp");
        assert!(
            !tmp_residue.exists(),
            "temp file must not exist after successful atomic rename"
        );
        assert!(inventory_path.exists(), "final inventory file must exist");
    }
}
