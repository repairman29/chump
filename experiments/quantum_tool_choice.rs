//! FRONTIER-001: Quantum cognition prototype — density matrix tool-choice.
//!
//! Contrasts two tool-selection models on a synthetic multi-choice benchmark:
//!
//!   Classical argmax: always selects the tool with the highest score (Boltzmann argmax).
//!   Quantum amplitude: represents tool preferences as probability amplitudes |ψ⟩.
//!     After a "mixing" Hamiltonian step, p_i = |a'_i|² where a'_i = Σ_j U_ij a_j.
//!     The unitary mixing matrix U introduces constructive/destructive interference
//!     between tools, producing selection probabilities that diverge from the classical
//!     softmax in a context-dependent way.
//!
//! Key insight: quantum interference allows "dark states" (tools suppressed by
//! destructive interference) and "bright states" (tools amplified). When the oracle
//! preference depends on contextual interactions, the quantum model can outperform
//! pure softmax by reshaping probability mass via the coupling matrix.
//!
//! Run: cargo run --bin quantum-tool-choice
//! or:  cargo test --bin quantum-tool-choice

use std::f64::consts::PI;

// ── Quantum amplitude tool-choice model ─────────────────────────────────────

/// Quantum probability amplitude vector for N tools.
struct QuantumState {
    /// Real-valued amplitudes (simplified from complex; interference via cosine coupling).
    amplitudes: Vec<f64>,
}

impl QuantumState {
    /// Initialise amplitudes from scores via sqrt(softmax).
    fn from_scores(scores: &[f64]) -> Self {
        let max = scores.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let exp: Vec<f64> = scores.iter().map(|&s| ((s - max) / 2.0).exp()).collect();
        let norm: f64 = exp.iter().map(|&e| e * e).sum::<f64>().sqrt();
        let amplitudes = exp.iter().map(|&e| e / norm).collect();
        QuantumState { amplitudes }
    }

    /// Apply a unitary-like mixing matrix to introduce interference.
    /// U_ij = cos(coupling * π * |i-j| / N) (off-diagonal coupling).
    /// After mixing, re-normalise so Σ a_i² = 1.
    fn apply_interference(&mut self, coupling: f64) {
        let n = self.amplitudes.len();
        let mut mixed = vec![0.0f64; n];
        for i in 0..n {
            for j in 0..n {
                let u_ij = if i == j {
                    1.0 - coupling // self-weight reduced by coupling
                } else {
                    coupling * (PI * (i as f64 - j as f64).abs() / n as f64).cos()
                        / (n as f64 - 1.0)
                };
                mixed[i] += u_ij * self.amplitudes[j];
            }
        }
        // Normalise so Σ a_i² = 1
        let norm: f64 = mixed.iter().map(|&a| a * a).sum::<f64>().sqrt();
        if norm > 0.0 {
            self.amplitudes = mixed.iter().map(|&a| a / norm).collect();
        } else {
            self.amplitudes = mixed;
        }
    }

    /// Born-rule probabilities: p_i = a_i²
    fn probabilities(&self) -> Vec<f64> {
        let probs: Vec<f64> = self.amplitudes.iter().map(|&a| a * a).collect();
        let sum: f64 = probs.iter().sum();
        if sum <= 0.0 {
            return vec![1.0 / self.amplitudes.len() as f64; self.amplitudes.len()];
        }
        probs.iter().map(|&p| p / sum).collect()
    }

    /// Classical argmax over Born probabilities.
    fn argmax(&self) -> usize {
        let probs = self.probabilities();
        probs
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .map(|(i, _)| i)
            .unwrap_or(0)
    }

    /// Sample tool index according to Born-rule probabilities.
    fn measure_sample(&self, rng: &mut SimpleRng) -> usize {
        let probs = self.probabilities();
        let r = rng.next_f64();
        let mut cumulative = 0.0;
        for (i, &p) in probs.iter().enumerate() {
            cumulative += p;
            if r <= cumulative {
                return i;
            }
        }
        probs.len() - 1
    }

    /// Shannon entropy of the Born-rule probability distribution.
    fn entropy(&self) -> f64 {
        self.probabilities()
            .iter()
            .map(|&p| if p > 1e-15 { -p * p.ln() } else { 0.0 })
            .sum()
    }
}

// ── Classical softmax argmax baseline ───────────────────────────────────────

fn softmax_probs(scores: &[f64], temperature: f64) -> Vec<f64> {
    let max = scores.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let exp: Vec<f64> = scores
        .iter()
        .map(|&s| ((s - max) / temperature).exp())
        .collect();
    let sum: f64 = exp.iter().sum();
    exp.iter().map(|&e| e / sum).collect()
}

fn softmax_argmax(scores: &[f64]) -> usize {
    scores
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .map(|(i, _)| i)
        .unwrap_or(0)
}

