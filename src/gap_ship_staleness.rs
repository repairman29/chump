//! INFRA-1007: belt-and-suspenders for the manual `chump gap ship` path.
//!
//! `bot-merge.sh` already has the INFRA-995 "branch too stale to push" gate
//! (refuses to push when HEAD..origin/main > 15 commits — main moved during
//! build/test and a push would queue a stale base for CI). Operators who run
//! `chump gap ship` directly bypass bot-merge.sh entirely, so the only
//! defense was hoping they fetched recently. This module mirrors that gate
//! inside the Rust ship path so the protection is uniform.

use anyhow::{bail, Result};
use std::path::Path;
use std::process::Command;

/// Default threshold — matches `CHUMP_BOT_MERGE_STALE_THRESHOLD` in
/// scripts/coord/bot-merge.sh.
const DEFAULT_THRESHOLD: u64 = 15;

/// Resolve the effective threshold from env, falling back to the default.
pub fn threshold_from_env() -> u64 {
    std::env::var("CHUMP_GAP_SHIP_STALE_THRESHOLD")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_THRESHOLD)
}

/// Run the staleness check. Best-effort: silently succeeds when not in a
/// git repo or when the remote is unreachable — same posture as bot-merge.sh
/// which uses `|| true` on the fetch and `|| echo 0` on the rev-list.
///
/// Refuses (returns Err) only when `HEAD..origin/main` is definitively
/// greater than the threshold.
pub fn enforce_for_gap_ship(repo_root: &Path) -> Result<()> {
    if std::env::var("CHUMP_GAP_SHIP_STALE_CHECK")
        .map(|v| v == "0")
        .unwrap_or(false)
    {
        return Ok(());
    }
    let remote = std::env::var("CHUMP_REMOTE").unwrap_or_else(|_| "origin".into());
    let base_branch = std::env::var("CHUMP_BASE_BRANCH").unwrap_or_else(|_| "main".into());
    let threshold = threshold_from_env();

    // Best-effort fetch — quiet, ignore failures (offline, etc.).
    let _ = Command::new("git")
        .args(["fetch", &remote, &base_branch, "--quiet"])
        .current_dir(repo_root)
        .output();

    let behind = count_behind(repo_root, &remote, &base_branch).unwrap_or(0);
    let branch = current_branch(repo_root).unwrap_or_else(|| "(detached)".to_string());

    enforce_behind(repo_root, &branch, behind, threshold)
}

/// Pure-logic core of the enforcement — exposed for unit tests so they
/// don't need a git repo to verify the threshold + ambient-event behavior.
pub fn enforce_behind(repo_root: &Path, branch: &str, behind: u64, threshold: u64) -> Result<()> {
    if behind <= threshold {
        return Ok(());
    }
    emit_stale_blocked(repo_root, branch, behind, threshold);
    eprintln!(
        "INFRA-1007: branch {branch} is {behind} commits behind origin/main \
         (threshold {threshold}). main moved during the local cycle; shipping now \
         would queue a stale base. Recover: git fetch && git rebase origin/main && retry."
    );
    bail!(
        "refused: branch {behind} commits behind origin/main > threshold {threshold}. \
         Run `git fetch && git rebase origin/main` first, or override with \
         CHUMP_GAP_SHIP_STALE_THRESHOLD=<larger N> / CHUMP_GAP_SHIP_STALE_CHECK=0."
    )
}

