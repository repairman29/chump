//! INFRA-601 — Thompson vs UCB1 regret replay study.
//!
//! Reads `kind=cascade_decision` rows from ambient.jsonl (or generates a
//! synthetic benchmark when none are found) and replays both bandit strategies
//! over the same decision sequence. Cumulative regret per strategy and per
//! slot is written to stdout as JSON Lines and to
//! `docs/research/bandit-replay-2026-05.md` as a Markdown report.
//!
//! # Usage
//!
//! ```
//! bandit-replay [--log <path>] [--days <N>] [--seed <u64>] [--out <path>]
//! ```
//!
//! - `--log`  Path to ambient.jsonl. Defaults to `$CHUMP_AMBIENT_LOG` then
//!            `.chump-locks/ambient.jsonl` relative to repo root.
//! - `--days` Window: only rows whose `ts` is within the last N days.
//!            Default: 30.
//! - `--seed` RNG seed for Thompson sampling replay. Default: 42.
//! - `--out`  Output report path. Default: `docs/research/bandit-replay-2026-05.md`.

use rand::prelude::*;
use rand::rngs::StdRng;
use serde::Deserialize;
use std::collections::HashMap;
use std::io::{BufRead, Write as _};
use std::path::PathBuf;

// ────────────────────────────────────────────────────────────────────────────
// CLI
// ────────────────────────────────────────────────────────────────────────────

struct Cfg {
    log_path: PathBuf,
    days: u64,
    seed: u64,
    out_path: PathBuf,
}

impl Cfg {
    fn from_args() -> Self {
        let mut log_path: Option<PathBuf> =
            std::env::var("CHUMP_AMBIENT_LOG").ok().map(PathBuf::from);
        let mut days: u64 = 30;
        let mut seed: u64 = 42;
        let mut out_path: Option<PathBuf> = None;

        let args: Vec<String> = std::env::args().collect();
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--log" => {
                    i += 1;
                    log_path = Some(PathBuf::from(&args[i]));
                }
                "--days" => {
                    i += 1;
                    days = args[i].parse().unwrap_or(30);
                }
                "--seed" => {
                    i += 1;
                    seed = args[i].parse().unwrap_or(42);
                }
                "--out" => {
                    i += 1;
                    out_path = Some(PathBuf::from(&args[i]));
                }
                _ => {}
            }
            i += 1;
        }

        let repo_root = {
            let mut d = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
            // Walk up to find the repo root (contains .chump-locks or .git).
            for _ in 0..6 {
                if d.join(".git").exists() || d.join(".chump-locks").exists() {
                    break;
                }
                if let Some(p) = d.parent() {
                    d = p.to_path_buf();
                } else {
                    break;
                }
            }
            d
        };

        let log_path = log_path.unwrap_or_else(|| repo_root.join(".chump-locks/ambient.jsonl"));
        let out_path =
            out_path.unwrap_or_else(|| repo_root.join("docs/research/bandit-replay-2026-05.md"));

        Self {
            log_path,
            days,
            seed,
            out_path,
        }
    }
}

// ────────────────────────────────────────────────────────────────────────────
// Ambient event parsing
// ────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct AmbientRow {
    ts: Option<String>,
    kind: Option<String>,
    slot: Option<String>,
    reward: Option<f64>,
    success: Option<bool>,
    latency_s: Option<f64>,
}

#[derive(Debug, Clone)]
struct Decision {
    ts_epoch: i64,
    slot: String,
    reward: f64,
}

fn parse_decisions(path: &PathBuf, days: u64) -> Vec<Decision> {
    let cutoff = chrono::Utc::now() - chrono::Duration::days(days as i64);
    let cutoff_epoch = cutoff.timestamp();

    let f = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return vec![],
    };

    let mut out = vec![];
    for line in std::io::BufReader::new(f).lines().flatten() {
        let row: AmbientRow = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(_) => continue,
        };
        if row.kind.as_deref() != Some("cascade_decision") {
            continue;
        }
        let slot = match row.slot {
            Some(ref s) if !s.is_empty() => s.clone(),
            _ => continue,
        };
        // Parse timestamp.
        let ts_epoch = row
            .ts
            .as_deref()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|dt| dt.timestamp())
            .unwrap_or(0);
        if ts_epoch < cutoff_epoch {
            continue;
        }
        // Reward: explicit field → inferred from success → default 0.5.
        let reward = row
            .reward
            .or_else(|| row.success.map(|s| if s { 1.0 } else { 0.0 }))
            .unwrap_or(0.5)
            .clamp(0.0, 1.0);
        let _ = row.latency_s; // available for future reward composition
        out.push(Decision {
            ts_epoch,
            slot,
            reward,
        });
    }
    out.sort_by_key(|d| d.ts_epoch);
    out
}