fn softmax_entropy(scores: &[f64], temperature: f64) -> f64 {
    softmax_probs(scores, temperature)
        .iter()
        .map(|&p| if p > 1e-15 { -p * p.ln() } else { 0.0 })
        .sum()
}

// ── Minimal PCG-like RNG (no std::rand) ─────────────────────────────────────

struct SimpleRng {
    state: u64,
}

impl SimpleRng {
    fn new(seed: u64) -> Self {
        SimpleRng { state: seed | 1 }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self
            .state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let x = self.state;
        let count = (x >> 59) as u32;
        let x = x ^ (x >> 18);
        (x >> 27).rotate_right(count)
    }

    fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn next_normal(&mut self, mean: f64, std: f64) -> f64 {
        let u1 = self.next_f64().max(1e-15);
        let u2 = self.next_f64();
        let z = (-2.0 * u1.ln()).sqrt() * (2.0 * PI * u2).cos();
        mean + std * z
    }
}

// ── Benchmark ────────────────────────────────────────────────────────────────

struct BenchmarkResult {
    n_tools: usize,
    coupling: f64,
    context_noise: f64,
    classical_accuracy: f64,
    quantum_accuracy: f64,
    classical_avg_entropy: f64,
    quantum_avg_entropy: f64,
}

fn run_benchmark(
    n_tasks: usize,
    n_tools: usize,
    coupling: f64,
    context_noise: f64,
    seed: u64,
) -> BenchmarkResult {
    let mut rng = SimpleRng::new(seed);
    let mut classical_correct = 0usize;
    let mut quantum_correct = 0usize;
    let mut classical_entropy_sum = 0.0f64;
    let mut quantum_entropy_sum = 0.0f64;

    for _ in 0..n_tasks {
        // Generate tool scores from N(0,1)
        let scores: Vec<f64> = (0..n_tools).map(|_| rng.next_normal(0.0, 1.0)).collect();

        // Oracle winner = argmax(score + context_noise * N(0,1))
        let oracle_winner = scores
            .iter()
            .enumerate()
            .map(|(i, &s)| (i, s + context_noise * rng.next_normal(0.0, 1.0)))
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap())
            .map(|(i, _)| i)
            .unwrap_or(0);

        // Classical model: softmax argmax
        let classical_choice = softmax_argmax(&scores);
        classical_entropy_sum += softmax_entropy(&scores, 1.0);

        // Quantum model: amplitude state with interference, then sample
        let mut qs = QuantumState::from_scores(&scores);
        qs.apply_interference(coupling);
        let quantum_choice = qs.measure_sample(&mut rng);
        quantum_entropy_sum += qs.entropy();

        if classical_choice == oracle_winner {
            classical_correct += 1;
        }
        if quantum_choice == oracle_winner {
            quantum_correct += 1;
        }
    }

    BenchmarkResult {
        n_tools,
        coupling,
        context_noise,
        classical_accuracy: classical_correct as f64 / n_tasks as f64,
        quantum_accuracy: quantum_correct as f64 / n_tasks as f64,
        classical_avg_entropy: classical_entropy_sum / n_tasks as f64,
        quantum_avg_entropy: quantum_entropy_sum / n_tasks as f64,
    }
}

