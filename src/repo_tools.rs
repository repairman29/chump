//! Repo-scoped file tools: read_file, list_dir (Phase 1), write_file (Phase 2). Paths under CHUMP_REPO/CHUMP_HOME/cwd.

use crate::chump_log;
use crate::patch_apply;
use crate::repo_path;
use crate::test_aware;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;

fn get_path(input: &Value) -> Result<String> {
    input
        .get("path")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("missing or empty path"))
}

fn get_patch_target_path(input: &Value) -> Result<String> {
    if let Some(s) = input.get("file_path").and_then(|v| v.as_str()) {
        let t = s.trim();
        if !t.is_empty() {
            return Ok(t.to_string());
        }
    }
    get_path(input)
}

fn format_numbered_snippet(content: &str, focus_1based: Option<u64>) -> String {
    const WINDOW: usize = 45;
    const MAX_WHOLE: usize = 200;
    let lines: Vec<&str> = content.lines().collect();
    let n = lines.len();
    if n == 0 {
        return "(empty file)".to_string();
    }
    if n <= MAX_WHOLE {
        return lines
            .iter()
            .enumerate()
            .map(|(i, l)| format!("{:4}| {}", i + 1, l))
            .collect::<Vec<_>>()
            .join("\n");
    }
    let center = focus_1based.unwrap_or(1).max(1) as usize;
    let lo = center.saturating_sub(WINDOW).max(1);
    let hi = (center + WINDOW).min(n);
    let header = format!("(lines {}-{} of {})\n", lo, hi, n);
    let body: String = lines[lo - 1..hi]
        .iter()
        .enumerate()
        .map(|(i, l)| format!("{:4}| {}", lo + i, l))
        .collect::<Vec<_>>()
        .join("\n");
    header + &body
}

fn patch_recovery_message(content: &str, diff: &str, err: &patch_apply::PatchApplyError) -> String {
    let focus_from_err = match err {
        patch_apply::PatchApplyError::ContextMismatch {
            old_line_1based, ..
        } => Some(*old_line_1based as u64),
        _ => None,
    };
    let focus = patch_apply::first_target_line_1based(diff).or(focus_from_err);
    let snippet = format_numbered_snippet(content, focus);
    format!(
        "Diff failed to apply due to context mismatch or an invalid diff.\nDetails: {}\n\nHere is the actual current code at that location (line numbers on the left). Please generate a new patch_file tool call with corrected context.\n\n{}",
        err, snippet
    )
}

