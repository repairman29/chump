//! COG-046: real embedding-backed lesson retrieval.
//!
//! TF-IDF (COG-041) is bag-of-words: "auth" doesn't match "credentials,"
//! "fleet" doesn't match "dispatcher." Embedding models capture
//! semantic similarity that bag-of-words can't.
//!
//! Design:
//! - Local Ollama by default (`http://localhost:11434/api/embeddings`,
//!   model `nomic-embed-text`). No API cost, private.
//! - Best-effort: if Ollama is unreachable / model not pulled / network
//!   fails, return None and let the caller fall through to TF-IDF
//!   (COG-041) → recency-frequency (existing default). Never panic.
//! - In-memory cache per call; we don't persist (yet — that's a follow-up
//!   gap if the latency hurts at scale).
//!
//! Env knobs:
//!   CHUMP_LESSONS_EMBEDDING_URL    default http://localhost:11434/api/embeddings
//!   CHUMP_LESSONS_EMBEDDING_MODEL  default nomic-embed-text
//!   CHUMP_LESSONS_EMBEDDING_TIMEOUT_MS  default 5000
//!
//! Master enable: CHUMP_LESSONS_EMBEDDING=1
//!   When unset, the embedding path is skipped entirely (no Ollama call,
//!   no latency tax). Default OFF — this path is opt-in until validated
//!   via EVAL-099-style downstream eval.

// Implementation note: we shell out to `curl` rather than using
// `reqwest::blocking` because the workspace builds reqwest without the
// `blocking` feature, and threading an async runtime into the
// briefing.rs sync call path adds complexity for a single best-effort
// HTTP POST. `curl` is universally available on macOS + Linux.
use std::process::Command;

const DEFAULT_URL: &str = "http://localhost:11434/api/embeddings";
const DEFAULT_MODEL: &str = "nomic-embed-text";
const DEFAULT_TIMEOUT_MS: u64 = 5000;

/// Master flag — must be `1`/`true`/`on` for the embedding path to fire.
pub fn embedding_enabled() -> bool {
    matches!(
        std::env::var("CHUMP_LESSONS_EMBEDDING").as_deref(),
        Ok("1") | Ok("true") | Ok("on")
    )
}

/// Embed a single text via the configured embedding endpoint.
///
/// Returns `Some(vector)` on success, `None` on any failure (unreachable
/// endpoint, malformed response, timeout, model not pulled, etc.).
/// Caller is expected to fall through to a non-embedding path on None.
pub fn embed_text(text: &str) -> Option<Vec<f32>> {
    if text.trim().is_empty() {
        return None;
    }
    let url = std::env::var("CHUMP_LESSONS_EMBEDDING_URL").unwrap_or_else(|_| DEFAULT_URL.into());
    let model =
        std::env::var("CHUMP_LESSONS_EMBEDDING_MODEL").unwrap_or_else(|_| DEFAULT_MODEL.into());
    let timeout_ms: u64 = std::env::var("CHUMP_LESSONS_EMBEDDING_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_TIMEOUT_MS);
    let timeout_secs = ((timeout_ms as f64) / 1000.0).max(0.5);

    let body = serde_json::json!({
        "model": model,
        "prompt": text,
    })
    .to_string();

    let out = Command::new("curl")
        .args([
            "-sS",
            "--fail",
            "--max-time",
            &format!("{:.1}", timeout_secs),
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-d",
            &body,
            &url,
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let parsed: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    let arr = parsed.get("embedding")?.as_array()?;
    let mut vec = Vec::with_capacity(arr.len());
    for v in arr {
        let f = v.as_f64()? as f32;
        vec.push(f);
    }
    if vec.is_empty() {
        return None;
    }
    Some(vec)
}

/// Cosine similarity between two equal-length f32 vectors. Returns 0.0
/// for length mismatch or zero-norm inputs.
pub fn cosine_similarity_f32(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let mut dot = 0.0_f32;
    let mut na = 0.0_f32;
    let mut nb = 0.0_f32;
    for i in 0..a.len() {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    dot / (na.sqrt() * nb.sqrt())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cog046_cosine_orthogonal() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![0.0, 1.0, 0.0];
        assert!((cosine_similarity_f32(&a, &b)).abs() < 1e-6);
    }

    #[test]
    fn cog046_cosine_identical() {
        let a = vec![0.5, 0.5, 0.5, 0.5];
        let s = cosine_similarity_f32(&a, &a);
        assert!((s - 1.0).abs() < 1e-6, "expected 1.0, got {}", s);
    }

    #[test]
    fn cog046_cosine_length_mismatch_returns_zero() {
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![1.0, 2.0];
        assert_eq!(cosine_similarity_f32(&a, &b), 0.0);
    }

    #[test]
    fn cog046_cosine_zero_norm() {
        let a = vec![0.0, 0.0, 0.0];
        let b = vec![1.0, 2.0, 3.0];
        assert_eq!(cosine_similarity_f32(&a, &b), 0.0);
    }

    #[test]
    fn cog046_embedding_enabled_default_off() {
        std::env::remove_var("CHUMP_LESSONS_EMBEDDING");
        assert!(!embedding_enabled());
    }

    #[test]
    fn cog046_embedding_enabled_recognizes_truthy() {
        for v in ["1", "true", "on"] {
            std::env::set_var("CHUMP_LESSONS_EMBEDDING", v);
            assert!(embedding_enabled(), "expected enabled for {}", v);
        }
        std::env::remove_var("CHUMP_LESSONS_EMBEDDING");
    }

    #[test]
    fn cog046_embed_unreachable_url_returns_none() {
        // Point at a port nothing is listening on — must not panic.
        std::env::set_var(
            "CHUMP_LESSONS_EMBEDDING_URL",
            "http://127.0.0.1:1/embed-nope",
        );
        std::env::set_var("CHUMP_LESSONS_EMBEDDING_TIMEOUT_MS", "200");
        let v = embed_text("hello");
        assert!(v.is_none(), "expected None on unreachable endpoint");
        std::env::remove_var("CHUMP_LESSONS_EMBEDDING_URL");
        std::env::remove_var("CHUMP_LESSONS_EMBEDDING_TIMEOUT_MS");
    }

    #[test]
    fn cog046_embed_empty_text_returns_none() {
        assert!(embed_text("").is_none());
        assert!(embed_text("   ").is_none());
    }
}
