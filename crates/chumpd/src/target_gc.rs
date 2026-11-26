//! Cross-platform bounded Cargo target-cache & orphan-worktree GC (`ZERO-WASTE-052`, `RESILIENT-307`).
//!
//! Why this lives in `chumpd` as pure Rust:
//! `scripts/coord/shared-target-cache-reaper.sh` relied on Linux-only GNU flags
//! (`du -s -BG`, `df -BG`, `flock`, `mapfile`) and silently no-opped on macOS
//! and Windows, allowing `~/.cargo/chump-shared-target` and
//! `~/.cache/chump-fleet-target` to grow past 55 GiB and push host storage to
//! 95% full.
//!
//! Safety invariants (`RESILIENT-1647`, `RESILIENT-1680`):
//! - Thresholds and paths are compile-time constants + explicit function args
//!   (no `CHUMP_*` env overrides on safety inputs).
//! - Any live `cargo`, `rustc`, `cargo-nextest`, or `rustdoc` process skips the
//!   target sweep completely so an active build never loses artifacts mid-link.
//! - `release/deps` is never pruned, keeping warm production `.rlib` caches intact.
//! - Orphan worktrees under `.claude/worktrees` and `.chump/worktrees` are only
//!   removed when older than `DEFAULT_ORPHAN_WORKTREE_MAX_AGE_SECS`, unleased in
//!   `.chump-locks/*.json`, and completely clean (`git status --porcelain` empty,
//!   protecting both tracked edits and untracked files).

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

/// Default periodic GC cadence (1 hour, with an immediate pass after boot).
pub const DEFAULT_TARGET_GC_INTERVAL_SECS: u64 = 3600;

/// Shared Cargo target size budget in GiB above which debug artifacts are pruned.
pub const DEFAULT_SHARED_TARGET_BUDGET_GB: f64 = 25.0;

/// Free-disk floor in GiB below which debug/incremental pruning activates even under budget.
pub const DEFAULT_FREE_DISK_FLOOR_GB: f64 = 25.0;

/// Critical free-disk floor in GiB below which artifact retention tightens from 72h to 24h.
pub const DEFAULT_CRITICAL_DISK_FLOOR_GB: f64 = 20.0;

/// Normal retention window for rebuildable debug artifacts (72 hours).
pub const DEFAULT_ARTIFACT_MAX_AGE_SECS: u64 = 72 * 3600;

/// Tightened retention window under critical disk pressure or >35 GiB target bloat (24 hours).
pub const TIGHTENED_ARTIFACT_MAX_AGE_SECS: u64 = 24 * 3600;

/// Minimum age before an unleased, clean git worktree is considered orphaned (72 hours).
pub const DEFAULT_ORPHAN_WORKTREE_MAX_AGE_SECS: u64 = 72 * 3600;

const BYTES_PER_GIB: f64 = 1_073_741_824.0;

/// Summary returned by a single target-cache + orphan-worktree GC pass.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TargetGcSummary {
    pub skipped_active_build: bool,
    pub removed_files: usize,
    pub removed_dirs: usize,
    pub pruned_worktrees: usize,
    pub reclaimed_bytes: u64,
}

impl TargetGcSummary {
    pub fn total_removed(&self) -> usize {
        self.removed_files + self.removed_dirs + self.pruned_worktrees
    }
}

/// Cross-platform check for any active Rust compiler or test runner process.
pub fn any_rust_build_active() -> bool {
    const PROCS: &[&str] = &["cargo", "rustc", "cargo-nextest", "rustdoc"];

    #[cfg(unix)]
    {
        for name in PROCS {
            if let Ok(status) = Command::new("pgrep").args(["-x", name]).status() {
                if status.success() {
                    return true;
                }
            }
        }
        false
    }

    #[cfg(windows)]
    {
        for name in PROCS {
            let exe = format!("{name}.exe");
            let filter = format!("IMAGENAME eq {exe}");
            if let Ok(out) = Command::new("tasklist")
                .args(["/NH", "/FI", &filter])
                .output()
            {
                if out.status.success() {
                    let stdout = String::from_utf8_lossy(&out.stdout).to_ascii_lowercase();
                    if stdout.contains(&exe) {
                        return true;
                    }
                }
            }
        }
        false
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = PROCS;
        false
    }
}

