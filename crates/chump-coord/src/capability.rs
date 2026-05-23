// crates/chump-coord/src/capability.rs — INFRA-1760
//
// CapabilityManifest is the v1 schema for "what can this Opus session do?"
// — the foundation slice (1/4) of META-061 Layer 2c (the answer to "is
// agent X online?" / "who has capability Y?" routing decisions).
//
// This file ships the schema + struct + the `current_manifest()` helper
// that any worker can call to publish itself. The KV publish/heartbeat
// loop, picker integration, and presence query API are subsequent slices
// (filed as INFRA-1120 follow-ups once the schema lands).
//
// Privacy stance:
//   - `harness`, `model_tier`, `skills`, `machine` — always populated
//   - `gpu`, `ip` — populated ONLY when CHUMP_PUBLISH_HARDWARE=1 is set
//     (operators opt-in to publishing hardware details; default off)
//
// JSON wire shape (chump-capability-v1):
//   {
//     "schema_version": "chump-capability-v1",
//     "session_id":     "curator-opus-ci-audit-2026-05-23",
//     "harness":        "claude",
//     "model_tier":     "opus",
//     "skills":         ["rust", "shell", "ci-mirror"],
//     "machine":        "macbook",
//     "gpu":            null,    // unless CHUMP_PUBLISH_HARDWARE=1
//     "ip":             null,    // unless CHUMP_PUBLISH_HARDWARE=1
//     "started_at":     "2026-05-23T05:00:00Z",
//     "heartbeat_at":   "2026-05-23T05:30:00Z",
//     "ttl_seconds":    300
//   }

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Wire-version constant. Bump to `chump-capability-v2` when adding a new
/// REQUIRED field; readers should tolerate forward-compat optional fields
/// without a bump.
pub const CAPABILITY_SCHEMA_VERSION: &str = "chump-capability-v1";

/// Default heartbeat TTL when not overridden by the caller. Matches the
/// 5-min stale-session window the picker uses to exclude dead manifests.
pub const DEFAULT_TTL_SECONDS: u32 = 300;

/// Manifest published by every worker session to the `chump_capabilities`
/// NATS KV bucket. Stale entries (heartbeat_at > ttl_seconds old) are
/// excluded from routing decisions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityManifest {
    /// Schema identifier; today `chump-capability-v1`.
    pub schema_version: String,
    /// Stable session identifier (e.g. `curator-opus-ci-audit-2026-05-23`
    /// or `claim-infra-1760-<pid>-<ts>`).
    pub session_id: String,
    /// `claude` | `opencode` | `codex` | `manual` | `fleet-dispatcher`.
    pub harness: String,
    /// `opus` | `sonnet` | `haiku` | `local` | `unknown`.
    pub model_tier: String,
    /// Free-form capability tags. Examples: "rust", "shell", "pwa",
    /// "tree-sitter", "ci-mirror", "doc-author".
    pub skills: Vec<String>,
    /// Machine identifier (hostname or operator-assigned label).
    /// Always populated (it's not sensitive).
    pub machine: Option<String>,
    /// GPU model. Populated only when `CHUMP_PUBLISH_HARDWARE=1`.
    pub gpu: Option<String>,
    /// IP address. Populated only when `CHUMP_PUBLISH_HARDWARE=1`.
    pub ip: Option<String>,
    /// When this manifest was first published.
    pub started_at: DateTime<Utc>,
    /// Last heartbeat. Stale-session detection compares against this.
    pub heartbeat_at: DateTime<Utc>,
    /// Seconds after `heartbeat_at` before this manifest is treated as
    /// stale. Default `DEFAULT_TTL_SECONDS` (300).
    pub ttl_seconds: u32,
}

impl CapabilityManifest {
    /// Whether this manifest should still be considered alive given a
    /// reference timestamp (usually `Utc::now()`).
    pub fn is_alive(&self, now: DateTime<Utc>) -> bool {
        let age = now.signed_duration_since(self.heartbeat_at);
        age.num_seconds() <= self.ttl_seconds as i64
    }

    /// Whether this session is publishing hardware details (gpu/ip).
    pub fn has_hardware_fields(&self) -> bool {
        self.gpu.is_some() || self.ip.is_some()
    }
}

