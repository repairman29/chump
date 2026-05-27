//! INFRA-2054: chump binary staleness probe (META-114 freshness cluster).
//!
//! This is the binary-staleness layer of the 7-layer freshness coverage. It
//! complements `version.rs` (gap-store-affecting commits) with a generic
//! probe that classifies the binary against two axes:
//!
//! 1. **Age** of the installed binary on disk (mtime of `current_exe()`).
//! 2. **Commits behind** `origin/main` (parsed `git rev-list HEAD..origin/main --count`).
//!
//! The threshold classification is intentionally the same scheme as
//! META-115's preamble:
//!
//!   - `Fresh`          : both axes inside threshold.
//!   - `Stale`          : at least one axis past threshold but not critical.
//!   - `CriticalStale`  : either axis past the critical multiplier.
//!
//! Defaults (matching META-115): age threshold 3600s (1h) Fresh, 14400s (4h)
//! Critical; commits threshold 5 Fresh, 50 Critical. Callers can override.
//!
//! Phase 1 surfaces this as two CLI subcommands:
//!
//!   - `chump --build-info [--json]` — print embedded BuildInfo.
//!   - `chump self-check-staleness [--threshold-age-s N] [--threshold-commits N]`
//!     — classify + exit 0 / 1 / 2 for FRESH / STALE / CRITICAL_STALE.
//!
//! Phase 1 is observation-free: no ambient emit, no EVENT_REGISTRY entry.
//! Phase 2 (separate sub-gap) wires this into `chump claim` / `chump gap ship`
//! as a hard gate and emits `kind=binary_staleness_check`.

use serde::Serialize;
use std::path::Path;
use std::process::Command;

/// Default age (seconds) above which a binary is no longer `Fresh`.
pub const DEFAULT_THRESHOLD_AGE_S: u64 = 3600; // 1h
/// Default age (seconds) above which a binary is `CriticalStale`.
pub const DEFAULT_THRESHOLD_AGE_CRITICAL_S: u64 = 14_400; // 4h
/// Default commits-behind above which a binary is no longer `Fresh`.
pub const DEFAULT_THRESHOLD_COMMITS: u64 = 5;
/// Default commits-behind above which a binary is `CriticalStale`.
pub const DEFAULT_THRESHOLD_COMMITS_CRITICAL: u64 = 50;

/// Build-time metadata baked into the binary via `cargo:rustc-env` in `build.rs`.
///
/// The four fields are read at compile time via `env!()` and stored as
/// `&'static str`. Returned by-value (owned `String`) from `build_info()` so
/// callers can serialize without lifetime gymnastics.
#[derive(Debug, Clone, Serialize)]
pub struct BuildInfo {
    /// Full git SHA of HEAD when `cargo build` ran. `"unknown-no-git-context"`
    /// outside a git checkout (cargo install --git URL, packaged source).
    pub sha: String,
    /// UTC build timestamp in ISO-8601 (`YYYY-MM-DDTHH:MM:SSZ`).
    pub timestamp: String,
    /// Output of `rustc --version` at build time (e.g. `"rustc 1.78.0 (...)"`).
    pub rustc: String,
    /// Absolute path to the workspace root at build time (CARGO_MANIFEST_DIR).
    pub workspace_root: String,
}

/// Classification used by [`check_staleness`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StalenessClass {
    /// Both age and commits-behind are inside the soft threshold.
    Fresh,
    /// At least one axis past the soft threshold but not critical.
    Stale,
    /// At least one axis past the critical threshold. High-risk operations
    /// should refuse without explicit override.
    CriticalStale,
}

impl StalenessClass {
    /// CLI exit code mapping: 0 / 1 / 2 for Fresh / Stale / CriticalStale.
    pub fn exit_code(&self) -> i32 {
        match self {
            StalenessClass::Fresh => 0,
            StalenessClass::Stale => 1,
            StalenessClass::CriticalStale => 2,
        }
    }
}

