//! Multi-armed bandit for provider slot selection.
//!
//! Chump's [`provider_cascade`] has long used a hand-configured priority
//! order over provider slots (local → cloud-A → cloud-B → …). That order
//! assumes the operator knows which model is best for which query type.
//! On a real mixed workload that's rarely true: the 9B local model is
//! great for simple chat but bad at long-context tool work; the cloud
//! 14B is fast for code but expensive for trivial tasks. The optimal
//! pick is workload-dependent AND drifts over time.
//!
//! This module replaces (or augments) hand-configured priority with a
//! learned policy: a multi-armed bandit over slot names. Every turn,
//! the bandit recommends which slot to try; after the turn, the caller
//! feeds back a scalar reward in `[0, 1]` and the bandit updates its
//! estimate. Over a few dozen turns the cascade converges to the best
//! slot for the workload.
//!
//! # Strategies
//!
//! Two classical bandit algorithms, both implemented exactly as in the
//! bandit literature:
//!
//! - **Thompson Sampling** ([`BanditStrategy::ThompsonSampling`]):
//!   maintains a Beta(α, β) posterior per arm and samples from it at
//!   select time. Naturally balances exploration vs exploitation via
//!   posterior uncertainty. Default.
//! - **UCB1** ([`BanditStrategy::Ucb1`]): picks the arm with highest
//!   upper confidence bound `mean + sqrt(2 ln(N) / n)`. Deterministic
//!   given the same history — useful for reproducible evals.
//!
//! # Reward shape
//!
//! Callers compute a reward in `[0, 1]`. Suggested starting formula:
//!
//! ```text
//! reward = success_weight * (success ? 1.0 : 0.0)
//!        + latency_weight * (1.0 - min(1.0, latency_s / max_acceptable_s))
//!        + token_weight   * min(1.0, tokens_per_sec / nominal_tps)
//! ```
//!
//! For a first pass it's fine to just use `success ? 1.0 : 0.0`. The
//! bandit converges; the choice of reward function decides what it
//! converges *toward*.
//!
//! # Persistence
//!
//! In-memory only. Stats reset on process restart. A follow-up can
//! persist to `sessions/provider_bandit.db` if long-running learning
//! becomes important — for now the bootstrap cost is ~20 turns and
//! we cold-start every Chump process anyway.
//!
//! # Influences
//!
//! Mirrors the shape of `openjarvis::learning::bandit::BanditRouterPolicy`
//! (Stanford Scaling Intelligence Lab, Apache-2.0). Reimplementation,
//! not adaptation — ours is MIT.

use rand::prelude::*;
use rand::rng;
use std::collections::HashMap;
use std::sync::Mutex;

/// Bandit selection strategy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BanditStrategy {
    /// Thompson sampling over Beta(α, β) posteriors. Stochastic. Default.
    #[default]
    ThompsonSampling,
    /// Upper confidence bound (UCB1). Deterministic given history.
    Ucb1,
}

impl BanditStrategy {
    /// Parse from an env string. Unknown values default to Thompson.
    pub fn from_env_str(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "ucb1" | "ucb" => Self::Ucb1,
            "thompson" | "ts" | "thompson_sampling" => Self::ThompsonSampling,
            _ => Self::default(),
        }
    }
}

/// Per-arm sufficient statistics. `successes`/`failures` start at 1.0
/// (Beta(1,1) = uniform prior), so new arms get explored before they
/// accrue evidence.
#[derive(Debug, Clone)]
pub struct ArmStats {
    /// Pseudo-count of successes; starts at 1.0 for the uniform prior.
    pub successes: f64,
    /// Pseudo-count of failures; starts at 1.0 for the uniform prior.
    pub failures: f64,
    /// Sum of rewards observed (not just binary 0/1).
    pub total_reward: f64,
    /// Number of times this arm was pulled.
    pub count: u64,
}

impl Default for ArmStats {
    fn default() -> Self {
        Self {
            successes: 1.0,
            failures: 1.0,
            total_reward: 0.0,
            count: 0,
        }
    }
}

