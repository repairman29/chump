//! Failure-class taxonomy for mission execution errors.
//!
//! Distinguishes errors an orchestrator should retry ([`FailureClass::Transient`])
//! from errors it should not ([`FailureClass::Permanent`]), with an explicit
//! [`FailureClass::Unknown`] bucket for anything the mapper can't classify —
//! callers should treat `Unknown` as non-retryable-by-default (safer to
//! surface to a human than to retry-storm on a novel error shape).

use serde::{Deserialize, Serialize};

/// Whether a mission-execution failure is worth retrying.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureClass {
    /// Likely to succeed on retry (network blip, rate limit, timeout).
    Transient,
    /// Retrying will not help (validation error, auth failure, not-found).
    Permanent,
    /// Not enough signal to classify; treat as non-retryable-by-default.
    Unknown,
}

/// Classify an HTTP-style status code into a [`FailureClass`].
///
/// - 408, 429, and 5xx are [`FailureClass::Transient`] (timeout, rate limit,
///   server-side overload — all worth a retry with backoff).
/// - 4xx (other than 408/429) are [`FailureClass::Permanent`] (the request
///   itself is invalid; retrying without changing it will not help).
/// - Anything else falls back to [`FailureClass::Unknown`].
pub fn classify_status_code(status: u16) -> FailureClass {
    match status {
        408 | 429 => FailureClass::Transient,
        500..=599 => FailureClass::Transient,
        400..=499 => FailureClass::Permanent,
        _ => FailureClass::Unknown,
    }
}

/// Classify a lowercase error-message fragment into a [`FailureClass`].
///
/// Intended for error types that don't carry a structured status code
/// (e.g. a `std::io::Error` or a driver-specific error string). Matches on
/// common substrings for network timeouts and rate limits; falls back to
/// [`FailureClass::Unknown`] when nothing matches.
pub fn classify_error_message(message: &str) -> FailureClass {
    let lower = message.to_lowercase();
    let transient_markers = [
        "timeout",
        "timed out",
        "rate limit",
        "too many requests",
        "connection reset",
        "connection refused",
        "temporarily unavailable",
        "econnreset",
        "etimedout",
    ];
    let permanent_markers = [
        "validation",
        "invalid",
        "unauthorized",
        "forbidden",
        "not found",
        "bad request",
    ];
    if transient_markers.iter().any(|m| lower.contains(m)) {
        return FailureClass::Transient;
    }
    if permanent_markers.iter().any(|m| lower.contains(m)) {
        return FailureClass::Permanent;
    }
    FailureClass::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_timeout_status_is_transient() {
        assert_eq!(classify_status_code(408), FailureClass::Transient);
    }

    #[test]
    fn rate_limit_status_is_transient() {
        assert_eq!(classify_status_code(429), FailureClass::Transient);
    }

    #[test]
    fn server_error_status_is_transient() {
        assert_eq!(classify_status_code(500), FailureClass::Transient);
        assert_eq!(classify_status_code(503), FailureClass::Transient);
    }

    #[test]
    fn validation_4xx_status_is_permanent() {
        assert_eq!(classify_status_code(400), FailureClass::Permanent);
        assert_eq!(classify_status_code(422), FailureClass::Permanent);
    }

    #[test]
    fn unrecognized_status_is_unknown() {
        assert_eq!(classify_status_code(302), FailureClass::Unknown);
    }

    #[test]
    fn timeout_message_is_transient() {
        assert_eq!(
            classify_error_message("Connection timed out after 30s"),
            FailureClass::Transient
        );
    }

    #[test]
    fn rate_limit_message_is_transient() {
        assert_eq!(
            classify_error_message("429 Too Many Requests"),
            FailureClass::Transient
        );
    }

    #[test]
    fn validation_message_is_permanent() {
        assert_eq!(
            classify_error_message("Validation error: field 'id' is required"),
            FailureClass::Permanent
        );
    }

    #[test]
    fn unmatched_message_is_unknown() {
        assert_eq!(
            classify_error_message("something unexpected happened"),
            FailureClass::Unknown
        );
    }
}
