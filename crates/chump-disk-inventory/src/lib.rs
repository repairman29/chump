//! `chump-disk-inventory` — META-128/C2 (INFRA-2193)
//!
//! Core, testable logic for the disk-inventory daemon: snapshot schema,
//! df/du output parsing, top-consumer selection, node-id resolution, and
//! headroom/threshold math. I/O orchestration (spawning `df`/`du`, opening
//! NATS, the poll loop) lives in `main.rs`; this module stays free of
//! process-spawning so it's cheap to unit-test.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Default free-space threshold (GB) below which a node is "disk critical".
pub const DEFAULT_THRESHOLD_GB: f64 = 5.0;

/// Default poll interval in seconds.
pub const DEFAULT_POLL_S: u64 = 30;

/// How many top consumers to retain in a snapshot.
pub const TOP_CONSUMER_LIMIT: usize = 10;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Consumer {
    pub path: String,
    pub size_gb: f64,
    pub mtime: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiskSnapshot {
    pub ts: String,
    pub node_id: String,
    pub total_gb: f64,
    pub free_gb: f64,
    pub used_gb: f64,
    pub threshold_gb: f64,
    pub top_consumers: Vec<Consumer>,
    pub headroom_gb: f64,
}

/// Convert 1024-byte blocks (as reported by `df -k` / `du -k`) to GB.
pub fn kb_to_gb(kb: u64) -> f64 {
    (kb as f64) / (1024.0 * 1024.0)
}

/// Parse a single data line of `df -kP <path>` output.
///
/// Expected format (POSIX `-P`):
/// `Filesystem 1024-blocks Used Available Capacity Mounted-on`
/// Returns `(total_kb, used_kb, avail_kb)`.
pub fn parse_df_line(line: &str) -> Option<(u64, u64, u64)> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    if fields.len() < 4 {
        return None;
    }
    let total = fields[1].parse::<u64>().ok()?;
    let used = fields[2].parse::<u64>().ok()?;
    let avail = fields[3].parse::<u64>().ok()?;
    Some((total, used, avail))
}

/// Parse `du -sk <path>` output line: `<kb>\t<path>`.
pub fn parse_du_line(line: &str) -> Option<u64> {
    line.split_whitespace().next()?.parse::<u64>().ok()
}

/// Parse multi-path `du -sk <p1> <p2> ...` output: one `<kb>\t<path>` line
/// per argument. Used to batch a glob's matches into a single `du` process
/// spawn instead of one-per-match (avoids the fork-storm a `/tmp/chump-*`
/// glob with thousands of matches would otherwise trigger).
pub fn parse_du_multi(text: &str) -> Vec<(u64, String)> {
    text.lines()
        .filter_map(|line| {
            let mut parts = line.splitn(2, char::is_whitespace);
            let kb = parts.next()?.parse::<u64>().ok()?;
            let path = parts.next()?.trim().to_string();
            Some((kb, path))
        })
        .collect()
}

/// Compute headroom (can be negative once below threshold).
pub fn compute_headroom(free_gb: f64, threshold_gb: f64) -> f64 {
    free_gb - threshold_gb
}

/// Whether free space has crossed the critical threshold.
pub fn is_critical(free_gb: f64, threshold_gb: f64) -> bool {
    free_gb < threshold_gb
}

