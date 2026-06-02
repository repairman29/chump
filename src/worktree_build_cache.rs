//! INFRA-2183: per-worktree build-cache wiring for `chump claim`.
//!
//! After `git worktree add`, `provision_worktree_build_cache` is called to
//! ensure every new worktree builds with the shared sccache compile cache AND
//! its own isolated CARGO_TARGET_DIR so parallel Sonnet workers do not collide
//! on the same build artefacts.
//!
//! # What this module does
//!
//! 1. Reads the repo-root `.cargo/config.toml`.
//! 2. Writes a per-worktree `.cargo/config.toml` that copies the `[build]`
//!    section (keeping `rustc-wrapper = ".../sccache"`) and the `[env]`
//!    section, but **overrides** `target-dir` to `<worktree_path>/target`.
//!    The reaper (INFRA-1170 / INFRA-2125) already covers `/tmp/chump-*/target/`
//!    — no new reaper scope required.
//! 3. Emits `kind=worktree_build_cache_provisioned` to `ambient.jsonl` on
//!    success, or `kind=worktree_build_cache_skip` (with reason) when sccache
//!    is absent or the repo-root config is missing.
//!
//! # Design constraints
//!
//! - **sccache (compile cache) is shared / warm** — the `rustc-wrapper` path
//!   is copied verbatim so the sccache daemon serves all worktrees.
//! - **CARGO_TARGET_DIR is per-worktree / isolated** — `target-dir` is set to
//!   `<worktree>/target` so concurrent cargo invocations write to distinct dirs.
//! - **Fail-open**: if provisioning fails (missing config, sccache absent, I/O
//!   error), we emit a skip event and continue — a cold build is preferable to a
//!   failed claim.
//! - **CI-safe**: when `CHUMP_WORKTREE_BUILD_CACHE_DISABLED=1` is set (e.g. CI
//!   runners without sccache) the function returns `Outcome::Skipped` without
//!   writing anything.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Outcome of a `provision_worktree_build_cache` call.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// sccache wiring + per-worktree target-dir written successfully.
    Provisioned {
        sccache_path: String,
        target_dir: PathBuf,
    },
    /// Provisioning skipped (sccache absent, config missing, CI override, etc.).
    /// The `reason` string is included in the ambient event.
    Skipped { reason: String },
}

