//! Configuration loaded from environment variables.
//!
//! All knobs have sensible defaults; none are required.
//!
//! ## LIVE-mode toggle (SCALE-A, INFRA-2130)
//!
//! The canonical dry-run flag is `CHUMP_INTEGRATOR_DRY_RUN` (default `1`).
//! `CHUMP_INTEGRATOR_LIVE` is an ergonomic alias: setting it to `1` sets
//! `dry_run = false`. If both are set, `CHUMP_INTEGRATOR_DRY_RUN` wins
//! (explicit beats alias). Operator must opt-in — default is always safe.
//!
//! Safety rails applied when `dry_run = false`:
//! - Trunk-RED gate: read `.chump-locks/trunk-red-detector-state.json`; hold
//!   if `is_red = true`.
//! - Batch cap: `CHUMP_INTEGRATOR_BATCH_MAX` (default 5 in v1). Cap sits
//!   below `max_batch` to start conservatively.
//! - `do-not-batch` label: candidates with this GitHub label are excluded.
//! - Circuit breaker: on merge failure, emit `integration_cycle_failed` and
//!   force dry-run for the next cycle.

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
    ///
    /// Set `CHUMP_INTEGRATOR_DRY_RUN=0` OR `CHUMP_INTEGRATOR_LIVE=1` to
    /// enable LIVE mode. `CHUMP_INTEGRATOR_DRY_RUN` takes precedence when
    /// both are set.
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
    /// v1 LIVE-mode batch cap. Default 5 — conservative starting point.
    ///
    /// Separate from `max_batch` so the LIVE-mode guard is explicit and
    /// the operator must consciously raise it.
    ///
    /// Env: `CHUMP_INTEGRATOR_BATCH_MAX` (default 5).
    pub batch_max_live: usize,
    /// GitHub label name that opts a PR out of batching. Default: "do-not-batch".
    ///
    /// Env: `CHUMP_INTEGRATOR_DO_NOT_BATCH_LABEL`.
    pub do_not_batch_label: String,
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
            batch_max_live: 5,
            do_not_batch_label: "do-not-batch".to_string(),
        }
    }
}

impl IntegratorConfig {
    /// Load from environment variables, falling back to defaults.
    ///
    /// `CHUMP_INTEGRATOR_DRY_RUN` is the authoritative dry-run flag.
    /// `CHUMP_INTEGRATOR_LIVE=1` is an alias that sets dry_run=false when
    /// `CHUMP_INTEGRATOR_DRY_RUN` is not explicitly set.
    pub fn from_env() -> Self {
        let poll_s = env_u64("CHUMP_INTEGRATOR_POLL_S", 15);
        let cadence_min = env_u64("CHUMP_INTEGRATOR_CADENCE_MIN", 30);
        let volume_threshold = env_usize("CHUMP_INTEGRATOR_VOLUME_THRESHOLD", 5);
        let loc_budget = env_usize("CHUMP_INTEGRATOR_LOC_BUDGET", 1500);
        let max_batch = env_usize("CHUMP_INTEGRATOR_MAX_BATCH", 10);
        let preflight_timeout_s = env_u64("CHUMP_INTEGRATOR_PREFLIGHT_TIMEOUT_S", 480);
        let sampling_pct = env_sampling_pct("CHUMP_INTEGRATOR_SAMPLING_PCT", 100);
        let batch_max_live = env_usize("CHUMP_INTEGRATOR_BATCH_MAX", 5);
        let do_not_batch_label = std::env::var("CHUMP_INTEGRATOR_DO_NOT_BATCH_LABEL")
            .unwrap_or_else(|_| "do-not-batch".to_string());

        // CHUMP_INTEGRATOR_DRY_RUN is authoritative. When absent, check the
        // CHUMP_INTEGRATOR_LIVE alias. Default is always dry_run=true.
        let dry_run = if std::env::var("CHUMP_INTEGRATOR_DRY_RUN").is_ok() {
            env_bool("CHUMP_INTEGRATOR_DRY_RUN", true)
        } else {
            // LIVE=1 means dry_run=false; anything else keeps dry_run=true.
            !env_bool("CHUMP_INTEGRATOR_LIVE", false)
        };

        Self {
            poll_interval: Duration::from_secs(poll_s),
            cadence_min,
            volume_threshold,
            loc_budget,
            max_batch,
            preflight_timeout: Duration::from_secs(preflight_timeout_s),
            dry_run,
            sampling_pct,
            batch_max_live,
            do_not_batch_label,
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
        assert_eq!(cfg.batch_max_live, 5, "v1 LIVE batch cap must default to 5");
        assert_eq!(
            cfg.do_not_batch_label, "do-not-batch",
            "default exclusion label"
        );
    }

    #[test]
    #[serial]
    fn test_live_alias_enables_live_mode() {
        // CHUMP_INTEGRATOR_LIVE=1 sets dry_run=false when DRY_RUN is absent.
        std::env::remove_var("CHUMP_INTEGRATOR_DRY_RUN");
        std::env::set_var("CHUMP_INTEGRATOR_LIVE", "1");
        let cfg = IntegratorConfig::from_env();
        assert!(!cfg.dry_run, "LIVE=1 must enable live mode");
        std::env::remove_var("CHUMP_INTEGRATOR_LIVE");
    }

    #[test]
    #[serial]
    fn test_dry_run_overrides_live_alias() {
        // DRY_RUN=1 wins even when LIVE=1.
        std::env::set_var("CHUMP_INTEGRATOR_DRY_RUN", "1");
        std::env::set_var("CHUMP_INTEGRATOR_LIVE", "1");
        let cfg = IntegratorConfig::from_env();
        assert!(cfg.dry_run, "DRY_RUN=1 must override LIVE=1");
        std::env::remove_var("CHUMP_INTEGRATOR_DRY_RUN");
        std::env::remove_var("CHUMP_INTEGRATOR_LIVE");
    }

    #[test]
    #[serial]
    fn test_live_alias_zero_keeps_dry_run() {
        // CHUMP_INTEGRATOR_LIVE=0 keeps dry_run=true (default).
        std::env::remove_var("CHUMP_INTEGRATOR_DRY_RUN");
        std::env::set_var("CHUMP_INTEGRATOR_LIVE", "0");
        let cfg = IntegratorConfig::from_env();
        assert!(cfg.dry_run, "LIVE=0 must keep dry_run=true");
        std::env::remove_var("CHUMP_INTEGRATOR_LIVE");
    }

    #[test]
    #[serial]
    fn test_batch_max_live_env() {
        std::env::set_var("CHUMP_INTEGRATOR_BATCH_MAX", "3");
        let cfg = IntegratorConfig::from_env();
        assert_eq!(cfg.batch_max_live, 3);
        std::env::remove_var("CHUMP_INTEGRATOR_BATCH_MAX");
    }

    #[test]
    #[serial]
    fn test_do_not_batch_label_env() {
        std::env::set_var("CHUMP_INTEGRATOR_DO_NOT_BATCH_LABEL", "skip-batch");
        let cfg = IntegratorConfig::from_env();
        assert_eq!(cfg.do_not_batch_label, "skip-batch");
        std::env::remove_var("CHUMP_INTEGRATOR_DO_NOT_BATCH_LABEL");
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