/// Best-effort 1-based line number from executor error text (e.g. patch parse / hunk messages).
fn line_focus_from_error_message(msg: &str) -> Option<u64> {
    for (idx, _) in msg.match_indices("line ") {
        let rest = msg[idx + "line ".len()..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>();
        if let Ok(n) = rest.parse::<u64>() {
            if n >= 1 {
                return Some(n);
            }
        }
    }
    None
}

/// When repo file tools fail with `Err`, attach numbered file context so the model can retry
/// (`patch_file` soft-fail recovery is separate — this covers hard errors like I/O).
pub(crate) fn enrich_file_tool_error(
    tool_name: &str,
    input: &Value,
    err: &dyn std::fmt::Display,
) -> String {
    let base = format!("Tool error: {}", err);
    if !matches!(tool_name, "patch_file" | "write_file" | "read_file") {
        return base;
    }
    if !repo_path::repo_root_is_explicit() {
        return base;
    }
    let path_str = match tool_name {
        "patch_file" => get_patch_target_path(input).ok(),
        _ => get_path(input).ok(),
    };
    let Some(path_str) = path_str else {
        return base;
    };
    let resolved = match tool_name {
        "write_file" | "patch_file" => repo_path::resolve_under_root_for_write(&path_str).ok(),
        "read_file" => repo_path::resolve_under_root(&path_str).ok(),
        _ => None,
    };
    let Some(path) = resolved else {
        return base;
    };
    if !path.is_file() {
        return base;
    }
    let Ok(content) = fs::read_to_string(&path) else {
        return base;
    };
    let focus = line_focus_from_error_message(&base);
    let snippet = format_numbered_snippet(&content, focus);
    format!(
        "{}\n\n--- Current repo file `{}` (numbered lines; retry with read_file / patch_file) ---\n{}",
        base, path_str, snippet
    )
}

pub struct ReadFileTool;

#[async_trait]
impl Tool for ReadFileTool {
    fn name(&self) -> String {
        "read_file".to_string()
    }

    fn description(&self) -> String {
        "Read a file from the repo. Path is relative to repo root (CHUMP_REPO or CHUMP_HOME). Optional start_line and end_line (1-based) to return a line range.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "File path relative to repo root" },
                "start_line": { "type": "number", "description": "Optional first line (1-based)" },
                "end_line": { "type": "number", "description": "Optional last line (1-based)" }
            },
            "required": ["path"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let path_str = get_path(&input)?;
        let start_line = input
            .get("start_line")
            .and_then(|v| v.as_f64())
            .map(|n| n as usize)
            .filter(|&n| n >= 1);
        let end_line = input
            .get("end_line")
            .and_then(|v| v.as_f64())
            .map(|n| n as usize)
            .filter(|&n| n >= 1);

        // ACP delegation: when running under an ACP client that declared fs.read,
        // route the read through the client's filesystem instead of touching local
        // disk. Convert (start_line, end_line) → ACP's (line, limit). We pass the
        // raw path string — the client resolves relative to its session cwd.
        let acp_line = start_line.map(|n| n as u32);
        let acp_limit = match (start_line, end_line) {
            (Some(s), Some(e)) if e >= s => Some((e - s + 1) as u32),
            (None, Some(e)) => Some(e as u32),
            _ => None,
        };
        if let Some(acp_result) =
            crate::acp_server::acp_maybe_read_text_file(&path_str, acp_line, acp_limit).await
        {
            // Client owns the result — return whatever it gave us (success or error).
            return acp_result;
        }

        let path = repo_path::resolve_under_root(&path_str).map_err(|e| anyhow!("{}", e))?;
        if !path.is_file() {
            return Err(anyhow!("not a file: {}", path.display()));
        }
        let content = fs::read_to_string(&path).map_err(|e| anyhow!("read failed: {}", e))?;

        // Hard cap for ALL reads — including line-range reads. Defense-in-depth
        // for the regression guard: the matrix caught a model that sidesteps
        // the no-range truncation path by asking for `start_line=1, end_line=<EOF>`
        // and pulling the whole file anyway. Cap defaults to 4× the no-range
        // preview size so legitimate line ranges work but pathological ones
        // get cleanly truncated with a sentinel.
        let hard_cap: usize = std::env::var("CHUMP_READ_FILE_HARD_CAP_CHARS")
            .ok()
            .and_then(|v| v.trim().parse().ok())
            .filter(|&n| n >= 2000)
            .unwrap_or_else(|| {
                std::env::var("CHUMP_READ_FILE_MAX_CHARS")
                    .ok()
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .filter(|&n| n >= 500)
                    .unwrap_or(6000)
                    .saturating_mul(4)
            });

        // Enforce hard cap on any joined-lines output. Returns a sentinel-
        // tagged truncation explaining to the model what happened + inviting
        // a narrower retry.
        let enforce_cap = |out: String, req: &str| -> String {
            if out.len() <= hard_cap {
                return out;
            }
            let truncated: String = out.chars().take(hard_cap).collect();
            format!(
                "{}\n\n[…truncated: {} chars > hard cap {} — {} returned too much content; retry with a narrower start_line/end_line range]",
                truncated,
                out.len(),
                hard_cap,
                req
            )
        };

        let out = if let (Some(s), Some(e)) = (start_line, end_line) {
            if s > e {
                return Err(anyhow!("start_line must be <= end_line"));
            }
            let lines: Vec<&str> = content.lines().collect();
            let len = lines.len();
            let s1 = (s - 1).min(len);
            let e1 = e.min(len);
            enforce_cap(lines[s1..e1].join("\n"), &format!("lines {}-{}", s, e))
        } else if let Some(s) = start_line {
            let lines: Vec<&str> = content.lines().collect();
            let len = lines.len();
            let s1 = (s - 1).min(len);
            enforce_cap(lines[s1..].join("\n"), &format!("lines {}-end", s))
        } else if let Some(e) = end_line {
            let lines: Vec<&str> = content.lines().collect();
            let len = lines.len();
            let e1 = e.min(len);
            enforce_cap(lines[..e1].join("\n"), &format!("lines 1-{}", e))
        } else {
            // Max chars returned for a full-file read (no line range). The model
            // gets a numbered-line preview of this size; beyond it, it must
            // re-read with start_line/end_line for the rest.
            //
            // 6000 chars ≈ 1500 tokens — leaves room for system prompt,
            // message history, and tool schemas while staying comfortably
            // under an 8192-token single-sequence backend budget. Was 12000
            // briefly; that pushed the narration request for a file like
            // src/local_openai.rs (1547 lines, truncated to 285) to 26K total
            // chars ≈ 6.6K tokens — right at the vLLM-MLX budget edge —
            // which triggered a long generation + Metal GPU crash (Chump
            // task #58). Override via CHUMP_READ_FILE_MAX_CHARS=<N> when
            // running on a large-context backend (Ollama 32k, OpenAI API).
            let max_chars: usize = std::env::var("CHUMP_READ_FILE_MAX_CHARS")
                .ok()
                .and_then(|v| v.trim().parse().ok())
                .filter(|&n| n >= 500)
                .unwrap_or(12000);
            if content.len() > max_chars {
                // Return numbered-line preview (head) instead of LLM summarization.
                // The delegate summarize sent a separate LLM request that blocked
                // single-sequence inference servers (vLLM-MLX max_num_seqs=1),
                // causing the next agent loop LLM call to queue and timeout/crash.
                let lines: Vec<&str> = content.lines().collect();
                let total_lines = lines.len();
                // Show enough head lines to fit within max_chars
                let mut preview_lines = 0;
                let mut chars_used = 0usize;
                for (i, line) in lines.iter().enumerate() {
                    // Line number prefix: "  123| "
                    let prefix_len = format!("{:>4}| ", i + 1).len();
                    chars_used += prefix_len + line.len() + 1;
                    if chars_used > max_chars {
                        break;
                    }
                    preview_lines = i + 1;
                }
                let numbered: String = lines[..preview_lines]
                    .iter()
                    .enumerate()
                    .map(|(i, l)| format!("{:>4}| {}", i + 1, l))
                    .collect::<Vec<_>>()
                    .join("\n");
                format!(
                    "--- Current repo file `{}` (numbered lines; retry with read_file / patch_file) ---\n(lines 1-{} of {})\n{}",
                    path_str, preview_lines, total_lines, numbered
                )
            } else {
                content.to_string()
            }
        };
        Ok(out)
    }
}

pub struct ListDirTool;

#[async_trait]
impl Tool for ListDirTool {
    fn name(&self) -> String {
        "list_dir".to_string()
    }

    fn description(&self) -> String {
        "List directory contents (names and types: file or dir). Path is relative to repo root; default is '.'.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Directory path relative to repo root (default .)" }
            }
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let path_str = input
            .get("path")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| ".".to_string());
        let path = repo_path::resolve_under_root(&path_str).map_err(|e| anyhow!("{}", e))?;
        if !path.is_dir() {
            return Err(anyhow!("not a directory: {}", path.display()));
        }
        let mut entries: Vec<String> = fs::read_dir(&path)
            .map_err(|e| anyhow!("read_dir failed: {}", e))?
            .filter_map(|e| e.ok())
            .map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                let kind = if e.path().is_dir() { "dir" } else { "file" };
                format!("{} ({})", name, kind)
            })
            .collect();
        entries.sort();
        Ok(entries.join("\n"))
    }
}