impl ArmStats {
    /// Empirical mean reward. 0.5 when never pulled (the uniform prior
    /// baseline). Used by UCB1.
    pub fn mean_reward(&self) -> f64 {
        if self.count == 0 {
            0.5
        } else {
            self.total_reward / self.count as f64
        }
    }
}

/// Bandit router over a fixed set of arm names (typically provider slot
/// names). Thread-safe via `std::sync::Mutex` — contention is very low in
/// practice since select/update happen once per agent turn.
pub struct BanditRouter {
    /// Arm names in a stable order — useful for display + when `UCB1`
    /// needs a tiebreak.
    arms: Vec<String>,
    stats: Mutex<HashMap<String, ArmStats>>,
    strategy: BanditStrategy,
}

impl BanditRouter {
    /// Construct with the arms the caller will route between. Empty `arms`
    /// is allowed but `select()` will return `None` until at least one
    /// arm is registered.
    pub fn new(arms: Vec<String>, strategy: BanditStrategy) -> Self {
        Self {
            arms,
            stats: Mutex::new(HashMap::new()),
            strategy,
        }
    }

    /// Add an arm post-construction. No-op if the arm already exists.
    pub fn register_arm(&mut self, name: String) {
        if !self.arms.iter().any(|a| a == &name) {
            self.arms.push(name);
        }
    }

    pub fn arms(&self) -> &[String] {
        &self.arms
    }

    pub fn strategy(&self) -> BanditStrategy {
        self.strategy
    }

    /// Select an arm to pull. Returns `None` if the router has no arms.
    /// Callers can restrict to a subset via [`select_from`].
    pub fn select(&self) -> Option<String> {
        if self.arms.is_empty() {
            return None;
        }
        self.select_from_internal(&self.arms)
    }

    /// Select from a caller-supplied candidate subset (e.g. "only slots
    /// that passed the rate-limit check"). If the subset is empty, falls
    /// back to the full arm list.
    pub fn select_from(&self, candidates: &[String]) -> Option<String> {
        if candidates.is_empty() {
            return self.select();
        }
        self.select_from_internal(candidates)
    }

    fn select_from_internal(&self, candidates: &[String]) -> Option<String> {
        let stats = self
            .stats
            .lock()
            .expect("provider_bandit stats lock poisoned");
        match self.strategy {
            BanditStrategy::ThompsonSampling => {
                let mut rng = rng();
                let mut best: Option<(&str, f64)> = None;
                for name in candidates {
                    let arm = stats.get(name).cloned().unwrap_or_default();
                    let sample = beta_sample(&mut rng, arm.successes, arm.failures);
                    if best.map(|(_, s)| sample > s).unwrap_or(true) {
                        best = Some((name.as_str(), sample));
                    }
                }
                best.map(|(n, _)| n.to_string())
            }
            BanditStrategy::Ucb1 => {
                let total: u64 = stats.values().map(|a| a.count).sum();
                // UCB1: arg max over i of (mean_i + sqrt(2 ln N / n_i))
                // Special case: any unpulled candidate wins (infinite bonus).
                let mut best: Option<(&str, f64)> = None;
                for name in candidates {
                    let arm = stats.get(name).cloned().unwrap_or_default();
                    let bonus = if arm.count == 0 {
                        f64::INFINITY
                    } else {
                        (2.0_f64 * (total.max(1) as f64).ln() / arm.count as f64).sqrt()
                    };
                    let score = arm.mean_reward() + bonus;
                    if best.map(|(_, s)| score > s).unwrap_or(true) {
                        best = Some((name.as_str(), score));
                    }
                }
                best.map(|(n, _)| n.to_string())
            }
        }
    }

