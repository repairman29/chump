//! COG-037 — Thompson-sampling self-learning router.
//!
//! Each routing arm — a [`crate::routing::Candidate`] identified by
//! `(backend, model, provider_pfx)` — has an unknown success probability θ.
//! We maintain a Beta(α, β) posterior per arm with a uniform Beta(1,1) prior:
//!
//!   α = successes + 1
//!   β = failures + 1
//!
//! To pick the next arm, sample θ̂_i ∼ Beta(α_i, β_i) for each candidate and
//! take the argmax. New arms (no rows yet) sample from the uniform prior, so
//! they explore freely; arms with lots of data have tight posteriors and
//! tend to win consistently when they're actually best. This is the standard
//! Thompson sampler — see Russo et al., "A Tutorial on Thompson Sampling".
//!
//! ## Why Beta via Gamma ratio
//!
//! `rand_distr` doesn't expose a `Beta` distribution directly, but
//! Beta(α, β) ≡ X / (X + Y) where X ∼ Gamma(α, 1) and Y ∼ Gamma(β, 1). This
//! is exact (no inverse-transform bias) and matches what `rand_distr` does
//! internally for its own Beta where it exposes one.
//!
//! ## Determinism
//!
//! Every entry point takes `&mut impl rand::Rng` so tests can pass a
//! seeded `StdRng` and assert exact orderings. Production callers pass
//! `rand::rng()` (the thread-local default in rand 0.10). Note: rand 0.10
//! folded the old `RngCore` trait into `Rng`; the bound here matches
//! `rand_distr::Distribution::sample`'s `R: Rng + ?Sized` requirement.

use crate::routing::Candidate;
use rand::Rng;
use rand_distr::{Distribution, Gamma};
use std::collections::HashMap;

/// Per-arm success/failure counters from the routing scoreboard.
///
/// These are loaded once per ranking (not per candidate) by
/// [`crate::dispatch::select_candidates_for_gap`] when the `cog_037` flag
/// is enabled. Empty stats (`successes = 0`, `failures = 0`) yield a uniform
/// Beta(1, 1) prior — same as a never-seen arm.
#[derive(Debug, Clone, Default)]
pub struct ArmStats {
    pub successes: u64,
    pub failures: u64,
}

impl ArmStats {
    /// α = successes + 1 (Beta(1, 1) uniform prior).
    pub fn alpha(&self) -> f64 {
        (self.successes as f64) + 1.0
    }

    /// β = failures + 1 (Beta(1, 1) uniform prior).
    pub fn beta(&self) -> f64 {
        (self.failures as f64) + 1.0
    }
}

/// Sample one draw θ̂ ∼ Beta(α, β) using the X / (X + Y) Gamma-ratio trick.
///
/// Returns a value in (0, 1). Defensive on degenerate inputs:
/// non-finite or non-positive `α`/`β` are clamped to a tiny positive constant
/// so we never panic on bad scoreboard data (per COG-037 spec). A zero-sum
/// X + Y (extraordinarily unlikely with α, β ≥ 1) returns 0.5.
pub fn sample_beta<R: Rng + ?Sized>(alpha: f64, beta: f64, rng: &mut R) -> f64 {
    // Defensive clamp. With Beta(1,1) priors α and β are always ≥ 1, but
    // never trust your inputs — a corrupted scoreboard row with NaN/inf
    // must not panic the dispatcher.
    let a = if alpha.is_finite() && alpha > 0.0 {
        alpha
    } else {
        1e-9
    };
    let b = if beta.is_finite() && beta > 0.0 {
        beta
    } else {
        1e-9
    };

    // Gamma::new returns Err only for shape <= 0; we just clamped above so
    // both branches succeed. The .ok() + unwrap_or_else fallback path is
    // defense-in-depth in case rand_distr's invariant changes — never panics.
    let x = Gamma::new(a, 1.0)
        .ok()
        .map(|g| g.sample(rng))
        .unwrap_or(0.5);
    let y = Gamma::new(b, 1.0)
        .ok()
        .map(|g| g.sample(rng))
        .unwrap_or(0.5);
    let denom = x + y;
    if denom.is_finite() && denom > 0.0 {
        x / denom
    } else {
        0.5
    }
}

