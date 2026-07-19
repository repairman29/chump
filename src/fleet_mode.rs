//! INFRA-1718: fleet-mode surface — one glance at auth + backend + cost
//! ceiling before an agent routes work.
//!
//! `chump fleet mode [--json]` and the `Fleet Mode` section folded into
//! `chump --briefing <GAP-ID>` both render this. Root cause this closes:
//! `chump fleet doctor` / `auth-status.sh` answer "is auth present/valid"
//! but say nothing about which cost ceiling or provider backend a spawned
//! agent will actually hit — an agent could pass every auth check and
//! still misroute work into a broken or misconfigured cascade because
//! nothing surfaced the backend + ceiling alongside the auth verdict.
//!
//! Read-only, local-file/env only — no network calls, no `gh` calls. Safe
//! to run at session start on every session.

use crate::auth;
use crate::budget_tracker;
use serde::Serialize;

#[derive(Debug, Clone, Serialize, Default)]
pub struct FleetModeSurface {
    /// "api-key" | "oauth" | "none" — mirrors `auth::ActiveMode`.
    pub auth_mode: String,
    /// False when neither ANTHROPIC_API_KEY nor CLAUDE_CODE_OAUTH_TOKEN
    /// resolved to a usable credential (`ActiveMode::None`).
    pub auth_usable: bool,
    /// "cascade" when `CHUMP_CASCADE_ENABLED=1` routes through the
    /// multi-provider cascade (provider_cascade.rs); "claude-direct"
    /// otherwise (agent spawns call `claude -p` with the resolved auth
    /// directly, no cascade).
    pub backend: String,
    /// Effort tier used to derive the cost ceiling. Read from
    /// `CHUMP_GAP_EFFORT` (set by `chump claim`); defaults to "m" when
    /// unset (matches `budget_tracker::tier_default_cost_usd`'s own
    /// unknown-tier default).
    pub effort_tier: String,
    /// USD ceiling for this session's LLM spend, per
    /// `budget_tracker::tier_default_cost_usd`.
    pub cost_ceiling_usd: f64,
}

/// Build the surface from env + credential files. Read-only.
pub fn build() -> FleetModeSurface {
    let creds = auth::detect_credentials();
    let active = auth::resolve(creds);
    let auth_mode = match active.mode {
        auth::ActiveMode::ApiKey => "api-key",
        auth::ActiveMode::OAuth => "oauth",
        auth::ActiveMode::None => "none",
    }
    .to_string();
    let backend = if std::env::var("CHUMP_CASCADE_ENABLED")
        .map(|v| v == "1")
        .unwrap_or(false)
    {
        "cascade".to_string()
    } else {
        "claude-direct".to_string()
    };
    let effort_tier = std::env::var("CHUMP_GAP_EFFORT").unwrap_or_else(|_| "m".to_string());
    let cost_ceiling_usd = budget_tracker::tier_default_cost_usd(&effort_tier);

    FleetModeSurface {
        auth_usable: !active.is_none(),
        auth_mode,
        backend,
        effort_tier,
        cost_ceiling_usd,
    }
}

impl FleetModeSurface {
    /// One-line human-readable render, e.g.:
    /// `fleet-mode: auth=oauth backend=claude-direct cost-ceiling=$5.00 (tier=m)`
    /// Appends ` [AUTH UNUSABLE]` when no credential resolved, so a scan of
    /// the session-start banner catches the failure mode instead of an
    /// agent discovering it three tool calls into a spawn.
    pub fn render_line(&self) -> String {
        let mut line = format!(
            "fleet-mode: auth={} backend={} cost-ceiling=${:.2} (tier={})",
            self.auth_mode, self.backend, self.cost_ceiling_usd, self.effort_tier
        );
        if !self.auth_usable {
            line.push_str(" [AUTH UNUSABLE]");
        }
        line
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Env vars are process-global; serialize tests that touch them.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn render_line_flags_unusable_auth() {
        let _guard = ENV_LOCK.lock().unwrap();
        let surface = FleetModeSurface {
            auth_mode: "none".into(),
            auth_usable: false,
            backend: "claude-direct".into(),
            effort_tier: "s".into(),
            cost_ceiling_usd: 2.0,
        };
        let line = surface.render_line();
        assert!(line.contains("AUTH UNUSABLE"));
        assert!(line.contains("auth=none"));
    }

    #[test]
    fn render_line_omits_flag_when_usable() {
        let surface = FleetModeSurface {
            auth_mode: "oauth".into(),
            auth_usable: true,
            backend: "claude-direct".into(),
            effort_tier: "m".into(),
            cost_ceiling_usd: 5.0,
        };
        let line = surface.render_line();
        assert!(!line.contains("UNUSABLE"));
        assert!(line.contains("cost-ceiling=$5.00"));
        assert!(line.contains("tier=m"));
    }

    #[test]
    fn build_reads_cascade_backend_from_env() {
        let _guard = ENV_LOCK.lock().unwrap();
        let prev = std::env::var("CHUMP_CASCADE_ENABLED").ok();
        std::env::set_var("CHUMP_CASCADE_ENABLED", "1");
        let surface = build();
        assert_eq!(surface.backend, "cascade");
        match prev {
            Some(v) => std::env::set_var("CHUMP_CASCADE_ENABLED", v),
            None => std::env::remove_var("CHUMP_CASCADE_ENABLED"),
        }
    }

    #[test]
    fn build_defaults_to_claude_direct_backend() {
        let _guard = ENV_LOCK.lock().unwrap();
        let prev = std::env::var("CHUMP_CASCADE_ENABLED").ok();
        std::env::remove_var("CHUMP_CASCADE_ENABLED");
        let surface = build();
        assert_eq!(surface.backend, "claude-direct");
        if let Some(v) = prev {
            std::env::set_var("CHUMP_CASCADE_ENABLED", v);
        }
    }
}
