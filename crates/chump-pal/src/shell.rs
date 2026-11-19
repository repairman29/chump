//! Cross-platform shell command builders (`sh -c` on Unix, `cmd /C` and
//! `pwsh` / `powershell` helper on Windows).

use std::path::PathBuf;
use std::process::Command;

/// Build a platform shell [`Command`] executing `script` (`sh -c` on Unix,
/// `cmd /C` on Windows).
pub fn shell_command(script: &str) -> Command {
    #[cfg(unix)]
    {
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg(script);
        cmd
    }

    #[cfg(windows)]
    {
        let mut cmd = Command::new("cmd");
        cmd.arg("/C").arg(script);
        cmd
    }
}

fn find_in_path(candidates: &[&str]) -> Option<PathBuf> {
    let path_os = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_os) {
        for cand in candidates {
            let full = dir.join(cand);
            if full.is_file() {
                return Some(full);
            }
        }
    }
    None
}

/// Build a PowerShell [`Command`] (`pwsh` or `powershell` with
/// `-NoProfile -NonInteractive -Command`) when available on `PATH`, falling back
/// to [`shell_command`] (`cmd /C` on Windows, `sh -c` on Unix).
pub fn pwsh_or_cmd(script: &str) -> Command {
    #[cfg(windows)]
    let candidates: &[&str] = &["pwsh.exe", "powershell.exe"];
    #[cfg(not(windows))]
    let candidates: &[&str] = &["pwsh"];

    if let Some(ps) = find_in_path(candidates) {
        let mut cmd = Command::new(ps);
        cmd.args(["-NoProfile", "-NonInteractive", "-Command", script]);
        return cmd;
    }

    #[cfg(windows)]
    if let Ok(sysroot) = std::env::var("SystemRoot") {
        let builtin = PathBuf::from(sysroot)
            .join("System32")
            .join("WindowsPowerShell")
            .join("v1.0")
            .join("powershell.exe");
        if builtin.is_file() {
            let mut cmd = Command::new(builtin);
            cmd.args(["-NoProfile", "-NonInteractive", "-Command", script]);
            return cmd;
        }
    }

    shell_command(script)
}
