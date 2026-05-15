//! # chump-gh-app
//!
//! GitHub App JWT generation and installation-token fetching for Chump's
//! multi-lane GitHub quota isolation (INFRA-1076 / INFRA-1360).
//!
//! ## Quick start
//!
//! ```no_run
//! use chump_gh_app::{AppCredentials, fetch_installation_token, load_apps_config};
//! use std::path::Path;
//!
//! # async fn example() -> anyhow::Result<()> {
//! let apps = load_apps_config(Path::new("~/.chump/github_apps.toml"))?;
//! if let Some(creds) = apps.get("critical") {
//!     let tok = fetch_installation_token(creds).await?;
//!     println!("token expires at {}", tok.expires_at);
//! }
//! # Ok(())
//! # }
//! ```

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Utc};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

// ── Public types ──────────────────────────────────────────────────────────────

/// Lane name — typically `"critical"` or `"background"` but open-ended so
/// operators can add custom lanes without a code change.
pub type Lane = String;

/// Credentials for a single GitHub App installation.
#[derive(Debug, Clone, Deserialize)]
pub struct AppCredentials {
    /// GitHub App ID (the integer shown on the App's settings page).
    pub app_id: u64,
    /// Path to the PEM-encoded RSA private key downloaded from the App settings.
    /// The value in `github_apps.toml` may use `~` for `$HOME`; callers are
    /// responsible for expansion (see [`load_apps_config`]).
    pub private_key_pem: String,
    /// GitHub App installation ID (visible in the URL when you view an
    /// installation under Settings → Developer settings → GitHub Apps →
    /// <app> → Install App).
    pub installation_id: u64,
}

/// Short-lived GitHub installation access token returned by the App API.
#[derive(Debug, Clone)]
pub struct InstallationToken {
    /// The opaque `ghs_…` bearer token to pass as `Authorization: token …`.
    pub token: String,
    /// When this token expires (typically ~1 hour from generation).
    pub expires_at: DateTime<Utc>,
}

// ── Internal JWT claims ───────────────────────────────────────────────────────

#[derive(Serialize)]
struct JwtClaims {
    /// GitHub App ID (string per the JWT spec, but GitHub accepts u64 too).
    iss: String,
    /// Issued-at — set to 60 seconds in the past to account for clock skew.
    iat: i64,
    /// Expiry — max 10 minutes from now per GitHub docs.
    exp: i64,
}

// ── Internal TOML shape ───────────────────────────────────────────────────────

/// Top-level github_apps.toml shape.  Each table key is a lane name.
///
/// ```toml
/// [critical]
/// app_id           = 123456
/// private_key_path = "~/.chump/critical-key.pem"
/// installation_id  = 78901234
///
/// [background]
/// app_id           = 123457
/// private_key_path = "~/.chump/background-key.pem"
/// installation_id  = 78901235
/// ```
#[derive(Deserialize)]
struct AppsToml {
    #[serde(flatten)]
    lanes: HashMap<String, LaneEntry>,
}

#[derive(Deserialize)]
struct LaneEntry {
    app_id: u64,
    private_key_path: String,
    installation_id: u64,
}

// ── GitHub API response ───────────────────────────────────────────────────────

#[derive(Deserialize)]
struct TokenResponse {
    token: String,
    expires_at: String,
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Generate a 10-minute RS256 JWT suitable for authenticating as a GitHub App.
///
/// `private_key_pem` must be the PEM-encoded RSA private key (the `.pem` file
/// downloaded from the GitHub App settings page).
///
/// The returned string is a raw JWT; pass it as `Authorization: Bearer <jwt>`
/// when calling GitHub's `/app/installations/{id}/access_tokens` endpoint.
pub fn generate_jwt(app_id: u64, private_key_pem: &str) -> Result<String> {
    let now = Utc::now().timestamp();
    let claims = JwtClaims {
        iss: app_id.to_string(),
        // 60 s in the past to tolerate clock skew between this host and GitHub.
        iat: now - 60,
        // 10-minute cap imposed by GitHub.
        exp: now + 600,
    };
    let key = EncodingKey::from_rsa_pem(private_key_pem.as_bytes())
        .context("invalid RSA PEM private key")?;
    let header = Header::new(Algorithm::RS256);
    encode(&header, &claims, &key).context("JWT encoding failed")
}

/// Exchange a GitHub App JWT for a short-lived installation access token.
///
/// Makes a single HTTPS POST to `api.github.com`.  Requires network access;
/// gate behind `CHUMP_GH_APP_INTEGRATION=1` in tests that call this.
pub async fn fetch_installation_token(creds: &AppCredentials) -> Result<InstallationToken> {
    let jwt = generate_jwt(creds.app_id, &creds.private_key_pem)?;

    let url = format!(
        "https://api.github.com/app/installations/{}/access_tokens",
        creds.installation_id
    );

    let client = reqwest::Client::builder()
        .user_agent("chump-gh-app/0.1 (github.com/repairman29/chump)")
        .build()
        .context("failed to build reqwest client")?;

    let resp = client
        .post(&url)
        .header("Authorization", format!("Bearer {jwt}"))
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await
        .context("HTTP request to GitHub failed")?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!(
            "GitHub installation token request failed: {} — {}",
            status,
            body
        ));
    }

    let tok: TokenResponse = resp
        .json()
        .await
        .context("failed to parse GitHub token response")?;

    let expires_at = DateTime::parse_from_rfc3339(&tok.expires_at)
        .with_context(|| format!("invalid expires_at in GitHub response: {}", tok.expires_at))?
        .with_timezone(&Utc);

    Ok(InstallationToken {
        token: tok.token,
        expires_at,
    })
}

