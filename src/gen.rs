//! `chump gen <task>` — agent-loop user-facing coding task (INFRA-593 / PRODUCT-050).
//!
//! Front door for the offline-LLM mission: takes a natural-language task,
//! drives `ChumpAgent::run` with `read_file` + `list_dir` tools to explore
//! context and produce code edits, applies them to the current working
//! directory, runs `cargo check`, and commits.
//!
//! ## Stub mode (CI / smoke tests)
//!
//! Set `CHUMP_GEN_STUB_FILE=<rel-path>` to skip the real LLM call. The
//! command prepends `// chump-gen: <task>` to the named file, which satisfies
//! the AC requirement ("asserts a commit lands") without an API key.
//!
//! ## LLM edit format
//!
//! The provider is prompted to emit changed files in a delimited block:
//!
//! ```text
//! ===FILE: src/main.rs===
//! <complete file content>
//! ===ENDFILE===
//! ```
//!
//! Only paths that are relative and contain no `..` traversal are accepted.

use crate::agent_loop::ChumpAgent;
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::Instant;

const FILE_BEGIN: &str = "===FILE:";
const FILE_END: &str = "===ENDFILE===";

// ── Model registry (INFRA-739) ─────────────────────────────────────────────

/// Per-model pricing entry loaded from docs/dispatch/model_registry.yaml.
#[derive(Debug, Deserialize)]
struct RegistryEntry {
    model_id: String,
    input_per_mtk: f64,
    output_per_mtk: f64,
}

#[derive(Debug, Deserialize)]
struct ModelRegistry {
    models: Vec<RegistryEntry>,
}

/// Returns a cached map of model_id → blended $/MTok rate loaded from
/// docs/dispatch/model_registry.yaml. The registry is located relative to
/// `CARGO_MANIFEST_DIR` (the workspace root at compile time) or via the
/// `CHUMP_REPO_ROOT` env var at runtime. If the file cannot be found or
/// parsed, the map is empty and callers fall back to substring matching.
fn registry_blended_rates() -> &'static HashMap<String, f64> {
    static CACHE: OnceLock<HashMap<String, f64>> = OnceLock::new();
    CACHE.get_or_init(|| {
        // Prefer runtime env override so integration tests can point at the
        // real repo root even when the binary runs from a temp dir.
        let candidates = [
            std::env::var("CHUMP_REPO_ROOT")
                .map(|r| format!("{}/docs/dispatch/model_registry.yaml", r))
                .ok(),
            // compile-time path: workspace root is always CARGO_MANIFEST_DIR
            Some(format!(
                "{}/docs/dispatch/model_registry.yaml",
                env!("CARGO_MANIFEST_DIR")
            )),
        ];
        for candidate in candidates.iter().flatten() {
            if let Ok(text) = std::fs::read_to_string(candidate) {
                match serde_yaml::from_str::<ModelRegistry>(&text) {
                    Ok(reg) => {
                        return reg
                            .models
                            .into_iter()
                            .map(|e| {
                                // Blended rate: simple average of input + output $/MTok.
                                let blended = (e.input_per_mtk + e.output_per_mtk) / 2.0;
                                (e.model_id, blended)
                            })
                            .collect();
                    }
                    Err(err) => {
                        tracing::warn!(
                            path = %candidate,
                            error = %err,
                            "INFRA-739: failed to parse model_registry.yaml — falling back to substring matching"
                        );
                    }
                }
            }
        }
        HashMap::new()
    })
}

// ──────────────────────────────────────────────────────────────────────────────

pub struct GenOptions {
    pub task: String,
    pub work_dir: PathBuf,
    /// When true, suppress the per-call cost summary line.
    pub quiet: bool,
    /// When true, force local-only provider (bypass cascade, use Ollama).
    pub local: bool,
}

/// Estimate token count and USD cost, then print a one-line summary to stderr.
///
/// Token estimate: (input_chars + output_chars) / 4 — rough but consistent.
/// Cost table uses published $/MTok rates; unknown models default to Sonnet pricing.
pub fn print_cost_summary(elapsed_secs: f64, input_chars: usize, output_chars: usize, slot: &str) {
    let total_tokens = ((input_chars + output_chars) / 4).max(1);
    let cost_usd = estimate_cost_usd(total_tokens as u64, slot);
    let model_label = friendly_model_label(slot);
    eprintln!(
        "completed in {:.1}s — {:>5} tokens (~${:.2} {})",
        elapsed_secs,
        fmt_tokens(total_tokens as u64),
        cost_usd,
        model_label,
    );
}

