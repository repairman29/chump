//! Validated cross-platform `config.toml` loader + seamless environment overrides.
//!
//! Resolves `chump_pal::chump_home().join("config.toml")` (`~/.chump/config.toml`
//! on macOS/Linux, `%USERPROFILE%\.chump\config.toml` on Windows, or `CHUMP_CONFIG_FILE`
//! when explicitly overridden) and merges legacy `[api]` keys into `[auth]`.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Maximum cascading LLM provider slots supported by `ProviderCascade`.
pub const MAX_PROVIDER_SLOTS: usize = 40;

/// Errors returned while loading, parsing, validating, or writing `config.toml`.
#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("failed reading config at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("invalid TOML in {path}: {message}")]
    Parse { path: PathBuf, message: String },
    #[error("config validation failed:\n  - {}", .0.join("\n  - "))]
    Validation(Vec<String>),
    #[error("failed serializing config to TOML: {0}")]
    Serialize(String),
}

/// Top-level Chump configuration (`~/.chump/config.toml` / `%USERPROFILE%\.chump\config.toml`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ChumpConfig {
    #[serde(default)]
    pub auth: AuthSection,

    /// Backwards-compatible `[api]` section from legacy `~/.chump/config.toml` (`src/auth.rs`).
    #[serde(default, skip_serializing_if = "LegacyApiSection::is_empty")]
    pub api: LegacyApiSection,

    /// Cascading BYOK / local / subscription LLM provider slots (up to 40).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub providers: Vec<ProviderSlotConfig>,

    #[serde(default)]
    pub fleet: FleetSection,

    #[serde(default)]
    pub worker: WorkerSection,

    #[serde(default)]
    pub web: WebSection,

    #[serde(default)]
    pub nats: NatsSection,

    /// Backwards-compatible `[settings]` bag (`INFRA-988`).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub settings: BTreeMap<String, toml::Value>,
}

/// Authentication mode (`auto` | `oauth` | `api-key`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AuthModeConfig {
    #[default]
    Auto,
    Oauth,
    #[serde(alias = "api_key", alias = "apikey")]
    ApiKey,
}

impl AuthModeConfig {
    pub fn parse_loose(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "auto" | "" => Some(Self::Auto),
            "oauth" => Some(Self::Oauth),
            "api-key" | "api_key" | "apikey" => Some(Self::ApiKey),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Oauth => "oauth",
            Self::ApiKey => "api-key",
        }
    }
}

/// `[auth]` section of `config.toml`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthSection {
    #[serde(default)]
    pub mode: AuthModeConfig,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anthropic_api_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_code_oauth_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oauth_token_file: Option<PathBuf>,
}

/// Legacy `[api]` section preserved for 100% backwards compatibility with `src/auth.rs`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct LegacyApiSection {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anthropic_api_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_code_oauth_token: Option<String>,
}

impl LegacyApiSection {
    pub fn is_empty(&self) -> bool {
        self.anthropic_api_key.is_none() && self.claude_code_oauth_token.is_none()
    }
}

/// Provider cost/deployment tier for a `[[providers]]` slot.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderTierConfig {
    Local,
    #[default]
    Cloud,
    Free,
    Paid,
    Subscription,
}

fn default_true() -> bool {
    true
}

/// One `[[providers]]` entry feeding `ProviderCascade`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProviderSlotConfig {
    pub name: String,
    pub base_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key_env: Option<String>,
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rpm_limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rpd_limit: Option<u32>,
    #[serde(default)]
    pub tier: ProviderTierConfig,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub privacy: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_k: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_class: Option<String>,
    #[serde(default)]
    pub xml_tool_tags: bool,
}

impl ProviderSlotConfig {
    /// Resolve the effective API key: explicit `api_key` if non-empty, else
    /// env var named by `api_key_env`, else empty string (valid for local Ollama/vLLM).
    pub fn resolve_api_key(&self) -> String {
        if let Some(ref k) = self.api_key {
            let trimmed = k.trim();
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
        if let Some(ref env_name) = self.api_key_env {
            let env_name = env_name.trim();
            if !env_name.is_empty() {
                if let Ok(val) = std::env::var(env_name) {
                    let trimmed = val.trim();
                    if !trimmed.is_empty() {
                        return trimmed.to_string();
                    }
                }
            }
        }
        String::new()
    }
}

/// Fleet operating mode (`grind` | `travel` | `off`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FleetModeConfig {
    Grind,
    Travel,
    #[default]
    Off,
}