fn count_behind(repo_root: &Path, remote: &str, base_branch: &str) -> Option<u64> {
    let out = Command::new("git")
        .args([
            "rev-list",
            "--count",
            &format!("HEAD..{remote}/{base_branch}"),
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    s.trim().parse::<u64>().ok()
}

fn current_branch(repo_root: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Emit the same `stale_branch_blocked` event shape as bot-merge.sh, with
/// `phase=gap-ship` so consumers (fleet-brief, waste-tally) can tell the
/// two sources apart without losing the count.
fn emit_stale_blocked(repo_root: &Path, branch: &str, behind: u64, threshold: u64) {
    let ambient = std::env::var("CHUMP_AMBIENT_IN_PROMPT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            let lock_dir = repo_root.join(".chump-locks");
            let _ = std::fs::create_dir_all(&lock_dir);
            lock_dir.join("ambient.jsonl")
        });
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"stale_branch_blocked\",\"branch\":\"{branch}\",\"behind\":{behind},\"threshold\":{threshold},\"phase\":\"gap-ship\"}}\n",
        ts = json_escape(&ts),
        branch = json_escape(branch),
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enforce_passes_at_or_below_threshold() {
        let tmp = tempfile::tempdir().unwrap();
        // AC #3: BEHIND=5 must pass (under default 15 threshold).
        assert!(enforce_behind(tmp.path(), "chump/test", 5, 15).is_ok());
        assert!(enforce_behind(tmp.path(), "chump/test", 0, 15).is_ok());
        assert!(enforce_behind(tmp.path(), "chump/test", 14, 15).is_ok());
        assert!(enforce_behind(tmp.path(), "chump/test", 15, 15).is_ok());
    }

    #[test]
    fn enforce_refuses_above_threshold() {
        let tmp = tempfile::tempdir().unwrap();
        // AC #3: BEHIND=20 must refuse with default 15 threshold.
        let res = enforce_behind(tmp.path(), "chump/test", 20, 15);
        assert!(res.is_err(), "expected refusal at behind=20, threshold=15");
        let err = res.unwrap_err().to_string();
        assert!(err.contains("20"), "error must mention behind count");
        assert!(err.contains("15"), "error must mention threshold");
        // And a tight just-over-the-line case for boundary clarity.
        assert!(enforce_behind(tmp.path(), "chump/test", 16, 15).is_err());
    }

    #[test]
    fn enforce_emits_ambient_event_with_gap_ship_phase() {
        let tmp = tempfile::tempdir().unwrap();
        let amb_path = tmp.path().join("custom-ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_IN_PROMPT", &amb_path);

        let _ = enforce_behind(tmp.path(), "chump/test-branch", 20, 15);

        let body = std::fs::read_to_string(&amb_path).expect("ambient must exist after refusal");
        assert!(
            body.contains("\"kind\":\"stale_branch_blocked\""),
            "missing kind: {body}"
        );
        assert!(
            body.contains("\"phase\":\"gap-ship\""),
            "missing phase: {body}"
        );
        assert!(body.contains("\"behind\":20"), "missing behind: {body}");
        assert!(
            body.contains("\"threshold\":15"),
            "missing threshold: {body}"
        );
        assert!(body.contains("\"branch\":\"chump/test-branch\""));
        for line in body.lines() {
            let _: serde_json::Value =
                serde_json::from_str(line).unwrap_or_else(|e| panic!("bad json '{line}': {e}"));
        }
        std::env::remove_var("CHUMP_AMBIENT_IN_PROMPT");
    }

    #[test]
    fn no_ambient_event_when_under_threshold() {
        let tmp = tempfile::tempdir().unwrap();
        let amb_path = tmp.path().join("custom-ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_IN_PROMPT", &amb_path);

        let _ = enforce_behind(tmp.path(), "chump/test", 5, 15);

        assert!(
            !amb_path.exists(),
            "no event must be emitted when within threshold"
        );
        std::env::remove_var("CHUMP_AMBIENT_IN_PROMPT");
    }

    /// One combined test for the env-driven threshold paths — cargo runs
    /// tests in parallel and env vars are process-global, so splitting these
    /// into two tests races on `CHUMP_GAP_SHIP_STALE_THRESHOLD`.
    #[test]
    fn threshold_from_env_overrides_and_validates() {
        // Save + clear any inherited value.
        let saved = std::env::var("CHUMP_GAP_SHIP_STALE_THRESHOLD").ok();
        std::env::remove_var("CHUMP_GAP_SHIP_STALE_THRESHOLD");
        assert_eq!(threshold_from_env(), DEFAULT_THRESHOLD);

        std::env::set_var("CHUMP_GAP_SHIP_STALE_THRESHOLD", "42");
        assert_eq!(threshold_from_env(), 42);

        std::env::set_var("CHUMP_GAP_SHIP_STALE_THRESHOLD", "not-a-number");
        assert_eq!(threshold_from_env(), DEFAULT_THRESHOLD);

        std::env::remove_var("CHUMP_GAP_SHIP_STALE_THRESHOLD");
        assert_eq!(threshold_from_env(), DEFAULT_THRESHOLD);

        if let Some(v) = saved {
            std::env::set_var("CHUMP_GAP_SHIP_STALE_THRESHOLD", v);
        }
    }

    /// Integration-style: synthesize a tiny git repo + a "remote" with N
    /// extra commits, run the real enforce_for_gap_ship, assert it refuses
    /// when N > threshold and passes when N <= threshold. Ignored by default
    /// because the synthetic git setup is sensitive to the host's GPG / hook
    /// configuration; the pure-logic `enforce_behind` tests above cover the
    /// AC #3 cases without external dependencies. Run on-demand with:
    ///   cargo test --bin chump gap_ship_staleness -- --ignored
    #[test]
    #[ignore]
    fn integration_refuses_when_behind_20_passes_when_behind_5() {
        let tmp = tempfile::tempdir().unwrap();
        let remote_dir = tmp.path().join("remote.git");
        let local_dir = tmp.path().join("local");

        let git = |args: &[&str], cwd: &Path| -> std::process::Output {
            Command::new("git")
                .args(args)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_SYSTEM", "/dev/null")
                .env("HOME", tmp.path())
                .current_dir(cwd)
                .output()
                .expect("git spawn")
        };

        std::fs::create_dir_all(&remote_dir).unwrap();
        std::fs::create_dir_all(&local_dir).unwrap();
        assert!(git(&["init", "--bare", "-b", "main"], &remote_dir)
            .status
            .success());
        assert!(git(&["init", "-b", "main"], &local_dir).status.success());
        assert!(
            git(&["config", "user.email", "t@example.invalid"], &local_dir)
                .status
                .success()
        );
        assert!(git(&["config", "user.name", "Test"], &local_dir)
            .status
            .success());
        assert!(git(&["config", "commit.gpgsign", "false"], &local_dir)
            .status
            .success());
        assert!(git(
            &["remote", "add", "origin", remote_dir.to_str().unwrap()],
            &local_dir
        )
        .status
        .success());

        // Base commit on local + push to remote.
        std::fs::write(local_dir.join("base.txt"), "0").unwrap();
        assert!(git(&["add", "base.txt"], &local_dir).status.success());
        assert!(git(&["commit", "-m", "base"], &local_dir).status.success());
        assert!(git(&["push", "origin", "main"], &local_dir)
            .status
            .success());

        // Build a divergent state: local fork on a new branch ('feat'),
        // and meanwhile 'main' on the remote gets N extra commits.
        assert!(git(&["checkout", "-b", "feat"], &local_dir)
            .status
            .success());
        std::fs::write(local_dir.join("feat.txt"), "f").unwrap();
        assert!(git(&["add", "feat.txt"], &local_dir).status.success());
        assert!(git(&["commit", "-m", "feat commit"], &local_dir)
            .status
            .success());

        // Helper: append N commits to remote's main via a scratch checkout.
        let add_remote_commits = |n: u32| {
            let scratch = tmp.path().join(format!("scratch-{n}"));
            std::fs::create_dir_all(&scratch).unwrap();
            assert!(git(&["clone", remote_dir.to_str().unwrap(), "."], &scratch)
                .status
                .success());
            assert!(
                git(&["config", "user.email", "t@example.invalid"], &scratch)
                    .status
                    .success()
            );
            assert!(git(&["config", "user.name", "Test"], &scratch)
                .status
                .success());
            assert!(git(&["config", "commit.gpgsign", "false"], &scratch)
                .status
                .success());
            for i in 0..n {
                let f = format!("r{i}.txt");
                std::fs::write(scratch.join(&f), i.to_string()).unwrap();
                assert!(git(&["add", &f], &scratch).status.success());
                assert!(git(&["commit", "-m", &format!("r{i}")], &scratch)
                    .status
                    .success());
            }
            assert!(git(&["push", "origin", "main"], &scratch).status.success());
        };

        // Case A: 5 commits behind, threshold 15 (default) → passes.
        add_remote_commits(5);
        std::env::set_var("CHUMP_GAP_SHIP_STALE_THRESHOLD", "15");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("amb-a.jsonl").as_os_str(),
        );
        assert!(
            enforce_for_gap_ship(&local_dir).is_ok(),
            "behind=5 should pass with threshold=15"
        );

        // Case B: total 20 commits behind, threshold 15 → refuses.
        add_remote_commits(15);
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("amb-b.jsonl").as_os_str(),
        );
        let res_b = enforce_for_gap_ship(&local_dir);
        assert!(
            res_b.is_err(),
            "behind=20 should refuse with threshold=15: {res_b:?}"
        );

        let amb_b = std::fs::read_to_string(tmp.path().join("amb-b.jsonl")).unwrap();
        assert!(amb_b.contains("\"phase\":\"gap-ship\""));
        assert!(amb_b.contains("\"behind\":20"));

        std::env::remove_var("CHUMP_GAP_SHIP_STALE_THRESHOLD");
        std::env::remove_var("CHUMP_AMBIENT_IN_PROMPT");
    }
}
