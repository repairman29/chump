//! Holographic Global Workspace (HGW): distributed representations of blackboard state.
//!
//! Replaces centralized entry lookup with Holographic Reduced Representations (HRR)
//! via the `amari-holographic` crate. Each module can maintain a single superposed
//! vector that encodes low-resolution awareness of the full blackboard.
//!
//! Uses ProductCliffordAlgebra<32> (256-dimensional, ~46 item capacity) which fits
//! the typical blackboard size of 20-30 entries.
//!
//! Part of the Synthetic Consciousness Framework, Section 3.4.

use amari_holographic::{AlgebraConfig, BindingAlgebra, HolographicMemory, ProductCliffordAlgebra};
use std::collections::HashMap;
use std::sync::Mutex;

type Algebra = ProductCliffordAlgebra<32>; // 256-dimensional

/// A named key in the holographic workspace.
#[derive(Debug, Clone, Hash, PartialEq, Eq)]
struct EntryKey {
    source: String,
    id: u64,
}

struct HgwInner {
    memory: HolographicMemory<Algebra>,
    /// Stable random versors for each registered key, so we can retrieve by the same key.
    key_vectors: HashMap<EntryKey, Algebra>,
    /// Stable random versors for module names (used as role keys in the encoding).
    module_vectors: HashMap<String, Algebra>,
}

impl HgwInner {
    fn new() -> Self {
        Self {
            memory: HolographicMemory::<Algebra>::with_key_tracking(AlgebraConfig::default()),
            key_vectors: HashMap::new(),
            module_vectors: HashMap::new(),
        }
    }

    fn module_vector(&mut self, name: &str) -> Algebra {
        self.module_vectors
            .entry(name.to_string())
            .or_insert_with(|| Algebra::random_versor(2))
            .clone()
    }
}

static STATE: std::sync::OnceLock<Mutex<HgwInner>> = std::sync::OnceLock::new();

fn state() -> &'static Mutex<HgwInner> {
    STATE.get_or_init(|| Mutex::new(HgwInner::new()))
}

/// Encode a blackboard entry into the holographic workspace.
///
/// The entry is stored as: key=source_vector⊛id_vector, value=content_vector.
/// Content is encoded by hashing to a deterministic set of coefficients.
pub fn encode_entry(source: &str, id: u64, content: &str) {
    if let Ok(mut guard) = state().lock() {
        let entry_key = EntryKey {
            source: source.to_string(),
            id,
        };

        let key_vec = guard
            .key_vectors
            .entry(entry_key)
            .or_insert_with(|| Algebra::random_versor(2))
            .clone();

        let value_vec = string_to_vector(content);

        guard.memory.store(&key_vec, &value_vec);
    }
}

/// Retrieve the content vector most similar to a given query string.
/// Returns (similarity_score, approximate_match_bool).
pub fn query_similarity(probe: &str) -> (f64, bool) {
    if let Ok(guard) = state().lock() {
        let probe_vec = string_to_vector(probe);
        let result = guard.memory.retrieve(&probe_vec);
        let confidence = result.confidence;
        (confidence, confidence > 0.3)
    } else {
        (0.0, false)
    }
}

/// Retrieve using a known key (source + id).
pub fn retrieve_by_key(source: &str, id: u64) -> Option<f64> {
    let entry_key = EntryKey {
        source: source.to_string(),
        id,
    };
    if let Ok(guard) = state().lock() {
        if let Some(key_vec) = guard.key_vectors.get(&entry_key) {
            let result = guard.memory.retrieve(key_vec);
            return Some(result.confidence);
        }
    }
    None
}

/// Probe whether the workspace likely contains content related to a module.
///
/// **Known limitation:** Module vectors are random versors unrelated to the
/// key vectors used by `encode_entry`, so the returned confidence is not
/// semantically meaningful. This is a placeholder for future work where
/// entries would be tagged with their source module during encoding.
#[deprecated(note = "returns arbitrary confidence; module vectors are not aligned with entry keys")]
pub fn module_awareness(module_name: &str) -> f64 {
    if let Ok(mut guard) = state().lock() {
        let mv = guard.module_vector(module_name);
        let result = guard.memory.retrieve(&mv);
        result.confidence
    } else {
        0.0
    }
}

