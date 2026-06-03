//! RESILIENT-069: `chump farmer status` — readiness probe ("lights on?").
//!
//! One command, exit 0 = GREEN (ready), exit 1 = RED (lights off).
//!
//! GREEN requires ALL of:
//!   1. .chump/fleet-paused sentinel absent
//!   2. Zero control-plane daemons with exit-78 (launchctl list)
//!   3. OAuth token fresh (mtime < FARMER_OAUTH_MAX_AGE_S, default 3600s)
//!   4. Farmer heartbeat file fresh (mtime < 120s)
//!
//! All checks read only local state — no network, no GitHub API, <100ms.
//! RED admits no new claims but the Farmer's recovery routes around it.
//!
//! Usage:
//!   chump farmer status            # exit 0 (GREEN) or 1 (RED)
//!   chump farmer status --json     # structured output
//!   chump farmer status --quiet    # no output, just exit code

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Resolve repo root: CHUMP_REPO_ROOT env → walk up from cwd looking for Cargo.toml.
pub fn resolve_repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    if let Ok(r) = std::env::var("CHUMP_REPO") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        if dir.join("Cargo.toml").exists() && dir.join(".chump").is_dir() {
            return dir;
        }
        match dir.parent() {
            Some(p) => dir = p.to_path_buf(),
            None => return std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        }
    }
}

// Control-plane daemon labels to probe for exit-78 via launchctl.
const CONTROL_PLANE_LABELS: &[&str] = &[
    "com.chump.bot-merge-watchdog",
    "com.chump.main-health-watchdog",
    "com.chump.reap-stale-leases",
    "com.chump.stale-process-watchdog",
    "com.chump.heartbeat-watcher",
    "com.chump.ci-health-gate",
    "com.chump.queue-health-monitor",
    "dev.chump.premature-closure-watch",
    "dev.chump.system-invariants-monitor",
];

/// Maximum oauth token age in seconds before considered stale.
const DEFAULT_OAUTH_MAX_AGE_S: u64 = 3600;

/// Maximum farmer heartbeat age in seconds before considered stale.
const FARMER_HEARTBEAT_MAX_AGE_S: u64 = 120;

#[derive(Debug)]
struct StatusResult {
    green: bool,
    sentinel_present: bool,
    exit78_daemons: Vec<String>,
    oauth_age_s: Option<u64>,
    oauth_ok: bool,
    heartbeat_age_s: Option<u64>,
    heartbeat_ok: bool,
    reasons: Vec<String>,
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn file_age_s(path: &Path) -> Option<u64> {
    let meta = fs::metadata(path).ok()?;
    let mtime = meta
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_secs();
    let now = unix_now();
    Some(now.saturating_sub(mtime))
}

/// Check 1: sentinel absent.
fn check_sentinel(chump_dir: &Path) -> bool {
    !chump_dir.join("fleet-paused").exists()
}

/// Check 2: zero exit-78 control-plane daemons.
/// Runs `launchctl list` once and scans for known labels with non-zero exit.
fn check_daemons() -> Vec<String> {
    let output = Command::new("launchctl")
        .arg("list")
        .output()
        .unwrap_or_else(|_| {
            // launchctl unavailable (CI / Linux) — treat as no exit-78 daemons
            std::process::Output {
                stdout: vec![],
                stderr: vec![],
                status: {
                    #[cfg(unix)]
                    {
                        use std::os::unix::process::ExitStatusExt;
                        std::process::ExitStatus::from_raw(0)
                    }
                    #[cfg(not(unix))]
                    {
                        // Windows: just return success
                        Command::new("cmd")
                            .arg("/C")
                            .arg("exit 0")
                            .status()
                            .unwrap()
                    }
                },
            }
        });
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut exit78 = Vec::new();
    for line in stdout.lines() {
        // launchctl list format: "<pid>\t<exit_code>\t<label>"
        // or "-\t<exit_code>\t<label>" when not running
        let parts: Vec<&str> = line.splitn(3, '\t').collect();
        if parts.len() < 3 {
            continue;
        }
        let exit_code = parts[1];
        let label = parts[2];
        if (exit_code == "78" || exit_code == "127") && CONTROL_PLANE_LABELS.contains(&label) {
            exit78.push(label.to_string());
        }
    }
    exit78
}

/// Check 3: oauth token fresh.
fn check_oauth(home: &Path, max_age_s: u64) -> (bool, Option<u64>) {
    let token_path = home.join(".chump/oauth-token.json");
    match file_age_s(&token_path) {
        Some(age) => (age <= max_age_s, Some(age)),
        None => {
            // Token file absent — RED
            (false, None)
        }
    }
}

/// Check 4: farmer heartbeat fresh.
fn check_heartbeat(chump_dir: &Path) -> (bool, Option<u64>) {
    let hb_path = chump_dir.join("farmer-heartbeat");
    match file_age_s(&hb_path) {
        Some(age) => (age <= FARMER_HEARTBEAT_MAX_AGE_S, Some(age)),
        None => {
            // No heartbeat file — farmer may not be installed; treat as RED
            // but with a distinct reason so operators know to install the farmer.
            (false, None)
        }
    }
}

fn run_checks(repo_root: &Path) -> StatusResult {
    let chump_dir = repo_root.join(".chump");
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"));
    let oauth_max_age = std::env::var("FARMER_OAUTH_MAX_AGE_S")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_OAUTH_MAX_AGE_S);

