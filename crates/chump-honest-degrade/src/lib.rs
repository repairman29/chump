//! Generic honest-degradation handler (EFFECTIVE-370 slice).
//!
//! The anti-beast-mode.dev rule, applied: when a free/trial bucket dies or
//! hits quota, the caller gets a truthful state back, never a dead endpoint.
//! This crate is intentionally dependency-free so a lighthouse surface
//! (arcade, upshift, olive, ...) can vendor it directly.

use std::fmt;

/// The signal a caller reports when a bucket-backed feature can't serve a
/// normal response.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BucketFailure {
    /// The bucket (DB, API, service) is unreachable or erroring.
    Dead,
    /// The bucket is reachable but its quota/credits are exhausted.
    QuotaExhausted,
}

impl fmt::Display for BucketFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BucketFailure::Dead => write!(f, "dead"),
            BucketFailure::QuotaExhausted => write!(f, "quota_exhausted"),
        }
    }
}

/// A truthful, user-facing card describing the degraded state. Never an
/// error page, never a dead endpoint — the primary CTA always has somewhere
/// honest to land.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DegradedCard {
    /// Short, human copy explaining what's unavailable (write-as-jeff register).
    pub message: String,
    /// Which bucket signal produced this card.
    pub cause: BucketFailure,
    /// Whether the caller should retry later (true) or the condition is
    /// terminal for this session (false, e.g. quota reset is out of the
    /// user's control right now).
    pub retryable: bool,
}

/// Handle a bucket-failure signal and return a truthful card. This function
/// never panics and never represents an HTTP 5xx / dead endpoint — every
/// `BucketFailure` variant maps to a concrete, honest `DegradedCard`.
pub fn handle_bucket_failure(signal: BucketFailure) -> DegradedCard {
    match signal {
        BucketFailure::Dead => DegradedCard {
            message: "This is napping right now — the data source is down. Try again shortly."
                .to_string(),
            cause: signal,
            retryable: true,
        },
        BucketFailure::QuotaExhausted => DegradedCard {
            message:
                "You've used up the available credits for this. It'll refresh — nothing's broken."
                    .to_string(),
            cause: signal,
            retryable: false,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn happy_path_bucket_dead_returns_truthful_retryable_card() {
        let card = handle_bucket_failure(BucketFailure::Dead);
        assert_eq!(card.cause, BucketFailure::Dead);
        assert!(card.retryable);
        assert!(!card.message.is_empty());
    }

    #[test]
    fn bucket_dead_never_panics_and_never_looks_like_an_error_page() {
        let card = handle_bucket_failure(BucketFailure::Dead);
        assert!(!card.message.to_lowercase().contains("error"));
        assert!(!card.message.to_lowercase().contains("500"));
    }

    #[test]
    fn quota_exhausted_returns_truthful_non_retryable_card() {
        let card = handle_bucket_failure(BucketFailure::QuotaExhausted);
        assert_eq!(card.cause, BucketFailure::QuotaExhausted);
        assert!(!card.retryable);
        assert!(!card.message.is_empty());
    }

    #[test]
    fn display_impl_covers_every_variant() {
        assert_eq!(BucketFailure::Dead.to_string(), "dead");
        assert_eq!(BucketFailure::QuotaExhausted.to_string(), "quota_exhausted");
    }
}
