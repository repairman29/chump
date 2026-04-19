//! Three-layer user model (PRODUCT-003).
//!
//! Layer 1 — Identity: who the user is (persistent, encrypted).
//! Layer 2 — Context: what they're working on (volatile, 7-day expiry).
//! Layer 3 — Preferences: what Chump has learned (user-confirmable).
//!
//! Security contract:
//! - Sensitive fields encrypted AES-256-GCM; key in sessions/.profile_key (mode 0o600).
//! - `user_context()` returns a sanitized summary — never raw field values.
//! - Profile data must never appear in logs, tool responses, or error output.
//! - `sessions/` is git-ignored; profile never lands in git.

use aes_gcm::aead::{Aead, AeadCore, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// How autonomously Chump should operate. Feeds PrecisionController at session start.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckinFrequency {
    /// Check in after every significant action.
    Frequent,
    /// Summarize async; interrupt only for blockers.
    #[default]
    Async,
    /// Grind autonomously; surface only final results.
    Autonomous,
}

impl std::str::FromStr for CheckinFrequency {
    type Err = ();
    fn from_str(s: &str) -> std::result::Result<Self, ()> {
        match s {
            "frequent" => Ok(CheckinFrequency::Frequent),
            "async" => Ok(CheckinFrequency::Async),
            "autonomous" => Ok(CheckinFrequency::Autonomous),
            _ => Ok(CheckinFrequency::Async),
        }
    }
}