    /// Feed back a reward in `[0, 1]` for an arm pull. Rewards outside
    /// the range are silently clamped — better than panicking on a
    /// caller bug in production.
    pub fn update(&self, arm: &str, reward: f64) {
        let reward = reward.clamp(0.0, 1.0);
        let mut stats = self
            .stats
            .lock()
            .expect("provider_bandit stats lock poisoned");
        let a = stats.entry(arm.to_string()).or_default();
        a.count += 1;
        a.total_reward += reward;
        // Update the Beta(α, β) posterior. reward > 0.5 counts as a
        // success, ≤ 0.5 as a failure — the binary update common in
        // contextual-bandit literature. (An alternative is a continuous
        // update: α += reward, β += 1 - reward. Equivalent in the limit;
        // binary converges faster on small samples.)
        if reward > 0.5 {
            a.successes += 1.0;
        } else {
            a.failures += 1.0;
        }
    }

    /// Inspect the current stats for all arms. Returns a snapshot
    /// (clone), so the caller doesn't hold the mutex.
    pub fn snapshot(&self) -> Vec<(String, ArmStats)> {
        let stats = self
            .stats
            .lock()
            .expect("provider_bandit stats lock poisoned");
        self.arms
            .iter()
            .map(|name| (name.clone(), stats.get(name).cloned().unwrap_or_default()))
            .collect()
    }

    /// Reset all arm stats (useful for eval runs). The arm list itself
    /// is preserved.
    pub fn reset(&self) {
        self.stats
            .lock()
            .expect("provider_bandit stats lock poisoned")
            .clear();
    }
}

/// Compose a reward in `[0, 1]` from (success, latency, tokens).
///
/// Default weights: success 0.5, latency 0.3, throughput 0.2.
/// `latency_budget_s` and `nominal_tps` are the scales at which the
/// latency and throughput terms saturate to 0 and 1 respectively.
/// Override via env:
///
/// - `CHUMP_BANDIT_W_SUCCESS` / `CHUMP_BANDIT_W_LATENCY` / `CHUMP_BANDIT_W_TPS`
/// - `CHUMP_BANDIT_LATENCY_BUDGET_S` (default 30)
/// - `CHUMP_BANDIT_NOMINAL_TPS` (default 20)
pub fn compose_reward(success: bool, latency_s: f64, tokens_per_sec: f64) -> f64 {
    let w_success = env_f64("CHUMP_BANDIT_W_SUCCESS", 0.5);
    let w_latency = env_f64("CHUMP_BANDIT_W_LATENCY", 0.3);
    let w_tps = env_f64("CHUMP_BANDIT_W_TPS", 0.2);
    let budget = env_f64("CHUMP_BANDIT_LATENCY_BUDGET_S", 30.0).max(1.0);
    let nominal = env_f64("CHUMP_BANDIT_NOMINAL_TPS", 20.0).max(1.0);

    let success_term = if success { 1.0 } else { 0.0 };
    let latency_term = (1.0 - (latency_s / budget).clamp(0.0, 1.0)).clamp(0.0, 1.0);
    let tps_term = (tokens_per_sec / nominal).clamp(0.0, 1.0);

    let total = w_success * success_term + w_latency * latency_term + w_tps * tps_term;
    total.clamp(0.0, 1.0)
}

fn env_f64(key: &str, default: f64) -> f64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.trim().parse::<f64>().ok())
        .filter(|v| v.is_finite())
        .unwrap_or(default)
}

// ────────────────────────────────────────────────────────────────────
// Beta sampling via two Gammas (Marsaglia-Tsang for α ≥ 1; Ahrens-
// Dieter-style scale trick for α < 1). Avoids a rand_distr dependency.
// ────────────────────────────────────────────────────────────────────

/// Sample from Beta(a, b). Both `a` and `b` must be > 0.
pub fn beta_sample<R: rand::Rng + ?Sized>(rng: &mut R, a: f64, b: f64) -> f64 {
    // Beta(a, b) = X / (X + Y) with X ~ Gamma(a, 1), Y ~ Gamma(b, 1).
    let x = gamma_sample(rng, a.max(f64::EPSILON));
    let y = gamma_sample(rng, b.max(f64::EPSILON));
    let s = x + y;
    if s <= 0.0 {
        0.5
    } else {
        (x / s).clamp(0.0, 1.0)
    }
}

