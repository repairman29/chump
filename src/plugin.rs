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
        let missing = std::env::temp_dir().join(format!("chump-plugin-missing-{}", uuid::Uuid::new_v4()));
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
}
