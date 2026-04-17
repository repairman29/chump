//! Chump plugin system: third-party extension points for tools, context engines, and adapters.
//!
//! Discovery sources (scanned in order; later sources override earlier ones by name):
//! - `~/.chump/plugins/<name>/` — user-level plugins
//! - `<CHUMP_REPO>/.chump/plugins/<name>/` — project-level plugins
//! - Cargo dependency with `chump-plugin` convention — build-time integration
//!   (registered statically via the `inventory` crate; not handled by the discovery
//!   scanner since they ship as compiled code, not on-disk manifests)
//!
//! Each plugin directory contains a `plugin.yaml` manifest and (eventually) a dynamic
//! library or static binary. For V1, we support **static registration only** (Rust
//! plugins compiled into the binary). V2 will add dynamic loading via `libloading`.
//!
//! See `docs/PLUGIN_DEVELOPMENT.md` for the developer guide.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Standard manifest filename inside each plugin directory.
pub const MANIFEST_FILENAME: &str = "plugin.yaml";

/// Plugin manifest loaded from `plugin.yaml`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginManifest {
    /// Unique plugin name (used as the registry key). Lowercase, hyphenated.
    pub name: String,
    /// Semver-ish version string. Free-form; not currently parsed.
    pub version: String,
    /// One-line human description.
    #[serde(default)]
    pub description: Option<String>,
    /// Author or maintainer (free-form).
    #[serde(default)]
    pub author: Option<String>,
    /// Cargo features that must be enabled in the host binary for this plugin to work.
    /// Plugins listing unmet features are loaded as inert (manifest-only) and a
    /// warning is emitted.
    #[serde(default)]
    pub requires_features: Vec<String>,
    /// Optional path (relative to the plugin directory) to the entry artifact.
    /// For V1 this is informational only. V2 will use it to `dlopen` a shared library.
    #[serde(default)]
    pub entry_path: Option<String>,
    /// Optional JSON Schema describing the plugin's user-facing config.
    #[serde(default)]
    pub config_schema: serde_json::Value,
    /// Declarative summary of what the plugin contributes. Purely advisory at load
    /// time — the plugin's `initialize()` is the source of truth.
    #[serde(default)]
    pub provides: PluginProvides,
}

/// Declarative summary of what a plugin contributes to the host.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PluginProvides {
    #[serde(default)]
    pub tools: Vec<String>,
    #[serde(default)]
    pub context_engines: Vec<String>,
    #[serde(default)]
    pub adapters: Vec<String>,
    #[serde(default)]
    pub skills: Vec<String>,
}

/// Where a plugin was discovered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginSource {
    /// `~/.chump/plugins/<name>/`
    User,
    /// `<CHUMP_REPO>/.chump/plugins/<name>/`
    Project,
    /// Statically linked via the `inventory` crate (no on-disk manifest).
    Static,
}

/// A plugin found on disk during discovery, with its parsed manifest.
#[derive(Debug, Clone)]
pub struct DiscoveredPlugin {
    pub source: PluginSource,
    pub directory: PathBuf,
    pub manifest_path: PathBuf,
    pub manifest: PluginManifest,
}

/// Runtime context handed to a plugin's `initialize()` method.
///
/// V1 keeps this intentionally narrow — it carries paths and environment lookups
/// rather than borrowed handles to the global tool registry, so the trait stays
/// `Send + Sync` and forward-compatible with dynamic loading.
#[derive(Debug, Clone)]
pub struct PluginContext {
    /// Path to the user's chump brain directory (resolves `CHUMP_HOME`/default).
    pub brain_path: PathBuf,
    /// Working repository root (`CHUMP_REPO` or override).
    pub repo_root: PathBuf,
    /// Directory containing this plugin's manifest, for resolving relative assets.
    pub plugin_dir: PathBuf,
    /// Snapshot of plugin-relevant env vars (CHUMP_* prefix).
    pub env: std::collections::HashMap<String, String>,
}