/// Non-symlink-following recursive byte size of `root`.
pub fn dir_size_bytes(root: &Path) -> u64 {
    let Ok(meta) = fs::symlink_metadata(root) else {
        return 0;
    };
    if meta.file_type().is_symlink() {
        return 0;
    }
    if meta.is_file() {
        return meta.len();
    }
    if !meta.is_dir() {
        return 0;
    }
    let mut total = 0u64;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in rd.flatten() {
            let p = entry.path();
            let Ok(m) = fs::symlink_metadata(&p) else {
                continue;
            };
            if m.file_type().is_symlink() {
                continue;
            }
            if m.is_file() {
                total = total.saturating_add(m.len());
            } else if m.is_dir() {
                stack.push(p);
            }
        }
    }
    total
}

fn is_older_than(path: &Path, now: SystemTime, max_age: Duration) -> bool {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return false;
    };
    let Ok(modified) = meta.modified() else {
        return false;
    };
    now.duration_since(modified)
        .map(|age| age > max_age)
        .unwrap_or(false)
}

fn remove_dir_counted(path: &Path, summary: &mut TargetGcSummary) {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return;
    };
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return;
    }
    let bytes = dir_size_bytes(path);
    if fs::remove_dir_all(path).is_ok() {
        summary.removed_dirs += 1;
        summary.reclaimed_bytes = summary.reclaimed_bytes.saturating_add(bytes);
    }
}

fn remove_file_counted(path: &Path, summary: &mut TargetGcSummary) {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return;
    };
    if meta.file_type().is_symlink() || !meta.is_file() {
        return;
    }
    let bytes = meta.len();
    if fs::remove_file(path).is_ok() {
        summary.removed_files += 1;
        summary.reclaimed_bytes = summary.reclaimed_bytes.saturating_add(bytes);
    }
}

/// Run a single bounded target-cache + orphan-worktree GC pass using live host probes.
pub fn sweep_host_caches_and_worktrees(repo_root: &Path, home_dir: &Path) -> TargetGcSummary {
    let shared_target = home_dir.join(".cargo").join("chump-shared-target");
    let fleet_target = home_dir.join(".cache").join("chump-fleet-target");
    let free_gb = chump_pal::free_disk_gb(repo_root);
    sweep_target_and_worktrees_with(
        repo_root,
        &shared_target,
        &fleet_target,
        free_gb,
        SystemTime::now(),
        any_rust_build_active,
    )
}

/// Deterministic, injectable entrypoint for unit testing target-cache and worktree GC.
pub fn sweep_target_and_worktrees_with<F>(
    repo_root: &Path,
    shared_target: &Path,
    fleet_target: &Path,
    free_disk_gb: Option<f64>,
    now: SystemTime,
    build_active: F,
) -> TargetGcSummary
where
    F: Fn() -> bool,
{
    let mut summary = sweep_target_cache_with(
        shared_target,
        fleet_target,
        free_disk_gb,
        now,
        &build_active,
    );
    if !summary.skipped_active_build {
        let (pruned, wt_bytes) = sweep_orphan_worktrees(
            repo_root,
            now,
            Duration::from_secs(DEFAULT_ORPHAN_WORKTREE_MAX_AGE_SECS),
        );
        summary.pruned_worktrees += pruned;
        summary.reclaimed_bytes = summary.reclaimed_bytes.saturating_add(wt_bytes);
    }
    summary
}