/// Get capacity info about the holographic workspace.
pub fn capacity() -> (usize, usize) {
    if let Ok(guard) = state().lock() {
        let info = guard.memory.capacity_info();
        (guard.key_vectors.len(), info.theoretical_capacity)
    } else {
        (0, 0)
    }
}

/// Clear the holographic workspace.
pub fn clear() {
    if let Ok(mut guard) = state().lock() {
        guard.memory.clear();
        guard.key_vectors.clear();
    }
}

/// Sync from the current explicit blackboard entries. Called periodically
/// to keep the HRR representation in sync with the real blackboard.
pub fn sync_from_blackboard() {
    let entries = crate::blackboard::global().broadcast_entries();
    clear();
    for entry in &entries {
        encode_entry(&entry.source.to_string(), entry.id, &entry.content);
    }
}

/// JSON metrics for the health endpoint.
pub fn metrics_json() -> serde_json::Value {
    let (items, theoretical_max) = capacity();
    serde_json::json!({
        "items_encoded": items,
        "theoretical_capacity": theoretical_max,
        "algebra": "ProductCl3x32 (256-dim)",
        "utilization_pct": if theoretical_max > 0 {
            ((items as f64 / theoretical_max as f64) * 100.0).round()
        } else {
            0.0
        },
    })
}

/// Deterministic encoding of a string into a 256-dimensional algebra element.
/// Uses a simple hash-based approach: each 8-byte chunk of the content hash
/// maps to coefficients.
fn string_to_vector(s: &str) -> Algebra {
    let hash = simple_hash(s);
    let mut coeffs = vec![0.0f64; 256];
    for (i, c) in coeffs.iter_mut().enumerate() {
        let seed = hash
            .wrapping_mul(i as u64 + 1)
            .wrapping_add(0x9E3779B97F4A7C15);
        let normalized = (seed as f64) / (u64::MAX as f64) * 2.0 - 1.0;
        *c = normalized;
    }
    let norm: f64 = coeffs.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm > 0.0 {
        for c in coeffs.iter_mut() {
            *c /= norm;
        }
    }
    Algebra::from_coefficients(&coeffs).unwrap_or_else(|_| Algebra::random_unit())
}

fn simple_hash(s: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_and_capacity() {
        clear();
        assert_eq!(capacity().0, 0);
        encode_entry("memory", 1, "the user likes Rust");
        encode_entry("episode", 2, "last turn was successful");
        let (items, cap) = capacity();
        assert_eq!(items, 2);
        assert!(
            cap >= 40,
            "ProductCl3x32 capacity should be ~46, got {}",
            cap
        );
    }

    #[test]
    fn test_retrieve_by_known_key() {
        clear();
        encode_entry("test_mod", 42, "important fact about AI");
        let conf = retrieve_by_key("test_mod", 42);
        assert!(conf.is_some(), "should find entry by known key");
        let c = conf.unwrap();
        assert!(c > 0.5, "confidence should be high for known key: {}", c);
    }

    #[test]
    fn test_unknown_key_low_confidence() {
        clear();
        encode_entry("test_mod", 1, "some data");
        let conf = retrieve_by_key("other", 999);
        assert!(conf.is_none(), "unknown key should return None");
    }

    #[test]
    fn test_string_to_vector_deterministic() {
        let v1 = string_to_vector("hello world");
        let v2 = string_to_vector("hello world");
        let sim = v1.similarity(&v2);
        assert!(
            (sim - 1.0).abs() < 0.01,
            "same string should produce identical vectors: sim={}",
            sim
        );
    }

    #[test]
    fn test_different_strings_dissimilar() {
        let v1 = string_to_vector("hello world");
        let v2 = string_to_vector("completely different text about something else");
        let sim = v1.similarity(&v2).abs();
        assert!(
            sim < 0.5,
            "different strings should be dissimilar: sim={}",
            sim
        );
    }

    #[test]
    fn test_clear_resets() {
        clear();
        encode_entry("test", 1, "data");
        assert_eq!(capacity().0, 1);
        clear();
        assert_eq!(capacity().0, 0);
    }

    #[test]
    fn test_metrics_json_structure() {
        let j = metrics_json();
        assert!(j.get("items_encoded").is_some());
        assert!(j.get("theoretical_capacity").is_some());
        assert!(j.get("algebra").is_some());
        assert!(j.get("utilization_pct").is_some());
    }
}
