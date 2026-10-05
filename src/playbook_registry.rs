//! Playbook Registry loading from JSON (RESILIENT-274 slice, RESILIENT-443).
//!
//! Loads a `PlaybookRegistry` (signal -> tier -> action map) from a JSON
//! file on disk, matching the schema described in
//! `docs/design/DUTY_OFFICER.md` §3. See also `duty_officer::Signal`/`Tier`
//! for the raw-signal evaluation side of the same design.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Deserializer};

/// Response tier a signal's playbook entry is routed to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// T1 — deterministic auto-heal, no agent or operator involved.
    AutoHeal = 1,
    /// T2 — agent-run runbook after a reality-check gate.
    Runbook = 2,
    /// T3 — escalate to the operator through the quiet gate.
    Escalate = 3,
}

impl<'de> Deserialize<'de> for Tier {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        match u8::deserialize(deserializer)? {
            1 => Ok(Tier::AutoHeal),
            2 => Ok(Tier::Runbook),
            3 => Ok(Tier::Escalate),
            other => Err(serde::de::Error::custom(format!(
                "invalid tier {other}: expected 1 (AutoHeal), 2 (Runbook), or 3 (Escalate)"
            ))),
        }
    }
}

/// A single registry entry: the tier a signal maps to, plus its action.
#[derive(Debug, Clone, Deserialize)]
pub struct PlaybookEntry {
    pub signal: String,
    pub tier: Tier,
    pub action: String,
    #[serde(default)]
    pub detect: Option<String>,
    #[serde(default)]
    pub verify: Option<String>,
    #[serde(default)]
    pub false_positive_class: Option<String>,
}

/// Registry of `signal` -> `PlaybookEntry` lookups, loaded from JSON.
#[derive(Debug, Default)]
pub struct PlaybookRegistry {
    entries: HashMap<String, PlaybookEntry>,
}

impl PlaybookRegistry {
    /// Looks up the playbook entry for a given signal name, if registered.
    pub fn get_entry(&self, signal: &str) -> Option<&PlaybookEntry> {
        self.entries.get(signal)
    }

    /// Number of entries in the registry.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True if the registry has no entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// Loads a `PlaybookRegistry` from a JSON file at `path`.
///
/// The file must contain a JSON array of playbook entries, each with at
/// least `signal`, `tier` (1, 2, or 3), and `action` fields. Returns a
/// clear, contextual error if the file is missing or the JSON is malformed.
pub fn load_registry(path: &Path) -> Result<PlaybookRegistry> {
    let raw = fs::read_to_string(path)
        .with_context(|| format!("failed to read playbook registry file: {}", path.display()))?;

    let parsed: Vec<PlaybookEntry> = serde_json::from_str(&raw).with_context(|| {
        format!(
            "malformed playbook registry JSON in {}: expected an array of {{signal, tier, action}} entries",
            path.display()
        )
    })?;

    let mut entries = HashMap::with_capacity(parsed.len());
    for entry in parsed {
        entries.insert(entry.signal.clone(), entry);
    }

    Ok(PlaybookRegistry { entries })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn load_registry_reads_entries() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(
            file,
            r#"[
                {{"signal": "disk_critical", "tier": 1, "action": "scripts/coord/disk-cleanup.sh"}},
                {{"signal": "pr_pipeline_wedged", "tier": 2, "action": "diagnose the blocking check"}}
            ]"#
        )
        .unwrap();

        let registry = load_registry(file.path()).expect("valid registry JSON should load");
        assert_eq!(registry.len(), 2);

        let entry = registry
            .get_entry("disk_critical")
            .expect("disk_critical entry must exist");
        assert_eq!(entry.tier, Tier::AutoHeal);
        assert_eq!(entry.action, "scripts/coord/disk-cleanup.sh");

        assert!(registry.get_entry("nonexistent_signal").is_none());
    }

    #[test]
    fn load_registry_fails_on_malformed_json() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(file, "{{ not valid json").unwrap();

        let err = load_registry(file.path()).expect_err("malformed JSON must fail");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("malformed playbook registry JSON"),
            "error should explain the failure clearly, got: {msg}"
        );
    }

    /// Integration test (RESILIENT-443 AC3): loads the real fixture file and
    /// asserts the expected entries come back. This crate ships as a binary
    /// only (no `src/lib.rs`), so `tests/*.rs` cannot import this module
    /// directly; this in-crate test exercises `load_registry` against the
    /// on-disk fixture the same way an external integration test would.
    #[test]
    fn load_registry_reads_fixture_file() {
        let fixture =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/registry_example.json");

        let registry = load_registry(&fixture).expect("fixture registry should load");
        assert_eq!(registry.len(), 3);

        let disk_critical = registry
            .get_entry("disk_critical")
            .expect("disk_critical entry must exist");
        assert_eq!(disk_critical.tier, Tier::AutoHeal);
        assert_eq!(
            disk_critical.action,
            "scripts/coord/disk-critical-reactor.sh"
        );

        let wedged = registry
            .get_entry("pr_pipeline_wedged")
            .expect("pr_pipeline_wedged entry must exist");
        assert_eq!(wedged.tier, Tier::Runbook);

        let auth_dead = registry
            .get_entry("farmer_auth_dead")
            .expect("farmer_auth_dead entry must exist");
        assert_eq!(auth_dead.tier, Tier::Escalate);
        assert_eq!(
            auth_dead.false_positive_class.as_deref(),
            Some("known #1 false-positive (CREDIBLE-090); mis-called 4x")
        );
    }

    #[test]
    fn load_registry_fails_on_missing_file() {
        let err = load_registry(Path::new("/nonexistent/path/registry.json"))
            .expect_err("missing file must fail");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("failed to read playbook registry file"),
            "error should explain the failure clearly, got: {msg}"
        );
    }
}