/// Sort consumers descending by size and keep the top `limit`.
pub fn select_top_consumers(mut consumers: Vec<Consumer>, limit: usize) -> Vec<Consumer> {
    consumers.sort_by(|a, b| {
        b.size_gb
            .partial_cmp(&a.size_gb)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    consumers.truncate(limit);
    consumers
}

/// Resolve this node's identity: `~/.chump/node-id.txt` (or
/// `<chump_dir>/node-id.txt` when a dir is passed explicitly), falling back
/// to the OS hostname, falling back to `"unknown-node"`.
pub fn resolve_node_id(chump_dir: &Path) -> String {
    let node_id_path = chump_dir.join("node-id.txt");
    if let Ok(contents) = fs::read_to_string(&node_id_path) {
        let trimmed = contents.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    hostname_fallback()
}

fn hostname_fallback() -> String {
    if let Ok(h) = std::env::var("HOSTNAME") {
        if !h.trim().is_empty() {
            return h.trim().to_string();
        }
    }
    if let Ok(out) = std::process::Command::new("hostname").output() {
        if out.status.success() {
            let h = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !h.is_empty() {
                return h;
            }
        }
    }
    "unknown-node".to_string()
}

/// Default `~/.chump` directory, honoring `CHUMP_HOME` for tests/overrides.
pub fn default_chump_dir() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_HOME") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    dirs_home().join(".chump")
}

fn dirs_home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}

/// Assemble a full snapshot from already-gathered parts.
#[allow(clippy::too_many_arguments)]
pub fn build_snapshot(
    ts: String,
    node_id: String,
    total_kb: u64,
    used_kb: u64,
    free_kb: u64,
    threshold_gb: f64,
    consumers: Vec<Consumer>,
) -> DiskSnapshot {
    let total_gb = kb_to_gb(total_kb);
    let used_gb = kb_to_gb(used_kb);
    let free_gb = kb_to_gb(free_kb);
    let top_consumers = select_top_consumers(consumers, TOP_CONSUMER_LIMIT);
    let headroom_gb = compute_headroom(free_gb, threshold_gb);
    DiskSnapshot {
        ts,
        node_id,
        total_gb,
        free_gb,
        used_gb,
        threshold_gb,
        top_consumers,
        headroom_gb,
    }
}

/// Atomically write the snapshot to `path` (tmp-write + rename).
pub fn write_snapshot_atomic(path: &Path, snapshot: &DiskSnapshot) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("create snapshot parent dir")?;
    }
    let tmp_path = path.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(snapshot).context("serialize snapshot")?;
    fs::write(&tmp_path, body).context("write tmp snapshot")?;
    fs::rename(&tmp_path, path).context("atomic rename snapshot")?;
    Ok(())
}

/// NATS subject for a given node.
pub fn nats_subject(node_id: &str) -> String {
    format!("chump.disk.inventory.{node_id}")
}

/// Resolve the poll interval in seconds from `CHUMP_DISK_POLL_S`, falling
/// back to `DEFAULT_POLL_S` on unset/invalid values.
pub fn resolve_poll_interval_s() -> u64 {
    std::env::var("CHUMP_DISK_POLL_S")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|&v| v > 0)
        .unwrap_or(DEFAULT_POLL_S)
}

/// Resolve the free-space critical threshold in GB from
/// `CHUMP_DISK_THRESHOLD_GB`, falling back to `DEFAULT_THRESHOLD_GB`.
pub fn resolve_threshold_gb() -> f64 {
    std::env::var("CHUMP_DISK_THRESHOLD_GB")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|&v| v > 0.0)
        .unwrap_or(DEFAULT_THRESHOLD_GB)
}

/// Attempt a NATS publish via the given closure, but never let a failure
/// propagate — a down/unreachable broker degrades to file-only mode. Returns
/// `true` on a successful publish, `false` on any error (caller logs).
pub async fn attempt_publish<F, Fut>(publish: F) -> bool
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<()>>,
{
    match publish().await {
        Ok(()) => true,
        Err(_) => false,
    }
}

/// Failure-class taxonomy for a `poll_once` error (INFRA-2359).
///
/// - `"transient_io"` — the underlying cause is a `std::io::Error` (e.g. `df`/`du`
///   temporarily unavailable, resource exhaustion). The next poll cycle
///   (`CHUMP_DISK_POLL_S` later) is expected to self-heal without operator
///   action.
/// - `"config_or_parse"` — everything else (unexpected `df`/`du` output shape,
///   no watch path resolved). Retrying on the same cadence will not fix this;
///   it needs a code/config change, so repeated occurrences should page an
///   operator rather than be treated as noise.
pub fn classify_poll_failure(err: &anyhow::Error) -> &'static str {
    if err
        .chain()
        .any(|c| c.downcast_ref::<std::io::Error>().is_some())
    {
        "transient_io"
    } else {
        "config_or_parse"
    }
}

#[cfg(test)]
mod failure_classification_tests {
    use super::*;

    #[test]
    fn io_error_classified_transient() {
        let err = anyhow::Error::new(std::io::Error::other("spawn failed"));
        assert_eq!(classify_poll_failure(&err), "transient_io");
    }

    #[test]
    fn wrapped_io_error_classified_transient() {
        let err = anyhow::Error::new(std::io::Error::other("spawn failed"))
            .context("could not parse df output for /tmp");
        assert_eq!(classify_poll_failure(&err), "transient_io");
    }