/// Structured report returned alongside the classification.
#[derive(Debug, Clone, Serialize)]
pub struct StalenessReport {
    /// Seconds since the binary file was last modified on disk. `None` if
    /// `current_exe()` mtime is unreadable.
    pub build_age_s: Option<u64>,
    /// Commits ahead on `origin/main` vs local `HEAD`. `None` outside a git
    /// context or when `git rev-list` failed.
    pub commits_behind: Option<u64>,
    /// SHA the binary was built from (from `BuildInfo`).
    pub build_sha: String,
    /// SHA of local repo HEAD at probe time. `None` outside a git context.
    pub local_head_sha: Option<String>,
    /// Final classification.
    pub classification: StalenessClass,
    /// Thresholds in effect for this probe (so JSON consumers can verify).
    pub threshold_age_s: u64,
    pub threshold_age_critical_s: u64,
    pub threshold_commits: u64,
    pub threshold_commits_critical: u64,
    /// Why the probe arrived at its classification (for human-readable
    /// stderr; not enumerated for machine consumers).
    pub reason: String,
}

/// Errors that can prevent the probe from running. Each variant is
/// fail-soft — the CLI maps these to `Stale` with a reason rather than
/// propagating, but library callers may inspect.
#[derive(Debug)]
pub enum StalenessError {
    /// `current_exe()` itself failed (very rare; sandbox / chrooted env).
    CurrentExeUnavailable(String),
}

impl std::fmt::Display for StalenessError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StalenessError::CurrentExeUnavailable(msg) => {
                write!(f, "current_exe unavailable: {msg}")
            }
        }
    }
}

impl std::error::Error for StalenessError {}

/// Returns the build-time metadata baked into this binary.
pub fn build_info() -> BuildInfo {
    BuildInfo {
        sha: env!("CHUMP_BUILD_GIT_SHA").to_string(),
        timestamp: env!("CHUMP_BUILD_TIMESTAMP").to_string(),
        rustc: env!("CHUMP_BUILD_RUSTC").to_string(),
        workspace_root: env!("CHUMP_BUILD_WORKSPACE_ROOT").to_string(),
    }
}

/// Compute the binary's age in seconds since last-modified.
fn current_binary_age_s() -> Option<u64> {
    let exe = std::env::current_exe().ok()?;
    let meta = std::fs::metadata(&exe).ok()?;
    let mtime = meta.modified().ok()?;
    let elapsed = mtime.elapsed().ok()?;
    Some(elapsed.as_secs())
}