/// Bounded Cargo shared-target & fleet-target sweep with live-build safety guard.
pub fn sweep_target_cache_with<F>(
    shared_target: &Path,
    fleet_target: &Path,
    free_disk_gb: Option<f64>,
    now: SystemTime,
    build_active: F,
) -> TargetGcSummary
where
    F: Fn() -> bool,
{
    let mut summary = TargetGcSummary::default();
    if !shared_target.exists() && !fleet_target.exists() {
        return summary;
    }
    if build_active() {
        summary.skipped_active_build = true;
        return summary;
    }

    let shared_bytes = dir_size_bytes(shared_target);
    let shared_gb = shared_bytes as f64 / BYTES_PER_GIB;
    let under_floor = free_disk_gb
        .map(|g| g < DEFAULT_FREE_DISK_FLOOR_GB)
        .unwrap_or(false);
    let critical_floor = free_disk_gb
        .map(|g| g < DEFAULT_CRITICAL_DISK_FLOOR_GB)
        .unwrap_or(false);
    let over_budget = shared_gb > DEFAULT_SHARED_TARGET_BUDGET_GB;

    let max_age = if critical_floor || shared_gb > 35.0 {
        Duration::from_secs(TIGHTENED_ARTIFACT_MAX_AGE_SECS)
    } else {
        Duration::from_secs(DEFAULT_ARTIFACT_MAX_AGE_SECS)
    };

    // 1. Always remove legacy nested `<shared-target>/cargo-test-target` waste.
    let nested_test_target = shared_target.join("cargo-test-target");
    if nested_test_target.is_dir() {
        remove_dir_counted(&nested_test_target, &mut summary);
    }

    // 2. Prune stale `~/.cache/chump-fleet-target/clippy-*` directories.
    if let Ok(rd) = fs::read_dir(fleet_target) {
        for entry in rd.flatten() {
            let p = entry.path();
            let Some(name) = p.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            if name.starts_with("clippy-") && is_older_than(&p, now, max_age) {
                remove_dir_counted(&p, &mut summary);
            }
        }
    }

    // 3. Prune incremental compilation caches (`debug/incremental`, `release/incremental`).
    // Under disk pressure or over budget, evict all `debug/incremental/*` subdirectories;
    // otherwise evict entries older than `max_age`.
    for (profile, evict_all_when_pressured) in [("debug", true), ("release", false)] {
        let incr_dir = shared_target.join(profile).join("incremental");
        let Ok(rd) = fs::read_dir(&incr_dir) else {
            continue;
        };
        for entry in rd.flatten() {
            let p = entry.path();
            let evict_now = (evict_all_when_pressured && (under_floor || over_budget))
                || is_older_than(&p, now, max_age);
            if evict_now {
                remove_dir_counted(&p, &mut summary);
            }
        }
    }

    // 4. Prune stale `debug/deps` hashed artifacts (`release/deps` is NEVER touched so
    // warm production `.rlib` artifacts remain immediately reusable).
    if under_floor || over_budget {
        let debug_deps = shared_target.join("debug").join("deps");
        if let Ok(rd) = fs::read_dir(&debug_deps) {
            for entry in rd.flatten() {
                let p = entry.path();
                if is_older_than(&p, now, max_age) {
                    remove_file_counted(&p, &mut summary);
                }
            }
        }
    }

    summary
}

fn collect_leased_worktrees_and_tokens(locks_dir: &Path) -> (HashSet<PathBuf>, HashSet<String>) {
    let mut paths = HashSet::new();
    let mut tokens = HashSet::new();
    let Ok(rd) = fs::read_dir(locks_dir) else {
        return (paths, tokens);
    };
    for entry in rd.flatten() {
        let p = entry.path();
        if p.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(raw) = fs::read_to_string(&p) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&raw) else {
            continue;
        };
        for key in ["worktree", "worktree_path", "cwd"] {
            if let Some(wt) = val.get(key).and_then(|v| v.as_str()) {
                let trimmed = wt.trim();
                if !trimmed.is_empty() {
                    let pb = PathBuf::from(trimmed);
                    paths.insert(pb.clone());
                    if let Ok(canon) = fs::canonicalize(&pb) {
                        paths.insert(canon);
                    }
                }
            }
        }
        for key in ["gap_id", "gap", "session_id"] {
            if let Some(tok) = val.get(key).and_then(|v| v.as_str()) {
                let lower = tok.trim().to_ascii_lowercase();
                if !lower.is_empty() {
                    tokens.insert(lower);
                }
            }
        }
    }
    (paths, tokens)
}

fn is_worktree_clean(wt_path: &Path) -> bool {
    let Ok(out) = Command::new("git")
        .arg("-C")
        .arg(wt_path)
        .args(["status", "--porcelain"])
        .output()
    else {
        return false;
    };
    out.status.success() && out.stdout.is_empty()
}

