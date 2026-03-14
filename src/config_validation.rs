//! Startup config validation: report what's enabled and what's missing so there's no silent misconfiguration.
//! Log to stderr and chump.log. Call after load_dotenv() in main and at start of Discord run().

use std::path::PathBuf;

use crate::chump_log;
use crate::gh_tools;
use crate::github_tools;
use crate::repo_path;
use crate::tavily_tool;

fn brain_root_ok() -> bool {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let base = repo_path::runtime_base();
    let path = if PathBuf::from(&root).is_absolute() {
        PathBuf::from(root)
    } else {
        base.join(root)
    };
    path.is_dir()
}

fn executive_mode() -> bool {
    std::env::var("CHUMP_EXECUTIVE_MODE")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Validate config and log enabled features plus warnings to stderr and chump.log.
/// Call after load_dotenv() and before entering --discord / --chump paths.
pub fn validate_config() {
    let mut enabled: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();

    if std::env::var("DISCORD_TOKEN")
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
    {
        enabled.push("discord".to_string());
    } else {
        warnings.push("DISCORD_TOKEN not set or empty (Discord mode disabled)".to_string());
    }

    if repo_path::repo_root_is_explicit() {
        let root = repo_path::repo_root();
        if root.is_dir() {
            enabled.push(format!("repo_root={}", root.display()));
        } else {
            warnings.push(format!(
                "CHUMP_REPO/CHUMP_HOME set but path is not a dir: {}",
                root.display()
            ));
        }
    } else {
        enabled.push("repo_root=cwd".to_string());
    }

    if github_tools::github_enabled() {
        enabled.push("github_tools".to_string());
    } else {
        let has_token = std::env::var("GITHUB_TOKEN")
            .or_else(|_| std::env::var("CHUMP_GITHUB_TOKEN"))
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false);
        let repos_empty = std::env::var("CHUMP_GITHUB_REPOS")
            .map(|s| s.trim().is_empty())
            .unwrap_or(true);
        if has_token && repos_empty {
            warnings.push("GITHUB_TOKEN (or CHUMP_GITHUB_TOKEN) set but CHUMP_GITHUB_REPOS empty — add repo(s) to enable GitHub tools".to_string());
        }
    }
    if gh_tools::gh_tools_enabled() {
        enabled.push("gh_tools".to_string());
    }
    if tavily_tool::tavily_enabled() {
        enabled.push("tavily".to_string());
    }
    if brain_root_ok() {
        enabled.push("brain".to_string());
    } else {
        warnings
            .push("CHUMP_BRAIN_PATH missing or not a directory (brain tools disabled)".to_string());
    }
    if executive_mode() {
        enabled.push("executive_mode".to_string());
    }

    chump_log::log_config_summary(&enabled, &warnings);

    for w in &warnings {
        eprintln!("chump config warning: {}", w);
    }
    eprintln!("chump config: enabled=[{}]", enabled.join(", "));
}
