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
use tracing::info;

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

/// The v1 seed keys. Documented in docs/design/A2A_SCRATCHPAD_KEYS.md.
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
/// 6. `ci.flake_classification` — CI-audit curator's latest JSON blob
///    classifying current trunk failures as flake/logic-bug/missing-gate.
///    CAS-required (writer reads existing blob, merges, CAS-writes back).
///    Not prompt-injected into general briefings (CI-audit curator reads it
///    directly); injected only when the briefing gap is CI-related.
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
        SeedKey {
            key: "ci.flake_classification",
            conflict_policy: ConflictPolicy::CASRequired,
            ttl_seconds: 3_600,
            // Not injected into general briefings — CI-audit curator reads
            // it directly to avoid bloating every agent's context.
            prompt_inject: false,
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
    let result = write_envelope(&dir, &env);
    if result.is_ok() {
        // kind=scratchpad_set — registered in EVENT_REGISTRY.yaml (INFRA-1121)
        info!(kind = "scratchpad_set", key = key, "scratchpad LWW set");
    }
    result
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
        // kind=scratchpad_cas_conflict — registered in EVENT_REGISTRY.yaml (INFRA-1121)
        info!(
            kind = "scratchpad_cas_conflict",
            key = key,
            "scratchpad CAS conflict: caller should retry"
        );
        return Err(ScratchError::CASConflict {
            key: key.to_string(),
            expected: expected.to_string(),
            actual: current.to_string(),
        });
    }

    let env = make_envelope(key, new, sk.ttl_seconds);
    write_envelope(&dir, &env)
}

