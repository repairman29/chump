//! MCP server discovery: scan PATH, user-config dir, and well-known system locations
//! for `chump-mcp-*` binaries and report them grouped by source.
//!
//! This module is intentionally free of I/O side-effects at the module level —
//! all discovery is triggered by calling [`discover_mcp_servers`] explicitly.
//! No globals, no startup scanning. The results are used by `chump mcp list`
//! and (eventually) `chump mcp enable`.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Where a discovered MCP server binary was found.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum McpSource {
    /// Found in a directory listed in `$PATH`.
    Path,
    /// Found in `~/.config/chump/mcp-servers/`.
    UserConfig,
    /// Found in a well-known system location (`/usr/local/lib/mcp-servers/` or `/usr/local/bin/`).
    System,
}

impl McpSource {
    pub fn label(&self) -> &'static str {
        match self {
            McpSource::Path => "PATH",
            McpSource::UserConfig => "user-config",
            McpSource::System => "system",
        }
    }
}

/// A discovered MCP server binary.
#[derive(Debug, Clone)]
pub struct McpServerInfo {
    /// Short name extracted from the binary, e.g. `"github"` from `chump-mcp-github`.
    pub name: String,
    /// Full path to the binary.
    pub path: PathBuf,
    /// Where this binary was found.
    pub source: McpSource,
}

impl McpServerInfo {
    /// Extract the human-readable server name from a `chump-mcp-<name>` binary filename.
    /// Returns `None` if the filename doesn't match the expected prefix.
    pub fn name_from_binary(filename: &str) -> Option<String> {
        let stem = filename
            .strip_prefix("chump-mcp-")
            .or_else(|| filename.strip_prefix("chump-mcp-"))?;
        if stem.is_empty() {
            return None;
        }
        Some(stem.to_string())
    }
}

/// Directories to scan for well-known system MCP server locations.
const SYSTEM_DIRS: &[&str] = &["/usr/local/lib/mcp-servers", "/usr/local/bin"];

/// Scan a single directory for `chump-mcp-*` executables and append any found
/// to `results`. Tracks `seen_paths` to avoid duplicates across overlapping
/// directories.
fn scan_dir(
    dir: &Path,
    source: McpSource,
    seen_paths: &mut HashSet<PathBuf>,
    results: &mut Vec<McpServerInfo>,
) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let filename = entry.file_name().to_string_lossy().to_string();

        // Must match chump-mcp-<name> pattern and be a file
        if !filename.starts_with("chump-mcp-") || !path.is_file() {
            continue;
        }

        // Must be executable
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(meta) = std::fs::metadata(&path) {
                if meta.permissions().mode() & 0o111 == 0 {
                    continue;
                }
            }
        }

        // Deduplicate by canonical path
        let canonical = path.canonicalize().unwrap_or_else(|_| path.clone());
        if seen_paths.contains(&canonical) {
            continue;
        }
        seen_paths.insert(canonical);

        if let Some(name) = McpServerInfo::name_from_binary(&filename) {
            results.push(McpServerInfo {
                name,
                path: path.clone(),
                source: source.clone(),
            });
        }
    }
}

/// Returns the user-config MCP server directory: `~/.config/chump/mcp-servers/`.
/// Respects `$XDG_CONFIG_HOME` if set.
pub fn user_config_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        let p = PathBuf::from(xdg).join("chump").join("mcp-servers");
        return p;
    }
    dirs_home()
        .map(|h| h.join(".config").join("chump").join("mcp-servers"))
        .unwrap_or_else(|| PathBuf::from("~/.config/chump/mcp-servers"))
}

/// Cross-platform home directory via `$HOME`.
fn dirs_home() -> Option<PathBuf> {
    std::env::var("HOME").ok().map(PathBuf::from)
}

/// Discover all installed MCP servers by scanning:
/// 1. Directories in `$PATH` — tagged as [`McpSource::Path`]
/// 2. `~/.config/chump/mcp-servers/` — tagged as [`McpSource::UserConfig`]
/// 3. Well-known system locations — tagged as [`McpSource::System`]
///
/// Results are returned in source priority order (PATH first, then UserConfig, then System).
/// Within each source, binaries are ordered by filename.
/// Duplicates (same canonical path) are suppressed.
pub fn discover_mcp_servers() -> Vec<McpServerInfo> {
    let mut results: Vec<McpServerInfo> = Vec::new();
    let mut seen: HashSet<PathBuf> = HashSet::new();

    // 1. PATH
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_var) {
            scan_dir(&dir, McpSource::Path, &mut seen, &mut results);
        }
    }

    // 2. User config dir
    let user_dir = user_config_dir();
    scan_dir(&user_dir, McpSource::UserConfig, &mut seen, &mut results);

    // 3. Well-known system locations
    for dir in SYSTEM_DIRS {
        scan_dir(Path::new(dir), McpSource::System, &mut seen, &mut results);
    }

    // Sort within each source group by name for stable output
    results.sort_by(|a, b| a.source.cmp(&b.source).then_with(|| a.name.cmp(&b.name)));

    results
}

