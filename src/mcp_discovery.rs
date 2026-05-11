//! MCP server discovery: scan PATH, user-config dir, and well-known system locations
//! for `chump-mcp-*` binaries and report them grouped by source.
//!
//! This module is intentionally free of I/O side-effects at the module level —
//! all discovery is triggered by calling [`discover_mcp_servers`] explicitly.
//! No globals, no startup scanning. The results are used by `chump mcp list`
//! and (eventually) `chump mcp enable`.
//!
//! PRODUCT-061: `registry/mcp-servers.toml` is the catalog of known servers.
//! `chump mcp list` (no flags) shows the catalog; `--installed` shows discovered
//! installed binaries; `--json` makes either mode machine-readable.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

// ── Registry (PRODUCT-061) ────────────────────────────────────────────────────

/// One entry from `registry/mcp-servers.toml`.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct RegistryEntry {
    pub name: String,
    pub description: String,
    pub transport: String,
    pub package: Option<String>,
}

/// Wrapper so `toml::from_str` can deserialize `[[server]]` sections.
#[derive(Debug, serde::Deserialize)]
struct RegistryFile {
    #[serde(default)]
    server: Vec<RegistryEntry>,
}

/// Load `registry/mcp-servers.toml` relative to `repo_root`.
/// Returns an empty Vec on any error (missing file, parse error) so callers
/// degrade gracefully.
pub fn read_registry(repo_root: &Path) -> Vec<RegistryEntry> {
    let path = repo_root.join("registry").join("mcp-servers.toml");
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    match toml::from_str::<RegistryFile>(&content) {
        Ok(f) => f.server,
        Err(e) => {
            eprintln!(
                "[mcp_discovery] WARN: failed to parse {}: {e}",
                path.display()
            );
            Vec::new()
        }
    }
}

/// Print catalog (all registry entries) to stdout.
pub fn print_registry(entries: &[RegistryEntry], json: bool) {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(entries).unwrap_or_default()
        );
        return;
    }
    if entries.is_empty() {
        println!("No servers found in registry.");
        return;
    }
    println!("MCP server registry ({} servers):", entries.len());
    println!();
    for e in entries {
        let pkg = e
            .package
            .as_deref()
            .map(|p| format!("  install: cargo install {p}"))
            .unwrap_or_default();
        println!("  {:<20} [{}]  {}", e.name, e.transport, e.description);
        if !pkg.is_empty() {
            println!("  {:<20} {}", "", pkg);
        }
    }
}

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

/// Print `chump mcp list --installed` output to stdout.
///
/// `json=true` emits a JSON array; `json=false` groups servers by source.
pub fn print_mcp_list(servers: &[McpServerInfo], json: bool) {
    if json {
        #[derive(serde::Serialize)]
        struct Row<'a> {
            name: &'a str,
            path: &'a Path,
            source: &'a str,
        }
        let rows: Vec<Row> = servers
            .iter()
            .map(|s| Row {
                name: &s.name,
                path: &s.path,
                source: s.source.label(),
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&rows).unwrap_or_default()
        );
        return;
    }

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

// ── Declarative config (INFRA-744) ───────────────────────────────────────────

/// One server entry from `chump-mcp.json`.
///
/// Schema mirrors Claude Desktop's `claude_desktop_config.json` so the same
/// config can be shared between Chump and Claude Desktop.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize, PartialEq)]
pub struct McpServerEntry {
    /// Executable name or absolute path.
    pub command: String,
    /// Arguments passed to the executable (default: empty).
    #[serde(default)]
    pub args: Vec<String>,
    /// Environment variable overrides for this server.
    #[serde(default)]
    pub env: std::collections::BTreeMap<String, String>,
    /// Whether Chump should start this server (default: true).
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_enabled() -> bool {
    true
}

/// Top-level structure of `chump-mcp.json`.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize, Default)]
pub struct ChumpMcpConfig {
    /// Map of server name → configuration.
    #[serde(rename = "mcpServers", default)]
    pub mcp_servers: std::collections::BTreeMap<String, McpServerEntry>,
}

/// Runtime status of a configured server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpConfigStatus {
    /// Enabled and binary found on PATH or at the specified path.
    Ready,
    /// Enabled but binary not found.
    Missing,
    /// Disabled in config.
    Disabled,
}

