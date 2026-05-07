//! INFRA-625: Operator-presence detection and autonomous-mode policy.
//!
//! When the operator has been absent for longer than the configured threshold the
//! fleet switches into autonomous mode:
//!
//!   (a) cascade restricted to free-tier slots (Cerebras / Groq / Gemini)
//!   (b) gap picker limited to P0 only
//!   (c) daily cost cap tightened to CHUMP_AUTONOMOUS_DAILY_COST_CAP_USD
//!   (d) work summaries appended to the digest file for review on return
//!   (e) irrecoverable credential failure → fleet halt + operator-recall notice
//!
//! Detection sources (checked in order):
//!   1. Filesystem mtime of CHUMP_OPERATOR_ACTIVITY_PATH (default ~/.claude/)
//!   2. CHUMP_OPERATOR_LAST_SEEN_UNIX env var (set by shell hooks or NATS bridge)
//!
//! Integrators:
//!   - `AutonomousPolicy::apply_cascade_env()` exports the env vars that
//!     `provider_cascade.rs` already reads, so no changes are needed there.
//!   - `AutonomousPolicy::picker_filter()` returns an SQL WHERE snippet for the
//!     gap picker's `chump gap list` query.
//!   - `AutonomousPolicy::check_cost_cap(current, cap)` returns Err when the daily cap
//!     is exceeded; callers should halt the current work unit.
//!   - `AutonomousPolicy::append_digest()` writes a one-liner to the digest file.
//!   - `AutonomousPolicy::halt_on_credential_failure()` writes the recall notice
//!     and returns Err so the launcher can exit cleanly.

use std::fs;
use std::io::Write as IoWrite;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};

// ── Configuration ─────────────────────────────────────────────────────────────

/// Hours of operator absence that trigger autonomous mode (default 4 h).
const DEFAULT_ABSENCE_THRESHOLD_HOURS: u64 = 4;

/// Default filesystem path whose mtime we inspect.
fn default_activity_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".claude")
}

