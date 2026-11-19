//! Cross-platform `chump up`, `chump service <install|uninstall|status>`, and
//! `chump --worker-tick` supervisor lifecycle commands (`Milestone 4`).
//!
//! Supports rootless user-level daemon registration on all three desktop/server OSes:
//! - **macOS**: LaunchAgent (`~/Library/LaunchAgents/com.chump.chumpd.plist`)
//! - **Linux**: systemd user service (`~/.config/systemd/user/chumpd.service`)
//! - **Windows**: Scheduled Task (`schtasks /Create /SC ONLOGON /TN "ChumpDaemon" ...`)

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Canonical macOS LaunchAgent label for `chumpd`.
pub const MACOS_LAUNCH_AGENT_LABEL: &str = "com.chump.chumpd";
/// Canonical Linux systemd user service unit name for `chumpd`.
pub const LINUX_SYSTEMD_UNIT_NAME: &str = "chumpd.service";
/// Canonical Windows Scheduled Task name for `chumpd`.
pub const WINDOWS_SCHEDULED_TASK_NAME: &str = "ChumpDaemon";

/// Resolve the active target git repository for `chump hook`, `chump service`, and `chump up`:
/// 1. Explicit `--repo <path>` argument if provided
/// 2. `CHUMP_REPO` environment variable if set and non-empty
/// 3. `git rev-parse --show-toplevel` from `std::env::current_dir()` when inside a git repo
/// 4. `crate::repo_path::repo_root()` fallback
pub fn resolve_active_git_repo(explicit_repo: Option<&Path>) -> PathBuf {
    if let Some(p) = explicit_repo {
        return p.to_path_buf();
    }
    if let Ok(v) = std::env::var("CHUMP_REPO") {
        let t = v.trim();
        if !t.is_empty() {
            return PathBuf::from(t);
        }
    }
    if let Ok(out) = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout);
            let t = s.trim();
            if !t.is_empty() {
                return PathBuf::from(t);
            }
        }
    }
    crate::repo_path::repo_root()
}

/// Resolve the sibling `chumpd` executable next to `chump` (`std::env::current_exe()`),
/// falling back to `CHUMPD_BIN` or `"chumpd"` on `PATH`.
pub fn resolve_chumpd_exe() -> PathBuf {
    if let Ok(explicit) = std::env::var("CHUMPD_BIN") {
        let t = explicit.trim();
        if !t.is_empty() {
            return PathBuf::from(t);
        }
    }
    if let Ok(cur) = std::env::current_exe() {
        if let Some(dir) = cur.parent() {
            let name = if cfg!(windows) {
                "chumpd.exe"
            } else {
                "chumpd"
            };
            let sibling = dir.join(name);
            if sibling.is_file() {
                return sibling;
            }
        }
    }
    PathBuf::from(if cfg!(windows) {
        "chumpd.exe"
    } else {
        "chumpd"
    })
}

/// Path to the user-level macOS LaunchAgent plist (`~/Library/LaunchAgents/com.chump.chumpd.plist`).
pub fn macos_launch_agent_path(user_home: &Path) -> PathBuf {
    user_home
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{MACOS_LAUNCH_AGENT_LABEL}.plist"))
}

/// Path to the user-level Linux systemd unit (`~/.config/systemd/user/chumpd.service`).
pub fn linux_systemd_unit_path(user_home: &Path) -> PathBuf {
    user_home
        .join(".config")
        .join("systemd")
        .join("user")
        .join(LINUX_SYSTEMD_UNIT_NAME)
}