impl McpConfigStatus {
    pub fn label(&self) -> &'static str {
        match self {
            McpConfigStatus::Ready => "ready",
            McpConfigStatus::Missing => "missing",
            McpConfigStatus::Disabled => "disabled",
        }
    }
}

/// A configured server with its resolved runtime status.
#[derive(Debug, Clone)]
pub struct McpConfigEntry {
    pub name: String,
    pub config: McpServerEntry,
    pub status: McpConfigStatus,
}

/// Load `chump-mcp.json` from the project root, then overlay `~/.chump/mcp.json`
/// (user-level overrides). Returns the merged config, or an empty config on error.
///
/// Resolution order (later wins for the same server name):
///   1. `<repo_root>/chump-mcp.json` — project-level, checked into version control
///   2. `~/.chump/mcp.json` — user-level, not checked in
pub fn read_mcp_config(repo_root: &Path) -> ChumpMcpConfig {
    let mut merged = ChumpMcpConfig::default();

    let candidates = [
        repo_root.join("chump-mcp.json"),
        dirs_home()
            .map(|h| h.join(".chump").join("mcp.json"))
            .unwrap_or_default(),
    ];

    for path in &candidates {
        if !path.is_file() {
            continue;
        }
        let content = match std::fs::read_to_string(path) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[mcp_config] WARN: cannot read {}: {e}", path.display());
                continue;
            }
        };
        match serde_json::from_str::<ChumpMcpConfig>(&content) {
            Ok(cfg) => {
                for (name, entry) in cfg.mcp_servers {
                    merged.mcp_servers.insert(name, entry);
                }
            }
            Err(e) => {
                eprintln!("[mcp_config] WARN: failed to parse {}: {e}", path.display());
            }
        }
    }

    merged
}

/// Resolve runtime status for each entry in a `ChumpMcpConfig`.
pub fn resolve_config_status(cfg: &ChumpMcpConfig) -> Vec<McpConfigEntry> {
    cfg.mcp_servers
        .iter()
        .map(|(name, entry)| {
            let status = if !entry.enabled {
                McpConfigStatus::Disabled
            } else if command_exists(&entry.command) {
                McpConfigStatus::Ready
            } else {
                McpConfigStatus::Missing
            };
            McpConfigEntry {
                name: name.clone(),
                config: entry.clone(),
                status,
            }
        })
        .collect()
}

/// Check if `command` is an absolute path that exists, or is discoverable on PATH.
fn command_exists(command: &str) -> bool {
    let p = std::path::Path::new(command);
    if p.is_absolute() {
        return p.is_file();
    }
    // Search PATH
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_var) {
            if dir.join(command).is_file() {
                return true;
            }
        }
    }
    false
}

/// Print the declarative config list to stdout.
pub fn print_mcp_config_list(entries: &[McpConfigEntry], json: bool) {
    if json {
        #[derive(serde::Serialize)]
        struct Row<'a> {
            name: &'a str,
            command: &'a str,
            args: &'a [String],
            enabled: bool,
            status: &'static str,
        }
        let rows: Vec<Row> = entries
            .iter()
            .map(|e| Row {
                name: &e.name,
                command: &e.config.command,
                args: &e.config.args,
                enabled: e.config.enabled,
                status: e.status.label(),
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&rows).unwrap_or_default()
        );
        return;
    }

    if entries.is_empty() {
        println!("No MCP servers configured.");
        println!();
        println!(
            "Create chump-mcp.json in your project root to declare servers.\n\
             Example:\n\
             {{\n\
               \"mcpServers\": {{\n\
                 \"filesystem\": {{\n\
                   \"command\": \"chump-mcp-filesystem\",\n\
                   \"args\": [],\n\
                   \"enabled\": true\n\
                 }}\n\
               }}\n\
             }}"
        );
        return;
    }

    let col_w = entries.iter().map(|e| e.name.len()).max().unwrap_or(4) + 2;
    for entry in entries {
        let status_str = match &entry.status {
            McpConfigStatus::Ready => "ready   ",
            McpConfigStatus::Missing => "MISSING ",
            McpConfigStatus::Disabled => "disabled",
        };
        let args_str = if entry.config.args.is_empty() {
            String::new()
        } else {
            format!(" {}", entry.config.args.join(" "))
        };
        println!(
            "  {:<width$}  [{}]  {}{}",
            entry.name,
            status_str,
            entry.config.command,
            args_str,
            width = col_w,
        );
    }
}

