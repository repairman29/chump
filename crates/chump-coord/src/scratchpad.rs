// crates/chump-coord/src/scratchpad.rs — INFRA-1761
//
// A2A Layer 3d foundation slice (1/4) — shared KV scratchpad with seed
// keys + conflict-policy schema.
//
// This file ships ONLY: ConflictPolicy enum, SeedKey struct, the 5 seed
// keys, bucket_name(), and stubbed get/set/cas returning NotImplemented.
// Real NATS KV ops + prompt injection + bash wrapper land in subsequent
// INFRA-1121 slices.
//
// Why stub-first: nails the seed-key set + conflict semantics so any agent
// reading scratchpad values can use the documented contract today (e.g.
// referenced from --briefing context generation in slice 3/4), while the
// real CAS write logic catches up.

use std::sync::Arc;

/// NATS KV bucket name. Real impl in slice 2/4 creates it on first publish
/// with TTL = 86400s default and history = 1 (CAS-friendly).
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
    NotImplemented,
    UnknownKey(String),
    CASConflict {
        key: String,
        expected: String,
        actual: String,
    },
    InfiniteTtlMissingReview {
        key: String,
    },
}

impl std::fmt::Display for ScratchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScratchError::NotImplemented => write!(
                f,
                "scratchpad stub — real NATS KV impl ships in INFRA-1121 slice 2/4"
            ),
            ScratchError::UnknownKey(k) => write!(f, "unknown scratchpad key: {k}"),
            ScratchError::CASConflict {
                key,
                expected,
                actual,
            } => write!(
                f,
                "CAS conflict on '{key}': expected '{expected}', got '{actual}'"
            ),
            ScratchError::InfiniteTtlMissingReview { key } => write!(
                f,
                "key '{key}' marked ttl=infinite but lacks operator_reviewed_at timestamp"
            ),
        }
    }
}

impl std::error::Error for ScratchError {}

/// Look up a seed key's schema. Returns None for unknown keys.
pub fn seed_key_lookup(key: &str) -> Option<SeedKey> {
    seed_keys().into_iter().find(|sk| sk.key == key)
}

/// Stub `get` — real impl in slice 2/4 reads NATS KV entry.
pub async fn get(key: &str) -> Result<Option<serde_json::Value>, ScratchError> {
    if seed_key_lookup(key).is_none() {
        return Err(ScratchError::UnknownKey(key.to_string()));
    }
    Err(ScratchError::NotImplemented)
}

/// Stub `set` (LWW path) — real impl in slice 2/4 publishes to NATS KV.
pub async fn set(key: &str, value: serde_json::Value) -> Result<(), ScratchError> {
    let sk = seed_key_lookup(key).ok_or_else(|| ScratchError::UnknownKey(key.to_string()))?;
    if matches!(sk.conflict_policy, ConflictPolicy::CASRequired) {
        // CAS-required keys reject bare set() — caller must use cas().
        // For the stub, surface as NotImplemented so callers see the
        // distinction immediately.
        let _ = value;
        return Err(ScratchError::NotImplemented);
    }
    let _ = value;
    Err(ScratchError::NotImplemented)
}

/// Stub `cas` (compare-and-swap) — real impl in slice 2/4 reads NATS KV
/// revision, attempts compare-and-write, returns CASConflict on contention.
pub async fn cas(
    key: &str,
    expected: serde_json::Value,
    new: serde_json::Value,
) -> Result<(), ScratchError> {
    if seed_key_lookup(key).is_none() {
        return Err(ScratchError::UnknownKey(key.to_string()));
    }
    let _ = (expected, new);
    Err(ScratchError::NotImplemented)
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
    async fn get_returns_not_implemented_for_known_key() {
        match get("fleet.size").await {
            Err(ScratchError::NotImplemented) => {}
            other => panic!("expected NotImplemented, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn get_rejects_unknown_key_before_stub() {
        match get("bogus").await {
            Err(ScratchError::UnknownKey(k)) => assert_eq!(k, "bogus"),
            other => panic!("expected UnknownKey, got {:?}", other),
        }
    }
}