/// Print `chump mcp list` output to stdout. Groups servers by source.
pub fn print_mcp_list(servers: &[McpServerInfo]) {
    if servers.is_empty() {
        println!("No chump-mcp-* servers found.");
        println!();
        println!("Install a server binary (e.g. `cargo install chump-mcp-github`) and");
        println!("ensure it is on your PATH, or place it in ~/.config/chump/mcp-servers/");
        return;
    }

    // Group by source
    let sources = [McpSource::Path, McpSource::UserConfig, McpSource::System];
    let mut first_group = true;

    for source in &sources {
        let group: Vec<&McpServerInfo> = servers.iter().filter(|s| &s.source == source).collect();

        if group.is_empty() {
            continue;
        }

        if !first_group {
            println!();
        }
        first_group = false;

        println!("[{}]", source.label());
        for s in &group {
            println!("  {} ({})", s.name, s.path.display());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::TempDir;

    fn make_executable(path: &Path) {
        let mut perms = fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(path, perms).unwrap();
    }

    fn write_binary(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, b"#!/bin/sh\n").unwrap();
        make_executable(&path);
        path
    }

    // --- name_from_binary ---

    #[test]
    fn name_from_binary_happy_path() {
        assert_eq!(
            McpServerInfo::name_from_binary("chump-mcp-github"),
            Some("github".to_string())
        );
    }

    #[test]
    fn name_from_binary_multi_segment() {
        assert_eq!(
            McpServerInfo::name_from_binary("chump-mcp-my-tool"),
            Some("my-tool".to_string())
        );
    }

    #[test]
    fn name_from_binary_wrong_prefix() {
        assert_eq!(McpServerInfo::name_from_binary("other-binary"), None);
    }

    #[test]
    fn name_from_binary_exact_prefix_no_name() {
        assert_eq!(McpServerInfo::name_from_binary("chump-mcp-"), None);
    }

    // --- scan_dir ---

    #[test]
    fn scan_dir_finds_matching_executables() {
        let tmp = TempDir::new().unwrap();
        write_binary(tmp.path(), "chump-mcp-github");
        write_binary(tmp.path(), "chump-mcp-tavily");
        // Non-matching file — should be ignored
        let other = tmp.path().join("other-tool");
        fs::write(&other, b"#!/bin/sh\n").unwrap();

        let mut seen = HashSet::new();
        let mut results = Vec::new();
        scan_dir(tmp.path(), McpSource::Path, &mut seen, &mut results);

        assert_eq!(results.len(), 2);
        let names: Vec<&str> = results.iter().map(|r| r.name.as_str()).collect();
        assert!(names.contains(&"github"));
        assert!(names.contains(&"tavily"));
    }

    #[test]
    fn scan_dir_ignores_non_executable() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("chump-mcp-noexec");
        fs::write(&path, b"#!/bin/sh\n").unwrap();
        // Do NOT make executable — default permissions on Linux are 0o644

        let mut seen = HashSet::new();
        let mut results = Vec::new();
        scan_dir(tmp.path(), McpSource::Path, &mut seen, &mut results);

        assert_eq!(results.len(), 0, "non-executable should be skipped");
    }

    #[test]
    fn scan_dir_deduplicates_same_path() {
        let tmp = TempDir::new().unwrap();
        write_binary(tmp.path(), "chump-mcp-dup");

        let mut seen = HashSet::new();
        let mut results = Vec::new();
        // Scan the same dir twice
        scan_dir(tmp.path(), McpSource::Path, &mut seen, &mut results);
        scan_dir(tmp.path(), McpSource::UserConfig, &mut seen, &mut results);

        assert_eq!(
            results.len(),
            1,
            "duplicate canonical path should not appear twice"
        );
    }

    #[test]
    fn scan_dir_missing_dir_is_noop() {
        let mut seen = HashSet::new();
        let mut results = Vec::new();
        scan_dir(
            Path::new("/nonexistent/path/that/does/not/exist"),
            McpSource::System,
            &mut seen,
            &mut results,
        );
        assert!(results.is_empty());
    }

    // --- discover_mcp_servers with env overrides ---

    #[test]
    fn discover_finds_binaries_on_path() {
        let tmp = TempDir::new().unwrap();
        write_binary(tmp.path(), "chump-mcp-test-alpha");
        write_binary(tmp.path(), "chump-mcp-test-beta");

        // Override PATH to our tmp dir. We use a unique prefix (test-alpha, test-beta)
        // so that even if the real user-config dir has other chump-mcp-* binaries,
        // we can identify our specific test binaries among the results.
        let old_path = std::env::var("PATH").unwrap_or_default();
        let new_path = format!("{}:{}", tmp.path().display(), old_path);
        std::env::set_var("PATH", &new_path);

        let results = discover_mcp_servers();

        std::env::set_var("PATH", &old_path);

        // Check that our test binaries appear with the PATH source
        let path_results: Vec<&McpServerInfo> = results
            .iter()
            .filter(|r| r.source == McpSource::Path)
            .collect();
        let path_names: Vec<&str> = path_results.iter().map(|r| r.name.as_str()).collect();
        assert!(
            path_names.contains(&"test-alpha"),
            "test-alpha not found in PATH results, got: {:?}",
            path_names
        );
        assert!(
            path_names.contains(&"test-beta"),
            "test-beta not found in PATH results, got: {:?}",
            path_names
        );
    }

    #[test]
    fn discover_finds_user_config_binaries() {
        let tmp = TempDir::new().unwrap();
        let user_mcp_dir = tmp.path().join("chump").join("mcp-servers");
        fs::create_dir_all(&user_mcp_dir).unwrap();
        write_binary(&user_mcp_dir, "chump-mcp-user-server");

        std::env::set_var("XDG_CONFIG_HOME", tmp.path().as_os_str());
        // Clear PATH to avoid noise
        let old_path = std::env::var("PATH").unwrap_or_default();
        std::env::set_var("PATH", "");

        let results = discover_mcp_servers();

        std::env::set_var("PATH", &old_path);
        std::env::remove_var("XDG_CONFIG_HOME");

        let user_results: Vec<&McpServerInfo> = results
            .iter()
            .filter(|r| r.source == McpSource::UserConfig)
            .collect();
        assert_eq!(user_results.len(), 1);
        assert_eq!(user_results[0].name, "user-server");
    }

    #[test]
    fn results_are_sorted_by_source_then_name() {
        let tmp = TempDir::new().unwrap();
        // PATH dir with two binaries
        let path_dir = tmp.path().join("path");
        fs::create_dir_all(&path_dir).unwrap();
        write_binary(&path_dir, "chump-mcp-zzz");
        write_binary(&path_dir, "chump-mcp-aaa");

        let old_path = std::env::var("PATH").unwrap_or_default();
        std::env::set_var("PATH", path_dir.as_os_str());

        let results = discover_mcp_servers();

        std::env::set_var("PATH", &old_path);

        let path_results: Vec<&McpServerInfo> = results
            .iter()
            .filter(|r| r.source == McpSource::Path)
            .collect();
        assert!(
            path_results.len() >= 2,
            "expected at least 2 PATH results, got: {:?}",
            path_results.iter().map(|r| &r.name).collect::<Vec<_>>()
        );
        // Should be sorted: aaa before zzz
        let idx_aaa = path_results
            .iter()
            .position(|r| r.name == "aaa")
            .expect("aaa not found");
        let idx_zzz = path_results
            .iter()
            .position(|r| r.name == "zzz")
            .expect("zzz not found");
        assert!(idx_aaa < idx_zzz, "results should be sorted by name");
    }

    // --- user_config_dir ---

    #[test]
    fn user_config_dir_uses_xdg() {
        // Note: env var mutations may be visible to other tests running concurrently.
        // Use a unique sentinel value and restore on exit.
        let old = std::env::var("XDG_CONFIG_HOME").ok();
        std::env::set_var("XDG_CONFIG_HOME", "/tmp/xdg-test-chump");
        let dir = user_config_dir();
        match old {
            Some(v) => std::env::set_var("XDG_CONFIG_HOME", v),
            None => std::env::remove_var("XDG_CONFIG_HOME"),
        }
        assert_eq!(dir, PathBuf::from("/tmp/xdg-test-chump/chump/mcp-servers"));
    }

    #[test]
    fn user_config_dir_falls_back_to_home() {
        // Save and clear XDG_CONFIG_HOME so we exercise the HOME fallback path.
        let old_xdg = std::env::var("XDG_CONFIG_HOME").ok();
        let old_home = std::env::var("HOME").ok();
        std::env::remove_var("XDG_CONFIG_HOME");
        std::env::set_var("HOME", "/home/testuser");
        let dir = user_config_dir();
        // Restore
        match old_xdg {
            Some(v) => std::env::set_var("XDG_CONFIG_HOME", v),
            None => std::env::remove_var("XDG_CONFIG_HOME"),
        }
        match old_home {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
        assert_eq!(
            dir,
            PathBuf::from("/home/testuser/.config/chump/mcp-servers")
        );
    }

    // --- print_mcp_list (smoke test: should not panic) ---

    #[test]
    fn print_mcp_list_empty_does_not_panic() {
        print_mcp_list(&[]);
    }

    #[test]
    fn print_mcp_list_with_servers_does_not_panic() {
        let servers = vec![
            McpServerInfo {
                name: "github".to_string(),
                path: PathBuf::from("/usr/local/bin/chump-mcp-github"),
                source: McpSource::Path,
            },
            McpServerInfo {
                name: "tavily".to_string(),
                path: PathBuf::from("/home/user/.config/chump/mcp-servers/chump-mcp-tavily"),
                source: McpSource::UserConfig,
            },
        ];
        print_mcp_list(&servers);
    }
}
