//! memory_brain: read/write Chump's wiki files under CHUMP_BRAIN_PATH (/chump-brain/).

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::{Component, Path, PathBuf};

fn brain_root() -> Result<std::path::PathBuf> {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let base = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
    let path = if Path::new(&root).is_absolute() {
        std::path::PathBuf::from(root)
    } else {
        base.join(root)
    };
    Ok(path)
}

/// Normalize relative path: resolve . and ..; reject if would escape above root.
fn normalize_relative(rel: &str) -> Result<PathBuf> {
    let mut out = PathBuf::new();
    for c in Path::new(rel).components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    return Err(anyhow!("Path escapes brain root: {}", rel));
                }
            }
            Component::Normal(s) => out.push(s),
            Component::Prefix(_) | Component::RootDir => {
                return Err(anyhow!("Path must be relative: {}", rel));
            }
        }
    }
    Ok(out)
}

/// Resolve path under brain root; reject path traversal.
fn resolve_brain_path(relative: &str) -> Result<std::path::PathBuf> {
    let root = brain_root()?;
    let rel = relative.trim();
    if rel.is_empty() {
        return Err(anyhow!("path is empty"));
    }
    let normalized = normalize_relative(rel)?;
    let path = root.join(normalized);
    let root_abs = root.canonicalize().unwrap_or_else(|_| root.clone());
    if path.exists() {
        let path_abs = path.canonicalize().map_err(|e| anyhow!("{}", e))?;
        if !path_abs.starts_with(&root_abs) {
            return Err(anyhow!("Path escapes brain root: {}", relative));
        }
    } else if let Some(parent) = path.parent() {
        if parent != root && parent.exists() {
            let parent_abs = parent.canonicalize().map_err(|e| anyhow!("{}", e))?;
            if !parent_abs.starts_with(&root_abs) {
                return Err(anyhow!("Path escapes brain root: {}", relative));
            }
        }
    }
    Ok(path)
}

/// List .md files under brain root (no recursion depth limit for now, but we can add).
fn list_md_files(root: &Path, prefix: &str) -> Result<Vec<String>> {
    let mut out = Vec::new();
    let dir = if prefix.is_empty() {
        root.to_path_buf()
    } else {
        root.join(prefix)
    };
    if !dir.exists() {
        return Ok(out);
    }
    let entries = std::fs::read_dir(&dir)?;
    for e in entries {
        let e = e?;
        let name = e.file_name().to_string_lossy().to_string();
        let rel = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{}/{}", prefix, name)
        };
        if e.file_type()?.is_dir() {
            out.extend(list_md_files(root, &rel)?);
        } else if name.ends_with(".md") {
            out.push(rel);
        }
    }
    out.sort();
    Ok(out)
}

/// Search .md files for a query (grep -r -l).
fn search_md_files(root: &Path, query: &str) -> Result<Vec<String>> {
    let mut out = Vec::new();
    let all = list_md_files(root, "")?;
    let query_lower = query.to_lowercase();
    for rel in all {
        let full = root.join(&rel);
        if let Ok(content) = std::fs::read_to_string(&full) {
            if content.to_lowercase().contains(&query_lower) {
                out.push(rel);
            }
        }
    }
    Ok(out)
}

pub struct MemoryBrainTool;

#[async_trait]
impl Tool for MemoryBrainTool {
    fn name(&self) -> String {
        "memory_brain".to_string()
    }

    fn description(&self) -> String {
        "Read and write Chump's persistent brain files in CHUMP_BRAIN_PATH (default chump-brain/). Use to load architectural knowledge, update gotchas, record opinions, and maintain the wiki. Actions: read_file, write_file, append_file, list_files, search_files.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "description": "read_file | write_file | append_file | list_files | search_files" },
                "path": { "type": "string", "description": "Relative path within brain e.g. repos/my-app/gotchas.md" },
                "content": { "type": "string", "description": "Content to write or append" },
                "query": { "type": "string", "description": "Search term (for search_files)" }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let root = brain_root().map_err(|e| anyhow!("CHUMP_BRAIN_PATH: {}", e))?;
        if !root.exists() {
            return Err(anyhow!(
                "Brain root does not exist: {}. Create it and init git.",
                root.display()
            ));
        }
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing action"))?
            .trim()
            .to_lowercase();

        match action.as_str() {
            "read_file" => {
                let path = input
                    .get("path")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("read_file requires path"))?
                    .trim();
                if path.is_empty() {
                    return Err(anyhow!("path is empty"));
                }
                let full = resolve_brain_path(path)?;
                let content = std::fs::read_to_string(&full).map_err(|e| anyhow!("Could not read {}: {}", path, e))?;
                Ok(content)
            }
            "write_file" => {
                let path = input
                    .get("path")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("write_file requires path"))?
                    .trim();
                let content = input
                    .get("content")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("write_file requires content"))?
                    .to_string();
                if path.is_empty() {
                    return Err(anyhow!("path is empty"));
                }
                let full = resolve_brain_path(path)?;
                if let Some(parent) = full.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                std::fs::write(&full, content)?;
                Ok(format!("Wrote {}.", path))
            }
            "append_file" => {
                let path = input
                    .get("path")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("append_file requires path"))?
                    .trim();
                let content = input
                    .get("content")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("append_file requires content"))?
                    .to_string();
                if path.is_empty() {
                    return Err(anyhow!("path is empty"));
                }
                let full = resolve_brain_path(path)?;
                if let Some(parent) = full.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let mut file = std::fs::OpenOptions::new().append(true).create(true).open(&full)?;
                use std::io::Write;
                writeln!(file, "\n{}", content)?;
                Ok(format!("Appended to {}.", path))
            }
            "list_files" => {
                let files = list_md_files(&root, "")?;
                if files.is_empty() {
                    return Ok("No .md files in brain.".to_string());
                }
                Ok(files.join("\n"))
            }
            "search_files" => {
                let query = input
                    .get("query")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .unwrap_or("");
                if query.is_empty() {
                    return Err(anyhow!("search_files requires query"));
                }
                let files = search_md_files(&root, query)?;
                if files.is_empty() {
                    return Ok("No matching files.".to_string());
                }
                Ok(files.join("\n"))
            }
            _ => Err(anyhow!(
                "action must be read_file, write_file, append_file, list_files, or search_files"
            )),
        }
    }
}
