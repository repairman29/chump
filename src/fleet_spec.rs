//! INFRA-1483: declarative `chump.fleet.yaml` spec primitive (Marcus M-B).
//!
//! Marcus's interview quote (2026-05-15):
//! > "I don't want to type 40 different prompts. I want to write one
//! > architectural instruction in a markdown-like spec file, define the
//! > variables, and tell Chump how to fan out."
//!
//! This module implements that primitive. The operator commits a
//! `chump.fleet.yaml` into their repo:
//!
//! ```yaml
//! name: rust-fmt-sweep
//! intent: |
//!   For each Rust file listed below, run cargo fmt + cargo clippy --fix,
//!   commit the result with a Style: trailer. No cross-file refactors.
//! parameters:
//!   - name: file
//!     values:
//!       - src/foo.rs
//!       - src/bar.rs
//!       - src/baz.rs
//! validation: cargo fmt --check && cargo clippy -- -D warnings
//! success: file is clippy-clean and committed
//! ```
//!
//! `chump fleet plan <spec>` shows the gap set it WOULD reserve (dry-run).
//! `chump fleet apply <spec>` reserves the gap set in state.db.
//! `chump fleet spec-status <name>` aggregates per-instance progress.
//!
//! All gaps reserved by a single spec share `spec_name=<name>` in notes so
//! status aggregation is a single state.db query.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Parsed fleet-spec YAML.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FleetSpec {
    /// Unique name (e.g. `rust-fmt-sweep`). Used as the spec-status key.
    pub name: String,
    /// Markdown block describing what each instance should accomplish.
    pub intent: String,
    /// Variables to fan out across — Cartesian product when multiple.
    pub parameters: Vec<FleetParam>,
    /// Per-instance validation shell command (run inside the gap's worktree).
    pub validation: String,
    /// Per-instance success criteria (operator-readable; goes into gap AC).
    pub success: String,
    /// Default effort tier for reserved gaps (defaults to "s").
    #[serde(default = "default_effort")]
    pub effort: String,
    /// Default domain for reserved gaps (defaults to "INFRA").
    #[serde(default = "default_domain")]
    pub domain: String,
}

fn default_effort() -> String {
    "s".to_string()
}

fn default_domain() -> String {
    "INFRA".to_string()
}

/// One parameter dimension. The cartesian product across all parameters
/// determines the gap count.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FleetParam {
    /// Variable name (referenced from intent as `{name}`).
    pub name: String,
    /// Values the variable can take.
    pub values: Vec<String>,
}

/// One materialized gap-to-be-reserved (output of `plan`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlannedGap {
    pub title: String,
    pub intent: String,
    pub validation: String,
    pub success: String,
    pub effort: String,
    pub domain: String,
    pub spec_name: String,
    /// The parameter-binding for this instance (name → value).
    pub bindings: Vec<(String, String)>,
}

impl FleetSpec {
    /// Parse from YAML text.
    pub fn from_yaml(text: &str) -> Result<Self, String> {
        serde_yaml::from_str(text).map_err(|e| format!("invalid fleet-spec YAML: {e}"))
    }

    /// Load from a path.
    pub fn from_path(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("read {}: {e}", path.display()))?;
        Self::from_yaml(&text)
    }

    /// Expand parameters into one PlannedGap per cartesian product instance.
    pub fn plan(&self) -> Vec<PlannedGap> {
        let combos = cartesian(&self.parameters);
        combos
            .into_iter()
            .map(|bindings| {
                let title = format_one(&format!("{}: {}", self.name, bind_summary(&bindings)), &bindings);
                let intent = format_one(&self.intent, &bindings);
                PlannedGap {
                    title,
                    intent,
                    validation: self.validation.clone(),
                    success: self.success.clone(),
                    effort: self.effort.clone(),
                    domain: self.domain.clone(),
                    spec_name: self.name.clone(),
                    bindings,
                }
            })
            .collect()
    }
}

/// Cartesian product of all parameter values.
fn cartesian(params: &[FleetParam]) -> Vec<Vec<(String, String)>> {
    if params.is_empty() {
        return vec![vec![]];
    }
    let mut acc: Vec<Vec<(String, String)>> = vec![vec![]];
    for p in params {
        let mut next = Vec::with_capacity(acc.len() * p.values.len());
        for combo in &acc {
            for v in &p.values {
                let mut new_combo = combo.clone();
                new_combo.push((p.name.clone(), v.clone()));
                next.push(new_combo);
            }
        }
        acc = next;
    }
    acc
}

