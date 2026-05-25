//! Typed error surface for the [`Broker`](crate::broker::Broker) trait.

use thiserror::Error;

/// Errors returned by [`Broker`](crate::broker::Broker) implementations.
///
/// The variants are intentionally narrow — Phase 1 only needs to
/// distinguish "wrong arguments / wrong shape" from "transport failure"
/// so callers can decide whether to retry. NATS-specific variants land
/// with the NatsBroker in a follow-up sub-gap.
#[derive(Debug, Error)]
pub enum BrokerError {
    /// Caller supplied an empty recipient for a send that needs one
    /// (e.g. WARN with no --to, where the legacy bash path would have
    /// written ambient-only).
    #[error("missing recipient for send (use a `to` field or call ambient emit instead)")]
    MissingRecipient,

    /// Caller supplied an unknown [`MessageLevel`](crate::broker::MessageLevel) string
    /// when parsing from the legacy bash positional argv (e.g. typo like "DOEN").
    #[error("invalid message level: {0}")]
    InvalidLevel(String),

    /// Underlying filesystem operation failed (FileBroker only).
    #[error("io failure: {0}")]
    IoFailure(#[from] std::io::Error),

    /// JSON serialization or parse failure.
    #[error("json failure: {0}")]
    JsonFailure(#[from] serde_json::Error),
}