pub struct WriteFileTool;

#[async_trait]
impl Tool for WriteFileTool {
    fn name(&self) -> String {
        "write_file".to_string()
    }

    fn description(&self) -> String {
        "Write or append to a file in the repo. Path relative to repo root. Only allowed when CHUMP_REPO or CHUMP_HOME is set. Mode: overwrite (default) or append.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "File path relative to repo root" },
                "content": { "type": "string", "description": "Content to write" },
                "mode": { "type": "string", "description": "overwrite (default) or append" }
            },
            "required": ["path", "content"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let path_str = get_path(&input)?;
        let content = input
            .get("content")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing content"))?
            .to_string();
        let mode = input
            .get("mode")
            .and_then(|v| v.as_str())
            .unwrap_or("overwrite")
            .trim()
            .to_lowercase();

        // ACP delegation: when running under an ACP client that declared fs.write,
        // route the write through the client's filesystem. Append mode needs a
        // read-modify-write because ACP's fs/write_text_file only does overwrite.
        // Skip the local CHUMP_REPO/CHUMP_HOME check — under ACP the client
        // owns access control.
        let acp_payload = if mode == "append" {
            // Read existing content (treat read failure as "file doesn't exist yet").
            let prior =
                match crate::acp_server::acp_maybe_read_text_file(&path_str, None, None).await {
                    Some(Ok(c)) => Some(c),
                    Some(Err(_)) => Some(String::new()),
                    None => None,
                };
            prior.map(|p| format!("{}{}", p, content))
        } else {
            Some(content.clone())
        };
        if let Some(payload) = acp_payload {
            if let Some(acp_result) =
                crate::acp_server::acp_maybe_write_text_file(&path_str, &payload).await
            {
                return acp_result.map(|_| {
                    format!(
                        "wrote {} bytes to {} via ACP fs/write_text_file ({} mode)",
                        payload.len(),
                        path_str,
                        mode
                    )
                });
            }
        }

        if !repo_path::repo_root_is_explicit() {
            return Err(anyhow!(
                "write_file requires CHUMP_REPO or CHUMP_HOME to be set (no arbitrary writes)"
            ));
        }
        let path =
            repo_path::resolve_under_root_for_write(&path_str).map_err(|e| anyhow!("{}", e))?;
        if path.exists() && path.is_dir() {
            return Err(anyhow!(
                "path is a directory, not a file: {}",
                path.display()
            ));
        }
        let parent = path.parent().ok_or_else(|| anyhow!("no parent dir"))?;
        if !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| anyhow!("create_dir_all failed: {}", e))?;
        }

        let baseline = if test_aware::test_aware_enabled() {
            Some(
                test_aware::capture_baseline()
                    .map_err(|e| anyhow!("test_aware baseline: {}", e))?,
            )
        } else {
            None
        };

        let (op, result) = match mode.as_str() {
            "overwrite" => {
                fs::write(&path, &content).map_err(|e| anyhow!("write failed: {}", e))?;
                let msg = if let Some((_, _, ref failing)) = baseline {
                    if let Err(e) = test_aware::check_regression(failing) {
                        return Err(anyhow!("{}", e));
                    }
                    "Written."
                } else {
                    "Written."
                };
                ("overwrite", Ok(msg.to_string()))
            }
            "append" => {
                let mut f = fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
                    .map_err(|e| anyhow!("open for append failed: {}", e))?;
                f.write_all(content.as_bytes())
                    .map_err(|e| anyhow!("append failed: {}", e))?;
                let msg = if let Some((_, _, ref failing)) = baseline {
                    if let Err(e) = test_aware::check_regression(failing) {
                        return Err(anyhow!("{}", e));
                    }
                    "Appended."
                } else {
                    "Appended."
                };
                ("append", Ok(msg.to_string()))
            }
            _ => return Err(anyhow!("mode must be overwrite or append")),
        };
        chump_log::log_write_file(path.display().to_string(), content.len(), op);
        result
    }
}

/// Apply a standard unified diff to one repo file. On context mismatch, returns Ok(...) with the
/// real file excerpt so the model can self-correct in the same turn (no wasted Err).
pub struct PatchFileTool;

#[async_trait]
impl Tool for PatchFileTool {
    fn name(&self) -> String {
        "patch_file".to_string()
    }