/// Substitute `{name}` placeholders in a template.
fn format_one(template: &str, bindings: &[(String, String)]) -> String {
    let mut out = template.to_string();
    for (k, v) in bindings {
        out = out.replace(&format!("{{{k}}}"), v);
    }
    out
}

/// Human-readable summary of a parameter binding for titles.
fn bind_summary(bindings: &[(String, String)]) -> String {
    bindings
        .iter()
        .map(|(_, v)| v.as_str())
        .collect::<Vec<_>>()
        .join("/")
}

/// Render a plan as a human-readable table for `chump fleet plan`.
pub fn render_plan(plan: &[PlannedGap]) -> String {
    let mut out = String::new();
    out.push_str(&format!("=== fleet-spec plan: {} gap(s) ===\n\n", plan.len()));
    for (i, g) in plan.iter().enumerate() {
        out.push_str(&format!(
            "[{:>2}] {}\n     effort={} domain={}\n     bindings: {}\n     validation: {}\n     success:    {}\n\n",
            i + 1,
            g.title,
            g.effort,
            g.domain,
            g
                .bindings
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join(", "),
            g.validation,
            g.success
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
name: rust-fmt-sweep
intent: |
  Run cargo fmt on {file}. Commit the result.
parameters:
  - name: file
    values:
      - src/foo.rs
      - src/bar.rs
      - src/baz.rs
validation: cargo fmt --check
success: "{file} is clippy-clean"
"#;

    #[test]
    fn parses_minimal_spec() {
        let s = FleetSpec::from_yaml(SAMPLE).expect("parse");
        assert_eq!(s.name, "rust-fmt-sweep");
        assert_eq!(s.parameters.len(), 1);
        assert_eq!(s.parameters[0].values.len(), 3);
        assert_eq!(s.effort, "s"); // default
        assert_eq!(s.domain, "INFRA"); // default
    }

    #[test]
    fn plan_expands_single_param() {
        let s = FleetSpec::from_yaml(SAMPLE).expect("parse");
        let plan = s.plan();
        assert_eq!(plan.len(), 3);
        assert!(plan[0].intent.contains("src/foo.rs"));
        assert!(plan[0].success.contains("src/foo.rs"));
        assert_eq!(plan[0].spec_name, "rust-fmt-sweep");
        assert_eq!(plan[0].bindings, vec![("file".to_string(), "src/foo.rs".to_string())]);
    }

    #[test]
    fn plan_cartesian_two_params() {
        let yaml = r#"
name: dep-bump-matrix
intent: "Bump {dep} to {version}"
parameters:
  - name: dep
    values: [tokio, serde]
  - name: version
    values: ["1.0", "1.1"]
validation: cargo build
success: "{dep}@{version} builds"
"#;
        let s = FleetSpec::from_yaml(yaml).expect("parse");
        let plan = s.plan();
        assert_eq!(plan.len(), 4); // 2 × 2
        let titles: Vec<_> = plan.iter().map(|g| g.title.clone()).collect();
        assert!(titles.iter().any(|t| t.contains("tokio") && t.contains("1.0")));
        assert!(titles.iter().any(|t| t.contains("serde") && t.contains("1.1")));
    }

    #[test]
    fn empty_parameters_yields_one_gap() {
        let yaml = r#"
name: singleton
intent: "do the thing"
parameters: []
validation: "true"
success: "done"
"#;
        let s = FleetSpec::from_yaml(yaml).expect("parse");
        let plan = s.plan();
        assert_eq!(plan.len(), 1);
    }

    #[test]
    fn malformed_yaml_returns_error() {
        let err = FleetSpec::from_yaml("not yaml at all: : :").unwrap_err();
        assert!(err.contains("fleet-spec"));
    }

    #[test]
    fn placeholder_substitution_idempotent() {
        let yaml = r#"
name: t
intent: "{x}{x}{x}"
parameters:
  - name: x
    values: ["A"]
validation: "true"
success: "ok"
"#;
        let s = FleetSpec::from_yaml(yaml).expect("parse");
        let plan = s.plan();
        assert_eq!(plan[0].intent, "AAA");
    }
}