impl FleetModeConfig {
    pub fn parse_loose(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "grind" => Some(Self::Grind),
            "travel" => Some(Self::Travel),
            "off" | "" => Some(Self::Off),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Grind => "grind",
            Self::Travel => "travel",
            Self::Off => "off",
        }
    }
}

fn default_desired_workers() -> usize {
    2
}

fn default_harness() -> String {
    "claude".to_string()
}

fn default_disk_floor_gb() -> f64 {
    5.0
}

/// `[fleet]` section of `config.toml`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FleetSection {
    #[serde(default)]
    pub mode: FleetModeConfig,
    #[serde(default = "default_desired_workers")]
    pub desired_workers: usize,
    #[serde(default = "default_harness")]
    pub harness: String,
    #[serde(default = "default_disk_floor_gb")]
    pub disk_floor_gb: f64,
    #[serde(default)]
    pub auto_merge: bool,
}

impl Default for FleetSection {
    fn default() -> Self {
        Self {
            mode: FleetModeConfig::Off,
            desired_workers: default_desired_workers(),
            harness: default_harness(),
            disk_floor_gb: default_disk_floor_gb(),
            auto_merge: false,
        }
    }
}

fn default_subagent_budget_secs() -> u64 {
    900
}

/// `[worker]` section of `config.toml`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WorkerSection {
    #[serde(default)]
    pub cadence_secs: u64,
    #[serde(default = "default_subagent_budget_secs")]
    pub subagent_budget_secs: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disk_floor_gb: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_merge: Option<bool>,
}

impl Default for WorkerSection {
    fn default() -> Self {
        Self {
            cadence_secs: 0,
            subagent_budget_secs: default_subagent_budget_secs(),
            harness: None,
            disk_floor_gb: None,
            auto_merge: None,
        }
    }
}

fn default_bind_addr() -> String {
    "127.0.0.1".to_string()
}

fn default_web_port() -> u16 {
    3847
}

/// `[web]` section of `config.toml`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WebSection {
    #[serde(default = "default_bind_addr")]
    pub bind_addr: String,
    #[serde(default = "default_web_port")]
    pub port: u16,
}

impl Default for WebSection {
    fn default() -> Self {
        Self {
            bind_addr: default_bind_addr(),
            port: default_web_port(),
        }
    }
}

/// `[nats]` section of `config.toml`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NatsSection {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nats_url: Option<String>,
    #[serde(default = "default_true")]
    pub offline_mode: bool,
}

impl Default for NatsSection {
    fn default() -> Self {
        Self {
            nats_url: None,
            offline_mode: true,
        }
    }
}

/// Return the canonical cross-platform `config.toml` path (`CHUMP_CONFIG_FILE`
/// if set, else `chump_pal::chump_home().join("config.toml")`).
pub fn default_config_path() -> PathBuf {
    if let Some(explicit) = std::env::var_os("CHUMP_CONFIG_FILE") {
        let p = PathBuf::from(explicit);
        if !p.as_os_str().is_empty() {
            return p;
        }
    }
    chump_pal::chump_home().join("config.toml")
}

impl ChumpConfig {
    /// Parse a `ChumpConfig` from a TOML string and normalize `[api]` fallbacks into `[auth]`.
    pub fn parse_toml_str(raw: &str, source_path: &Path) -> Result<Self, ConfigError> {
        let mut cfg: ChumpConfig = toml::from_str(raw).map_err(|e| ConfigError::Parse {
            path: source_path.to_path_buf(),
            message: e.to_string(),
        })?;
        cfg.merge_legacy_api_into_auth();
        Ok(cfg)
    }

    /// Load `config.toml` from `path` (returning `Ok(ChumpConfig::default())` if missing).
    pub fn load_from_path(path: &Path) -> Result<Self, ConfigError> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = fs::read_to_string(path).map_err(|source| ConfigError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        Self::parse_toml_str(&raw, path)
    }

    /// Load `default_config_path()`, overlay environment variables, and return the
    /// effective configuration.
    pub fn load_effective() -> Result<Self, ConfigError> {
        let path = default_config_path();
        let mut cfg = Self::load_from_path(&path)?;
        cfg.apply_env_overrides();
        Ok(cfg)
    }

