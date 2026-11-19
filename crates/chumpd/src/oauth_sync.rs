//! Cross-platform subscription OAuth token sync & refresher (`Milestone 4`).
//!
//! Replaces `scripts/coord/oauth-token-refresh.sh` with a native background task
//! inside `chumpd`:
//! - On macOS: probes Keychain (`security find-generic-password -s "Claude Code-credentials" -w`)
//!   first, then falls back to `~/.claude/.credentials.json`.
//! - On Windows & Linux: probes `%USERPROFILE%\.claude\.credentials.json` /
//!   `~/.claude/.credentials.json`.
//! - Preserves pinned long-lived `sk-ant-oat*` setup-tokens (`RESILIENT-1566`) while
//!   refreshing `written_at` + file `mtime` (`RESILIENT-410`).
//! - Writes `oauth-token.json` atomically with restricted file permissions
//!   (`chump_pal::restrict_file_permissions`).

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::{SecondsFormat, Utc};

/// Default refresh cadence: 5 minutes (matches `INFRA-622` / `INFRA-2124`).
pub const DEFAULT_OAUTH_REFRESH_INTERVAL_SECS: u64 = 300;

/// Result of a single OAuth sync cycle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OAuthSyncStatus {
    /// Wrote a new or updated token into `oauth-token.json`.
    Updated,
    /// Re-published an existing pinned `sk-ant-oat*` token to keep `mtime` fresh.
    RefreshedPinnedMtime,
    /// Existing token on disk already matches extracted token (and is fresh).
    Unchanged,
    /// Neither Keychain nor `.credentials.json` held a usable subscription token.
    NoSourceFound,
}

/// Summary of one [`sync_once_to`] execution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OAuthSyncOutcome {
    pub status: OAuthSyncStatus,
    pub source: Option<String>,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Extract `(token, expires_at_ms)` from a Claude Code Keychain or `.credentials.json`
/// payload (nested `claudeAiOauth`, flat JSON object, or raw `sk-ant-oat*` string).
pub fn extract_oauth_from_json_or_raw(raw: &str) -> Option<(String, Option<i64>)> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(trimmed) {
        let scope = val.get("claudeAiOauth").unwrap_or(&val);
        let tok = ["accessToken", "access_token", "token", "claudeAiOauthToken"]
            .iter()
            .find_map(|k| {
                scope
                    .get(*k)
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
            })?;
        let expires_at = scope
            .get("expiresAt")
            .or_else(|| scope.get("expires_at"))
            .and_then(|x| {
                x.as_i64()
                    .or_else(|| x.as_str().and_then(|s| s.trim().parse::<i64>().ok()))
            });
        if let Some(exp) = expires_at {
            if exp <= now_ms() {
                let has_refresh = scope
                    .get("refreshToken")
                    .and_then(|v| v.as_str())
                    .is_some_and(|s| !s.trim().is_empty());
                if !has_refresh {
                    return None;
                }
            }
        }
        return Some((tok.to_string(), expires_at));
    }

    // Raw single-line token fallback (e.g. plain token stored in Keychain).
    if !trimmed.contains(char::is_whitespace) && trimmed.starts_with("sk-ant-") {
        return Some((trimmed.to_string(), None));
    }
    None
}

#[cfg(target_os = "macos")]
fn probe_macos_keychain() -> Option<(String, Option<i64>, String)> {
    let service = std::env::var("CHUMP_OAUTH_KEYCHAIN_SERVICE")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Claude Code-credentials".to_string());

    let out = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", &service, "-w"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let raw = String::from_utf8_lossy(&out.stdout);
    let (tok, exp) = extract_oauth_from_json_or_raw(&raw)?;
    Some((tok, exp, format!("macos-keychain:{service}")))
}

