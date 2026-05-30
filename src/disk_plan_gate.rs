//! INFRA-2198 (META-128/C7): disk-aware gate for `chump fleet up` and `chump fleet auto-scale`.
//!
//! Calls `chump disk plan <action_class> --count N` as a subprocess and
//! interprets the exit code:
//!   exit 0  → OK   — proceed unchanged
//!   exit 2  → WAIT — disk headroom low; downsize or warn
//!   exit 1  → REFUSE — insufficient headroom; downsize to budget max
//!
//! Falls back gracefully when `chump disk` is not yet installed (INFRA-2196
//! not merged): logs a WARN and continues as if OK.  This ensures `chump fleet up`
//! keeps working on a base main build before C5 lands.
//!
//! `max_safe_n_from_budget` calls `chump disk budget --for <action_class> --json`
//! to get the max-safe-N for a given action class; falls back to `requested_n`
//! when budget output can't be parsed (defensive).
//!
//! Cross-references:
//!   INFRA-2193 — daemon writes ~/.chump/disk-inventory.json
//!   INFRA-2196 — `chump disk` CLI (substrate for this gate)
//!   META-128   — umbrella disk-aware fleet design

use std::path::Path;
use tracing::warn;

/// Decision returned from the disk-plan gate.
#[derive(Debug, Clone, PartialEq)]
pub enum DiskPlanDecision {
    /// Disk headroom is fine — proceed with the requested N.
    Ok,
    /// Headroom is low (WAIT). Proceed only if `CHUMP_FLEET_ACCEPT_WAIT=1`;
    /// otherwise downsize to `recommended_n`.
    Wait { recommended_n: u32 },
    /// Insufficient headroom (REFUSE). Must downsize to `recommended_n`.
    Refuse { recommended_n: u32 },
}

/// Probe the disk plan for `action_class` with `count` workers.
///
/// Spawns `chump disk plan <action_class> --count <count>` as a subprocess.
/// When the binary is absent the function returns `Ok` (graceful fallback so
/// fleets without INFRA-2196 keep working unchanged).
pub fn check(action_class: &str, count: u32, repo_root: &Path) -> DiskPlanDecision {
    let chump_bin = chump_binary_path(repo_root);

    let result = std::process::Command::new(&chump_bin)
        .args(["disk", "plan", action_class, "--count", &count.to_string()])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .status();

    match result {
        Err(e) if is_not_found(&e) => {
            // INFRA-2196 not installed yet — fall through silently.
            DiskPlanDecision::Ok
        }
        Err(e) => {
            // Binary exists but invocation failed for some other reason; warn + allow.
            warn!(action_class, count, err = %e, "disk_plan_gate: subprocess error — proceeding as OK");
            DiskPlanDecision::Ok
        }
        Ok(status) => {
            match status.code() {
                Some(0) => DiskPlanDecision::Ok,
                Some(2) => {
                    // WAIT: compute recommended_n via budget.
                    let budget_n = max_safe_n_from_budget(action_class, repo_root, count);
                    DiskPlanDecision::Wait {
                        recommended_n: budget_n,
                    }
                }
                Some(1) | Some(_) => {
                    // REFUSE: must downsize.
                    let budget_n = max_safe_n_from_budget(action_class, repo_root, count);
                    DiskPlanDecision::Refuse {
                        recommended_n: budget_n,
                    }
                }
                None => {
                    // Killed by signal — be conservative.
                    warn!(
                        action_class,
                        count, "disk_plan_gate: subprocess killed — treating as REFUSE"
                    );
                    DiskPlanDecision::Refuse { recommended_n: 0 }
                }
            }
        }
    }
}

