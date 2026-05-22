//! INFRA-1700: Content Bots toggle resolver.
//!
//! Computes the set of enabled content-bot IDs from two sources, in
//! precedence order:
//!
//!   1. `CHUMP_CONTENT_BOTS` env var — comma-separated bot_ids (highest)
//!   2. `.chump-config.toml` `[content_bots] enabled = [...]` array
//!   3. Empty set — default-off-on-missing (foundation invariant)
//!
//! Both sources are tolerated when missing or malformed; the resolver never
//! panics. A malformed `.chump-config.toml` is logged via `eprintln!` (debug
//! tier) and treated as absent.
//!
//! This module ships INFRA-1700 (narrow phase of INFRA-1696 under the
//! META-066 Content Bots Suite productization). The CLI subcommand
//! `chump content-bots list` that surfaces this set to operators is a
//! separate follow-up gap.

use std::collections::BTreeSet;
use std::path::Path;

/// Resolve the set of enabled content-bot IDs for the given repo.
///
/// Resolution precedence:
///   1. `CHUMP_CONTENT_BOTS` env (csv) — highest precedence; empty string
///      explicitly disables all (returns empty set)
///   2. `<repo_root>/.chump-config.toml` `[content_bots] enabled = [...]`
///   3. Empty set (no enabled bots — foundation default)
///
/// Tolerant: missing config file, missing `[content_bots]` section, and
/// malformed TOML all return an empty set rather than panicking.
pub fn enabled_set(repo_root: &Path) -> BTreeSet<String> {
    // 1. Env var takes precedence (set or empty-set).
    if let Ok(raw) = std::env::var("CHUMP_CONTENT_BOTS") {
        return raw
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
    }

    // 2. .chump-config.toml fallback.
    let cfg_path = repo_root.join(".chump-config.toml");
    if !cfg_path.exists() {
        return BTreeSet::new();
    }
    let raw = match std::fs::read_to_string(&cfg_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[content_bots] WARN: cannot read {} — treating as no-config: {e}",
                cfg_path.display()
            );
            return BTreeSet::new();
        }
    };
    let parsed: toml::Table = match toml::from_str(&raw) {
        Ok(t) => t,
        Err(e) => {
            eprintln!(
                "[content_bots] WARN: malformed .chump-config.toml — treating as no-config: {e}"
            );
            return BTreeSet::new();
        }
    };
    let Some(toml::Value::Table(section)) = parsed.get("content_bots").cloned() else {
        return BTreeSet::new();
    };
    let Some(toml::Value::Array(list)) = section.get("enabled").cloned() else {
        return BTreeSet::new();
    };
    list.into_iter()
        .filter_map(|v| match v {
            toml::Value::String(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// Guard for env-var mutation: only one test may touch the env at a time
    /// because cargo runs tests in parallel and `std::env` is process-wide.
    /// Each test takes this lock before mutating `CHUMP_CONTENT_BOTS`.
    static ENV_GUARD: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn with_env<F: FnOnce() -> R, R>(value: Option<&str>, body: F) -> R {
        let _g = ENV_GUARD.lock().unwrap();
        match value {
            Some(v) => std::env::set_var("CHUMP_CONTENT_BOTS", v),
            None => std::env::remove_var("CHUMP_CONTENT_BOTS"),
        }
        let r = body();
        std::env::remove_var("CHUMP_CONTENT_BOTS");
        r
    }

    #[test]
    fn env_csv_sets_the_enabled_list() {
        let dir = TempDir::new().unwrap();
        let got = with_env(Some("pmm,docubot"), || enabled_set(dir.path()));
        let want: BTreeSet<String> = ["pmm", "docubot"].iter().map(|s| s.to_string()).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn env_empty_string_explicitly_disables_all() {
        let dir = TempDir::new().unwrap();
        let got = with_env(Some(""), || enabled_set(dir.path()));
        assert!(got.is_empty());
    }

    #[test]
    fn env_overrides_toml_even_when_both_present() {
        let dir = TempDir::new().unwrap();
        std::fs::write(
            dir.path().join(".chump-config.toml"),
            "[content_bots]\nenabled = [\"copybot\"]\n",
        )
        .unwrap();
        let got = with_env(Some("pmm,evangelist"), || enabled_set(dir.path()));
        let want: BTreeSet<String> = ["pmm", "evangelist"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(got, want);
    }

    #[test]
    fn toml_only_when_env_unset() {
        let dir = TempDir::new().unwrap();
        std::fs::write(
            dir.path().join(".chump-config.toml"),
            "[content_bots]\nenabled = [\"docubot\", \"evangelist\"]\n",
        )
        .unwrap();
        let got = with_env(None, || enabled_set(dir.path()));
        let want: BTreeSet<String> = ["docubot", "evangelist"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(got, want);
    }

    #[test]
    fn missing_config_and_env_returns_empty() {
        let dir = TempDir::new().unwrap();
        let got = with_env(None, || enabled_set(dir.path()));
        assert!(got.is_empty());
    }

    #[test]
    fn malformed_toml_tolerated() {
        let dir = TempDir::new().unwrap();
        std::fs::write(dir.path().join(".chump-config.toml"), "this = is = bad").unwrap();
        let got = with_env(None, || enabled_set(dir.path()));
        assert!(got.is_empty());
    }

    #[test]
    fn missing_content_bots_section_returns_empty() {
        let dir = TempDir::new().unwrap();
        std::fs::write(
            dir.path().join(".chump-config.toml"),
            "[some_other_section]\nfoo = \"bar\"\n",
        )
        .unwrap();
        let got = with_env(None, || enabled_set(dir.path()));
        assert!(got.is_empty());
    }

    #[test]
    fn enabled_array_skips_non_string_and_empty_entries() {
        let dir = TempDir::new().unwrap();
        std::fs::write(
            dir.path().join(".chump-config.toml"),
            "[content_bots]\nenabled = [\"pmm\", \"\", \"docubot\"]\n",
        )
        .unwrap();
        let got = with_env(None, || enabled_set(dir.path()));
        let want: BTreeSet<String> = ["pmm", "docubot"].iter().map(|s| s.to_string()).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn whitespace_in_env_csv_trimmed() {
        let dir = TempDir::new().unwrap();
        let got = with_env(Some(" pmm , docubot ,  ,evangelist"), || {
            enabled_set(dir.path())
        });
        let want: BTreeSet<String> = ["pmm", "docubot", "evangelist"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(got, want);
    }
}
