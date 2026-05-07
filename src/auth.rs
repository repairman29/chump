//! Dual-mode authentication: API-key (ANTHROPIC_API_KEY) and subscription OAUTH
//! (CLAUDE_CODE_OAUTH_TOKEN). Resolves which credential to use, handles per-spawn
//! re-evaluation, and emits fleet_auth_fallback when one mode fails.
//!
//! # Precedence
//! Controlled by `CHUMP_AUTH_MODE=auto|api-key|oauth` (default `auto`).
//! In `auto` mode: prefer a non-empty ANTHROPIC_API_KEY, else use OAUTH.
//!
//! # Sources checked (in priority order)
//! 1. Environment variables (ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN)
//! 2. OAUTH refresh file at CHUMP_OAUTH_TOKEN_FILE (written by control.sh every 5 min)
//! 3. ~/.chump/config.toml [api] section (anthropic_api_key / claude_code_oauth_token)

use std::path::{Path, PathBuf};

// ── Types ──────────────────────────────────────────────────────────────────

/// Which auth mode the operator wants.
#[derive(Debug, Clone, PartialEq)]
pub enum AuthMode {
    /// Prefer API key when present and non-empty; fall back to OAUTH.
    Auto,
    /// Always use ANTHROPIC_API_KEY; error if absent.
    ApiKey,
    /// Always use CLAUDE_CODE_OAUTH_TOKEN (subscription); error if absent.
    OAuth,
}

impl AuthMode {
    fn from_env() -> Self {
        match std::env::var("CHUMP_AUTH_MODE")
            .unwrap_or_default()
            .to_ascii_lowercase()
            .trim()
            .to_string()
            .as_str()
        {
            "api-key" | "api_key" | "apikey" => AuthMode::ApiKey,
            "oauth" => AuthMode::OAuth,
            _ => AuthMode::Auto,
        }
    }
}

/// Raw credentials loaded from all sources.
#[derive(Debug, Clone, Default)]
pub struct AuthCredentials {
    /// Value of ANTHROPIC_API_KEY (env, then config.toml).
    pub api_key: String,
    /// Value of CLAUDE_CODE_OAUTH_TOKEN (env, refresh file, then config.toml).
    pub oauth_token: String,
}

impl AuthCredentials {
    pub fn has_api_key(&self) -> bool {
        !self.api_key.trim().is_empty()
    }

    pub fn has_oauth(&self) -> bool {
        !self.oauth_token.trim().is_empty()
    }
}

/// The resolved auth state for one spawn / re-evaluation cycle.
#[derive(Debug, Clone)]
pub struct ActiveAuth {
    /// Which mode is currently active.
    pub mode: ActiveMode,
    /// The raw credentials that were loaded (both may be set; `mode` says which to use).
    pub creds: AuthCredentials,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ActiveMode {
    ApiKey,
    OAuth,
    /// Neither mode has credentials — auth will fail.
    None,
}

impl ActiveAuth {
    /// Env var pairs to inject into `claude -p` spawns.
    /// Returns `(key, value)` pairs; callers set them in the child environment.
    pub fn env_pairs(&self) -> Vec<(String, String)> {
        match self.mode {
            ActiveMode::ApiKey => vec![
                ("ANTHROPIC_API_KEY".into(), self.creds.api_key.clone()),
                ("CLAUDE_CODE_OAUTH_TOKEN".into(), String::new()),
            ],
            ActiveMode::OAuth => vec![
                (
                    "CLAUDE_CODE_OAUTH_TOKEN".into(),
                    self.creds.oauth_token.clone(),
                ),
                ("ANTHROPIC_API_KEY".into(), String::new()),
            ],
            ActiveMode::None => vec![],
        }
    }