/// Prune clean, unleased git worktrees under `<repo>/.claude/worktrees` and
/// `<repo>/.chump/worktrees` older than `max_age` (`RESILIENT-307`).
pub fn sweep_orphan_worktrees(
    repo_root: &Path,
    now: SystemTime,
    max_age: Duration,
) -> (usize, u64) {
    let (leased_paths, leased_tokens) =
        collect_leased_worktrees_and_tokens(&repo_root.join(".chump-locks"));
    let mut pruned = 0usize;
    let mut reclaimed_bytes = 0u64;

    for parent_rel in [".claude/worktrees", ".chump/worktrees"] {
        let base = repo_root.join(parent_rel);
        let Ok(rd) = fs::read_dir(&base) else {
            continue;
        };
        for entry in rd.flatten() {
            let wt = entry.path();
            let Ok(meta) = fs::symlink_metadata(&wt) else {
                continue;
            };
            if meta.file_type().is_symlink() || !meta.is_dir() {
                continue;
            }
            if !is_older_than(&wt, now, max_age) {
                continue;
            }
            let git_marker = wt.join(".git");
            if git_marker.exists() && !is_older_than(&git_marker, now, max_age) {
                continue;
            }
            if leased_paths.contains(&wt) {
                continue;
            }
            if let Ok(canon) = fs::canonicalize(&wt) {
                if leased_paths.contains(&canon) {
                    continue;
                }
            }
            if let Some(dir_name) = wt.file_name().and_then(|s| s.to_str()) {
                let lower = dir_name.to_ascii_lowercase();
                if leased_tokens.iter().any(|tok| lower.contains(tok)) {
                    continue;
                }
            }
            if !is_worktree_clean(&wt) {
                continue;
            }
            let bytes = dir_size_bytes(&wt);
            let removed = Command::new("git")
                .arg("-C")
                .arg(repo_root)
                .args(["worktree", "remove"])
                .arg(&wt)
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if removed {
                pruned += 1;
                reclaimed_bytes = reclaimed_bytes.saturating_add(bytes);
            }
        }
    }

    (pruned, reclaimed_bytes)
}

