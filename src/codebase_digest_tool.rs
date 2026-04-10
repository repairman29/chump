//! codebase_digest: generate a compressed repo representation (signatures, structure) and write to
//! chump-brain/projects/{name}/digest.md. Cap at ~10k tokens (~40k chars). Used for large-repo context.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use crate::repo_path;

const MAX_CHARS: usize = 40_000;

fn brain_root() -> Result<std::path::PathBuf> {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let base = repo_path::runtime_base();
    let path = if std::path::PathBuf::from(&root).is_absolute() {
        std::path::PathBuf::from(root)
    } else {
        base.join(root)
    };
    Ok(path)
}

fn should_skip_dir(name: &str) -> bool {
    let name = name.to_lowercase();
    name == "target"
        || name == "node_modules"
        || name == ".git"
        || name == "dist"
        || name == "build"
        || name.starts_with('.')
}

fn extract_rust_signatures(content: &str, path: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in content.lines() {
        let t = line.trim();
        if t.starts_with("pub fn ")
            || t.starts_with("pub struct ")
            || t.starts_with("pub enum ")
            || t.starts_with("pub trait ")
            || t.starts_with("pub type ")
            || (t.starts_with("pub ")
                && (t.contains(" fn ") || t.contains(" struct ") || t.contains(" enum ")))
        {
            out.push(format!("  {}: {}", path, t));
        }
    }
    out
}

fn extract_js_ts_signatures(content: &str, path: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in content.lines() {
        let t = line.trim();
        if (t.starts_with("export function ") || t.starts_with("export async function "))
            || (t.starts_with("export const ") && t.contains(" = "))
            || t.starts_with("export class ")
            || t.starts_with("export interface ")
            || t.starts_with("export type ")
        {
            out.push(format!(
                "  {}: {}",
                path,
                t.chars().take(120).collect::<String>()
            ));
        }
    }
    out
}

fn extract_go_signatures(content: &str, path: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in content.lines() {
        let t = line.trim();
        if t.starts_with("func ")
            || (t.starts_with("type ") && (t.contains(" struct ") || t.contains(" interface ")))
        {
            out.push(format!(
                "  {}: {}",
                path,
                t.chars().take(120).collect::<String>()
            ));
        }
    }
    out
}

fn extract_py_signatures(content: &str, path: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in content.lines() {
        let t = line.trim();
        if t.starts_with("def ") || t.starts_with("class ") {
            out.push(format!(
                "  {}: {}",
                path,
                t.chars().take(120).collect::<String>()
            ));
        }
    }
    out
}

fn walk_and_collect(root: &Path, prefix: &str, out: &mut Vec<String>, total: &mut usize) {
    if *total >= MAX_CHARS {
        return;
    }
    let dir = if prefix.is_empty() {
        root.to_path_buf()
    } else {
        root.join(prefix)
    };
    let Ok(entries) = fs::read_dir(&dir) else {
        return;
    };
    let mut files = Vec::new();
    let mut dirs = Vec::new();
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if e.path().is_dir() {
            if !should_skip_dir(&name) {
                dirs.push(name);
            }
        } else {
            files.push(name);
        }
    }
    dirs.sort();
    files.sort();
    for name in dirs {
        let rel = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{}/{}", prefix, name)
        };
        walk_and_collect(root, &rel, out, total);
    }
    for name in files {
        let rel = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{}/{}", prefix, name)
        };
        let path = root.join(&rel);
        let content = match fs::read_to_string(&path) {
            Ok(c) => c,
            _ => continue,
        };
        let sigs = if name.ends_with(".rs") {
            extract_rust_signatures(&content, &rel)
        } else if name.ends_with(".ts")
            || name.ends_with(".tsx")
            || name.ends_with(".js")
            || name.ends_with(".jsx")
        {
            extract_js_ts_signatures(&content, &rel)
        } else if name.ends_with(".go") {
            extract_go_signatures(&content, &rel)
        } else if name.ends_with(".py") {
            extract_py_signatures(&content, &rel)
        } else {
            continue;
        };
        for s in sigs {
            *total += s.len() + 1;
            if *total > MAX_CHARS {
                out.push("[truncated]".to_string());
                return;
            }
            out.push(s);
        }
    }
}

pub fn codebase_digest_enabled() -> bool {
    crate::set_working_repo_tool::set_working_repo_enabled()
}

pub struct CodebaseDigestTool;

#[async_trait]
impl Tool for CodebaseDigestTool {
    fn name(&self) -> String {
        "codebase_digest".to_string()
    }

    fn description(&self) -> String {
        "Generate a compressed codebase digest (pub fn/struct/trait for Rust; export/def/class for JS/TS/Go/Python) and write to chump-brain/projects/{name}/digest.md. Use after set_working_repo for large repos. Optional name overrides project dir name.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "name": { "type": "string", "description": "Project name for brain path (default: repo dir name)" }
            }
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !codebase_digest_enabled() {
            return Err(anyhow!(
                "codebase_digest requires CHUMP_MULTI_REPO_ENABLED=1 and CHUMP_REPO or CHUMP_HOME"
            ));
        }
        let root = repo_path::repo_root();
        let name = input
            .get("name")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                root.file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("unknown")
                    .to_string()
            });

        let mut lines = Vec::new();
        let mut total = 0usize;
        walk_and_collect(&root, "", &mut lines, &mut total);

        let digest = format!("# Codebase digest: {}\n\n{}\n", name, lines.join("\n"));

        let brain = brain_root()?;
        let project_dir = brain.join("projects").join(&name);
        fs::create_dir_all(&project_dir)?;
        let digest_path = project_dir.join("digest.md");
        fs::write(&digest_path, &digest)?;
        Ok(format!(
            "Wrote digest ({} chars) to {}.",
            digest.len(),
            digest_path.display()
        ))
    }
}
