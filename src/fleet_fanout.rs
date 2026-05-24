//! INFRA-1484: cross-repo fan-out from a single operator command (Marcus M-B).
//!
//! Marcus's interview quote (2026-05-15):
//! > "I point Chump to the core library change and give it a single test
//! > script that asserts successful data ingestion. The orchestrator
//! > automatically creates 12 isolated git worktrees on my local machine,
//! > maps the local Docker/environment contexts for each service, and
//! > drops one autonomous agent into each bucket."
//!
//! Where [`crate::fleet_spec`] fans out across a parameter list inside a
//! single repo, this module fans out across N **repos** for the same intent.
//! One repo = one reserved gap = one isolated worktree.
//!
//! Operator file (`chump.fanout.yaml`):
//!
//! ```yaml
//! name: shared-lib-bump
//! intent: |
//!   Bump shared-lib to v2.0 in this service. Run the service's existing
//!   integration suite. No cross-service refactors.
//! repos:
//!   - path: ../service-a
//!   - path: ../service-b
//!   - path: ../service-c
//! validation: ./scripts/test-integration.sh
//! success: integration suite passes after the bump
//! effort: m
//! domain: INFRA
//! ```
//!
//! Subcommands (wired in `main.rs`):
//! - `chump fanout plan <spec>` — dry-run; render the per-repo gap set.
//! - `chump fanout apply <spec>` — reserve one gap per repo via the existing
//!   chump CLI; record `fanout_group=<name>` + `target_repo=<path>` in notes
//!   so [`crate::fleet_fanout::aggregate_status`] can group them later.
//! - `chump fanout status <name>` — aggregate by fanout_group.
//!
//! Sandbox / env-isolation per-repo (AC#4) graceful-degrades in v1: we
//! **detect** docker-compose / .env presence per repo and surface it in the
//! plan output. Actual container isolation lands with INFRA-1454; until
//! then operators are responsible for their own port-namespace hygiene.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Parsed cross-repo fan-out spec.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FanoutSpec {
    /// Unique name (used as the fanout-group key in `chump fanout status`).
    pub name: String,
    /// Markdown block describing what each per-repo agent should accomplish.
    pub intent: String,
    /// One entry per target repo. Each becomes one reserved gap.
    pub repos: Vec<RepoTarget>,
    /// Per-repo validation shell command (runs inside the per-repo worktree).
    pub validation: String,
    /// Per-repo success criteria (operator-readable; goes into gap AC).
    pub success: String,
    /// Default effort tier for reserved gaps (defaults to "m" — cross-repo
    /// work is rarely xs/s).
    #[serde(default = "default_effort")]
    pub effort: String,
    /// Default domain for reserved gaps (defaults to "INFRA").
    #[serde(default = "default_domain")]
    pub domain: String,
    /// INFRA-1935: resolved commit SHA for --reference flag (Marcus M-B).
    /// Operator passes a commit SHA or PR-N; chump fanout resolves PR-N to
    /// merge commit SHA via REST (not GraphQL — fleet GraphQL is exhausted).
    /// Serialized into per-worktree agent dispatch payload.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
}

fn default_effort() -> String {
    "m".to_string()
}

fn default_domain() -> String {
    "INFRA".to_string()
}

/// One target repository. v1 supports local paths; remote `url:` is parsed
/// but `apply` will refuse with a clear "v1: clone the repo first" message.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RepoTarget {
    /// Local path (relative to the spec file's directory, or absolute).
    #[serde(default)]
    pub path: Option<String>,
    /// Remote URL — parsed but not auto-cloned in v1.
    #[serde(default)]
    pub url: Option<String>,
    /// Override label for the gap title; defaults to the basename of
    /// `path` (or the last segment of `url`).
    #[serde(default)]
    pub label: Option<String>,
}

/// One materialized gap-to-be-reserved, one per target repo.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlannedRepoGap {
    pub title: String,
    pub intent: String,
    pub validation: String,
    pub success: String,
    pub effort: String,
    pub domain: String,
    pub fanout_group: String,
    pub target_repo: String,
    pub repo_label: String,
    /// Env-isolation hints surfaced in v1 without acting on them — they
    /// fire when the target repo has a docker-compose.yml or .env file
    /// that the operator should be aware of when running concurrent
    /// worktrees. Lands as real container isolation under INFRA-1454.
    pub env_isolation_warnings: Vec<String>,
    /// INFRA-1935: resolved commit SHA from --reference flag, propagated
    /// per-worktree so each agent dispatch payload carries the reference.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
}

