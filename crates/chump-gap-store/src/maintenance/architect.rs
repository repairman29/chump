//! LLM-driven gap decomposition — port of `scripts/coord/gap-architect.py`
//! (Phase 1 of INFRA-2000).
//!
//! ## What this module is
//!
//! The Python `gap-architect.py` reads strategic docs (RED_LETTER.md,
//! RESEARCH_PLAN.md, FINDINGS.md), assembles a context block, asks
//! Claude to emit ~20 concrete gap candidates, dedupes them against
//! existing open gaps, assigns sequential IDs, and ships a PR.
//!
//! Phase 1 ports **the decomposition path**: a trait-bounded
//! [`GapArchitect::decompose`] that takes an existing gap ID, builds a
//! decomposition prompt from the gap's description + the current
//! codebase context, calls an LLM through the [`LlmClient`] trait, and
//! returns the proposed sub-gap candidates.
//!
//! The trait boundary is the key win — Phase 1's
//! [`ClaudeBinaryClient`] shells out to `claude -p` (matching what
//! `gap-architect.py` does today), but tests + future in-process
//! callers can swap a mock or an `anthropic` SDK-backed impl without
//! touching the port logic.
//!
//! ## Non-goals (Phase 1)
//!
//! - PR-creation surface. The Python tool's `ship()` path keeps its
//!   `gh pr create` / `git push` workflow; the Rust port surfaces
//!   parsed gap dicts only.
//! - Full integration with `chump-cost-tracker`. Phase 1 keeps the
//!   Python tool's cost-collection-via-stderr behavior; the Rust path
//!   exposes the raw stderr on the returned [`ArchitectError`] so
//!   the existing collector still works.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use anyhow::Context;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::GapStore;

/// Decomposition mode mirrors the Python tool's `--dry-run` flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecomposeMode {
    /// Print the prompt + parsed candidates only; no LLM call.
    DryRun,
    /// Call the LLM, parse, return the candidates.
    Apply,
}

/// One decomposed sub-gap candidate. Matches the field set the Python
/// tool emits when it writes to `docs/gaps.yaml`.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct SubGap {
    /// Candidate ID. `ClaudeBinaryClient` returns these unassigned; the
    /// caller is responsible for collision-checking and re-numbering.
    #[serde(default)]
    pub id: String,
    /// One-line title.
    pub title: String,
    /// Domain string (e.g. `INFRA`, `COG`, `CREDIBLE`).
    pub domain: String,
    /// `P0`/`P1`/`P2`/`P3`.
    pub priority: String,
    /// `xs`/`s`/`m`/`l`.
    pub effort: String,
    /// Long description (multi-paragraph allowed).
    pub description: String,
    /// `open`/`done`. New decomposition output is always `open`.
    #[serde(default)]
    pub status: String,
}

/// Failure modes for [`GapArchitect::decompose`].
#[derive(Debug, Error)]
pub enum ArchitectError {
    /// I/O or DB error while reading the source gap.
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    /// Source gap not found in `state.db`.
    #[error("gap {0} not found")]
    GapNotFound(String),
    /// LLM call failed.
    #[error("llm: {0}")]
    Llm(String),
    /// Response could not be parsed as YAML.
    #[error("parse: {0}")]
    Parse(String),
    /// Backing store error from rusqlite or chump-gap-store.
    #[error("store: {0}")]
    Store(String),
}

/// LLM boundary. Phase 1 implements this for the `claude -p` CLI
/// binary; tests + future in-process integrations swap implementations.
#[async_trait]
pub trait LlmClient: Send + Sync {
    /// Send a single prompt to the LLM and return its text response.
    /// Long-tail failures (network, timeout, non-zero exit) surface as
    /// [`ArchitectError::Llm`] with the stderr/error text attached.
    async fn complete(&self, prompt: &str) -> Result<String, ArchitectError>;
}

/// Subprocess-backed [`LlmClient`] that shells out to `claude -p`.
///
/// Mirrors what `gap-architect.py` does today. `CHUMP_GAP_DECOMPOSE_MODEL`
/// selects the model; default is `claude-haiku-4-5` (the value the Python
/// tool uses for its haiku-cheap dry-runs). Pass an explicit `model` to
/// override.
pub struct ClaudeBinaryClient {
    /// `claude` binary path. Defaults to `claude` on PATH.
    pub binary: PathBuf,
    /// Model selector (`--model` arg).
    pub model: String,
    /// `--output-format` value. Default `text`.
    pub output_format: String,
}