// ── Install / remove (PRODUCT-062) ───────────────────────────────────────────

/// Result of `install_mcp_server`.
#[derive(Debug)]
pub enum InstallOutcome {
    /// Binary was already on PATH — config updated, no cargo install needed.
    AlreadyInstalled,
    /// `cargo install <package>` was run and succeeded.
    CargoInstalled,
    /// `--no-install` was passed — config updated, binary install skipped.
    ConfigOnly,
}

/// Install an MCP server by name from the registry.
///
/// Steps:
///   1. Look up `name` in `registry/mcp-servers.toml`.
///   2. If the binary is already on PATH, skip cargo install.
///   3. Otherwise run `cargo install <package>` (unless `no_install`).
///   4. Add the server to `chump-mcp.json` in `config_root` with `enabled: true`.
///
/// Returns `Err` if the server is not in the registry, if cargo install fails,
/// or if the config file cannot be written.
pub fn install_mcp_server(
    registry_root: &Path,
    config_root: &Path,
    name: &str,
    no_install: bool,
) -> anyhow::Result<InstallOutcome> {
    let registry = read_registry(registry_root);
    let entry = registry.iter().find(|e| e.name == name).ok_or_else(|| {
        anyhow::anyhow!(
            "Server '{name}' not found in registry. Run 'chump mcp list' to see available servers."
        )
    })?;

    let binary_name = format!("chump-mcp-{name}");
    let already_installed = command_exists(&binary_name);

    let outcome = if already_installed {
        InstallOutcome::AlreadyInstalled
    } else if no_install {
        InstallOutcome::ConfigOnly
    } else {
        let package = entry.package.as_deref().unwrap_or(&binary_name);
        let status = std::process::Command::new("cargo")
            .args(["install", package])
            .status()
            .map_err(|e| anyhow::anyhow!("Failed to run cargo install: {e}"))?;
        if !status.success() {
            anyhow::bail!(
                "cargo install {package} failed (exit {}). \
                 Install manually and re-run with --no-install.",
                status.code().unwrap_or(-1)
            );
        }
        InstallOutcome::CargoInstalled
    };

    // Add to chump-mcp.json.
    let mut cfg = read_mcp_config(config_root);
    cfg.mcp_servers
        .entry(name.to_string())
        .or_insert_with(|| McpServerEntry {
            command: binary_name,
            args: Vec::new(),
            env: Default::default(),
            enabled: true,
        });
    // If existing entry had enabled:false, set to true.
    if let Some(e) = cfg.mcp_servers.get_mut(name) {
        e.enabled = true;
    }
    write_mcp_config(config_root, &cfg)?;

    // INFRA-755: emit observability event on install.
    let outcome_str = match &outcome {
        InstallOutcome::AlreadyInstalled => "already_installed",
        InstallOutcome::CargoInstalled => "cargo_installed",
        InstallOutcome::ConfigOnly => "config_only",
    };
    emit_mcp_install_event(name, outcome_str);

    Ok(outcome)
}

