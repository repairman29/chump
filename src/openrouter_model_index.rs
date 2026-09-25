//! EFFECTIVE-1567 (EFFECTIVE-409 slice): fetch live model metadata from the
//! OpenRouter catalog (`GET /api/v1/models`) and persist it to a local,
//! deterministic JSON index.
//!
//! This is a pure catalog fetch-and-store slice — no ranking, no per-provider
//! probing, no cascade wiring. Those are separate EFFECTIVE-409 slices.
//!
//! Persisted models are keyed by `id` and merged into the existing index on
//! each refresh (upsert, not append), so re-running the job never duplicates
//! entries — it only adds new ids or updates existing ones with fresher data.

use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

pub const OPENROUTER_MODELS_URL: &str = "https://openrouter.ai/api/v1/models";
const FETCH_TIMEOUT_SECS: u64 = 15;

/// Fields EFFECTIVE-409 identified as the reason this index is worth
/// borrowing rather than reimplementing: context, pricing, limits,
/// lifecycle, and tool-capability signals.
pub const TRACKED_FIELDS: &[&str] = &[
    "context_length",
    "pricing",
    "per_request_limits",
    "expiration_date",
    "knowledge_cutoff",
    "architecture",
    "reasoning",
    "supported_parameters",
];

pub struct RefreshSummary {
    pub fetched: usize,
    pub total_stored: usize,
    pub path: PathBuf,
}

/// Deterministic on-disk location: `<repo_root>/.chump/model_index/openrouter_models.json`.
pub fn index_path() -> PathBuf {
    crate::repo_path::repo_root()
        .join(".chump")
        .join("model_index")
        .join("openrouter_models.json")
}

fn utc_now_iso8601() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// GET the OpenRouter model catalog and return the raw `data` array.
pub async fn fetch_models(client: &reqwest::Client) -> Result<Vec<Value>> {
    let mut req = client.get(OPENROUTER_MODELS_URL);
    if let Ok(key) = std::env::var("OPENROUTER_API_KEY") {
        if !key.trim().is_empty() {
            req = req.bearer_auth(key.trim());
        }
    }
    let resp = req
        .send()
        .await
        .with_context(|| format!("GET {OPENROUTER_MODELS_URL} failed"))?;
    let status = resp.status();
    if !status.is_success() {
        bail!("GET {OPENROUTER_MODELS_URL} returned HTTP {status}");
    }
    let body: Value = resp
        .json()
        .await
        .context("OpenRouter /models response was not valid JSON")?;
    let data = body
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .context("OpenRouter /models response missing 'data' array")?;
    Ok(data)
}

/// Load the existing index from disk, keyed by model id. Missing/unreadable
/// file yields an empty map (first run).
pub fn load_index(path: &std::path::Path) -> BTreeMap<String, Value> {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return BTreeMap::new();
    };
    let Ok(doc) = serde_json::from_str::<Value>(&raw) else {
        return BTreeMap::new();
    };
    let mut map = BTreeMap::new();
    if let Some(models) = doc.get("models").and_then(Value::as_array) {
        for m in models {
            if let Some(id) = m.get("id").and_then(Value::as_str) {
                map.insert(id.to_string(), m.clone());
            }
        }
    }
    map
}

/// Upsert freshly-fetched models into `map` by id — never appends duplicates.
pub fn merge_models(map: &mut BTreeMap<String, Value>, fetched: &[Value]) {
    for m in fetched {
        if let Some(id) = m.get("id").and_then(Value::as_str) {
            map.insert(id.to_string(), m.clone());
        }
    }
}

/// Persist the index as a deterministically-ordered (by model id) JSON doc.
pub fn save_index(path: &std::path::Path, map: &BTreeMap<String, Value>) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    let models: Vec<&Value> = map.values().collect();
    let doc = serde_json::json!({
        "source": OPENROUTER_MODELS_URL,
        "fetched_at": utc_now_iso8601(),
        "count": models.len(),
        "models": models,
    });
    let body = serde_json::to_string_pretty(&doc).context("serializing model index")?;
    std::fs::write(path, body).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// Fetch the live catalog, upsert into the on-disk index, and persist.
/// Idempotent: running this repeatedly never duplicates entries.
pub async fn refresh() -> Result<RefreshSummary> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(FETCH_TIMEOUT_SECS))
        .build()
        .context("building HTTP client")?;
    let fetched = fetch_models(&client).await?;
    let path = index_path();
    let mut map = load_index(&path);
    merge_models(&mut map, &fetched);
    save_index(&path, &map)?;
    Ok(RefreshSummary {
        fetched: fetched.len(),
        total_stored: map.len(),
        path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(id: &str, context_length: u64) -> Value {
        serde_json::json!({
            "id": id,
            "context_length": context_length,
            "pricing": {"prompt": "0", "completion": "0"},
            "per_request_limits": null,
            "supported_parameters": ["tools"],
        })
    }

    #[test]
    fn merge_upserts_by_id_no_duplicates() {
        let mut map = BTreeMap::new();
        merge_models(&mut map, &[model("a/one", 8_000), model("b/two", 4_000)]);
        assert_eq!(map.len(), 2);

        // Re-running with the same fetch must not duplicate or grow the map.
        merge_models(&mut map, &[model("a/one", 8_000), model("b/two", 4_000)]);
        assert_eq!(map.len(), 2);

        // A refresh that updates one field on an existing id upserts in place.
        merge_models(&mut map, &[model("a/one", 16_000)]);
        assert_eq!(map.len(), 2);
        assert_eq!(map["a/one"]["context_length"], serde_json::json!(16_000));
    }

    #[test]
    fn save_and_load_roundtrip_is_deterministic() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("openrouter_models.json");

        let mut map = BTreeMap::new();
        merge_models(&mut map, &[model("z/last", 1), model("a/first", 2)]);
        save_index(&path, &map).expect("save");

        let raw = std::fs::read_to_string(&path).expect("read back");
        let doc: Value = serde_json::from_str(&raw).expect("valid json");
        assert_eq!(doc["count"], serde_json::json!(2));
        let ids: Vec<&str> = doc["models"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, vec!["a/first", "z/last"]);

        let reloaded = load_index(&path);
        assert_eq!(reloaded.len(), 2);
        assert!(reloaded.contains_key("z/last"));
    }

    #[test]
    fn rerun_against_disk_does_not_duplicate() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("openrouter_models.json");

        let mut map = BTreeMap::new();
        merge_models(&mut map, &[model("a/one", 8_000)]);
        save_index(&path, &map).expect("save 1");

        // Simulate a second job run: load from disk, merge the same fetch, save again.
        let mut reloaded = load_index(&path);
        merge_models(&mut reloaded, &[model("a/one", 8_000)]);
        save_index(&path, &reloaded).expect("save 2");

        let final_map = load_index(&path);
        assert_eq!(final_map.len(), 1);
    }

    /// AC1/AC2 — live network check. Ignored by default (no network in CI
    /// sandboxes, and OpenRouter's exact model count drifts over time); run
    /// manually with `cargo test --package chump openrouter_live_fetch -- --ignored`.
    #[tokio::test]
    #[ignore]
    async fn openrouter_live_fetch_returns_models_with_tracked_fields() {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(FETCH_TIMEOUT_SECS))
            .build()
            .unwrap();
        let models = fetch_models(&client).await.expect("live fetch");
        assert!(!models.is_empty(), "expected at least one model");
        let first = &models[0];
        for field in TRACKED_FIELDS {
            assert!(
                first.get(field).is_some(),
                "expected field {field} on live model entry"
            );
        }
    }
}