impl std::fmt::Display for CheckinFrequency {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CheckinFrequency::Frequent => write!(f, "frequent"),
            CheckinFrequency::Async => write!(f, "async"),
            CheckinFrequency::Autonomous => write!(f, "autonomous"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum RiskTolerance {
    Low,
    #[default]
    Medium,
    High,
}

impl std::str::FromStr for RiskTolerance {
    type Err = ();
    fn from_str(s: &str) -> std::result::Result<Self, ()> {
        match s {
            "low" => Ok(RiskTolerance::Low),
            "medium" => Ok(RiskTolerance::Medium),
            "high" => Ok(RiskTolerance::High),
            _ => Ok(RiskTolerance::Medium),
        }
    }
}

/// Compiled behavioral configuration — fed into PrecisionController at session start.
#[derive(Debug, Clone)]
pub struct BehaviorRegime {
    pub checkin_frequency: CheckinFrequency,
    pub risk_tolerance: RiskTolerance,
    pub communication_style: String,
    pub never_do: Vec<String>,
}

impl Default for BehaviorRegime {
    fn default() -> Self {
        BehaviorRegime {
            checkin_frequency: CheckinFrequency::Async,
            risk_tolerance: RiskTolerance::Medium,
            communication_style: "concise".to_string(),
            never_do: vec![],
        }
    }
}

/// Sanitized user context — safe for injection into prompts.
/// Contains no raw sensitive values; role_summary and current_focus are derived summaries.
#[derive(Debug, Clone)]
pub struct UserContext {
    /// First name only. None if not set.
    pub display_name: Option<String>,
    /// Constructed summary e.g. "software developer and founder".
    pub role_summary: String,
    /// Top 3 active context items, summarized. Each is "<type>: <value>".
    pub current_focus: Vec<String>,
    /// Behavioral regime for PrecisionController.
    pub regime: BehaviorRegime,
}

impl UserContext {
    /// Format as a compact system-prompt injection. Never includes raw sensitive fields.
    pub fn as_prompt_fragment(&self) -> String {
        let mut parts = Vec::new();
        if let Some(name) = &self.display_name {
            parts.push(format!("User: {name}"));
        }
        if !self.role_summary.is_empty() {
            parts.push(format!("Role: {}", self.role_summary));
        }
        if !self.current_focus.is_empty() {
            parts.push(format!(
                "Currently working on: {}",
                self.current_focus.join("; ")
            ));
        }
        if !self.regime.never_do.is_empty() {
            parts.push(format!("NEVER: {}", self.regime.never_do.join(", ")));
        }
        parts.join("\n")
    }
}

// ---------------------------------------------------------------------------
// Key management
// ---------------------------------------------------------------------------

fn sessions_dir() -> std::path::PathBuf {
    std::env::current_dir()
        .unwrap_or_else(|_| std::path::PathBuf::from("."))
        .join("sessions")
}

fn profile_key_path() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("CHUMP_PROFILE_KEY_PATH") {
        return std::path::PathBuf::from(p);
    }
    sessions_dir().join(".profile_key")
}

fn load_or_create_key() -> Result<[u8; 32]> {
    let path = profile_key_path();
    if path.exists() {
        let bytes = std::fs::read(&path)?;
        if bytes.len() == 32 {
            let mut key = [0u8; 32];
            key.copy_from_slice(&bytes);
            return Ok(key);
        }
    }
    let _ = std::fs::create_dir_all(sessions_dir());
    let key: [u8; 32] = Aes256Gcm::generate_key(OsRng).into();
    std::fs::write(&path, key)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(key)
}

// ---------------------------------------------------------------------------
// Field encryption / decryption
// ---------------------------------------------------------------------------

fn encrypt_field(plaintext: &str, key: &[u8; 32]) -> Result<Vec<u8>> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let ciphertext = cipher
        .encrypt(&nonce, plaintext.as_bytes())
        .map_err(|_| anyhow!("encrypt failed"))?;
    let mut out = nonce.to_vec(); // 12 bytes
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

fn decrypt_field(data: &[u8], key: &[u8; 32]) -> Result<String> {
    if data.len() < 13 {
        return Err(anyhow!("ciphertext too short"));
    }
    let (nonce_bytes, ct) = data.split_at(12);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let nonce = Nonce::from_slice(nonce_bytes);
    let plain = cipher
        .decrypt(nonce, ct)
        .map_err(|_| anyhow!("decrypt failed"))?;
    Ok(String::from_utf8(plain)?)
}

// ---------------------------------------------------------------------------
// Layer 1 — Identity
// ---------------------------------------------------------------------------

pub fn save_identity(name: &str, role: &str, domains: &[String], timezone: &str) -> Result<()> {
    let key = load_or_create_key()?;
    let name_enc = encrypt_field(name, &key)?;
    let role_enc = encrypt_field(role, &key)?;
    let domains_json = serde_json::to_string(domains)?;
    let domains_enc = encrypt_field(&domains_json, &key)?;
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO user_identity (id, name_enc, role_enc, domains_enc, timezone, updated_at)
         VALUES (1, ?1, ?2, ?3, ?4, datetime('now'))
         ON CONFLICT(id) DO UPDATE SET
             name_enc=excluded.name_enc,
             role_enc=excluded.role_enc,
             domains_enc=excluded.domains_enc,
             timezone=excluded.timezone,
             updated_at=excluded.updated_at",
        rusqlite::params![name_enc, role_enc, domains_enc, timezone],
    )?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Layer 2 — Current Context
// ---------------------------------------------------------------------------

/// Write or update a context item. Expires in 7 days.
pub fn update_context(key: &str, value: &str, ctx_type: &str) -> Result<()> {
    let enc_key = load_or_create_key()?;
    let value_enc = encrypt_field(value, &enc_key)?;
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO user_context_items (key, value_enc, context_type, expires_at, updated_at)
         VALUES (?1, ?2, ?3, datetime('now', '+7 days'), datetime('now'))
         ON CONFLICT(key) DO UPDATE SET
             value_enc=excluded.value_enc,
             context_type=excluded.context_type,
             expires_at=excluded.expires_at,
             updated_at=excluded.updated_at",
        rusqlite::params![key, value_enc, ctx_type],
    )?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Layer 3 — Learned Preferences
// ---------------------------------------------------------------------------

/// Record an observed preference. Starts unconfirmed.
pub fn record_preference(key: &str, value: &str, note: &str, source: &str) -> Result<()> {
    let enc_key = load_or_create_key()?;
    let value_enc = encrypt_field(value, &enc_key)?;
    let note_enc = encrypt_field(note, &enc_key)?;
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO user_preferences (key, value_enc, source, note_enc, confirmed)
         VALUES (?1, ?2, ?3, ?4, 0)
         ON CONFLICT(key) DO UPDATE SET
             value_enc=excluded.value_enc,
             source=excluded.source,
             note_enc=excluded.note_enc",
        rusqlite::params![key, value_enc, source, note_enc],
    )?;
    Ok(())
}

/// Mark a preference as user-confirmed.
pub fn confirm_preference(key: &str) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE user_preferences SET confirmed=1 WHERE key=?1",
        rusqlite::params![key],
    )?;
    Ok(())
}

