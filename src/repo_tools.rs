//! Repo-scoped file tools: read_file, list_dir (Phase 1), write_file (Phase 2). Paths under CHUMP_REPO/CHUMP_HOME/cwd.

use crate::chump_log;
use crate::repo_path;
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
            content
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
        if !repo_path::repo_root_is_explicit() {
            return Err(anyhow!(
                "write_file requires CHUMP_REPO or CHUMP_HOME to be set (no arbitrary writes)"
            ));
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

        let path = repo_path::resolve_under_root_for_write(&path_str).map_err(|e| anyhow!("{}", e))?;
        if path.exists() && path.is_dir() {
            return Err(anyhow!("path is a directory, not a file: {}", path.display()));
        }
        let parent = path.parent().ok_or_else(|| anyhow!("no parent dir"))?;
        if !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| anyhow!("create_dir_all failed: {}", e))?;
        }

        let (op, result) = match mode.as_str() {
            "overwrite" => {
                fs::write(&path, &content).map_err(|e| anyhow!("write failed: {}", e))?;
                ("overwrite", Ok("Written.".to_string()))
            }
            "append" => {
                let mut f = fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
                    .map_err(|e| anyhow!("open for append failed: {}", e))?;
                f.write_all(content.as_bytes())
                    .map_err(|e| anyhow!("append failed: {}", e))?;
                ("append", Ok("Appended.".to_string()))
            }
            _ => return Err(anyhow!("mode must be overwrite or append")),
        };
        chump_log::log_write_file(path.display().to_string(), content.len(), op);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use serde_json::json;
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
        let out = ReadFileTool.execute(json!({ "path": "hello.txt" })).await.unwrap();
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
        let out = ReadFileTool.execute(json!({ "path": "../etc/passwd" })).await;
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
}