// ────────────────────────────────────────────────────────────────────────────
// Synthetic benchmark (used when no real cascade_decision events exist)
// ────────────────────────────────────────────────────────────────────────────

// Slot names and their assumed true mean reward (from provider quality data).
// Based on docs/architecture/PROVIDER_CASCADE.md slot ordering and typical
// observed success rates.
const SYNTHETIC_ARMS: &[(&str, f64)] = &[
    ("local", 0.72),
    ("groq", 0.88),
    ("cerebras", 0.85),
    ("mistral", 0.80),
    ("openrouter", 0.76),
    ("gemini", 0.83),
    ("github", 0.74),
    ("nvidia", 0.78),
    ("sambanova", 0.70),
];

fn generate_synthetic(n: usize, seed: u64) -> Vec<Decision> {
    let mut rng = StdRng::seed_from_u64(seed ^ 0xDEAD_BEEF);
    let base_ts: i64 = chrono::Utc::now().timestamp() - (n as i64) * 60;

    (0..n)
        .map(|i| {
            // Round-robin arm selection for a fair synthetic dataset.
            let arm_idx = i % SYNTHETIC_ARMS.len();
            let (slot, p_success) = SYNTHETIC_ARMS[arm_idx];
            let reward: f64 = if rng.random::<f64>() < p_success {
                1.0
            } else {
                0.0
            };
            Decision {
                ts_epoch: base_ts + (i as i64) * 60,
                slot: slot.to_string(),
                reward,
            }
        })
        .collect()
}

// ────────────────────────────────────────────────────────────────────────────
// Bandit state
// ────────────────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct ArmState {
    successes: f64,
    failures: f64,
    total_reward: f64,
    count: u64,
}

impl Default for ArmState {
    fn default() -> Self {
        // Beta(1,1) = uniform prior.
        Self {
            successes: 1.0,
            failures: 1.0,
            total_reward: 0.0,
            count: 0,
        }
    }
}

impl ArmState {
    fn mean_reward(&self) -> f64 {
        if self.count == 0 {
            0.5
        } else {
            self.total_reward / self.count as f64
        }
    }

    fn update(&mut self, reward: f64) {
        self.count += 1;
        self.total_reward += reward;
        if reward > 0.5 {
            self.successes += 1.0;
        } else {
            self.failures += 1.0;
        }
    }
}

struct BanditState {
    arms: HashMap<String, ArmState>,
}

impl BanditState {
    fn new() -> Self {
        Self {
            arms: HashMap::new(),
        }
    }

    fn arm(&self, slot: &str) -> ArmState {
        self.arms.get(slot).cloned().unwrap_or_default()
    }

    fn update(&mut self, slot: &str, reward: f64) {
        self.arms
            .entry(slot.to_string())
            .or_default()
            .update(reward);
    }

    fn select_thompson(&self, candidates: &[&str], rng: &mut StdRng) -> String {
        candidates
            .iter()
            .map(|&slot| {
                let a = self.arm(slot);
                let sample = beta_sample(rng, a.successes, a.failures);
                (slot, sample)
            })
            .max_by(|x, y| x.1.partial_cmp(&y.1).unwrap())
            .map(|(s, _)| s.to_string())
            .unwrap_or_default()
    }

    fn select_ucb1(&self, candidates: &[&str]) -> String {
        let total: u64 = self.arms.values().map(|a| a.count).sum();
        candidates
            .iter()
            .map(|&slot| {
                let a = self.arm(slot);
                let bonus = if a.count == 0 {
                    f64::INFINITY
                } else {
                    (2.0 * (total.max(1) as f64).ln() / a.count as f64).sqrt()
                };
                (slot, a.mean_reward() + bonus)
            })
            .max_by(|x, y| x.1.partial_cmp(&y.1).unwrap())
            .map(|(s, _)| s.to_string())
            .unwrap_or_default()
    }
}

// ────────────────────────────────────────────────────────────────────────────
// Beta sampling (duplicated from provider_bandit to keep this binary standalone)
// ────────────────────────────────────────────────────────────────────────────