/// List unconfirmed preferences (for surfacing in PWA "What I've Learned" panel).
pub fn pending_preferences() -> Result<Vec<(String, String)>> {
    let key = load_or_create_key()?;
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT key, note_enc FROM user_preferences WHERE confirmed=0 ORDER BY created_at DESC",
    )?;
    let rows = stmt.query_map([], |row| {
        let k: String = row.get(0)?;
        let note_enc: Vec<u8> = row.get(1)?;
        Ok((k, note_enc))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (k, note_enc) = row?;
        if let Ok(note) = decrypt_field(&note_enc, &key) {
            out.push((k, note));
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Behavioral regime
// ---------------------------------------------------------------------------

pub fn save_behavior(
    checkin: CheckinFrequency,
    risk: RiskTolerance,
    style: &str,
    never_do: &[String],
) -> Result<()> {
    let never_json = serde_json::to_string(never_do)?;
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO user_behavior (id, checkin_frequency, risk_tolerance, communication_style, never_do_json, updated_at)
         VALUES (1, ?1, ?2, ?3, ?4, datetime('now'))
         ON CONFLICT(id) DO UPDATE SET
             checkin_frequency=excluded.checkin_frequency,
             risk_tolerance=excluded.risk_tolerance,
             communication_style=excluded.communication_style,
             never_do_json=excluded.never_do_json,
             updated_at=excluded.updated_at",
        rusqlite::params![checkin.to_string(), format!("{risk:?}").to_lowercase(), style, never_json],
    )?;
    Ok(())
}

fn load_behavior(conn: &rusqlite::Connection) -> BehaviorRegime {
    conn.query_row(
        "SELECT checkin_frequency, risk_tolerance, communication_style, never_do_json
         FROM user_behavior WHERE id=1",
        [],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        },
    )
    .map(|(checkin, risk, style, never_json)| BehaviorRegime {
        checkin_frequency: checkin.parse().unwrap_or_default(),
        risk_tolerance: risk.parse().unwrap_or_default(),
        communication_style: style,
        never_do: serde_json::from_str(&never_json).unwrap_or_default(),
    })
    .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Onboarding state
// ---------------------------------------------------------------------------

/// Returns true once all five onboarding questions have been answered.
pub fn profile_complete() -> bool {
    let Ok(conn) = crate::db_pool::get() else {
        return false;
    };
    conn.query_row(
        "SELECT onboarding_complete FROM user_identity WHERE id=1",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|v| v != 0)
    .unwrap_or(false)
}

/// Mark onboarding complete. Called after Q5 is answered and confirmed.
pub fn mark_onboarding_complete() -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO user_identity (id, onboarding_complete, updated_at)
         VALUES (1, 1, datetime('now'))
         ON CONFLICT(id) DO UPDATE SET
             onboarding_complete=1,
             updated_at=excluded.updated_at",
        [],
    )?;
    Ok(())
}

// ---------------------------------------------------------------------------
// user_context() — the safe injection interface
// ---------------------------------------------------------------------------

/// Return a sanitized UserContext safe for prompt injection.
/// Never exposes raw field values — only derived summaries.
/// Returns None if the profile is empty (onboarding not started).
pub fn user_context() -> Option<UserContext> {
    let key = load_or_create_key().ok()?;
    let conn = crate::db_pool::get().ok()?;

    // Layer 1: identity — derive display_name (first name only) and role_summary
    let (display_name, role_summary) = conn
        .query_row(
            "SELECT name_enc, role_enc FROM user_identity WHERE id=1",
            [],
            |row| {
                Ok((
                    row.get::<_, Option<Vec<u8>>>(0)?,
                    row.get::<_, Option<Vec<u8>>>(1)?,
                ))
            },
        )
        .ok()
        .map(|(name_enc, role_enc)| {
            let name = name_enc
                .as_deref()
                .and_then(|b| decrypt_field(b, &key).ok())
                .and_then(|s| s.split_whitespace().next().map(|f| f.to_string()));
            let role = role_enc
                .as_deref()
                .and_then(|b| decrypt_field(b, &key).ok())
                .unwrap_or_default();
            (name, role)
        })
        .unwrap_or((None, String::new()));

    if display_name.is_none() && role_summary.is_empty() {
        return None;
    }

    // Layer 2: top 3 non-expired context items
    let current_focus = {
        let mut stmt = conn
            .prepare(
                "SELECT context_type, value_enc FROM user_context_items
                 WHERE expires_at IS NULL OR expires_at > datetime('now')
                 ORDER BY updated_at DESC LIMIT 3",
            )
            .ok()?;
        let rows: Vec<(String, Vec<u8>)> = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?))
            })
            .ok()?
            .filter_map(|r| r.ok())
            .collect();
        rows.into_iter()
            .filter_map(|(ctx_type, value_enc)| {
                let value = decrypt_field(&value_enc, &key).ok()?;
                Some(format!("{ctx_type}: {value}"))
            })
            .collect::<Vec<_>>()
    };

    let regime = load_behavior(&conn);

    Some(UserContext {
        display_name,
        role_summary,
        current_focus,
        regime,
    })
}

