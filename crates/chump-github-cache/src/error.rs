//! Error types for `chump-github-cache`.
//!
//! Phase 1 keeps the surface small: anything that can go wrong in the
//! reader-side cache helpers maps to one of these variants.

use thiserror::Error;

/// Errors returned by [`crate::GithubCache`] implementations.
#[derive(Debug, Error)]
pub enum CacheError {
    /// Underlying SQLite error (connect, query, decode).
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    /// JSON parsing error decoding `raw_payload_json` from a cached row.
    ///
    /// Phase 1 tolerates unknown fields (`serde` does not deny them) but
    /// fails fast on type mismatches in the typed-out subset.
    #[error("json decode error: {0}")]
    Json(#[from] serde_json::Error),

    /// IO error opening the DB file or its directory.
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    /// HMAC verification error in the webhook receiver path.
    ///
    /// Phase 1 uses this for both the signature mismatch case and the
    /// missing-secret case — the receiver returns 401 either way and the
    /// underlying reason is recorded via `tracing`.
    #[error("hmac verification failed: {0}")]
    HmacVerify(String),

    /// Unknown / malformed input from the caller (e.g. CLI arg parse).
    #[error("bad input: {0}")]
    BadInput(String),
}