fn beta_sample(rng: &mut StdRng, a: f64, b: f64) -> f64 {
    let x = gamma_sample(rng, a.max(f64::EPSILON));
    let y = gamma_sample(rng, b.max(f64::EPSILON));
    let s = x + y;
    if s <= 0.0 {
        0.5
    } else {
        (x / s).clamp(0.0, 1.0)
    }
}

fn gamma_sample(rng: &mut StdRng, shape: f64) -> f64 {
    if shape < 1.0 {
        let u: f64 = rng.random_range(f64::EPSILON..1.0);
        return gamma_marsaglia(rng, shape + 1.0) * u.powf(1.0 / shape);
    }
    gamma_marsaglia(rng, shape)
}

fn gamma_marsaglia(rng: &mut StdRng, shape: f64) -> f64 {
    let d = shape - 1.0 / 3.0;
    let c = 1.0 / (9.0 * d).sqrt();
    loop {
        let x = box_muller(rng);
        let v_base = 1.0 + c * x;
        if v_base <= 0.0 {
            continue;
        }
        let v = v_base * v_base * v_base;
        let u: f64 = rng.random_range(f64::EPSILON..1.0);
        let x2 = x * x;
        if u < 1.0 - 0.0331 * x2 * x2 {
            return d * v;
        }
        if u.ln() < 0.5 * x2 + d * (1.0 - v + v.ln()) {
            return d * v;
        }
    }
}

