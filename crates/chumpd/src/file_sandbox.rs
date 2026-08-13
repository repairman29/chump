//! RESILIENT-178 — worker file-access sandbox.
//!
//! chumpd is the single chokepoint that spawns every worker (MISSION-051
//! cutover), so it is the chokepoint to constrain the worker's file view.
//! Interim "search within repo paths only" prompt discipline is
//! advisory-only: on 2026-07-19 a mid-gap broad find/grep strayed past the
//! repo into an iCloud-synced location, and macOS attributed the resulting
//! TCC prompt ("chump wants access to iCloud Drive") to the operator,
//! because the worker `claude` process inherits the operator's full user
//! file authority. The operator denied it — correctly, nothing in the
//! fleet needs iCloud.
//!
//! This module wraps the *whole worker process* (not just chump's own
//! bash tool — see `src/sandbox.rs` in the main crate for that narrower
//! INFRA-1454 layer) in a macOS `sandbox-exec` profile: writes are
//! deny-by-default with an explicit allow-list (repo, claim worktrees,
//! /tmp, `$HOME/.chump`, toolchain dirs); reads stay broadly permissive
//! (the agent binary + toolchain need arbitrary system/library reads) but
//! the known TCC-prompting surfaces (Desktop, Documents, iCloud "Mobile
//! Documents", Downloads, …) are explicitly walled off on top, so a stray
//! access becomes a logged kernel denial instead of an operator dialog.

use std::path::{Path, PathBuf};

/// True when `sandbox-exec` is available on this host (macOS only in v1).
pub fn detect_runtime() -> Option<&'static str> {
    if cfg!(target_os = "macos") && Path::new("/usr/bin/sandbox-exec").is_file() {
        Some("macos/sandbox-exec")
    } else {
        None
    }
}

/// Operator escape hatch: forces the legacy unrestricted-file-view path
/// even when sandbox-exec is available. Mirrors the CHUMP_AGENT_UNSAFE_HOST_EXEC
/// pattern from src/sandbox.rs (INFRA-1454) so the two layers are
/// consistent to operate.
pub fn unsafe_host_exec_forced() -> bool {
    std::env::var("CHUMP_WORKER_UNSAFE_HOST_EXEC")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Whether chumpd should wrap the worker spawn in the file-access
/// sandbox. Default ON whenever the runtime is available (this is the
/// structural fix RESILIENT-178 asks for — not an opt-in pilot like
/// INFRA-1454). `CHUMP_WORKER_FILE_SANDBOX=0` or
/// `CHUMP_WORKER_UNSAFE_HOST_EXEC=1` disable it explicitly (audited via
/// the caller emitting an event when this returns false but a runtime was
/// found).
pub fn worker_sandbox_enabled() -> bool {
    if unsafe_host_exec_forced() {
        return false;
    }
    if let Ok(v) = std::env::var("CHUMP_WORKER_FILE_SANDBOX") {
        return v == "1" || v.eq_ignore_ascii_case("true");
    }
    detect_runtime().is_some()
}

/// The TCC-prompting surfaces a worker must never read from, regardless
/// of the broad read allow below. Kept as a function (not a const) so
/// tests and the profile builder derive it from the same `$HOME`.
pub fn tcc_deny_surfaces(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join("Desktop"),
        home.join("Documents"),
        home.join("Downloads"),
        home.join("Pictures"),
        home.join("Library/Mobile Documents"), // iCloud Drive
        home.join("Library/CloudStorage"),     // Dropbox/OneDrive/GDrive mounts
    ]
}

