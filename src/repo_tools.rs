//! Repo-scoped file tools: read_file, list_dir (Phase 1), write_file (Phase 2). Paths under CHUMP_REPO/CHUMP_HOME/cwd.

use crate::chump_log;
use crate::delegate_tool;
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
        let out = if let (Some(s), Some(e)) = (start_line, end_line) {
            if s > e {
                return Err(anyhow!("start_line must be <= end_line"));
            }
            let lines: Vec<&str> = content.lines().collect();
            let len = lines.len();
            let s1 = (s - 1).min(len);
            let e1 = e.min(len);
            lines[s1..e1].join("\n")
        } else if let Some(s) = start_line {
            let lines: Vec<&str> = content.lines().collect();
            let len = lines.len();
            let s1 = (s - 1).min(len);
            lines[s1..].join("\n")
        } else if let Some(e) = end_line {
            let lines: Vec<&str> = content.lines().collect();
            let len = lines.len();
            let e1 = e.min(len);
            lines[..e1].join("\n")
        } else {
            let max_chars: usize = std::env::var("CHUMP_READ_FILE_MAX_CHARS")
                .ok()
                .and_then(|v| v.trim().parse().ok())
                .filter(|&n| n >= 500)
                .unwrap_or(4000);
            if content.len() > max_chars {
                match delegate_tool::run_delegate_summarize(&content, 5).await {
                    Ok(summary) => {
                        let char_count = content.chars().count();
                        let tail: String = content
                            .chars()
                            .skip(char_count.saturating_sub(500))
                            .collect();
                        format!(
                            "[Auto-summary of {} chars: {}]\n\n--- Last 500 chars ---\n{}",
                            content.len(),
                            summary.trim(),
                            tail
                        )
                    }
                    Err(_) => {
                        format!(
                            "{}… [truncated at {} chars; summary failed]",
                            content.chars().take(max_chars - 50).collect::<String>(),
                            content.len()
                        )
                    }
                }
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
            let prior = match crate::acp_server::acp_maybe_read_text_file(&path_str, None, None)
                .await
            {
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

        match patch_apply::apply_unified_diff(&content, diff) {
            Ok(new_content) => {
                let baseline = if test_aware::test_aware_enabled() {
                    Some(
                        test_aware::capture_baseline()
                            .map_err(|e| anyhow!("test_aware baseline: {}", e))?,
                    )
                } else {
                    None
                };
                fs::write(&path, &new_content).map_err(|e| anyhow!("write failed: {}", e))?;
                chump_log::log_patch_file(&path.display().to_string(), diff.len(), "applied");
                if let Some((_, _, ref failing)) = baseline {
                    test_aware::check_regression(failing).map_err(|e| anyhow!("{}", e))?;
                }
                Ok(format!("Patched {} successfully.", path_str))
            }
            Err(e) => {
                chump_log::log_patch_file(&path.display().to_string(), diff.len(), "mismatch");
                Ok(patch_recovery_message(&content, diff, &e))
            }
        }
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
}
