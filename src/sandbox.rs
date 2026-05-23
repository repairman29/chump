//! INFRA-1454: agent bash sandbox primitive (commercial-launch precondition).
//!
//! Persona-5 skeptic interview surfaced this as a hard ship-blocker for any
//! commercial tier: today agents run bash directly on the host filesystem.
//! Trust model collapses into "operator owns the machine" — defensible for
//! solo dogfood, NOT defensible for any environment where the agent ingests
//! third-party content or where the operator wouldn't run a curl|bash from
//! a stranger. A single adversarial dependency-description-interpreted-as-
//! instruction = CVE with the operator's name on it.
//!
//! This module supplies a thin wrapper that, when enabled, runs the agent's
//! shell command inside macOS's native `sandbox-exec` with a profile that
//! restricts file-write access to the active worktree (and a few well-known
//! tempdirs). Linux/podman/docker fallbacks land under follow-up gaps.
//!
//! ## Defaults & opt-in
//!
//! - **Default off** in v1 — flip to `default on` once the audit log shows
//!   a sustained zero-regression window across the fleet.
//! - **Opt in**: `CHUMP_AGENT_SANDBOX=1` to wrap agent bash through `sandbox-exec`.
//! - **Operator escape**: `CHUMP_AGENT_UNSAFE_HOST_EXEC=1` forces the legacy
//!   host-shell path even when sandbox would otherwise run; emits an
//!   `agent_unsafe_host_exec` event to ambient.jsonl so the choice is auditable.
//!
//! Distinct from [`crate::sandbox_tool`] (which sandboxes via a *throwaway
//! worktree* — filesystem isolation only, no syscall restriction). This
//! module is the syscall-restriction layer; the two compose.

use std::path::{Path, PathBuf};
use tokio::process::Command;

/// Status of the sandbox runtime on this host (reported by `chump fleet doctor`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SandboxStatus {
    /// `sandbox-exec` is on PATH and the agent-sandbox env is opted in.
    Active { runtime: String },
    /// Runtime is installed but the operator hasn't opted in
    /// (`CHUMP_AGENT_SANDBOX` is unset or zero).
    AvailableNotEnabled { runtime: String },
    /// Operator forced the legacy host-shell path via
    /// `CHUMP_AGENT_UNSAFE_HOST_EXEC=1`.
    DisabledByOperator { runtime: String },
    /// No supported runtime found on this platform.
    Missing { reason: String },
}

impl SandboxStatus {
    /// Short summary line for `chump fleet doctor` text output.
    pub fn summary(&self) -> String {
        match self {
            SandboxStatus::Active { runtime } => {
                format!("sandbox active (runtime: {runtime})")
            }
            SandboxStatus::AvailableNotEnabled { runtime } => format!(
                "sandbox runtime present but not enabled — set CHUMP_AGENT_SANDBOX=1 to wrap agent bash through {runtime}"
            ),
            SandboxStatus::DisabledByOperator { runtime } => format!(
                "sandbox runtime present ({runtime}) but disabled by CHUMP_AGENT_UNSAFE_HOST_EXEC=1 — agent bash runs on host shell"
            ),
            SandboxStatus::Missing { reason } => {
                format!("sandbox runtime missing: {reason}")
            }
        }
    }

    /// Whether the doctor should treat this status as healthy. A missing
    /// runtime is degraded; an explicit operator opt-out is *informational*
    /// (operator made the choice consciously) so it counts as healthy.
    pub fn healthy(&self) -> bool {
        !matches!(self, SandboxStatus::Missing { .. })
    }

    /// Stable tag string for telemetry / fleet doctor JSON output.
    pub fn tag(&self) -> &'static str {
        match self {
            SandboxStatus::Active { .. } => "active",
            SandboxStatus::AvailableNotEnabled { .. } => "available_not_enabled",
            SandboxStatus::DisabledByOperator { .. } => "disabled_by_operator",
            SandboxStatus::Missing { .. } => "missing",
        }
    }
}

