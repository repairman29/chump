//! Standing duty-officer loop (RESILIENT-274 slice, RESILIENT-445).
//!
//! Wires `PlaybookRegistry` (RESILIENT-443) to a `DutyOfficer` (RESILIENT-444):
//! collect signals -> look up the registry entry -> route through the
//! officer. See `docs/design/DUTY_OFFICER.md` for the full design.

use std::time::Duration;

use anyhow::Result;

use crate::duty_officer::{DutyOfficer, Signal, Tier as OfficerTier};
use crate::playbook_registry::{PlaybookRegistry, Tier as RegistryTier};

/// How often the loop polls signal sources between cycles.
const POLL_INTERVAL: Duration = Duration::from_secs(60);

fn registry_tier_to_officer_tier(tier: RegistryTier) -> OfficerTier {
    match tier {
        RegistryTier::AutoHeal => OfficerTier::AutoHeal,
        RegistryTier::Runbook => OfficerTier::Runbook,
        RegistryTier::Escalate => OfficerTier::Escalate,
    }
}

/// Collects current health signals from the fleet's standing sources:
/// ambient.jsonl tail, ship-rate, disk pressure, auth status, and PR wedges.
///
/// RESILIENT-445 scaffolds the registry -> officer wiring; a later slice
/// replaces this stub with real reads (today those live in shell form as
/// `scripts/coord/duty-officer-loop.sh` `tick`). Tests exercise the wiring
/// directly via `route_signals`, bypassing collection entirely.
async fn collect_signals() -> Vec<Signal> {
    Vec::new()
}

/// Looks up each signal in `registry` and routes matches through `officer`.
/// Unregistered signal kinds are skipped (no playbook entry = no action).
///
/// Shared by the standing loop and by tests: tests call this directly with a
/// fixed signal list (the "test harness" for AC2) to exercise the full
/// registry -> officer wiring without a live loop or real signal sources.
fn route_signals(
    registry: &PlaybookRegistry,
    officer: &impl DutyOfficer,
    signals: Vec<Signal>,
) -> Result<()> {
    for signal in signals {
        if let Some(entry) = registry.get_entry(&signal.kind) {
            let tier = registry_tier_to_officer_tier(entry.tier);
            officer.route(tier, signal)?;
        }
    }
    Ok(())
}

/// Standing loop (RESILIENT-274 slice): polls signal sources, looks each
/// signal up in `registry`, and routes matches through `officer`. Runs until
/// the process is killed; intended to be spawned behind the `duty_officer`
/// feature flag (see `src/main.rs`).
pub async fn run_duty_officer_loop(
    registry: PlaybookRegistry,
    officer: impl DutyOfficer,
) -> Result<()> {
    loop {
        let signals = collect_signals().await;
        route_signals(&registry, &officer, signals)?;
        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::duty_officer::TestDutyOfficer;
    use std::io::Write;

    /// Mock signals standing in for the 5 source kinds named in AC2:
    /// ambient.jsonl, ship-rate, disk, auth, wedges.
    fn mock_signals() -> Vec<Signal> {
        vec![
            Signal {
                kind: "ambient_lag".to_string(),
                detail: "tail stalled 5m".to_string(),
            },
            Signal {
                kind: "ship_rate_low".to_string(),
                detail: "0 merges/1h".to_string(),
            },
            Signal {
                kind: "disk_critical".to_string(),
                detail: "free_gb=10".to_string(),
            },
            Signal {
                kind: "farmer_auth_dead".to_string(),
                detail: "oauth expired".to_string(),
            },
            Signal {
                kind: "pr_pipeline_wedged".to_string(),
                detail: "3 PRs stuck".to_string(),
            },
        ]
    }

    fn test_registry() -> PlaybookRegistry {
        let json = r#"[
            {"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-cleanup.sh"},
            {"signal": "pr_pipeline_wedged", "tier": 2, "action": "diagnose the blocking check"},
            {"signal": "farmer_auth_dead", "tier": 3, "action": "page operator"}
        ]"#;
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(file, "{json}").unwrap();
        crate::playbook_registry::load_registry(file.path()).unwrap()
    }

    #[test]
    fn route_signals_only_routes_registered_kinds() {
        let registry = test_registry();
        let officer = TestDutyOfficer::default();

        route_signals(&registry, &officer, mock_signals()).unwrap();

        let routed = officer.routed.borrow();
        // ambient_lag and ship_rate_low have no registry entry -> skipped.
        // Order follows `mock_signals()`'s input order (ambient_lag and
        // ship_rate_low have no registry entry, so they're skipped).
        assert_eq!(routed.len(), 3);
        assert_eq!(routed[0].0, OfficerTier::AutoHeal);
        assert_eq!(routed[0].1.kind, "disk_critical");
        assert_eq!(routed[1].0, OfficerTier::Escalate);
        assert_eq!(routed[1].1.kind, "farmer_auth_dead");
        assert_eq!(routed[2].0, OfficerTier::Runbook);
        assert_eq!(routed[2].1.kind, "pr_pipeline_wedged");
    }

    #[test]
    fn registry_tier_maps_to_officer_tier() {
        assert_eq!(
            registry_tier_to_officer_tier(RegistryTier::AutoHeal),
            OfficerTier::AutoHeal
        );
        assert_eq!(
            registry_tier_to_officer_tier(RegistryTier::Runbook),
            OfficerTier::Runbook
        );
        assert_eq!(
            registry_tier_to_officer_tier(RegistryTier::Escalate),
            OfficerTier::Escalate
        );
    }
}