    /// Returns the alternate `ActiveAuth` to try after a 401, or `None` if no fallback.
    /// Also emits a `fleet_auth_fallback` event to ambient.jsonl.
    pub fn on_auth_failure(&self, ambient_path: Option<&Path>) -> Option<ActiveAuth> {
        let fallback = match self.mode {
            ActiveMode::ApiKey if self.creds.has_oauth() => Some(ActiveAuth {
                mode: ActiveMode::OAuth,
                creds: self.creds.clone(),
            }),
            ActiveMode::OAuth if self.creds.has_api_key() => Some(ActiveAuth {
                mode: ActiveMode::ApiKey,
                creds: self.creds.clone(),
            }),
            _ => None,
        };

        if let Some(ref fb) = fallback {
            let failed = format!("{:?}", self.mode).to_lowercase();
            let next = format!("{:?}", fb.mode).to_lowercase();
            let ts = chrono_ts();
            let event = format!(
                "{{\"ts\":\"{ts}\",\"kind\":\"fleet_auth_fallback\",\"failed_mode\":\"{failed}\",\"fallback_mode\":\"{next}\"}}\n"
            );
            emit_ambient(ambient_path, &event);
        }

        fallback
    }

    pub fn is_none(&self) -> bool {
        self.mode == ActiveMode::None
    }
}

// ── Detection ──────────────────────────────────────────────────────────────

/// Detect all available credentials from env, refresh file, and config.toml.
/// Call this at startup and before each worker spawn for re-evaluation.
pub fn detect_credentials() -> AuthCredentials {
    let mut creds = AuthCredentials::default();

    // 1. Environment (highest priority)
    creds.api_key = std::env::var("ANTHROPIC_API_KEY")
        .unwrap_or_default()
        .trim()
        .to_string();
    creds.oauth_token = std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
        .unwrap_or_default()
        .trim()
        .to_string();

    // 2. OAUTH refresh file (CHUMP_OAUTH_TOKEN_FILE written by control.sh every 5 min)
    //    Only overrides oauth_token when env is empty.
    if creds.oauth_token.is_empty() {
        if let Ok(tok_path) = std::env::var("CHUMP_OAUTH_TOKEN_FILE") {
            if let Some(tok) = read_oauth_token_file(Path::new(&tok_path)) {
                creds.oauth_token = tok;
            }
        }
    }

    // 3. ~/.chump/config.toml — fills blanks not covered by env or refresh file
    if creds.api_key.is_empty() || creds.oauth_token.is_empty() {
        if let Some(cfg) = read_config_toml(&chump_config_path()) {
            if creds.api_key.is_empty() {
                creds.api_key = cfg.api_key;
            }
            if creds.oauth_token.is_empty() {
                creds.oauth_token = cfg.oauth_token;
            }
        }
    }

    creds
}

/// Resolve which auth mode to activate given operator preference and available creds.
pub fn resolve(creds: AuthCredentials) -> ActiveAuth {
    let mode = match AuthMode::from_env() {
        AuthMode::ApiKey => {
            if creds.has_api_key() {
                ActiveMode::ApiKey
            } else {
                ActiveMode::None
            }
        }
        AuthMode::OAuth => {
            if creds.has_oauth() {
                ActiveMode::OAuth
            } else {
                ActiveMode::None
            }
        }
        AuthMode::Auto => {
            // Prefer API key; fall back to OAUTH.
            if creds.has_api_key() {
                ActiveMode::ApiKey
            } else if creds.has_oauth() {
                ActiveMode::OAuth
            } else {
                ActiveMode::None
            }
        }
    };
    ActiveAuth { mode, creds }
}

/// Convenience: detect + resolve in one call. Use before each worker spawn.
pub fn detect_and_resolve() -> ActiveAuth {
    resolve(detect_credentials())
}

// ── Fleet doctor ───────────────────────────────────────────────────────────

#[derive(Debug)]
pub struct DoctorReport {
    pub api_key_ok: bool,
    pub oauth_ok: bool,
    pub active_mode: ActiveMode,
    pub warnings: Vec<String>,
}

/// Validates both auth paths and returns a report. Used by `chump fleet doctor`.
pub fn fleet_doctor_validate() -> DoctorReport {
    let creds = detect_credentials();
    let auth = resolve(creds.clone());

    let mut warnings = Vec::new();

    if !creds.has_api_key() && !creds.has_oauth() {
        warnings.push(
            "No auth credentials found. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN.".into(),
        );
    }

    let mode_env = std::env::var("CHUMP_AUTH_MODE").unwrap_or_else(|_| "auto".into());
    if mode_env.eq_ignore_ascii_case("api-key") && !creds.has_api_key() {
        warnings.push("CHUMP_AUTH_MODE=api-key but ANTHROPIC_API_KEY is absent or empty.".into());
    }
    if mode_env.eq_ignore_ascii_case("oauth") && !creds.has_oauth() {
        warnings.push(
            "CHUMP_AUTH_MODE=oauth but no OAUTH token found (env, refresh file, or config.toml)."
                .into(),
        );
    }
    if auth.mode == ActiveMode::None {
        warnings
            .push("Resolved auth mode is None — workers will fail at first claude -p call.".into());
    }
    if creds.has_api_key() && creds.has_oauth() {
        // Both present: make the active choice visible.
        let inactive = if auth.mode == ActiveMode::ApiKey {
            "OAUTH"
        } else {
            "API key"
        };
        warnings.push(format!(
            "Both API key and OAUTH token present. {inactive} is configured as fallback only."
        ));
    }

    DoctorReport {
        api_key_ok: creds.has_api_key(),
        oauth_ok: creds.has_oauth(),
        active_mode: auth.mode,
        warnings,
    }
}

// ── Internal helpers ───────────────────────────────────────────────────────

/// Parse a JSON token file written by control.sh:
/// `{"token":"sk-ant-oat01-...","written_at":"...","source":"..."}` or
/// `{"access_token":"..."}` (Claude Code's own format).
fn read_oauth_token_file(path: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(path).ok()?;
    // Try the fields we know about.
    for key in &["token", "access_token", "claudeAiOauthToken"] {
        if let Some(tok) = extract_json_string(&raw, key) {
            if !tok.is_empty() {
                return Some(tok);
            }
        }
    }
    None
}

/// Extremely minimal JSON string extractor — avoids pulling in serde just for auth.
/// Finds `"key":"value"` in a flat JSON object.
fn extract_json_string(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\"", key);
    let start = json.find(&needle)? + needle.len();
    let after = json[start..].trim_start();
    let after = after.strip_prefix(':')?.trim_start();
    let after = after.strip_prefix('"')?;
    let end = after.find('"')?;
    Some(after[..end].to_string())
}

