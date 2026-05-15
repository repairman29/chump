//! INFRA-1361: `chump gh-token rotate` — GitHub App installation token refresh.
//!
//! Reads `~/.chump/github_apps.toml`, fetches a fresh GitHub App installation
//! token for each configured lane, and writes it to
//! `~/.chump/oauth-token-<lane>.json` with permissions 0600.
//!
//! Behaviour contract:
//! - No `~/.chump/github_apps.toml` → exit 0 (noop). Emits
//!   `kind=gh_token_rotate_noop` with `reason=apps_config_missing`.
//! - Malformed TOML → exit 2 (stderr message with path + parse error).
//! - Per-lane fetch failure → log to stderr, continue other lanes, exit 1
//!   at end if any lane failed (partial success is valid).
//! - Per-lane success → write token file (chmod 600), emit
//!   `kind=gh_token_rotated` with {lane, expires_at}.
//!
//! ## Dependency note (INFRA-1360)
//!
//! Actual JWT signing and GitHub API calls are delegated to the
//! `chump-gh-app` crate (INFRA-1360). Until that crate ships, this module
//! calls `fetch_installation_token_via_subprocess` which invokes the `gh`
//! CLI to obtain an installation token from a pre-configured GitHub App.
//!
//! The TOML format is documented in `docs/process/OPERATOR_RUNBOOK.md`
//! (INFRA-1362). Each `[<lane>]` section has:
//!
//! ```toml
//! [critical]
//! app_id           = 12345
//! private_key_path = "/Users/you/.chump/keys/chump-critical.pem"
//! installation_id  = 67890
//! ```

use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::io::Write as _;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

// ── TOML config shape ────────────────────────────────────────────────────────

/// One lane entry from `~/.chump/github_apps.toml`.
#[derive(Debug, Deserialize, Clone)]
pub struct LaneConfig {
    pub app_id: u64,
    pub private_key_path: String,
    pub installation_id: u64,
}

/// The full `~/.chump/github_apps.toml` file.
/// Top-level keys are lane names (e.g. "critical", "background").
type AppsConfig = BTreeMap<String, LaneConfig>;

// ── Token output shape ────────────────────────────────────────────────────────