impl Default for ClaudeBinaryClient {
    fn default() -> Self {
        let model = std::env::var("CHUMP_GAP_DECOMPOSE_MODEL")
            .unwrap_or_else(|_| "claude-haiku-4-5".to_string());
        Self {
            binary: PathBuf::from("claude"),
            model,
            output_format: "text".to_string(),
        }
    }
}

#[async_trait]
impl LlmClient for ClaudeBinaryClient {
    async fn complete(&self, prompt: &str) -> Result<String, ArchitectError> {
        // Use std::process::Command (sync) rather than tokio::process to
        // keep this trait callable from sync contexts; we wrap the whole
        // call in `tokio::task::spawn_blocking` when an async caller wants
        // concurrency. Phase 1's CLI is single-shot so we just block.
        let binary = self.binary.clone();
        let model = self.model.clone();
        let output_format = self.output_format.clone();
        let prompt_owned = prompt.to_string();

        let handle = tokio::task::spawn_blocking(move || -> Result<String, ArchitectError> {
            let child = std::process::Command::new(&binary)
                .arg("-p")
                .arg(&prompt_owned)
                .arg("--model")
                .arg(&model)
                .arg("--output-format")
                .arg(&output_format)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|e| {
                    ArchitectError::Llm(format!("spawn {} failed: {}", binary.display(), e))
                })?;
            let out = child
                .wait_with_output()
                .map_err(|e| ArchitectError::Llm(format!("wait failed: {}", e)))?;
            if !out.status.success() {
                return Err(ArchitectError::Llm(format!(
                    "claude exited {} stderr={}",
                    out.status,
                    String::from_utf8_lossy(&out.stderr)
                )));
            }
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        });
        match handle.await {
            Ok(r) => r,
            Err(e) => Err(ArchitectError::Llm(format!("join: {}", e))),
        }
    }
}

/// Repo-rooted decomposition orchestrator.
pub struct GapArchitect<C: LlmClient> {
    repo_root: PathBuf,
    client: C,
}

impl<C: LlmClient> GapArchitect<C> {
    /// Construct an architect with a custom client.
    pub fn new(repo_root: impl AsRef<Path>, client: C) -> Self {
        Self {
            repo_root: repo_root.as_ref().to_path_buf(),
            client,
        }
    }

    /// Build the decomposition prompt for a gap, without calling the LLM.
    ///
    /// Two inputs feed in:
    /// 1. The gap's `description` (per-gap context the filer wrote at
    ///    file-time).
    /// 2. A short slice of the repo state (open-gap summary count + the
    ///    target gap's title/domain/priority/effort).
    pub fn build_prompt(&self, gap_id: &str) -> Result<String, ArchitectError> {
        let store = GapStore::open(&self.repo_root)
            .with_context(|| format!("open state.db at {}", self.repo_root.display()))
            .map_err(|e| ArchitectError::Store(e.to_string()))?;
        let row = store
            .get(gap_id)
            .map_err(|e| ArchitectError::Store(e.to_string()))?
            .ok_or_else(|| ArchitectError::GapNotFound(gap_id.to_string()))?;
        let opens = store
            .list(Some("open"))
            .map_err(|e| ArchitectError::Store(e.to_string()))?;
        let open_summaries: Vec<String> = opens
            .iter()
            .take(40)
            .map(|g| format!("- {}: {} [{}]", g.id, g.title, g.domain))
            .collect();

        let prompt = format!(
            "You are decomposing a Chump gap into 3-6 concrete, individually-shippable sub-gaps.\n\
\n\
TARGET GAP\n\
  id: {id}\n\
  title: {title}\n\
  domain: {domain}\n\
  priority: {priority}\n\
  effort: {effort}\n\
\n\
DESCRIPTION (filer's context — may be stale):\n\
{desc}\n\
\n\
EXISTING OPEN GAPS (sample) — do NOT propose duplicates:\n\
{opens}\n\
\n\
TASK\n\
  Emit a YAML list (no prose, no fences) of 3-6 sub-gap entries with fields:\n\
    id (string; placeholder is fine — caller will reassign)\n\
    title (one line; tag with the pillar prefix of the parent if applicable)\n\
    domain ({domain} unless the slice clearly belongs elsewhere)\n\
    priority (P0/P1/P2/P3 — usually one tier lower than the parent)\n\
    effort (xs/s/m/l — xs/s preferred for shippability)\n\
    description (multi-line ok)\n\
    status (always 'open')\n\
\n\
Each sub-gap must be picked + shipped independently of the others.\n",
            id = row.id,
            title = row.title,
            domain = row.domain,
            priority = row.priority,
            effort = row.effort,
            desc = if row.description.trim().is_empty() {
                "(no description — proceed from title + existing gaps)"
            } else {
                row.description.as_str()
            },
            opens = open_summaries.join("\n"),
        );
        Ok(prompt)
    }