/// Sample from Gamma(shape, 1). Uses Marsaglia-Tsang for shape ≥ 1 and
/// a scale trick for shape < 1 (G(k,1) with k = shape+1 then multiply
/// by U^{1/shape}).
fn gamma_sample<R: rand::Rng + ?Sized>(rng: &mut R, shape: f64) -> f64 {
    if shape < 1.0 {
        // Sample Gamma(shape+1, 1), multiply by U^(1/shape) — equivalent
        // to Gamma(shape, 1). Stable for small shapes.
        let u: f64 = rng.random_range(f64::EPSILON..1.0);
        return gamma_marsaglia_tsang(rng, shape + 1.0) * u.powf(1.0 / shape);
    }
    gamma_marsaglia_tsang(rng, shape)
}

/// Marsaglia-Tsang method for Gamma(shape, 1) with shape ≥ 1.
/// Reference: Marsaglia & Tsang, "A Simple Method for Generating Gamma
/// Variables", ACM TOMS, 2000.
fn gamma_marsaglia_tsang<R: rand::Rng + ?Sized>(rng: &mut R, shape: f64) -> f64 {
    let d = shape - 1.0 / 3.0;
    let c = 1.0 / (9.0 * d).sqrt();
    loop {
        let x: f64 = standard_normal(rng);
        let v_base = 1.0 + c * x;
        if v_base <= 0.0 {
            continue;
        }
        let v = v_base * v_base * v_base;
        let u: f64 = rng.random_range(f64::EPSILON..1.0);
        let x_sq = x * x;
        // Squeeze test, then full acceptance test.
        if u < 1.0 - 0.0331 * x_sq * x_sq {
            return d * v;
        }
        if u.ln() < 0.5 * x_sq + d * (1.0 - v + v.ln()) {
            return d * v;
        }
    }
}