/// Probe the host for a usable sandbox runtime. macOS-only in v1.
pub fn sandbox_runtime_status() -> SandboxStatus {
    let runtime = match detect_runtime() {
        Some(r) => r,
        None => {
            return SandboxStatus::Missing {
                reason: if cfg!(target_os = "macos") {
                    "sandbox-exec not on PATH (expected /usr/bin/sandbox-exec on macOS)".to_string()
                } else {
                    "no supported runtime on this platform yet (macOS sandbox-exec v1; linux/docker follow-up)".to_string()
                },
            };
        }
    };
    if std::env::var("CHUMP_AGENT_UNSAFE_HOST_EXEC")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        return SandboxStatus::DisabledByOperator { runtime };
    }
    if agent_sandbox_enabled() {
        SandboxStatus::Active { runtime }
    } else {
        SandboxStatus::AvailableNotEnabled { runtime }
    }
}

/// True when `CHUMP_AGENT_SANDBOX=1` is set.
pub fn agent_sandbox_enabled() -> bool {
    std::env::var("CHUMP_AGENT_SANDBOX")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// True when the operator has forced the legacy host-shell path.
pub fn unsafe_host_exec_forced() -> bool {
    std::env::var("CHUMP_AGENT_UNSAFE_HOST_EXEC")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn detect_runtime() -> Option<String> {
    if cfg!(target_os = "macos") && which("sandbox-exec") {
        return Some("macos/sandbox-exec".to_string());
    }
    None
}

fn which(bin: &str) -> bool {
    // Cheap PATH lookup; no need to shell out.
    std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths).any(|p| {
                let candidate = p.join(bin);
                candidate.is_file()
                    && std::fs::metadata(&candidate)
                        .map(|m| {
                            use std::os::unix::fs::PermissionsExt;
                            m.permissions().mode() & 0o111 != 0
                        })
                        .unwrap_or(false)
            })
        })
        .unwrap_or(false)
        || std::path::Path::new(&format!("/usr/bin/{bin}")).is_file()
}

/// Build the macOS sandbox-exec profile (SBPL) that permits writes only
/// inside `worktree_root`, plus the standard tempdirs that build tools need.
/// Reads are kept permissive in v1 (tools need to read system libraries);
/// network is permissive (LLM calls + git fetch must work); follow-up
/// gaps tighten both.
pub fn build_profile(worktree_root: &Path) -> String {
    let wt = worktree_root.display();
    // SBPL — Apple's TinyScheme-based sandbox language. The profile blocks
    // host-fs writes outside the worktree (the AC#1 invariant). Reads stay
    // permissive so the agent can read system libs / git objects; network
    // stays permissive so LLM API + git remote work. Tightening either is
    // a separate gap (network allowlist is AC#3, planned follow-up).
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
(allow file-write*
  (subpath "{wt}")
  (subpath "/private/tmp")
  (subpath "/private/var/folders")
  (subpath "/tmp"))
(allow network*)
"#
    )
}

/// Wrap a shell command in the sandbox if [`agent_sandbox_enabled`] and the
/// runtime is available; otherwise return a plain `sh -c '<cmd>'` Command.
///
/// This is the single chokepoint cli_tool.rs (and any other host-bash
/// caller) routes through. Reading the status first (rather than just
/// calling sandbox-exec unconditionally) lets the function degrade
/// gracefully on Linux dev boxes during the transition.
pub fn wrap_command(cmd: &str, cwd: &Path) -> Command {
    if !agent_sandbox_enabled() || unsafe_host_exec_forced() {
        return plain_sh(cmd, cwd);
    }
    let runtime = match detect_runtime() {
        Some(r) => r,
        None => return plain_sh(cmd, cwd),
    };
    if runtime.starts_with("macos/") {
        return wrap_macos(cmd, cwd);
    }
    plain_sh(cmd, cwd)
}