/// Build the SBPL profile for a worker process.
///
/// - Writes: deny-by-default, explicit allow-list (repo, worktree base if
///   distinct from repo, /tmp variants, `$HOME/.chump`, toolchain dirs).
/// - Reads: broadly permissive (matches src/sandbox.rs's INFRA-1454
///   rationale — the agent binary and toolchain need to read arbitrary
///   system/library paths), EXCEPT the TCC deny-list above, layered on
///   top so it wins over the broad read allow for those specific
///   subpaths.
pub fn build_worker_profile(repo: &Path, worktree_base: Option<&Path>, home: &Path) -> String {
    let mut write_subpaths = vec![
        format!("(subpath \"{}\")", repo.display()),
        "(subpath \"/private/tmp\")".to_string(),
        "(subpath \"/private/var/folders\")".to_string(),
        "(subpath \"/tmp\")".to_string(),
        format!("(subpath \"{}\")", home.join(".chump").display()),
        format!("(subpath \"{}\")", home.join(".cargo").display()),
        format!("(subpath \"{}\")", home.join(".rustup").display()),
        format!("(subpath \"{}\")", home.join(".local").display()),
        format!("(subpath \"{}\")", home.join(".npm").display()),
        format!("(subpath \"{}\")", home.join(".claude").display()),
    ];
    if let Some(wt) = worktree_base {
        if wt != repo && !wt.starts_with(repo) {
            write_subpaths.push(format!("(subpath \"{}\")", wt.display()));
        }
    }

    let deny_read_subpaths: Vec<String> = tcc_deny_surfaces(home)
        .into_iter()
        .map(|p| format!("(subpath \"{}\")", p.display()))
        .collect();

    format!(
        r#"(version 1)
(deny default)
(allow process-fork)
(allow process-exec*)
(allow signal)
(allow mach-lookup)
(allow ipc-posix-shm*)
(allow sysctl-read)
(allow iokit-open)
(allow file-read*)
(deny file-read*
  {deny_read})
(allow file-write*
  {write_list})
(allow network*)
"#,
        deny_read = deny_read_subpaths.join("\n  "),
        write_list = write_subpaths.join("\n  ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_denies_by_default_and_walls_off_tcc_surfaces() {
        let repo = Path::new("/tmp/chump-repo");
        let home = Path::new("/Users/operator");
        let p = build_worker_profile(repo, None, home);
        assert!(p.contains("(deny default)"));
        assert!(p.contains(r#"(subpath "/tmp/chump-repo")"#));
        assert!(p.contains(r#"(subpath "/Users/operator/Desktop")"#));
        assert!(p.contains(r#"(subpath "/Users/operator/Documents")"#));
        assert!(p.contains(r#"(subpath "/Users/operator/Downloads")"#));
        assert!(p.contains(r#"(subpath "/Users/operator/Library/Mobile Documents")"#));
    }

    #[test]
    fn profile_allows_toolchain_and_worktree_paths() {
        let repo = Path::new("/tmp/chump-repo");
        let home = Path::new("/Users/operator");
        let wt = Path::new("/tmp/chump-worktrees");
        let p = build_worker_profile(repo, Some(wt), home);
        assert!(p.contains(r#"(subpath "/Users/operator/.chump")"#));
        assert!(p.contains(r#"(subpath "/Users/operator/.cargo")"#));
        assert!(p.contains(r#"(subpath "/tmp/chump-worktrees")"#));
    }

    #[test]
    fn worktree_base_inside_repo_not_duplicated() {
        let repo = Path::new("/tmp/chump-repo");
        let home = Path::new("/Users/operator");
        let wt = Path::new("/tmp/chump-repo/.claude/worktrees");
        let p = build_worker_profile(repo, Some(wt), home);
        // The repo subpath already covers it — don't emit a second,
        // redundant allow line for a path already under the repo.
        assert_eq!(
            p.matches(r#"(subpath "/tmp/chump-repo/.claude/worktrees")"#)
                .count(),
            0
        );
    }

    #[test]
    fn tcc_deny_surfaces_are_derived_from_home() {
        let home = Path::new("/Users/jeff");
        let surfaces = tcc_deny_surfaces(home);
        assert!(surfaces.contains(&home.join("Desktop")));
        assert!(surfaces.contains(&home.join("Library/Mobile Documents")));
    }

    #[test]
    fn enabled_env_parsing() {
        // SAFETY: localized env-var manipulation, single-threaded test.
        unsafe {
            std::env::remove_var("CHUMP_WORKER_FILE_SANDBOX");
            std::env::remove_var("CHUMP_WORKER_UNSAFE_HOST_EXEC");
        }
        // Default depends on runtime detection (platform-specific); just
        // exercise the override paths deterministically.
        unsafe {
            std::env::set_var("CHUMP_WORKER_FILE_SANDBOX", "0");
        }
        assert!(!worker_sandbox_enabled());
        unsafe {
            std::env::set_var("CHUMP_WORKER_UNSAFE_HOST_EXEC", "1");
        }
        assert!(unsafe_host_exec_forced());
        assert!(!worker_sandbox_enabled());
        unsafe {
            std::env::remove_var("CHUMP_WORKER_FILE_SANDBOX");
            std::env::remove_var("CHUMP_WORKER_UNSAFE_HOST_EXEC");
        }
    }
}