fn estimate_cost_usd(tokens: u64, slot: &str) -> f64 {
    // INFRA-739: check the model registry first (exact match).
    let rates = registry_blended_rates();
    if let Some(&blended) = rates.get(slot) {
        return tokens as f64 / 1_000_000.0 * blended;
    }

    // Prefix/suffix match: handles date-stamped variants not explicitly
    // registered (e.g. "claude-sonnet-4-5-20250929" → registered "claude-sonnet-4-5").
    for (model_id, &blended) in rates.iter() {
        if slot.starts_with(model_id.as_str()) || model_id.starts_with(slot) {
            return tokens as f64 / 1_000_000.0 * blended;
        }
    }

    // Fallback: legacy substring matching for unregistered models.
    let slot_lc = slot.to_lowercase();
    // $/MTok blended (input+output averaged); offline/local models are $0
    let per_million: f64 = if slot_lc.contains("opus") {
        75.0
    } else if slot_lc.contains("sonnet") {
        15.0
    } else if slot_lc.contains("haiku") {
        1.25
    } else if slot_lc.contains("gpt-4") {
        30.0
    } else if slot_lc.contains("gpt-3") {
        0.5
    } else if slot_lc.is_empty()
        || slot_lc.contains("local")
        || slot_lc.contains("ollama")
        || slot_lc.contains("mistral")
    {
        0.0
    } else {
        15.0 // default: Sonnet pricing
    };
    tokens as f64 / 1_000_000.0 * per_million
}

fn friendly_model_label(slot: &str) -> String {
    if slot.is_empty() {
        return "unknown".to_string();
    }
    let lc = slot.to_lowercase();
    if lc.contains("opus") {
        "Opus".to_string()
    } else if lc.contains("sonnet") {
        "Sonnet".to_string()
    } else if lc.contains("haiku") {
        "Haiku".to_string()
    } else {
        // Use the slot name directly, trimmed to 20 chars
        slot.chars().take(20).collect()
    }
}