/// Run `git rev-list HEAD..origin/main --count` in the given dir. Returns
/// `None` outside a git context or on any subprocess failure.
fn commits_behind_origin_main(repo_root: &Path) -> Option<u64> {
    if !repo_root.join(".git").exists() {
        return None;
    }
    let output = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["rev-list", "HEAD..origin/main", "--count"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout.trim().parse::<u64>().ok()
}

/// Get the local HEAD SHA. `None` outside a git context.
fn local_head_sha(repo_root: &Path) -> Option<String> {
    if !repo_root.join(".git").exists() {
        return None;
    }
    let output = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["rev-parse", "HEAD"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Locate a repo root by walking up from `start` looking for `.git`.
/// Same algorithm as `version::find_repo_root` but lives here so this
/// module is self-contained.
fn find_repo_root(start: &Path) -> Option<std::path::PathBuf> {
    let mut cur = start.canonicalize().ok()?;
    loop {
        if cur.join(".git").exists() {
            return Some(cur);
        }
        if !cur.pop() {
            return None;
        }
    }
}

/// Classify staleness against two axes and the supplied thresholds. The
/// function never returns an error in normal operation — outside-git or
/// missing-mtime conditions are absorbed into the report as `None` and a
/// human-readable `reason`.
///
/// Note: the SOFT threshold flips `Fresh -> Stale`; the CRITICAL multiplier
/// (4x for age, 10x for commits) flips `Stale -> CriticalStale`. Callers
/// who want symmetric custom thresholds should use
/// [`check_staleness_with_critical`] instead.
pub fn check_staleness(
    threshold_age_s: u64,
    threshold_commits: u64,
) -> Result<(StalenessClass, StalenessReport), StalenessError> {
    // Derived critical multipliers — 4x for age, 10x for commits. Matches
    // META-115 preamble scheme (3600s Fresh / 14400s Critical = 4x).
    let critical_age = threshold_age_s.saturating_mul(4);
    let critical_commits = threshold_commits.saturating_mul(10);
    check_staleness_with_critical(
        threshold_age_s,
        critical_age,
        threshold_commits,
        critical_commits,
    )
}

/// Same as [`check_staleness`] but with explicit critical thresholds.
pub fn check_staleness_with_critical(
    threshold_age_s: u64,
    threshold_age_critical_s: u64,
    threshold_commits: u64,
    threshold_commits_critical: u64,
) -> Result<(StalenessClass, StalenessReport), StalenessError> {
    let bi = build_info();

    // Age axis.
    let build_age_s = current_binary_age_s();

    // Commits axis. Locate the repo by walking up from the workspace_root
    // baked into the binary; fall back to CWD if that's unavailable.
    let repo_root = find_repo_root(Path::new(&bi.workspace_root)).or_else(|| {
        std::env::current_dir()
            .ok()
            .and_then(|d| find_repo_root(&d))
    });

    let (commits_behind, local_sha) = match repo_root.as_deref() {
        Some(root) => (commits_behind_origin_main(root), local_head_sha(root)),
        None => (None, None),
    };

    // Classify.
    let mut classification = StalenessClass::Fresh;
    let mut reasons: Vec<String> = Vec::new();

    if let Some(age) = build_age_s {
        if age >= threshold_age_critical_s {
            classification = StalenessClass::CriticalStale;
            reasons.push(format!(
                "binary age {}s >= critical threshold {}s",
                age, threshold_age_critical_s
            ));
        } else if age >= threshold_age_s {
            if classification == StalenessClass::Fresh {
                classification = StalenessClass::Stale;
            }
            reasons.push(format!(
                "binary age {}s >= soft threshold {}s",
                age, threshold_age_s
            ));
        }
    } else {
        reasons.push("binary age unreadable (current_exe mtime unavailable)".to_string());
        if classification == StalenessClass::Fresh {
            classification = StalenessClass::Stale;
        }
    }

    if let Some(commits) = commits_behind {
        if commits >= threshold_commits_critical {
            classification = StalenessClass::CriticalStale;
            reasons.push(format!(
                "commits-behind {} >= critical threshold {}",
                commits, threshold_commits_critical
            ));
        } else if commits >= threshold_commits {
            if classification == StalenessClass::Fresh {
                classification = StalenessClass::Stale;
            }
            reasons.push(format!(
                "commits-behind {} >= soft threshold {}",
                commits, threshold_commits
            ));
        }
    } else {
        reasons.push("commits-behind unknown (outside git context or rev-list failed)".to_string());
        // Outside-git is not by itself stale — only flip if no other signal
        // already moved us off Fresh. (Caller can opt into stricter behavior
        // by lowering thresholds.)
    }

    let reason = if reasons.is_empty() {
        "fresh: both axes inside threshold".to_string()
    } else {
        reasons.join("; ")
    };

    let report = StalenessReport {
        build_age_s,
        commits_behind,
        build_sha: bi.sha.clone(),
        local_head_sha: local_sha,
        classification,
        threshold_age_s,
        threshold_age_critical_s,
        threshold_commits,
        threshold_commits_critical,
        reason,
    };

    Ok((classification, report))
}

/// CLI handler for `chump --build-info [--json]`.
/// Returns the exit code.
pub fn run_build_info_cli(json: bool) -> i32 {
    let bi = build_info();
    if json {
        match serde_json::to_string_pretty(&bi) {
            Ok(s) => {
                println!("{}", s);
                0
            }
            Err(e) => {
                eprintln!("error serializing build_info to JSON: {e}");
                1
            }
        }
    } else {
        println!("chump build info");
        println!("  sha:            {}", bi.sha);
        println!("  timestamp:      {}", bi.timestamp);
        println!("  rustc:          {}", bi.rustc);
        println!("  workspace_root: {}", bi.workspace_root);
        0
    }
}

/// CLI handler for `chump self-check-staleness [--threshold-age-s N]
/// [--threshold-commits N] [--json]`.
/// Returns the exit code per `StalenessClass::exit_code()`.
pub fn run_self_check_staleness_cli(
    threshold_age_s: u64,
    threshold_commits: u64,
    json: bool,
) -> i32 {
    match check_staleness(threshold_age_s, threshold_commits) {
        Ok((class, report)) => {
            if json {
                match serde_json::to_string_pretty(&report) {
                    Ok(s) => println!("{}", s),
                    Err(e) => {
                        eprintln!("error serializing staleness report to JSON: {e}");
                        return 1;
                    }
                }
            } else {
                let label = match class {
                    StalenessClass::Fresh => "FRESH",
                    StalenessClass::Stale => "STALE",
                    StalenessClass::CriticalStale => "CRITICAL_STALE",
                };
                println!("staleness: {label}");
                println!("  build_sha:        {}", report.build_sha);
                match report.local_head_sha {
                    Some(ref s) => println!("  local_head_sha:   {}", s),
                    None => println!("  local_head_sha:   (unknown)"),
                }
                match report.build_age_s {
                    Some(s) => println!("  build_age_s:      {}", s),
                    None => println!("  build_age_s:      (unknown)"),
                }
                match report.commits_behind {
                    Some(n) => println!("  commits_behind:   {}", n),
                    None => println!("  commits_behind:   (unknown)"),
                }
                println!(
                    "  threshold_age:    {}s soft / {}s critical",
                    report.threshold_age_s, report.threshold_age_critical_s
                );
                println!(
                    "  threshold_commits:{} soft / {} critical",
                    report.threshold_commits, report.threshold_commits_critical
                );
                println!("  reason:           {}", report.reason);
            }
            class.exit_code()
        }
        Err(e) => {
            eprintln!("staleness probe failed: {e}");
            // Unreadable probe is treated as Stale (exit 1) by convention.
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_info_fields_are_populated() {
        let bi = build_info();
        // SHA is either a hex string or the sentinel.
        assert!(!bi.sha.is_empty(), "build sha should be non-empty");
        assert!(!bi.timestamp.is_empty(), "timestamp should be non-empty");
        assert!(!bi.rustc.is_empty(), "rustc should be non-empty");
        assert!(
            !bi.workspace_root.is_empty(),
            "workspace_root should be non-empty"
        );
    }

    #[test]
    fn staleness_class_exit_codes_match_contract() {
        assert_eq!(StalenessClass::Fresh.exit_code(), 0);
        assert_eq!(StalenessClass::Stale.exit_code(), 1);
        assert_eq!(StalenessClass::CriticalStale.exit_code(), 2);
    }

    #[test]
    fn huge_thresholds_force_fresh() {
        // With absurdly-permissive thresholds we should always classify Fresh
        // regardless of binary age + git state.
        let (class, _) = check_staleness(u64::MAX, u64::MAX).unwrap();
        assert_eq!(class, StalenessClass::Fresh);
    }

    #[test]
    fn zero_thresholds_force_non_fresh() {
        // With threshold_age_s=0, any nonzero binary age tips us off Fresh.
        // Test binaries from cargo test have age=0..few seconds, but with
        // strict-zero threshold even age=0 trips: `>=0` is true.
        let (class, _) = check_staleness(0, 0).unwrap();
        assert_ne!(
            class,
            StalenessClass::Fresh,
            "strict-zero thresholds should not produce Fresh"
        );
    }

    #[test]
    fn report_includes_thresholds_in_use() {
        let (_class, report) = check_staleness(42, 7).unwrap();
        assert_eq!(report.threshold_age_s, 42);
        assert_eq!(report.threshold_commits, 7);
        // Critical defaults to 4x age, 10x commits.
        assert_eq!(report.threshold_age_critical_s, 168);
        assert_eq!(report.threshold_commits_critical, 70);
    }

    #[test]
    fn custom_critical_thresholds_honored() {
        let (_class, report) = check_staleness_with_critical(100, 200, 5, 50).unwrap();
        assert_eq!(report.threshold_age_critical_s, 200);
        assert_eq!(report.threshold_commits_critical, 50);
    }
}