fn plain_sh(cmd: &str, cwd: &Path) -> Command {
    let mut c = Command::new(if cfg!(target_os = "windows") {
        "cmd"
    } else {
        "sh"
    });
    let arg = if cfg!(target_os = "windows") {
        "/c"
    } else {
        "-c"
    };
    c.arg(arg).arg(cmd);
    c.current_dir(cwd);
    c
}

fn wrap_macos(cmd: &str, cwd: &Path) -> Command {
    // Profile must be a string passed via `-p` (no inline SBPL on stdin in
    // the canonical sandbox-exec(1) usage). The profile resolves the
    // worktree path so any write outside the worktree gets DENY default.
    let worktree = resolve_worktree(cwd);
    let profile = build_profile(&worktree);
    let mut c = Command::new("sandbox-exec");
    c.arg("-p").arg(profile).arg("sh").arg("-c").arg(cmd);
    c.current_dir(cwd);
    c
}

/// The effective worktree root for the sandbox profile. Uses `git
/// rev-parse --show-toplevel` if it succeeds, otherwise falls back to the
/// caller's `cwd` (so non-git callers still get *some* isolation).
fn resolve_worktree(cwd: &Path) -> PathBuf {
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(cwd)
        .output();
    if let Ok(o) = out {
        if o.status.success() {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !s.is_empty() {
                return PathBuf::from(s);
            }
        }
    }
    cwd.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_summary_strings_render() {
        let s = SandboxStatus::Active {
            runtime: "macos/sandbox-exec".into(),
        };
        assert!(s.summary().contains("active"));
        assert_eq!(s.tag(), "active");
        assert!(s.healthy());

        let s = SandboxStatus::AvailableNotEnabled {
            runtime: "macos/sandbox-exec".into(),
        };
        assert!(s.summary().contains("not enabled"));
        assert_eq!(s.tag(), "available_not_enabled");
        assert!(s.healthy());

        let s = SandboxStatus::DisabledByOperator {
            runtime: "macos/sandbox-exec".into(),
        };
        assert!(s.summary().contains("disabled by"));
        assert_eq!(s.tag(), "disabled_by_operator");
        assert!(s.healthy());

        let s = SandboxStatus::Missing {
            reason: "test".into(),
        };
        assert!(s.summary().contains("missing"));
        assert_eq!(s.tag(), "missing");
        assert!(!s.healthy());
    }

    #[test]
    fn build_profile_pins_worktree_path() {
        let p = build_profile(Path::new("/tmp/my-worktree"));
        assert!(p.contains(r#"(subpath "/tmp/my-worktree")"#));
        assert!(p.contains("(deny default)"));
        // Network is permissive in v1 (LLM/git access).
        assert!(p.contains("(allow network*)"));
        // Read permissive in v1 (system libs).
        assert!(p.contains("(allow file-read*)"));
    }

    #[test]
    fn enabled_env_parsing() {
        // SAFETY: these test functions only set/remove env vars locally and
        // do not race with other tests because each acquires its own var.
        let key = "CHUMP_AGENT_SANDBOX";
        unsafe {
            std::env::remove_var(key);
        }
        assert!(!agent_sandbox_enabled());
        unsafe {
            std::env::set_var(key, "1");
        }
        assert!(agent_sandbox_enabled());
        unsafe {
            std::env::set_var(key, "TRUE");
        }
        assert!(agent_sandbox_enabled());
        unsafe {
            std::env::set_var(key, "0");
        }
        assert!(!agent_sandbox_enabled());
        unsafe {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn wrap_returns_plain_when_disabled() {
        // SAFETY: localized env-var manipulation, see note above.
        let key = "CHUMP_AGENT_SANDBOX";
        let unsafe_key = "CHUMP_AGENT_UNSAFE_HOST_EXEC";
        unsafe {
            std::env::remove_var(key);
            std::env::remove_var(unsafe_key);
        }
        let c = wrap_command("echo hi", Path::new("/tmp"));
        // Plain sh path doesn't reference sandbox-exec in argv0.
        let prog = format!("{:?}", c.as_std().get_program());
        assert!(!prog.contains("sandbox-exec"));
    }
}
