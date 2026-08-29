//! INFRA-1562: `chump eval list` — surfaces execution status for every
//! preregistered eval/research gap under `docs/eval/preregistered/`.
//!
//! Preregistration LOCKED (see TEMPLATE.md) only records that the
//! hypothesis + analysis plan were fixed before data collection. It says
//! nothing about whether the sweep actually ran. Before this gap, that
//! answer was "read commit history and guess." Now it's a single YAML file
//! (`docs/eval/preregistered/EVAL_STATUS.yaml`) plus this CLI surface.
//!
//! Usage:
//!   chump eval list [--status pending|running|complete|abandoned] [--json]

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvalStatusEntry {
    pub eval_id: String,
    pub status: String,
    #[serde(default)]
    pub last_run_ts: Option<String>,
    #[serde(default)]
    pub result_doc_path: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
}

pub const VALID_STATUSES: [&str; 4] = ["pending", "running", "complete", "abandoned"];

pub fn status_yaml_path(repo_root: &Path) -> PathBuf {
    repo_root.join("docs/eval/preregistered/EVAL_STATUS.yaml")
}

pub fn load_status(repo_root: &Path) -> Result<Vec<EvalStatusEntry>> {
    let path = status_yaml_path(repo_root);
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("reading {}", path.display()))?;
    let entries: Vec<EvalStatusEntry> =
        serde_yaml::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
    Ok(entries)
}

/// Every `docs/eval/preregistered/*.md` that isn't scaffolding (README,
/// TEMPLATE, the cost-optimization guide) is expected to have a status
/// entry. Used by both `chump eval list` (to flag drift) and
/// `scripts/ci/test-preregistered-eval-status.sh`.
pub fn discover_prereg_ids(repo_root: &Path) -> Result<Vec<String>> {
    let dir = repo_root.join("docs/eval/preregistered");
    let mut ids = Vec::new();
    for entry in std::fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let stem = match path.file_stem().and_then(|s| s.to_str()) {
            Some(s) => s,
            None => continue,
        };
        if matches!(stem, "README" | "TEMPLATE" | "COST_OPTIMIZATION") {
            continue;
        }
        ids.push(stem.to_string());
    }
    ids.sort();
    Ok(ids)
}

pub fn run_list(args: &[String], repo_root: &Path) -> Result<i32> {
    let json_out = args.iter().any(|a| a == "--json");
    let status_filter = args
        .windows(2)
        .find(|w| w[0] == "--status")
        .map(|w| w[1].clone());

    if let Some(ref s) = status_filter {
        if !VALID_STATUSES.contains(&s.as_str()) {
            eprintln!(
                "chump eval list: invalid --status '{s}' (expected one of: {})",
                VALID_STATUSES.join(", ")
            );
            return Ok(1);
        }
    }

    let entries = load_status(repo_root)?;
    let filtered: Vec<&EvalStatusEntry> = entries
        .iter()
        .filter(|e| status_filter.as_deref().is_none_or(|s| e.status == s))
        .collect();

    if json_out {
        println!("{}", serde_json::to_string_pretty(&filtered)?);
        return Ok(0);
    }

    if filtered.is_empty() {
        println!("(no evals match)");
        return Ok(0);
    }

    println!(
        "{:<14} {:<10} {:<12} {}",
        "EVAL_ID", "STATUS", "LAST_RUN", "RESULT_DOC"
    );
    for e in &filtered {
        println!(
            "{:<14} {:<10} {:<12} {}",
            e.eval_id,
            e.status,
            e.last_run_ts.as_deref().unwrap_or("-"),
            e.result_doc_path.as_deref().unwrap_or("-")
        );
    }

    let discovered = discover_prereg_ids(repo_root)?;
    let tracked: std::collections::HashSet<&str> =
        entries.iter().map(|e| e.eval_id.as_str()).collect();
    let missing: Vec<&String> = discovered
        .iter()
        .filter(|id| !tracked.contains(id.as_str()))
        .collect();
    if !missing.is_empty() {
        println!();
        println!(
            "WARNING: {} preregistered file(s) missing a status entry: {}",
            missing.len(),
            missing
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    Ok(0)
}