fn absence_threshold() -> Duration {
    let hours = std::env::var("CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(DEFAULT_ABSENCE_THRESHOLD_HOURS);
    Duration::from_secs(hours * 3600)
}

fn activity_path() -> PathBuf {
    std::env::var("CHUMP_OPERATOR_ACTIVITY_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_activity_path())
}

fn digest_path() -> PathBuf {
    std::env::var("CHUMP_AUTONOMOUS_DIGEST_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
            PathBuf::from(home).join(".chump-autonomous-digest.jsonl")
        })
}

fn daily_cost_cap_usd() -> f64 {
    std::env::var("CHUMP_AUTONOMOUS_DAILY_COST_CAP_USD")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(1.00)
}

// ── Presence detection ────────────────────────────────────────────────────────

/// Detected state of the operator.
#[derive(Debug, Clone, PartialEq)]
pub enum PresenceState {
    /// Activity seen within the threshold window.
    Present,
    /// Absent for `hours` hours — autonomous mode active.
    Absent { hours: f64 },
}

impl PresenceState {
    pub fn is_absent(&self) -> bool {
        matches!(self, PresenceState::Absent { .. })
    }
}

/// Returns the Unix timestamp (seconds) of the most recent operator activity.
///
/// Checks, in order:
///   1. `CHUMP_OPERATOR_LAST_SEEN_UNIX` env var (NATS bridge or shell hook)
///   2. Filesystem mtime of `activity_path()`
fn last_seen_unix() -> Option<u64> {
    // Source 1: explicit env override (NATS heartbeat bridge sets this).
    if let Ok(val) = std::env::var("CHUMP_OPERATOR_LAST_SEEN_UNIX") {
        if let Ok(ts) = val.trim().parse::<u64>() {
            return Some(ts);
        }
    }

    // Source 2: mtime of ~/.claude/ (or configured path).
    let path = activity_path();
    fs::metadata(&path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
}

/// Detect current operator presence.
pub fn detect() -> PresenceState {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    match last_seen_unix() {
        None => {
            // No signal at all — assume present (safe default; don't auto-restrict).
            PresenceState::Present
        }
        Some(last) => {
            let elapsed = now.saturating_sub(last);
            let threshold = absence_threshold().as_secs();
            if elapsed >= threshold {
                PresenceState::Absent {
                    hours: elapsed as f64 / 3600.0,
                }
            } else {
                PresenceState::Present
            }
        }
    }
}

// ── Autonomous-mode policy ────────────────────────────────────────────────────

/// Policy values derived from `PresenceState::Absent`.
#[derive(Debug, Clone)]
pub struct AutonomousPolicy {
    pub absent_hours: f64,
    pub daily_cost_cap_usd: f64,
    pub digest_path: PathBuf,
}

impl AutonomousPolicy {
    pub fn from_state(state: &PresenceState) -> Option<Self> {
        match state {
            PresenceState::Present => None,
            PresenceState::Absent { hours } => Some(AutonomousPolicy {
                absent_hours: *hours,
                daily_cost_cap_usd: daily_cost_cap_usd(),
                digest_path: digest_path(),
            }),
        }
    }

    /// (a) Export env vars that restrict `provider_cascade.rs` to free-tier slots.
    ///
    /// Slots marked `CHUMP_PROVIDER_N_TIER=free` are kept; Anthropic slots are
    /// disabled by setting `CHUMP_PROVIDER_N_ENABLED=0` for any slot whose name
    /// contains "anthropic" or "claude".
    ///
    /// In practice callers set these before spawning worker subprocesses:
    ///
    ///   for (k, v) in policy.cascade_env_overrides() { env::set_var(k, v); }
    pub fn cascade_env_overrides(&self) -> Vec<(String, String)> {
        let mut overrides = Vec::new();

        // Signal that autonomous mode is active so cascade can log it.
        overrides.push(("CHUMP_AUTONOMOUS_MODE".to_string(), "1".to_string()));

        // Disable Anthropic slots (slot names known from provider_cascade.rs convention).
        // Slots 1-9; callers who configured non-free slots with "anthropic"/"claude" in
        // the name will have them masked. This is conservative — better to skip a free
        // slot than to spend on a paid one.
        for n in 1..=9 {
            let name_key = format!("CHUMP_PROVIDER_{n}_NAME");
            if let Ok(name) = std::env::var(&name_key) {
                let name_lc = name.to_lowercase();
                if name_lc.contains("anthropic") || name_lc.contains("claude") {
                    overrides.push((format!("CHUMP_PROVIDER_{n}_ENABLED"), "0".to_string()));
                }
            }
            // Also respect explicit tier labels.
            let tier_key = format!("CHUMP_PROVIDER_{n}_TIER");
            if let Ok(tier) = std::env::var(&tier_key) {
                if tier != "free" {
                    overrides.push((format!("CHUMP_PROVIDER_{n}_ENABLED"), "0".to_string()));
                }
            }
        }

        overrides.push((
            "CHUMP_AUTONOMOUS_DAILY_COST_CAP_USD".to_string(),
            self.daily_cost_cap_usd.to_string(),
        ));

        overrides
    }

    /// (b) SQL WHERE snippet to restrict gap picker to P0 only.
    ///
    /// Drop into: `SELECT … FROM gaps WHERE status='open' AND <picker_filter()>`
    pub fn picker_filter(&self) -> &'static str {
        "priority = 'P0'"
    }

    /// (c) Check whether the daily cost cap has been exceeded.
    ///
    /// Pass `self.daily_cost_cap_usd` (captured at construction from env) or an
    /// explicit override. Accepting the cap as a parameter removes the env-var
    /// dependency from the call site, enabling parallel test execution without
    /// test-isolation annotations.
    pub fn check_cost_cap(&self, current_cost_usd: f64, daily_cap_usd: f64) -> Result<()> {
        if current_cost_usd >= daily_cap_usd {
            anyhow::bail!(
                "autonomous-mode daily cost cap reached: ${:.4} >= ${:.2}; halting",
                current_cost_usd,
                daily_cap_usd
            );
        }
        Ok(())
    }

    /// (d) Append a summary entry to the operator-return digest.
    pub fn append_digest(&self, kind: &str, message: &str) -> Result<()> {
        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let entry = serde_json::json!({
            "ts": ts,
            "kind": kind,
            "absent_hours": self.absent_hours,
            "message": message,
        });
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.digest_path)
            .with_context(|| format!("opening digest at {:?}", self.digest_path))?;
        writeln!(file, "{}", entry)
            .with_context(|| format!("writing digest at {:?}", self.digest_path))?;
        Ok(())
    }

    /// (e) Halt the fleet on an irrecoverable credential failure.
    ///
    /// Writes an operator-recall notice to the digest and returns Err so the
    /// launcher can exit.  Callers should also emit a `fleet_halt` event to
    /// `ambient.jsonl`.
    pub fn halt_on_credential_failure(&self, reason: &str) -> Result<()> {
        let message = format!(
            "OPERATOR RECALL REQUIRED — irrecoverable credential failure: {}. \
             Fleet has halted. Re-run `chump fleet start` after refreshing credentials.",
            reason
        );
        let _ = self.append_digest("operator_recall", &message);
        anyhow::bail!("{}", message)
    }
}