impl FanoutSpec {
    pub fn from_yaml(text: &str) -> Result<Self, String> {
        let parsed: FanoutSpec =
            serde_yaml::from_str(text).map_err(|e| format!("invalid fanout-spec YAML: {e}"))?;
        parsed.validate()?;
        Ok(parsed)
    }

    pub fn from_path(path: &Path) -> Result<Self, String> {
        let text =
            std::fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;
        Self::from_yaml(&text)
    }

    fn validate(&self) -> Result<(), String> {
        if self.name.trim().is_empty() {
            return Err("fanout-spec: name is required".to_string());
        }
        if self.repos.is_empty() {
            return Err("fanout-spec: repos list must have at least one entry".to_string());
        }
        for (i, r) in self.repos.iter().enumerate() {
            if r.path.is_none() && r.url.is_none() {
                return Err(format!(
                    "fanout-spec: repos[{i}] needs either `path:` or `url:`"
                ));
            }
        }
        Ok(())
    }

    /// Expand the spec into one PlannedRepoGap per target repo.
    /// `spec_dir` is the directory the spec file lived in — used to
    /// resolve relative `path:` entries.
    pub fn plan(&self, spec_dir: &Path) -> Vec<PlannedRepoGap> {
        self.repos
            .iter()
            .map(|r| {
                let resolved_path = r.path.as_ref().map(|p| {
                    let candidate = PathBuf::from(p);
                    if candidate.is_absolute() {
                        candidate
                    } else {
                        spec_dir.join(p)
                    }
                });
                let label = derive_label(r, resolved_path.as_deref());
                let target_repo = resolved_path
                    .as_ref()
                    .map(|p| p.to_string_lossy().to_string())
                    .or_else(|| r.url.clone())
                    .unwrap_or_else(|| "?".to_string());
                let env_warnings = detect_env_hints(resolved_path.as_deref());
                let title = format!("{}: {}", self.name, label);
                PlannedRepoGap {
                    title,
                    intent: self.intent.clone(),
                    validation: self.validation.clone(),
                    success: self.success.clone(),
                    effort: self.effort.clone(),
                    domain: self.domain.clone(),
                    fanout_group: self.name.clone(),
                    target_repo,
                    repo_label: label,
                    env_isolation_warnings: env_warnings,
                    reference: self.reference.clone(),
                }
            })
            .collect()
    }
}

fn derive_label(r: &RepoTarget, resolved_path: Option<&Path>) -> String {
    if let Some(l) = &r.label {
        return l.clone();
    }
    if let Some(p) = resolved_path {
        if let Some(b) = p.file_name() {
            return b.to_string_lossy().to_string();
        }
    }
    if let Some(u) = &r.url {
        return u
            .rsplit('/')
            .find(|s| !s.is_empty())
            .unwrap_or(u.as_str())
            .trim_end_matches(".git")
            .to_string();
    }
    "?".to_string()
}

/// V1 env-isolation hints (AC#4 graceful-degrade): peek at common files
/// that signal the operator will get port collisions if multiple worktrees
/// run their stacks concurrently. Does NOT mutate anything.
fn detect_env_hints(path: Option<&Path>) -> Vec<String> {
    let Some(p) = path else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for f in ["docker-compose.yml", "docker-compose.yaml", "compose.yml"] {
        if p.join(f).exists() {
            out.push(format!(
                "{f} present — concurrent fanout worktrees may collide on container ports until INFRA-1454 ships sandbox isolation"
            ));
            break;
        }
    }
    if p.join(".env").exists() {
        out.push(
            ".env present — operator-managed in v1; not auto-isolated per-worktree".to_string(),
        );
    }
    out
}

