//! Phase 2 sampling gate — deterministic per-cycle live/dry-run decision.
//!
//! ## Determinism guarantee
//!
//! The decision uses `FNV-1a` of the raw `cycle_id` bytes, modulo 100, plus 1,
//! giving a roll in `[1, 100]`. Re-running with the same `cycle_id` always
//! produces the same roll. This prevents flip-flopping when the daemon restarts
//! mid-cycle.
//!
//! ## Phase 2 setup
//!
//! The installer plist sets `CHUMP_INTEGRATOR_SAMPLING_PCT=10`, meaning ~10% of
//! cycles go LIVE. Phase 3 raises it to 100 (default) after soak validation.
//!
//! ## Decision table
//!
//! | sampling_pct | roll result | decision |
//! |---|---|---|
//! | 100 | any | live |
//! | 0 | any | dry_run |
//! | 10 | roll ≤ 10 | live |
//! | 10 | roll > 10 | dry_run |

/// The sampling decision for a cycle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SamplingDecision {
    Live,
    DryRun,
}

impl SamplingDecision {
    pub fn as_str(&self) -> &'static str {
        match self {
            SamplingDecision::Live => "live",
            SamplingDecision::DryRun => "dry_run",
        }
    }

    pub fn is_live(&self) -> bool {
        *self == SamplingDecision::Live
    }
}

/// Compute the deterministic roll for a `cycle_id` string.
///
/// Uses FNV-1a (64-bit) which is `no_std`-compatible and has no external
/// dependency — consistent with the rest of the crate.
///
/// Returns a value in `[1, 100]`.
pub fn cycle_roll(cycle_id: &str) -> u8 {
    let hash = fnv1a_64(cycle_id.as_bytes());
    // Clamp to [1, 100]: (hash % 100) gives [0, 99]; +1 gives [1, 100].
    ((hash % 100) + 1) as u8
}

/// Decide whether a cycle runs LIVE or stays DRY-RUN.
///
/// - `sampling_pct = 100` → always live.
/// - `sampling_pct = 0`   → always dry_run.
/// - Otherwise: live iff `cycle_roll(cycle_id) <= sampling_pct`.
pub fn sampling_decision(cycle_id: &str, sampling_pct: u8) -> (SamplingDecision, u8) {
    let roll = cycle_roll(cycle_id);
    let decision = if roll <= sampling_pct {
        SamplingDecision::Live
    } else {
        SamplingDecision::DryRun
    };
    (decision, roll)
}

// ── FNV-1a 64-bit ─────────────────────────────────────────────────────────────

const FNV_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

fn fnv1a_64(bytes: &[u8]) -> u64 {
    let mut hash = FNV_OFFSET_BASIS;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    hash
}

// ── unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Same cycle_id must always produce the same roll (determinism).
    #[test]
    fn test_deterministic_same_cycle_same_roll() {
        let id = "abc12345";
        let roll_a = cycle_roll(id);
        let roll_b = cycle_roll(id);
        assert_eq!(
            roll_a, roll_b,
            "roll must be deterministic for the same cycle_id"
        );
    }

    /// Different cycle_ids should (in practice) produce different rolls.
    #[test]
    fn test_different_cycles_differ() {
        let roll_a = cycle_roll("aaaaaaaa");
        let roll_b = cycle_roll("bbbbbbbb");
        // Not guaranteed, but FNV-1a distributes well enough that these
        // particular fixed values must differ.
        assert_ne!(roll_a, roll_b, "these specific ids must hash differently");
    }

    /// sampling_pct = 100 → always live, regardless of cycle_id.
    #[test]
    fn test_100_pct_always_live() {
        for i in 0..200u32 {
            let id = format!("cycle-{i:08x}");
            let (decision, _roll) = sampling_decision(&id, 100);
            assert_eq!(
                decision,
                SamplingDecision::Live,
                "sampling_pct=100 must always be Live (id={id})"
            );
        }
    }

    /// sampling_pct = 0 → always dry_run, regardless of cycle_id.
    #[test]
    fn test_0_pct_always_dry_run() {
        for i in 0..200u32 {
            let id = format!("cycle-{i:08x}");
            let (decision, _roll) = sampling_decision(&id, 0);
            assert_eq!(
                decision,
                SamplingDecision::DryRun,
                "sampling_pct=0 must always be DryRun (id={id})"
            );
        }
    }

    /// sampling_pct = 10 → approximately 10% live across 1000 cycles.
    ///
    /// The FNV-1a hash distributes well; we allow ±5% tolerance (5-15%).
    #[test]
    fn test_10_pct_monte_carlo() {
        let live_count = (0..1000u32)
            .filter(|&i| {
                let id = format!("mc-cycle-{i:08x}");
                let (decision, _) = sampling_decision(&id, 10);
                decision.is_live()
            })
            .count();

        // Expect 100 ± 50 (i.e. 5%–15% of 1000).
        assert!(
            (50..=150).contains(&live_count),
            "expected ~10% live (50-150/1000), got {live_count}"
        );
    }

    /// Roll is always in [1, 100].
    #[test]
    fn test_roll_range() {
        for i in 0..500u32 {
            let id = format!("range-{i:08x}");
            let roll = cycle_roll(&id);
            assert!(
                (1..=100).contains(&roll),
                "roll must be in [1, 100], got {roll} for id={id}"
            );
        }
    }
}