    /// Backwards-compatible merge: fill unset `[auth]` credentials from legacy `[api]`.
    pub fn merge_legacy_api_into_auth(&mut self) {
        if self
            .auth
            .anthropic_api_key
            .as_deref()
            .map(str::trim)
            .unwrap_or("")
            .is_empty()
        {
            if let Some(ref k) = self.api.anthropic_api_key {
                if !k.trim().is_empty() {
                    self.auth.anthropic_api_key = Some(k.trim().to_string());
                }
            }
        }
        if self
            .auth
            .claude_code_oauth_token
            .as_deref()
            .map(str::trim)
            .unwrap_or("")
            .is_empty()
        {
            if let Some(ref t) = self.api.claude_code_oauth_token {
                if !t.trim().is_empty() {
                    self.auth.claude_code_oauth_token = Some(t.trim().to_string());
                }
            }
        }
    }

    /// Overlay non-empty environment variables onto `self` (env always wins over file).
    pub fn apply_env_overrides(&mut self) {
        if let Some(v) = env_nonempty("CHUMP_AUTH_MODE") {
            if let Some(m) = AuthModeConfig::parse_loose(&v) {
                self.auth.mode = m;
            }
        }
        if let Some(v) = env_nonempty("ANTHROPIC_API_KEY") {
            self.auth.anthropic_api_key = Some(v);
        }
        if let Some(v) = env_nonempty("CLAUDE_CODE_OAUTH_TOKEN") {
            self.auth.claude_code_oauth_token = Some(v);
        }
        if let Some(v) = env_nonempty("CHUMP_OAUTH_TOKEN_FILE") {
            self.auth.oauth_token_file = Some(PathBuf::from(v));
        }

        if let Some(v) = env_nonempty("CHUMP_FLEET_MODE") {
            if let Some(m) = FleetModeConfig::parse_loose(&v) {
                self.fleet.mode = m;
            }
        }
        if let Some(v) = env_nonempty("CHUMP_DESIRED_WORKERS").and_then(|s| s.parse::<usize>().ok())
        {
            self.fleet.desired_workers = v;
        }
        if let Some(v) = env_nonempty("CHUMP_AGENT_HARNESS") {
            self.fleet.harness = v;
        }
        if let Some(v) = env_nonempty("CHUMP_DISK_FLOOR_GB")
            .or_else(|| env_nonempty("CHUMP_DISK_CRITICAL_GB"))
            .and_then(|s| s.parse::<f64>().ok())
        {
            self.fleet.disk_floor_gb = v;
        }

        if let Some(v) =
            env_nonempty("CHUMP_WORKER_TICK_CADENCE_S").and_then(|s| s.parse::<u64>().ok())
        {
            self.worker.cadence_secs = v;
        }
        if let Some(v) = env_nonempty("CHUMP_SUBAGENT_BUDGET_S").and_then(|s| s.parse::<u64>().ok())
        {
            self.worker.subagent_budget_secs = v;
        }

        if let Some(v) = env_nonempty("CHUMP_WEB_BIND").or_else(|| env_nonempty("CHUMP_BIND_ADDR"))
        {
            self.web.bind_addr = v;
        }
        if let Some(v) = env_nonempty("CHUMP_WEB_PORT").and_then(|s| s.parse::<u16>().ok()) {
            self.web.port = v;
        }

        if let Some(v) = env_nonempty("CHUMP_NATS_URL").or_else(|| env_nonempty("NATS_URL")) {
            self.nats.nats_url = Some(v);
            if env_nonempty("CHUMP_OFFLINE_MODE").is_none() {
                self.nats.offline_mode = false;
            }
        }
        if let Some(v) = env_nonempty("CHUMP_OFFLINE_MODE") {
            self.nats.offline_mode = v == "1" || v.eq_ignore_ascii_case("true");
        }
    }