/// Render a plan as a human-readable table for `chump fanout plan`.
pub fn render_plan(plan: &[PlannedRepoGap]) -> String {
    let mut out = String::new();
    out.push_str(&format!("=== fanout plan: {} repo(s) ===\n\n", plan.len()));
    for (i, g) in plan.iter().enumerate() {
        out.push_str(&format!(
            "[{:>2}] {}\n     effort={} domain={}\n     target_repo: {}\n     validation:  {}\n     success:     {}\n",
            i + 1,
            g.title,
            g.effort,
            g.domain,
            g.target_repo,
            g.validation,
            g.success
        ));
        for w in &g.env_isolation_warnings {
            out.push_str(&format!("     ⚠ {w}\n"));
        }
        out.push('\n');
    }
    out
}

/// Build the `notes` string written into each reserved gap so
/// `chump fanout status` can aggregate by fanout_group and so the
/// downstream worker can locate `target_repo` to create its worktree.
pub fn build_gap_notes(g: &PlannedRepoGap) -> String {
    let mut s = format!(
        "fanout_group={}\\ntarget_repo={}\\nrepo_label={}\\nvalidation: {}\\nsuccess: {}",
        g.fanout_group, g.target_repo, g.repo_label, g.validation, g.success
    );
    for w in &g.env_isolation_warnings {
        s.push_str(&format!("\\nenv_hint: {w}"));
    }
    if let Some(r) = &g.reference {
        s.push_str(&format!("\\nreference: {r}"));
    }
    s
}

/// INFRA-1935: Render the agent dispatch prompt template.
///
/// Reads `scripts/dispatch/fanout-agent-prompt.md` from `repo_root`, then:
/// - If `reference_sha` is Some, substitutes `{{REFERENCE_DIFF}}` with the
///   actual `git diff <sha>^..<sha>` output (best-effort; empty string on
///   failure) and injects the "Reference implementation" section.
/// - If `reference_sha` is None, substitutes `{{REFERENCE_DIFF}}` with an
///   empty string so the today-path renders without the reference block.
///
/// Returns the populated template string, or an error if the template file
/// cannot be read.
pub fn render_agent_prompt(
    repo_root: &Path,
    reference_sha: Option<&str>,
) -> Result<String, String> {
    let template_path = repo_root.join("scripts/dispatch/fanout-agent-prompt.md");
    let template = std::fs::read_to_string(&template_path)
        .map_err(|e| format!("read {}: {e}", template_path.display()))?;

    let populated = match reference_sha {
        Some(sha) => {
            // Obtain the diff for this SHA via git. Best-effort: if git is
            // unavailable or the SHA doesn't resolve, we fall back to an
            // informational placeholder rather than hard-failing.
            let diff_output = std::process::Command::new("git")
                .args(["diff", &format!("{sha}^"), sha])
                .current_dir(repo_root)
                .output();
            let diff_text = match diff_output {
                Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
                Ok(o) => {
                    // git exited non-zero (e.g. SHA not found in this repo).
                    let stderr = String::from_utf8_lossy(&o.stderr);
                    format!("(git diff failed for {sha}: {stderr})")
                }
                Err(e) => format!("(could not exec git: {e})"),
            };
            template.replace("{{REFERENCE_DIFF}}", &diff_text)
        }
        None => template.replace("{{REFERENCE_DIFF}}", ""),
    };

    Ok(populated)
}

/// Aggregate `chump gap list --json` output into per-status counts and
/// per-repo rows for a given fanout-group name. Lenient parser: accepts
/// either a single JSON array or newline-delimited objects.
pub fn aggregate_status(gap_list_json: &str, name: &str) -> StatusReport {
    let needle = format!("fanout_group={name}");
    let entries: Vec<serde_json::Value> = if gap_list_json.trim_start().starts_with('[') {
        serde_json::from_str(gap_list_json).unwrap_or_default()
    } else {
        gap_list_json
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .collect()
    };

    let mut rows: Vec<StatusRow> = Vec::new();
    for e in &entries {
        let notes = e.get("notes").and_then(|v| v.as_str()).unwrap_or("");
        if !notes.contains(&needle) {
            continue;
        }
        let id = e
            .get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("?")
            .to_string();
        let status = e
            .get("status")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        // Parse target_repo / repo_label out of notes (best-effort).
        let target_repo = extract_note(notes, "target_repo=").unwrap_or_default();
        let repo_label = extract_note(notes, "repo_label=").unwrap_or_default();
        let closed_pr = e
            .get("closed_pr")
            .and_then(|v| v.as_i64())
            .map(|n| n as u64);
        rows.push(StatusRow {
            id,
            status,
            target_repo,
            repo_label,
            closed_pr,
        });
    }

    let mut by_status = std::collections::BTreeMap::<String, usize>::new();
    for r in &rows {
        *by_status.entry(r.status.clone()).or_insert(0) += 1;
    }
    StatusReport {
        name: name.to_string(),
        rows,
        by_status,
    }
}

