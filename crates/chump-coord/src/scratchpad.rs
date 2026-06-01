// crates/chump-coord/src/scratchpad.rs — INFRA-1826
//
// A2A Layer 3d (2/4) — real file-backed get/set/cas for seed keys.
//
// Backend: `.chump-locks/scratch/<key>.json` (dots in key become slashes for
// path safety — reversed at read time via key extraction from JSON, not path).
// Actually, we keep key as filename with dots replaced by underscores to stay
// filesystem-safe; the JSON payload records the original key.
//
// File envelope schema:
//   { "key": "<key>", "value": <json>, "written_at": "<rfc3339>",
//     "ttl_expires_at": "<rfc3339>" }
//
// CAS atomicity: tempfile + rename (POSIX atomic on same filesystem).
//
// INFRA-1121 slice 3/4 swaps the file backend for NATS KV `chump_scratch`
// bucket; all call sites stay identical.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// NATS KV bucket name (used when the real NATS backend ships in INFRA-1121 slice 3/4).
pub fn bucket_name() -> &'static str {
    "chump_scratch"
}

/// Conflict-resolution policy per seed key. Each key declares one and the
/// CAS write path enforces it.
///
/// Variant rationale:
/// - `LastWriterWins` — high-frequency counters (fleet.size); last value
///   in beats accidental staleness. No retry on conflict.
/// - `CASRequired` — pointers to canonical state (main.head.sha,
///   last_known_good.chump_binary). Writer must read+CAS; conflict means
///   retry-from-fresh-read.
/// - `MergeWithFn` — map-shaped values where two writers can each
///   legitimately add keys (e.g. per-session capability rollup). Merge
///   function combines both halves.
#[derive(Clone)]
pub enum ConflictPolicy {
    LastWriterWins,
    CASRequired,
    MergeWithFn(
        Arc<dyn Fn(serde_json::Value, serde_json::Value) -> serde_json::Value + Send + Sync>,
    ),
}

impl std::fmt::Debug for ConflictPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConflictPolicy::LastWriterWins => write!(f, "LastWriterWins"),
            ConflictPolicy::CASRequired => write!(f, "CASRequired"),
            ConflictPolicy::MergeWithFn(_) => write!(f, "MergeWithFn(<fn>)"),
        }
    }
}

impl PartialEq for ConflictPolicy {
    fn eq(&self, other: &Self) -> bool {
        matches!(
            (self, other),
            (
                ConflictPolicy::LastWriterWins,
                ConflictPolicy::LastWriterWins
            ) | (ConflictPolicy::CASRequired, ConflictPolicy::CASRequired)
        )
        // MergeWithFn equality is undefined (closures aren't comparable);
        // tests should compare LastWriterWins/CASRequired only.
    }
}

/// Per-key schema entry. Owned in the static SEED_KEYS table below.
#[derive(Clone)]
pub struct SeedKey {
    pub key: &'static str,
    pub conflict_policy: ConflictPolicy,
    pub ttl_seconds: u32,
    /// When true, top-N scratchpad values are injected into the agent's
    /// --briefing context at session start (per slice 3/4).
    pub prompt_inject: bool,
}

impl std::fmt::Debug for SeedKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SeedKey")
            .field("key", &self.key)
            .field("conflict_policy", &self.conflict_policy)
            .field("ttl_seconds", &self.ttl_seconds)
            .field("prompt_inject", &self.prompt_inject)
            .finish()
    }
}

/// The 5 v1 seed keys. Documented in docs/design/A2A_SCRATCHPAD_KEYS.md.
///
/// 1. `main.head.sha` — current canonical main HEAD SHA. CAS-required so
///    two parallel observers race-safely converge.
/// 2. `fleet.size` — current worker count. LWW (high frequency, latest
///    value is fine).
/// 3. `pillar.focus` — current pillar emphasis pointer. LWW (operator
///    decision moves slowly).
/// 4. `last_known_good.chump_binary` — most recent verified chump build
///    SHA. CAS-required (preserve linear history).
/// 5. `red_letter.last_ts` — last ts the RED_LETTER.md was rewritten. LWW.
pub fn seed_keys() -> Vec<SeedKey> {
    vec![
        SeedKey {
            key: "main.head.sha",
            conflict_policy: ConflictPolicy::CASRequired,
            ttl_seconds: 86_400,
            prompt_inject: true,
        },
        SeedKey {
            key: "fleet.size",
            conflict_policy: ConflictPolicy::LastWriterWins,
            ttl_seconds: 300,
            prompt_inject: true,
        },
        SeedKey {
            key: "pillar.focus",
            conflict_policy: ConflictPolicy::LastWriterWins,
            ttl_seconds: 3_600,
            prompt_inject: true,
        },
        SeedKey {
            key: "last_known_good.chump_binary",
            conflict_policy: ConflictPolicy::CASRequired,
            ttl_seconds: 86_400,
            prompt_inject: true,
        },
        SeedKey {
            key: "red_letter.last_ts",
            conflict_policy: ConflictPolicy::LastWriterWins,
            ttl_seconds: 86_400,
            prompt_inject: true,
        },
    ]
}