fn probe_claude_credentials_file(explicit: Option<&Path>) -> Option<(String, Option<i64>, String)> {
    let candidates: Vec<PathBuf> = if let Some(p) = explicit {
        vec![p.to_path_buf()]
    } else if let Ok(env_p) = std::env::var("CHUMP_CLAUDE_CREDENTIALS_FILE") {
        let t = env_p.trim();
        if t.is_empty() {
            vec![]
        } else {
            vec![PathBuf::from(t)]
        }
    } else {
        let mut v = vec![chump_pal::state_base_dir()
            .join(".claude")
            .join(".credentials.json")];
        let home_cand = chump_pal::user_home()
            .join(".claude")
            .join(".credentials.json");
        if !v.contains(&home_cand) {
            v.push(home_cand);
        }
        v
    };

    for path in candidates {
        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        if let Some((tok, exp)) = extract_oauth_from_json_or_raw(&raw) {
            return Some((tok, exp, format!("credentials-file:{}", path.display())));
        }
    }
    None
}

fn read_existing_token_file(path: &Path) -> Option<(String, Option<i64>, Option<String>)> {
    let raw = fs::read_to_string(path).ok()?;
    let val: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let tok = val
        .get("token")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())?
        .to_string();
    let exp = val.get("expires_at").and_then(|v| v.as_i64());
    let src = val
        .get("source")
        .and_then(|v| v.as_str())
        .map(ToOwned::to_owned);
    Some((tok, exp, src))
}

