//! `chump cron health` (META-600, slice of META-110) — enumerate
//! chump-managed plists/timer units (identified by the `SENTINEL` comment
//! shared with install/uninstall) and report per-unit health: loaded
//! state, last-run timestamp, exit status. Flags units whose backing file
//! is missing or whose last run looks stale.

use crate::backend::{Backend, SENTINEL};
use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Default staleness window: a managed unit that has never fired, or whose
/// last run is older than this, gets a "stale" warning.
const DEFAULT_STALE_AFTER_SECS: u64 = 24 * 60 * 60;

#[derive(Debug, Clone)]
pub struct UnitHealth {
    pub name: String,
    pub backend: &'static str,
    pub loaded: bool,
    pub last_run: Option<String>,
    pub last_run_epoch: Option<u64>,
    pub exit_status: Option<i32>,
    pub warnings: Vec<String>,
}

fn home_dir() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/root".to_string())
}

/// Scan the well-known unit directory for the backend and return the
/// bare `--name` values (prefix/suffix stripped) of every file that
/// carries the chump `SENTINEL` comment — i.e. every unit `chump cron`
/// itself installed, as opposed to operator-owned plists/units.
pub fn discover_managed_names(backend: Backend) -> Vec<String> {
    let home = home_dir();
    match backend {
        Backend::Launchd => {
            let dir = PathBuf::from(&home).join("Library/LaunchAgents");
            scan_dir(&dir, "com.chump.", ".plist")
        }
        Backend::Systemd => {
            let dir = PathBuf::from(&home).join(".config/systemd/user");
            scan_dir(&dir, "chump-", ".timer")
        }
    }
}

fn scan_dir(dir: &Path, prefix: &str, suffix: &str) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(fname) = path.file_name().and_then(|f| f.to_str()) else {
            continue;
        };
        if !fname.starts_with(prefix) || !fname.ends_with(suffix) {
            continue;
        }
        let Ok(contents) = std::fs::read_to_string(&path) else {
            continue;
        };
        if !contents.contains(SENTINEL) {
            continue;
        }
        let name = fname
            .strip_prefix(prefix)
            .and_then(|s| s.strip_suffix(suffix))
            .unwrap_or(fname)
            .to_string();
        out.push(name);
    }
    out.sort();
    out
}

/// Parse `systemctl --user show <unit> -p k1,k2,...` KEY=VALUE output.
fn systemctl_show(unit: &str, props: &[&str]) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let output = Command::new("systemctl")
        .args(["--user", "show", unit, "-p", &props.join(",")])
        .output();
    if let Ok(o) = output {
        if let Ok(text) = String::from_utf8(o.stdout) {
            for line in text.lines() {
                if let Some((k, v)) = line.split_once('=') {
                    map.insert(k.to_string(), v.to_string());
                }
            }
        }
    }
    map
}

/// Best-effort conversion of a systemd-formatted timestamp string
/// (e.g. "Tue 2026-09-16 10:00:00 UTC") to unix-epoch seconds, by
/// shelling out to GNU `date -d`. Returns None for "n/a"/empty/unparseable.
fn parse_systemd_timestamp(s: &str) -> Option<u64> {
    let s = s.trim();
    if s.is_empty() || s == "n/a" {
        return None;
    }
    Command::new("date")
        .args(["-d", s, "+%s"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|out| out.trim().parse::<u64>().ok())
}

fn query_systemd_health(name: &str, now: u64, stale_after: u64) -> UnitHealth {
    let timer_unit = format!("chump-{name}.timer");
    let service_unit = format!("chump-{name}.service");

    let timer_props = systemctl_show(
        &timer_unit,
        &["LoadState", "ActiveState", "LastTriggerUSec"],
    );
    let service_props = systemctl_show(&service_unit, &["ExecMainStatus", "ActiveState"]);

    let loaded = timer_props
        .get("LoadState")
        .map(|s| s == "loaded")
        .unwrap_or(false);

    let last_run_raw = timer_props.get("LastTriggerUSec").cloned();
    let last_run_epoch = last_run_raw.as_deref().and_then(parse_systemd_timestamp);

    let exit_status = service_props
        .get("ExecMainStatus")
        .and_then(|s| s.parse::<i32>().ok());

    let mut warnings = Vec::new();
    if !loaded {
        warnings
            .push("unit file present but not loaded by systemd (missing/unregistered)".to_string());
    }
    match last_run_epoch {
        None => warnings.push("never triggered (no LastTriggerUSec recorded)".to_string()),
        Some(epoch) if now.saturating_sub(epoch) > stale_after => {
            warnings.push(format!(
                "stale: last run {}s ago exceeds stale-after threshold of {}s",
                now.saturating_sub(epoch),
                stale_after
            ));
        }
        Some(_) => {}
    }
    if let Some(code) = exit_status {
        if code != 0 {
            warnings.push(format!("last exit status was non-zero: {code}"));
        }
    }

    UnitHealth {
        name: name.to_string(),
        backend: "systemd",
        loaded,
        last_run: last_run_raw.filter(|s| s != "n/a" && !s.is_empty()),
        last_run_epoch,
        exit_status,
        warnings,
    }
}

fn launchctl_print(label: &str) -> Option<String> {
    let uid = Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "501".to_string());
    let output = Command::new("launchctl")
        .arg("print")
        .arg(format!("gui/{uid}/{label}"))
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}