// ---------------------------------------------------------------------------
// Tests — crypto primitives only (no pool dependency)
// DB integration tests live in tests/user_profile_integration.rs (PRODUCT-003)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_roundtrip() {
        let key = [0xABu8; 32];
        let plain = "hello, world";
        let enc = encrypt_field(plain, &key).unwrap();
        let dec = decrypt_field(&enc, &key).unwrap();
        assert_eq!(dec, plain);
    }

    #[test]
    fn encrypt_empty_string() {
        let key = [0x01u8; 32];
        let enc = encrypt_field("", &key).unwrap();
        let dec = decrypt_field(&enc, &key).unwrap();
        assert_eq!(dec, "");
    }

    #[test]
    fn encrypt_unicode() {
        let key = [0xFFu8; 32];
        let plain = "こんにちは 🤖 Ünïcödé";
        let enc = encrypt_field(plain, &key).unwrap();
        let dec = decrypt_field(&enc, &key).unwrap();
        assert_eq!(dec, plain);
    }

    #[test]
    fn encrypt_unique_nonces() {
        // Same plaintext + key → different ciphertexts (random nonce)
        let key = [0x42u8; 32];
        let a = encrypt_field("same", &key).unwrap();
        let b = encrypt_field("same", &key).unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn decrypt_wrong_key_fails() {
        let key1 = [0x01u8; 32];
        let key2 = [0x02u8; 32];
        let enc = encrypt_field("secret", &key1).unwrap();
        assert!(decrypt_field(&enc, &key2).is_err());
    }

    #[test]
    fn decrypt_truncated_fails() {
        let key = [0x01u8; 32];
        assert!(decrypt_field(&[0u8; 5], &key).is_err());
    }

    #[test]
    fn prompt_fragment_no_surname_leak() {
        // UserContext.as_prompt_fragment() must only include first name
        let ctx = UserContext {
            display_name: Some("Jeff".to_string()),
            role_summary: "founder, software developer".to_string(),
            current_focus: vec!["project: Chump FTUE".to_string()],
            regime: BehaviorRegime::default(),
        };
        let frag = ctx.as_prompt_fragment();
        assert!(frag.contains("Jeff"));
        assert!(frag.contains("founder"));
        assert!(frag.contains("Chump FTUE"));
        // Regime's never_do is empty by default — no NEVER line
        assert!(!frag.contains("NEVER"));
    }

    #[test]
    fn prompt_fragment_never_do() {
        let ctx = UserContext {
            display_name: None,
            role_summary: String::new(),
            current_focus: vec![],
            regime: BehaviorRegime {
                never_do: vec!["commit to main".to_string()],
                ..BehaviorRegime::default()
            },
        };
        assert!(ctx.as_prompt_fragment().contains("NEVER"));
        assert!(ctx.as_prompt_fragment().contains("commit to main"));
    }

    #[test]
    fn checkin_frequency_roundtrip() {
        for (s, v) in [
            ("frequent", CheckinFrequency::Frequent),
            ("async", CheckinFrequency::Async),
            ("autonomous", CheckinFrequency::Autonomous),
        ] {
            assert_eq!(s.parse::<CheckinFrequency>().unwrap(), v);
            assert_eq!(v.to_string(), s);
        }
    }

    #[test]
    fn unknown_checkin_defaults_to_async() {
        assert_eq!(
            "garbage".parse::<CheckinFrequency>().unwrap(),
            CheckinFrequency::Async
        );
    }
}