// ── Public helper: emit autonomous-mode event to ambient.jsonl ────────────────

/// Emit a `autonomous_mode_entered` or `autonomous_mode_exited` event.
pub fn emit_ambient_event(kind: &str, absent_hours: Option<f64>) -> Result<()> {
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let entry = if let Some(h) = absent_hours {
        serde_json::json!({ "ts": ts, "kind": kind, "absent_hours": h })
    } else {
        serde_json::json!({ "ts": ts, "kind": kind })
    };

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .with_context(|| format!("opening ambient log at {ambient_path}"))?;
    writeln!(file, "{}", entry)
        .with_context(|| format!("writing ambient log at {ambient_path}"))?;
    Ok(())
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use tempfile::TempDir;

    fn clear_env() {
        for key in &[
            "CHUMP_OPERATOR_LAST_SEEN_UNIX",
            "CHUMP_OPERATOR_ACTIVITY_PATH",
            "CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS",
            "CHUMP_AUTONOMOUS_DAILY_COST_CAP_USD",
            "CHUMP_AUTONOMOUS_DIGEST_PATH",
            "CHUMP_AUTONOMOUS_MODE",
        ] {
            env::remove_var(key);
        }
    }

    #[test]
    fn present_when_last_seen_recent() {
        clear_env();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        env::set_var("CHUMP_OPERATOR_LAST_SEEN_UNIX", now.to_string());
        env::set_var("CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS", "4");

        assert_eq!(detect(), PresenceState::Present);
    }

    #[test]
    fn absent_when_last_seen_old() {
        clear_env();
        let old = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            .saturating_sub(6 * 3600); // 6 hours ago
        env::set_var("CHUMP_OPERATOR_LAST_SEEN_UNIX", old.to_string());
        env::set_var("CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS", "4");

        let state = detect();
        assert!(state.is_absent(), "expected Absent, got {:?}", state);
        if let PresenceState::Absent { hours } = state {
            assert!(hours >= 5.9, "expected ~6h, got {hours}");
        }
    }

    #[test]
    fn present_when_no_signal() {
        clear_env();
        // No env var; point activity path at a non-existent dir so mtime fails.
        env::set_var("CHUMP_OPERATOR_ACTIVITY_PATH", "/nonexistent/path/xyz");
        assert_eq!(detect(), PresenceState::Present);
    }

    #[test]
    fn policy_none_when_present() {
        clear_env();
        let state = PresenceState::Present;
        assert!(AutonomousPolicy::from_state(&state).is_none());
    }

    #[test]
    fn policy_some_when_absent() {
        clear_env();
        let state = PresenceState::Absent { hours: 7.5 };
        let policy = AutonomousPolicy::from_state(&state).unwrap();
        assert!((policy.absent_hours - 7.5).abs() < 0.01);
        assert_eq!(policy.daily_cost_cap_usd, 1.00); // default
    }

    #[test]
    fn cost_cap_under_limit_ok() {
        let policy = AutonomousPolicy::from_state(&PresenceState::Absent { hours: 5.0 }).unwrap();
        assert!(policy.check_cost_cap(1.99, 2.00).is_ok());
    }

    #[test]
    fn cost_cap_at_limit_err() {
        let policy = AutonomousPolicy::from_state(&PresenceState::Absent { hours: 5.0 }).unwrap();
        assert!(policy.check_cost_cap(2.00, 2.00).is_err());
    }

    #[test]
    fn picker_filter_is_p0_only() {
        let state = PresenceState::Absent { hours: 8.0 };
        let policy = AutonomousPolicy::from_state(&state).unwrap();
        assert_eq!(policy.picker_filter(), "priority = 'P0'");
    }

    #[test]
    fn cascade_env_overrides_contains_autonomous_mode() {
        clear_env();
        let state = PresenceState::Absent { hours: 5.0 };
        let policy = AutonomousPolicy::from_state(&state).unwrap();
        let overrides = policy.cascade_env_overrides();
        let found = overrides
            .iter()
            .any(|(k, v)| k == "CHUMP_AUTONOMOUS_MODE" && v == "1");
        assert!(found, "expected CHUMP_AUTONOMOUS_MODE=1 in overrides");
    }

    #[test]
    fn cascade_env_disables_anthropic_slots() {
        clear_env();
        env::set_var("CHUMP_PROVIDER_1_NAME", "anthropic-claude-opus");
        env::set_var("CHUMP_PROVIDER_2_NAME", "groq");

        let state = PresenceState::Absent { hours: 5.0 };
        let policy = AutonomousPolicy::from_state(&state).unwrap();
        let overrides = policy.cascade_env_overrides();

        let slot1_disabled = overrides
            .iter()
            .any(|(k, v)| k == "CHUMP_PROVIDER_1_ENABLED" && v == "0");
        let slot2_disabled = overrides
            .iter()
            .any(|(k, v)| k == "CHUMP_PROVIDER_2_ENABLED" && v == "0");

        assert!(slot1_disabled, "anthropic slot 1 should be disabled");
        assert!(!slot2_disabled, "groq slot 2 should not be disabled");

        env::remove_var("CHUMP_PROVIDER_1_NAME");
        env::remove_var("CHUMP_PROVIDER_2_NAME");
    }

    #[test]
    fn append_digest_creates_file() {
        clear_env();
        let dir = TempDir::new().unwrap();
        let digest = dir.path().join("digest.jsonl");
        env::set_var("CHUMP_AUTONOMOUS_DIGEST_PATH", digest.to_str().unwrap());

        let state = PresenceState::Absent { hours: 5.0 };
        let policy = AutonomousPolicy::from_state(&state).unwrap();
        policy
            .append_digest("work_complete", "shipped INFRA-625")
            .unwrap();

        let contents = fs::read_to_string(&digest).unwrap();
        assert!(contents.contains("work_complete"));
        assert!(contents.contains("shipped INFRA-625"));
    }

    #[test]
    fn halt_on_credential_failure_returns_err() {
        clear_env();
        let dir = TempDir::new().unwrap();
        let digest = dir.path().join("digest.jsonl");
        env::set_var("CHUMP_AUTONOMOUS_DIGEST_PATH", digest.to_str().unwrap());

        let state = PresenceState::Absent { hours: 5.0 };
        let policy = AutonomousPolicy::from_state(&state).unwrap();
        let result = policy.halt_on_credential_failure("API key expired");
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("OPERATOR RECALL REQUIRED"));
    }
}
