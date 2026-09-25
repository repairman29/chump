//! EFFECTIVE-1567 (EFFECTIVE-409 slice): `chump model-index <refresh|show>`.
//!
//! `refresh` fetches the live OpenRouter model catalog and upserts it into a
//! local deterministic JSON index (`.chump/model_index/openrouter_models.json`).
//! `show` prints the current on-disk index without hitting the network.

use crate::openrouter_model_index::{index_path, load_index, refresh};

fn print_usage() {
    eprintln!("Usage: chump model-index <refresh|show> [--json]");
    eprintln!("  refresh   GET the OpenRouter model catalog and upsert into the local index");
    eprintln!("  show      print the current on-disk index (no network call)");
}

pub async fn run(args: &[String]) -> i32 {
    let json_out = args.iter().any(|a| a == "--json");
    match args.first().map(String::as_str) {
        Some("refresh") => match refresh().await {
            Ok(summary) => {
                if json_out {
                    println!(
                        "{}",
                        serde_json::json!({
                            "fetched": summary.fetched,
                            "total_stored": summary.total_stored,
                            "path": summary.path.display().to_string(),
                        })
                    );
                } else {
                    println!(
                        "model-index refresh: fetched {} models, {} total stored -> {}",
                        summary.fetched,
                        summary.total_stored,
                        summary.path.display()
                    );
                }
                0
            }
            Err(e) => {
                eprintln!("model-index refresh failed: {e:#}");
                1
            }
        },
        Some("show") => {
            let path = index_path();
            let map = load_index(&path);
            if json_out {
                let models: Vec<_> = map.values().collect();
                println!(
                    "{}",
                    serde_json::json!({"path": path.display().to_string(), "count": models.len(), "models": models})
                );
            } else {
                println!("{} models indexed at {}", map.len(), path.display());
                for id in map.keys() {
                    println!("  {id}");
                }
            }
            0
        }
        _ => {
            print_usage();
            2
        }
    }
}
