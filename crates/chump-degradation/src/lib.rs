//! EFFECTIVE-1681: generic honest-degradation handler (EFFECTIVE-370 slice).
//!
//! The anti-beast-mode.dev rule, applied as a reusable library function:
//! when a free/trial bucket dies or hits quota, the caller gets back a
//! truthful [`DegradedCard`] describing what still works, never a dead
//! endpoint or a panic/5xx.
//!
//! [`handle_bucket_failure`] never panics and never returns an HTTP 5xx
//! for a primary CTA — callers should render the returned card as-is.

use serde::{Deserialize, Serialize};

/// The signal a caller reports when a bucket-backed dependency stops working.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BucketSignal {
    /// The bucket is healthy — no degradation needed.
    Healthy,
    /// The bucket is unreachable/dead (network error, 5xx from upstream, dead hostname, etc.).
    BucketDead,
    /// The bucket responded but the caller's quota/credits are exhausted.
    QuotaExhausted,
}

/// A truthful, user-facing card describing the current state of a surface.
///
/// This is the only thing [`handle_bucket_failure`] returns — there is no
/// error variant, because a degraded-but-honest card *is* the success path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DegradedCard {
    /// Short, honest status line (e.g. "scores are napping").
    pub headline: String,
    /// One sentence of plain-language detail about what happened.
    pub detail: String,
    /// Whether the surface's primary CTA is still usable in this state.
    pub primary_cta_usable: bool,
    /// The signal that produced this card, for logging/telemetry.
    pub signal: BucketSignal,
}

/// Turn a [`BucketSignal`] into a truthful [`DegradedCard`].
///
/// `surface_name` is a short human label for the degraded surface (e.g.
/// `"leaderboard"`, `"AI-explain"`) used to compose the headline/detail
/// copy. This function is total: every variant of `BucketSignal` maps to
/// a card, it never panics, and it never signals an HTTP 5xx — the healthy
/// case simply returns a card whose primary CTA is usable.
pub fn handle_bucket_failure(signal: BucketSignal, surface_name: &str) -> DegradedCard {
    match signal {
        BucketSignal::Healthy => DegradedCard {
            headline: format!("{surface_name} is up"),
            detail: format!("{surface_name} is working normally."),
            primary_cta_usable: true,
            signal,
        },
        BucketSignal::BucketDead => DegradedCard {
            headline: format!("{surface_name} is napping"),
            detail: format!(
                "{surface_name} can't reach its backing service right now. The rest of this page still works."
            ),
            primary_cta_usable: false,
            signal,
        },
        BucketSignal::QuotaExhausted => DegradedCard {
            headline: format!("{surface_name} is out of credits"),
            detail: format!(
                "{surface_name} has used up its available quota for now. Try again later, or upgrade."
            ),
            primary_cta_usable: false,
            signal,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn happy_path_reports_usable_cta() {
        let card = handle_bucket_failure(BucketSignal::Healthy, "leaderboard");
        assert!(card.primary_cta_usable);
        assert_eq!(card.signal, BucketSignal::Healthy);
        assert!(!card.headline.is_empty());
    }

    #[test]
    fn bucket_dead_returns_truthful_card_not_a_panic() {
        let card = handle_bucket_failure(BucketSignal::BucketDead, "leaderboard");
        assert!(!card.primary_cta_usable);
        assert_eq!(card.signal, BucketSignal::BucketDead);
        assert!(card.headline.contains("leaderboard"));
        assert!(card.detail.contains("still works"));
    }

    #[test]
    fn quota_exhausted_returns_truthful_card() {
        let card = handle_bucket_failure(BucketSignal::QuotaExhausted, "AI-explain");
        assert!(!card.primary_cta_usable);
        assert_eq!(card.signal, BucketSignal::QuotaExhausted);
        assert!(card.headline.contains("AI-explain"));
        assert!(
            card.detail.to_lowercase().contains("quota")
                || card.detail.to_lowercase().contains("credits")
        );
    }

    #[test]
    fn never_panics_across_all_signals() {
        for signal in [
            BucketSignal::Healthy,
            BucketSignal::BucketDead,
            BucketSignal::QuotaExhausted,
        ] {
            let _card = handle_bucket_failure(signal, "");
        }
    }
}