fn emit_mcp_install_event(name: &str, outcome: &str) {
    let locks_dir = {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        std::path::PathBuf::from(home).join(".chump-locks")
    };
    // Fall back to project-local .chump-locks if home dir unavailable.
    let locks_dir = if locks_dir.exists() {
        locks_dir
    } else {
        std::path::PathBuf::from(".chump-locks")
    };
    let _ = std::fs::create_dir_all(&locks_dir);
    let amb = locks_dir.join("ambient.jsonl");
    let ts = {
        use std::time::{SystemTime, UNIX_EPOCH};
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        // ISO-8601 UTC — simple format sufficient for ambient stream.
        format!("{}", secs)
    };
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"mcp_server_installed\",\"name\":\"{name}\",\"outcome\":\"{outcome}\"}}\n"
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Remove an MCP server from `chump-mcp.json`.
///
/// Does NOT uninstall the binary — prints a hint for that.
/// Returns `true` if the server was found and removed, `false` if it wasn't in config.
pub fn remove_mcp_server(config_root: &Path, name: &str) -> anyhow::Result<bool> {
    let mut cfg = read_mcp_config(config_root);
    let removed = cfg.mcp_servers.remove(name).is_some();
    if removed {
        write_mcp_config(config_root, &cfg)?;
    }
    Ok(removed)
}

/// Write `ChumpMcpConfig` to `<config_root>/chump-mcp.json`.
pub fn write_mcp_config(config_root: &Path, cfg: &ChumpMcpConfig) -> anyhow::Result<()> {
    let path = config_root.join("chump-mcp.json");
    let content = serde_json::to_string_pretty(cfg)
        .map_err(|e| anyhow::anyhow!("Failed to serialize chump-mcp.json: {e}"))?;
    std::fs::write(&path, content + "\n")
        .map_err(|e| anyhow::anyhow!("Failed to write {}: {e}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Mutex, OnceLock};
    use tempfile::TempDir;

    // ── INFRA-744: declarative config tests ───────────────────────────────────

    #[test]
    fn read_mcp_config_empty_dir_returns_default() {
        let tmp = TempDir::new().unwrap();
        let cfg = read_mcp_config(tmp.path());
        assert!(cfg.mcp_servers.is_empty());
    }

    #[test]
    fn read_mcp_config_parses_project_file() {
        let tmp = TempDir::new().unwrap();
        fs::write(
            tmp.path().join("chump-mcp.json"),
            r#"{"mcpServers":{"test-srv":{"command":"my-binary","args":["--flag"],"enabled":true}}}"#,
        )
        .unwrap();
        let cfg = read_mcp_config(tmp.path());
        assert_eq!(cfg.mcp_servers.len(), 1);
        let entry = cfg.mcp_servers.get("test-srv").unwrap();
        assert_eq!(entry.command, "my-binary");
        assert_eq!(entry.args, vec!["--flag"]);
        assert!(entry.enabled);
    }

    #[test]
    fn read_mcp_config_defaults_enabled_to_true() {
        let tmp = TempDir::new().unwrap();
        fs::write(
            tmp.path().join("chump-mcp.json"),
            r#"{"mcpServers":{"srv":{"command":"bin"}}}"#,
        )
        .unwrap();
        let cfg = read_mcp_config(tmp.path());
        assert!(cfg.mcp_servers["srv"].enabled);
    }

    #[test]
    fn read_mcp_config_tolerates_malformed_json() {
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("chump-mcp.json"), b"not valid json").unwrap();
        let cfg = read_mcp_config(tmp.path());
        assert!(cfg.mcp_servers.is_empty());
    }

    #[test]
    fn resolve_config_status_disabled_entry() {
        let mut cfg = ChumpMcpConfig::default();
        cfg.mcp_servers.insert(
            "srv".to_string(),
            McpServerEntry {
                command: "chump-mcp-github".to_string(),
                args: vec![],
                env: Default::default(),
                enabled: false,
            },
        );
        let entries = resolve_config_status(&cfg);
        assert_eq!(entries[0].status, McpConfigStatus::Disabled);
    }

    #[test]
    fn resolve_config_status_missing_binary() {
        let mut cfg = ChumpMcpConfig::default();
        cfg.mcp_servers.insert(
            "srv".to_string(),
            McpServerEntry {
                command: "definitely-does-not-exist-binary-xyz".to_string(),
                args: vec![],
                env: Default::default(),
                enabled: true,
            },
        );
        let entries = resolve_config_status(&cfg);
        assert_eq!(entries[0].status, McpConfigStatus::Missing);
    }

    #[test]
    fn resolve_config_status_absolute_path_found() {
        let tmp = TempDir::new().unwrap();
        let bin = tmp.path().join("my-server");
        fs::write(&bin, b"#!/bin/sh\n").unwrap();
        let mut perms = fs::metadata(&bin).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&bin, perms).unwrap();

        let mut cfg = ChumpMcpConfig::default();
        cfg.mcp_servers.insert(
            "srv".to_string(),
            McpServerEntry {
                command: bin.to_string_lossy().to_string(),
                args: vec![],
                env: Default::default(),
                enabled: true,
            },
        );
        let entries = resolve_config_status(&cfg);
        assert_eq!(entries[0].status, McpConfigStatus::Ready);
    }

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

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
        let _guard = env_lock().lock().unwrap();
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
        let _guard = env_lock().lock().unwrap();
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
        let _guard = env_lock().lock().unwrap();
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
        let _guard = env_lock().lock().unwrap();
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
        let _guard = env_lock().lock().unwrap();
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
        print_mcp_list(&[], false);
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
        print_mcp_list(&servers, false);
    }

    // ── PRODUCT-062: install / remove tests ───────────────────────────────────

    fn write_registry(dir: &Path) {
        fs::create_dir_all(dir.join("registry")).unwrap();
        fs::write(
            dir.join("registry").join("mcp-servers.toml"),
            r#"
[[server]]
name = "git"
description = "Git operations"
transport = "stdio"
package = "chump-mcp-git"

[[server]]
name = "filesystem"
description = "File access"
transport = "stdio"
package = "chump-mcp-filesystem"
"#,
        )
        .unwrap();
    }

    #[test]
    fn write_mcp_config_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let mut cfg = ChumpMcpConfig::default();
        cfg.mcp_servers.insert(
            "git".to_string(),
            McpServerEntry {
                command: "chump-mcp-git".to_string(),
                args: vec!["--verbose".to_string()],
                env: Default::default(),
                enabled: true,
            },
        );
        write_mcp_config(tmp.path(), &cfg).unwrap();
        let loaded = read_mcp_config(tmp.path());
        assert_eq!(loaded.mcp_servers.len(), 1);
        let e = &loaded.mcp_servers["git"];
        assert_eq!(e.command, "chump-mcp-git");
        assert_eq!(e.args, vec!["--verbose"]);
        assert!(e.enabled);
    }

    #[test]
    fn install_mcp_server_unknown_name_returns_err() {
        let tmp = TempDir::new().unwrap();
        write_registry(tmp.path());
        let result = install_mcp_server(tmp.path(), tmp.path(), "no-such-server", true);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("not found in registry"));
    }

    #[test]
    fn install_mcp_server_no_install_adds_to_config() {
        let tmp = TempDir::new().unwrap();
        write_registry(tmp.path());
        let outcome = install_mcp_server(tmp.path(), tmp.path(), "git", true).unwrap();
        assert!(matches!(outcome, InstallOutcome::ConfigOnly));
        let cfg = read_mcp_config(tmp.path());
        assert!(cfg.mcp_servers.contains_key("git"));
        assert!(cfg.mcp_servers["git"].enabled);
    }

    #[test]
    fn install_mcp_server_already_installed_skips_cargo() {
        let tmp = TempDir::new().unwrap();
        write_registry(tmp.path());
        // Fake binary on PATH by writing to tmp dir and prepending to PATH.
        let _lock = env_lock().lock().unwrap();
        write_binary(tmp.path(), "chump-mcp-git");
        let old_path = std::env::var("PATH").unwrap_or_default();
        std::env::set_var("PATH", format!("{}:{}", tmp.path().display(), old_path));
        let outcome = install_mcp_server(tmp.path(), tmp.path(), "git", false).unwrap();
        std::env::set_var("PATH", old_path);
        assert!(matches!(outcome, InstallOutcome::AlreadyInstalled));
        let cfg = read_mcp_config(tmp.path());
        assert!(cfg.mcp_servers.contains_key("git"));
    }

    #[test]
    fn remove_mcp_server_existing_entry() {
        let tmp = TempDir::new().unwrap();
        let mut cfg = ChumpMcpConfig::default();
        cfg.mcp_servers.insert(
            "git".to_string(),
            McpServerEntry {
                command: "chump-mcp-git".to_string(),
                args: vec![],
                env: Default::default(),
                enabled: true,
            },
        );
        write_mcp_config(tmp.path(), &cfg).unwrap();

        let removed = remove_mcp_server(tmp.path(), "git").unwrap();
        assert!(removed);
        let loaded = read_mcp_config(tmp.path());
        assert!(!loaded.mcp_servers.contains_key("git"));
    }

    #[test]
    fn remove_mcp_server_nonexistent_returns_false() {
        let tmp = TempDir::new().unwrap();
        let removed = remove_mcp_server(tmp.path(), "no-such").unwrap();
        assert!(!removed);
    }
}
