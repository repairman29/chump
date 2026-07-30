//! Calibrated confidence score for machine-generated changes — the judgment
//! organ's scoring primitive (EFFECTIVE-331 / EFFECTIVE-332, WS1 piece 1).
//!
//! Lifted from code-roach's `confidenceCalculator` (portfolio harvest — take the
//! substrate, leave the platform): a weighted blend of independent signals,
//! sigmoid-normalized to `0.0..=1.0`, so the OS emits a *calibrated score* it can
//! act on (ship / iterate / hold) rather than a bare pass/fail boolean. The
//! motivating case is the RESCUE bench lap that reached the fix agent but
//! produced an honest no-change: the agent had no score to iterate against.
//!
//! This module is pure and standalone. Piece 2 (EFFECTIVE-331) feeds the
//! `pr_ac_coverage` coverage fraction in as the `coverage` signal.
//!
//! The public items have no non-test caller yet — piece 2 wires them into the
//! ac-coverage path — so `dead_code` is allowed at the module level until then.
#![allow(dead_code)]

/// Independent signals feeding the confidence blend. Each is normalized to
/// `0.0..=1.0`; an unknown signal defaults to `0.5` (maximally uncertain).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Signals {
    /// S — structural/coverage similarity, e.g. the fraction of a gap's
    /// acceptance-criteria bullets the diff covers (piece 2 feeds this in).
    pub coverage: f64,
    /// H — historical success rate for this class of change (0.5 when unknown).
    pub history: f64,
    /// T — temporal freshness of the supporting evidence (1.0 fresh → decays).
    pub recency: f64,
    /// M — optional model/self-assessed prediction (0.5 when absent).
    pub model: f64,
}

impl Default for Signals {
    /// Maximally-uncertain prior: every signal at 0.5.
    fn default() -> Self {
        Self {
            coverage: 0.5,
            history: 0.5,
            recency: 0.5,
            model: 0.5,
        }
    }
}

/// Per-domain tunable weights for the blend. Defaults match code-roach's
/// calibrated starting point (α .3 H, β .2 S, γ .1 T, δ .4 M).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Weights {
    pub history: f64,
    pub coverage: f64,
    pub recency: f64,
    pub model: f64,
}

impl Default for Weights {
    fn default() -> Self {
        Self {
            history: 0.3,
            coverage: 0.2,
            recency: 0.1,
            model: 0.4,
        }
    }
}

/// Logistic sigmoid centered at `center` with slope `gain`.
fn sigmoid(x: f64, center: f64, gain: f64) -> f64 {
    1.0 / (1.0 + (-gain * (x - center)).exp())
}

/// Blend `sig` under `w` into a calibrated confidence in `0.0..=1.0`.
///
/// The raw blend is the weight-normalized average of the signals (robust to
/// weights that don't sum to 1); the sigmoid then sharpens it around 0.5 so
/// middling evidence stays near 0.5 while strong evidence saturates.
pub fn confidence(sig: &Signals, w: &Weights) -> f64 {
    let wsum = (w.history + w.coverage + w.recency + w.model).max(f64::EPSILON);
    let raw = (w.history * sig.history
        + w.coverage * sig.coverage
        + w.recency * sig.recency
        + w.model * sig.model)
        / wsum;
    sigmoid(raw, 0.5, 6.0)
}

/// Confidence from the primary signal alone (coverage), with the other signals
/// at the uncertain prior (0.5) and default weights. Piece 2's first caller
/// (`pr_ac_coverage` → covered-bullet fraction) uses this. `coverage` is clamped
/// to `0.0..=1.0`.
pub fn confidence_from_coverage(coverage: f64) -> f64 {
    confidence(
        &Signals {
            coverage: coverage.clamp(0.0, 1.0),
            ..Signals::default()
        },
        &Weights::default(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64, eps: f64) -> bool {
        (a - b).abs() < eps
    }

    #[test]
    fn all_signals_high_is_confident() {
        let c = confidence(
            &Signals {
                coverage: 1.0,
                history: 1.0,
                recency: 1.0,
                model: 1.0,
            },
            &Weights::default(),
        );
        assert!(c > 0.9, "all-1 signals → high confidence, got {c}");
    }

    #[test]
    fn all_signals_low_is_unconfident() {
        let c = confidence(
            &Signals {
                coverage: 0.0,
                history: 0.0,
                recency: 0.0,
                model: 0.0,
            },
            &Weights::default(),
        );
        assert!(c < 0.1, "all-0 signals → low confidence, got {c}");
    }

    #[test]
    fn uncertain_prior_is_midpoint() {
        let c = confidence(&Signals::default(), &Weights::default());
        assert!(approx(c, 0.5, 0.01), "all-0.5 signals → ~0.5, got {c}");
    }

    #[test]
    fn confidence_is_monotonic_in_coverage() {
        let lo = confidence_from_coverage(0.2);
        let hi = confidence_from_coverage(0.8);
        assert!(hi > lo, "more coverage → more confidence: {lo} !< {hi}");
    }

    #[test]
    fn output_always_in_unit_interval() {
        for &v in &[0.0_f64, 0.5, 1.0, -5.0, 5.0] {
            let c = confidence_from_coverage(v);
            assert!(
                (0.0..=1.0).contains(&c),
                "score must be in 0..=1, got {c} for coverage {v}"
            );
        }
    }

    #[test]
    fn weights_are_configurable() {
        // A high-coverage / everything-else-uncertain case scores higher under
        // coverage-dominant weights than under the default blend.
        let sig = Signals {
            coverage: 1.0,
            ..Signals::default()
        };
        let default = confidence(&sig, &Weights::default());
        let cov_heavy = confidence(
            &sig,
            &Weights {
                coverage: 1.0,
                history: 0.0,
                recency: 0.0,
                model: 0.0,
            },
        );
        assert!(
            cov_heavy > default,
            "coverage-heavy weights raise a high-coverage score: {default} !< {cov_heavy}"
        );
    }
}