impl PluginContext {
    /// Look up a `CHUMP_*` env var captured at context build time.
    pub fn env_var(&self, key: &str) -> Option<&str> {
        self.env.get(key).map(String::as_str)
    }
}

/// The trait every Chump plugin implements.
///
/// V1 expectation: implementations are compiled into the host binary and registered
/// either via the `inventory` crate or by direct `Vec<Box<dyn ChumpPlugin>>`
/// construction at startup.
pub trait ChumpPlugin: Send + Sync {
    /// Stable, unique plugin name (matches `manifest().name`).
    fn name(&self) -> &str;

    /// Plugin version string.
    fn version(&self) -> &str;

    /// Return the plugin's manifest. May be a synthetic manifest for static plugins
    /// that ship without an on-disk `plugin.yaml`.
    fn manifest(&self) -> PluginManifest;

    /// Hook called once at host startup. Plugins should register their tools,
    /// context engines, adapters, etc. here. The default impl is a no-op so that
    /// inert/manifest-only plugins compile.
    fn initialize(&self, _ctx: &PluginContext) -> Result<()> {
        Ok(())
    }
}

/// Resolve `~/.chump/plugins/`. Honors `CHUMP_HOME` if set.
pub fn user_plugins_dir() -> PathBuf {
    if let Ok(home) = std::env::var("CHUMP_HOME") {
        if !home.is_empty() {
            return PathBuf::from(home).join("plugins");
        }
    }
    if let Some(home) = dirs_home() {
        return home.join(".chump").join("plugins");
    }
    PathBuf::from(".chump").join("plugins")
}

/// Resolve `<CHUMP_REPO>/.chump/plugins/`.
pub fn project_plugins_dir() -> PathBuf {
    crate::repo_path::repo_root().join(".chump").join("plugins")
}

/// Cross-platform `$HOME` lookup without pulling in the `dirs` crate.
fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

/// Load and parse a `plugin.yaml` manifest from the given path.
pub fn load_manifest(path: &Path) -> Result<PluginManifest> {
    let bytes = std::fs::read(path)
        .with_context(|| format!("reading plugin manifest at {}", path.display()))?;
    let manifest: PluginManifest = serde_yaml::from_slice(&bytes)
        .with_context(|| format!("parsing plugin manifest at {}", path.display()))?;
    if manifest.name.trim().is_empty() {
        return Err(anyhow!(
            "plugin manifest at {} is missing required `name`",
            path.display()
        ));
    }
    if manifest.version.trim().is_empty() {
        return Err(anyhow!(
            "plugin manifest at {} is missing required `version`",
            path.display()
        ));
    }
    Ok(manifest)
}

/// Scan a single plugins-root directory for subdirectories containing a manifest.
/// Returns an empty Vec if the directory does not exist; logs (via `tracing`) and
/// skips entries whose manifest fails to parse.
fn scan_dir(root: &Path, source: PluginSource) -> Vec<DiscoveredPlugin> {
    let mut out = Vec::new();
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return out, // missing dir is not an error
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let manifest_path = dir.join(MANIFEST_FILENAME);
        if !manifest_path.is_file() {
            continue;
        }
        match load_manifest(&manifest_path) {
            Ok(manifest) => out.push(DiscoveredPlugin {
                source,
                directory: dir,
                manifest_path,
                manifest,
            }),
            Err(e) => {
                tracing::warn!(target: "chump::plugin", "skipping invalid plugin manifest at {}: {e:#}", manifest_path.display());
            }
        }
    }
    out
}

/// Discover all on-disk plugins from user and project directories.
///
/// Order: user plugins first, then project plugins. If two sources declare the
/// same `name`, the project-level entry wins (later in the returned Vec) — callers
/// that build a registry should de-dup by `manifest.name`, keeping the last entry.
///
/// Statically-registered plugins are not included here; they are surfaced separately
/// (see `inventory`-based registration in the host).
pub fn discover_plugins() -> Vec<DiscoveredPlugin> {
    let mut out = Vec::new();
    out.extend(scan_dir(&user_plugins_dir(), PluginSource::User));
    out.extend(scan_dir(&project_plugins_dir(), PluginSource::Project));
    out
}