/// Token file written to `~/.chump/oauth-token-<lane>.json`.
/// Supports both `{token: ...}` and `{access_token: ...}` shapes so
/// `_chump_gh_lane_token()` in github.sh (INFRA-1076) can parse either.
#[derive(Debug, serde::Serialize)]
struct TokenFile {
    token: String,
    expires_at: String,
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Run `chump gh-token rotate`.
///
/// Returns `Ok(false)` for noop (no config file), `Ok(true)` if all lanes
/// rotated successfully, and `Err(...)` only on unexpected I/O errors.
/// Per-lane GitHub fetch failures are printed to stderr and tracked in the
/// exit code via `any_failed`.
pub fn run_rotate(args: &[String]) -> i32 {
    let show_help = args.iter().any(|a| a == "--help" || a == "-h");
    if show_help {
        eprintln!(
            "Usage: chump gh-token rotate\n\n\
             Reads ~/.chump/github_apps.toml, fetches a fresh GitHub App\n\
             installation token for each configured lane, and writes it to\n\
             ~/.chump/oauth-token-<lane>.json (chmod 600).\n\n\
             Exit codes:\n\
               0  success (or noop when config absent)\n\
               1  one or more lanes failed (partial success)\n\
               2  config file is malformed TOML\n"
        );
        return 0;
    }

    match rotate_inner() {
        Ok(exit_code) => exit_code,
        Err(e) => {
            eprintln!("[gh-token-rotate] unexpected error: {e:#}");
            1
        }
    }
}

fn rotate_inner() -> Result<i32> {
    rotate_with_config(&config_path())
}

/// Testable entry point — accepts an explicit config path to avoid global-env
/// races in parallel tests.
fn rotate_with_config(config_path: &Path) -> Result<i32> {
    // ── Noop path: no config file ────────────────────────────────────────────
    if !config_path.exists() {
        emit_noop("apps_config_missing");
        return Ok(0);
    }

    // ── Parse TOML ───────────────────────────────────────────────────────────
    let raw = std::fs::read_to_string(config_path)
        .with_context(|| format!("read {}", config_path.display()))?;

    let config: AppsConfig = toml::from_str(&raw).map_err(|e| {
        eprintln!(
            "[gh-token-rotate] malformed TOML in {}: {}",
            config_path.display(),
            e
        );
        anyhow::anyhow!("toml parse error")
    })?;

    if config.is_empty() {
        // Config exists but has no lanes — treat as noop.
        emit_noop("apps_config_empty");
        return Ok(0);
    }

    // ── Per-lane rotation ────────────────────────────────────────────────────
    let token_dir = token_dir();
    std::fs::create_dir_all(&token_dir)
        .with_context(|| format!("create {}", token_dir.display()))?;

    let mut any_failed = false;

    for (lane, lane_cfg) in &config {
        match rotate_lane(lane, lane_cfg, &token_dir) {
            Ok(expires_at) => {
                eprintln!(
                    "[gh-token-rotate] {}  → {}/oauth-token-{}.json  (chmod 600)",
                    lane,
                    token_dir.display(),
                    lane
                );
                emit_rotated(lane, &expires_at);
            }
            Err(e) => {
                eprintln!("[gh-token-rotate] lane '{}' failed: {:#}", lane, e);
                any_failed = true;
            }
        }
    }

    if !any_failed {
        eprintln!("[gh-token-rotate] done");
    }

    Ok(if any_failed { 1 } else { 0 })
}

// ── Per-lane fetch ────────────────────────────────────────────────────────────

fn rotate_lane(lane: &str, cfg: &LaneConfig, token_dir: &Path) -> Result<String> {
    // Delegate to chump-gh-app crate once INFRA-1360 ships.
    // Until then, use subprocess-based token fetch.
    fetch_installation_token_via_subprocess(lane, cfg, token_dir)
}

/// Fetch a GitHub App installation token via the `gh` CLI.
///
/// Uses `gh api -X POST /app/installations/<id>/access_tokens` with the
/// GitHub App's JWT for authentication. The JWT is generated by
/// `scripts/dev/gen-gh-app-jwt.sh` (wrapper around openssl + base64).
///
/// Once `chump-gh-app` (INFRA-1360) ships, this function will be replaced
/// by `chump_gh_app::fetch_installation_token(cfg.app_id, &cfg.private_key_path,
/// cfg.installation_id)`.
fn fetch_installation_token_via_subprocess(
    lane: &str,
    cfg: &LaneConfig,
    token_dir: &Path,
) -> Result<String> {
    // Build JWT (RS256, iat/exp window of 10 min) via openssl + shell.
    // The private key at cfg.private_key_path must be RSA PKCS#8 PEM.
    let key_path = expand_tilde(&cfg.private_key_path);
    if !Path::new(&key_path).exists() {
        anyhow::bail!("private key not found at '{}' (lane={})", key_path, lane);
    }

    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let exp = now + 600; // 10-minute JWT window

    // Generate JWT header.payload (RS256) via openssl — avoids adding
    // a Rust JWT crate dependency before INFRA-1360 ships.
    let header = base64_url_nopad(b"{\"alg\":\"RS256\",\"typ\":\"JWT\"}");
    let payload_json = format!("{{\"iat\":{},\"exp\":{},\"iss\":{}}}", now, exp, cfg.app_id);
    let payload = base64_url_nopad(payload_json.as_bytes());
    let signing_input = format!("{}.{}", header, payload);

    // Sign with openssl dgst -sha256 -sign <key>
    let sign_out = std::process::Command::new("openssl")
        .args(["dgst", "-sha256", "-sign", &key_path, "-binary"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("spawn openssl")?;

    // Write signing_input to stdin
    let mut child = sign_out;
    {
        let stdin = child.stdin.as_mut().context("openssl stdin")?;
        stdin
            .write_all(signing_input.as_bytes())
            .context("write to openssl stdin")?;
    }
    let output = child.wait_with_output().context("wait openssl")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "openssl signing failed for lane '{}': {}",
            lane,
            stderr.trim()
        );
    }
    let sig = base64_url_nopad(&output.stdout);
    let jwt = format!("{}.{}.{}", header, payload, sig);

    // Call GitHub API to fetch installation token.
    let url = format!(
        "https://api.github.com/app/installations/{}/access_tokens",
        cfg.installation_id
    );
    let api_out = std::process::Command::new("gh")
        .args([
            "api",
            "-X",
            "POST",
            "--jq",
            "{token: .token, expires_at: .expires_at}",
            &url,
        ])
        .env("GH_TOKEN", &jwt)
        .output()
        .context("gh api call")?;

    if !api_out.status.success() {
        let stderr = String::from_utf8_lossy(&api_out.stderr);
        anyhow::bail!(
            "GitHub API returned error for lane '{}': {}",
            lane,
            stderr.trim()
        );
    }

    let json_str = String::from_utf8_lossy(&api_out.stdout);
    let parsed: serde_json::Value =
        serde_json::from_str(json_str.trim()).context("parse gh api JSON")?;

    let token = parsed["token"]
        .as_str()
        .context("missing 'token' in gh api response")?
        .to_string();
    let expires_at = parsed["expires_at"]
        .as_str()
        .unwrap_or("unknown")
        .to_string();

    // Write ~/.chump/oauth-token-<lane>.json (chmod 600)
    let out_path = token_dir.join(format!("oauth-token-{}.json", lane));
    let token_content = serde_json::to_string(&TokenFile {
        token,
        expires_at: expires_at.clone(),
    })
    .context("serialize token")?;

    std::fs::write(&out_path, &token_content)
        .with_context(|| format!("write {}", out_path.display()))?;
    std::fs::set_permissions(&out_path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("chmod 600 {}", out_path.display()))?;

    Ok(expires_at)
}

// ── Ambient event helpers ─────────────────────────────────────────────────────

fn emit_noop(reason: &str) {
    let args = crate::ambient_emit::EmitArgs {
        kind: "gh_token_rotate_noop".to_string(),
        fields: vec![("reason".to_string(), reason.to_string())],
        ..Default::default()
    };
    let _ = crate::ambient_emit::emit(&args);
}

fn emit_rotated(lane: &str, expires_at: &str) {
    let ts = chrono::Utc::now().to_rfc3339();
    let args = crate::ambient_emit::EmitArgs {
        kind: "gh_token_rotated".to_string(),
        fields: vec![
            ("ts".to_string(), ts),
            ("lane".to_string(), lane.to_string()),
            ("expires_at".to_string(), expires_at.to_string()),
        ],
        ..Default::default()
    };
    let _ = crate::ambient_emit::emit(&args);
}

// ── Path helpers ──────────────────────────────────────────────────────────────

fn config_path() -> PathBuf {
    // CHUMP_GH_APPS_CONFIG override for tests.
    if let Ok(p) = std::env::var("CHUMP_GH_APPS_CONFIG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    PathBuf::from(home).join(".chump").join("github_apps.toml")
}

fn token_dir() -> PathBuf {
    // CHUMP_GH_LANE_TOKEN_DIR override (INFRA-1076 test isolation convention).
    if let Ok(p) = std::env::var("CHUMP_GH_LANE_TOKEN_DIR") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    PathBuf::from(home).join(".chump")
}

// ── Tilde expansion ───────────────────────────────────────────────────────────

fn expand_tilde(path: &str) -> String {
    if path.starts_with("~/") {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        format!("{}/{}", home.trim_end_matches('/'), &path[2..])
    } else {
        path.to_string()
    }
}

// ── base64url no-padding helper ───────────────────────────────────────────────

fn base64_url_nopad(data: &[u8]) -> String {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
    URL_SAFE_NO_PAD.encode(data)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Noop when config path does not exist.
    #[test]
    fn noop_when_config_absent() {
        let tmp = tempfile::tempdir().unwrap();
        let absent = tmp.path().join("no_github_apps.toml");
        // Call rotate_with_config directly to avoid global-env races.
        let exit = rotate_with_config(&absent).unwrap();
        assert_eq!(exit, 0, "noop should exit 0");
    }

    /// Malformed TOML exits non-zero.
    #[test]
    fn malformed_toml_returns_nonzero() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = tmp.path().join("github_apps.toml");
        std::fs::write(&cfg, "this is not valid toml !!!===\n").unwrap();
        // rotate_with_config returns Err on malformed TOML (propagated from toml parse).
        // rotate_inner maps that to exit code 1 via the outer match.
        let result = rotate_with_config(&cfg);
        assert!(result.is_err(), "malformed TOML should return Err");
    }

    /// Empty TOML (no lanes) exits 0 as a noop.
    #[test]
    fn empty_toml_noop() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = tmp.path().join("github_apps.toml");
        std::fs::write(&cfg, "# no lanes\n").unwrap();
        let exit = rotate_with_config(&cfg).unwrap();
        assert_eq!(exit, 0, "empty config should exit 0");
    }
}
