//! RESILIENT-274 slice — Playbook Registry data structures.
//!
//! Maps an incoming `Signal` to a `Tier` (severity/response class) and a
//! concrete `Action` the fleet should take. This is the data-structure
//! layer only; wiring signals into the live dispatch path is a follow-up
//! gap.

use std::collections::HashMap;

/// A named signal the fleet can observe (ambient event kind, detector
/// output, etc.) that the playbook registry can route.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Signal(pub String);

impl Signal {
    pub fn new(name: impl Into<String>) -> Self {
        Signal(name.into())
    }
}

/// Severity/response class for a playbook entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// No action required beyond logging.
    Informational,
    /// Requires attention but not immediate operator involvement.
    Advisory,
    /// Requires an automated or curator-driven response.
    Actionable,
    /// Halt-class — requires operator escalation.
    Halt,
}

/// A single playbook entry: the tier a signal maps to plus the action text
/// describing what response to take.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaybookEntry {
    pub tier: Tier,
    pub action: String,
}

impl PlaybookEntry {
    pub fn new(tier: Tier, action: impl Into<String>) -> Self {
        PlaybookEntry {
            tier,
            action: action.into(),
        }
    }
}

/// Signal -> PlaybookEntry lookup table.
#[derive(Debug, Default)]
pub struct PlaybookRegistry {
    entries: HashMap<Signal, PlaybookEntry>,
}

impl PlaybookRegistry {
    pub fn new() -> Self {
        PlaybookRegistry {
            entries: HashMap::new(),
        }
    }

    pub fn insert(&mut self, signal: Signal, entry: PlaybookEntry) {
        self.entries.insert(signal, entry);
    }

    pub fn get_entry(&self, signal: &Signal) -> Option<&PlaybookEntry> {
        self.entries.get(signal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_lookup() {
        let mut registry = PlaybookRegistry::new();
        let signal = Signal::new("fleet_wedge");
        registry.insert(
            signal.clone(),
            PlaybookEntry::new(Tier::Actionable, "unstick queue"),
        );

        let found = registry.get_entry(&signal).expect("entry should exist");
        assert_eq!(found.tier, Tier::Actionable);
        assert_eq!(found.action, "unstick queue");

        let missing = registry.get_entry(&Signal::new("unknown_signal"));
        assert!(missing.is_none());
    }
}