    /// Validate structural invariants across all sections.
    pub fn validate(&self) -> Result<(), ConfigError> {
        let mut errs = Vec::new();

        if self.providers.len() > MAX_PROVIDER_SLOTS {
            errs.push(format!(
                "providers count ({}) exceeds maximum supported slots ({MAX_PROVIDER_SLOTS})",
                self.providers.len()
            ));
        }

        for (idx, slot) in self.providers.iter().enumerate() {
            let label = if slot.name.trim().is_empty() {
                format!("providers[{idx}]")
            } else {
                format!("providers[{idx}] ({})", slot.name)
            };
            if slot.name.trim().is_empty() {
                errs.push(format!("{label}: `name` must not be empty"));
            }
            if slot.enabled {
                let u = slot.base_url.trim();
                if !(u.starts_with("http://") || u.starts_with("https://")) {
                    errs.push(format!(
                        "{label}: `base_url` must start with http:// or https:// (got {u:?})"
                    ));
                }
                if slot.model.trim().is_empty() {
                    errs.push(format!("{label}: `model` must not be empty"));
                }
            }
        }

        if self.fleet.desired_workers > 64 {
            errs.push(format!(
                "fleet.desired_workers ({}) must be <= 64",
                self.fleet.desired_workers
            ));
        }
        if self.fleet.harness.trim().is_empty() {
            errs.push("fleet.harness must not be empty".to_string());
        }
        let disk_floor = self.effective_disk_floor_gb();
        if !disk_floor.is_finite() || disk_floor < 0.0 {
            errs.push(format!(
                "disk_floor_gb ({disk_floor}) must be a finite non-negative number"
            ));
        }

        if self.web.bind_addr.trim().is_empty() {
            errs.push("web.bind_addr must not be empty".to_string());
        }
        if self.web.port == 0 {
            errs.push("web.port must be > 0".to_string());
        }

        if let Some(ref url) = self.nats.nats_url {
            let u = url.trim();
            let valid_scheme = u.is_empty()
                || u.starts_with("nats://")
                || u.starts_with("tls://")
                || u.starts_with("ws://")
                || u.starts_with("wss://");
            if !valid_scheme {
                errs.push(format!(
                    "nats.nats_url must start with nats://, tls://, ws://, or wss:// (got {u:?})"
                ));
            }
        }

        if errs.is_empty() {
            Ok(())
        } else {
            Err(ConfigError::Validation(errs))
        }
    }

    /// Effective harness (`worker.harness` override -> `fleet.harness`).
    pub fn effective_harness(&self) -> &str {
        self.worker
            .harness
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(&self.fleet.harness)
    }

    /// Effective disk floor in GiB (`worker.disk_floor_gb` override -> `fleet.disk_floor_gb`).
    pub fn effective_disk_floor_gb(&self) -> f64 {
        self.worker
            .disk_floor_gb
            .unwrap_or(self.fleet.disk_floor_gb)
    }

    /// Effective auto-merge setting (`worker.auto_merge` override -> `fleet.auto_merge`).
    pub fn effective_auto_merge(&self) -> bool {
        self.worker.auto_merge.unwrap_or(self.fleet.auto_merge)
    }

    /// Return a copy with inline secret strings masked (`***REDACTED***`) for safe display.
    pub fn redacted(&self) -> Self {
        let mut copy = self.clone();
        if copy
            .auth
            .anthropic_api_key
            .as_deref()
            .is_some_and(|s| !s.is_empty())
        {
            copy.auth.anthropic_api_key = Some("***REDACTED***".to_string());
        }
        if copy
            .auth
            .claude_code_oauth_token
            .as_deref()
            .is_some_and(|s| !s.is_empty())
        {
            copy.auth.claude_code_oauth_token = Some("***REDACTED***".to_string());
        }
        if copy
            .api
            .anthropic_api_key
            .as_deref()
            .is_some_and(|s| !s.is_empty())
        {
            copy.api.anthropic_api_key = Some("***REDACTED***".to_string());
        }
        if copy
            .api
            .claude_code_oauth_token
            .as_deref()
            .is_some_and(|s| !s.is_empty())
        {
            copy.api.claude_code_oauth_token = Some("***REDACTED***".to_string());
        }
        for p in &mut copy.providers {
            if p.api_key.as_deref().is_some_and(|s| !s.is_empty()) {
                p.api_key = Some("***REDACTED***".to_string());
            }
        }
        copy
    }

    /// Serialize `self` to pretty TOML.
    pub fn to_toml_string(&self) -> Result<String, ConfigError> {
        toml::to_string_pretty(self).map_err(|e| ConfigError::Serialize(e.to_string()))
    }
}

fn env_nonempty(key: &str) -> Option<String> {
    let val = std::env::var(key).ok()?;
    let trimmed = val.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Render a well-commented starter `config.toml` supporting subscription OAuth,
/// cascading BYOK API keys, and local zero-key endpoints (Ollama / LM Studio / vLLM).
pub fn render_starter_toml() -> &'static str {
    r#"# Universal Chump v1.0 Configuration
# Environment variables seamlessly override any setting in this file.

[auth]
# "auto" (prefer subscription OAuth, fall back to API key), "oauth", or "api-key"
mode = "auto"
# anthropic_api_key = ""
# claude_code_oauth_token = ""

# Add up to 40 cascading LLM provider slots (local Ollama/LM Studio/vLLM, OpenCode Zen, BYOK APIs):
# [[providers]]
# name = "ollama-local"
# base_url = "http://127.0.0.1:11434/v1"
# model = "qwen2.5-coder:14b"
# tier = "local"
# rpm_limit = 0
# rpd_limit = 0
# enabled = true

[fleet]
# "grind" | "travel" | "off"
mode = "off"
desired_workers = 2
harness = "claude"
disk_floor_gb = 5.0
auto_merge = false

[worker]
cadence_secs = 0
subagent_budget_secs = 900

[web]
bind_addr = "127.0.0.1"
port = 3847

[nats]
# nats_url = "nats://127.0.0.1:4222"
offline_mode = true
"#
}