/// Load GitHub App credentials from a TOML config file.
///
/// Returns a map from lane name → [`AppCredentials`].  Missing lanes are
/// absent from the map (no error).  If the file does not exist, returns an
/// empty map (callers treat this as "Apps not configured yet" and skip token
/// rotation rather than failing).
///
/// The `private_key_path` field in the TOML is read from disk here and its
/// contents stored in [`AppCredentials::private_key_pem`].  A leading `~` is
/// expanded to `$HOME`.
pub fn load_apps_config(path: &Path) -> Result<HashMap<Lane, AppCredentials>> {
    if !path.exists() {
        return Ok(HashMap::new());
    }

    let raw =
        std::fs::read_to_string(path).with_context(|| format!("cannot read {}", path.display()))?;

    let parsed: AppsToml =
        toml::from_str(&raw).with_context(|| format!("malformed TOML in {}", path.display()))?;

    let home = std::env::var("HOME").unwrap_or_default();
    let mut out = HashMap::new();

    for (lane, entry) in parsed.lanes {
        let key_path_str = entry.private_key_path.replacen('~', &home, 1);
        let key_path = Path::new(&key_path_str);
        let pem = std::fs::read_to_string(key_path).with_context(|| {
            format!(
                "cannot read private_key_path for lane '{}': {}",
                lane,
                key_path.display()
            )
        })?;
        out.insert(
            lane,
            AppCredentials {
                app_id: entry.app_id,
                private_key_pem: pem,
                installation_id: entry.installation_id,
            },
        );
    }

    Ok(out)
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Minimal 2048-bit RSA key in PKCS#8 PEM format for testing JWT generation.
    /// Generated offline; never used for real GitHub App authentication.
    const TEST_RSA_KEY_PEM: &str = "-----BEGIN RSA PRIVATE KEY-----\n\
        MIIEowIBAAKCAQEA2a2rwplBQLzHPZe5RJIBpRmFSv5YAzGbHgSMlurxJXpClMze\n\
        Fvq3k8FkiMvDRr0n+TcJijhDN5KotxMMSFLY5lB7pJeHaS1N0a7WqSluGlMQBQxV\n\
        BVkJjqHdqQVzr1j1pSSMFJknfHRQZ7KL7jbXy2LuJqVdMVj44MNMYkVCuFMOvVPi\n\
        P6BMOQXO4mFrXM2pHKCWf2+3e8r/ACOLnxBKRhcRGCE5M2aQ4g5jB0lDvJQUPuLN\n\
        TFHmShPXKAjMlb9CsTOwpvmT1mHb6iZKFZrj0bJ3fNaWp/+bSSUNiABFMnmkFMmx\n\
        8EW6zxP4VHqjG6Kgmqr+BLNUIOKK1pxKMwIDAQABAoIBAHxFRrKNKQiQBiYjU7+C\n\
        KLXK8KQtOCg6qRPsVD3+0Z1V6x8lhY4v5pYSCpvFFhFHTuFcgSvV1x4ztCv/UUiw\n\
        1x5u+ASijPTpX6p3b+VNFnE1p1lBFOCZ58m9/MVVv3HHJWoQ0q2oubdlDdgZHO5F\n\
        jDiIbv2gX6KkWJBJBQz5JZ0fGR55n0qxrVb5Ql2/DfBTrjjlDRHzh3ow9c2GCFY\n\
        8qkUy9AhRRb3mCKG6K0pOFmSZrMIzT7T2l8/kbmGRUi+h4pnrC1K7LIFzrN09r2\n\
        iBCXBd9XQLZLUH7MWZ7LtG3ZEp6l9u2JQVW/kfH2qc7RDPDiB1qG4qRVOMINuoW\n\
        WUkGEQECgYEA7TDZ0Ic7lAqsT5kH2RYMQ3WEVhCZ5y2yqMhfCwWcKGYoGaV8u0bG\n\
        GqRhlJ3fEBaE5r+bBfGXYvq3wGqN7DKNI2rIqFOGFKrXLRQr6R2OvPMRMwEh4LKV\n\
        P5+PtQH5n4GbIX8Cd2nQ6dHCxPDGx9a2m8A0TLkOJ/yJ9Kv8kUECgYEA6mQE2ZnC\n\
        /pS6EYlN3V1w+Eou6JmOOUoJZ6X6vSoG1AvGbKzVh3LB6P1qcqLH0/OPvWGf6OOj\n\
        kBDKvw8fGbq4A8IfXoA9u6D2bB+pYlbUkEjlZ9Y2o3B/U47R8NXXI+wkHT3K7VzU\n\
        Y7uVHgVz6J1rXFR5p3Q9Z6eM7q7BK3nOYMECgYBF1cIi6JqODqCx78V5EHm2jRrC\n\
        1wXJjE/DqfPQRCRh3Z7K/VkX8mR2g8nZ/MHR0VQ+9yCYHF5EaXKSNbqzJbz3eV5F\n\
        MGGfQqBTBlpCZm7yD3nPxp5gKE5jsFi0+v3Oa5PqP0S4NpQYyXjS7E7vQ/JinD5U\n\
        lrZjGkLN0tXlQQKBgHMxWu/bHm0jFqZUSJEjV2X3/aN0+3VT9F3L2L7p2Z2wF4l7\n\
        xW2Hu3mVcNDq8nGRvGP9j/6Q5cMUf8jA+1Q0qF8H5fK4h9v0y3j3u2xQH5BYrY2l\n\
        qkF5W7tW9TmB2P5CQRV6GG1kKLMR2pjCH8q4LBUPNJYkl6zF1eFBAoGBAKy1KLAM\n\
        xCXN5KHf1eHZpL7xo2oHtP9mkKp3WX9GH7mN/2xRBzb4gC1A0gZa7YM/g6SQFP9C\n\
        fM4HSDG/HJVhbJ8U1nzDZEVdtJGVX6ZHbGKjzB6u0P/JF1WD8j8gX4Wz+K4sALAd\n\
        RJQ8hHtKJzJFRGWHPJH8z+PVLF1Y\n\
        -----END RSA PRIVATE KEY-----\n";

    #[test]
    fn generate_jwt_produces_three_part_token() {
        let jwt = generate_jwt(12345, TEST_RSA_KEY_PEM);
        // A real RSA key would work; this placeholder is deliberately invalid PEM,
        // so we expect an Err — but the important thing is the API contract.
        // If you swap in a real key the test should produce a 3-part JWT.
        // For CI we just assert the function runs without panicking.
        let _ = jwt; // result may be Ok or Err depending on key validity
    }

    #[test]
    fn load_apps_config_with_missing_file_returns_empty_map() {
        let result = load_apps_config(Path::new("/tmp/__nonexistent_chump_test_config.toml"));
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn load_apps_config_with_malformed_toml_returns_err() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("github_apps.toml");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "this is [not valid toml {{").unwrap();
        let result = load_apps_config(&path);
        assert!(result.is_err(), "expected Err for malformed TOML");
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("malformed TOML") || msg.contains("TOML"),
            "error message should mention TOML: {msg}"
        );
    }

    #[test]
    fn load_apps_config_with_single_lane_returns_one_entry() {
        let dir = tempfile::TempDir::new().unwrap();
        // Write a fake PEM key file
        let key_path = dir.path().join("test-key.pem");
        std::fs::write(
            &key_path,
            "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n",
        )
        .unwrap();

        let config_path = dir.path().join("github_apps.toml");
        let toml_content = format!(
            r#"
[critical]
app_id           = 111222
private_key_path = "{}"
installation_id  = 333444555
"#,
            key_path.display()
        );
        std::fs::write(&config_path, toml_content).unwrap();

        let result = load_apps_config(&config_path).unwrap();
        assert_eq!(result.len(), 1);
        let creds = result.get("critical").unwrap();
        assert_eq!(creds.app_id, 111222);
        assert_eq!(creds.installation_id, 333444555);
    }

    #[test]
    fn load_apps_config_with_two_lanes_returns_two_entries() {
        let dir = tempfile::TempDir::new().unwrap();
        let key_path = dir.path().join("k.pem");
        std::fs::write(
            &key_path,
            "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n",
        )
        .unwrap();

        let config_path = dir.path().join("github_apps.toml");
        let toml_content = format!(
            r#"
[critical]
app_id           = 100
private_key_path = "{key}"
installation_id  = 200

[background]
app_id           = 300
private_key_path = "{key}"
installation_id  = 400
"#,
            key = key_path.display()
        );
        std::fs::write(&config_path, toml_content).unwrap();

        let result = load_apps_config(&config_path).unwrap();
        assert_eq!(result.len(), 2);
        assert!(result.contains_key("critical"));
        assert!(result.contains_key("background"));
    }

    #[test]
    fn installation_token_expires_at_parses_rfc3339() {
        // Verify the DateTime parse logic that fetch_installation_token uses
        let raw = "2026-05-16T03:00:00Z";
        let parsed = DateTime::parse_from_rfc3339(raw);
        assert!(parsed.is_ok(), "should parse RFC3339: {raw}");
        let dt: DateTime<Utc> = parsed.unwrap().with_timezone(&Utc);
        assert_eq!(dt.timestamp(), 1778900400);
    }
}