/// Spawn the periodic background target-cache & orphan-worktree GC inside `chumpd`.
pub fn spawn_background_target_gc(repo_root: PathBuf, home_dir: PathBuf, interval_secs: u64) {
    let cadence = interval_secs.max(60);
    tokio::spawn(async move {
        // Brief initial delay so daemon startup and IPC bind settle first.
        tokio::time::sleep(Duration::from_secs(10)).await;
        loop {
            let repo = repo_root.clone();
            let home = home_dir.clone();
            let _ =
                tokio::task::spawn_blocking(move || sweep_host_caches_and_worktrees(&repo, &home))
                    .await;
            tokio::time::sleep(Duration::from_secs(cadence)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn skips_sweep_when_rust_build_is_active() {
        let tmp = TempDir::new().unwrap();
        let shared = tmp.path().join("chump-shared-target");
        let fleet = tmp.path().join("chump-fleet-target");
        let nested = shared.join("cargo-test-target");
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("libfoo.rlib"), vec![0u8; 4096]).unwrap();

        let summary = sweep_target_cache_with(
            &shared,
            &fleet,
            Some(10.0),
            SystemTime::now() + Duration::from_secs(10 * 86_400),
            || true,
        );
        assert!(summary.skipped_active_build);
        assert_eq!(summary.total_removed(), 0);
        assert!(
            nested.exists(),
            "active build guard must leave cargo-test-target untouched"
        );
    }

    #[test]
    fn reaps_nested_test_target_stale_clippy_and_debug_deps_while_preserving_release() {
        let tmp = TempDir::new().unwrap();
        let shared = tmp.path().join("chump-shared-target");
        let fleet = tmp.path().join("chump-fleet-target");

        // 1. Legacy nested cargo-test-target (must always be removed when idle).
        let nested = shared.join("cargo-test-target");
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("stale.rlib"), vec![1u8; 2048]).unwrap();

        // 2. Stale clippy-* dir under fleet-target.
        let clippy_dir = fleet.join("clippy-host-0");
        fs::create_dir_all(&clippy_dir).unwrap();
        fs::write(clippy_dir.join("meta.rmeta"), vec![2u8; 1024]).unwrap();

        // 3. Stale debug/deps + debug/incremental vs warm release/deps.
        let debug_deps = shared.join("debug").join("deps");
        let debug_incr = shared
            .join("debug")
            .join("incremental")
            .join("chump-abc123");
        let release_deps = shared.join("release").join("deps");
        fs::create_dir_all(&debug_deps).unwrap();
        fs::create_dir_all(&debug_incr).unwrap();
        fs::create_dir_all(&release_deps).unwrap();

        let stale_dep = debug_deps.join("chump-deadbeef");
        let warm_release = release_deps.join("libchump.rlib");
        fs::write(&stale_dep, vec![3u8; 8192]).unwrap();
        fs::write(debug_incr.join("work.bin"), vec![4u8; 1024]).unwrap();
        fs::write(&warm_release, vec![5u8; 4096]).unwrap();

        // Simulate `now` 5 days ahead under low free disk (< 25 GB floor).
        let future_now = SystemTime::now() + Duration::from_secs(5 * 86_400);
        let summary = sweep_target_cache_with(&shared, &fleet, Some(18.0), future_now, || false);

        assert!(!summary.skipped_active_build);
        assert!(!nested.exists(), "nested cargo-test-target must be reaped");
        assert!(!clippy_dir.exists(), "stale clippy-host-0 must be reaped");
        assert!(
            !debug_incr.exists(),
            "debug/incremental entry must be reaped"
        );
        assert!(
            !stale_dep.exists(),
            "stale debug/deps binary must be reaped"
        );
        assert!(
            warm_release.exists(),
            "release/deps warm cache must NEVER be evicted"
        );
        assert!(summary.reclaimed_bytes >= 2048 + 1024 + 8192 + 1024);
    }

    #[test]
    fn tightens_age_window_under_critical_disk_pressure() {
        let tmp = TempDir::new().unwrap();
        let shared = tmp.path().join("chump-shared-target");
        let fleet = tmp.path().join("chump-fleet-target");
        let debug_deps = shared.join("debug").join("deps");
        fs::create_dir_all(&debug_deps).unwrap();
        let artifact = debug_deps.join("test_bin-1234");
        fs::write(&artifact, vec![7u8; 4096]).unwrap();

        // At +36h with 22 GB free (< 25 GB floor, >= 20 GB critical), 72h window retains artifact.
        let t_36h = SystemTime::now() + Duration::from_secs(36 * 3600);
        let s1 = sweep_target_cache_with(&shared, &fleet, Some(22.0), t_36h, || false);
        assert_eq!(s1.removed_files, 0);
        assert!(artifact.exists());

        // At +36h with 15 GB free (< 20 GB critical), tightened 24h window evicts artifact.
        let s2 = sweep_target_cache_with(&shared, &fleet, Some(15.0), t_36h, || false);
        assert_eq!(s2.removed_files, 1);
        assert!(!artifact.exists());
    }

    #[test]
    fn prunes_clean_stale_orphan_worktree_and_preserves_dirty_or_leased_worktrees() {
        let tmp = TempDir::new().unwrap();
        let repo = tmp.path().join("repo");
        fs::create_dir_all(&repo).unwrap();

        assert!(Command::new("git")
            .arg("init")
            .arg("-b")
            .arg("main")
            .arg(&repo)
            .status()
            .unwrap()
            .success());
        for (k, v) in [("user.name", "GC Test"), ("user.email", "gc@chump.local")] {
            assert!(Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(["config", k, v])
                .status()
                .unwrap()
                .success());
        }
        fs::write(repo.join("README.md"), "seed\n").unwrap();
        assert!(Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(["add", "README.md"])
            .status()
            .unwrap()
            .success());
        assert!(Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(["commit", "-m", "seed"])
            .status()
            .unwrap()
            .success());

        let wt_base = repo.join(".claude").join("worktrees");
        fs::create_dir_all(&wt_base).unwrap();
        let wt_clean = wt_base.join("clean-orphan");
        let wt_dirty = wt_base.join("dirty-untracked");
        let wt_leased = wt_base.join("leased-infra-9999");

        for (wt, br) in [
            (&wt_clean, "wt/clean"),
            (&wt_dirty, "wt/dirty"),
            (&wt_leased, "wt/leased"),
        ] {
            assert!(Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(["worktree", "add", "-b", br])
                .arg(wt)
                .status()
                .unwrap()
                .success());
        }

        // Untracked file in wt_dirty must protect it from removal.
        fs::write(wt_dirty.join("untracked-notes.sh"), "#!/bin/sh\n").unwrap();

        // Active lease referencing wt_leased must protect it from removal.
        let locks = repo.join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        fs::write(
            locks.join("claim-infra-9999.json"),
            serde_json::json!({
                "gap_id": "INFRA-9999",
                "worktree": wt_leased.display().to_string(),
            })
            .to_string(),
        )
        .unwrap();

        let future_now = SystemTime::now() + Duration::from_secs(5 * 86_400);
        let (pruned, _) = sweep_orphan_worktrees(
            &repo,
            future_now,
            Duration::from_secs(DEFAULT_ORPHAN_WORKTREE_MAX_AGE_SECS),
        );

        assert_eq!(
            pruned, 1,
            "exactly the clean unleased stale worktree should be pruned"
        );
        assert!(!wt_clean.exists(), "clean orphan worktree must be removed");
        assert!(
            wt_dirty.exists(),
            "worktree with untracked file must survive"
        );
        assert!(wt_leased.exists(), "leased worktree must survive");
    }
}
