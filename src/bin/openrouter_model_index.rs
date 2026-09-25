//! EFFECTIVE-1567 (EFFECTIVE-409 slice) — fetch live model metadata from the
//! OpenRouter API and persist it to a local, deterministic JSON index.
//!
//! Usage: openrouter-model-index [--out <path>] [--url <url>]
//! Env: OPENROUTER_API_KEY (optional — the public /models listing endpoint
//!   works unauthenticated; the key is sent when present in case OpenRouter
//!   tightens the endpoint later).
//!
//! Re-running upserts by model `id` into the existing index file rather than
//! appending, so repeated runs never duplicate entries.

use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const DEFAULT_URL: &str = "https://openrouter.ai/api/v1/models";
const DEFAULT_OUT: &str = ".chump/openrouter_models.json";

#[tokio::main]
async fn main() {
    let cfg = Cfg::from_args(std::env::args().skip(1));
    match run(&cfg).await {
        Ok(count) => {
            println!(
                "openrouter-model-index: wrote {count} models to {}",
                cfg.out_path.display()
            );
        }
        Err(e) => {
            eprintln!("openrouter-model-index: error: {e}");
            std::process::exit(1);
        }
    }
}

struct Cfg {
    url: String,
    out_path: PathBuf,
}

impl Cfg {
    fn from_args(args: impl Iterator<Item = String>) -> Self {
        let mut url = DEFAULT_URL.to_string();
        let mut out_path = PathBuf::from(DEFAULT_OUT);
        let mut args = args.peekable();
        while let Some(a) = args.next() {
            match a.as_str() {
                "--out" => {
                    if let Some(v) = args.next() {
                        out_path = PathBuf::from(v);
                    }
                }
                "--url" => {
                    if let Some(v) = args.next() {
                        url = v;
                    }
                }
                _ => {}
            }
        }
        Cfg { url, out_path }
    }
}

async fn run(cfg: &Cfg) -> Result<usize, Box<dyn std::error::Error>> {
    let body = fetch_models(&cfg.url).await?;
    let entries = extract_entries(&body)?;
    let merged = merge_into_index(&cfg.out_path, entries);
    write_index(&cfg.out_path, &merged)?;
    Ok(merged.len())
}

async fn fetch_models(url: &str) -> Result<Value, Box<dyn std::error::Error>> {
    let client = reqwest::Client::builder()
        .user_agent("chump-openrouter-model-index/1.0")
        .build()?;
    let mut req = client.get(url);
    if let Ok(key) = std::env::var("OPENROUTER_API_KEY") {
        if !key.is_empty() {
            req = req.bearer_auth(key);
        }
    }
    let resp = req.send().await?;
    let status = resp.status();
    if !status.is_success() {
        return Err(format!("GET {url} -> {status}").into());
    }
    Ok(resp.json::<Value>().await?)
}

/// Pulls the `data` array out of the OpenRouter response and returns
/// `(model_id, raw_entry)` pairs, preserving every field OpenRouter sends
/// (context_length, pricing, per_request_limits, expiration_date,
/// knowledge_cutoff, architecture, reasoning, supported_parameters, ...).
fn extract_entries(body: &Value) -> Result<Vec<(String, Value)>, Box<dyn std::error::Error>> {
    let data = body
        .get("data")
        .and_then(Value::as_array)
        .ok_or("response missing `data` array")?;
    let mut out = Vec::with_capacity(data.len());
    for m in data {
        let id = m
            .get("id")
            .and_then(Value::as_str)
            .ok_or("model entry missing `id`")?
            .to_string();
        out.push((id, m.clone()));
    }
    Ok(out)
}

/// Upserts by model id so re-running the job never duplicates entries —
/// existing entries are overwritten in place, new ones are inserted.
fn merge_into_index(out_path: &Path, entries: Vec<(String, Value)>) -> BTreeMap<String, Value> {
    let mut index = load_index(out_path).unwrap_or_default();
    for (id, entry) in entries {
        index.insert(id, entry);
    }
    index
}

fn load_index(path: &Path) -> Option<BTreeMap<String, Value>> {
    let text = std::fs::read_to_string(path).ok()?;
    let doc: Value = serde_json::from_str(&text).ok()?;
    let models = doc.get("models")?.as_object()?.clone();
    Some(models.into_iter().collect())
}

fn write_index(path: &Path, index: &BTreeMap<String, Value>) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let doc = serde_json::json!({
        "source": DEFAULT_URL,
        "fetched_at": chrono::Utc::now().to_rfc3339(),
        "count": index.len(),
        "models": index,
    });
    let text = serde_json::to_string_pretty(&doc)?;
    std::fs::write(path, text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn sample_response() -> Value {
        serde_json::json!({
            "data": [
                {
                    "id": "openrouter/model-a",
                    "context_length": 128000,
                    "pricing": {"prompt": "0", "completion": "0"},
                    "per_request_limits": null,
                    "expiration_date": null,
                    "knowledge_cutoff": "2025-01-01",
                    "architecture": {"modality": "text"},
                    "reasoning": false,
                    "supported_parameters": ["tools"]
                },
                {
                    "id": "openrouter/model-b",
                    "context_length": 262144,
                    "pricing": {"prompt": "0.5", "completion": "1.5"},
                    "supported_parameters": ["tools", "reasoning"]
                }
            ]
        })
    }

    #[test]
    fn extract_entries_pulls_id_and_preserves_full_entry() {
        let body = sample_response();
        let entries = extract_entries(&body).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].0, "openrouter/model-a");
        assert_eq!(entries[0].1["context_length"], 128000);
        assert_eq!(entries[1].1["supported_parameters"][1], "reasoning");
    }

    #[test]
    fn extract_entries_errors_on_missing_data_array() {
        let body = serde_json::json!({"nope": []});
        assert!(extract_entries(&body).is_err());
    }

    #[test]
    fn extract_entries_errors_on_entry_missing_id() {
        let body = serde_json::json!({"data": [{"context_length": 1}]});
        assert!(extract_entries(&body).is_err());
    }

    #[test]
    fn rerun_upserts_without_duplicating() {
        let dir = tempdir().unwrap();
        let out_path = dir.path().join("openrouter_models.json");

        let first = extract_entries(&sample_response()).unwrap();
        let merged1 = merge_into_index(&out_path, first);
        write_index(&out_path, &merged1).unwrap();
        assert_eq!(merged1.len(), 2);

        // Re-run with the same payload plus one changed field on an existing id.
        let mut second_body = sample_response();
        second_body["data"][0]["context_length"] = serde_json::json!(999);
        let second = extract_entries(&second_body).unwrap();
        let merged2 = merge_into_index(&out_path, second);
        write_index(&out_path, &merged2).unwrap();

        // Still exactly 2 entries — no duplication — and the update landed.
        assert_eq!(merged2.len(), 2);
        assert_eq!(merged2["openrouter/model-a"]["context_length"], 999);

        let on_disk: Value =
            serde_json::from_str(&std::fs::read_to_string(&out_path).unwrap()).unwrap();
        assert_eq!(on_disk["count"], 2);
        assert_eq!(on_disk["models"].as_object().unwrap().len(), 2);
    }

    #[test]
    fn cfg_parses_out_and_url_flags() {
        let cfg = Cfg::from_args(
            vec![
                "--out".to_string(),
                "/tmp/x.json".to_string(),
                "--url".to_string(),
                "https://example.com/models".to_string(),
            ]
            .into_iter(),
        );
        assert_eq!(cfg.out_path, PathBuf::from("/tmp/x.json"));
        assert_eq!(cfg.url, "https://example.com/models");
    }
}
