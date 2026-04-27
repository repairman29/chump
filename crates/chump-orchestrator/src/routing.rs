//! COG-035 — dispatch router v1: hand-tuned `routing.yaml` + `Vec<Candidate>` cascade.
//!
//! Replaces the 2-rule heuristic in [`crate::dispatch::select_backend_for_gap`]
//! with a YAML-driven routing table that returns an **ordered list of
//! candidates** so the orchestrator can cascade across providers/models on
//! rate-limits, tool-storms, or transient failures.
//!
//! ## Design progression
//!
//! - **COG-035 (this file)** — hand-tuned `docs/dispatch/routing.yaml`. First
//!   matching route wins; `default_candidates` is the fallback.
//! - **COG-036 (next)** — replace the YAML source with a scoreboard table
//!   computed from reflection telemetry.
//! - **COG-037 (later)** — Thompson-sampling self-learner. The
//!   [`Candidate`] struct shape is stable across all three; only the source
//!   of the candidate list changes.
//!
//! ## File-missing behavior
//!
//! [`RoutingTable::load`] returns a hardcoded fallback table when
//! `docs/dispatch/routing.yaml` is missing — equivalent to the pre-COG-035
//! heuristic. This keeps the dispatcher functional in tempdirs and on machines
//! that haven't synced docs yet. Malformed YAML returns `Err` (drift should
//! be loud per INFRA-143 convention).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::dispatch::DispatchBackend;

/// One ordered choice in a routing cascade. The orchestrator tries
/// candidates in list order on rate-limits / tool-storms / failures.
///
/// Shape is stable across COG-035/036/037 — only the *source* of the list
/// changes (YAML → scoreboard → Thompson sampler).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Candidate {
    /// Which subagent binary the spawner forks.
    #[serde(deserialize_with = "de_backend", serialize_with = "ser_backend")]
    pub backend: DispatchBackend,
    /// Provider model id (e.g. `openai/gpt-oss-120b`). `None` for the
    /// `claude` backend, which selects its own model via the Anthropic CLI.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Provider prefix label (`TOGETHER`, `GROQ`, …) used for log + telemetry
    /// disambiguation. `None` for the `claude` backend.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_pfx: Option<String>,
    /// One-line rationale captured in dispatch logs and (eventually)
    /// reflection rows.
    pub why: String,
}

fn de_backend<'de, D>(d: D) -> std::result::Result<DispatchBackend, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let s = String::deserialize(d)?;
    match s.as_str() {
        "claude" => Ok(DispatchBackend::Claude),
        "chump-local" | "chump_local" | "local" => Ok(DispatchBackend::ChumpLocal),
        other => Err(serde::de::Error::custom(format!(
            "unknown backend {other:?} (valid: claude | chump-local)"
        ))),
    }
}

fn ser_backend<S>(b: &DispatchBackend, s: S) -> std::result::Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    s.serialize_str(b.label())
}

/// One or more strings — accepts either `effort: xs` or `effort: [l, xl]`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
enum StringOrList {
    One(String),
    Many(Vec<String>),
}

