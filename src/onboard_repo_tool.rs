//! onboard_repo: run 9-step onboarding for a repo (list_dir, README, build system, tests, CI,
//! CONTRIBUTING) and write chump-brain/projects/{name}/brief.md + architecture.md.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::process::Command;

use crate::repo_path;

fn brain_root() -> Result<PathBuf> {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let base = repo_path::runtime_base();
    let path = if PathBuf::from(&root).is_absolute() {
        PathBuf::from(root)
    } else {
        base.join(root)
    };
    Ok(path)
}

/// Resolve repo path: if absolute use as-is; else relative to CHUMP_HOME/repos.
fn resolve_repo_path(path_str: &str) -> Result<PathBuf> {
    let path = PathBuf::from(path_str.trim());
    if path.is_absolute() {
        let canonical = path.canonicalize().map_err(|e| anyhow!("{}", e))?;
        if !canonical.join(".git").exists() {
            return Err(anyhow!("path is not a git repo (no .git)"));
        }
        return Ok(canonical);
    }
    let base = repo_path::runtime_base().join("repos");
    let joined = base.join(path_str.trim_start_matches('/'));
    let canonical = joined.canonicalize().map_err(|e| anyhow!("{}", e))?;
    if !canonical.join(".git").exists() {
        return Err(anyhow!("path is not a git repo (no .git)"));
    }
    Ok(canonical)
}

fn list_dir(root: &std::path::Path, rel: &str) -> Result<String> {
    let path = if rel.is_empty() || rel == "." {
        root.to_path_buf()
    } else {
        root.join(rel)
    };
    if !path.is_dir() {
        return Ok(format!("(not a dir: {})", path.display()));
    }
    let mut entries: Vec<String> = fs::read_dir(&path)?
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

fn read_file_optional(root: &std::path::Path, rel: &str) -> Option<String> {
    let path = root.join(rel);
    fs::read_to_string(&path).ok()
}

fn detect_build_system(root: &std::path::Path) -> (String, String) {
    let configs = [
        ("Cargo.toml", "Rust (Cargo)"),
        ("package.json", "Node/npm"),
        ("go.mod", "Go"),
        ("setup.py", "Python setuptools"),
        ("pyproject.toml", "Python (pyproject)"),
        ("Makefile", "Make"),
        ("CMakeLists.txt", "CMake"),
    ];
    for (file, label) in configs {
        if root.join(file).exists() {
            let content = read_file_optional(root, file).unwrap_or_default();
            let preview = if content.len() > 2000 {
                format!("{}… [truncated {} chars]", &content[..2000], content.len())
            } else {
                content
            };
            return (label.to_string(), preview);
        }
    }
    (
        "unknown".to_string(),
        "No standard build config found.".to_string(),
    )
}

fn run_tests(root: &std::path::Path, build_system: &str) -> String {
    let (cmd, args): (&str, &[&str]) = if build_system.contains("Cargo") {
        ("cargo", &["test", "--", "--nocapture"][..])
    } else if build_system.contains("Node") || build_system.contains("npm") {
        ("npm", &["test"])
    } else if build_system.contains("Go") {
        ("go", &["test", "./..."])
    } else if build_system.contains("Python") {
        ("python", &["-m", "pytest", "-v"])
    } else if build_system.contains("Make") {
        ("make", &["test"])
    } else {
        return "No test command for this build system.".to_string();
    };
    let out = Command::new(cmd).args(args).current_dir(root).output();
    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            let stderr = String::from_utf8_lossy(&o.stderr);
            let status = if o.status.success() { "ok" } else { "failed" };
            format!(
                "{} {} (exit {}):\nstdout:\n{}\nstderr:\n{}",
                cmd,
                status,
                o.status.code().unwrap_or(-1),
                stdout.trim(),
                stderr.trim()
            )
        }
        Err(e) => format!("{}: {}", cmd, e),
    }
}

fn scan_ci(root: &std::path::Path) -> String {
    let mut out = Vec::new();
    let gh = root.join(".github").join("workflows");
    if gh.is_dir() {
        if let Ok(entries) = fs::read_dir(&gh) {
            for e in entries.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                out.push(format!(".github/workflows/{}", name));
            }
        }
    }
    let gitlab = root.join(".gitlab-ci.yml");
    if gitlab.exists() {
        out.push(".gitlab-ci.yml".to_string());
    }
    if out.is_empty() {
        return "No CI config found.".to_string();
    }
    out.join("\n")
}