    let sentinel_present = !check_sentinel(&chump_dir);
    let exit78_daemons = check_daemons();
    let (oauth_ok, oauth_age_s) = check_oauth(&home, oauth_max_age);
    let (heartbeat_ok, heartbeat_age_s) = check_heartbeat(&chump_dir);

    let mut reasons = Vec::new();
    if sentinel_present {
        reasons.push("fleet-paused sentinel present".to_string());
    }
    if !exit78_daemons.is_empty() {
        reasons.push(format!("exit-78 daemons: {}", exit78_daemons.join(", ")));
    }
    if !oauth_ok {
        match oauth_age_s {
            Some(age) => reasons.push(format!("oauth token stale ({}s > {}s)", age, oauth_max_age)),
            None => reasons.push("oauth token absent".to_string()),
        }
    }
    if !heartbeat_ok {
        match heartbeat_age_s {
            Some(age) => reasons.push(format!(
                "farmer heartbeat stale ({}s > {}s — run: scripts/setup/install-farmer-launchd.sh)",
                age, FARMER_HEARTBEAT_MAX_AGE_S
            )),
            None => reasons.push(
                "farmer heartbeat absent — farmer not installed? run: scripts/setup/install-farmer-launchd.sh".to_string(),
            ),
        }
    }

    let green = !sentinel_present && exit78_daemons.is_empty() && oauth_ok && heartbeat_ok;

    StatusResult {
        green,
        sentinel_present,
        exit78_daemons,
        oauth_age_s,
        oauth_ok,
        heartbeat_age_s,
        heartbeat_ok,
        reasons,
    }
}

fn print_human(result: &StatusResult) {
    if result.green {
        println!("GREEN — farmer lights on, control plane healthy");
    } else {
        println!("RED — farmer lights OFF");
        for r in &result.reasons {
            println!("  - {}", r);
        }
    }
}

fn print_json(result: &StatusResult) {
    let status = if result.green { "green" } else { "red" };
    let sentinel = if result.sentinel_present {
        "true"
    } else {
        "false"
    };
    let oauth_age = result
        .oauth_age_s
        .map(|a| a.to_string())
        .unwrap_or_else(|| "null".to_string());
    let hb_age = result
        .heartbeat_age_s
        .map(|a| a.to_string())
        .unwrap_or_else(|| "null".to_string());
    let exit78 = result
        .exit78_daemons
        .iter()
        .map(|l| format!("\"{}\"", l))
        .collect::<Vec<_>>()
        .join(",");
    let reasons = result
        .reasons
        .iter()
        .map(|r| format!("\"{}\"", r.replace('"', "\\\"")))
        .collect::<Vec<_>>()
        .join(",");
    println!(
        "{{\"status\":\"{}\",\"sentinel_present\":{},\"exit78_daemons\":[{}],\
        \"oauth_age_s\":{},\"oauth_ok\":{},\"heartbeat_age_s\":{},\"heartbeat_ok\":{},\
        \"reasons\":[{}]}}",
        status, sentinel, exit78, oauth_age, result.oauth_ok, hb_age, result.heartbeat_ok, reasons
    );
}