fn xml_escape(raw: &str) -> String {
    raw.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Render a rootless macOS LaunchAgent `.plist` for `chumpd`.
pub fn render_macos_launchd_plist(chumpd_bin: &Path, repo_root: &Path, log_dir: &Path) -> String {
    let bin = xml_escape(&chumpd_bin.display().to_string());
    let repo = xml_escape(&repo_root.display().to_string());
    let out_log = xml_escape(&log_dir.join("chumpd.out.log").display().to_string());
    let err_log = xml_escape(&log_dir.join("chumpd.err.log").display().to_string());

    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{MACOS_LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{bin}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>{repo}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CHUMP_REPO</key>
        <string>{repo}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{out_log}</string>
    <key>StandardErrorPath</key>
    <string>{err_log}</string>
</dict>
</plist>
"#
    )
}

/// Render a rootless Linux `systemd --user` service unit for `chumpd`.
pub fn render_linux_systemd_unit(chumpd_bin: &Path, repo_root: &Path) -> String {
    let bin = chumpd_bin.display().to_string().replace('"', "\\\"");
    let repo = repo_root.display().to_string().replace('"', "\\\"");
    format!(
        "[Unit]\n\
         Description=Universal Chump Supervisor Daemon (chumpd)\n\
         After=network-online.target\n\
         \n\
         [Service]\n\
         Type=simple\n\
         WorkingDirectory=\"{repo}\"\n\
         Environment=\"CHUMP_REPO={repo}\"\n\
         ExecStart=\"{bin}\"\n\
         Restart=always\n\
         RestartSec=5\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n"
    )
}

/// Build `schtasks.exe` arguments to install `ChumpDaemon` at user logon on Windows.
pub fn build_windows_schtasks_install_args(chumpd_bin: &Path) -> Vec<String> {
    vec![
        "/Create".to_string(),
        "/SC".to_string(),
        "ONLOGON".to_string(),
        "/TN".to_string(),
        WINDOWS_SCHEDULED_TASK_NAME.to_string(),
        "/TR".to_string(),
        format!("\"{}\"", chumpd_bin.display()),
        "/F".to_string(),
    ]
}

/// Build `schtasks.exe` arguments to uninstall `ChumpDaemon` on Windows.
pub fn build_windows_schtasks_uninstall_args() -> Vec<String> {
    vec![
        "/Delete".to_string(),
        "/TN".to_string(),
        WINDOWS_SCHEDULED_TASK_NAME.to_string(),
        "/F".to_string(),
    ]
}

/// Build `schtasks.exe` arguments to query `ChumpDaemon` status on Windows.
pub fn build_windows_schtasks_status_args() -> Vec<String> {
    vec![
        "/Query".to_string(),
        "/TN".to_string(),
        WINDOWS_SCHEDULED_TASK_NAME.to_string(),
    ]
}

/// Entry point for `chump service <install|uninstall|status> [--dry-run]`.
pub fn run_service_cli(args: &[String]) -> i32 {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let sub = args
        .iter()
        .find(|a| !a.starts_with('-'))
        .map(String::as_str)
        .unwrap_or("--help");
    tracing::debug!(subcommand = %sub, dry_run, "chump service dispatch");

    if args.iter().any(|a| a == "--help" || a == "-h") || sub == "help" || sub == "--help" {
        println!("Usage: chump service <install|uninstall|status> [--dry-run]");
        println!();
        println!("Manages rootless user-level background supervision for `chumpd`:");
        println!("  - macOS:   ~/Library/LaunchAgents/com.chump.chumpd.plist");
        println!("  - Linux:   ~/.config/systemd/user/chumpd.service");
        println!("  - Windows: schtasks ONLOGON task \"ChumpDaemon\"");
        return 0;
    }

    let user_home = chump_pal::user_home();
    let chump_home = chump_pal::chump_home();
    let log_dir = chump_home.join("logs");
    let repo_root = resolve_active_git_repo(None);
    let chumpd_bin = resolve_chumpd_exe();

    match sub {
        "install" => service_install(&user_home, &log_dir, &chumpd_bin, &repo_root, dry_run),
        "uninstall" => service_uninstall(&user_home, dry_run),
        "status" => service_status(&user_home, dry_run),
        other => {
            eprintln!("chump service: unknown subcommand '{other}'");
            eprintln!("usage: chump service <install|uninstall|status> [--dry-run]");
            2
        }
    }
}

fn service_install(
    user_home: &Path,
    log_dir: &Path,
    chumpd_bin: &Path,
    repo_root: &Path,
    dry_run: bool,
) -> i32 {
    if cfg!(target_os = "macos") {
        let plist_path = macos_launch_agent_path(user_home);
        let plist = render_macos_launchd_plist(chumpd_bin, repo_root, log_dir);
        if dry_run {
            println!("[dry-run] write {}", plist_path.display());
            print!("{plist}");
            println!("[dry-run] launchctl load -w {}", plist_path.display());
            return 0;
        }
        if let Some(parent) = plist_path.parent() {
            if let Err(e) = fs::create_dir_all(parent) {
                eprintln!("chump service install: create {}: {e}", parent.display());
                return 1;
            }
        }
        let _ = fs::create_dir_all(log_dir);
        if let Err(e) = fs::write(&plist_path, plist) {
            eprintln!("chump service install: write {}: {e}", plist_path.display());
            return 1;
        }
        let _ = Command::new("launchctl")
            .args(["unload", &plist_path.display().to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        match Command::new("launchctl")
            .args(["load", "-w", &plist_path.display().to_string()])
            .status()
        {
            Ok(st) if st.success() => {
                println!(
                    "Installed and loaded LaunchAgent at {}",
                    plist_path.display()
                );
                0
            }
            Ok(st) => {
                eprintln!(
                    "Wrote {}, but `launchctl load` exited with {st}",
                    plist_path.display()
                );
                1
            }
            Err(e) => {
                eprintln!("Failed invoking launchctl: {e}");
                1
            }
        }
    } else if cfg!(windows) {
        let sch_args = build_windows_schtasks_install_args(chumpd_bin);
        if dry_run {
            println!("[dry-run] schtasks {}", sch_args.join(" "));
            return 0;
        }
        match Command::new("schtasks").args(&sch_args).status() {
            Ok(st) if st.success() => {
                println!("Installed Windows Scheduled Task `{WINDOWS_SCHEDULED_TASK_NAME}`");
                0
            }
            Ok(st) => {
                eprintln!("schtasks install exited with {st}");
                1
            }
            Err(e) => {
                eprintln!("Failed invoking schtasks: {e}");
                1
            }
        }
    } else {
        let unit_path = linux_systemd_unit_path(user_home);
        let unit = render_linux_systemd_unit(chumpd_bin, repo_root);
        if dry_run {
            println!("[dry-run] write {}", unit_path.display());
            print!("{unit}");
            println!("[dry-run] systemctl --user daemon-reload && systemctl --user enable --now {LINUX_SYSTEMD_UNIT_NAME}");
            return 0;
        }
        if let Some(parent) = unit_path.parent() {
            if let Err(e) = fs::create_dir_all(parent) {
                eprintln!("chump service install: create {}: {e}", parent.display());
                return 1;
            }
        }
        if let Err(e) = fs::write(&unit_path, unit) {
            eprintln!("chump service install: write {}: {e}", unit_path.display());
            return 1;
        }
        let _ = Command::new("systemctl")
            .args(["--user", "daemon-reload"])
            .status();
        match Command::new("systemctl")
            .args(["--user", "enable", "--now", LINUX_SYSTEMD_UNIT_NAME])
            .status()
        {
            Ok(st) if st.success() => {
                println!("Installed and enabled {}", unit_path.display());
                0
            }
            Ok(st) => {
                eprintln!(
                    "Wrote {}, but `systemctl --user enable --now` exited with {st}",
                    unit_path.display()
                );
                1
            }
            Err(e) => {
                eprintln!("Failed invoking systemctl: {e}");
                1
            }
        }
    }
}

fn service_uninstall(user_home: &Path, dry_run: bool) -> i32 {
    if cfg!(target_os = "macos") {
        let plist_path = macos_launch_agent_path(user_home);
        if dry_run {
            println!("[dry-run] launchctl unload -w {}", plist_path.display());
            println!("[dry-run] rm {}", plist_path.display());
            return 0;
        }
        if plist_path.exists() {
            let _ = Command::new("launchctl")
                .args(["unload", "-w", &plist_path.display().to_string()])
                .status();
            let _ = fs::remove_file(&plist_path);
        }
        println!("Uninstalled LaunchAgent {}", plist_path.display());
        0
    } else if cfg!(windows) {
        let sch_args = build_windows_schtasks_uninstall_args();
        if dry_run {
            println!("[dry-run] schtasks {}", sch_args.join(" "));
            return 0;
        }
        let _ = Command::new("schtasks").args(&sch_args).status();
        println!("Removed Windows Scheduled Task `{WINDOWS_SCHEDULED_TASK_NAME}`");
        0
    } else {
        let unit_path = linux_systemd_unit_path(user_home);
        if dry_run {
            println!("[dry-run] systemctl --user disable --now {LINUX_SYSTEMD_UNIT_NAME}");
            println!("[dry-run] rm {}", unit_path.display());
            return 0;
        }
        let _ = Command::new("systemctl")
            .args(["--user", "disable", "--now", LINUX_SYSTEMD_UNIT_NAME])
            .status();
        if unit_path.exists() {
            let _ = fs::remove_file(&unit_path);
        }
        let _ = Command::new("systemctl")
            .args(["--user", "daemon-reload"])
            .status();
        println!("Uninstalled systemd user unit {}", unit_path.display());
        0
    }
}

fn service_status(user_home: &Path, dry_run: bool) -> i32 {
    if cfg!(target_os = "macos") {
        let plist_path = macos_launch_agent_path(user_home);
        if dry_run {
            println!("[dry-run] launchctl list {MACOS_LAUNCH_AGENT_LABEL}");
            return 0;
        }
        let installed = plist_path.is_file();
        let loaded = Command::new("launchctl")
            .args(["list", MACOS_LAUNCH_AGENT_LABEL])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        println!(
            "platform: macos\nplist: {} ({})\nloaded: {}",
            plist_path.display(),
            if installed { "present" } else { "absent" },
            loaded
        );
        0
    } else if cfg!(windows) {
        let sch_args = build_windows_schtasks_status_args();
        if dry_run {
            println!("[dry-run] schtasks {}", sch_args.join(" "));
            return 0;
        }
        let registered = Command::new("schtasks")
            .args(&sch_args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        println!(
            "platform: windows\ntask: {WINDOWS_SCHEDULED_TASK_NAME}\nregistered: {registered}"
        );
        0
    } else {
        let unit_path = linux_systemd_unit_path(user_home);
        if dry_run {
            println!("[dry-run] systemctl --user is-active {LINUX_SYSTEMD_UNIT_NAME}");
            return 0;
        }
        let installed = unit_path.is_file();
        let active = Command::new("systemctl")
            .args(["--user", "is-active", "--quiet", LINUX_SYSTEMD_UNIT_NAME])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        println!(
            "platform: linux\nunit: {} ({})\nactive: {}",
            unit_path.display(),
            if installed { "present" } else { "absent" },
            active
        );
        0
    }
}

/// Entry point for `chump up [--foreground] [--mode grind|travel|off] [--workers N] [--dry-run]`.
pub fn run_up_cli(args: &[String]) -> i32 {
    if args
        .iter()
        .any(|a| a == "--help" || a == "-h" || a == "help")
    {
        println!(
            "Usage: chump up [--foreground] [--mode grind|travel|off] [--workers N] [--dry-run]"
        );
        println!();
        println!("Initializes ~/.chump/config.toml (if missing) and starts the cross-platform `chumpd` supervisor.");
        return 0;
    }

    let foreground = args.iter().any(|a| a == "--foreground");
    let dry_run = args.iter().any(|a| a == "--dry-run");

    let mut requested_mode: Option<String> = None;
    let mut requested_workers: Option<usize> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--mode" => {
                if let Some(m) = args.get(i + 1) {
                    requested_mode = Some(m.trim().to_ascii_lowercase());
                    i += 1;
                }
            }
            "--workers" => {
                if let Some(w) = args.get(i + 1).and_then(|s| s.trim().parse::<usize>().ok()) {
                    requested_workers = Some(w);
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }

    let chump_home = chump_pal::chump_home();
    let cfg_path = chump_config::default_config_path();
    let repo_root = resolve_active_git_repo(None);
    let chumpd_bin = resolve_chumpd_exe();

    if dry_run {
        println!(
            "[dry-run] ensure config at {}\n[dry-run] start {} (foreground={}, repo={})",
            cfg_path.display(),
            chumpd_bin.display(),
            foreground,
            repo_root.display()
        );
        return 0;
    }

    let _ = chump_config::write_starter_config(&cfg_path, false);

    if let Some(ref mode) = requested_mode {
        if chump_config::FleetModeConfig::parse_loose(mode).is_none() {
            eprintln!("chump up: invalid --mode '{mode}' (expected grind, travel, or off)");
            return 2;
        }
        let _ = fs::create_dir_all(&chump_home);
        let _ = fs::write(chump_home.join("fleet-mode"), format!("{mode}\n"));
    }
    if let Some(n) = requested_workers {
        let dot_chump = repo_root.join(".chump");
        let _ = fs::create_dir_all(&dot_chump);
        let _ = fs::write(dot_chump.join("fleet-desired-size"), format!("{n}\n"));
    }

    // Check if chumpd is already running via its loopback IPC endpoint.
    let ipc_path = chump_pal::ipc::ipc_file_path_in(&chump_home, "chumpd");
    if let Some(ep) = fs::read_to_string(&ipc_path)
        .ok()
        .and_then(|s| serde_json::from_str::<chump_pal::ipc::IpcEndpoint>(&s).ok())
    {
        if chump_pal::is_pid_alive(ep.pid) {
            println!(
                "chumpd is already running (pid={}, ipc=127.0.0.1:{})",
                ep.pid, ep.port
            );
            return 0;
        }
    }

    let mut cmd = Command::new(&chumpd_bin);
    cmd.current_dir(&repo_root).env("CHUMP_REPO", &repo_root);

    if foreground {
        match cmd.status() {
            Ok(st) => st.code().unwrap_or(0),
            Err(e) => {
                eprintln!("chump up: failed starting {}: {e}", chumpd_bin.display());
                1
            }
        }
    } else {
        let log_dir = chump_home.join("logs");
        let _ = fs::create_dir_all(&log_dir);
        let log_path = log_dir.join("chumpd.log");
        let log_file = match fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
        {
            Ok(f) => f,
            Err(e) => {
                eprintln!("chump up: failed opening {}: {e}", log_path.display());
                return 1;
            }
        };
        let log_err = match log_file.try_clone() {
            Ok(f) => f,
            Err(e) => {
                eprintln!("chump up: failed cloning log handle: {e}");
                return 1;
            }
        };
        chump_pal::configure_isolated_child(&mut cmd);
        cmd.stdin(Stdio::null())
            .stdout(Stdio::from(log_file))
            .stderr(Stdio::from(log_err));
        match cmd.spawn() {
            Ok(child) => {
                println!(
                    "Started chumpd in background (pid={}, logs={})",
                    child.id(),
                    log_path.display()
                );
                0
            }
            Err(e) => {
                eprintln!("chump up: failed spawning {}: {e}", chumpd_bin.display());
                1
            }
        }
    }
}

/// Pure-Rust single worker cycle (`chump --worker-tick`) invoked by `chumpd worker --native`
/// across Windows, macOS, and Linux with zero bash dependency.
pub fn run_worker_tick() -> i32 {
    let chump_home = chump_pal::chump_home();
    let repo_root = crate::repo_path::repo_root();
    if repo_root.join(".chump/fleet-paused").exists() || crate::node_pause::is_paused(&chump_home) {
        return 0;
    }

    // Check if a local canonical state.db exists in `repo_root/.chump/state.db`
    // (never walking up from linked worktrees unless CHUMP_STATE_DB is set).
    let state_db = std::env::var_os("CHUMP_STATE_DB")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo_root.join(".chump/state.db"));
    if !state_db.is_file() {
        return 0;
    }

    if std::env::var("CHUMP_WORKER_AUTO_DISPATCH").as_deref() == Ok("1") {
        let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("chump"));
        let st = Command::new(exe)
            .args(["dispatch", "--auto"])
            .current_dir(&repo_root)
            .status();
        return st.ok().and_then(|s| s.code()).unwrap_or(1);
    }

    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_valid_macos_launchd_plist() {
        let plist = render_macos_launchd_plist(
            Path::new("/usr/local/bin/chumpd"),
            Path::new("/Users/op/Projects/Chump"),
            Path::new("/Users/op/.chump/logs"),
        );
        assert!(plist.contains("<string>com.chump.chumpd</string>"));
        assert!(plist.contains("<string>/usr/local/bin/chumpd</string>"));
        assert!(plist.contains("<key>KeepAlive</key>"));
        assert!(plist.contains("<true/>"));
    }

    #[test]
    fn renders_valid_linux_systemd_user_unit() {
        let unit = render_linux_systemd_unit(
            Path::new("/home/op/.cargo/bin/chumpd"),
            Path::new("/home/op/Chump"),
        );
        assert!(unit.contains("ExecStart=\"/home/op/.cargo/bin/chumpd\""));
        assert!(unit.contains("Restart=always"));
        assert!(unit.contains("WantedBy=default.target"));
    }

    #[test]
    fn builds_valid_windows_schtasks_commands() {
        let install =
            build_windows_schtasks_install_args(Path::new(r"C:\Users\op\.cargo\bin\chumpd.exe"));
        assert_eq!(
            install,
            vec![
                "/Create",
                "/SC",
                "ONLOGON",
                "/TN",
                "ChumpDaemon",
                "/TR",
                r#""C:\Users\op\.cargo\bin\chumpd.exe""#,
                "/F",
            ]
        );
        let uninstall = build_windows_schtasks_uninstall_args();
        assert_eq!(uninstall, vec!["/Delete", "/TN", "ChumpDaemon", "/F"]);
        let status = build_windows_schtasks_status_args();
        assert_eq!(status, vec!["/Query", "/TN", "ChumpDaemon"]);
    }

    #[test]
    fn service_and_up_dry_run_succeed_without_side_effects() {
        assert_eq!(
            run_service_cli(&["install".to_string(), "--dry-run".to_string()]),
            0
        );
        assert_eq!(
            run_service_cli(&["status".to_string(), "--dry-run".to_string()]),
            0
        );
        assert_eq!(
            run_service_cli(&["uninstall".to_string(), "--dry-run".to_string()]),
            0
        );
        assert_eq!(run_up_cli(&["--dry-run".to_string()]), 0);
    }
}