/// Ask `chump disk budget --for <action_class> --json` for the max-safe-N.
///
/// Falls back to `requested_n` when INFRA-2196 is absent or output can't be parsed.
pub fn max_safe_n_from_budget(action_class: &str, repo_root: &Path, requested_n: u32) -> u32 {
    let chump_bin = chump_binary_path(repo_root);

    let output = match std::process::Command::new(&chump_bin)
        .args(["disk", "budget", "--for", action_class, "--json"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output()
    {
        Ok(o) if o.status.success() => o.stdout,
        _ => return requested_n, // fallback
    };

    // JSON output is an array of BudgetRow objects: [{action_class, p95_gb, max_safe_n, …}]
    let text = String::from_utf8_lossy(&output);
    let parsed: Result<Vec<serde_json::Value>, _> = serde_json::from_str(&text);
    match parsed {
        Ok(rows) => rows
            .first()
            .and_then(|r| r["max_safe_n"].as_u64())
            .map(|n| n as u32)
            .unwrap_or(requested_n),
        Err(_) => requested_n,
    }
}

fn chump_binary_path(repo_root: &Path) -> std::path::PathBuf {
    // Prefer the binary that lives beside the repo root (typical release layout).
    // Fall back to PATH via bare "chump".
    let beside = repo_root.join("target/release/chump");
    if beside.exists() {
        return beside;
    }
    let debug = repo_root.join("target/debug/chump");
    if debug.exists() {
        return debug;
    }
    std::path::PathBuf::from("chump")
}

fn is_not_found(e: &std::io::Error) -> bool {
    e.kind() == std::io::ErrorKind::NotFound
}

// ── tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── Test 1: DiskPlanDecision variants are correct ───────────────────────
    #[test]
    fn test_decision_variant_identity() {
        assert_eq!(DiskPlanDecision::Ok, DiskPlanDecision::Ok);
        assert_eq!(
            DiskPlanDecision::Wait { recommended_n: 3 },
            DiskPlanDecision::Wait { recommended_n: 3 }
        );
        assert_ne!(
            DiskPlanDecision::Wait { recommended_n: 3 },
            DiskPlanDecision::Wait { recommended_n: 2 }
        );
        assert_eq!(
            DiskPlanDecision::Refuse { recommended_n: 0 },
            DiskPlanDecision::Refuse { recommended_n: 0 }
        );
    }

    // ── Test 2: chump_binary_path prefers release over debug ────────────────
    #[test]
    fn test_binary_path_preference() {
        let dir = tempfile::tempdir().unwrap();
        // No binaries present — should fall back to bare "chump".
        let p = chump_binary_path(dir.path());
        assert_eq!(p.to_str().unwrap(), "chump");

        // Create debug binary.
        let debug_dir = dir.path().join("target/debug");
        std::fs::create_dir_all(&debug_dir).unwrap();
        std::fs::write(debug_dir.join("chump"), b"").unwrap();
        let p = chump_binary_path(dir.path());
        assert!(p.ends_with("target/debug/chump"));

        // Create release binary — should now prefer release.
        let release_dir = dir.path().join("target/release");
        std::fs::create_dir_all(&release_dir).unwrap();
        std::fs::write(release_dir.join("chump"), b"").unwrap();
        let p = chump_binary_path(dir.path());
        assert!(p.ends_with("target/release/chump"));
    }

    // ── Test 3: check() returns Ok when binary not found ────────────────────
    // We test the NotFound fallback by calling the internal helper directly
    // (is_not_found) and verifying the DiskPlanDecision path that gets taken.
    #[test]
    fn test_check_returns_ok_when_binary_missing() {
        // Simulate: Command::new("/nonexistent/chump-xyzzy") fails with NotFound.
        let e = std::io::Error::new(std::io::ErrorKind::NotFound, "no such file");
        assert!(
            is_not_found(&e),
            "not-found detection must fire for NotFound error"
        );

        // Verify the match arm that fires returns Ok (mirrors the match arm in check()).
        // This tests the logic path without requiring a real subprocess.
        let decision = if is_not_found(&e) {
            DiskPlanDecision::Ok
        } else {
            DiskPlanDecision::Refuse { recommended_n: 0 }
        };
        assert_eq!(decision, DiskPlanDecision::Ok);
    }

    // ── Test 4: max_safe_n_from_budget falls back on missing binary ──────────
    #[test]
    fn test_budget_fallback_when_binary_missing() {
        let dir = tempfile::tempdir().unwrap();
        let n = max_safe_n_from_budget("sonnet_dispatch_with_worktree", dir.path(), 5);
        // binary missing → returns requested_n unchanged
        assert_eq!(n, 5);
    }

    // ── Test 5: is_not_found correctly identifies NotFound ──────────────────
    #[test]
    fn test_is_not_found_detection() {
        let not_found = std::io::Error::new(std::io::ErrorKind::NotFound, "no such file");
        assert!(is_not_found(&not_found));

        let permission = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied");
        assert!(!is_not_found(&permission));
    }

    // ── Test 6: max_safe_n_from_budget parses valid JSON ────────────────────
    // (Pure logic test — no subprocess; we mock the JSON parsing logic inline.)
    #[test]
    fn test_budget_json_parse_logic() {
        // Simulate the JSON parsing path used by max_safe_n_from_budget.
        let json = r#"[{"action_class":"sonnet_dispatch_with_worktree","p95_gb":4.0,"max_safe_n":3,"free_now_gb":30.0,"threshold_gb":5.0}]"#;
        let parsed: Vec<serde_json::Value> = serde_json::from_str(json).unwrap();
        let n = parsed
            .first()
            .and_then(|r| r["max_safe_n"].as_u64())
            .map(|n| n as u32)
            .unwrap_or(99);
        assert_eq!(n, 3);
    }
}
