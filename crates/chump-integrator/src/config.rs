//! Configuration loaded from environment variables.
//!
//! All knobs have sensible defaults; none are required.

use std::time::Duration;

/// Runtime configuration for the integrator daemon.
#[derive(Debug, Clone)]
pub struct IntegratorConfig {
    /// How often to poll the NATS work-board (seconds). Default: 15.
    pub poll_interval: Duration,
    /// How long to wait between full integration cycles (minutes). Default: 30.
    pub cadence_min: u64,
    /// Minimum candidates required before a cycle fires. Default: 5.
    pub volume_threshold: usize,
    /// Max total estimated LOC across the batch. Default: 1500.
    pub loc_budget: usize,
    /// Hard cap on batch size. Default: 10.
    pub max_batch: usize,
    /// Preflight command timeout. Default: 480s.
    pub preflight_timeout: Duration,
    /// Dry-run mode (Phase 1 default: true). When true, stops after PREFLIGHT.
    pub dry_run: bool,
    /// Sampling percentage for live cycles (Phase 2 knob). Integer 0-100.
    ///
    /// After CLAIM, before SELECT, a deterministic hash of `cycle_id` is used
    /// to roll a value in [1..=100]. If `roll <= sampling_pct` the cycle runs
    /// LIVE (full lifecycle including SHIP); otherwise it stays DRY-RUN.
    ///
    /// Default: 100 (all cycles live when `dry_run = false`).
    /// Phase 2 installer sets this to 10 via the launchd plist env key
    /// `CHUMP_INTEGRATOR_SAMPLING_PCT`.
    ///
    /// CLI override: `--sampling-pct N` (env takes precedence over CLI).
    pub sampling_pct: u8,
}

impl Default for IntegratorConfig {
    fn default() -> Self {
        Self {
            poll_interval: Duration::from_secs(15),
            cadence_min: 30,
            volume_threshold: 5,
            loc_budget: 1500,
            max_batch: 10,
            preflight_timeout: Duration::from_secs(480),
            dry_run: true,
            sampling_pct: 100,
        }
    }
}

impl IntegratorConfig {
    /// Load from environment variables, falling back to defaults.
    pub fn from_env() -> Self {
        let poll_s = env_u64("CHUMP_INTEGRATOR_POLL_S", 15);
        let cadence_min = env_u64("CHUMP_INTEGRATOR_CADENCE_MIN", 30);
        let volume_threshold = env_usize("CHUMP_INTEGRATOR_VOLUME_THRESHOLD", 5);
        let loc_budget = env_usize("CHUMP_INTEGRATOR_LOC_BUDGET", 1500);
        let max_batch = env_usize("CHUMP_INTEGRATOR_MAX_BATCH", 10);
        let preflight_timeout_s = env_u64("CHUMP_INTEGRATOR_PREFLIGHT_TIMEOUT_S", 480);
        let dry_run = env_bool("CHUMP_INTEGRATOR_DRY_RUN", true);
        let sampling_pct = env_sampling_pct("CHUMP_INTEGRATOR_SAMPLING_PCT", 100);

        Self {
            poll_interval: Duration::from_secs(poll_s),
            cadence_min,
            volume_threshold,
            loc_budget,
            max_batch,
            preflight_timeout: Duration::from_secs(preflight_timeout_s),
            dry_run,
            sampling_pct,
        }
    }
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_bool(key: &str, default: bool) -> bool {
    match std::env::var(key).ok().as_deref() {
        Some("0") | Some("false") | Some("no") => false,
        Some("1") | Some("true") | Some("yes") => true,
        _ => default,
    }
}

/// Parse `CHUMP_INTEGRATOR_SAMPLING_PCT` as an integer clamped to [0, 100].
/// Invalid or missing values fall back to `default`.
fn env_sampling_pct(key: &str, default: u8) -> u8 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<u8>().ok())
        .map(|v| v.min(100))
        .unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn test_defaults() {
        // Ensure default values match documented spec.
        let cfg = IntegratorConfig::default();
        assert_eq!(cfg.poll_interval, Duration::from_secs(15));
        assert_eq!(cfg.cadence_min, 30);
        assert_eq!(cfg.volume_threshold, 5);
        assert_eq!(cfg.loc_budget, 1500);
        assert_eq!(cfg.max_batch, 10);
        assert_eq!(cfg.preflight_timeout, Duration::from_secs(480));
        assert!(cfg.dry_run, "dry_run must default to true in Phase 1");
        assert_eq!(
            cfg.sampling_pct, 100,
            "sampling_pct must default to 100 (fully live when enabled)"
        );
    }

    #[test]
    #[serial]
    fn test_sampling_pct_env() {
        std::env::set_var("CHUMP_INTEGRATOR_SAMPLING_PCT", "10");
        let cfg = IntegratorConfig::from_env();
        assert_eq!(cfg.sampling_pct, 10);
        std::env::remove_var("CHUMP_INTEGRATOR_SAMPLING_PCT");
    }

    #[test]
    #[serial]
    fn test_sampling_pct_clamp() {
        // Values > 100 are clamped to 100.
        std::env::set_var("CHUMP_INTEGRATOR_SAMPLING_PCT", "200");
        // u8 parse of "200" succeeds (200 fits in u8), then min(100) clamps it.
        let cfg = IntegratorConfig::from_env();
        assert_eq!(cfg.sampling_pct, 100);
        std::env::remove_var("CHUMP_INTEGRATOR_SAMPLING_PCT");
    }

    #[test]
    #[serial]
    fn test_sampling_pct_zero() {
        std::env::set_var("CHUMP_INTEGRATOR_SAMPLING_PCT", "0");
        let cfg = IntegratorConfig::from_env();
        assert_eq!(cfg.sampling_pct, 0);
        std::env::remove_var("CHUMP_INTEGRATOR_SAMPLING_PCT");
    }

    #[test]
    #[serial]
    fn test_env_bool_parse() {
        // env_bool edge cases: "0" and "1" are the canonical forms.
        std::env::set_var("CHUMP_INTEGRATOR_DRY_RUN", "0");
        let cfg = IntegratorConfig::from_env();
        assert!(!cfg.dry_run);
        std::env::remove_var("CHUMP_INTEGRATOR_DRY_RUN");

        std::env::set_var("CHUMP_INTEGRATOR_DRY_RUN", "1");
        let cfg2 = IntegratorConfig::from_env();
        assert!(cfg2.dry_run);
        std::env::remove_var("CHUMP_INTEGRATOR_DRY_RUN");
    }

    #[test]
    #[serial]
    fn test_env_override() {
        std::env::set_var("CHUMP_INTEGRATOR_MAX_BATCH", "3");
        std::env::set_var("CHUMP_INTEGRATOR_LOC_BUDGET", "800");
        let cfg = IntegratorConfig::from_env();
        assert_eq!(cfg.max_batch, 3);
        assert_eq!(cfg.loc_budget, 800);
        std::env::remove_var("CHUMP_INTEGRATOR_MAX_BATCH");
        std::env::remove_var("CHUMP_INTEGRATOR_LOC_BUDGET");
    }
}
