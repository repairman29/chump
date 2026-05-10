//! `chump gen <task>` — single-shot user-facing coding task (INFRA-593).
//!
//! Front door for the offline-LLM mission: takes a natural-language task,
//! uses `provider_cascade::build_provider()` to produce code edits, applies
//! them to the current working directory, runs `cargo check`, and commits.
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

use anyhow::{bail, Context, Result};
use axonerai::provider::Message;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

const FILE_BEGIN: &str = "===FILE:";
const FILE_END: &str = "===ENDFILE===";

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
        // Real LLM path via provider cascade (or local-only if --local).
        let provider: Box<dyn axonerai::provider::Provider + Send + Sync> = if opts.local {
            std::env::set_var("OPENAI_API_BASE", "http://127.0.0.1:11434/v1");
            std::env::set_var("OPENAI_API_KEY", "ollama");
            crate::provider_cascade::build_provider_single_pub()
        } else {
            crate::provider_cascade::build_provider()
        };
        let ctx = gather_source_context(work_dir)?;
        let in_chars = opts.task.len() + ctx.len();
        let edits = request_edits(&*provider, &opts.task, &ctx).await?;
        let out_chars: usize = edits.iter().map(|(p, c)| p.len() + c.len()).sum();
        apply_file_edits(&edits, work_dir)?;
        (in_chars, out_chars)
    };

    // Verify the edit compiles.
    let status = Command::new("cargo")
        .arg("check")
        .current_dir(work_dir)
        .status()
        .context("spawn cargo check")?;
    if !status.success() {
        bail!("cargo check failed after applying gen edits");
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

/// Collect up to ~8 KB of source context from `src/` (or the work dir root).
fn gather_source_context(work_dir: &Path) -> Result<String> {
    let mut out = String::new();
    let src_dir = work_dir.join("src");
    let base = if src_dir.is_dir() {
        src_dir
    } else {
        work_dir.to_path_buf()
    };
    if let Ok(entries) = std::fs::read_dir(&base) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().map(|e| e == "rs").unwrap_or(false) {
                if let Ok(content) = std::fs::read_to_string(&p) {
                    let rel = p.strip_prefix(work_dir).unwrap_or(&p);
                    let snippet = &content[..content.len().min(3000)];
                    out.push_str(&format!("// {}\n{}\n\n", rel.display(), snippet));
                    if out.len() > 8000 {
                        break;
                    }
                }
            }
        }
    }
    Ok(out)
}

/// Call the provider and return parsed `(rel_path, content)` edits.
async fn request_edits(
    provider: &(dyn axonerai::provider::Provider + Send + Sync),
    task: &str,
    source_ctx: &str,
) -> Result<Vec<(String, String)>> {
    let system = format!(
        "You are a coding assistant. Make the requested change and output ONLY \
         the modified files using this exact format for each changed file:\n\n\
         {FILE_BEGIN} path/to/file.rs===\n<complete file content>\n{FILE_END}\n\n\
         Do not include any explanation outside these delimited blocks."
    );

    let user_content = if source_ctx.is_empty() {
        format!("Task: {task}")
    } else {
        format!("Task: {task}\n\nSource files:\n{source_ctx}")
    };

    let messages = vec![Message {
        role: "user".into(),
        content: user_content,
    }];

    let resp = provider
        .complete(messages, None, Some(4096), Some(system))
        .await
        .context("provider.complete for gen")?;

    let text = resp.text.unwrap_or_default();
    let edits = parse_file_edits(&text)?;
    Ok(edits)
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
}