/// Provision build-cache wiring for a freshly-created linked worktree.
///
/// `repo_root`     — main repo root (source of `.cargo/config.toml`)
/// `worktree_path` — the new worktree directory (destination)
/// `gap_id`        — claimed gap ID (for ambient events)
/// `ambient_log`   — path to `.chump-locks/ambient.jsonl` for events
///
/// Never returns `Err` — on failure it returns `Outcome::Skipped` with a
/// reason string and emits the skip event.
pub fn provision_worktree_build_cache(
    repo_root: &Path,
    worktree_path: &Path,
    gap_id: &str,
    ambient_log: &Path,
) -> Outcome {
    // CI-override escape hatch.
    if std::env::var("CHUMP_WORKTREE_BUILD_CACHE_DISABLED")
        .map(|v| v.trim() == "1")
        .unwrap_or(false)
    {
        let reason = "CHUMP_WORKTREE_BUILD_CACHE_DISABLED=1".to_string();
        emit_skip(ambient_log, gap_id, &reason);
        return Outcome::Skipped { reason };
    }

    let host_config = repo_root.join(".cargo/config.toml");

    // Read and parse the host .cargo/config.toml.
    let host_contents = match std::fs::read_to_string(&host_config) {
        Ok(c) => c,
        Err(e) => {
            let reason = format!("host .cargo/config.toml unreadable: {e}");
            emit_skip(ambient_log, gap_id, &reason);
            eprintln!("[claim] worktree-build-cache: skip — {reason}");
            return Outcome::Skipped { reason };
        }
    };

    // Extract sccache path from `rustc-wrapper = "..."` line.
    let sccache_path = match extract_rustc_wrapper(&host_contents) {
        Some(p) => p,
        None => {
            let reason = "no rustc-wrapper in host config — sccache not configured".to_string();
            emit_skip(ambient_log, gap_id, &reason);
            eprintln!("[claim] worktree-build-cache: skip — {reason}");
            return Outcome::Skipped { reason };
        }
    };

    // Verify sccache binary is present on this machine.
    if !Path::new(&sccache_path).exists() {
        let reason = format!("sccache binary absent: {sccache_path}");
        emit_skip(ambient_log, gap_id, &reason);
        eprintln!("[claim] worktree-build-cache: skip — {reason}");
        return Outcome::Skipped { reason };
    }

    // Per-worktree target dir: <worktree>/target
    // This keeps it under /tmp/chump-<gap>/target/ which is already covered by
    // the INFRA-1170 reaper pass (orphaned worktree target dirs).
    let target_dir = worktree_path.join("target");

    // Build the worktree-local config.toml content.
    // Strategy: copy the original content, then:
    //   - Replace or insert `target-dir` under [build]
    //   - Preserve rustc-wrapper and [env] section verbatim
    let worktree_config_contents =
        build_worktree_config(&host_contents, &sccache_path, &target_dir);

    // Create .cargo/ dir in the worktree (git worktree add doesn't create it).
    let worktree_cargo_dir = worktree_path.join(".cargo");
    if let Err(e) = std::fs::create_dir_all(&worktree_cargo_dir) {
        let reason = format!("cannot create worktree .cargo/ dir: {e}");
        emit_skip(ambient_log, gap_id, &reason);
        eprintln!("[claim] worktree-build-cache: skip — {reason}");
        return Outcome::Skipped { reason };
    }

    let dest = worktree_cargo_dir.join("config.toml");
    if let Err(e) = std::fs::write(&dest, &worktree_config_contents) {
        let reason = format!("cannot write worktree .cargo/config.toml: {e}");
        emit_skip(ambient_log, gap_id, &reason);
        eprintln!("[claim] worktree-build-cache: skip — {reason}");
        return Outcome::Skipped { reason };
    }

    eprintln!(
        "[claim] worktree-build-cache: provisioned (sccache={}, target={})",
        sccache_path,
        target_dir.display()
    );
    emit_provisioned(ambient_log, gap_id, &sccache_path, &target_dir);

    Outcome::Provisioned {
        sccache_path,
        target_dir,
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Extract the `rustc-wrapper = "<path>"` value from a config.toml string.
/// Returns `None` if the key is absent.
fn extract_rustc_wrapper(config: &str) -> Option<String> {
    for line in config.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("rustc-wrapper") {
            // `rustc-wrapper = "/path/to/sccache"`
            let rest = rest.trim_start_matches(|c: char| c.is_whitespace() || c == '=');
            let path = rest.trim_matches('"').trim_matches('\'');
            if !path.is_empty() {
                return Some(path.to_string());
            }
        }
    }
    None
}

/// Build the per-worktree config.toml contents:
///   - Copy all lines from the host config verbatim
///   - Remove any existing `target-dir` line under [build] (we'll re-inject it)
///   - Insert `target-dir = "<worktree>/target"` immediately after
///     `rustc-wrapper = ...` (both are [build] keys)
///
/// If there is no `rustc-wrapper` line (guarded upstream), fall back to
/// injecting `target-dir` at the start of the [build] block.
fn build_worktree_config(host: &str, sccache_path: &str, target_dir: &Path) -> String {
    let target_dir_str = target_dir.display().to_string();
    let target_dir_line = format!("target-dir = \"{target_dir_str}\"");

    let mut out = String::with_capacity(host.len() + 64);
    let mut injected = false;

    for line in host.lines() {
        let trimmed = line.trim();

        // Drop any existing target-dir assignment (we're replacing it).
        if trimmed.starts_with("target-dir") && trimmed.contains('=') {
            continue;
        }

        out.push_str(line);
        out.push('\n');

        // Inject our per-worktree target-dir immediately after rustc-wrapper.
        if !injected && trimmed.starts_with("rustc-wrapper") && trimmed.contains(sccache_path) {
            out.push_str(&target_dir_line);
            out.push('\n');
            injected = true;
        }
    }

    // Fallback: if we never saw rustc-wrapper (shouldn't happen — checked upstream),
    // append target-dir at the end of the [build] section heuristically.
    if !injected {
        // Find [build] section and inject there, or just append.
        let mut rebuilt = String::with_capacity(out.len() + 64);
        let mut in_build = false;
        let mut done = false;
        for line in out.lines() {
            rebuilt.push_str(line);
            rebuilt.push('\n');
            if line.trim() == "[build]" {
                in_build = true;
            } else if in_build
                && !done
                && (line.trim().starts_with('[') && line.trim() != "[build]")
            {
                // We're leaving [build] section — inject before this new section.
                rebuilt.insert_str(
                    rebuilt.len() - line.len() - 1,
                    &format!("{target_dir_line}\n"),
                );
                done = true;
                in_build = false;
            }
        }
        if in_build && !done {
            // [build] was the last section.
            rebuilt.push_str(&target_dir_line);
            rebuilt.push('\n');
        }
        return rebuilt;
    }

    out
}

// ── Ambient event emitters ────────────────────────────────────────────────────

fn now_ts() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn append_event(ambient_log: &Path, line: &str) {
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

fn emit_provisioned(ambient_log: &Path, gap_id: &str, sccache_path: &str, target_dir: &Path) {
    let ts = now_ts();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"worktree_build_cache_provisioned\",\
         \"gap_id\":\"{gap}\",\"sccache_path\":\"{sc}\",\"target_dir\":\"{td}\"}}\n",
        ts = ts,
        gap = json_escape(gap_id),
        sc = json_escape(sccache_path),
        td = json_escape(&target_dir.display().to_string()),
    );
    append_event(ambient_log, &line);
}

fn emit_skip(ambient_log: &Path, gap_id: &str, reason: &str) {
    let ts = now_ts();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"worktree_build_cache_skip\",\
         \"gap_id\":\"{gap}\",\"reason\":\"{reason}\"}}\n",
        ts = ts,
        gap = json_escape(gap_id),
        reason = json_escape(reason),
    );
    append_event(ambient_log, &line);
}

