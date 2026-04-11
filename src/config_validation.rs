//! Startup config validation: report what's enabled and what's missing so there's no silent misconfiguration.
//! Log to stderr and chump.log. Call after load_dotenv() in main and at start of Discord run().

use std::path::PathBuf;

use crate::chump_log;
use crate::env_flags;
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

/// True when `DISCORD_TOKEN` is a non-empty, non-placeholder value (real Discord bot use).
pub(crate) fn discord_token_effective(raw: &str) -> bool {
    let t = raw.trim();
    !t.is_empty() && !is_discord_token_placeholder(t)
}

fn is_discord_token_placeholder(t: &str) -> bool {
    let lower = t.to_lowercase();
    lower == "your-bot-token-here"
        || lower.contains("your-bot-token")
        || lower == "replace_me"
        || lower == "changeme"
}

/// Validate config and log enabled features plus warnings to stderr and chump.log.
/// Call after load_dotenv() and before entering --discord / --chump paths.
pub fn validate_config() {
    let mut enabled: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();

    let discord_raw = std::env::var("DISCORD_TOKEN").unwrap_or_default();
    if discord_token_effective(&discord_raw) {
        enabled.push("discord".to_string());
    } else {
        if !discord_raw.trim().is_empty() && is_discord_token_placeholder(discord_raw.trim()) {
            warnings.push(
                "DISCORD_TOKEN looks like a placeholder from .env.example — set a real token or clear for web-only"
                    .to_string(),
            );
        } else {
            warnings.push("DISCORD_TOKEN not set or empty (Discord mode disabled)".to_string());
        }
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
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false);
        let repos_empty = std::env::var("CHUMP_GITHUB_REPOS")
            .map(|s| s.trim().is_empty())
            .unwrap_or(true);
        if has_token && repos_empty {
            warnings.push("GITHUB_TOKEN set but CHUMP_GITHUB_REPOS empty — add repo(s) to enable GitHub tools".to_string());
        }
    }
    if gh_tools::gh_tools_enabled() {
        enabled.push("gh_tools".to_string());
    }
    if env_flags::chump_air_gap_mode() {
        enabled.push("air_gap_mode".to_string());
        if tavily_tool::tavily_enabled() {
            warnings.push(
                "CHUMP_AIR_GAP_MODE=1: web_search and read_url are not registered; TAVILY_API_KEY has no effect on tools"
                    .to_string(),
            );
        }
    } else if tavily_tool::tavily_enabled() {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discord_token_effective_realistic_shape() {
        assert!(discord_token_effective(
            "MTIz456789012345678901234567890.AbcDef.ghijklmnopqrstuvwxyz12"
        ));
    }

    #[test]
    fn discord_token_placeholder_rejected() {
        assert!(!discord_token_effective("your-bot-token-here"));
        assert!(!discord_token_effective("  your-bot-token-here  "));
        assert!(!discord_token_effective("REPLACE_ME"));
        assert!(!discord_token_effective(""));
    }

    #[test]
    fn discord_token_placeholder_detection() {
        assert!(is_discord_token_placeholder("your-bot-token-here"));
        assert!(is_discord_token_placeholder("prefix-your-bot-token-suffix"));
    }
}