/// Error type for scratchpad operations.
#[derive(Debug)]
pub enum ScratchError {
    Io(std::io::Error),
    Json(serde_json::Error),
    UnknownKey(String),
    CASConflict {
        key: String,
        expected: String,
        actual: String,
    },
    CASRequiredOnBareSet(String),
    InfiniteTtlMissingReview {
        key: String,
    },
}

impl std::fmt::Display for ScratchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScratchError::Io(e) => write!(f, "scratchpad I/O error: {e}"),
            ScratchError::Json(e) => write!(f, "scratchpad JSON error: {e}"),
            ScratchError::UnknownKey(k) => write!(f, "unknown scratchpad key: {k}"),
            ScratchError::CASConflict {
                key,
                expected,
                actual,
            } => write!(
                f,
                "CAS conflict on '{key}': expected '{expected}', got '{actual}'"
            ),
            ScratchError::CASRequiredOnBareSet(k) => {
                write!(f, "key '{k}' is CASRequired — use cas() instead of set()")
            }
            ScratchError::InfiniteTtlMissingReview { key } => write!(
                f,
                "key '{key}' marked ttl=infinite but lacks operator_reviewed_at timestamp"
            ),
        }
    }
}

impl std::error::Error for ScratchError {}

// ── File envelope ─────────────────────────────────────────────────────────────

/// JSON file payload stored at `.chump-locks/scratch/<filename>.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Envelope {
    /// Logical scratchpad key (e.g. "main.head.sha").
    key: String,
    /// The stored value.
    value: serde_json::Value,
    /// RFC3339 write timestamp.
    written_at: String,
    /// RFC3339 expiry timestamp. Empty string = no TTL (not used for v1 seed keys).
    #[serde(default)]
    ttl_expires_at: String,
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Return the directory where scratch files live, creating it if needed.
///
/// Resolves from `CHUMP_SCRATCH_DIR` env var (useful for tests), then from
/// `git rev-parse --show-toplevel` → `.chump-locks/scratch/`, then falls back
/// to `.chump-locks/scratch/` relative to cwd.
fn scratch_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("CHUMP_SCRATCH_DIR") {
        let p = PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&p);
        return p;
    }

    let repo_root = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout)
                    .ok()
                    .map(|s| PathBuf::from(s.trim()))
            } else {
                None
            }
        })
        .unwrap_or_else(|| PathBuf::from("."));

    let dir = repo_root.join(".chump-locks").join("scratch");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Convert a scratchpad key to a filesystem-safe filename stem.
/// Dots → `__dot__`, slashes → `__slash__`.
/// Exported for tests that need to construct expected file paths.
pub fn key_to_filename(key: &str) -> String {
    key.replace('.', "__dot__").replace('/', "__slash__")
}

/// Path for a given key's envelope file.
fn key_path(dir: &Path, key: &str) -> PathBuf {
    dir.join(format!("{}.json", key_to_filename(key)))
}