/// Write a starter `config.toml` atomically with restricted file permissions (`0600` on Unix).
/// Fails if `path` already exists unless `force == true`.
pub fn write_starter_config(path: &Path, force: bool) -> Result<PathBuf, ConfigError> {
    if path.exists() && !force {
        // Validate existing config so `chump config init` is idempotently helpful.
        let existing = ChumpConfig::load_from_path(path)?;
        existing.validate()?;
        return Ok(path.to_path_buf());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| ConfigError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    let tmp = path.with_extension(format!("toml.tmp.{}", std::process::id()));
    {
        let mut f = fs::File::create(&tmp).map_err(|source| ConfigError::Io {
            path: tmp.clone(),
            source,
        })?;
        f.write_all(render_starter_toml().as_bytes())
            .map_err(|source| ConfigError::Io {
                path: tmp.clone(),
                source,
            })?;
        let _ = f.sync_all();
    }
    let _ = chump_pal::restrict_file_permissions(&tmp);
    fs::rename(&tmp, path).map_err(|source| ConfigError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    Ok(path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn starter_toml_parses_and_validates() {
        let cfg =
            ChumpConfig::parse_toml_str(render_starter_toml(), Path::new("config.toml")).unwrap();
        cfg.validate().expect("starter config must validate");
        assert_eq!(cfg.auth.mode, AuthModeConfig::Auto);
        assert_eq!(cfg.fleet.mode, FleetModeConfig::Off);
        assert_eq!(cfg.fleet.desired_workers, 2);
        assert_eq!(cfg.web.port, 3847);
        assert!(cfg.nats.offline_mode);
    }

    #[test]
    fn legacy_api_section_merges_into_auth() {
        let raw = r#"
[api]
anthropic_api_key = "sk-test-123"
claude_code_oauth_token = "oat-test-456"

[settings]
user_role = "builder"
"#;
        let cfg = ChumpConfig::parse_toml_str(raw, Path::new("legacy.toml")).unwrap();
        assert_eq!(cfg.auth.anthropic_api_key.as_deref(), Some("sk-test-123"));
        assert_eq!(
            cfg.auth.claude_code_oauth_token.as_deref(),
            Some("oat-test-456")
        );
        assert_eq!(
            cfg.settings.get("user_role").and_then(|v| v.as_str()),
            Some("builder")
        );

        let redacted = cfg.redacted();
        assert_eq!(
            redacted.auth.anthropic_api_key.as_deref(),
            Some("***REDACTED***")
        );
        assert_eq!(
            redacted.api.claude_code_oauth_token.as_deref(),
            Some("***REDACTED***")
        );
    }

    #[test]
    fn providers_validate_and_reject_bad_urls() {
        let good = r#"
[[providers]]
name = "ollama"
base_url = "http://localhost:11434/v1"
model = "llama3.2"
tier = "local"

[[providers]]
name = "groq"
base_url = "https://api.groq.com/openai/v1"
api_key_env = "GROQ_API_KEY"
model = "llama-3.3-70b-versatile"
rpm_limit = 30
rpd_limit = 1000
tier = "free"
"#;
        let cfg = ChumpConfig::parse_toml_str(good, Path::new("good.toml")).unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.providers.len(), 2);

        let bad = r#"
[[providers]]
name = ""
base_url = "ftp://invalid"
model = ""
"#;
        let bad_cfg = ChumpConfig::parse_toml_str(bad, Path::new("bad.toml")).unwrap();
        let err = bad_cfg.validate().unwrap_err().to_string();
        assert!(err.contains("name"), "{err}");
        assert!(err.contains("http://"), "{err}");
        assert!(err.contains("model"), "{err}");
    }

    #[test]
    fn write_starter_config_creates_file_idempotently() {
        let tmp = TempDir::new().unwrap();
        let p = tmp.path().join("config.toml");
        write_starter_config(&p, false).unwrap();
        assert!(p.is_file());
        // Second call without force validates and succeeds without error.
        write_starter_config(&p, false).unwrap();
    }
}
