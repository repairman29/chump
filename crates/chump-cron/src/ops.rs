//! install / uninstall / status operations, shared across backends.

use crate::backend::{render_launchd_plist, render_systemd_units, Backend};
use crate::spec::{CronSpec, Scope};
use anyhow::{Context, Result};
use std::path::Path;
use std::process::Command;

fn home_dir() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/root".to_string())
}

pub enum InstallOutcome {
    NoopUnchanged,
    Installed,
    Reloaded,
}

pub fn install(spec: &CronSpec, backend: Backend) -> Result<InstallOutcome> {
    match backend {
        Backend::Launchd => install_launchd(spec),
        Backend::Systemd => install_systemd(spec),
    }
}

fn install_launchd(spec: &CronSpec) -> Result<InstallOutcome> {
    let home = home_dir();
    let path = spec.launchd_plist_path(&home);
    let new_content = render_launchd_plist(spec);

    let existed = path.exists();
    if existed {
        let existing = std::fs::read_to_string(&path).unwrap_or_default();
        if existing == new_content {
            return Ok(InstallOutcome::NoopUnchanged);
        }
        // Changed config: unload before rewriting so the reload picks up
        // the new definition atomically.
        bootout_launchd(spec);
    }

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    std::fs::write(&path, &new_content).with_context(|| format!("write {}", path.display()))?;

    bootstrap_launchd(spec, &path)?;

    Ok(if existed {
        InstallOutcome::Reloaded
    } else {
        InstallOutcome::Installed
    })
}

fn domain_target(scope: Scope) -> String {
    match scope {
        Scope::User => format!("gui/{}", current_uid()),
        Scope::System => "system".to_string(),
    }
}

/// Current user id via `id -u` — avoids pulling in the `libc` crate for one syscall.
fn current_uid() -> String {
    Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "501".to_string())
}

fn bootstrap_launchd(spec: &CronSpec, path: &Path) -> Result<()> {
    let domain = domain_target(spec.scope);
    let status = Command::new("launchctl")
        .arg("bootstrap")
        .arg(&domain)
        .arg(path)
        .status();
    match status {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => anyhow::bail!("launchctl bootstrap exited with {s}"),
        Err(e) => anyhow::bail!("launchctl bootstrap failed to run: {e}"),
    }
}

fn bootout_launchd(spec: &CronSpec) {
    let domain = domain_target(spec.scope);
    let target = format!("{domain}/{}", spec.label());
    let _ = Command::new("launchctl")
        .arg("bootout")
        .arg(target)
        .status();
}

pub fn uninstall_launchd(spec: &CronSpec) -> Result<bool> {
    let home = home_dir();
    let path = spec.launchd_plist_path(&home);
    if !path.exists() {
        return Ok(false);
    }
    bootout_launchd(spec);
    std::fs::remove_file(&path).with_context(|| format!("remove {}", path.display()))?;
    Ok(true)
}

fn install_systemd(spec: &CronSpec) -> Result<InstallOutcome> {
    let home = home_dir();
    let dir = spec.systemd_unit_dir(&home);
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;

    let service_path = dir.join(spec.systemd_service_name());
    let timer_path = dir.join(spec.systemd_timer_name());
    let (new_service, new_timer) = render_systemd_units(spec);

    let existed = service_path.exists() && timer_path.exists();
    if existed {
        let cur_service = std::fs::read_to_string(&service_path).unwrap_or_default();
        let cur_timer = std::fs::read_to_string(&timer_path).unwrap_or_default();
        if cur_service == new_service && cur_timer == new_timer {
            return Ok(InstallOutcome::NoopUnchanged);
        }
        systemctl(&["--user", "disable", "--now", &spec.systemd_timer_name()]);
    }

    std::fs::write(&service_path, &new_service)
        .with_context(|| format!("write {}", service_path.display()))?;
    std::fs::write(&timer_path, &new_timer)
        .with_context(|| format!("write {}", timer_path.display()))?;

    systemctl(&["--user", "daemon-reload"]);
    let status = Command::new("systemctl")
        .args(["--user", "enable", "--now", &spec.systemd_timer_name()])
        .status();
    match status {
        Ok(s) if s.success() => {}
        Ok(s) => anyhow::bail!("systemctl enable --now exited with {s}"),
        Err(e) => anyhow::bail!("systemctl enable --now failed to run: {e}"),
    }

    Ok(if existed {
        InstallOutcome::Reloaded
    } else {
        InstallOutcome::Installed
    })
}

fn systemctl(args: &[&str]) {
    let _ = Command::new("systemctl").args(args).status();
}

pub fn uninstall_systemd(spec: &CronSpec) -> Result<bool> {
    let home = home_dir();
    let dir = spec.systemd_unit_dir(&home);
    let service_path = dir.join(spec.systemd_service_name());
    let timer_path = dir.join(spec.systemd_timer_name());

    if !service_path.exists() && !timer_path.exists() {
        return Ok(false);
    }

    systemctl(&["--user", "disable", "--now", &spec.systemd_timer_name()]);
    if service_path.exists() {
        std::fs::remove_file(&service_path)
            .with_context(|| format!("remove {}", service_path.display()))?;
    }
    if timer_path.exists() {
        std::fs::remove_file(&timer_path)
            .with_context(|| format!("remove {}", timer_path.display()))?;
    }
    systemctl(&["--user", "daemon-reload"]);
    Ok(true)
}

/// Status text for `chump cron status --name NAME`.
pub fn status(spec: &CronSpec, backend: Backend) -> String {
    match backend {
        Backend::Launchd => {
            let home = home_dir();
            let path = spec.launchd_plist_path(&home);
            if !path.exists() {
                return format!("{}: not installed", spec.label());
            }
            let domain = domain_target(spec.scope);
            let loaded = Command::new("launchctl")
                .arg("print")
                .arg(format!("{domain}/{}", spec.label()))
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);
            format!(
                "{}: plist present at {}, launchd loaded={}",
                spec.label(),
                path.display(),
                loaded
            )
        }
        Backend::Systemd => {
            let home = home_dir();
            let dir = spec.systemd_unit_dir(&home);
            let timer_path = dir.join(spec.systemd_timer_name());
            if !timer_path.exists() {
                return format!("chump-{}.timer: not installed", spec.name);
            }
            let active = Command::new("systemctl")
                .args(["--user", "is-active", &spec.systemd_timer_name()])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|_| "unknown".to_string());
            format!(
                "chump-{}.timer: unit present at {}, systemd state={}",
                spec.name,
                timer_path.display(),
                active
            )
        }
    }
}