/// Snapshot the top-N prompt-injectable seed keys for agent briefing injection.
///
/// Returns a Vec of `(key, value_string)` pairs for keys where `prompt_inject: true`
/// and the current value is set (non-expired). Capped at `max_keys` entries
/// (default 5 = all v1 seed keys). Total rendered length capped at ~500 tokens
/// via character truncation at 2000 chars (≈500 tokens at 4 chars/token).
///
/// Designed for injection into `chump --briefing` output (INFRA-1121 slice 3/4).
/// Called at session start; I/O is local file reads only (no NATS required).
///
/// Graceful: individual key errors are silently skipped (key may be unset).
/// Returns empty vec when scratch dir is absent or all keys are expired/unset.
pub async fn prompt_inject_snapshot(max_keys: usize) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let total_char_budget: usize = 2000; // ≈500 tokens at 4 chars/token
    let mut used: usize = 0;

    for sk in seed_keys() {
        if !sk.prompt_inject {
            continue;
        }
        if out.len() >= max_keys {
            break;
        }
        match get(sk.key).await {
            Ok(Some(v)) => {
                let v_str = v.to_string();
                // Truncate long values so a single key can't exhaust the budget.
                let budget_remaining = total_char_budget.saturating_sub(used);
                if budget_remaining == 0 {
                    break;
                }
                let truncated = if v_str.len() > budget_remaining {
                    format!("{}…", &v_str[..budget_remaining.saturating_sub(1)])
                } else {
                    v_str.clone()
                };
                used += truncated.len();
                out.push((sk.key.to_string(), truncated));
            }
            Ok(None) => {} // absent or expired — skip silently
            Err(_) => {}   // unknown key or I/O error — skip silently
        }
    }
    if !out.is_empty() {
        // kind=scratchpad_injected — registered in EVENT_REGISTRY.yaml (INFRA-1121)
        info!(
            kind = "scratchpad_injected",
            key_count = out.len(),
            "scratchpad context injected into briefing"
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    // serial_test: env var CHUMP_SCRATCH_DIR is process-global; tokio runs
    // async tests concurrently by default. #[serial] serialises all tests
    // in this module that touch CHUMP_SCRATCH_DIR so they don't race.
    use serial_test::serial;

    #[test]
    fn bucket_name_is_chump_scratch() {
        assert_eq!(bucket_name(), "chump_scratch");
    }

    #[test]
    fn seed_keys_has_expected_count() {
        // v1 = 5 original keys + ci.flake_classification (INFRA-1121)
        let keys = seed_keys();
        assert_eq!(keys.len(), 6);
    }

    #[test]
    fn all_documented_seed_keys_present() {
        let names: Vec<&str> = seed_keys().iter().map(|k| k.key).collect();
        assert!(names.contains(&"main.head.sha"));
        assert!(names.contains(&"fleet.size"));
        assert!(names.contains(&"pillar.focus"));
        assert!(names.contains(&"last_known_good.chump_binary"));
        assert!(names.contains(&"red_letter.last_ts"));
        assert!(names.contains(&"ci.flake_classification"));
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
    fn prompt_inject_flags_match_design_doc() {
        // Original 5 seed keys are all prompt-injected.
        for key in [
            "main.head.sha",
            "fleet.size",
            "pillar.focus",
            "last_known_good.chump_binary",
            "red_letter.last_ts",
        ] {
            let sk = seed_key_lookup(key).unwrap();
            assert!(
                sk.prompt_inject,
                "{key} should be prompt-injected per A2A_SCRATCHPAD_KEYS.md"
            );
        }
        // ci.flake_classification is intentionally NOT injected into general
        // briefings (CI-audit curator reads it directly).
        let ci_key = seed_key_lookup("ci.flake_classification").unwrap();
        assert!(
            !ci_key.prompt_inject,
            "ci.flake_classification should NOT be prompt-injected into general briefings"
        );
    }

    #[test]
    fn seed_key_lookup_unknown_returns_none() {
        assert!(seed_key_lookup("totally-bogus-key").is_none());
    }

    #[serial]
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
        // No env var needed — unknown-key path never touches CHUMP_SCRATCH_DIR.
        match get("bogus").await {
            Err(ScratchError::UnknownKey(k)) => assert_eq!(k, "bogus"),
            other => panic!("expected UnknownKey, got {:?}", other),
        }
    }

    #[serial]
    #[tokio::test]
    async fn set_and_get_roundtrip_lww_key() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        set("fleet.size", serde_json::json!(3)).await.unwrap();
        let val = get("fleet.size").await.unwrap();
        assert_eq!(val, Some(serde_json::json!(3)));

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[serial]
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

    #[serial]
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

    #[serial]
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

    #[serial]
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

    // ── prompt_inject_snapshot tests ──────────────────────────────────────────

    #[serial]
    #[tokio::test]
    async fn prompt_inject_snapshot_empty_when_no_keys_set() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        let snap = prompt_inject_snapshot(5).await;
        assert!(
            snap.is_empty(),
            "should be empty when no keys written, got {:?}",
            snap
        );

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[serial]
    #[tokio::test]
    async fn prompt_inject_snapshot_returns_set_lww_keys() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        set("fleet.size", serde_json::json!(4)).await.unwrap();
        set("pillar.focus", serde_json::json!("EFFECTIVE"))
            .await
            .unwrap();

        let snap = prompt_inject_snapshot(5).await;
        let keys: Vec<&str> = snap.iter().map(|(k, _)| k.as_str()).collect();
        assert!(keys.contains(&"fleet.size"), "fleet.size missing: {keys:?}");
        assert!(
            keys.contains(&"pillar.focus"),
            "pillar.focus missing: {keys:?}"
        );

        // Values must be present
        let fleet_val = snap
            .iter()
            .find(|(k, _)| k == "fleet.size")
            .map(|(_, v)| v.as_str());
        assert_eq!(fleet_val, Some("4"));

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[serial]
    #[tokio::test]
    async fn prompt_inject_snapshot_respects_max_keys_cap() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        // Write all LWW keys
        set("fleet.size", serde_json::json!(2)).await.unwrap();
        set("pillar.focus", serde_json::json!("CREDIBLE"))
            .await
            .unwrap();
        set(
            "red_letter.last_ts",
            serde_json::json!("2026-06-01T00:00:00Z"),
        )
        .await
        .unwrap();

        // Cap at 2 — should only return 2 entries even though 3 are set.
        let snap = prompt_inject_snapshot(2).await;
        assert!(
            snap.len() <= 2,
            "expected ≤2 entries with max_keys=2, got {}",
            snap.len()
        );

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }

    #[serial]
    #[tokio::test]
    async fn prompt_inject_snapshot_includes_cas_keys_after_write() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

        cas(
            "main.head.sha",
            serde_json::Value::Null,
            serde_json::json!("abc123"),
        )
        .await
        .unwrap();

        let snap = prompt_inject_snapshot(5).await;
        let found = snap.iter().find(|(k, _)| k == "main.head.sha");
        assert!(
            found.is_some(),
            "main.head.sha should appear after CAS write: {snap:?}"
        );
        assert_eq!(found.unwrap().1, "\"abc123\"");

        std::env::remove_var("CHUMP_SCRATCH_DIR");
    }
}