/// Minimal JSON string escaping (backslash + quote + control chars).
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out
}

/// Seconds → (year, month, day, hour, minute, second) UTC decomposition.
/// Mirrors the helper in atomic_claim.rs to avoid a cross-module dependency.
fn secs_to_ymdhms(mut secs: u64) -> (u32, u32, u32, u32, u32, u32) {
    let s = (secs % 60) as u32;
    secs /= 60;
    let mi = (secs % 60) as u32;
    secs /= 60;
    let h = (secs % 24) as u32;
    secs /= 24;
    // Days since 1970-01-01 → Gregorian calendar.
    let mut year = 1970u32;
    loop {
        let days_in_year = if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
            366
        } else {
            365
        };
        if secs < days_in_year {
            break;
        }
        secs -= days_in_year;
        year += 1;
    }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days_in_month = [
        31u32,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut month = 1u32;
    for dim in &days_in_month {
        if secs < *dim as u64 {
            break;
        }
        secs -= *dim as u64;
        month += 1;
    }
    let day = (secs + 1) as u32;
    (year, month, day, h, mi, s)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Mutex;
    use tempfile::TempDir;

    /// Shared mutex so tests that mutate CHUMP_WORKTREE_BUILD_CACHE_DISABLED don't
    /// race with tests that must read it as unset.  Any test that calls
    /// set_var / remove_var on this key must hold `_env_guard` for the
    /// duration of the `provision_*` call.
    static ENV_MUTEX: Mutex<()> = Mutex::new(());

    fn make_host_config(sccache_path: &str) -> String {
        format!(
            "# INFRA-202: sccache wiring\n\
             [build]\n\
             target-dir = \"/Users/test/Projects/Chump/target\"\n\
             rustc-wrapper = \"{sccache_path}\"\n\
             \n\
             [env]\n\
             SCCACHE_CACHE_SIZE = \"20G\"\n"
        )
    }

    /// AC1 + AC2: freshly-provisioned worktree has sccache wiring AND unique target-dir.
    #[test]
    fn test_provision_creates_cargo_config() {
        // Hold ENV_MUTEX so test_env_skip_override cannot set the env var
        // concurrently while this test reads it (Rust tests run in parallel).
        let _env_guard = ENV_MUTEX.lock().unwrap();
        std::env::remove_var("CHUMP_WORKTREE_BUILD_CACHE_DISABLED");

        let repo_dir = TempDir::new().unwrap();
        let wt_dir = TempDir::new().unwrap();

        // Create a fake sccache binary (must exist for the path-check).
        let sccache_bin = repo_dir.path().join("sccache");
        fs::write(&sccache_bin, "#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&sccache_bin, fs::Permissions::from_mode(0o755)).unwrap();
        }

        // Write host .cargo/config.toml.
        let host_cargo = repo_dir.path().join(".cargo");
        fs::create_dir_all(&host_cargo).unwrap();
        let host_config = host_cargo.join("config.toml");
        fs::write(
            &host_config,
            make_host_config(sccache_bin.to_str().unwrap()),
        )
        .unwrap();

        let ambient_log = repo_dir.path().join(".chump-locks/ambient.jsonl");

        let outcome = provision_worktree_build_cache(
            repo_dir.path(),
            wt_dir.path(),
            "INFRA-2183",
            &ambient_log,
        );

        // AC1: Provisioned outcome with sccache path.
        assert!(
            matches!(outcome, Outcome::Provisioned { .. }),
            "expected Provisioned, got {outcome:?}"
        );
        if let Outcome::Provisioned {
            ref sccache_path,
            ref target_dir,
        } = outcome
        {
            assert_eq!(sccache_path, sccache_bin.to_str().unwrap());
            // AC2: target_dir is per-worktree (under the new worktree, not the repo root).
            assert_eq!(target_dir, &wt_dir.path().join("target"));
            assert!(
                target_dir.starts_with(wt_dir.path()),
                "target_dir must be inside the worktree"
            );
        }

        // Verify the written config contains rustc-wrapper.
        let written = fs::read_to_string(wt_dir.path().join(".cargo/config.toml")).unwrap();
        assert!(
            written.contains("rustc-wrapper"),
            "config must contain rustc-wrapper"
        );

        // Verify target-dir in written config points at worktree/target, NOT repo root.
        assert!(
            written.contains(&format!(
                "target-dir = \"{}\"",
                wt_dir.path().join("target").display()
            )),
            "written config must set per-worktree target-dir"
        );
        assert!(
            !written.contains("/Users/test/Projects/Chump/target"),
            "written config must NOT contain the shared target-dir"
        );

        // AC5: ambient event was emitted.
        let events = fs::read_to_string(&ambient_log).unwrap_or_default();
        assert!(
            events.contains("worktree_build_cache_provisioned"),
            "expected provisioned event"
        );
    }

    /// Skips gracefully when host .cargo/config.toml is missing.
    #[test]
    fn test_skip_when_no_host_config() {
        let repo_dir = TempDir::new().unwrap();
        let wt_dir = TempDir::new().unwrap();
        let ambient_log = repo_dir.path().join(".chump-locks/ambient.jsonl");

        let outcome = provision_worktree_build_cache(
            repo_dir.path(),
            wt_dir.path(),
            "INFRA-2183",
            &ambient_log,
        );

        assert!(
            matches!(outcome, Outcome::Skipped { .. }),
            "expected Skipped"
        );
        let events = fs::read_to_string(&ambient_log).unwrap_or_default();
        assert!(
            events.contains("worktree_build_cache_skip"),
            "expected skip event"
        );
    }

    /// Skips gracefully when sccache binary path doesn't exist on disk.
    #[test]
    fn test_skip_when_sccache_binary_absent() {
        let repo_dir = TempDir::new().unwrap();
        let wt_dir = TempDir::new().unwrap();

        let host_cargo = repo_dir.path().join(".cargo");
        std::fs::create_dir_all(&host_cargo).unwrap();
        // Point to a non-existent sccache binary.
        fs::write(
            host_cargo.join("config.toml"),
            make_host_config("/nonexistent/path/sccache"),
        )
        .unwrap();

        let ambient_log = repo_dir.path().join(".chump-locks/ambient.jsonl");
        let outcome = provision_worktree_build_cache(
            repo_dir.path(),
            wt_dir.path(),
            "INFRA-2183",
            &ambient_log,
        );

        assert!(matches!(outcome, Outcome::Skipped { .. }));
        let events = fs::read_to_string(&ambient_log).unwrap_or_default();
        assert!(events.contains("worktree_build_cache_skip"));
    }

    /// CHUMP_WORKTREE_BUILD_CACHE_DISABLED=1 exits early without writing any files.
    #[test]
    fn test_env_skip_override() {
        // Hold ENV_MUTEX for the duration so set_var + remove_var don't race
        // with test_provision_creates_cargo_config.
        let _env_guard = ENV_MUTEX.lock().unwrap();

        let repo_dir = TempDir::new().unwrap();
        let wt_dir = TempDir::new().unwrap();
        let ambient_log = repo_dir.path().join(".chump-locks/ambient.jsonl");

        std::env::set_var("CHUMP_WORKTREE_BUILD_CACHE_DISABLED", "1");
        let outcome = provision_worktree_build_cache(
            repo_dir.path(),
            wt_dir.path(),
            "INFRA-2183",
            &ambient_log,
        );
        std::env::remove_var("CHUMP_WORKTREE_BUILD_CACHE_DISABLED");

        assert!(matches!(outcome, Outcome::Skipped { reason } if reason.contains("SKIP=1")));
        assert!(
            !wt_dir.path().join(".cargo/config.toml").exists(),
            "no file should be written"
        );
    }

    /// extract_rustc_wrapper parses the wrapper path correctly.
    #[test]
    fn test_extract_rustc_wrapper() {
        let config = "# comment\n[build]\nrustc-wrapper = \"/opt/homebrew/bin/sccache\"\n";
        assert_eq!(
            extract_rustc_wrapper(config),
            Some("/opt/homebrew/bin/sccache".to_string())
        );

        let no_wrapper = "[build]\ntarget-dir = \"/foo\"\n";
        assert_eq!(extract_rustc_wrapper(no_wrapper), None);
    }

    /// build_worktree_config removes shared target-dir and injects per-worktree one.
    #[test]
    fn test_build_worktree_config_replaces_target_dir() {
        let host = "# comment\n[build]\ntarget-dir = \"/shared/target\"\nrustc-wrapper = \"/usr/bin/sccache\"\n\n[env]\nFOO = \"bar\"\n";
        let target = PathBuf::from("/tmp/chump-infra-2183/target");
        let result = build_worktree_config(host, "/usr/bin/sccache", &target);

        assert!(
            !result.contains("/shared/target"),
            "shared target-dir must be removed"
        );
        assert!(
            result.contains("/tmp/chump-infra-2183/target"),
            "per-worktree target-dir must be present"
        );
        assert!(
            result.contains("rustc-wrapper"),
            "rustc-wrapper must be preserved"
        );
        // [env] section in fixture has FOO=bar, not SCCACHE_CACHE_SIZE — check it's preserved.
        assert!(
            result.contains("[env]") && result.contains("FOO"),
            "[env] section must be preserved"
        );
    }
}