    #[test]
    fn non_io_error_classified_config_or_parse() {
        let err = anyhow::anyhow!("no df watch paths resolved");
        assert_eq!(classify_poll_failure(&err), "config_or_parse");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn snapshot_schema_round_trips_through_json() {
        let snap = build_snapshot(
            "2026-08-16T00:00:00Z".to_string(),
            "test-node".to_string(),
            100 * 1024 * 1024,
            40 * 1024 * 1024,
            60 * 1024 * 1024,
            5.0,
            vec![Consumer {
                path: "/tmp/chump-foo".to_string(),
                size_gb: 2.5,
                mtime: "2026-08-16T00:00:00Z".to_string(),
            }],
        );
        let json = serde_json::to_string(&snap).unwrap();
        let parsed: DiskSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, snap);
        assert!(json.contains("\"headroom_gb\""));
        assert!(json.contains("\"top_consumers\""));
    }

    #[test]
    fn top_consumer_selection_sorts_desc_and_truncates() {
        let consumers = vec![
            Consumer {
                path: "/a".into(),
                size_gb: 1.0,
                mtime: "t".into(),
            },
            Consumer {
                path: "/b".into(),
                size_gb: 5.0,
                mtime: "t".into(),
            },
            Consumer {
                path: "/c".into(),
                size_gb: 3.0,
                mtime: "t".into(),
            },
        ];
        let top = select_top_consumers(consumers, 2);
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].path, "/b");
        assert_eq!(top[1].path, "/c");
    }

    #[test]
    fn node_id_resolution_prefers_file_over_hostname() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("node-id.txt"), "my-node-123\n").unwrap();
        assert_eq!(resolve_node_id(dir.path()), "my-node-123");
    }

    #[test]
    fn node_id_resolution_falls_back_to_hostname_when_file_missing() {
        let dir = tempdir().unwrap();
        let id = resolve_node_id(dir.path());
        assert!(!id.is_empty());
    }

    #[test]
    fn headroom_computation_is_free_minus_threshold() {
        assert_eq!(compute_headroom(10.0, 5.0), 5.0);
        assert_eq!(compute_headroom(3.0, 5.0), -2.0);
    }

    #[test]
    fn threshold_breach_detection() {
        assert!(is_critical(2.0, 5.0));
        assert!(!is_critical(8.0, 5.0));
        assert!(!is_critical(5.0, 5.0)); // exactly at threshold is not < threshold
    }

    #[test]
    fn df_line_parses_total_used_avail() {
        let line = "/dev/disk1s1 976490568 500000000 400000000 56% /";
        let (total, used, avail) = parse_df_line(line).unwrap();
        assert_eq!(total, 976490568);
        assert_eq!(used, 500000000);
        assert_eq!(avail, 400000000);
    }

    #[test]
    fn df_line_rejects_short_lines() {
        assert!(parse_df_line("Filesystem").is_none());
    }

    #[test]
    fn du_line_parses_leading_kb_field() {
        assert_eq!(parse_du_line("12345\t/tmp/chump-foo"), Some(12345));
        assert_eq!(parse_du_line(""), None);
    }

    #[test]
    fn du_multi_parses_one_pair_per_line() {
        let text = "100\t/tmp/chump-a\n200\t/tmp/chump-b\n";
        let parsed = parse_du_multi(text);
        assert_eq!(
            parsed,
            vec![
                (100, "/tmp/chump-a".to_string()),
                (200, "/tmp/chump-b".to_string()),
            ]
        );
    }

    #[test]
    fn write_snapshot_atomic_creates_parent_and_file() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nested").join("disk-inventory.json");
        let snap = build_snapshot(
            "2026-08-16T00:00:00Z".to_string(),
            "n".to_string(),
            1024 * 1024,
            0,
            1024 * 1024,
            5.0,
            vec![],
        );
        write_snapshot_atomic(&path, &snap).unwrap();
        assert!(path.exists());
        let contents = fs::read_to_string(&path).unwrap();
        let parsed: DiskSnapshot = serde_json::from_str(&contents).unwrap();
        assert_eq!(parsed.node_id, "n");
    }

    #[test]
    fn nats_subject_includes_node_id() {
        assert_eq!(nats_subject("macbook-1"), "chump.disk.inventory.macbook-1");
    }

    #[test]
    fn poll_interval_falls_back_to_default_on_invalid_env() {
        std::env::remove_var("CHUMP_DISK_POLL_S");
        assert_eq!(resolve_poll_interval_s(), DEFAULT_POLL_S);
    }

    #[tokio::test]
    async fn nats_down_publish_failure_degrades_gracefully() {
        let ok = attempt_publish(|| async { Err(anyhow::anyhow!("connection refused")) }).await;
        assert!(
            !ok,
            "attempt_publish should report failure, not panic/propagate"
        );

        let ok = attempt_publish(|| async { Ok(()) }).await;
        assert!(ok);
    }
}