/// Parse the subset of ~/.chump/config.toml relevant to auth.
fn read_config_toml(path: &Path) -> Option<AuthCredentials> {
    let content = std::fs::read_to_string(path).ok()?;
    let mut creds = AuthCredentials::default();
    let mut in_api = false;

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_api = trimmed == "[api]";
            continue;
        }
        if !in_api || trimmed.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = parse_toml_kv(trimmed) {
            match k {
                "anthropic_api_key" => creds.api_key = v.to_string(),
                "claude_code_oauth_token" => creds.oauth_token = v.to_string(),
                _ => {}
            }
        }
    }

    if creds.has_api_key() || creds.has_oauth() {
        Some(creds)
    } else {
        None
    }
}

/// Parse `key = "value"` or `key = value` (no quotes) from a TOML line.
fn parse_toml_kv(line: &str) -> Option<(&str, &str)> {
    let (k, rest) = line.split_once('=')?;
    let k = k.trim();
    let v = rest.trim().trim_matches('"');
    Some((k, v))
}

fn chump_config_path() -> PathBuf {
    let home = std::env::var("CHUMP_HOME")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".chump").join("config.toml")
}

fn chrono_ts() -> String {
    // RFC3339-ish without pulling in chrono. Good enough for ambient log.
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Format as approximate ISO8601 — operators use this for "recent?" checks only.
    let (y, mo, d, h, mi, s) = secs_to_ymd_hms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn secs_to_ymd_hms(secs: u64) -> (u32, u32, u32, u32, u32, u32) {
    let s = (secs % 60) as u32;
    let m = ((secs / 60) % 60) as u32;
    let h = ((secs / 3600) % 24) as u32;
    let days = (secs / 86400) as u32;
    // Gregorian calendar approximation (good until 2100)
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    (y, mo, d, h, m, s)
}

fn emit_ambient(path: Option<&Path>, event: &str) {
    let p = path.map(|p| p.to_path_buf()).unwrap_or_else(|| {
        PathBuf::from(
            std::env::var("CHUMP_AMBIENT_LOG")
                .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".into()),
        )
    });
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&p)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(event.as_bytes())
        });
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Env var tests must be serialized — env is process-global.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_env<F: FnOnce()>(vars: &[(&str, &str)], cleared: &[&str], f: F) {
        let _guard = ENV_LOCK.lock().unwrap();
        let saved: Vec<(String, Option<String>)> = vars
            .iter()
            .map(|(k, _)| (k.to_string(), std::env::var(k).ok()))
            .chain(
                cleared
                    .iter()
                    .map(|k| (k.to_string(), std::env::var(k).ok())),
            )
            .collect();
        for (k, v) in vars {
            std::env::set_var(k, v);
        }
        for k in cleared {
            std::env::remove_var(k);
        }
        f();
        for (k, v) in &saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    // ── Quadrant 1: API key only ────────────────────────────────────────────

    #[test]
    fn api_key_only_resolves_api_key_mode() {
        with_env(
            &[("ANTHROPIC_API_KEY", "sk-ant-key123")],
            &[
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::ApiKey);
                assert!(auth.creds.has_api_key());
                assert!(!auth.creds.has_oauth());
                let pairs = auth.env_pairs();
                assert!(pairs
                    .iter()
                    .any(|(k, v)| k == "ANTHROPIC_API_KEY" && v == "sk-ant-key123"));
                assert!(pairs
                    .iter()
                    .any(|(k, v)| k == "CLAUDE_CODE_OAUTH_TOKEN" && v.is_empty()));
            },
        );
    }

    // ── Quadrant 2: OAUTH only ─────────────────────────────────────────────

    #[test]
    fn oauth_only_resolves_oauth_mode() {
        with_env(
            &[("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-tok")],
            &[
                "ANTHROPIC_API_KEY",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::OAuth);
                assert!(!auth.creds.has_api_key());
                assert!(auth.creds.has_oauth());
                let pairs = auth.env_pairs();
                assert!(pairs
                    .iter()
                    .any(|(k, v)| k == "CLAUDE_CODE_OAUTH_TOKEN" && v == "sk-ant-oat01-tok"));
                assert!(pairs
                    .iter()
                    .any(|(k, v)| k == "ANTHROPIC_API_KEY" && v.is_empty()));
            },
        );
    }

    // ── Quadrant 3: both present — API key preferred in auto mode ──────────

    #[test]
    fn both_present_auto_prefers_api_key() {
        with_env(
            &[
                ("ANTHROPIC_API_KEY", "sk-ant-key"),
                ("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-tok"),
            ],
            &["CHUMP_AUTH_MODE", "CHUMP_OAUTH_TOKEN_FILE", "CHUMP_HOME"],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::ApiKey);
                assert!(auth.creds.has_api_key());
                assert!(auth.creds.has_oauth());
            },
        );
    }

    #[test]
    fn both_present_mode_override_forces_oauth() {
        with_env(
            &[
                ("ANTHROPIC_API_KEY", "sk-ant-key"),
                ("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-tok"),
                ("CHUMP_AUTH_MODE", "oauth"),
            ],
            &["CHUMP_OAUTH_TOKEN_FILE", "CHUMP_HOME"],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::OAuth);
            },
        );
    }

    // ── Quadrant 4: neither present ────────────────────────────────────────

    #[test]
    fn neither_present_resolves_none() {
        with_env(
            &[],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::None);
                assert!(auth.is_none());
                assert!(auth.env_pairs().is_empty());
            },
        );
    }

    // ── Fallback (401 handling) ─────────────────────────────────────────────

    #[test]
    fn api_key_fallback_to_oauth_on_401() {
        let creds = AuthCredentials {
            api_key: "sk-ant-key".into(),
            oauth_token: "sk-ant-oat01-tok".into(),
        };
        let auth = ActiveAuth {
            mode: ActiveMode::ApiKey,
            creds,
        };
        let fallback = auth.on_auth_failure(None);
        assert!(fallback.is_some());
        let fb = fallback.unwrap();
        assert_eq!(fb.mode, ActiveMode::OAuth);
    }

    #[test]
    fn oauth_fallback_to_api_key_on_401() {
        let creds = AuthCredentials {
            api_key: "sk-ant-key".into(),
            oauth_token: "sk-ant-oat01-tok".into(),
        };
        let auth = ActiveAuth {
            mode: ActiveMode::OAuth,
            creds,
        };
        let fallback = auth.on_auth_failure(None);
        assert!(fallback.is_some());
        assert_eq!(fallback.unwrap().mode, ActiveMode::ApiKey);
    }

    #[test]
    fn no_fallback_when_only_one_cred() {
        let creds = AuthCredentials {
            api_key: "sk-ant-key".into(),
            oauth_token: String::new(),
        };
        let auth = ActiveAuth {
            mode: ActiveMode::ApiKey,
            creds,
        };
        let fallback = auth.on_auth_failure(None);
        assert!(fallback.is_none());
    }

    // ── OAuth token file ───────────────────────────────────────────────────

    #[test]
    fn reads_oauth_token_from_refresh_file() {
        let dir = tempfile::tempdir().unwrap();
        let tok_path = dir.path().join("oauth-token.json");
        std::fs::write(
            &tok_path,
            r#"{"token":"sk-ant-oat01-fresh","written_at":"2026-05-06T00:00:00Z"}"#,
        )
        .unwrap();

        with_env(
            &[("CHUMP_OAUTH_TOKEN_FILE", tok_path.to_str().unwrap())],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_HOME",
            ],
            || {
                let creds = detect_credentials();
                assert_eq!(creds.oauth_token, "sk-ant-oat01-fresh");
            },
        );
    }

    #[test]
    fn config_toml_parsed_correctly() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        std::fs::write(&cfg, "[api]\nanthropic_api_key = \"sk-ant-cfgkey\"\n").unwrap();

        let result = read_config_toml(&cfg);
        assert!(result.is_some());
        let creds = result.unwrap();
        assert_eq!(creds.api_key, "sk-ant-cfgkey");
    }

    // ── JSON extractor ─────────────────────────────────────────────────────

    #[test]
    fn extract_json_string_basic() {
        let json = r#"{"token":"sk-ant-oat01-test","written_at":"2026-05-06"}"#;
        assert_eq!(
            extract_json_string(json, "token"),
            Some("sk-ant-oat01-test".into())
        );
    }

    #[test]
    fn extract_json_string_access_token() {
        let json = r#"{"access_token":"bearer-tok","expires_in":3600}"#;
        assert_eq!(
            extract_json_string(json, "access_token"),
            Some("bearer-tok".into())
        );
    }

    // ── Fleet doctor ───────────────────────────────────────────────────────

    #[test]
    fn fleet_doctor_warns_when_no_creds() {
        with_env(
            &[],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let report = fleet_doctor_validate();
                assert!(!report.api_key_ok);
                assert!(!report.oauth_ok);
                assert_eq!(report.active_mode, ActiveMode::None);
                assert!(!report.warnings.is_empty());
            },
        );
    }

    #[test]
    fn fleet_doctor_clean_with_api_key() {
        with_env(
            &[("ANTHROPIC_API_KEY", "sk-ant-key")],
            &[
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let report = fleet_doctor_validate();
                assert!(report.api_key_ok);
                assert_eq!(report.active_mode, ActiveMode::ApiKey);
                // No critical warnings (might have "both present" note, but not error warnings)
                let has_error = report.warnings.iter().any(|w| w.contains("will fail"));
                assert!(!has_error);
            },
        );
    }
}