/// Reorder `candidates` by Thompson-sampling argmax.
///
/// For each candidate, look up [`ArmStats`] keyed by
/// [`Candidate::signature`]. If absent, use a default Beta(1, 1) prior
/// (so brand-new arms are picked at random). Sample one θ̂ per arm and
/// sort the candidates by θ̂ DESCENDING — highest sample wins.
///
/// This is a **stable-by-original-order** ranking modulo the score: ties
/// (vanishingly unlikely from continuous Gammas) preserve the input order.
/// Empty input yields empty output without panic.
pub fn rank_by_thompson<R: Rng + ?Sized>(
    candidates: Vec<Candidate>,
    stats_by_signature: &HashMap<String, ArmStats>,
    rng: &mut R,
) -> Vec<Candidate> {
    if candidates.is_empty() {
        return candidates;
    }
    let mut scored: Vec<(f64, Candidate)> = candidates
        .into_iter()
        .map(|c| {
            let stats = stats_by_signature
                .get(&c.signature())
                .cloned()
                .unwrap_or_default();
            let theta = sample_beta(stats.alpha(), stats.beta(), rng);
            (theta, c)
        })
        .collect();
    // Sort by θ̂ descending. partial_cmp guards against any NaN from
    // pathological inputs; treat NaN as "smallest" (it sorts to the end).
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored.into_iter().map(|(_, c)| c).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dispatch::DispatchBackend;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    fn cand(backend: DispatchBackend, model: Option<&str>, prov: Option<&str>) -> Candidate {
        Candidate {
            backend,
            model: model.map(String::from),
            provider_pfx: prov.map(String::from),
            why: format!(
                "test:{}:{}:{}",
                backend.label(),
                model.unwrap_or("-"),
                prov.unwrap_or("-")
            ),
        }
    }

    #[test]
    fn sample_beta_returns_in_open_unit_interval() {
        let mut rng = StdRng::seed_from_u64(42);
        for (a, b) in [
            (1.0, 1.0),
            (5.0, 1.0),
            (1.0, 5.0),
            (0.5, 0.5),
            (200.0, 50.0),
        ] {
            for _ in 0..200 {
                let x = sample_beta(a, b, &mut rng);
                assert!(
                    x > 0.0 && x < 1.0,
                    "sample_beta({a}, {b}) = {x}, not in (0,1)"
                );
                assert!(x.is_finite(), "sample_beta returned non-finite value");
            }
        }
    }

    #[test]
    fn sample_beta_mean_approximates_alpha_over_alpha_plus_beta() {
        // Beta(α, β) has mean α/(α+β). Average 10k seeded draws and check
        // we land within 1.5% of the analytical mean for several shapes.
        let mut rng = StdRng::seed_from_u64(0xC06_037);
        for (a, b) in [(1.0, 1.0), (2.0, 5.0), (10.0, 3.0), (50.0, 50.0)] {
            let n = 10_000;
            let sum: f64 = (0..n).map(|_| sample_beta(a, b, &mut rng)).sum();
            let mean = sum / (n as f64);
            let expected = a / (a + b);
            let err = (mean - expected).abs();
            assert!(
                err < 0.015,
                "Beta({a}, {b}) sample mean {mean:.5} drifted from analytical {expected:.5} by {err:.5}"
            );
        }
    }

    #[test]
    fn sample_beta_does_not_panic_on_garbage_inputs() {
        let mut rng = StdRng::seed_from_u64(7);
        for (a, b) in [
            (0.0, 0.0),
            (-1.0, 1.0),
            (1.0, -1.0),
            (f64::NAN, 1.0),
            (1.0, f64::INFINITY),
        ] {
            let x = sample_beta(a, b, &mut rng);
            assert!(x.is_finite(), "garbage input {a}, {b} produced {x}");
            assert!((0.0..=1.0).contains(&x), "garbage input out of [0,1]: {x}");
        }
    }

    #[test]
    fn rank_by_thompson_empty_input_returns_empty() {
        let mut rng = StdRng::seed_from_u64(1);
        let out = rank_by_thompson(Vec::new(), &HashMap::new(), &mut rng);
        assert!(out.is_empty());
    }

    #[test]
    fn rank_by_thompson_empty_stats_is_permutation_of_input() {
        // No stats → all arms sample from Beta(1,1). Output must contain
        // exactly the input arms (no drops, no dupes), in some order.
        let mut rng = StdRng::seed_from_u64(2);
        let cands = vec![
            cand(DispatchBackend::ChumpLocal, Some("a"), Some("X")),
            cand(DispatchBackend::ChumpLocal, Some("b"), Some("Y")),
            cand(DispatchBackend::Claude, None, None),
        ];
        let signatures_in: Vec<String> = cands.iter().map(|c| c.signature()).collect();
        let out = rank_by_thompson(cands, &HashMap::new(), &mut rng);
        let signatures_out: Vec<String> = out.iter().map(|c| c.signature()).collect();
        assert_eq!(signatures_out.len(), signatures_in.len());
        for s in &signatures_in {
            assert!(
                signatures_out.contains(s),
                "input arm {s} missing from output: {signatures_out:?}"
            );
        }
    }

    #[test]
    fn rank_by_thompson_is_deterministic_with_seeded_rng() {
        let cands = || {
            vec![
                cand(DispatchBackend::ChumpLocal, Some("a"), Some("X")),
                cand(DispatchBackend::ChumpLocal, Some("b"), Some("Y")),
                cand(DispatchBackend::Claude, None, None),
            ]
        };
        let stats = HashMap::new();
        let mut rng1 = StdRng::seed_from_u64(0xDEADBEEF);
        let mut rng2 = StdRng::seed_from_u64(0xDEADBEEF);
        let r1 = rank_by_thompson(cands(), &stats, &mut rng1);
        let r2 = rank_by_thompson(cands(), &stats, &mut rng2);
        let s1: Vec<String> = r1.iter().map(|c| c.signature()).collect();
        let s2: Vec<String> = r2.iter().map(|c| c.signature()).collect();
        assert_eq!(s1, s2, "same seed must produce same ranking");
    }

    #[test]
    fn rank_by_thompson_skewed_evidence_picks_winner() {
        // Arm A: 100 successes, 0 failures → tight posterior near 1.
        // Arm B: 0 successes, 100 failures → tight posterior near 0.
        // Over many seeded trials, A should be ranked first ≥ 95% of the
        // time. (Spec target.)
        let arm_a = cand(DispatchBackend::ChumpLocal, Some("a"), Some("X"));
        let arm_b = cand(DispatchBackend::ChumpLocal, Some("b"), Some("Y"));
        let mut stats = HashMap::new();
        stats.insert(
            arm_a.signature(),
            ArmStats {
                successes: 100,
                failures: 0,
            },
        );
        stats.insert(
            arm_b.signature(),
            ArmStats {
                successes: 0,
                failures: 100,
            },
        );

        let trials = 10_000;
        let mut a_wins = 0usize;
        let mut rng = StdRng::seed_from_u64(0xC060_37AB);
        for _ in 0..trials {
            let ranked = rank_by_thompson(
                vec![arm_b.clone(), arm_a.clone()], // start with B first to defeat any tie-break-by-input bias
                &stats,
                &mut rng,
            );
            if ranked[0].signature() == arm_a.signature() {
                a_wins += 1;
            }
        }
        let win_rate = (a_wins as f64) / (trials as f64);
        assert!(
            win_rate >= 0.95,
            "expected arm A to win ≥95% of the time with skewed evidence; got {a_wins}/{trials} = {win_rate:.4}"
        );
    }

    #[test]
    fn arm_stats_alpha_beta_uses_uniform_prior() {
        let s = ArmStats::default();
        assert_eq!(s.alpha(), 1.0);
        assert_eq!(s.beta(), 1.0);
        let s = ArmStats {
            successes: 4,
            failures: 6,
        };
        assert_eq!(s.alpha(), 5.0);
        assert_eq!(s.beta(), 7.0);
    }
}