fn project_name_from_path(root: &std::path::Path) -> String {
    root.file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string()
}

pub fn onboard_repo_enabled() -> bool {
    crate::set_working_repo_tool::set_working_repo_enabled()
}

pub struct OnboardRepoTool;

#[async_trait]
impl Tool for OnboardRepoTool {
    fn name(&self) -> String {
        "onboard_repo".to_string()
    }

    fn description(&self) -> String {
        "Onboard a repo in one shot: list root, read README, detect build system, read build config, run tests, scan CI, scan CONTRIBUTING, then write chump-brain/projects/{name}/brief.md and architecture.md. Path: repo root (absolute or relative to CHUMP_HOME/repos). Optional name overrides project name (default from dir name).".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Repo root path (absolute or under CHUMP_HOME/repos)" },
                "name": { "type": "string", "description": "Project name for brain dir (default: dir name of path)" }
            },
            "required": ["path"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !onboard_repo_enabled() {
            return Err(anyhow!(
                "onboard_repo requires CHUMP_MULTI_REPO_ENABLED=1 and CHUMP_REPO or CHUMP_HOME"
            ));
        }
        let path_str = input
            .get("path")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing path"))?
            .trim();
        let root = resolve_repo_path(path_str)?;
        let name = input
            .get("name")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| project_name_from_path(&root));

        // 1. list_dir at root
        let top_level = list_dir(&root, ".")?;
        let entry_count = top_level.lines().count();
        if entry_count > 50 {
            std::env::set_var("CHUMP_PREFER_LARGE_CONTEXT", "1");
        }
        // 2. README
        let readme = read_file_optional(&root, "README.md")
            .or_else(|| read_file_optional(&root, "README"))
            .unwrap_or_else(|| "(no README found)".to_string());
        let readme_preview = if readme.len() > 4000 {
            format!("{}… [truncated {} chars]", &readme[..4000], readme.len())
        } else {
            readme
        };
        // 3–4. build system + config
        let (build_label, build_config) = detect_build_system(&root);
        // 5. run tests
        let test_out = run_tests(&root, &build_label);
        // 6. scan CI
        let ci = scan_ci(&root);
        // 7. CONTRIBUTING
        let contributing = read_file_optional(&root, "CONTRIBUTING.md")
            .or_else(|| read_file_optional(&root, "CONTRIBUTING"))
            .unwrap_or_else(|| "(no CONTRIBUTING found)".to_string());
        let contributing_preview = if contributing.len() > 3000 {
            format!("{}… [truncated]", &contributing[..3000])
        } else {
            contributing
        };

        let brief = format!(
            "# Project: {}\n\n## Root contents\n{}\n\n## README\n{}\n\n## Build system\n{}\n\n## Build config (preview)\n```\n{}\n```\n\n## Tests (last run)\n{}\n\n## CI\n{}\n\n## CONTRIBUTING (preview)\n{}\n",
            name,
            top_level,
            readme_preview,
            build_label,
            build_config.lines().take(80).collect::<Vec<_>>().join("\n"),
            test_out.lines().take(50).collect::<Vec<_>>().join("\n"),
            ci,
            contributing_preview.lines().take(40).collect::<Vec<_>>().join("\n")
        );

        let architecture = format!(
            "# Architecture: {}\n\nBased on onboard scan.\n\n- Build: {}\n- CI: {}\n- Key dirs: (see brief)\n",
            name,
            build_label,
            ci
        );

        let brain = brain_root()?;
        let project_dir = brain.join("projects").join(&name);
        fs::create_dir_all(&project_dir)?;
        let brief_path = project_dir.join("brief.md");
        let arch_path = project_dir.join("architecture.md");
        fs::write(&brief_path, &brief)?;
        fs::write(&arch_path, &architecture)?;

        Ok(format!(
            "Onboarded {}. Wrote {} and {}.",
            name,
            brief_path.display(),
            arch_path.display()
        ))
    }
}
