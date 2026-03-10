//! In-process text embeddings via fastembed (optional feature `inprocess-embed`).
//! Uses the same model class as the Python embed server (all-MiniLM-L6-v2) for compatibility
//! with existing chump_memory_embeddings.json. Model is downloaded on first use.

use anyhow::{anyhow, Result};
use std::sync::Mutex;

use once_cell::sync::OnceCell;

static MODEL: OnceCell<Mutex<fastembed::TextEmbedding>> = OnceCell::new();

fn init_model() -> Result<&'static Mutex<fastembed::TextEmbedding>> {
    MODEL.get_or_try_init(|| {
        let cache_dir = std::env::var("CHUMP_EMBED_CACHE_DIR").ok();
        let opts = cache_dir.map_or_else(
            || fastembed::InitOptions::new(fastembed::EmbeddingModel::AllMiniLML6V2),
            |dir| {
                fastembed::InitOptions::new(fastembed::EmbeddingModel::AllMiniLML6V2)
                    .with_cache_dir(std::path::PathBuf::from(dir))
            },
        );
        fastembed::TextEmbedding::try_new(opts)
            .map(Mutex::new)
            .map_err(|e| anyhow!("{}", e))
    })
}

/// Embed a single text. Blocks; call from spawn_blocking if in async context.
pub fn embed_text_sync(text: &str) -> Result<Vec<f32>> {
    let model = init_model()?;
    let vecs = model.lock().map_err(|e| anyhow!("lock: {}", e))?.embed([text], None)?;
    let v = vecs.into_iter().next().ok_or_else(|| anyhow!("empty embed result"))?;
    Ok(v)
}

/// Embed multiple texts. Blocks; call from spawn_blocking if in async context.
pub fn embed_texts_sync(texts: &[String]) -> Result<Vec<Vec<f32>>> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    let model = init_model()?;
    let slice: Vec<&str> = texts.iter().map(String::as_str).collect();
    let vecs = model.lock().map_err(|e| anyhow!("lock: {}", e))?.embed(slice, None)?;
    Ok(vecs)
}

/// Returns true if in-process embedding is available (feature enabled and model can be loaded).
#[allow(dead_code)]
pub fn available() -> bool {
    init_model().is_ok()
}

#[cfg(all(test, feature = "inprocess-embed"))]
mod tests {
    use super::*;

    #[test]
    fn test_embed_text_sync_shape() {
        match embed_text_sync("test") {
            Ok(v) => assert_eq!(v.len(), 384, "all-MiniLM-L6-v2 dimension"),
            Err(_) => {} // skip when model not available (e.g. CI without cache)
        }
    }
}
