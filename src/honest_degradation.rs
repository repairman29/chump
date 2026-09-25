//! Generic honest-degradation handler (EFFECTIVE-1681, EFFECTIVE-370 slice).
//!
//! The anti-beast-mode.dev rule, applied as a reusable primitive: when a
//! free/trial bucket a surface depends on dies or hits quota, the caller
//! gets back a truthful [`DegradationCard`] to render — never a dead
//! endpoint, never a panic, never an HTTP 5xx. Each lighthouse surface
//! (arcade, upshift, olive, ...) calls `handle_bucket_signal` at its
//! bucket-touching boundary instead of hand-rolling its own fallback copy.

use std::fmt;

/// The signal a bucket-touching call site reports when it can't serve the
/// happy path. `Healthy` is included so callers can route a single signal
/// value through `handle_bucket_signal` without a separate happy-path branch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BucketSignal {
    /// The bucket answered normally; no degradation needed.
    Healthy,
    /// The bucket is unreachable or erroring (down, timed out, DNS dead).
    BucketDead,
    /// The bucket answered but the caller is out of quota/credits.
    QuotaExhausted,
}

impl fmt::Display for BucketSignal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            BucketSignal::Healthy => "healthy",
            BucketSignal::BucketDead => "bucket_dead",
            BucketSignal::QuotaExhausted => "quota_exhausted",
        };
        f.write_str(s)
    }
}

/// A truthful state for the caller to render in place of the primary CTA.
/// `None` for `card` on the happy path means "render normally, no
/// degradation copy needed."
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DegradationCard {
    /// Short, honest, non-alarming status line (write-as-jeff register —
    /// no stack traces, no "error", no dead links).
    pub message: String,
    /// Whether the primary CTA should still be shown, disabled with this
    /// card as an explanation, rather than hidden or dead.
    pub cta_disabled: bool,
}

/// Outcome of a bucket call: either the happy path (caller proceeds
/// normally) or a truthful card to render instead of a dead endpoint.
///
/// This is intentionally infallible — there is no `Err` variant. A bucket
/// failure is *expected* input, not an exceptional one, so the primary CTA
/// always has something safe to render.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DegradationOutcome {
    Proceed,
    Degraded(DegradationCard),
}

/// Turn a bucket-failure signal into a truthful card instead of a dead
/// endpoint. Never panics, never returns an HTTP 5xx — every `BucketSignal`
/// variant maps to a defined, renderable outcome.
///
/// `surface_label` names the degraded capability in plain language (e.g.
/// "leaderboard", "AI explain", "Kroger sync") so the resulting copy reads
/// as specific rather than generic.
pub fn handle_bucket_signal(signal: BucketSignal, surface_label: &str) -> DegradationOutcome {
    match signal {
        BucketSignal::Healthy => DegradationOutcome::Proceed,
        BucketSignal::BucketDead => DegradationOutcome::Degraded(DegradationCard {
            message: format!("{surface_label} is napping right now — the rest still works."),
            cta_disabled: true,
        }),
        BucketSignal::QuotaExhausted => DegradationOutcome::Degraded(DegradationCard {
            message: format!("{surface_label} is out of credits for now — try again later."),
            cta_disabled: true,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn happy_path_proceeds_without_a_card() {
        let outcome = handle_bucket_signal(BucketSignal::Healthy, "leaderboard");
        assert_eq!(outcome, DegradationOutcome::Proceed);
    }

    #[test]
    fn bucket_dead_returns_a_truthful_card_not_a_dead_endpoint() {
        let outcome = handle_bucket_signal(BucketSignal::BucketDead, "leaderboard");
        match outcome {
            DegradationOutcome::Degraded(card) => {
                assert!(card.cta_disabled);
                assert!(!card.message.is_empty());
                assert!(card.message.contains("leaderboard"));
            }
            DegradationOutcome::Proceed => panic!("expected a degraded card for BucketDead"),
        }
    }

    #[test]
    fn quota_exhausted_returns_a_truthful_card_not_a_dead_endpoint() {
        let outcome = handle_bucket_signal(BucketSignal::QuotaExhausted, "AI explain");
        match outcome {
            DegradationOutcome::Degraded(card) => {
                assert!(card.cta_disabled);
                assert!(!card.message.is_empty());
                assert!(card.message.contains("AI explain"));
            }
            DegradationOutcome::Proceed => panic!("expected a degraded card for QuotaExhausted"),
        }
    }

    #[test]
    fn never_panics_across_every_signal_variant() {
        for signal in [
            BucketSignal::Healthy,
            BucketSignal::BucketDead,
            BucketSignal::QuotaExhausted,
        ] {
            let _ = handle_bucket_signal(signal, "surface");
        }
    }
}
