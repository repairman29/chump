use crate::backend::Schedule;
use anyhow::{bail, Result};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    User,
    System,
}

impl Scope {
    pub fn as_str(&self) -> &'static str {
        match self {
            Scope::User => "user",
            Scope::System => "system",
        }
    }
}

#[derive(Debug, Clone)]
pub struct CronSpec {
    pub name: String,
    pub schedule: Schedule,
    pub exec_argv: Vec<String>,
    pub description: Option<String>,
    pub working_dir: Option<String>,
    pub env: Vec<(String, String)>,
    pub stdout_log: Option<String>,
    pub stderr_log: Option<String>,
    pub scope: Scope,
}

impl CronSpec {
    pub fn label(&self) -> String {
        format!("com.chump.{}", self.name)
    }

    /// Sanitize `--name`: com.chump.* label space only, no path traversal.
    pub fn validate_name(name: &str) -> Result<()> {
        if name.is_empty() {
            bail!("--name must not be empty");
        }
        if !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
        {
            bail!("--name must be alphanumeric plus '-', '_', '.' (got '{name}')");
        }
        if name.starts_with('.') || name.contains("..") {
            bail!("--name must not start with '.' or contain '..' (got '{name}')");
        }
        Ok(())
    }

    pub fn launchd_plist_path(&self, home: &str) -> PathBuf {
        match self.scope {
            Scope::User => {
                PathBuf::from(home).join(format!("Library/LaunchAgents/{}.plist", self.label()))
            }
            Scope::System => {
                PathBuf::from(format!("/Library/LaunchDaemons/{}.plist", self.label()))
            }
        }
    }

    pub fn systemd_unit_dir(&self, home: &str) -> PathBuf {
        PathBuf::from(home).join(".config/systemd/user")
    }

    pub fn systemd_service_name(&self) -> String {
        format!("chump-{}.service", self.name)
    }

    pub fn systemd_timer_name(&self) -> String {
        format!("chump-{}.timer", self.name)
    }
}

/// Split a shell-ish command string into argv, honoring single/double
/// quotes. No variable expansion, no globbing — deliberately minimal.
pub fn split_argv(cmd: &str) -> Result<Vec<String>> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_single = false;
    let mut in_double = false;
    let mut has_content = false;
    let mut chars = cmd.chars().peekable();

    while let Some(c) = chars.next() {
        match c {
            '\'' if !in_double => {
                in_single = !in_single;
                has_content = true;
            }
            '"' if !in_single => {
                in_double = !in_double;
                has_content = true;
            }
            '\\' if in_double || !in_single => {
                if let Some(next) = chars.next() {
                    cur.push(next);
                    has_content = true;
                }
            }
            c if c.is_whitespace() && !in_single && !in_double => {
                if has_content {
                    out.push(std::mem::take(&mut cur));
                    has_content = false;
                }
            }
            c => {
                cur.push(c);
                has_content = true;
            }
        }
    }
    if in_single || in_double {
        bail!("unterminated quote in --exec command: '{cmd}'");
    }
    if has_content {
        out.push(cur);
    }
    if out.is_empty() {
        bail!("--exec must not be empty");
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_name_accepts_normal_names() {
        assert!(CronSpec::validate_name("gap-gardener").is_ok());
        assert!(CronSpec::validate_name("prune_worktrees.v2").is_ok());
    }

    #[test]
    fn validate_name_rejects_traversal() {
        assert!(CronSpec::validate_name("../etc/passwd").is_err());
        assert!(CronSpec::validate_name("").is_err());
        assert!(CronSpec::validate_name(".hidden").is_err());
        assert!(CronSpec::validate_name("com/chump").is_err());
    }

    #[test]
    fn split_argv_handles_quotes() {
        let argv = split_argv("bash -c 'echo hello world'").unwrap();
        assert_eq!(argv, vec!["bash", "-c", "echo hello world"]);
    }

    #[test]
    fn split_argv_handles_double_quotes_and_plain() {
        let argv = split_argv("/usr/bin/python3 script.py --flag \"a b\"").unwrap();
        assert_eq!(argv, vec!["/usr/bin/python3", "script.py", "--flag", "a b"]);
    }

    #[test]
    fn split_argv_rejects_unterminated_quote() {
        assert!(split_argv("echo 'unterminated").is_err());
    }
}