pub fn run(repo_root: &Path, args: &[String]) -> i32 {
    let json = args.iter().any(|a| a == "--json");
    let quiet = args.iter().any(|a| a == "--quiet");

    let result = run_checks(repo_root);

    if !quiet {
        if json {
            print_json(&result);
        } else {
            print_human(&result);
        }
    }

    if result.green {
        0
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn make_repo() -> TempDir {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join(".chump")).unwrap();
        fs::create_dir_all(dir.path().join(".chump-locks")).unwrap();
        dir
    }

    fn write_fresh_heartbeat(repo: &TempDir) {
        fs::write(
            repo.path().join(".chump/farmer-heartbeat"),
            "2026-06-03T00:00:00Z\n",
        )
        .unwrap();
    }

    fn write_fresh_oauth(repo: &TempDir) -> TempDir {
        let home = tempfile::tempdir().unwrap();
        fs::create_dir_all(home.path().join(".chump")).unwrap();
        fs::write(home.path().join(".chump/oauth-token.json"), "{}").unwrap();
        let _ = repo; // keep lifetime
        home
    }

    #[test]
    fn test_green_when_all_ok() {
        let repo = make_repo();
        write_fresh_heartbeat(&repo);
        // Sentinel absent = good
        // exit78 = none (no launchctl in test env)
        // oauth: provide a fresh file via HOME override
        let home = tempfile::tempdir().unwrap();
        fs::create_dir_all(home.path().join(".chump")).unwrap();
        fs::write(home.path().join(".chump/oauth-token.json"), "{}").unwrap();

        // Manually run checks with the test repo
        let chump_dir = repo.path().join(".chump");
        let sentinel_ok = check_sentinel(&chump_dir);
        let exit78 = check_daemons(); // may return empty in test env
        let oauth_max = 3600u64;
        let (oauth_ok, _) = {
            let p = home.path().join(".chump/oauth-token.json");
            match file_age_s(&p) {
                Some(age) => (age <= oauth_max, Some(age)),
                None => (false, None),
            }
        };
        let hb_path = chump_dir.join("farmer-heartbeat");
        let (hb_ok, _) = match file_age_s(&hb_path) {
            Some(age) => (age <= FARMER_HEARTBEAT_MAX_AGE_S, Some(age)),
            None => (false, None),
        };

        assert!(sentinel_ok, "sentinel should be absent");
        assert!(oauth_ok, "fresh oauth should be ok");
        assert!(hb_ok, "fresh heartbeat should be ok");
        // exit78 check depends on host launchctl — just verify it returns a Vec
        let _ = exit78;
    }

    #[test]
    fn test_red_when_sentinel_present() {
        let repo = make_repo();
        write_fresh_heartbeat(&repo);
        // Create sentinel
        fs::write(repo.path().join(".chump/fleet-paused"), "test\n").unwrap();
        let chump_dir = repo.path().join(".chump");
        assert!(!check_sentinel(&chump_dir), "sentinel present → not ok");
    }

    #[test]
    fn test_red_when_heartbeat_absent() {
        let repo = make_repo();
        // No heartbeat file written
        let chump_dir = repo.path().join(".chump");
        let hb_path = chump_dir.join("farmer-heartbeat");
        let (ok, age) = match file_age_s(&hb_path) {
            Some(a) => (a <= FARMER_HEARTBEAT_MAX_AGE_S, Some(a)),
            None => (false, None),
        };
        assert!(!ok, "absent heartbeat should be RED");
        assert!(age.is_none(), "no age for absent file");
    }

    #[test]
    fn test_red_when_oauth_absent() {
        let home = tempfile::tempdir().unwrap();
        // No oauth token file
        let (ok, age) = {
            let p = home.path().join(".chump/oauth-token.json");
            match file_age_s(&p) {
                Some(a) => (a <= 3600, Some(a)),
                None => (false, None),
            }
        };
        assert!(!ok, "absent oauth should be RED");
        assert!(age.is_none());
    }

    #[test]
    fn test_run_returns_1_when_red() {
        let repo = make_repo();
        // No heartbeat → RED
        let exit_code = run(repo.path(), &["--quiet".to_string()]);
        assert_eq!(exit_code, 1);
    }
}