    /// Run one decomposition. Returns the parsed sub-gap candidates.
    ///
    /// In [`DecomposeMode::DryRun`] no LLM call happens — caller can
    /// pipe the prompt to a clipboard / log / human review.
    pub async fn decompose(
        &self,
        gap_id: &str,
        mode: DecomposeMode,
    ) -> Result<Vec<SubGap>, ArchitectError> {
        let prompt = self.build_prompt(gap_id)?;
        if matches!(mode, DecomposeMode::DryRun) {
            eprintln!("=== gap-architect dry-run: prompt ===");
            eprintln!("{}", prompt);
            eprintln!("=== gap-architect dry-run: (no LLM call) ===");
            return Ok(Vec::new());
        }
        let raw = self.client.complete(&prompt).await?;
        parse_yaml_from_response(&raw)
    }
}

/// Parse the LLM response as YAML and validate the required fields.
/// Mirrors `gap-architect.py::parse_yaml_from_response + validate_gap`.
pub fn parse_yaml_from_response(text: &str) -> Result<Vec<SubGap>, ArchitectError> {
    // Strip code fences if present (LLMs love to add ```yaml).
    let trimmed = text.trim();
    let mut body = trimmed.to_string();
    for fence in ["```yaml\n", "```yml\n", "```\n"] {
        if let Some(rest) = body.strip_prefix(fence) {
            body = rest.to_string();
            break;
        }
    }
    if let Some(end) = body.rfind("```") {
        body.truncate(end);
    }

    let parsed: serde_yaml::Value =
        serde_yaml::from_str(&body).map_err(|e| ArchitectError::Parse(format!("yaml: {}", e)))?;
    let seq = match parsed {
        serde_yaml::Value::Sequence(s) => s,
        serde_yaml::Value::Mapping(_) => vec![parsed],
        _ => return Err(ArchitectError::Parse("expected list of gaps".to_string())),
    };

    let mut out = Vec::new();
    for v in seq {
        let mut gap: SubGap = serde_yaml::from_value(v).unwrap_or_default();
        // Default status to open.
        if gap.status.is_empty() {
            gap.status = "open".to_string();
        }
        if validate_required_fields(&gap) {
            out.push(gap);
        }
    }
    Ok(out)
}

/// Check that the required REQUIRED_FIELDS are populated.
/// Mirrors `gap-architect.py::REQUIRED_FIELDS`.
fn validate_required_fields(g: &SubGap) -> bool {
    !g.title.is_empty()
        && !g.domain.is_empty()
        && !g.priority.is_empty()
        && !g.effort.is_empty()
        && !g.description.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[async_trait]
    impl LlmClient for std::sync::Arc<String> {
        async fn complete(&self, _prompt: &str) -> Result<String, ArchitectError> {
            Ok(self.as_str().to_string())
        }
    }

    #[test]
    fn parse_strips_yaml_fence() {
        let raw = "```yaml\n- id: INFRA-X\n  title: do thing\n  domain: INFRA\n  priority: P2\n  effort: s\n  description: stuff\n  status: open\n```";
        let gaps = parse_yaml_from_response(raw).unwrap();
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].title, "do thing");
        assert_eq!(gaps[0].status, "open");
    }

    #[test]
    fn parse_drops_invalid_entries() {
        // Missing description -> dropped.
        let raw = "- id: x\n  title: t\n  domain: D\n  priority: P1\n  effort: s\n";
        let gaps = parse_yaml_from_response(raw).unwrap();
        assert!(gaps.is_empty());
    }

    #[test]
    fn parse_accepts_single_mapping() {
        let raw =
            "id: x\ntitle: t\ndomain: D\npriority: P1\neffort: s\ndescription: d\nstatus: open\n";
        let gaps = parse_yaml_from_response(raw).unwrap();
        assert_eq!(gaps.len(), 1);
    }
}