/// Build a `PluginContext` from the current environment.
pub fn build_plugin_context(plugin_dir: &Path) -> PluginContext {
    let brain_path = if let Ok(home) = std::env::var("CHUMP_HOME") {
        if !home.is_empty() {
            PathBuf::from(home)
        } else {
            dirs_home()
                .map(|h| h.join(".chump"))
                .unwrap_or_else(|| PathBuf::from(".chump"))
        }
    } else {
        dirs_home()
            .map(|h| h.join(".chump"))
            .unwrap_or_else(|| PathBuf::from(".chump"))
    };
    let repo_root = crate::repo_path::repo_root();
    let env: std::collections::HashMap<String, String> = std::env::vars()
        .filter(|(k, _)| k.starts_with("CHUMP_"))
        .collect();
    PluginContext {
        brain_path,
        repo_root,
        plugin_dir: plugin_dir.to_path_buf(),
        env,
    }
}

/// Log all discovered plugins and call `initialize()` on any that implement the
/// `ChumpPlugin` trait (static plugins only in V1 — on-disk manifests are logged
/// and checked for feature requirements but cannot contribute runtime code until
/// V2 dynamic loading).
///
/// Returns the number of plugins found (manifest + static combined).
pub fn initialize_discovered(static_plugins: &[Box<dyn ChumpPlugin>]) -> usize {
    let discovered = discover_active_plugins();
    let mut count = static_plugins.len();

    for p in &discovered {
        count += 1;
        let source_label = match p.source {
            PluginSource::User => "user",
            PluginSource::Project => "project",
            PluginSource::Static => "static",
        };
        if !p.manifest.requires_features.is_empty() {
            // V1: we don't have a feature-flag check at runtime, so warn on any requirement.
            tracing::warn!(
                plugin = %p.manifest.name,
                requires = ?p.manifest.requires_features,
                "plugin requires features not verified at runtime (V2 dynamic loading needed)",
            );
        }
        tracing::info!(
            plugin = %p.manifest.name,
            version = %p.manifest.version,
            source = source_label,
            "discovered plugin manifest (V1: manifest-only; V2 will dlopen entry_path)",
        );
    }

    for sp in static_plugins {
        let ctx = build_plugin_context(&PathBuf::from("."));
        match sp.initialize(&ctx) {
            Ok(()) => tracing::info!(plugin = %sp.name(), "static plugin initialized"),
            Err(e) => tracing::warn!(plugin = %sp.name(), error = %e, "static plugin init failed"),
        }
    }

    count
}

/// Path to the disabled-plugins state file in the user plugins directory.
fn disabled_plugins_path() -> PathBuf {
    user_plugins_dir().join(".disabled.json")
}

/// Load the set of disabled plugin names from `.disabled.json`. Returns empty set on any error.
pub fn disabled_plugins() -> std::collections::HashSet<String> {
    let path = disabled_plugins_path();
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(_) => return Default::default(),
    };
    serde_json::from_slice::<Vec<String>>(&bytes)
        .map(|v| v.into_iter().collect())
        .unwrap_or_default()
}

/// Persist the disabled plugin set to `.disabled.json`.
fn save_disabled_plugins(set: &std::collections::HashSet<String>) -> Result<()> {
    let path = disabled_plugins_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut names: Vec<&String> = set.iter().collect();
    names.sort();
    let json = serde_json::to_string_pretty(&names)?;
    std::fs::write(&path, json)?;
    Ok(())
}

/// Discover plugins, filtering out any that appear in `.disabled.json`.
pub fn discover_active_plugins() -> Vec<DiscoveredPlugin> {
    let disabled = disabled_plugins();
    discover_plugins()
        .into_iter()
        .filter(|p| !disabled.contains(&p.manifest.name))
        .collect()
}