fn box_muller(rng: &mut StdRng) -> f64 {
    let u1: f64 = rng.random_range(f64::EPSILON..1.0);
    let u2: f64 = rng.random::<f64>();
    (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
}

// ────────────────────────────────────────────────────────────────────────────
// Replay engine
// ────────────────────────────────────────────────────────────────────────────

#[derive(Debug)]
struct RegretPoint {
    t: usize,
    ts_epoch: i64,
    actual_slot: String,
    actual_reward: f64,
    thompson_pick: String,
    thompson_reward: f64,
    thompson_regret: f64,
    ucb1_pick: String,
    ucb1_reward: f64,
    ucb1_regret: f64,
    optimal_reward: f64,
}

/// The oracle reward for a slot at step t is the reward that actually happened
/// IF that slot had been picked. Since we only observe one outcome per step,
/// we use the actual reward as the oracle for the slot that was actually chosen,
/// and estimate all others from the running mean (counterfactual estimate).
fn replay(decisions: &[Decision], seed: u64) -> Vec<RegretPoint> {
    let mut thompson_state = BanditState::new();
    let mut ucb1_state = BanditState::new();
    let mut all_slots: Vec<&str> = vec![];

    // Collect all unique slots.
    for d in decisions {
        if !all_slots.contains(&d.slot.as_str()) {
            all_slots.push(d.slot.as_str());
        }
    }

    let mut rng = StdRng::seed_from_u64(seed);
    let mut points = vec![];
    let mut thompson_cumulative = 0.0_f64;
    let mut ucb1_cumulative = 0.0_f64;

    for (t, d) in decisions.iter().enumerate() {
        let candidates: Vec<&str> = all_slots.clone();

        let thompson_pick = thompson_state.select_thompson(&candidates, &mut rng);
        let ucb1_pick = ucb1_state.select_ucb1(&candidates);

        // Counterfactual reward: if the strategy picked the actual slot, use
        // actual reward; otherwise use the running mean for that slot as a
        // best-estimate counterfactual.
        let thompson_reward = if thompson_pick == d.slot {
            d.reward
        } else {
            thompson_state.arm(&thompson_pick).mean_reward()
        };
        let ucb1_reward = if ucb1_pick == d.slot {
            d.reward
        } else {
            ucb1_state.arm(&ucb1_pick).mean_reward()
        };

        // Oracle: best known mean across all arms at this timestep.
        let optimal_reward = all_slots
            .iter()
            .map(|&s| {
                if s == d.slot {
                    d.reward
                } else {
                    thompson_state
                        .arm(s)
                        .mean_reward()
                        .max(ucb1_state.arm(s).mean_reward())
                }
            })
            .fold(f64::NEG_INFINITY, f64::max);

        let thompson_regret = (optimal_reward - thompson_reward).max(0.0);
        let ucb1_regret = (optimal_reward - ucb1_reward).max(0.0);
        thompson_cumulative += thompson_regret;
        ucb1_cumulative += ucb1_regret;

        // Update both states with the actual outcome for the actual slot.
        thompson_state.update(&d.slot, d.reward);
        ucb1_state.update(&d.slot, d.reward);

        points.push(RegretPoint {
            t: t + 1,
            ts_epoch: d.ts_epoch,
            actual_slot: d.slot.clone(),
            actual_reward: d.reward,
            thompson_pick,
            thompson_reward,
            thompson_regret: thompson_cumulative,
            ucb1_pick,
            ucb1_reward,
            ucb1_regret: ucb1_cumulative,
            optimal_reward,
        });
    }

    points
}

// ────────────────────────────────────────────────────────────────────────────
// Per-slot breakdown
// ────────────────────────────────────────────────────────────────────────────

struct SlotStats {
    thompson_picks: u64,
    ucb1_picks: u64,
    actual_picks: u64,
    total_reward: f64,
}

impl Default for SlotStats {
    fn default() -> Self {
        Self {
            thompson_picks: 0,
            ucb1_picks: 0,
            actual_picks: 0,
            total_reward: 0.0,
        }
    }
}

fn slot_breakdown(decisions: &[Decision], points: &[RegretPoint]) -> HashMap<String, SlotStats> {
    let mut map: HashMap<String, SlotStats> = HashMap::new();
    for (d, p) in decisions.iter().zip(points.iter()) {
        let s = map.entry(d.slot.clone()).or_default();
        s.actual_picks += 1;
        s.total_reward += d.reward;
        map.entry(p.thompson_pick.clone())
            .or_default()
            .thompson_picks += 1;
        map.entry(p.ucb1_pick.clone()).or_default().ucb1_picks += 1;
    }
    map
}

// ────────────────────────────────────────────────────────────────────────────
// Markdown report
// ────────────────────────────────────────────────────────────────────────────

fn write_report(
    out_path: &PathBuf,
    points: &[RegretPoint],
    decisions: &[Decision],
    synthetic: bool,
    days: u64,
    seed: u64,
) -> std::io::Result<()> {
    if let Some(parent) = out_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let n = points.len();
    let final_thompson = points.last().map(|p| p.thompson_regret).unwrap_or(0.0);
    let final_ucb1 = points.last().map(|p| p.ucb1_regret).unwrap_or(0.0);

    let winner = if final_thompson < final_ucb1 {
        "Thompson Sampling"
    } else if final_ucb1 < final_thompson {
        "UCB1"
    } else {
        "tied"
    };

    let breakdown = slot_breakdown(decisions, points);
    let mut slots: Vec<&String> = breakdown.keys().collect();
    slots.sort();

    // Sample regret curve (every 10th point or all if ≤ 100).
    let stride = if n > 100 { n / 20 } else { 1 };

    let data_label = if synthetic {
        format!("synthetic benchmark ({n} decisions, seed={seed}, round-robin arm exposure)")
    } else {
        format!("ambient.jsonl `kind=cascade_decision` rows from last {days} days ({n} decisions)")
    };

    let ts_now = chrono::Utc::now().format("%Y-%m-%d").to_string();

    let mut buf = String::new();

    buf.push_str(&format!(
        r#"# Bandit Replay Study — Thompson vs UCB1

**Generated:** {ts_now}
**Gap:** INFRA-601
**Baseline:** EVAL-101 (preregistration forthcoming — scope-up to P0 pending per ROADMAP.md)
**Data:** {data_label}
**RNG seed:** {seed}

---

## Summary

| Strategy | Cumulative Regret (T={n}) |
|---|---|
| Thompson Sampling | {final_thompson:.3} |
| UCB1 | {final_ucb1:.3} |
| **Winner** | **{winner}** |

---

## Methodology

This study replays {n} cascade slot decisions under two bandit policies:

- **Thompson Sampling** — maintains Beta(α,β) posterior per arm; samples θ̂ ∼ Beta(α,β)
  at each step and picks the arm with highest sample. Naturally explores high-uncertainty arms.
- **UCB1** — picks arm with highest `mean + √(2 ln N / n)`. Deterministic given history;
  more aggressive exploration of infrequently-tried arms early, then converges.

**Regret definition:** At each timestep t, regret = max_arm(oracle_reward_t) − reward(chosen_arm_t).
Cumulative regret = Σ regret(1..t). Lower is better.

**Counterfactual reward:** When a strategy picks an arm that was not the actual arm pulled,
the counterfactual reward is the running mean for that arm (best-estimate from observed history).
This is a conservative estimate that slightly underestimates both strategies' true performance.

{synthetic_note}
---

## Cumulative Regret Curve

| t | Thompson regret | UCB1 regret |
|---|---|---|
"#,
        synthetic_note = if synthetic {
            "**Note:** No `kind=cascade_decision` events found in ambient.jsonl. Results use a \
             synthetic benchmark: 9 slots (local, groq, cerebras, mistral, openrouter, gemini, \
             github, nvidia, sambanova) with reward probabilities drawn from documented provider \
             quality estimates. The synthetic dataset uses round-robin exposure to ensure all arms \
             are observed before either strategy commits to a preference.\n\n"
        } else {
            ""
        }
    ));

    for p in points.iter().step_by(stride) {
        buf.push_str(&format!(
            "| {} | {:.3} | {:.3} |\n",
            p.t, p.thompson_regret, p.ucb1_regret
        ));
    }
    // Always include the last point.
    if let Some(last) = points.last() {
        if n % stride != 0 {
            buf.push_str(&format!(
                "| {} | {:.3} | {:.3} |\n",
                last.t, last.thompson_regret, last.ucb1_regret
            ));
        }
    }

    buf.push_str(
        r#"
---

## Per-Slot Selection Distribution

| Slot | Actual picks | Thompson picks | UCB1 picks | Mean reward |
|---|---|---|---|---|
"#,
    );

    for slot in &slots {
        let s = &breakdown[*slot];
        let mean = if s.actual_picks > 0 {
            s.total_reward / s.actual_picks as f64
        } else {
            0.0
        };
        buf.push_str(&format!(
            "| {} | {} | {} | {} | {:.3} |\n",
            slot, s.actual_picks, s.thompson_picks, s.ucb1_picks, mean
        ));
    }

    buf.push_str(&format!(
        r#"
---

## Interpretation

{interpretation}

---

## Next Steps

1. **File EVAL-101** as a concrete preregistration fixture (scope-up to P0 per ROADMAP.md).
   EVAL-101 should specify: arm set, reward function, N, evaluation window, and the
   significance threshold for declaring a winner.
2. **Emit `cascade_decision` events** from `provider_cascade.rs` so future replays use
   real rather than synthetic data. Suggested schema:
   ```json
   {{"ts":"...","kind":"cascade_decision","slot":"groq","success":true,"latency_s":0.42,"reward":0.9}}
   ```
3. **Re-run after 7 days** of real cascade traffic to validate synthetic conclusions hold
   on production distributions.
4. **Contextual bandit**: if slot quality correlates with task type (code vs chat vs long-context),
   a linear contextual bandit over task-feature embeddings may further reduce regret.

---

*Report generated by `src/bin/bandit-replay.rs` (INFRA-601).*
"#,
        interpretation = if final_thompson < final_ucb1 {
            format!(
                "Thompson Sampling achieves lower cumulative regret ({final_thompson:.3}) than \
                 UCB1 ({final_ucb1:.3}), a difference of {diff:.3} over {n} decisions \
                 ({pct:.1}% improvement). This is consistent with theoretical expectations: \
                 Thompson naturally adapts its exploration rate to posterior uncertainty, while \
                 UCB1's √(ln N / n) bonus can over-explore well-characterised arms at large N. \
                 **Recommendation:** retain Thompson Sampling as the default bandit strategy.",
                diff = final_ucb1 - final_thompson,
                pct = (final_ucb1 - final_thompson) / final_ucb1 * 100.0
            )
        } else if final_ucb1 < final_thompson {
            format!(
                "UCB1 achieves lower cumulative regret ({final_ucb1:.3}) than Thompson \
                 Sampling ({final_thompson:.3}), a difference of {diff:.3} over {n} decisions \
                 ({pct:.1}% improvement). UCB1's deterministic exploration bonus may suit this \
                 particular reward distribution better. **Recommendation:** A/B test UCB1 vs \
                 Thompson on live traffic before switching the default.",
                diff = final_thompson - final_ucb1,
                pct = (final_thompson - final_ucb1) / final_thompson * 100.0
            )
        } else {
            format!(
                "Thompson Sampling and UCB1 achieve equal cumulative regret ({final_thompson:.3}) \
                 over {n} decisions. Both strategies are equivalent on this dataset. \
                 **Recommendation:** retain Thompson Sampling as the default (it is stochastic \
                 and harder to game/predict)."
            )
        }
    ));

    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(out_path)?;
    f.write_all(buf.as_bytes())?;
    Ok(())
}

// ────────────────────────────────────────────────────────────────────────────
// JSONL emit to stdout
// ────────────────────────────────────────────────────────────────────────────

fn emit_jsonl(points: &[RegretPoint]) {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    for p in points {
        let line = serde_json::json!({
            "t": p.t,
            "ts": p.ts_epoch,
            "actual_slot": p.actual_slot,
            "actual_reward": p.actual_reward,
            "thompson_pick": p.thompson_pick,
            "thompson_reward": p.thompson_reward,
            "thompson_cumulative_regret": p.thompson_regret,
            "ucb1_pick": p.ucb1_pick,
            "ucb1_reward": p.ucb1_reward,
            "ucb1_cumulative_regret": p.ucb1_regret,
            "optimal_reward": p.optimal_reward,
        });
        let _ = writeln!(out, "{}", line);
    }
}

// ────────────────────────────────────────────────────────────────────────────
// main
// ────────────────────────────────────────────────────────────────────────────

fn main() {
    let cfg = Cfg::from_args();

    let (decisions, synthetic) = {
        let from_log = parse_decisions(&cfg.log_path, cfg.days);
        if from_log.is_empty() {
            eprintln!(
                "[bandit-replay] no cascade_decision events in {:?} (last {} days); \
                 using synthetic benchmark of 1000 decisions",
                cfg.log_path, cfg.days
            );
            (generate_synthetic(1000, cfg.seed), true)
        } else {
            eprintln!(
                "[bandit-replay] loaded {} cascade_decision events from {:?}",
                from_log.len(),
                cfg.log_path
            );
            (from_log, false)
        }
    };

    let points = replay(&decisions, cfg.seed);

    emit_jsonl(&points);

    match write_report(
        &cfg.out_path,
        &points,
        &decisions,
        synthetic,
        cfg.days,
        cfg.seed,
    ) {
        Ok(()) => eprintln!("[bandit-replay] report written to {:?}", cfg.out_path),
        Err(e) => eprintln!("[bandit-replay] failed to write report: {e}"),
    }
}

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthetic_generates_correct_count() {
        let d = generate_synthetic(1000, 42);
        assert_eq!(d.len(), 1000);
    }

    #[test]
    fn synthetic_covers_all_arms() {
        let d = generate_synthetic(1000, 42);
        let slots: std::collections::HashSet<_> = d.iter().map(|x| x.slot.as_str()).collect();
        assert_eq!(slots.len(), SYNTHETIC_ARMS.len());
    }

    #[test]
    fn replay_produces_nondecreasing_cumulative_regret() {
        let d = generate_synthetic(100, 7);
        let points = replay(&d, 7);
        assert_eq!(points.len(), 100);
        let mut prev_ts = 0.0_f64;
        let mut prev_ucb = 0.0_f64;
        for p in &points {
            assert!(p.thompson_regret >= prev_ts - 1e-9);
            assert!(p.ucb1_regret >= prev_ucb - 1e-9);
            prev_ts = p.thompson_regret;
            prev_ucb = p.ucb1_regret;
        }
    }

    #[test]
    fn replay_regret_is_bounded() {
        let d = generate_synthetic(200, 99);
        let points = replay(&d, 99);
        let last = points.last().unwrap();
        // Each step regret ≤ 1.0, so cumulative ≤ n.
        assert!(last.thompson_regret <= 200.0);
        assert!(last.ucb1_regret <= 200.0);
    }

    #[test]
    fn parse_decisions_tolerates_missing_file() {
        let p = PathBuf::from("/nonexistent/path/ambient.jsonl");
        let d = parse_decisions(&p, 30);
        assert!(d.is_empty());
    }

    #[test]
    fn parse_decisions_filters_by_kind() {
        use std::io::Write as _;
        let tmp = tempfile::NamedTempFile::new().unwrap();
        writeln!(
            tmp.as_file(),
            r#"{{"ts":"2026-05-06T12:00:00Z","kind":"cascade_decision","slot":"groq","reward":1.0}}"#
        )
        .unwrap();
        writeln!(
            tmp.as_file(),
            r#"{{"ts":"2026-05-06T12:01:00Z","kind":"cycle_end","slot":"groq","reward":1.0}}"#
        )
        .unwrap();
        let d = parse_decisions(&tmp.path().to_path_buf(), 365);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].slot, "groq");
    }

    #[test]
    fn write_report_creates_file() {
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("test-report.md");
        let d = generate_synthetic(50, 1);
        let points = replay(&d, 1);
        write_report(&out, &points, &d, true, 30, 1).unwrap();
        let content = std::fs::read_to_string(&out).unwrap();
        assert!(content.contains("Thompson"));
        assert!(content.contains("UCB1"));
        assert!(content.contains("INFRA-601"));
        assert!(content.contains("EVAL-101"));
    }
}