fn extract_note(notes: &str, key: &str) -> Option<String> {
    // Notes are written with `\n` literal sequences (see build_gap_notes);
    // tolerate both real newlines and the literal `\n` separator that
    // `chump gap reserve --notes` historically passes through.
    let normalized = notes.replace("\\n", "\n");
    for line in normalized.lines() {
        if let Some(rest) = line.strip_prefix(key) {
            return Some(rest.trim().to_string());
        }
    }
    None
}

#[derive(Debug, Clone, Serialize)]
pub struct StatusReport {
    pub name: String,
    pub rows: Vec<StatusRow>,
    pub by_status: std::collections::BTreeMap<String, usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StatusRow {
    pub id: String,
    pub status: String,
    pub target_repo: String,
    pub repo_label: String,
    pub closed_pr: Option<u64>,
}

impl StatusReport {
    pub fn render_text(&self) -> String {
        if self.rows.is_empty() {
            return format!("no gaps found for fanout-group {}\n", self.name);
        }
        let mut s = format!(
            "fanout status: {}  ({} gap(s))\n",
            self.name,
            self.rows.len()
        );
        for (status, n) in &self.by_status {
            s.push_str(&format!("  {status}: {n}\n"));
        }
        s.push_str("\nper-repo:\n");
        for r in &self.rows {
            let pr = r.closed_pr.map(|n| format!(" PR#{n}")).unwrap_or_default();
            s.push_str(&format!(
                "  {} [{}] {}{}\n",
                r.id, r.status, r.repo_label, pr
            ));
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
name: shared-lib-bump
intent: |
  Bump shared-lib to v2.0 in this service. Run the service's existing
  integration suite. No cross-service refactors.
repos:
  - path: ../service-a
  - path: ../service-b
  - path: ../service-c
validation: ./scripts/test-integration.sh
success: integration suite passes after the bump
"#;

    #[test]
    fn parses_minimal_spec() {
        let s = FanoutSpec::from_yaml(SAMPLE).expect("parse");
        assert_eq!(s.name, "shared-lib-bump");
        assert_eq!(s.repos.len(), 3);
        assert_eq!(s.effort, "m"); // default for fanout
        assert_eq!(s.domain, "INFRA"); // default
    }

    #[test]
    fn plan_one_gap_per_repo() {
        let s = FanoutSpec::from_yaml(SAMPLE).expect("parse");
        let plan = s.plan(Path::new("/tmp/spec-dir"));
        assert_eq!(plan.len(), 3);
        let labels: Vec<_> = plan.iter().map(|g| g.repo_label.clone()).collect();
        assert!(labels.contains(&"service-a".to_string()));
        assert!(labels.contains(&"service-b".to_string()));
        assert!(labels.contains(&"service-c".to_string()));
        for g in &plan {
            assert_eq!(g.fanout_group, "shared-lib-bump");
            assert!(g.title.starts_with("shared-lib-bump: "));
        }
    }

    #[test]
    fn relative_paths_resolve_against_spec_dir() {
        let s = FanoutSpec::from_yaml(SAMPLE).expect("parse");
        let plan = s.plan(Path::new("/tmp/spec-dir"));
        // ../service-a from /tmp/spec-dir → /tmp/service-a
        assert!(plan[0].target_repo.ends_with("/service-a"));
    }

    #[test]
    fn empty_repos_rejected() {
        let yaml = r#"
name: empty
intent: do
repos: []
validation: "true"
success: ok
"#;
        let err = FanoutSpec::from_yaml(yaml).unwrap_err();
        assert!(err.contains("repos"));
    }

    #[test]
    fn missing_path_and_url_rejected() {
        let yaml = r#"
name: bad
intent: do
repos:
  - label: just-a-label
validation: "true"
success: ok
"#;
        let err = FanoutSpec::from_yaml(yaml).unwrap_err();
        assert!(err.contains("path") || err.contains("url"));
    }

    #[test]
    fn empty_name_rejected() {
        let yaml = r#"
name: ""
intent: do
repos:
  - path: ./x
validation: "true"
success: ok
"#;
        let err = FanoutSpec::from_yaml(yaml).unwrap_err();
        assert!(err.contains("name"));
    }

    #[test]
    fn url_only_repo_uses_url_basename_as_label() {
        let yaml = r#"
name: remote-only
intent: do
repos:
  - url: https://github.com/foo/service-x.git
validation: "true"
success: ok
"#;
        let s = FanoutSpec::from_yaml(yaml).expect("parse");
        let plan = s.plan(Path::new("/tmp"));
        assert_eq!(plan[0].repo_label, "service-x");
    }

    #[test]
    fn explicit_label_wins_over_path_basename() {
        let yaml = r#"
name: labeled
intent: do
repos:
  - path: ./alpha
    label: APP-frontend
validation: "true"
success: ok
"#;
        let s = FanoutSpec::from_yaml(yaml).expect("parse");
        let plan = s.plan(Path::new("/tmp"));
        assert_eq!(plan[0].repo_label, "APP-frontend");
    }

    #[test]
    fn build_gap_notes_round_trips_through_aggregate() {
        let yaml = r#"
name: roundtrip
intent: do
repos:
  - path: ./svc1
  - path: ./svc2
validation: "true"
success: ok
"#;
        let s = FanoutSpec::from_yaml(yaml).expect("parse");
        let plan = s.plan(Path::new("/tmp"));
        // Synthesize what `chump gap list --json` would emit per gap.
        let json = format!(
            "[{{\"id\":\"INFRA-9001\",\"status\":\"open\",\"notes\":\"{}\"}},\
              {{\"id\":\"INFRA-9002\",\"status\":\"open\",\"notes\":\"{}\"}}]",
            build_gap_notes(&plan[0]),
            build_gap_notes(&plan[1])
        );
        let report = aggregate_status(&json, "roundtrip");
        assert_eq!(report.rows.len(), 2);
        assert_eq!(report.by_status.get("open"), Some(&2));
        let labels: Vec<_> = report.rows.iter().map(|r| r.repo_label.clone()).collect();
        assert!(labels.contains(&"svc1".to_string()));
        assert!(labels.contains(&"svc2".to_string()));
    }

    #[test]
    fn aggregate_status_handles_ndjson_and_array() {
        let ndjson = "{\"id\":\"INFRA-1\",\"status\":\"open\",\"notes\":\"fanout_group=ndj\\\\ntarget_repo=/x\"}\n{\"id\":\"INFRA-2\",\"status\":\"done\",\"notes\":\"fanout_group=ndj\\\\ntarget_repo=/y\"}";
        let report = aggregate_status(ndjson, "ndj");
        assert_eq!(report.rows.len(), 2);
        assert_eq!(report.by_status.get("open"), Some(&1));
        assert_eq!(report.by_status.get("done"), Some(&1));
    }

    #[test]
    fn aggregate_status_filters_by_group_name() {
        let json = "[{\"id\":\"INFRA-1\",\"status\":\"open\",\"notes\":\"fanout_group=alpha\\\\ntarget_repo=/x\"},\
                     {\"id\":\"INFRA-2\",\"status\":\"open\",\"notes\":\"fanout_group=beta\\\\ntarget_repo=/y\"}]";
        let report = aggregate_status(json, "alpha");
        assert_eq!(report.rows.len(), 1);
        assert_eq!(report.rows[0].repo_label, ""); // no repo_label in the synthetic notes
        assert_eq!(report.rows[0].target_repo, "/x");
    }

    // ── INFRA-1935: reference field propagation ───────────────────────────────

    #[test]
    fn reference_field_defaults_to_none() {
        let s = FanoutSpec::from_yaml(SAMPLE).expect("parse");
        assert_eq!(s.reference, None);
    }

    #[test]
    fn reference_propagates_into_planned_gaps() {
        let mut s = FanoutSpec::from_yaml(SAMPLE).expect("parse");
        s.reference = Some("abc1234def5678".to_string());
        let plan = s.plan(Path::new("/tmp/spec-dir"));
        for g in &plan {
            assert_eq!(
                g.reference.as_deref(),
                Some("abc1234def5678"),
                "reference should propagate to every PlannedRepoGap"
            );
        }
    }

    #[test]
    fn reference_none_not_propagated_when_unset() {
        let s = FanoutSpec::from_yaml(SAMPLE).expect("parse");
        let plan = s.plan(Path::new("/tmp/spec-dir"));
        for g in &plan {
            assert_eq!(g.reference, None, "reference should be None when not set");
        }
    }

    #[test]
    fn build_gap_notes_includes_reference_when_set() {
        let mut s = FanoutSpec::from_yaml(SAMPLE).expect("parse");
        s.reference = Some("deadbeef1234".to_string());
        let plan = s.plan(Path::new("/tmp"));
        let notes = build_gap_notes(&plan[0]);
        assert!(
            notes.contains("reference: deadbeef1234"),
            "notes should contain reference SHA; got: {notes}"
        );
    }

    #[test]
    fn build_gap_notes_omits_reference_when_none() {
        let s = FanoutSpec::from_yaml(SAMPLE).expect("parse");
        let plan = s.plan(Path::new("/tmp"));
        let notes = build_gap_notes(&plan[0]);
        assert!(
            !notes.contains("reference:"),
            "notes should not contain reference when not set; got: {notes}"
        );
    }

    // ── INFRA-1935: render_agent_prompt today-path and reference-path ─────────

    #[test]
    fn render_prompt_today_path_substitutes_empty_diff() {
        // Write a minimal template to a temp dir, verify {{REFERENCE_DIFF}} → "".
        let tmp = std::env::temp_dir().join("chump-fanout-test-today");
        let dispatch_dir = tmp.join("scripts/dispatch");
        std::fs::create_dir_all(&dispatch_dir).unwrap();
        let tpl = "Before\n{{REFERENCE_DIFF}}\nAfter\n";
        std::fs::write(dispatch_dir.join("fanout-agent-prompt.md"), tpl).unwrap();

        let result = render_agent_prompt(&tmp, None).expect("render");
        assert!(
            result.contains("Before\n\nAfter"),
            "today-path: {{REFERENCE_DIFF}} should be replaced with empty string; got: {result}"
        );
        assert!(
            !result.contains("{{REFERENCE_DIFF}}"),
            "placeholder should be fully substituted"
        );
    }

    #[test]
    fn render_prompt_reference_path_substitutes_placeholder() {
        // Write a minimal template and verify the placeholder is substituted
        // (even though git diff may not find the SHA in CI — the substitution
        // itself is what we test here; we use a SHA that will fail gracefully).
        let tmp = std::env::temp_dir().join("chump-fanout-test-ref");
        let dispatch_dir = tmp.join("scripts/dispatch");
        std::fs::create_dir_all(&dispatch_dir).unwrap();
        let tpl = "---\n{{REFERENCE_DIFF}}\n---\n";
        std::fs::write(dispatch_dir.join("fanout-agent-prompt.md"), tpl).unwrap();

        // Use a SHA that won't exist in /tmp so git fails gracefully.
        let result = render_agent_prompt(&tmp, Some("0000000000000000000000000000000000000000"))
            .expect("render");
        // The placeholder must be gone regardless of whether git succeeded.
        assert!(
            !result.contains("{{REFERENCE_DIFF}}"),
            "placeholder should always be substituted; got: {result}"
        );
        // Template structure must be preserved.
        assert!(result.contains("---"), "template structure preserved");
    }

    #[test]
    fn render_prompt_missing_template_returns_error() {
        let tmp = std::env::temp_dir().join("chump-fanout-test-missing-tpl");
        // Don't create the template file.
        let err = render_agent_prompt(&tmp, None).unwrap_err();
        assert!(
            err.contains("fanout-agent-prompt.md") || err.contains("read"),
            "error should mention the template path; got: {err}"
        );
    }
}