/// Install a plugin from a local directory into `~/.chump/plugins/<name>/`.
///
/// The source directory must contain a valid `plugin.yaml`. Returns the installed
/// plugin name on success. Errors if the source is invalid or the copy fails.
pub fn plugins_install(source_path: &str) -> Result<String> {
    let src = PathBuf::from(source_path);
    if !src.is_dir() {
        return Err(anyhow!(
            "install path is not a directory: {}",
            src.display()
        ));
    }
    let manifest_path = src.join(MANIFEST_FILENAME);
    let manifest = load_manifest(&manifest_path)?;
    let name = manifest.name.clone();

    let dest = user_plugins_dir().join(&name);
    if dest.exists() {
        return Err(anyhow!(
            "plugin '{}' already installed at {}; remove it first with --plugins-uninstall or disable with --plugins-disable",
            name,
            dest.display()
        ));
    }
    copy_dir_all(&src, &dest)?;
    Ok(name)
}

/// Uninstall a user-level plugin by name (removes its directory from `~/.chump/plugins/`).
/// Project-level plugins cannot be uninstalled via this command.
pub fn plugins_uninstall(name: &str) -> Result<()> {
    let dest = user_plugins_dir().join(name);
    if !dest.exists() {
        return Err(anyhow!(
            "plugin '{}' not found in user plugins directory",
            name
        ));
    }
    std::fs::remove_dir_all(&dest)
        .with_context(|| format!("removing plugin directory at {}", dest.display()))?;
    let mut disabled = disabled_plugins();
    if disabled.remove(name) {
        let _ = save_disabled_plugins(&disabled);
    }
    Ok(())
}

/// Mark a plugin as disabled (persisted to `.disabled.json`).
pub fn plugins_disable(name: &str) -> Result<()> {
    let mut disabled = disabled_plugins();
    disabled.insert(name.to_string());
    save_disabled_plugins(&disabled)
}

/// Mark a plugin as enabled (removes from `.disabled.json`).
pub fn plugins_enable(name: &str) -> Result<()> {
    let mut disabled = disabled_plugins();
    if !disabled.remove(name) {
        return Err(anyhow!("plugin '{}' was not disabled", name));
    }
    save_disabled_plugins(&disabled)
}

/// Recursively copy a directory tree.
fn copy_dir_all(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let dst_path = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_all(&entry.path(), &dst_path)?;
        } else {
            std::fs::copy(entry.path(), &dst_path)?;
        }
    }
    Ok(())
}