/// Standard-normal sample via Box-Muller. A tiny helper so we don't
/// need `rand_distr`.
fn standard_normal<R: rand::Rng + ?Sized>(rng: &mut R) -> f64 {
    use std::f64::consts::TAU;
    let u1: f64 = rng.random_range(f64::EPSILON..1.0);
    let u2: f64 = rng.random::<f64>();
    (-2.0 * u1.ln()).sqrt() * (TAU * u2).cos()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    #[test]
    fn select_none_when_empty() {
        let router = BanditRouter::new(vec![], BanditStrategy::ThompsonSampling);
        assert!(router.select().is_none());
    }

    #[test]
    fn select_returns_registered_arm() {
        let router = BanditRouter::new(
            vec!["a".to_string(), "b".to_string()],
            BanditStrategy::ThompsonSampling,
        );
        let pick = router.select().unwrap();
        assert!(pick == "a" || pick == "b");
    }

    #[test]
    fn update_clamps_out_of_range_rewards() {
        let router = BanditRouter::new(vec!["a".to_string()], BanditStrategy::ThompsonSampling);
        router.update("a", 5.0); // clamped to 1.0 — counts as success
        router.update("a", -1.0); // clamped to 0.0 — counts as failure
        let snap = router.snapshot();
        let (_, stats) = &snap[0];
        // 1 success (reward clamped to 1.0) + 1 failure (clamped to 0.0)
        // plus the uniform priors (1.0 each), so 2.0 / 2.0 after two pulls.
        assert_eq!(stats.count, 2);
        assert!((stats.successes - 2.0).abs() < 1e-9);
        assert!((stats.failures - 2.0).abs() < 1e-9);
        assert!((stats.total_reward - 1.0).abs() < 1e-9);
    }

    /// Acceptance test: over many trials, Thompson sampling should
    /// converge on the arm with the higher reward probability.
    #[test]
    fn thompson_converges_on_best_arm() {
        let router = BanditRouter::new(
            vec!["bad".to_string(), "good".to_string()],
            BanditStrategy::ThompsonSampling,
        );
        let mut rng = StdRng::seed_from_u64(0xC0FFEE);
        // Warm up with 400 pulls — simulate a world where `good` pays
        // 0.8 on average and `bad` pays 0.2.
        for _ in 0..400 {
            let pick = router.select().unwrap();
            let reward = if pick == "good" {
                if rng.random::<f64>() < 0.8 {
                    1.0
                } else {
                    0.0
                }
            } else if rng.random::<f64>() < 0.2 {
                1.0
            } else {
                0.0
            };
            router.update(&pick, reward);
        }
        // After learning, sample 200 more picks. The `good` arm should
        // dominate by a wide margin.
        let mut good = 0;
        let mut bad = 0;
        for _ in 0..200 {
            let pick = router.select().unwrap();
            if pick == "good" {
                good += 1;
            } else {
                bad += 1;
            }
        }
        assert!(
            good > bad * 3,
            "thompson should heavily prefer the 0.8 arm; got good={} bad={}",
            good,
            bad
        );
    }

    /// UCB1 is deterministic given the same history; it should likewise
    /// converge on the better arm after enough exploration.
    #[test]
    fn ucb1_converges_on_best_arm() {
        let router = BanditRouter::new(
            vec!["bad".to_string(), "good".to_string()],
            BanditStrategy::Ucb1,
        );
        let mut rng = StdRng::seed_from_u64(0xFEEDFACE);
        for _ in 0..400 {
            let pick = router.select().unwrap();
            let reward = if pick == "good" {
                if rng.random::<f64>() < 0.8 {
                    1.0
                } else {
                    0.0
                }
            } else if rng.random::<f64>() < 0.2 {
                1.0
            } else {
                0.0
            };
            router.update(&pick, reward);
        }
        let snap = router.snapshot();
        let good_mean = snap
            .iter()
            .find(|(n, _)| n == "good")
            .unwrap()
            .1
            .mean_reward();
        let bad_mean = snap
            .iter()
            .find(|(n, _)| n == "bad")
            .unwrap()
            .1
            .mean_reward();
        // Both arms got explored; good should have noticeably higher mean.
        assert!(
            good_mean > bad_mean + 0.3,
            "ucb1 should identify the 0.8 arm; good_mean={} bad_mean={}",
            good_mean,
            bad_mean
        );
    }

    #[test]
    fn select_from_respects_subset() {
        let router = BanditRouter::new(
            vec!["a".to_string(), "b".to_string(), "c".to_string()],
            BanditStrategy::ThompsonSampling,
        );
        // Restrict selection to "b" and "c" only.
        for _ in 0..50 {
            let pick = router
                .select_from(&["b".to_string(), "c".to_string()])
                .unwrap();
            assert!(pick == "b" || pick == "c", "got {pick}");
        }
    }

    #[test]
    fn compose_reward_bounded() {
        // Happy path: success + fast latency + high throughput.
        let r = compose_reward(true, 1.0, 25.0);
        assert!((0.0..=1.0).contains(&r));
        // Pathological: failure + slow + low throughput.
        let r2 = compose_reward(false, 100.0, 0.1);
        assert!((0.0..0.1).contains(&r2));
    }

    #[test]
    fn beta_sample_in_unit_interval() {
        let mut rng = StdRng::seed_from_u64(42);
        for _ in 0..1000 {
            let s = beta_sample(&mut rng, 3.0, 7.0);
            assert!((0.0..=1.0).contains(&s), "beta sample out of [0,1]: {s}");
        }
    }

    #[test]
    fn bandit_strategy_from_env_str() {
        assert_eq!(
            BanditStrategy::from_env_str("thompson"),
            BanditStrategy::ThompsonSampling
        );
        assert_eq!(
            BanditStrategy::from_env_str("ts"),
            BanditStrategy::ThompsonSampling
        );
        assert_eq!(BanditStrategy::from_env_str("UCB1"), BanditStrategy::Ucb1);
        assert_eq!(BanditStrategy::from_env_str("ucb"), BanditStrategy::Ucb1);
        // Unknown → default (Thompson).
        assert_eq!(
            BanditStrategy::from_env_str("garbage"),
            BanditStrategy::ThompsonSampling
        );
    }
}