/// Read an envelope from disk. Returns `None` if the file doesn't exist.
fn read_envelope(path: &Path) -> Result<Option<Envelope>, ScratchError> {
    match std::fs::read_to_string(path) {
        Ok(s) => {
            let env: Envelope = serde_json::from_str(&s).map_err(ScratchError::Json)?;
            Ok(Some(env))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(ScratchError::Io(e)),
    }
}

/// Write an envelope atomically via tempfile + rename.
fn write_envelope(dir: &Path, env: &Envelope) -> Result<(), ScratchError> {
    let final_path = key_path(dir, &env.key);
    // Write to a temp file in the same directory (guarantees same filesystem for rename).
    let tmp_path = dir.join(format!(".__tmp_{}.json", key_to_filename(&env.key)));
    let json = serde_json::to_string_pretty(env).map_err(ScratchError::Json)?;
    std::fs::write(&tmp_path, json).map_err(ScratchError::Io)?;
    std::fs::rename(&tmp_path, &final_path).map_err(ScratchError::Io)?;
    Ok(())
}

/// Check if an envelope is expired. Returns true if expired.
fn is_expired(env: &Envelope) -> bool {
    if env.ttl_expires_at.is_empty() {
        return false;
    }
    match env.ttl_expires_at.parse::<DateTime<Utc>>() {
        Ok(expires) => Utc::now() > expires,
        Err(_) => false, // malformed TTL → treat as not expired
    }
}

/// Build a fresh envelope for a given key and value.
fn make_envelope(key: &str, value: serde_json::Value, ttl_seconds: u32) -> Envelope {
    let now = Utc::now();
    let expires = now + chrono::Duration::seconds(ttl_seconds as i64);
    Envelope {
        key: key.to_string(),
        value,
        written_at: now.to_rfc3339(),
        ttl_expires_at: expires.to_rfc3339(),
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Look up a seed key's schema. Returns None for unknown keys.
pub fn seed_key_lookup(key: &str) -> Option<SeedKey> {
    seed_keys().into_iter().find(|sk| sk.key == key)
}

/// Read the current value for `key`. Returns `None` if unset or expired.
///
/// Unknown keys return `Err(ScratchError::UnknownKey)`.
pub async fn get(key: &str) -> Result<Option<serde_json::Value>, ScratchError> {
    if seed_key_lookup(key).is_none() {
        return Err(ScratchError::UnknownKey(key.to_string()));
    }
    let dir = scratch_dir();
    let path = key_path(&dir, key);
    match read_envelope(&path)? {
        None => Ok(None),
        Some(env) if is_expired(&env) => Ok(None),
        Some(env) => Ok(Some(env.value)),
    }
}

/// Write `value` for `key` using LastWriterWins semantics (overwrites).
///
/// CAS-required keys reject bare `set()` — use `cas()` instead.
pub async fn set(key: &str, value: serde_json::Value) -> Result<(), ScratchError> {
    let sk = seed_key_lookup(key).ok_or_else(|| ScratchError::UnknownKey(key.to_string()))?;
    if matches!(sk.conflict_policy, ConflictPolicy::CASRequired) {
        return Err(ScratchError::CASRequiredOnBareSet(key.to_string()));
    }
    let dir = scratch_dir();
    let env = make_envelope(key, value, sk.ttl_seconds);
    write_envelope(&dir, &env)
}

/// Compare-and-swap: reads current value, compares with `expected`, writes `new` on match.
///
/// Returns `Ok(())` on success. Returns `Err(ScratchError::CASConflict)` if the
/// current value doesn't match `expected`. An absent/expired value is treated as
/// `serde_json::Value::Null` for the comparison.
///
/// Atomicity note: we use tempfile+rename for the write, but the read→write
/// window is not OS-level atomic. For file-backend v0 this is sufficient (single
/// machine, no concurrent writers in production). INFRA-1121 slice 3/4 replaces
/// with NATS KV CAS which is truly atomic.
pub async fn cas(
    key: &str,
    expected: serde_json::Value,
    new: serde_json::Value,
) -> Result<(), ScratchError> {
    let sk = seed_key_lookup(key).ok_or_else(|| ScratchError::UnknownKey(key.to_string()))?;
    let dir = scratch_dir();
    let path = key_path(&dir, key);

    // Read current value (absent/expired → Null).
    let current = match read_envelope(&path)? {
        None => serde_json::Value::Null,
        Some(env) if is_expired(&env) => serde_json::Value::Null,
        Some(env) => env.value,
    };

    if current != expected {
        return Err(ScratchError::CASConflict {
            key: key.to_string(),
            expected: expected.to_string(),
            actual: current.to_string(),
        });
    }

    let env = make_envelope(key, new, sk.ttl_seconds);
    write_envelope(&dir, &env)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_name_is_chump_scratch() {
        assert_eq!(bucket_name(), "chump_scratch");
    }

    #[test]
    fn seed_keys_has_exactly_five() {
        let keys = seed_keys();
        assert_eq!(keys.len(), 5);
    }

    #[test]
    fn all_documented_seed_keys_present() {
        let names: Vec<&str> = seed_keys().iter().map(|k| k.key).collect();
        assert!(names.contains(&"main.head.sha"));
        assert!(names.contains(&"fleet.size"));
        assert!(names.contains(&"pillar.focus"));
        assert!(names.contains(&"last_known_good.chump_binary"));
        assert!(names.contains(&"red_letter.last_ts"));
    }

    #[test]
    fn cas_required_keys_documented() {
        for key in ["main.head.sha", "last_known_good.chump_binary"] {
            let sk = seed_key_lookup(key).unwrap();
            assert_eq!(
                sk.conflict_policy,
                ConflictPolicy::CASRequired,
                "{key} should be CAS-required"
            );
        }
    }

    #[test]
    fn lww_keys_documented() {
        for key in ["fleet.size", "pillar.focus", "red_letter.last_ts"] {
            let sk = seed_key_lookup(key).unwrap();
            assert_eq!(
                sk.conflict_policy,
                ConflictPolicy::LastWriterWins,
                "{key} should be LastWriterWins"
            );
        }
    }

    #[test]
    fn all_seeds_prompt_inject_true() {
        for sk in seed_keys() {
            assert!(sk.prompt_inject, "{} should be prompt-injected", sk.key);
        }
    }

    #[test]
    fn seed_key_lookup_unknown_returns_none() {
        assert!(seed_key_lookup("totally-bogus-key").is_none());
    }

    #[tokio::test]
    async fn get_returns_none_for_absent_key() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());
        let result = get("fleet.size").await.unwrap();
        assert!(result.is_none());
        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[tokio::test]
    async fn get_rejects_unknown_key_before_stub() {
        match get("bogus").await {
            Err(ScratchError::UnknownKey(k)) => assert_eq!(k, "bogus"),
            other => panic!("expected UnknownKey, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn set_and_get_roundtrip_lww_key() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        set("fleet.size", serde_json::json!(3)).await.unwrap();
        let val = get("fleet.size").await.unwrap();
        assert_eq!(val, Some(serde_json::json!(3)));

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[tokio::test]
    async fn set_rejects_cas_required_key() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        match set("main.head.sha", serde_json::json!("abc")).await {
            Err(ScratchError::CASRequiredOnBareSet(k)) => assert_eq!(k, "main.head.sha"),
            other => panic!("expected CASRequiredOnBareSet, got {:?}", other),
        }

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[tokio::test]
    async fn cas_from_null_to_value() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        // CAS from Null (not yet set) to "sha123"
        cas(
            "main.head.sha",
            serde_json::Value::Null,
            serde_json::json!("sha123"),
        )
        .await
        .unwrap();

        let val = get("main.head.sha").await.unwrap();
        assert_eq!(val, Some(serde_json::json!("sha123")));

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[tokio::test]
    async fn cas_conflict_returns_error() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        // Set initial value
        cas(
            "main.head.sha",
            serde_json::Value::Null,
            serde_json::json!("sha_v1"),
        )
        .await
        .unwrap();

        // CAS with wrong expected → conflict
        match cas(
            "main.head.sha",
            serde_json::json!("sha_wrong"),
            serde_json::json!("sha_v2"),
        )
        .await
        {
            Err(ScratchError::CASConflict { key, .. }) => assert_eq!(key, "main.head.sha"),
            other => panic!("expected CASConflict, got {:?}", other),
        }

        // Value should remain sha_v1
        let val = get("main.head.sha").await.unwrap();
        assert_eq!(val, Some(serde_json::json!("sha_v1")));

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[tokio::test]
    async fn ttl_expiry_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        // Write an envelope with an already-expired TTL directly
        let path = key_path(dir.path(), "fleet.size");
        let expired_env = Envelope {
            key: "fleet.size".to_string(),
            value: serde_json::json!(99),
            written_at: "2020-01-01T00:00:00Z".to_string(),
            ttl_expires_at: "2020-01-01T00:00:01Z".to_string(), // in the past
        };
        let json = serde_json::to_string_pretty(&expired_env).unwrap();
        std::fs::write(&path, json).unwrap();

        let result = get("fleet.size").await.unwrap();
        assert!(
            result.is_none(),
            "expired entry should return None, got {:?}",
            result
        );

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }
}