/// Print discovered plugins to stdout. Called by `chump --plugins-list`.
pub fn print_plugins_list() {
    let all = discover_plugins();
    let disabled = disabled_plugins();
    if all.is_empty() {
        println!("No plugins discovered.");
        println!("Plugin search paths:");
        println!("  user:    {}", user_plugins_dir().display());
        println!("  project: {}", project_plugins_dir().display());
        return;
    }
    println!("Discovered plugins ({}):", all.len());
    for p in &all {
        let source_label = match p.source {
            PluginSource::User => "user",
            PluginSource::Project => "project",
            PluginSource::Static => "static",
        };
        let status = if disabled.contains(&p.manifest.name) {
            "  [DISABLED]"
        } else {
            ""
        };
        println!(
            "  {} v{}  [{}]  {}{}",
            p.manifest.name,
            p.manifest.version,
            source_label,
            p.manifest.description.as_deref().unwrap_or(""),
            status,
        );
        if let Some(ref entry) = p.manifest.entry_path {
            println!("    entry: {}", entry);
        }
        if !p.manifest.requires_features.is_empty() {
            println!(
                "    requires features: {}",
                p.manifest.requires_features.join(", ")
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_yaml() -> &'static str {
        r#"
name: hello-plugin
version: 0.1.0
description: A sample plugin
author: Test Author
requires_features: [inprocess-embed]
entry_path: lib/libhello.dylib
provides:
  tools: [hello, wave]
  context_engines: [greeter]
config_schema:
  type: object
  properties:
    greeting:
      type: string
"#
    }

    #[test]
    fn manifest_roundtrip() {
        let manifest: PluginManifest = serde_yaml::from_str(sample_yaml()).expect("parse");
        assert_eq!(manifest.name, "hello-plugin");
        assert_eq!(manifest.version, "0.1.0");
        assert_eq!(manifest.description.as_deref(), Some("A sample plugin"));
        assert_eq!(manifest.requires_features, vec!["inprocess-embed"]);
        assert_eq!(manifest.provides.tools, vec!["hello", "wave"]);
        assert_eq!(manifest.provides.context_engines, vec!["greeter"]);

        // Round-trip through YAML and back.
        let s = serde_yaml::to_string(&manifest).expect("serialize");
        let back: PluginManifest = serde_yaml::from_str(&s).expect("re-parse");
        assert_eq!(back.name, manifest.name);
        assert_eq!(back.version, manifest.version);
        assert_eq!(back.provides.tools, manifest.provides.tools);
    }

    #[test]
    fn manifest_minimal_fields() {
        let yaml = "name: tiny\nversion: '1'\n";
        let m: PluginManifest = serde_yaml::from_str(yaml).expect("parse minimal");
        assert_eq!(m.name, "tiny");
        assert!(m.description.is_none());
        assert!(m.provides.tools.is_empty());
    }

    #[test]
    fn load_manifest_missing_name_errors() {
        let dir = tempdir();
        let path = dir.join("plugin.yaml");
        std::fs::write(&path, "name: ''\nversion: 1.0\n").unwrap();
        let err = load_manifest(&path).unwrap_err();
        assert!(format!("{err:#}").contains("name"));
    }

    #[test]
    fn load_manifest_invalid_yaml_errors() {
        let dir = tempdir();
        let path = dir.join("plugin.yaml");
        std::fs::write(&path, "this: is: not: valid: yaml: [unterminated").unwrap();
        assert!(load_manifest(&path).is_err());
    }

    #[test]
    fn scan_dir_missing_returns_empty() {
        let missing =
            std::env::temp_dir().join(format!("chump-plugin-missing-{}", uuid::Uuid::new_v4()));
        let found = scan_dir(&missing, PluginSource::User);
        assert!(found.is_empty());
    }

    #[test]
    fn scan_dir_finds_plugin_and_skips_garbage() {
        let root = tempdir();

        // Valid plugin.
        let good_dir = root.join("good");
        std::fs::create_dir_all(&good_dir).unwrap();
        std::fs::write(good_dir.join("plugin.yaml"), sample_yaml()).unwrap();

        // Directory without a manifest — should be ignored.
        std::fs::create_dir_all(root.join("no-manifest")).unwrap();

        // Directory with an invalid manifest — should be skipped (logged).
        let bad_dir = root.join("bad");
        std::fs::create_dir_all(&bad_dir).unwrap();
        std::fs::write(bad_dir.join("plugin.yaml"), "name: ''\nversion: ''\n").unwrap();

        let found = scan_dir(&root, PluginSource::Project);
        assert_eq!(found.len(), 1, "only the valid plugin should load");
        assert_eq!(found[0].manifest.name, "hello-plugin");
        assert_eq!(found[0].source, PluginSource::Project);
        assert_eq!(found[0].manifest_path, good_dir.join("plugin.yaml"));
    }

    #[test]
    #[serial_test::serial]
    fn discover_plugins_uses_overridden_user_dir() {
        // Point CHUMP_HOME at a fresh temp dir so we don't depend on the real $HOME.
        let home = tempdir();
        let prev = std::env::var("CHUMP_HOME").ok();
        // SAFETY: tests in this module are not run in parallel relative to each
        // other for this env var because they all touch CHUMP_HOME via serial_test
        // elsewhere; here we save+restore to be polite.
        std::env::set_var("CHUMP_HOME", &home);

        let plugins_root = home.join("plugins").join("via-home");
        std::fs::create_dir_all(&plugins_root).unwrap();
        std::fs::write(plugins_root.join("plugin.yaml"), sample_yaml()).unwrap();

        assert_eq!(user_plugins_dir(), home.join("plugins"));
        let discovered = discover_plugins();
        assert!(discovered
            .iter()
            .any(|p| p.source == PluginSource::User && p.manifest.name == "hello-plugin"));

        match prev {
            Some(v) => std::env::set_var("CHUMP_HOME", v),
            None => std::env::remove_var("CHUMP_HOME"),
        }
    }

    /// Create a unique temp directory for the test and return its path.
    fn tempdir() -> PathBuf {
        let p = std::env::temp_dir().join(format!("chump-plugin-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    // ------------------------------------------------------------------
    // COMP-002: install / disable / enable / uninstall
    // ------------------------------------------------------------------

    #[test]
    #[serial_test::serial]
    fn plugins_install_copies_directory_to_user_plugins() {
        let home = tempdir();
        let prev = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_HOME", &home);

        // Source plugin directory
        let src = tempdir();
        std::fs::write(src.join("plugin.yaml"), sample_yaml()).unwrap();
        std::fs::write(src.join("extra.txt"), "extra").unwrap();

        let name = plugins_install(src.to_str().unwrap()).expect("install should succeed");
        assert_eq!(name, "hello-plugin");

        let installed = user_plugins_dir().join("hello-plugin");
        assert!(installed.exists(), "installed dir should exist");
        assert!(installed.join("plugin.yaml").exists(), "manifest should be copied");
        assert!(installed.join("extra.txt").exists(), "extra files should be copied");

        match prev {
            Some(v) => std::env::set_var("CHUMP_HOME", v),
            None => std::env::remove_var("CHUMP_HOME"),
        }
    }

    #[test]
    #[serial_test::serial]
    fn plugins_install_fails_if_already_installed() {
        let home = tempdir();
        let prev = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_HOME", &home);

        let src = tempdir();
        std::fs::write(src.join("plugin.yaml"), sample_yaml()).unwrap();

        plugins_install(src.to_str().unwrap()).expect("first install succeeds");
        let err = plugins_install(src.to_str().unwrap()).expect_err("second install should fail");
        assert!(err.to_string().contains("already installed"));

        match prev {
            Some(v) => std::env::set_var("CHUMP_HOME", v),
            None => std::env::remove_var("CHUMP_HOME"),
        }
    }

    #[test]
    #[serial_test::serial]
    fn plugins_disable_and_enable_round_trip() {
        let home = tempdir();
        let prev = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_HOME", &home);

        plugins_disable("my-plugin").expect("disable should succeed");
        assert!(disabled_plugins().contains("my-plugin"));

        plugins_enable("my-plugin").expect("enable should succeed");
        assert!(!disabled_plugins().contains("my-plugin"));

        match prev {
            Some(v) => std::env::set_var("CHUMP_HOME", v),
            None => std::env::remove_var("CHUMP_HOME"),
        }
    }

    #[test]
    #[serial_test::serial]
    fn discover_active_plugins_excludes_disabled() {
        let home = tempdir();
        let prev = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_HOME", &home);

        // Install a plugin and then disable it.
        let src = tempdir();
        std::fs::write(src.join("plugin.yaml"), sample_yaml()).unwrap();
        plugins_install(src.to_str().unwrap()).expect("install");
        plugins_disable("hello-plugin").expect("disable");

        let active = discover_active_plugins();
        assert!(
            !active.iter().any(|p| p.manifest.name == "hello-plugin"),
            "disabled plugin should not appear in active list"
        );

        match prev {
            Some(v) => std::env::set_var("CHUMP_HOME", v),
            None => std::env::remove_var("CHUMP_HOME"),
        }
    }

    #[test]
    #[serial_test::serial]
    fn plugins_uninstall_removes_directory() {
        let home = tempdir();
        let prev = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_HOME", &home);

        let src = tempdir();
        std::fs::write(src.join("plugin.yaml"), sample_yaml()).unwrap();
        plugins_install(src.to_str().unwrap()).expect("install");

        let installed = user_plugins_dir().join("hello-plugin");
        assert!(installed.exists());

        plugins_uninstall("hello-plugin").expect("uninstall");
        assert!(!installed.exists(), "directory should be removed after uninstall");

        match prev {
            Some(v) => std::env::set_var("CHUMP_HOME", v),
            None => std::env::remove_var("CHUMP_HOME"),
        }
    }
}