impl StringOrList {
    fn matches(&self, value: &str) -> bool {
        let needle = value.trim().to_ascii_lowercase();
        match self {
            StringOrList::One(s) => s.trim().eq_ignore_ascii_case(&needle),
            StringOrList::Many(list) => list.iter().any(|s| s.trim().eq_ignore_ascii_case(&needle)),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
struct MatchSpec {
    #[serde(default)]
    priority: Option<StringOrList>,
    #[serde(default)]
    effort: Option<StringOrList>,
    #[serde(default)]
    task_class: Option<StringOrList>,
}

impl MatchSpec {
    /// All-match semantics: every present field must match. Absent fields
    /// are ignored (don't constrain).
    fn matches(&self, priority: &str, effort: &str, task_class: Option<&str>) -> bool {
        if let Some(p) = &self.priority {
            if !p.matches(priority) {
                return false;
            }
        }
        if let Some(e) = &self.effort {
            if !e.matches(effort) {
                return false;
            }
        }
        if let Some(tc) = &self.task_class {
            // task_class match requires a value to compare against; if the
            // caller passed None, a task_class constraint cannot match.
            match task_class {
                Some(v) => {
                    if !tc.matches(v) {
                        return false;
                    }
                }
                None => return false,
            }
        }
        true
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct Route {
    #[serde(default)]
    r#match: MatchSpec,
    #[serde(default)]
    why: String,
    candidates: Vec<Candidate>,
}

/// Parsed routing table. First matching route wins; `default_candidates`
/// returns when no route matches.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RoutingTable {
    #[serde(default)]
    default_candidates: Vec<Candidate>,
    #[serde(default)]
    routes: Vec<Route>,
}

impl RoutingTable {
    /// Path the loader probes — `<repo_root>/docs/dispatch/routing.yaml`.
    pub fn yaml_path(repo_root: &Path) -> std::path::PathBuf {
        repo_root.join("docs").join("dispatch").join("routing.yaml")
    }

    /// Load from `<repo_root>/docs/dispatch/routing.yaml`.
    ///
    /// - Missing file → hardcoded fallback equivalent to the pre-COG-035
    ///   heuristic (so the dispatcher works in tempdirs and on machines
    ///   without the YAML).
    /// - Malformed YAML → `Err` (drift should be loud per INFRA-143).
    pub fn load(repo_root: &Path) -> Result<Self> {
        let path = Self::yaml_path(repo_root);
        if !path.exists() {
            return Ok(Self::hardcoded_fallback());
        }
        let text = std::fs::read_to_string(&path)
            .with_context(|| format!("reading routing table at {}", path.display()))?;
        let parsed: RoutingTable = serde_yaml::from_str(&text)
            .with_context(|| format!("parsing YAML at {}", path.display()))?;
        Ok(parsed)
    }

    /// Hardcoded fallback equivalent to [`crate::dispatch::select_backend_for_gap`]
    /// from before COG-035. Returned by [`Self::load`] when the YAML is missing.
    pub fn hardcoded_fallback() -> Self {
        let route_xs = Route {
            r#match: MatchSpec {
                effort: Some(StringOrList::One("xs".into())),
                ..Default::default()
            },
            why: "effort=xs → cheap tier (trivial codemod-class)".into(),
            candidates: vec![Candidate {
                backend: DispatchBackend::ChumpLocal,
                model: None,
                provider_pfx: None,
                why: "effort=xs → cheap tier (trivial codemod-class)".into(),
            }],
        };
        let route_p1_large = Route {
            r#match: MatchSpec {
                priority: Some(StringOrList::One("P1".into())),
                effort: Some(StringOrList::Many(vec!["l".into(), "xl".into()])),
                ..Default::default()
            },
            why: "priority=P1 + effort>=l → frontier (high-stakes large work)".into(),
            candidates: vec![Candidate {
                backend: DispatchBackend::Claude,
                model: None,
                provider_pfx: None,
                why: "priority=P1 + effort>=l → frontier (high-stakes large work)".into(),
            }],
        };
        let default_candidates = vec![Candidate {
            backend: DispatchBackend::ChumpLocal,
            model: None,
            provider_pfx: None,
            why: "default → cheap tier (override via CHUMP_DISPATCH_BACKEND=claude)".into(),
        }];
        RoutingTable {
            default_candidates,
            routes: vec![route_xs, route_p1_large],
        }
    }

    /// Build the candidate list for a gap. Walks routes in declaration
    /// order, returns the first match's candidates, or `default_candidates`
    /// if no route matches.
    ///
    /// `task_class` is derived by the caller (typically gap-id prefix →
    /// `Some("research")` for EVAL-/RESEARCH-, `None` otherwise).
    pub fn select(&self, priority: &str, effort: &str, task_class: Option<&str>) -> Vec<Candidate> {
        for r in &self.routes {
            if r.r#match.matches(priority, effort, task_class) {
                return r.candidates.clone();
            }
        }
        self.default_candidates.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_yaml(dir: &Path, body: &str) -> std::path::PathBuf {
        let docs = dir.join("docs").join("dispatch");
        std::fs::create_dir_all(&docs).unwrap();
        let path = docs.join("routing.yaml");
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(body.as_bytes()).unwrap();
        path
    }

    const SAMPLE: &str = r#"
default_candidates:
  - { backend: chump-local, model: meta-llama/Llama-3.3-70B-Instruct-Turbo-Free, provider_pfx: TOGETHER, why: free-tier-default }
  - { backend: chump-local, model: openai/gpt-oss-120b, provider_pfx: GROQ, why: groq-fallback }
  - { backend: claude, why: frontier-fallback }

routes:
  - match: { effort: xs }
    why: trivial codemod-class — fast cheap models suffice
    candidates:
      - { backend: chump-local, model: openai/gpt-oss-120b, provider_pfx: GROQ, why: groq-fast-cheap }
      - { backend: chump-local, model: meta-llama/Llama-3.3-70B-Instruct-Turbo-Free, provider_pfx: TOGETHER, why: together-free-fallback }

  - match: { priority: P1, effort: [l, xl] }
    why: high-stakes large work needs frontier reasoning
    candidates:
      - { backend: claude, why: frontier-only }

  - match: { task_class: research }
    why: EVAL/RESEARCH gaps require correctness — no free-tier risk
    candidates:
      - { backend: claude, why: research-needs-frontier }
"#;

    #[test]
    fn routing_table_loads_from_yaml() {
        let dir = tempfile::tempdir().unwrap();
        write_yaml(dir.path(), SAMPLE);
        let table = RoutingTable::load(dir.path()).expect("load ok");
        assert_eq!(table.default_candidates.len(), 3);
        assert_eq!(table.routes.len(), 3);
    }

    #[test]
    fn select_xs_returns_groq_first() {
        let dir = tempfile::tempdir().unwrap();
        write_yaml(dir.path(), SAMPLE);
        let table = RoutingTable::load(dir.path()).unwrap();
        let cands = table.select("P2", "xs", None);
        assert!(!cands.is_empty(), "expected candidates for xs");
        let first = &cands[0];
        assert_eq!(first.backend, DispatchBackend::ChumpLocal);
        assert_eq!(first.provider_pfx.as_deref(), Some("GROQ"));
        assert_eq!(first.model.as_deref(), Some("openai/gpt-oss-120b"));
    }

    #[test]
    fn select_p1_xl_returns_claude() {
        let dir = tempfile::tempdir().unwrap();
        write_yaml(dir.path(), SAMPLE);
        let table = RoutingTable::load(dir.path()).unwrap();
        let cands = table.select("P1", "xl", None);
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].backend, DispatchBackend::Claude);
        // Also covers the list-form effort match (l).
        let cands_l = table.select("P1", "l", None);
        assert_eq!(cands_l[0].backend, DispatchBackend::Claude);
    }