fn query_launchd_health(name: &str, now: u64, stale_after: u64) -> UnitHealth {
    let label = format!("com.chump.{name}");
    let printed = launchctl_print(&label);
    let loaded = printed.is_some();

    // launchctl print's textual dump varies by macOS version; extract
    // "last exit code" best-effort rather than depending on exact format.
    let exit_status = printed.as_deref().and_then(|text| {
        text.lines().find_map(|line| {
            let line = line.trim();
            line.strip_prefix("last exit code = ")
                .and_then(|v| v.trim().parse::<i32>().ok())
        })
    });

    let mut warnings = Vec::new();
    if !loaded {
        warnings.push("plist present but not loaded by launchd (missing/unregistered)".to_string());
    }
    // launchctl print does not reliably expose a last-run timestamp; fall
    // back to "unknown" rather than guessing — surfaced as a warning so an
    // operator knows the staleness check couldn't run for this unit.
    warnings.push("last-run timestamp not available from launchctl print".to_string());
    if let Some(code) = exit_status {
        if code != 0 {
            warnings.push(format!("last exit status was non-zero: {code}"));
        }
    }
    let _ = (now, stale_after); // staleness math not applicable without a timestamp

    UnitHealth {
        name: name.to_string(),
        backend: "launchd",
        loaded,
        last_run: None,
        last_run_epoch: None,
        exit_status,
        warnings,
    }
}

pub fn collect_health(backend: Backend, stale_after: u64) -> Vec<UnitHealth> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mut out: Vec<UnitHealth> = discover_managed_names(backend)
        .iter()
        .map(|name| match backend {
            Backend::Systemd => query_systemd_health(name, now, stale_after),
            Backend::Launchd => query_launchd_health(name, now, stale_after),
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

fn to_json(h: &UnitHealth) -> serde_json::Value {
    serde_json::json!({
        "kind": "chump_cron_managed",
        "name": h.name,
        "backend": h.backend,
        "loaded": h.loaded,
        "last_run": h.last_run,
        "last_run_epoch": h.last_run_epoch,
        "exit_status": h.exit_status,
        "warnings": h.warnings,
    })
}

fn print_json(healths: &[UnitHealth]) {
    let arr: Vec<serde_json::Value> = healths.iter().map(to_json).collect();
    println!(
        "{}",
        serde_json::to_string_pretty(&arr).unwrap_or_else(|_| "[]".to_string())
    );
}

fn print_text(healths: &[UnitHealth]) {
    if healths.is_empty() {
        println!("chump cron health: no chump-managed units found");
        return;
    }
    for h in healths {
        let last_run = h.last_run.as_deref().unwrap_or("unknown");
        let exit_status = h
            .exit_status
            .map(|c| c.to_string())
            .unwrap_or_else(|| "unknown".to_string());
        println!(
            "{} [{}]: loaded={} last_run={} exit_status={}",
            h.name, h.backend, h.loaded, last_run, exit_status
        );
        for w in &h.warnings {
            println!("  WARNING: {w}");
        }
    }
}

pub fn run_health(args: &[String]) -> Result<i32> {
    let mut json = false;
    let mut stale_after = DEFAULT_STALE_AFTER_SECS;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => {
                json = true;
                i += 1;
            }
            "--stale-after" => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--stale-after needs a value (seconds)"))?;
                stale_after = v
                    .parse::<u64>()
                    .map_err(|_| anyhow!("--stale-after must be an integer number of seconds"))?;
                i += 2;
            }
            other => return Err(anyhow!("unknown flag: {other}")),
        }
    }

    let backend = Backend::detect();
    let healths = collect_health(backend, stale_after);

    if json {
        print_json(&healths);
    } else {
        print_text(&healths);
    }

    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn discover_managed_names_filters_by_sentinel_and_extension() {
        let tmp = tempfile::tempdir().unwrap();
        let managed = tmp.path().join("chump-foo.timer");
        fs::write(&managed, format!("# {SENTINEL}\n[Timer]\n")).unwrap();
        let unmanaged = tmp.path().join("chump-bar.timer");
        fs::write(&unmanaged, "[Timer]\n# some other file\n").unwrap();
        let wrong_suffix = tmp.path().join("chump-foo.service");
        fs::write(&wrong_suffix, format!("# {SENTINEL}\n")).unwrap();

        let names = scan_dir(tmp.path(), "chump-", ".timer");
        assert_eq!(names, vec!["foo".to_string()]);
    }

    #[test]
    fn discover_managed_names_returns_empty_for_missing_dir() {
        let names = scan_dir(Path::new("/nonexistent/path/for/test"), "chump-", ".timer");
        assert!(names.is_empty());
    }

    #[test]
    fn parse_systemd_timestamp_handles_n_a_and_empty() {
        assert_eq!(parse_systemd_timestamp("n/a"), None);
        assert_eq!(parse_systemd_timestamp(""), None);
    }

    #[test]
    fn to_json_carries_managed_kind_field() {
        let h = UnitHealth {
            name: "foo".to_string(),
            backend: "systemd",
            loaded: true,
            last_run: Some("Tue 2026-09-16 10:00:00 UTC".to_string()),
            last_run_epoch: Some(1_000_000),
            exit_status: Some(0),
            warnings: vec![],
        };
        let v = to_json(&h);
        assert_eq!(v["kind"], "chump_cron_managed");
        assert_eq!(v["name"], "foo");
    }

    #[test]
    fn run_health_json_flag_parses() {
        // Runs against whatever the real machine has installed; asserts
        // only that the flag parses and the command doesn't error.
        let code = run_health(&["--json".to_string()]).unwrap();
        assert_eq!(code, 0);
    }

    #[test]
    fn run_health_rejects_unknown_flag() {
        assert!(run_health(&["--bogus".to_string()]).is_err());
    }

    #[test]
    fn run_health_rejects_bad_stale_after() {
        assert!(run_health(&["--stale-after".to_string(), "notanumber".to_string()]).is_err());
    }
}
