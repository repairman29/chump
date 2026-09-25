//! EFFECTIVE-1681: generic honest-degradation handler (EFFECTIVE-370 slice).
//!
//! The anti-beast-mode.dev rule, applied generically: when a bucket (a
//! free/trial dependency — Supabase, an AI quota, a third-party API) dies or
//! hits its limit, the primary CTA must show a truthful card, never a dead
//! endpoint. This module is the reusable core: call [`degrade`] with a
//! [`BucketFailure`] signal and get back a [`DegradedCard`] — it never
//! panics and never represents an HTTP 5xx for the caller to surface.

use std::fmt;

/// The kind of bucket failure observed by the caller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BucketFailure {
    /// The bucket is reachable and healthy — no degradation needed.
    Healthy,
    /// The bucket is unreachable / erroring (dead endpoint, connection
    /// refused, DNS failure, etc.).
    Dead,
    /// The bucket is reachable but has exhausted its quota/credits.
    QuotaExhausted,
}

impl fmt::Display for BucketFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            BucketFailure::Healthy => "healthy",
            BucketFailure::Dead => "dead",
            BucketFailure::QuotaExhausted => "quota_exhausted",
        };
        write!(f, "{s}")
    }
}

/// A truthful, user-facing card describing the current state of a bucket.
///
/// This is the only thing a primary CTA is allowed to render when its
/// backing bucket is degraded — never a dead endpoint, never a panic, never
/// an HTTP 5xx.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DegradedCard {
    /// True when the bucket is fully healthy (i.e. no degradation).
    pub healthy: bool,
    /// Short, honest, user-facing copy (write-as-jeff register: plain,
    /// no corporate hedging, no fake apology).
    pub message: String,
    /// Whether the primary CTA should still be shown (possibly disabled)
    /// rather than removed outright.
    pub cta_visible: bool,
}

/// Bucket name is deliberately free-text so callers don't need a shared
/// enum registry — the message is generated generically from the failure
/// kind, not the bucket name, so no per-bucket wiring is required.
pub fn degrade(bucket_name: &str, signal: BucketFailure) -> DegradedCard {
    match signal {
        BucketFailure::Healthy => DegradedCard {
            healthy: true,
            message: format!("{bucket_name} is up."),
            cta_visible: true,
        },
        BucketFailure::Dead => DegradedCard {
            healthy: false,
            message: format!("{bucket_name} is napping right now — try again in a bit."),
            cta_visible: true,
        },
        BucketFailure::QuotaExhausted => DegradedCard {
            healthy: false,
            message: format!("{bucket_name} hit its limit for now — back soon."),
            cta_visible: true,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn happy_path_is_healthy_and_cta_visible() {
        let card = degrade("leaderboard", BucketFailure::Healthy);
        assert!(card.healthy);
        assert!(card.cta_visible);
        assert!(!card.message.is_empty());
    }

    #[test]
    fn bucket_dead_returns_truthful_card_not_dead_endpoint() {
        let card = degrade("leaderboard", BucketFailure::Dead);
        assert!(!card.healthy);
        assert!(
            card.cta_visible,
            "primary CTA must stay visible, not vanish"
        );
        assert!(card.message.contains("leaderboard"));
    }

    #[test]
    fn quota_exhausted_returns_truthful_card_not_dead_endpoint() {
        let card = degrade("ai-explain", BucketFailure::QuotaExhausted);
        assert!(!card.healthy);
        assert!(
            card.cta_visible,
            "primary CTA must stay visible, not vanish"
        );
        assert!(card.message.contains("ai-explain"));
    }

    #[test]
    fn never_produces_empty_message_for_any_signal() {
        for signal in [
            BucketFailure::Healthy,
            BucketFailure::Dead,
            BucketFailure::QuotaExhausted,
        ] {
            let card = degrade("bucket", signal);
            assert!(!card.message.trim().is_empty());
        }
    }
}