fn write_oauth_token_atomic(
    dest: &Path,
    token: &str,
    expires_at: Option<i64>,
    source: &str,
) -> io::Result<()> {
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    let written_at = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
    let mut obj = serde_json::Map::new();
    obj.insert("token".into(), serde_json::Value::String(token.to_string()));
    if let Some(exp) = expires_at {
        obj.insert("expires_at".into(), serde_json::Value::Number(exp.into()));
    }
    obj.insert("written_at".into(), serde_json::Value::String(written_at));
    obj.insert(
        "source".into(),
        serde_json::Value::String(source.to_string()),
    );

    let payload =
        serde_json::to_vec_pretty(&serde_json::Value::Object(obj)).map_err(io::Error::other)?;
    let tmp = dest.with_extension(format!("json.tmp.{}", std::process::id()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(&payload)?;
        f.write_all(b"\n")?;
        let _ = f.sync_all();
    }
    chump_pal::restrict_file_permissions(&tmp)?;
    fs::rename(&tmp, dest)?;
    Ok(())
}

/// Run a single cross-platform OAuth sync pass into `dest_token_file`.
///
/// When `claude_creds_override` is `Some`, skips the macOS Keychain probe so unit
/// tests remain 100% hermetic without touching the host Keychain.
pub fn sync_once_to(
    dest_token_file: &Path,
    claude_creds_override: Option<&Path>,
) -> io::Result<OAuthSyncOutcome> {
    let pin_setup_token = std::env::var("CHUMP_OAUTH_PIN_SETUP_TOKEN")
        .map(|v| v.trim() != "0")
        .unwrap_or(true);

    let existing = read_existing_token_file(dest_token_file);
    if pin_setup_token {
        if let Some((ref cur_tok, cur_exp, ref cur_src)) = existing {
            if cur_tok.starts_with("sk-ant-oat") {
                let src = cur_src
                    .clone()
                    .unwrap_or_else(|| "pinned-setup-token".to_string());
                write_oauth_token_atomic(dest_token_file, cur_tok, cur_exp, &src)?;
                return Ok(OAuthSyncOutcome {
                    status: OAuthSyncStatus::RefreshedPinnedMtime,
                    source: Some(src),
                });
            }
        }
    }

    let extracted = {
        #[cfg(target_os = "macos")]
        {
            if claude_creds_override.is_none() {
                probe_macos_keychain().or_else(|| probe_claude_credentials_file(None))
            } else {
                probe_claude_credentials_file(claude_creds_override)
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            probe_claude_credentials_file(claude_creds_override)
        }
    };

    let Some((new_tok, new_exp, source)) = extracted else {
        return Ok(OAuthSyncOutcome {
            status: OAuthSyncStatus::NoSourceFound,
            source: None,
        });
    };

    write_oauth_token_atomic(dest_token_file, &new_tok, new_exp, &source)?;
    let status = if existing
        .as_ref()
        .is_some_and(|(old_tok, _, _)| old_tok == &new_tok)
    {
        OAuthSyncStatus::Unchanged
    } else {
        OAuthSyncStatus::Updated
    };
    Ok(OAuthSyncOutcome {
        status,
        source: Some(source),
    })
}

/// Resolve the target `oauth-token.json` path (`CHUMP_OAUTH_TOKEN_FILE` ->
/// `config.toml` `[auth].oauth_token_file` -> `chump_pal::chump_home().join("oauth-token.json")`).
pub fn resolve_oauth_token_target() -> PathBuf {
    if let Ok(v) = std::env::var("CHUMP_OAUTH_TOKEN_FILE") {
        let t = v.trim();
        if !t.is_empty() {
            return PathBuf::from(t);
        }
    }
    if let Ok(cfg) = chump_config::ChumpConfig::load_effective() {
        if let Some(p) = cfg.auth.oauth_token_file {
            return p;
        }
    }
    chump_pal::chump_home().join("oauth-token.json")
}

/// Spawn the periodic background OAuth sync task inside `chumpd`.
pub fn spawn_background_sync(dest_token_file: PathBuf, interval_secs: u64) {
    let cadence = interval_secs.max(10);
    tokio::spawn(async move {
        loop {
            if let Err(err) = sync_once_to(&dest_token_file, None) {
                eprintln!(
                    "chumpd oauth_sync: failed writing {}: {err}",
                    dest_token_file.display()
                );
            }
            tokio::time::sleep(Duration::from_secs(cadence)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn extracts_nested_and_rejects_expired_without_refresh() {
        let future_ms = now_ms() + 3_600_000;
        let nested = serde_json::json!({
            "claudeAiOauth": {
                "accessToken": "oat-live-token",
                "expiresAt": future_ms
            }
        })
        .to_string();
        let (tok, exp) = extract_oauth_from_json_or_raw(&nested).expect("valid nested");
        assert_eq!(tok, "oat-live-token");
        assert_eq!(exp, Some(future_ms));

        let expired = serde_json::json!({
            "claudeAiOauth": {
                "accessToken": "oat-expired",
                "expiresAt": 1000
            }
        })
        .to_string();
        assert!(extract_oauth_from_json_or_raw(&expired).is_none());
    }

    #[test]
    fn sync_once_writes_restricted_file_and_pins_setup_tokens() {
        let tmp = TempDir::new().unwrap();
        let creds_file = tmp.path().join("credentials.json");
        let dest = tmp.path().join("oauth-token.json");
        let future_ms = now_ms() + 7_200_000;

        fs::write(
            &creds_file,
            serde_json::json!({
                "claudeAiOauth": {
                    "accessToken": "sub-access-token-1",
                    "expiresAt": future_ms
                }
            })
            .to_string(),
        )
        .unwrap();

        let out = sync_once_to(&dest, Some(&creds_file)).unwrap();
        assert_eq!(out.status, OAuthSyncStatus::Updated);
        assert!(dest.is_file());

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&dest).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }

        // Seed a pinned `sk-ant-oat01-...` setup token -> must NOT be overwritten by creds_file!
        write_oauth_token_atomic(&dest, "sk-ant-oat01-pinned-long-lived", None, "setup-token")
            .unwrap();
        let pinned_out = sync_once_to(&dest, Some(&creds_file)).unwrap();
        assert_eq!(pinned_out.status, OAuthSyncStatus::RefreshedPinnedMtime);
        let (on_disk, _, _) = read_existing_token_file(&dest).unwrap();
        assert_eq!(on_disk, "sk-ant-oat01-pinned-long-lived");
    }
}
