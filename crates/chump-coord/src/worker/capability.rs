//! Worker capability adapter (INFRA-2002 / META-107 sub-gap #6).
//!
//! `WorkerCapability` is the runtime view of "what this worker process can
//! pick" — distinct from [`crate::capability::CapabilityManifest`] which is
//! the wire-format published into NATS KV for cross-fleet visibility
//! (INFRA-1760, chump-capability-v1 schema).
//!
//! ## Why a separate struct
//!
//! The wire manifest has TTL / hardware / serde semantics tuned for KV
//! storage; the per-cycle pickability question is much smaller — "given
//! `gap.skills_required`, `gap.preferred_machine`, `gap.preferred_backend`,
//! does this worker match?". Keeping it small means the loop body never
//! needs to deserialize a full manifest just to filter the next gap.
//!
//! ## Phase 1 scope
//!
//! - Build `WorkerCapability` from env (`WORKER_SKILLS`, `WORKER_MACHINE`,
//!   `WORKER_BACKEND`).
//! - Provide `matches(&GapRow)` for picker filtering.
//! - Provide `to_manifest()` adapter for future KV publish (deferred per the
//!   Phase 1 non-goals list in the gap description).
//!
//! Phase 2 (NOT in this PR): publish the manifest to the
//! `chump_capabilities` KV bucket, heartbeat refresh, presence query API.

use crate::capability::{CapabilityManifest, CAPABILITY_SCHEMA_VERSION, DEFAULT_TTL_SECONDS};
use chrono::Utc;
use chump_gap_store::GapRow;
use serde::{Deserialize, Serialize};
use std::env;

/// Per-worker capability view used by [`crate::worker::loop_body`].
///
/// Skills are matched against `gap.skills_required`; machine against
/// `gap.preferred_machine`; backend against `gap.preferred_backend`.
/// Empty / `"any"` values match unconditionally.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerCapability {
    /// Free-form capability tags. Examples: "rust", "shell", "python".
    /// Sourced from `WORKER_SKILLS` (comma-separated). Empty = no skill filter.
    pub skills: Vec<String>,
    /// Machine identifier. Sourced from `WORKER_MACHINE`.
    /// `None` or `"any"` matches all `preferred_machine` values.
    pub machine: Option<String>,
    /// Backend identifier. Sourced from `WORKER_BACKEND`.
    /// `None` or `"any"` matches all `preferred_backend` values.
    pub backend: Option<String>,
    /// Session ID this capability is attached to (for manifest publish).
    pub session_id: String,
}