    fn description(&self) -> String {
        "Apply a unified diff to a single file under the repo root. Use `path` or `file_path` (relative to CHUMP_REPO/CHUMP_HOME). The `diff` string must be one file pair (`---` / `+++` and hunks). Context lines must match the file exactly—use read_file first. If the patch does not apply, the tool still succeeds and returns the current file excerpt so you can emit a corrected patch_file call.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "File path relative to repo root (either this or file_path)" },
                "file_path": { "type": "string", "description": "Alias for path" },
                "diff": { "type": "string", "description": "Complete unified diff for this file only" }
            },
            "required": ["diff"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !repo_path::repo_root_is_explicit() {
            return Err(anyhow!(
                "patch_file requires CHUMP_REPO or CHUMP_HOME to be set"
            ));
        }
        let path_str = get_patch_target_path(&input)?;
        let diff = input
            .get("diff")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing diff"))?;

        let path =
            repo_path::resolve_under_root_for_write(&path_str).map_err(|e| anyhow!("{}", e))?;
        if !path.is_file() {
            return Err(anyhow!("not a file: {}", path.display()));
        }
        let content = fs::read_to_string(&path).map_err(|e| anyhow!("read failed: {}", e))?;

        // Run the parse+apply on a blocking thread so a panic in the upstream
        // `patch` crate (which happens on LLM-malformed diffs even with
        // catch_unwind inside apply_unified_diff) can't corrupt the tokio
        // runtime on the main thread.
        let diff_owned = diff.to_string();
        let content_for_apply = content.clone();
        let strict_result = tokio::task::spawn_blocking({
            let d = diff_owned.clone();
            let c = content_for_apply.clone();
            move || patch_apply::apply_unified_diff(&c, &d)
        })
        .await
        .map_err(|e| anyhow!("patch apply task failed: {}", e))?;

        // On strict failure, try fuzzy matching (whitespace-tolerant, ±3 line drift).
        let fuzzy_result: Option<Result<String, patch_apply::PatchApplyError>> =
            if strict_result.is_err() {
                tracing::info!(
                    path = %path_str,
                    "patch_file strict failed, attempting fuzzy fallback"
                );
                let d = diff_owned.clone();
                let c = content.clone();
                tokio::task::spawn_blocking(move || patch_apply::apply_unified_diff_fuzzy(&c, &d))
                    .await
                    .ok()
            } else {
                None
            };

        // INFRA-785: tier-c headerless fallback. Smaller models (Llama 3.3,
        // Mistral) sometimes emit unified diffs without `---`/`+++` filename
        // header lines — just `@@` hunks. Tier-c synthesizes a placeholder
        // header and reuses the strict→fuzzy applicator under the hood. Only
        // attempted when both prior tiers failed AND the diff looks
        // structurally headerless, to avoid masking legitimate parse errors
        // on properly-headered diffs.
        let headerless_result: Option<Result<String, patch_apply::PatchApplyError>> =
            if strict_result.is_err()
                && fuzzy_result.as_ref().is_none_or(|r| r.is_err())
                && patch_apply::looks_headerless(&diff_owned)
            {
                tracing::info!(
                    path = %path_str,
                    "patch_file fuzzy failed; diff looks headerless, attempting tier-c parse"
                );
                let d = diff_owned.clone();
                let c = content.clone();
                tokio::task::spawn_blocking(move || {
                    patch_apply::apply_unified_diff_headerless(&c, &d)
                })
                .await
                .ok()
            } else {
                None
            };

        let (new_content, mode) = match (&strict_result, &fuzzy_result, &headerless_result) {
            (Ok(nc), _, _) => (nc.clone(), "applied"),
            (_, Some(Ok(nc)), _) => (nc.clone(), "applied-fuzzy"),
            (_, _, Some(Ok(nc))) => (nc.clone(), "applied-headerless"),
            _ => {
                let e = strict_result.as_ref().unwrap_err();
                chump_log::log_patch_file(
                    &path.display().to_string(),
                    diff.len(),
                    "mismatch-all-tiers",
                );
                let mut msg = patch_recovery_message(&content, diff, e);
                msg.push_str(
                    "\n\nNote: patch_file also failed with fuzzy matching (whitespace-tolerant, ±3 line context drift) \
                     and headerless-diff parsing (tier-c, INFRA-785). \
                     Try using read_file to get the exact current content, then use write_file to write \
                     the corrected version directly.",
                );
                return Ok(msg);
            }
        };

        let baseline = if test_aware::test_aware_enabled() {
            Some(
                test_aware::capture_baseline()
                    .map_err(|e| anyhow!("test_aware baseline: {}", e))?,
            )
        } else {
            None
        };
        fs::write(&path, &new_content).map_err(|e| anyhow!("write failed: {}", e))?;
        // INFRA-785: tier-c applies emit a dedicated tracing line so dashboards
        // can count Llama-style headerless-diff successes separately from the
        // strict/fuzzy tiers (otherwise the obs signal is buried in chump_log).
        if mode == "applied-headerless" {
            tracing::info!(
                path = %path_str,
                mode = "applied-headerless",
                "patch_file tier-c headerless-diff applied (INFRA-785)"
            );
        }
        chump_log::log_patch_file(&path.display().to_string(), diff.len(), mode);
        if let Some((_, _, ref failing)) = baseline {
            test_aware::check_regression(failing).map_err(|e| anyhow!("{}", e))?;
        }
        Ok(format!("Patched {} successfully.", path_str))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use serial_test::serial;
    use std::fs;
    use std::path::PathBuf;

    /// Temp dir under current dir so canonicalize matches (avoid /tmp vs /private/tmp on macOS).
    fn test_dir(name: &str) -> PathBuf {
        let d = PathBuf::from("target").join(name);
        let _ = fs::create_dir_all(&d);
        d.canonicalize().unwrap_or(d)
    }

    #[tokio::test]
    #[serial]
    async fn read_file_returns_content() {
        let dir = test_dir("chump_read_file_test");
        let file = dir.join("hello.txt");
        fs::write(&file, "hello world").unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ReadFileTool
            .execute(json!({ "path": "hello.txt" }))
            .await
            .unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert_eq!(out, "hello world");
        let _ = fs::remove_dir_all("target/chump_read_file_test");
    }

    fn restore_env(name: &str, prev: Option<String>) {
        if let Some(p) = prev {
            std::env::set_var(name, p);
        } else {
            std::env::remove_var(name);
        }
    }

    /// Regression guard for the delegate_summarize crash (Apr 2026).
    /// Files larger than CHUMP_READ_FILE_MAX_CHARS must return a numbered-line
    /// preview — they must NOT call delegate_tool::run_delegate_summarize, which
    /// fires a separate LLM request during tool execution and crashes single-
    /// sequence inference servers (vLLM-MLX max_num_seqs=1) with a Metal
    /// assertion when the agent loop's next LLM call queues behind it.
    ///
    /// If anyone restores the in-tool LLM summarize call, this test fails
    /// synchronously at `cargo test`. The dogfood matrix can't guard this
    /// reliably because capable models use start_line/end_line to sidestep
    /// the threshold.
    #[tokio::test]
    #[serial]
    async fn read_file_large_returns_numbered_preview_no_llm_call() {
        let dir = test_dir("chump_read_file_large_test");
        let file = dir.join("big.txt");
        // ~40 chars/line × 400 lines = ~16 KB, well above the 6000-char default.
        let content: String = (1..=400)
            .map(|i| format!("this is line {:04} of the big test file.\n", i))
            .collect();
        fs::write(&file, &content).unwrap();

        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_max = std::env::var("CHUMP_READ_FILE_MAX_CHARS").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        std::env::remove_var("CHUMP_READ_FILE_MAX_CHARS");

        let out = ReadFileTool
            .execute(json!({ "path": "big.txt" }))
            .await
            .unwrap();

        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        restore_env("CHUMP_READ_FILE_MAX_CHARS", prev_max);

        // Sentinel from the truncation path. If this assertion fails, either:
        //   (a) someone restored the LLM summarize call (the bug we're guarding), or
        //   (b) someone removed the numbered-line preview header.
        // Either case needs review before merging.
        assert!(
            out.contains("numbered lines; retry with read_file / patch_file"),
            "large file should return numbered-line preview (regression: delegate_summarize bug). Got:\n{}",
            out.chars().take(400).collect::<String>()
        );
        // The preview must NOT contain the old LLM-summary format.
        assert!(
            !out.starts_with("[Auto-summary of"),
            "large file must NOT use LLM auto-summary (crashes single-sequence backends). Got:\n{}",
            out.chars().take(200).collect::<String>()
        );

        let _ = fs::remove_dir_all("target/chump_read_file_large_test");
    }

    /// Task #58 pass-2 regression guard: a line-range read that requests
    /// MORE than `CHUMP_READ_FILE_HARD_CAP_CHARS` must be truncated with the
    /// sentinel. Protects against the model sidestepping the no-range cap
    /// by asking for `start_line=1, end_line=<EOF>`.
    #[tokio::test]
    #[serial]
    async fn read_file_line_range_enforces_hard_cap() {
        let dir = test_dir("chump_read_file_hard_cap_test");
        let file = dir.join("huge.txt");
        // ~40 chars/line × 2000 lines = ~80 KB, way over any reasonable cap.
        let content: String = (1..=2000)
            .map(|i| format!("this is line {:04} of the huge test file.\n", i))
            .collect();
        fs::write(&file, &content).unwrap();

        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_cap = std::env::var("CHUMP_READ_FILE_HARD_CAP_CHARS").ok();
        let prev_max = std::env::var("CHUMP_READ_FILE_MAX_CHARS").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        std::env::remove_var("CHUMP_READ_FILE_HARD_CAP_CHARS");
        std::env::remove_var("CHUMP_READ_FILE_MAX_CHARS");

        // Request the WHOLE file via line range (the model's usual sidestep).
        let out = ReadFileTool
            .execute(json!({ "path": "huge.txt", "start_line": 1, "end_line": 2000 }))
            .await
            .unwrap();

        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        restore_env("CHUMP_READ_FILE_HARD_CAP_CHARS", prev_cap);
        restore_env("CHUMP_READ_FILE_MAX_CHARS", prev_max);

        // Default hard cap = 4× max_chars = 24000. Output should be strictly
        // smaller than the raw content (80K+) and contain the truncation
        // sentinel.
        assert!(
            out.len() < content.len(),
            "expected truncation: out.len={} content.len={}",
            out.len(),
            content.len()
        );
        assert!(
            out.contains("hard cap") && out.contains("retry with a narrower"),
            "expected truncation sentinel. Got tail:\n{}",
            out.chars()
                .rev()
                .take(300)
                .collect::<String>()
                .chars()
                .rev()
                .collect::<String>()
        );

        let _ = fs::remove_dir_all("target/chump_read_file_hard_cap_test");
    }

    #[tokio::test]
    #[serial]
    async fn read_file_rejects_path_traversal() {
        let dir = test_dir("chump_read_traversal_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ReadFileTool
            .execute(json!({ "path": "../etc/passwd" }))
            .await;
        restore_env("CHUMP_REPO", prev_repo);
        assert!(out.is_err());
        assert!(out.unwrap_err().to_string().contains(".."));
        let _ = fs::remove_dir_all("target/chump_read_traversal_test");
    }

    #[tokio::test]
    #[serial]
    async fn list_dir_returns_entries() {
        let dir = test_dir("chump_list_dir_test");
        fs::write(dir.join("a.txt"), "").unwrap();
        fs::create_dir_all(dir.join("sub")).unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ListDirTool.execute(json!({ "path": "." })).await.unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        assert!(out.contains("a.txt"));
        assert!(out.contains("sub"));
        let _ = fs::remove_dir_all("target/chump_list_dir_test");
    }

    #[tokio::test]
    #[serial]
    async fn write_file_requires_chump_repo() {
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        let out = WriteFileTool
            .execute(json!({ "path": "x.txt", "content": "x" }))
            .await;
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.is_err());
        assert!(out.unwrap_err().to_string().contains("CHUMP_REPO"));
    }

    #[tokio::test]
    #[serial]
    async fn write_file_overwrites_when_repo_set() {
        let dir = test_dir("chump_write_file_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        fs::write(dir.join("out.txt"), "old").unwrap();
        let _ = WriteFileTool
            .execute(json!({ "path": "out.txt", "content": "new" }))
            .await
            .unwrap();
        let written = repo_path::resolve_under_root_for_write("out.txt").unwrap();
        let content = fs::read_to_string(&written).unwrap();
        assert_eq!(content, "new");
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        let _ = fs::remove_dir_all("target/chump_write_file_test");
    }

    #[tokio::test]
    #[serial]
    async fn patch_file_applies_unified_diff() {
        let dir = test_dir("chump_patch_file_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        fs::write(dir.join("f.rs"), "fn foo() {\n    bar();\n}\n").unwrap();
        let diff = "\
--- a/f.rs
+++ b/f.rs
@@ -1,3 +1,3 @@
 fn foo() {
-    bar();
+    baz();
 }
";
        let out = PatchFileTool
            .execute(json!({ "path": "f.rs", "diff": diff }))
            .await
            .unwrap();
        assert!(out.contains("successfully"));
        let content = fs::read_to_string(dir.join("f.rs")).unwrap();
        assert!(content.contains("baz"));
        assert!(!content.contains("bar"));
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        let _ = fs::remove_dir_all("target/chump_patch_file_test");
    }

    #[tokio::test]
    #[serial]
    async fn patch_file_returns_recovery_on_mismatch() {
        let dir = test_dir("chump_patch_recover_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        fs::write(dir.join("f.rs"), "fn foo() {\n    bar();\n}\n").unwrap();
        let diff = "\
--- a/f.rs
+++ b/f.rs
@@ -1,3 +1,3 @@
 fn foo() {
-    WRONG;
+    baz();
 }
";
        let out = PatchFileTool
            .execute(json!({ "file_path": "f.rs", "diff": diff }))
            .await
            .unwrap();
        assert!(out.contains("Diff failed to apply"));
        assert!(out.contains("bar"));
        let content = fs::read_to_string(dir.join("f.rs")).unwrap();
        assert!(content.contains("bar"));
        restore_env("CHUMP_REPO", prev_repo);
        let _ = fs::remove_dir_all("target/chump_patch_recover_test");
    }

    #[tokio::test]
    #[serial]
    async fn enrich_file_tool_error_appends_numbered_snippet() {
        let dir = test_dir("chump_enrich_tool_error_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        fs::write(dir.join("x.txt"), "a\nb\nc\n").unwrap();
        let out = super::enrich_file_tool_error(
            "write_file",
            &json!({ "path": "x.txt", "content": "z" }),
            &"write failed: simulated",
        );
        assert!(out.starts_with("Tool error:"));
        assert!(out.contains("x.txt"));
        assert!(out.contains("   2| b"));
        restore_env("CHUMP_REPO", prev_repo);
        let _ = fs::remove_dir_all("target/chump_enrich_tool_error_test");
    }

    // ─── Pure helper: get_path ───────────────────────────────────────────────

    #[test]
    fn get_path_returns_trimmed_string() {
        let v = json!({ "path": "  src/foo.rs  " });
        assert_eq!(get_path(&v).unwrap(), "src/foo.rs");
    }

    #[test]
    fn get_path_rejects_missing_key() {
        let v = json!({ "other": "bar" });
        assert!(get_path(&v).is_err());
        assert!(get_path(&v).unwrap_err().to_string().contains("missing"));
    }

    #[test]
    fn get_path_rejects_empty_string() {
        let v = json!({ "path": "   " });
        assert!(get_path(&v).is_err());
    }

    #[test]
    fn get_path_rejects_non_string_value() {
        let v = json!({ "path": 42 });
        assert!(get_path(&v).is_err());
    }

    // ─── Pure helper: get_patch_target_path ─────────────────────────────────

    #[test]
    fn get_patch_target_path_prefers_file_path_key() {
        let v = json!({ "file_path": "a/b.rs", "path": "c/d.rs" });
        assert_eq!(get_patch_target_path(&v).unwrap(), "a/b.rs");
    }

    #[test]
    fn get_patch_target_path_falls_back_to_path() {
        let v = json!({ "path": "c/d.rs" });
        assert_eq!(get_patch_target_path(&v).unwrap(), "c/d.rs");
    }

    #[test]
    fn get_patch_target_path_trims_whitespace() {
        let v = json!({ "file_path": "  src/x.rs  " });
        assert_eq!(get_patch_target_path(&v).unwrap(), "src/x.rs");
    }

    #[test]
    fn get_patch_target_path_skips_empty_file_path_falls_back_to_path() {
        // file_path present but empty — should fall through to path
        let v = json!({ "file_path": "   ", "path": "real/file.rs" });
        assert_eq!(get_patch_target_path(&v).unwrap(), "real/file.rs");
    }

    #[test]
    fn get_patch_target_path_errors_when_both_absent() {
        let v = json!({ "diff": "@@ -1 +1 @@\n+line\n" });
        assert!(get_patch_target_path(&v).is_err());
    }

    // ─── Pure helper: format_numbered_snippet ────────────────────────────────

    #[test]
    fn format_numbered_snippet_empty_returns_sentinel() {
        let out = format_numbered_snippet("", None);
        assert_eq!(out, "(empty file)");
    }

    #[test]
    fn format_numbered_snippet_short_file_returns_all_lines_numbered() {
        let content = "alpha\nbeta\ngamma";
        let out = format_numbered_snippet(content, None);
        assert!(out.contains("   1| alpha"));
        assert!(out.contains("   2| beta"));
        assert!(out.contains("   3| gamma"));
        // Should not contain header for short files
        assert!(!out.contains("lines 1-"));
    }

    #[test]
    fn format_numbered_snippet_exactly_200_lines_no_header() {
        let content: String = (1..=200).map(|i| format!("line {}\n", i)).collect();
        // Lines collection from .lines() drops trailing newline — 200 lines
        let lines: Vec<_> = content.lines().collect();
        assert_eq!(lines.len(), 200);
        let out = format_numbered_snippet(&content, None);
        // At MAX_WHOLE boundary, should render without window header
        assert!(out.contains(" 200|"));
        assert!(!out.starts_with("(lines "));
    }

    #[test]
    fn format_numbered_snippet_large_file_shows_focus_window() {
        // Build a 300-line file (> MAX_WHOLE=200)
        let content: String = (1..=300).map(|i| format!("line {:03}\n", i)).collect();
        // Focus on line 150 — window of ±45 → lines 105-195
        let out = format_numbered_snippet(&content, Some(150));
        assert!(out.starts_with("(lines "));
        // Header must include the total line count
        assert!(out.contains("of 300"));
        // The focus line itself must be present
        assert!(out.contains("| line 150"));
    }

    #[test]
    fn format_numbered_snippet_large_file_clamps_focus_at_start() {
        let content: String = (1..=300).map(|i| format!("line {:03}\n", i)).collect();
        // Focus on line 1 — window lo should not go below 1
        let out = format_numbered_snippet(&content, Some(1));
        assert!(out.contains("(lines 1-"));
    }

    #[test]
    fn format_numbered_snippet_large_file_clamps_focus_at_end() {
        let content: String = (1..=300).map(|i| format!("line {:03}\n", i)).collect();
        // Focus near end — hi should not exceed n
        let out = format_numbered_snippet(&content, Some(299));
        assert!(out.contains("of 300"));
        assert!(out.contains("| line 300"));
    }

    // ─── Pure helper: line_focus_from_error_message ──────────────────────────

    #[test]
    fn line_focus_parses_first_line_number() {
        assert_eq!(
            line_focus_from_error_message("context mismatch at line 42"),
            Some(42)
        );
    }

    #[test]
    fn line_focus_returns_none_for_no_number() {
        assert_eq!(line_focus_from_error_message("some generic error"), None);
    }

    #[test]
    fn line_focus_ignores_line_zero() {
        // "line 0" should not be returned (we want 1-based only)
        // The impl requires n >= 1, so line 0 is skipped; but "line 5" later would be returned
        assert_eq!(line_focus_from_error_message("line 0 then line 5"), Some(5));
    }

    #[test]
    fn line_focus_handles_multiple_line_references() {
        // Should return the FIRST valid occurrence
        assert_eq!(
            line_focus_from_error_message("hunk failed at line 10, context at line 20"),
            Some(10)
        );
    }

    #[test]
    fn line_focus_handles_large_line_number() {
        assert_eq!(
            line_focus_from_error_message("parse error: line 99999"),
            Some(99999)
        );
    }

    // ─── Tool edge cases ─────────────────────────────────────────────────────

    #[tokio::test]
    #[serial]
    async fn read_file_start_gt_end_returns_error() {
        let dir = test_dir("chump_read_start_gt_end_test");
        let file = dir.join("f.txt");
        fs::write(&file, "a\nb\nc\n").unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ReadFileTool
            .execute(json!({ "path": "f.txt", "start_line": 5, "end_line": 2 }))
            .await;
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.is_err());
        assert!(out.unwrap_err().to_string().contains("start_line"));
        let _ = fs::remove_dir_all("target/chump_read_start_gt_end_test");
    }

    #[tokio::test]
    #[serial]
    async fn read_file_start_only_returns_tail() {
        let dir = test_dir("chump_read_start_only_test");
        let file = dir.join("lines.txt");
        fs::write(&file, "one\ntwo\nthree\nfour\n").unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ReadFileTool
            .execute(json!({ "path": "lines.txt", "start_line": 3 }))
            .await
            .unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.contains("three"));
        assert!(out.contains("four"));
        assert!(!out.contains("one"));
        assert!(!out.contains("two"));
        let _ = fs::remove_dir_all("target/chump_read_start_only_test");
    }

    #[tokio::test]
    #[serial]
    async fn read_file_end_only_returns_head() {
        let dir = test_dir("chump_read_end_only_test");
        let file = dir.join("lines.txt");
        fs::write(&file, "one\ntwo\nthree\nfour\n").unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ReadFileTool
            .execute(json!({ "path": "lines.txt", "end_line": 2 }))
            .await
            .unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.contains("one"));
        assert!(out.contains("two"));
        assert!(!out.contains("three"));
        let _ = fs::remove_dir_all("target/chump_read_end_only_test");
    }

    #[tokio::test]
    #[serial]
    async fn read_file_unicode_filename_via_tool() {
        let dir = test_dir("chump_read_unicode_name_test");
        let file = dir.join("файл.txt");
        fs::write(&file, "unicode content: 你好").unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ReadFileTool
            .execute(json!({ "path": "файл.txt" }))
            .await
            .unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.contains("你好"));
        let _ = fs::remove_dir_all("target/chump_read_unicode_name_test");
    }

    #[tokio::test]
    #[serial]
    async fn read_file_missing_path_field_errors() {
        let dir = test_dir("chump_read_no_path_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ReadFileTool.execute(json!({})).await;
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.is_err());
        let _ = fs::remove_dir_all("target/chump_read_no_path_test");
    }

    #[tokio::test]
    #[serial]
    async fn write_file_append_mode_via_tool() {
        let dir = test_dir("chump_write_append_via_tool_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        // First write establishes the file
        WriteFileTool
            .execute(json!({ "path": "append.txt", "content": "first\n", "mode": "overwrite" }))
            .await
            .unwrap();
        // Second call appends
        let result = WriteFileTool
            .execute(json!({ "path": "append.txt", "content": "second\n", "mode": "append" }))
            .await
            .unwrap();
        let written = dir.join("append.txt");
        let content = fs::read_to_string(&written).unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(result.contains("Appended"));
        assert_eq!(content, "first\nsecond\n");
        let _ = fs::remove_dir_all("target/chump_write_append_via_tool_test");
    }

    #[tokio::test]
    #[serial]
    async fn write_file_invalid_mode_errors() {
        let dir = test_dir("chump_write_bad_mode_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = WriteFileTool
            .execute(json!({ "path": "f.txt", "content": "x", "mode": "nope" }))
            .await;
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.is_err());
        assert!(out.unwrap_err().to_string().contains("mode"));
        let _ = fs::remove_dir_all("target/chump_write_bad_mode_test");
    }

    #[tokio::test]
    #[serial]
    async fn list_dir_default_path_dot_lists_root() {
        let dir = test_dir("chump_list_default_path_test");
        fs::write(dir.join("root_file.txt"), "").unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        // No "path" key — should default to "."
        let out = ListDirTool.execute(json!({})).await.unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        assert!(out.contains("root_file.txt (file)"));
        let _ = fs::remove_dir_all("target/chump_list_default_path_test");
    }

    #[tokio::test]
    #[serial]
    async fn list_dir_shows_file_and_dir_types() {
        let dir = test_dir("chump_list_types_test");
        fs::write(dir.join("plain.txt"), "").unwrap();
        fs::create_dir_all(dir.join("subdir")).unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ListDirTool.execute(json!({ "path": "." })).await.unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        assert!(out.contains("plain.txt (file)"));
        assert!(out.contains("subdir (dir)"));
        let _ = fs::remove_dir_all("target/chump_list_types_test");
    }

    #[tokio::test]
    #[serial]
    async fn list_dir_on_file_returns_error() {
        let dir = test_dir("chump_list_on_file_test");
        fs::write(dir.join("file.txt"), "").unwrap();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = ListDirTool.execute(json!({ "path": "file.txt" })).await;
        restore_env("CHUMP_REPO", prev_repo);
        assert!(out.is_err());
        let _ = fs::remove_dir_all("target/chump_list_on_file_test");
    }

    #[tokio::test]
    #[serial]
    async fn patch_file_requires_chump_repo() {
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        let out = PatchFileTool
            .execute(json!({ "path": "f.rs", "diff": "--- a/f.rs\n+++ b/f.rs\n@@ -1 +1 @@\n-old\n+new\n" }))
            .await;
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.is_err());
        assert!(out.unwrap_err().to_string().contains("CHUMP_REPO"));
    }

    #[tokio::test]
    #[serial]
    async fn patch_file_missing_diff_errors() {
        let dir = test_dir("chump_patch_no_diff_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = PatchFileTool.execute(json!({ "path": "f.rs" })).await;
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.is_err());
        assert!(out.unwrap_err().to_string().contains("diff"));
        let _ = fs::remove_dir_all("target/chump_patch_no_diff_test");
    }

    #[tokio::test]
    #[serial]
    async fn enrich_file_tool_error_falls_back_gracefully_without_repo() {
        // When CHUMP_REPO is unset, enrich should return bare "Tool error: ..." without panic
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        let out = super::enrich_file_tool_error(
            "read_file",
            &json!({ "path": "some/file.rs" }),
            &"not a file: some/file.rs",
        );
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.starts_with("Tool error:"));
        // No snippet should be injected since repo root is not set
        assert!(
            !out.contains("---"),
            "no snippet expected without repo root"
        );
    }

    #[tokio::test]
    #[serial]
    async fn enrich_file_tool_error_unknown_tool_returns_bare_error() {
        let dir = test_dir("chump_enrich_unknown_tool_test");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let out = super::enrich_file_tool_error(
            "unknown_tool",
            &json!({ "path": "x.txt" }),
            &"some error",
        );
        restore_env("CHUMP_REPO", prev_repo);
        // Unknown tool names should return base error only — no snippet enrichment
        assert_eq!(out, "Tool error: some error");
        let _ = fs::remove_dir_all("target/chump_enrich_unknown_tool_test");
    }
}