fn fmt_tokens(n: u64) -> String {
    if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

pub async fn run(opts: GenOptions) -> Result<()> {
    let work_dir = &opts.work_dir;
    let t0 = Instant::now();

    let (input_chars, output_chars) = if let Ok(stub_rel) = std::env::var("CHUMP_GEN_STUB_FILE") {
        // CI / smoke-test path — prepend a comment, no real LLM call.
        let target = work_dir.join(&stub_rel);
        let existing = std::fs::read_to_string(&target)
            .with_context(|| format!("CHUMP_GEN_STUB_FILE read: {}", target.display()))?;
        let patched = format!("// chump-gen: {}\n{}", opts.task, existing);
        std::fs::write(&target, &patched)
            .with_context(|| format!("CHUMP_GEN_STUB_FILE write: {}", target.display()))?;
        println!("gen (stub): patched {}", stub_rel);
        (opts.task.len(), patched.len())
    } else {
        // Real LLM path — agent loop with read_file + list_dir tools (PRODUCT-050).
        let provider: Box<dyn axonerai::provider::Provider + Send + Sync> = if opts.local {
            std::env::set_var("OPENAI_API_BASE", "http://127.0.0.1:11434/v1");
            std::env::set_var("OPENAI_API_KEY", "ollama");
            crate::provider_cascade::build_provider_single_pub()
        } else {
            crate::provider_cascade::build_provider()
        };
        // Point repo tools at the gen work dir so read_file/list_dir resolve paths.
        std::env::set_var("CHUMP_REPO", work_dir);
        let agent = build_gen_agent(provider);
        let user_prompt = format!("Task: {}", opts.task);
        let in_chars = user_prompt.len();
        tracing::info!(task = %opts.task, work_dir = %work_dir.display(), "gen: agent loop started");
        let outcome = agent.run(&user_prompt).await.context("gen agent run")?;
        tracing::info!(
            tool_calls = outcome.total_tool_calls,
            reply_chars = outcome.reply.len(),
            "gen: agent loop complete"
        );
        let out_chars = outcome.reply.len();
        // PRODUCT-052: fallback detection.
        // 0 tool calls → model doesn't support tool-use; ===FILE=== blocks required.
        // >0 tool calls → model used patch_file etc.; ===FILE=== blocks are optional
        //   (agent may have already applied changes to disk — not an error if absent).
        let edits = if outcome.total_tool_calls == 0 {
            tracing::warn!(
                reply_chars = outcome.reply.len(),
                "gen: agent used 0 tools — model may not support tool-use; \
                 treating reply as ===FILE=== blocks"
            );
            parse_file_edits(&outcome.reply)?
        } else {
            parse_file_edits(&outcome.reply).unwrap_or_default()
        };
        if !edits.is_empty() {
            apply_file_edits(&edits, work_dir)?;
        }
        (in_chars, out_chars)
    };

    // Verify the edit compiles. INFRA-2106: only run cargo check if work_dir is
    // a Rust project (has a Cargo.toml). For non-Rust targets (TypeScript repos,
    // arbitrary scratch dirs, etc.) skip the verify step and trust the agent's
    // own iteration loop — the agent has run_cli and can invoke whatever build
    // tool the target uses. Operator can also opt out unconditionally via
    // CHUMP_GEN_SKIP_VERIFY=1.
    let skip_verify = std::env::var("CHUMP_GEN_SKIP_VERIFY")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let has_cargo_toml = work_dir.join("Cargo.toml").exists();
    if !skip_verify && has_cargo_toml {
        let status = Command::new("cargo")
            .arg("check")
            .current_dir(work_dir)
            .status()
            .context("spawn cargo check")?;
        if !status.success() {
            bail!("cargo check failed after applying gen edits");
        }
    } else if !has_cargo_toml {
        tracing::info!(
            work_dir = %work_dir.display(),
            "gen: no Cargo.toml in work_dir — skipping cargo check (non-Rust target)"
        );
    }

    // Commit the result.
    let summary: String = opts.task.chars().take(72).collect();
    let commit_msg = format!("chump gen: {}", summary);

    let add_ok = Command::new("git")
        .args(["add", "--all"])
        .current_dir(work_dir)
        .status()
        .context("git add")?
        .success();
    if !add_ok {
        bail!("git add failed");
    }

    let commit_ok = Command::new("git")
        .args(["commit", "-m", &commit_msg])
        .current_dir(work_dir)
        .status()
        .context("git commit")?
        .success();
    if !commit_ok {
        bail!("git commit failed");
    }

    println!("gen: committed — {}", commit_msg);

    if !opts.quiet {
        let elapsed = t0.elapsed().as_secs_f64();
        let slot = crate::provider_cascade::get_last_used_slot().unwrap_or_default();
        print_cost_summary(elapsed, input_chars, output_chars, &slot);
    }

    Ok(())
}

/// Build a [`ChumpAgent`] for `chump gen` with read_file, list_dir, patch_file,
/// and run_cli tools (PRODUCT-050 / PRODUCT-051).
///
/// The agent explores context, patches files, verifies with `cargo check`, and
/// iterates on failures. It emits final ===FILE=== blocks (or has already applied
/// edits via patch_file) — gen.rs applies any remaining blocks, then commits.
fn build_gen_agent(provider: Box<dyn axonerai::provider::Provider + Send + Sync>) -> ChumpAgent {
    let system = format!(
        "You are a coding assistant. Use read_file and list_dir to explore the \
         codebase, patch_file to apply changes, and run_cli to invoke the \
         project's own build / type-check / test tools (e.g. `cargo check`, \
         `cargo test`, `pnpm typecheck`, `pnpm test`, `pytest`, `go test`) and \
         iterate on any errors. When all changes are correct, output ONLY the \
         final modified files using this exact format:\n\n\
         {FILE_BEGIN} path/to/file.ext===\n<complete file content>\n{FILE_END}\n\n\
         Do not include any explanation outside these delimited blocks. Each \
         file block must contain the COMPLETE file content (not a diff)."
    );
    let mut registry = axonerai::tool::ToolRegistry::new();
    crate::tool_inventory::register_gen_tools(&mut registry);
    let max_iter = std::env::var("CHUMP_AGENT_MAX_ITER")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(10);
    ChumpAgent::new(
        provider,
        registry,
        Some(system),
        None, // no session history — single task
        None, // no event channel — CLI output
        max_iter,
    )
}

/// Parse `===FILE: path===\ncontent\n===ENDFILE===` blocks from LLM output.
fn parse_file_edits(text: &str) -> Result<Vec<(String, String)>> {
    let mut edits = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find(FILE_BEGIN) {
        let after_marker = &rest[start + FILE_BEGIN.len()..];
        let Some(newline) = after_marker.find('\n') else {
            break;
        };
        let file_path = after_marker[..newline]
            .trim_end_matches('=')
            .trim()
            .to_string();
        let content_start = &after_marker[newline + 1..];
        let end_pos = content_start.find(FILE_END).unwrap_or(content_start.len());
        let content = content_start[..end_pos].to_string();
        if !file_path.is_empty() {
            edits.push((file_path, content));
        }
        let consumed = newline + 1 + end_pos + FILE_END.len();
        if consumed >= after_marker.len() {
            break;
        }
        rest = &after_marker[consumed..];
    }
    if edits.is_empty() {
        bail!(
            "LLM response contained no parseable file edits — raw response (first 400 chars): {}",
            &text[..text.len().min(400)]
        );
    }
    Ok(edits)
}

/// Write parsed file edits to disk, rejecting unsafe paths.
fn apply_file_edits(edits: &[(String, String)], work_dir: &Path) -> Result<()> {
    for (rel_path, content) in edits {
        if rel_path.starts_with('/') || rel_path.contains("..") {
            bail!("gen: rejected unsafe path in LLM response: {}", rel_path);
        }
        let target = work_dir.join(rel_path);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create_dir_all {}", parent.display()))?;
        }
        std::fs::write(&target, content).with_context(|| format!("write {}", target.display()))?;
        println!("gen: wrote {}", rel_path);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_single_file_edit() {
        let text = "===FILE: src/main.rs===\nfn main() {}\n===ENDFILE===";
        let edits = parse_file_edits(text).unwrap();
        assert_eq!(edits.len(), 1);
        assert_eq!(edits[0].0, "src/main.rs");
        assert_eq!(edits[0].1, "fn main() {}\n");
    }

    #[test]
    fn parse_multiple_file_edits() {
        let text = "===FILE: a.rs===\nfn a() {}\n===ENDFILE===\n===FILE: b.rs===\nfn b() {}\n===ENDFILE===";
        let edits = parse_file_edits(text).unwrap();
        assert_eq!(edits.len(), 2);
        assert_eq!(edits[0].0, "a.rs");
        assert_eq!(edits[1].0, "b.rs");
    }

    #[test]
    fn parse_empty_returns_error() {
        assert!(parse_file_edits("no delimiters here").is_err());
    }

    #[test]
    fn apply_rejects_path_traversal() {
        let tmp = std::env::temp_dir();
        let edits = vec![("../evil.rs".to_string(), "".to_string())];
        assert!(apply_file_edits(&edits, &tmp).is_err());
    }

    #[test]
    fn apply_rejects_absolute_path() {
        let tmp = std::env::temp_dir();
        let edits = vec![("/etc/passwd".to_string(), "".to_string())];
        assert!(apply_file_edits(&edits, &tmp).is_err());
    }

    // Fallback detection: when model used 0 tool_calls, FILE blocks are required.
    #[test]
    fn fallback_zero_tool_calls_requires_file_blocks() {
        // No FILE blocks → error (model must have used ===FILE=== format)
        assert!(parse_file_edits("I made the change, see above.").is_err());
    }

    // When model used tools (total_tool_calls > 0), FILE blocks are optional.
    #[test]
    fn fallback_tool_use_path_accepts_no_file_blocks() {
        // Simulates the `parse_file_edits(&outcome.reply).unwrap_or_default()` call.
        let edits = parse_file_edits("patch_file was already called").unwrap_or_default();
        assert!(edits.is_empty());
    }
}
