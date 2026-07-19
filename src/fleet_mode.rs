//! INFRA-1718: `chump fleet mode` — one-line/one-object surface for what an
//! agent needs before routing work: is auth usable, which backend serves
//! calls (cascade vs claude-direct), and what the cost ceiling is for the
//! current effort tier.
//!
//! Read-only. No network or `gh` calls — derived entirely from
//! `auth::detect_credentials`/`resolve`, the `CHUMP_CASCADE_ENABLED` env var,
//! and `budget_tracker::tier_default_cost_usd`. Exposed twice:
//!   - `chump fleet mode [--json]` — standalone CLI surface
//!   - `chump --briefing <GAP-ID>` — embedded `fleet_mode` section, computed
//!     fresh at briefing time (not cached), so a stale auth read never
//!     survives into a new session's briefing.

use crate::auth;
use crate::budget_tracker;
use serde::Serialize;

/// Backend that will actually serve LLM calls given current env.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Backend {
    Cascade,
    ClaudeDirect,
}

impl Backend {
    fn as_str(self) -> &'static str {
        match self {
            Backend::Cascade => "cascade",
            Backend::ClaudeDirect => "claude-direct",
        }
    }
}

/// The full fleet-mode snapshot.
#[derive(Debug, Clone, Serialize, Default)]
pub struct FleetMode {
    /// "api-key" | "oauth" | "none"
    pub auth_mode: String,
    /// True when the resolved auth mode has a usable (non-empty) credential.
    pub auth_usable: bool,
    /// "cascade" | "claude-direct"
    pub backend: String,
    /// Effort tier driving the cost ceiling (xs|s|m|l|...).
    pub effort_tier: String,
    /// USD ceiling for the resolved effort tier (budget_tracker::tier_default_cost_usd).
    pub cost_ceiling_usd: f64,
}

/// Effort tier to report. Reads `CHUMP_FLEET_EFFORT_TIER`, defaulting to "m"
/// (mirrors `budget_tracker::tier_default_cost_usd`'s unknown-tier fallback).
fn resolved_effort_tier() -> String {
    std::env::var("CHUMP_FLEET_EFFORT_TIER")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "m".to_string())
}

fn cascade_enabled() -> bool {
    std::env::var("CHUMP_CASCADE_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Compute the current fleet-mode snapshot fresh (no caching) from env +
/// credential detection.
pub fn detect() -> FleetMode {
    let active = auth::detect_and_resolve();
    let auth_mode = match active.mode {
        auth::ActiveMode::ApiKey => "api-key",
        auth::ActiveMode::OAuth => "oauth",
        auth::ActiveMode::None => "none",
    }
    .to_string();
    let auth_usable = !active.is_none();

    let backend = if cascade_enabled() {
        Backend::Cascade
    } else {
        Backend::ClaudeDirect
    };

    let effort_tier = resolved_effort_tier();
    let cost_ceiling_usd = budget_tracker::tier_default_cost_usd(&effort_tier);

    FleetMode {
        auth_mode,
        auth_usable,
        backend: backend.as_str().to_string(),
        effort_tier,
        cost_ceiling_usd,
    }
}

/// One-line human-readable render for the CLI's non-JSON path.
/// Prefixes `[AUTH UNUSABLE] ` when `auth_usable` is false so the flag is
/// impossible to miss in a scroll of terminal output.
pub fn render_line(mode: &FleetMode) -> String {
    let prefix = if mode.auth_usable {
        String::new()
    } else {
        "[AUTH UNUSABLE] ".to_string()
    };
    format!(
        "{prefix}auth={} backend={} effort={} cost_ceiling_usd={:.2}",
        mode.auth_mode, mode.backend, mode.effort_tier, mode.cost_ceiling_usd
    )
}

pub fn render_json(mode: &FleetMode) -> String {
    serde_json::to_string_pretty(mode).unwrap_or_else(|_| "{}".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Serialize env-mutating tests: std::env::set_var races across threads.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn clear_auth_env() {
        std::env::remove_var("ANTHROPIC_API_KEY");
        std::env::remove_var("CLAUDE_CODE_OAUTH_TOKEN");
        std::env::remove_var("CHUMP_AUTH_MODE");
        std::env::remove_var("CHUMP_OAUTH_TOKEN_FILE");
        std::env::remove_var("CHUMP_CASCADE_ENABLED");
        std::env::remove_var("CHUMP_FLEET_EFFORT_TIER");
    }

    #[test]
    fn render_line_flags_unusable_auth() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_auth_env();
        let mode = FleetMode {
            auth_mode: "none".to_string(),
            auth_usable: false,
            backend: "claude-direct".to_string(),
            effort_tier: "s".to_string(),
            cost_ceiling_usd: 2.0,
        };
        let line = render_line(&mode);
        assert!(line.starts_with("[AUTH UNUSABLE] "));
        assert!(line.contains("auth=none"));
    }

    #[test]
    fn render_line_no_flag_when_usable() {
        let mode = FleetMode {
            auth_mode: "api-key".to_string(),
            auth_usable: true,
            backend: "cascade".to_string(),
            effort_tier: "m".to_string(),
            cost_ceiling_usd: 5.0,
        };
        let line = render_line(&mode);
        assert!(!line.contains("[AUTH UNUSABLE]"));
        assert!(line.contains("backend=cascade"));
    }

    #[test]
    fn detect_backend_branches_on_cascade_env() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_auth_env();
        std::env::set_var("ANTHROPIC_API_KEY", "sk-test-key");

        std::env::set_var("CHUMP_CASCADE_ENABLED", "1");
        let mode = detect();
        assert_eq!(mode.backend, "cascade");
        assert!(mode.auth_usable);
        assert_eq!(mode.auth_mode, "api-key");

        std::env::remove_var("CHUMP_CASCADE_ENABLED");
        let mode = detect();
        assert_eq!(mode.backend, "claude-direct");

        clear_auth_env();
    }

    #[test]
    fn detect_effort_tier_defaults_to_m() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_auth_env();
        let mode = detect();
        assert_eq!(mode.effort_tier, "m");
        assert_eq!(
            mode.cost_ceiling_usd,
            budget_tracker::tier_default_cost_usd("m")
        );
    }

    #[test]
    fn detect_auth_unusable_when_forced_mode_has_no_creds() {
        // Machine-state independent: force api-key mode with no api key set
        // (even if oauth creds exist via config.toml / refresh file on this
        // box) — auth::resolve must report None because the forced mode
        // doesn't match what's available.
        let _guard = ENV_LOCK.lock().unwrap();
        clear_auth_env();
        std::env::set_var("CHUMP_AUTH_MODE", "api-key");
        let mode = detect();
        assert_eq!(mode.auth_mode, "none");
        assert!(!mode.auth_usable);
        clear_auth_env();
    }
}