    #[test]
    fn select_research_class_returns_claude() {
        let dir = tempfile::tempdir().unwrap();
        write_yaml(dir.path(), SAMPLE);
        let table = RoutingTable::load(dir.path()).unwrap();
        let cands = table.select("P2", "m", Some("research"));
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].backend, DispatchBackend::Claude);
        assert!(cands[0].why.contains("research"));
    }

    #[test]
    fn select_fallback_when_no_match() {
        let dir = tempfile::tempdir().unwrap();
        write_yaml(dir.path(), SAMPLE);
        let table = RoutingTable::load(dir.path()).unwrap();
        // P2 + m + no task_class — none of the three routes should match.
        let cands = table.select("P2", "m", None);
        assert_eq!(cands.len(), 3, "default_candidates returned");
        assert_eq!(cands[0].backend, DispatchBackend::ChumpLocal);
        assert_eq!(cands[0].provider_pfx.as_deref(), Some("TOGETHER"));
        assert_eq!(cands[2].backend, DispatchBackend::Claude);
    }

    #[test]
    fn load_missing_file_returns_fallback() {
        // Empty tempdir — no docs/dispatch/routing.yaml.
        let dir = tempfile::tempdir().unwrap();
        let table = RoutingTable::load(dir.path()).expect("missing file → fallback ok");
        // Hardcoded fallback always has at least one default candidate.
        assert!(!table.default_candidates.is_empty());
        // Fallback xs route routes to ChumpLocal.
        let cands = table.select("P2", "xs", None);
        assert_eq!(cands[0].backend, DispatchBackend::ChumpLocal);
        // Fallback P1+l route routes to Claude.
        let cands = table.select("P1", "l", None);
        assert_eq!(cands[0].backend, DispatchBackend::Claude);
        // Default for a P2/m matches default_candidates.
        let cands = table.select("P2", "m", None);
        assert_eq!(cands[0].backend, DispatchBackend::ChumpLocal);
    }

    #[test]
    fn load_malformed_yaml_returns_err() {
        let dir = tempfile::tempdir().unwrap();
        // `routes:` must be a list; passing a scalar should fail YAML parsing
        // at the structural level.
        write_yaml(dir.path(), "routes: not-a-list\n");
        let err = RoutingTable::load(dir.path()).expect_err("malformed YAML must fail");
        let msg = format!("{err:#}");
        assert!(
            msg.to_lowercase().contains("yaml") || msg.to_lowercase().contains("parsing"),
            "expected YAML/parse error, got: {msg}"
        );
    }

    #[test]
    fn match_priority_and_effort_are_case_insensitive() {
        let dir = tempfile::tempdir().unwrap();
        write_yaml(dir.path(), SAMPLE);
        let table = RoutingTable::load(dir.path()).unwrap();
        // "XS" should still hit the xs route.
        let cands = table.select("P2", "XS", None);
        assert_eq!(cands[0].provider_pfx.as_deref(), Some("GROQ"));
    }

    #[test]
    fn unknown_backend_in_yaml_fails_loudly() {
        let dir = tempfile::tempdir().unwrap();
        write_yaml(
            dir.path(),
            "default_candidates:\n  - { backend: ollama-direct, why: nope }\nroutes: []\n",
        );
        let err = RoutingTable::load(dir.path()).expect_err("unknown backend should fail");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("ollama-direct") || msg.to_lowercase().contains("backend"),
            "expected backend-rejection error, got: {msg}"
        );
    }
}