impl WorkerCapability {
    /// Build a `WorkerCapability` from environment variables.
    ///
    /// Falls back to "no filter" (empty skills, no machine, no backend) when
    /// env vars are absent — which matches the legacy `worker.sh` behavior of
    /// claiming any pickable gap.
    pub fn from_env(session_id: impl Into<String>) -> Self {
        let skills = env::var("WORKER_SKILLS")
            .ok()
            .map(|s| {
                s.split(',')
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let machine = env::var("WORKER_MACHINE")
            .ok()
            .filter(|s| !s.is_empty() && s != "any");
        let backend = env::var("WORKER_BACKEND")
            .ok()
            .filter(|s| !s.is_empty() && s != "any");
        Self {
            skills,
            machine,
            backend,
            session_id: session_id.into(),
        }
    }

    /// Picker filter: does this worker match the gap's preferred routing?
    ///
    /// Match rules (all must hold):
    /// - If `gap.skills_required` is non-empty, at least one skill in
    ///   `self.skills` must appear in the gap's required list. If the
    ///   worker has no skills configured, the gap must also have no skill
    ///   requirement (conservative: don't claim a skill-tagged gap blindly).
    /// - If `gap.preferred_machine` is set, it must equal `self.machine`
    ///   (or be `"any"`).
    /// - If `gap.preferred_backend` is set, it must equal `self.backend`
    ///   (or be `"any"`).
    pub fn matches(&self, gap: &GapRow) -> bool {
        // Skills: parse comma-separated string from gap.
        let gap_skills: Vec<String> = gap
            .skills_required
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if !gap_skills.is_empty() {
            if self.skills.is_empty() {
                return false;
            }
            let has_match = gap_skills.iter().any(|gs| self.skills.contains(gs));
            if !has_match {
                return false;
            }
        }

        // Machine: gap.preferred_machine must match self.machine (or "any" / empty).
        let pm = gap.preferred_machine.trim();
        if !pm.is_empty() && pm != "any" {
            match self.machine.as_deref() {
                Some(m) if m == pm => {}
                _ => return false,
            }
        }

        // Backend: gap.preferred_backend must match self.backend (or "any" / empty).
        let pb = gap.preferred_backend.trim();
        if !pb.is_empty() && pb != "any" {
            match self.backend.as_deref() {
                Some(b) if b == pb => {}
                _ => return false,
            }
        }

        true
    }

    /// Build a `CapabilityManifest` wire-format view of this capability.
    /// Used by the (deferred) KV publish path; included here so callers
    /// have one struct to thread through the worker loop.
    pub fn to_manifest(&self) -> CapabilityManifest {
        let now = Utc::now();
        CapabilityManifest {
            schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
            session_id: self.session_id.clone(),
            harness: env::var("CHUMP_AGENT_HARNESS").unwrap_or_else(|_| "manual".to_string()),
            model_tier: env::var("FLEET_MODEL").unwrap_or_else(|_| "unknown".to_string()),
            skills: self.skills.clone(),
            machine: self.machine.clone(),
            gpu: None,
            ip: None,
            started_at: now,
            heartbeat_at: now,
            ttl_seconds: DEFAULT_TTL_SECONDS,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chump_gap_store::GapRow;

    fn gap_with(skills: &str, machine: &str, backend: &str) -> GapRow {
        GapRow {
            id: "INFRA-TEST".to_string(),
            domain: "INFRA".to_string(),
            title: "test gap".to_string(),
            description: String::new(),
            priority: "P1".to_string(),
            effort: "s".to_string(),
            status: "open".to_string(),
            acceptance_criteria: "[]".to_string(),
            depends_on: String::new(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: None,
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: None,
            skills_required: skills.to_string(),
            preferred_backend: backend.to_string(),
            preferred_machine: machine.to_string(),
            estimated_minutes: String::new(),
            required_model: String::new(),
        }
    }

    #[test]
    fn empty_worker_matches_unconstrained_gap() {
        let w = WorkerCapability {
            skills: vec![],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
        };
        let g = gap_with("", "", "");
        assert!(w.matches(&g));
    }

    #[test]
    fn empty_worker_skips_skill_tagged_gap() {
        let w = WorkerCapability {
            skills: vec![],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
        };
        let g = gap_with("rust", "", "");
        assert!(
            !w.matches(&g),
            "no-skill worker must not claim skill-tagged gap"
        );
    }

    #[test]
    fn skill_match_required() {
        let w = WorkerCapability {
            skills: vec!["python".to_string()],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
        };
        let g = gap_with("rust", "", "");
        assert!(!w.matches(&g), "python worker must not match rust gap");
        let g2 = gap_with("rust,python", "", "");
        assert!(
            w.matches(&g2),
            "python worker matches multi-skill gap with python"
        );
    }

    #[test]
    fn machine_filter_respected() {
        let w = WorkerCapability {
            skills: vec![],
            machine: Some("macbook".to_string()),
            backend: None,
            session_id: "s".to_string(),
        };
        let g = gap_with("", "rpi", "");
        assert!(!w.matches(&g));
        let g2 = gap_with("", "macbook", "");
        assert!(w.matches(&g2));
        let g3 = gap_with("", "any", "");
        assert!(w.matches(&g3));
    }

    #[test]
    fn from_env_parses_comma_skills() {
        std::env::set_var("WORKER_SKILLS", "rust, shell , python");
        std::env::set_var("WORKER_MACHINE", "rpi");
        std::env::remove_var("WORKER_BACKEND");
        let w = WorkerCapability::from_env("s1");
        assert_eq!(
            w.skills,
            vec![
                "rust".to_string(),
                "shell".to_string(),
                "python".to_string()
            ]
        );
        assert_eq!(w.machine.as_deref(), Some("rpi"));
        assert_eq!(w.backend, None);
        std::env::remove_var("WORKER_SKILLS");
        std::env::remove_var("WORKER_MACHINE");
    }

    #[test]
    fn to_manifest_round_trip() {
        let w = WorkerCapability {
            skills: vec!["rust".to_string()],
            machine: Some("m".to_string()),
            backend: None,
            session_id: "sess-1".to_string(),
        };
        let m = w.to_manifest();
        assert_eq!(m.schema_version, CAPABILITY_SCHEMA_VERSION);
        assert_eq!(m.session_id, "sess-1");
        assert_eq!(m.skills, vec!["rust".to_string()]);
        assert_eq!(m.machine.as_deref(), Some("m"));
    }
}
