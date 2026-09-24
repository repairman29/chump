//! `chump model-index` — EFFECTIVE-1567 (EFFECTIVE-409 slice).
//!
//! Fetches live model metadata from OpenRouter's public catalog
//! (https://openrouter.ai/api/v1/models) and persists it to a local JSON
//! index keyed by model id, so downstream consumers (the EFFECTIVE-409
//! inference tender) can read the metadata without re-polling on every use.
//!
//! OpenRouter is a supplementary cross-provider metadata source, not the
//! provider registry of record (see EFFECTIVE-409's notes) — this slice
//! only covers the fetch + persist step.

use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;

const OPENROUTER_MODELS_URL: &str = "https://openrouter.ai/api/v1/models";

fn repo_root() -> PathBuf {
    crate::repo_path::repo_root()
}

fn index_path() -> PathBuf {
    repo_root().join(".chump/openrouter_models.json")
}

fn print_help() {
    println!("chump model-index — fetch + persist live OpenRouter model metadata (EFFECTIVE-1567)");
    println!();
    println!("USAGE:");
    println!("    chump model-index refresh [--json]");
    println!();
    println!(
        "Fetches {} and merges the result into",
        OPENROUTER_MODELS_URL
    );
    println!(
        "{} keyed by model id (rerunnable — no duplicate entries).",
        index_path().display()
    );
}

async fn fetch_models(client: &reqwest::Client) -> Result<Vec<Value>> {
    let mut req = client.get(OPENROUTER_MODELS_URL);
    if let Ok(key) = std::env::var("OPENROUTER_API_KEY") {
        if !key.trim().is_empty() {
            req = req.bearer_auth(key);
        }
    }
    let resp = req
        .send()
        .await
        .context("GET https://openrouter.ai/api/v1/models failed")?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("openrouter /models returned HTTP {}", status);
    }
    let body: Value = resp
        .json()
        .await
        .context("failed to parse openrouter /models response as JSON")?;
    let data = body
        .get("data")
        .and_then(|d| d.as_array())
        .context("openrouter /models response missing 'data' array")?;
    Ok(data.clone())
}

fn load_existing_index(path: &PathBuf) -> BTreeMap<String, Value> {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return BTreeMap::new();
    };
    let Ok(existing) = serde_json::from_str::<Value>(&raw) else {
        return BTreeMap::new();
    };
    existing
        .get("models")
        .and_then(|m| m.as_object())
        .map(|obj| obj.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
        .unwrap_or_default()
}

async fn refresh(json_out: bool) -> i32 {
    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: could not build HTTP client: {}", e);
            return 1;
        }
    };

    let models = match fetch_models(&client).await {
        Ok(m) => m,
        Err(e) => {
            eprintln!("error: {:#}", e);
            return 1;
        }
    };

    let path = index_path();
    let mut index = load_existing_index(&path);
    let fetched_count = models.len();
    for model in &models {
        let Some(id) = model.get("id").and_then(|v| v.as_str()) else {
            continue;
        };
        // Keyed insert — reruns overwrite the same id rather than duplicating it.
        index.insert(id.to_string(), model.clone());
    }

    if let Some(parent) = path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("error: could not create {}: {}", parent.display(), e);
            return 1;
        }
    }

    let fetched_at = chrono::Utc::now().to_rfc3339();
    let out = serde_json::json!({
        "fetched_at": fetched_at,
        "source": OPENROUTER_MODELS_URL,
        "model_count": index.len(),
        "models": index,
    });
    let pretty = match serde_json::to_string_pretty(&out) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: could not serialize index: {}", e);
            return 1;
        }
    };
    if let Err(e) = std::fs::write(&path, pretty) {
        eprintln!("error: could not write {}: {}", path.display(), e);
        return 1;
    }

    if json_out {
        println!(
            "{}",
            serde_json::json!({
                "fetched": fetched_count,
                "indexed_total": index.len(),
                "path": path.display().to_string(),
            })
        );
    } else {
        println!(
            "fetched {} models from OpenRouter; index now holds {} at {}",
            fetched_count,
            index.len(),
            path.display()
        );
    }
    0
}

pub async fn run(args: &[String]) -> i32 {
    let json_out = args.iter().any(|a| a == "--json");
    match args.first().map(String::as_str) {
        Some("refresh") => refresh(json_out).await,
        Some("--help") | Some("-h") | None => {
            print_help();
            if args.is_empty() {
                1
            } else {
                0
            }
        }
        Some(other) => {
            eprintln!("unknown model-index subcommand: {}", other);
            print_help();
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_existing_index_missing_file_returns_empty() {
        let path = PathBuf::from("/nonexistent/path/that/should/not/exist.json");
        assert!(load_existing_index(&path).is_empty());
    }

    #[test]
    fn load_existing_index_parses_models_map() {
        let dir = std::env::temp_dir().join(format!("model_index_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("index.json");
        std::fs::write(
            &path,
            serde_json::json!({
                "models": {
                    "vendor/model-a": {"id": "vendor/model-a", "context_length": 1000}
                }
            })
            .to_string(),
        )
        .unwrap();

        let index = load_existing_index(&path);
        assert_eq!(index.len(), 1);
        assert!(index.contains_key("vendor/model-a"));

        std::fs::remove_dir_all(&dir).ok();
    }
}