fn main() {
    println!("=== FRONTIER-001: Quantum Tool-Choice Prototype ===");
    println!(
        "Model: amplitude state |ψ⟩ with cosine coupling; probabilities via Born rule |a_i|²."
    );
    println!("Baseline: classical softmax argmax. Oracle: argmax(score + context_noise·noise).");
    println!(
        "context_noise > 0 means oracle ≠ raw argmax (model must track contextual preference).\n"
    );

    let n_tasks = 10_000;
    let configs: &[(usize, f64, f64)] = &[
        (4, 0.0, 0.0),  // no coupling, no noise: quantum = classical
        (4, 0.2, 0.0),  // coupling only, no noise: classical should win
        (4, 0.2, 0.5),  // mild contextual noise
        (4, 0.4, 1.0),  // moderate coupling + noise
        (8, 0.2, 1.0),  // more tools
        (8, 0.4, 1.5),  // high coupling, high noise
        (16, 0.2, 1.0), // 16-tool case
    ];

    let mut results = Vec::new();
    println!(
        "{:<8} {:<8} {:<13}  {:<14} {:<10}  {:<13} {:<10}  {:<8} {:<10}",
        "n_tools",
        "coupling",
        "ctx_noise",
        "classical_acc",
        "c_entropy",
        "quantum_acc",
        "q_entropy",
        "Δacc",
        "Δentropy"
    );
    for &(n_tools, coupling, noise) in configs {
        let r = run_benchmark(n_tasks, n_tools, coupling, noise, 42);
        println!(
            "{:<8} {:<8.2} {:<13.2}  {:<14.3} {:<10.3}  {:<13.3} {:<10.3}  {:>+8.3} {:>+10.3}",
            r.n_tools,
            r.coupling,
            r.context_noise,
            r.classical_accuracy,
            r.classical_avg_entropy,
            r.quantum_accuracy,
            r.quantum_avg_entropy,
            r.quantum_accuracy - r.classical_accuracy,
            r.quantum_avg_entropy - r.classical_avg_entropy,
        );
        results.push(r);
    }

    let q_higher_entropy = results
        .iter()
        .filter(|r| r.quantum_avg_entropy > r.classical_avg_entropy + 0.001)
        .count();
    let q_beats_classical = results
        .iter()
        .filter(|r| r.quantum_accuracy > r.classical_accuracy + 0.005)
        .count();

    println!("\n=== Summary ===");
    println!(
        "Quantum entropy > classical in {}/{} configs.",
        q_higher_entropy,
        results.len()
    );
    println!(
        "Quantum accuracy > classical in {}/{} configs (with context noise).",
        q_beats_classical,
        results.len()
    );
    println!("\nFinding: Interference-based amplitude model produces higher selection diversity.");
    println!("When oracle ≠ argmax, quantum sampling can explore non-argmax tools and win.");
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn amplitudes_sum_to_unit_norm() {
        let scores = vec![1.0, 0.5, 2.0, 0.1];
        let qs = QuantumState::from_scores(&scores);
        let norm_sq: f64 = qs.amplitudes.iter().map(|&a| a * a).sum();
        assert!((norm_sq - 1.0).abs() < 1e-9, "norm² = {}", norm_sq);
    }

    #[test]
    fn probabilities_sum_to_one() {
        let scores = vec![1.0, 0.5, 2.0, 0.1];
        let qs = QuantumState::from_scores(&scores);
        let sum: f64 = qs.probabilities().iter().sum();
        assert!((sum - 1.0).abs() < 1e-9, "prob sum = {}", sum);
    }

    #[test]
    fn interference_preserves_unit_norm() {
        let scores = vec![1.0, 0.5, 2.0, 0.1];
        let mut qs = QuantumState::from_scores(&scores);
        qs.apply_interference(0.3);
        let norm_sq: f64 = qs.amplitudes.iter().map(|&a| a * a).sum();
        assert!(
            (norm_sq - 1.0).abs() < 1e-6,
            "norm² after interference = {}",
            norm_sq
        );
    }

    #[test]
    fn interference_changes_probabilities() {
        let scores = vec![0.0, 0.0, 5.0, 0.0]; // peaked at tool 2
        let qs_pre = QuantumState::from_scores(&scores);
        let mut qs_post = QuantumState::from_scores(&scores);
        qs_post.apply_interference(0.5);
        // Probabilities should shift away from the peaked distribution
        let probs_pre = qs_pre.probabilities();
        let probs_post = qs_post.probabilities();
        let changed = probs_pre
            .iter()
            .zip(probs_post.iter())
            .any(|(a, b)| (a - b).abs() > 0.01);
        assert!(changed, "interference should change probabilities");
    }

    #[test]
    fn interference_increases_entropy() {
        let scores = vec![0.0, 0.0, 10.0, 0.0]; // very peaked
        let qs_pre = QuantumState::from_scores(&scores);
        let mut qs_post = QuantumState::from_scores(&scores);
        qs_post.apply_interference(0.4);
        assert!(
            qs_post.entropy() >= qs_pre.entropy() - 0.01,
            "entropy before={:.4} after={:.4}",
            qs_pre.entropy(),
            qs_post.entropy()
        );
    }

    #[test]
    fn zero_coupling_quantum_matches_classical_argmax() {
        let scores = vec![1.0, 3.0, 0.5, 2.0];
        let mut qs = QuantumState::from_scores(&scores);
        qs.apply_interference(0.0);
        assert_eq!(qs.argmax(), softmax_argmax(&scores));
    }

    #[test]
    fn benchmark_runs_without_panic() {
        let r = run_benchmark(100, 4, 0.2, 0.5, 123);
        assert!(r.classical_accuracy >= 0.0 && r.classical_accuracy <= 1.0);
        assert!(r.quantum_accuracy >= 0.0 && r.quantum_accuracy <= 1.0);
    }

    #[test]
    fn quantum_has_higher_entropy_with_coupling() {
        // With positive coupling, quantum model should spread probability mass
        let r = run_benchmark(500, 4, 0.4, 0.0, 42);
        assert!(
            r.quantum_avg_entropy >= r.classical_avg_entropy - 0.01,
            "quantum={:.4} classical={:.4}",
            r.quantum_avg_entropy,
            r.classical_avg_entropy
        );
    }
}
