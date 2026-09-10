//! EFFECTIVE-1567 — OpenRouter live model metadata fetcher (EFFECTIVE-409 slice).
//!
//! GETs https://openrouter.ai/api/v1/models and persists the model catalog
//! (context_length, pricing, per_request_limits, expiration_date,
//! knowledge_cutoff, architecture, reasoning, supported_parameters) to a
//! deterministic local JSON index. Re-running upserts by model `id` rather
//! than duplicating entries, so the job is idempotent under a schedule.
//!
//! Usage: `openrouter-model-index [--out <path>]`
//!
//! `--out` defaults to `$CHUMP_OPENROUTER_INDEX` then
//! `.chump/openrouter_models.json` relative to the repo root.

use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

const OPENROUTER_MODELS_URL: &str = "https://openrouter.ai/api/v1/models";

fn default_out_path() -> PathBuf {
    std::env::var("CHUMP_OPENROUTER_INDEX")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(".chump/openrouter_models.json"))
}

fn out_path_from_args() -> PathBuf {
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--out" && i + 1 < args.len() {
            return PathBuf::from(&args[i + 1]);
        }
        i += 1;
    }
    default_out_path()
}

/// Merges freshly fetched model entries into the existing on-disk index
/// (if any), keyed by model `id`. Re-running with the same fetched batch
/// upserts in place rather than duplicating entries — this is what makes
/// the job idempotent under a schedule (AC #4).
fn merge_index(existing_json: Option<&str>, fetched: Vec<Value>) -> BTreeMap<String, Value> {
    let mut index: BTreeMap<String, Value> = existing_json
        .and_then(|s| serde_json::from_str::<Value>(s).ok())
        .and_then(|parsed| {
            parsed
                .get("models")
                .and_then(|m| m.as_object())
                .map(|obj| obj.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
        })
        .unwrap_or_default();

    for model in fetched {
        if let Some(id) = model.get("id").and_then(|v| v.as_str()) {
            index.insert(id.to_string(), model);
        }
    }

    index
}

#[tokio::main]
async fn main() -> Result<()> {
    let out_path = out_path_from_args();

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .context("building HTTP client")?;

    let mut req = client.get(OPENROUTER_MODELS_URL);
    if let Ok(key) = std::env::var("OPENROUTER_API_KEY") {
        if !key.is_empty() {
            req = req.bearer_auth(key);
        }
    }

    let resp = req
        .send()
        .await
        .context("GET https://openrouter.ai/api/v1/models")?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("openrouter /v1/models returned HTTP {status}");
    }

    let body: Value = resp.json().await.context("parsing OpenRouter response")?;
    let fetched: Vec<Value> = body
        .get("data")
        .and_then(|d| d.as_array())
        .cloned()
        .context("response missing 'data' array")?;

    let existing = if out_path.exists() {
        Some(
            std::fs::read_to_string(&out_path)
                .with_context(|| format!("reading existing index at {}", out_path.display()))?,
        )
    } else {
        None
    };

    let fetched_count = fetched.len();
    let index = merge_index(existing.as_deref(), fetched);

    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
    }

    let out = serde_json::json!({
        "source": OPENROUTER_MODELS_URL,
        "fetched_count": fetched_count,
        "model_count": index.len(),
        "models": index,
    });
    std::fs::write(&out_path, serde_json::to_string_pretty(&out)?)
        .with_context(|| format!("writing {}", out_path.display()))?;

    println!(
        "openrouter-model-index: fetched {} models, index now holds {} at {}",
        fetched_count,
        index.len(),
        out_path.display()
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_index_starts_empty_with_no_existing_file() {
        let fetched = vec![serde_json::json!({"id": "openrouter/foo", "context_length": 8192})];
        let index = merge_index(None, fetched);
        assert_eq!(index.len(), 1);
        assert!(index.contains_key("openrouter/foo"));
    }

    #[test]
    fn merge_index_upserts_without_duplicating_on_rerun() {
        let first_batch = vec![
            serde_json::json!({"id": "openrouter/foo", "context_length": 8192}),
            serde_json::json!({"id": "openrouter/bar", "context_length": 4096}),
        ];
        let after_first = merge_index(None, first_batch);
        assert_eq!(after_first.len(), 2);

        let existing_doc = serde_json::json!({"models": after_first}).to_string();

        // Re-run with the same batch: count must not grow (idempotent).
        let second_batch = vec![
            serde_json::json!({"id": "openrouter/foo", "context_length": 8192}),
            serde_json::json!({"id": "openrouter/bar", "context_length": 4096}),
        ];
        let after_second = merge_index(Some(&existing_doc), second_batch);
        assert_eq!(after_second.len(), 2);
    }

    #[test]
    fn merge_index_updates_changed_fields_and_adds_new_models() {
        let first_batch = vec![serde_json::json!({"id": "openrouter/foo", "context_length": 8192})];
        let after_first = merge_index(None, first_batch);
        let existing_doc = serde_json::json!({"models": after_first}).to_string();

        // Re-run: "foo" changed context_length, and "baz" is brand new.
        let second_batch = vec![
            serde_json::json!({"id": "openrouter/foo", "context_length": 16384}),
            serde_json::json!({"id": "openrouter/baz", "context_length": 2048}),
        ];
        let after_second = merge_index(Some(&existing_doc), second_batch);

        assert_eq!(after_second.len(), 2);
        assert_eq!(
            after_second["openrouter/foo"]["context_length"],
            serde_json::json!(16384)
        );
        assert!(after_second.contains_key("openrouter/baz"));
    }

    #[test]
    fn merge_index_skips_entries_without_an_id() {
        let fetched = vec![serde_json::json!({"context_length": 8192})];
        let index = merge_index(None, fetched);
        assert!(index.is_empty());
    }
}