/// Build a CapabilityManifest for the current worker session by reading
/// environment + system state. Caller passes the skill list since that's
/// session-specific (and not auto-discoverable in a useful way today).
///
/// Hardware fields (gpu, ip) are populated only when
/// `CHUMP_PUBLISH_HARDWARE=1` is set in the environment.
pub fn current_manifest(skills: Vec<String>) -> CapabilityManifest {
    let now = Utc::now();
    let session_id = std::env::var("CHUMP_SESSION_ID")
        .unwrap_or_else(|_| format!("unknown-{}", std::process::id()));
    let harness = std::env::var("CHUMP_AGENT_HARNESS").unwrap_or_else(|_| "manual".to_string());
    let model_tier = std::env::var("FLEET_MODEL").unwrap_or_else(|_| "unknown".to_string());
    let machine = hostname_or_label();

    let publish_hw = std::env::var("CHUMP_PUBLISH_HARDWARE").as_deref() == Ok("1");
    let (gpu, ip) = if publish_hw {
        (gpu_label(), ip_address())
    } else {
        (None, None)
    };

    CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id,
        harness,
        model_tier,
        skills,
        machine,
        gpu,
        ip,
        started_at: now,
        heartbeat_at: now,
        ttl_seconds: DEFAULT_TTL_SECONDS,
    }
}

/// Best-effort hostname read. Falls back to `CHUMP_MACHINE_LABEL` env if
/// the hostname call fails. Returns `None` on total failure.
fn hostname_or_label() -> Option<String> {
    if let Ok(label) = std::env::var("CHUMP_MACHINE_LABEL") {
        if !label.is_empty() {
            return Some(label);
        }
    }
    // std doesn't expose hostname() portably; defer to `gethostname` via
    // /etc/hostname-ish path on unix. Best-effort; None is acceptable.
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Stubbed GPU label resolver. Real implementation would query system_profiler
/// (macOS) or nvidia-smi (linux) in a follow-up slice. For now: returns
/// `CHUMP_GPU_LABEL` env if set, else None.
fn gpu_label() -> Option<String> {
    std::env::var("CHUMP_GPU_LABEL")
        .ok()
        .filter(|s| !s.is_empty())
}

/// Stubbed IP address resolver. Real implementation would resolve via
/// `getifaddrs` in a follow-up slice. For now: returns `CHUMP_IP_LABEL`
/// env if set, else None.
fn ip_address() -> Option<String> {
    std::env::var("CHUMP_IP_LABEL")
        .ok()
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_version_is_v1() {
        assert_eq!(CAPABILITY_SCHEMA_VERSION, "chump-capability-v1");
    }

    #[test]
    fn json_round_trip() {
        let m = CapabilityManifest {
            schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
            session_id: "test-session-1".to_string(),
            harness: "claude".to_string(),
            model_tier: "opus".to_string(),
            skills: vec!["rust".to_string(), "ci-mirror".to_string()],
            machine: Some("test-host".to_string()),
            gpu: None,
            ip: None,
            started_at: Utc::now(),
            heartbeat_at: Utc::now(),
            ttl_seconds: DEFAULT_TTL_SECONDS,
        };
        let json = serde_json::to_string(&m).expect("serialize");
        let back: CapabilityManifest = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(m, back);
    }

    #[test]
    fn is_alive_within_ttl() {
        let now = Utc::now();
        let m = CapabilityManifest {
            schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
            session_id: "x".to_string(),
            harness: "manual".to_string(),
            model_tier: "unknown".to_string(),
            skills: vec![],
            machine: None,
            gpu: None,
            ip: None,
            started_at: now,
            heartbeat_at: now,
            ttl_seconds: 300,
        };
        assert!(m.is_alive(now));
        // 200 seconds in the future is still within TTL=300
        let later = now + chrono::Duration::seconds(200);
        assert!(m.is_alive(later));
        // 400 seconds in the future is past TTL=300
        let way_later = now + chrono::Duration::seconds(400);
        assert!(!m.is_alive(way_later));
    }

    #[test]
    fn hardware_fields_default_absent() {
        // current_manifest() with no env opt-in should have no hardware
        std::env::remove_var("CHUMP_PUBLISH_HARDWARE");
        let m = current_manifest(vec!["test".to_string()]);
        assert_eq!(
            m.gpu, None,
            "gpu should be absent without CHUMP_PUBLISH_HARDWARE=1"
        );
        assert_eq!(
            m.ip, None,
            "ip should be absent without CHUMP_PUBLISH_HARDWARE=1"
        );
        assert!(!m.has_hardware_fields());
    }
}
