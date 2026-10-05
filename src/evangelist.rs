//! `chump evangelize <target-repo-path>` — INFRA-1783 (INFRA-1746 phase 3).
//!
//! Static, read-only scan of a target repo. Zero LLM calls, zero network
//! calls, zero mutation of the target's tracked files — the one write this
//! phase performs is `<target-repo-path>/docs/HIDDEN_GEMS.md` itself
//! (creating `docs/` if it doesn't exist). Sibling of `src/cartographer.rs`
//! (INFRA-1782, phase 2): same read-only-sweep-of-a-target-repo shape, but
//! this phase surfaces *under-discovered primitives* (scripts, config
//! knobs) instead of mapping topology.

use regex::Regex;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Instant;

const SKIP_DIRS: &[&str] = &[
    ".git",
    "target",
    "node_modules",
    ".chump-ingest",
    ".chump-locks",
    "dist",
    "build",
    "vendor",
    ".venv",
    "venv",
];
const MAX_FILES_SCANNED: usize = 20_000;
const CODE_EXTS: &[&str] = &["rs", "py", "js", "jsx", "mjs", "cjs", "ts", "tsx", "go"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// Bad or missing target path. Not retryable without operator action.
    PathNotFound,
    /// Filesystem error mid-scan or while writing HIDDEN_GEMS.md. Retryable.
    IoError,
}

impl FailureClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            FailureClass::PathNotFound => "path_not_found",
            FailureClass::IoError => "io_error",
        }
    }

    pub fn transient(&self) -> bool {
        matches!(self, FailureClass::IoError)
    }

    pub fn exit_code(&self) -> i32 {
        match self {
            FailureClass::PathNotFound => 2,
            FailureClass::IoError => 1,
        }
    }
}

#[derive(Debug)]
pub struct EvangelistError {
    pub class: FailureClass,
    pub message: String,
}

impl std::fmt::Display for EvangelistError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.class.as_str(), self.message)
    }
}

pub struct EvangelistConfig {
    pub target_repo: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ScriptEntry {
    pub path: String,
    pub description: String,
}

#[derive(Debug, Clone)]
pub struct ConfigKnob {
    pub name: String,
    pub where_to_find: String,
}

#[derive(Debug, Clone)]
pub struct EvangelistReport {
    pub target_repo: PathBuf,
    pub files_scanned: usize,
    pub scripts: Vec<ScriptEntry>,
    pub config_knobs: Vec<ConfigKnob>,
    pub cost_usd_cents: u64,
    pub elapsed_ms: u128,
    pub truncated: bool,
}

/// Validate the target and run the static scan. Never writes to disk —
/// the caller decides whether/when to call `write_hidden_gems_md`.
pub fn run_scan(cfg: &EvangelistConfig) -> Result<EvangelistReport, EvangelistError> {
    if !cfg.target_repo.exists() || !cfg.target_repo.is_dir() {
        return Err(EvangelistError {
            class: FailureClass::PathNotFound,
            message: format!(
                "{} does not exist or is not a directory",
                cfg.target_repo.display()
            ),
        });
    }

    let start = Instant::now();
    let mut files: Vec<PathBuf> = Vec::new();
    let mut truncated = false;
    collect_files(&cfg.target_repo, &mut files, &mut truncated);

    let scripts = detect_scripts(&cfg.target_repo, &files);
    let config_knobs = detect_config_knobs(&cfg.target_repo, &files);

    Ok(EvangelistReport {
        target_repo: cfg.target_repo.clone(),
        files_scanned: files.len(),
        scripts,
        config_knobs,
        cost_usd_cents: 0, // static scan only — zero LLM/API calls
        elapsed_ms: start.elapsed().as_millis(),
        truncated,
    })
}

fn collect_files(root: &Path, out: &mut Vec<PathBuf>, truncated: &mut bool) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            if out.len() >= MAX_FILES_SCANNED {
                *truncated = true;
                return;
            }
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if path.is_dir() {
                if SKIP_DIRS.contains(&name.as_ref()) || name.starts_with('.') {
                    continue;
                }
                stack.push(path);
            } else {
                out.push(path);
            }
        }
    }
}

fn rel(root: &Path, p: &Path) -> String {
    p.strip_prefix(root)
        .unwrap_or(p)
        .to_string_lossy()
        .replace('\\', "/")
}

/// Executable scripts (shebang) with a human-readable one-liner pulled from
/// the first comment line following the shebang, if any.
fn detect_scripts(root: &Path, files: &[PathBuf]) -> Vec<ScriptEntry> {
    let mut out: Vec<ScriptEntry> = Vec::new();
    for f in files {
        let ext = f.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext != "sh" && ext != "bash" && ext != "py" {
            continue;
        }
        let Ok(contents) = std::fs::read_to_string(f) else {
            continue;
        };
        let mut lines = contents.lines();
        let Some(first) = lines.next() else {
            continue;
        };
        if !first.starts_with("#!") {
            continue;
        }
        let description = lines
            .find(|l| !l.trim().is_empty())
            .filter(|l| l.trim_start().starts_with('#'))
            .map(|l| l.trim_start().trim_start_matches('#').trim().to_string())
            .unwrap_or_else(|| "(no description comment found)".to_string());
        out.push(ScriptEntry {
            path: rel(root, f),
            description,
        });
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

fn env_var_regexes() -> &'static Vec<Regex> {
    static RES: OnceLock<Vec<Regex>> = OnceLock::new();
    RES.get_or_init(|| {
        vec![
            // Rust: std::env::var("X") / env::var_os("X")
            Regex::new(r#"env::var(?:_os)?\(\s*"([A-Z0-9_]+)"\s*\)"#).unwrap(),
            // Python: os.environ.get("X") / os.getenv("X") / os.environ["X"]
            Regex::new(r#"os\.(?:getenv|environ(?:\.get)?)\(\s*['"]([A-Z0-9_]+)['"]"#).unwrap(),
            Regex::new(r#"os\.environ\[\s*['"]([A-Z0-9_]+)['"]\s*\]"#).unwrap(),
            // JS/TS: process.env.X / process.env["X"]
            Regex::new(r"process\.env\.([A-Z0-9_]+)").unwrap(),
            Regex::new(r#"process\.env\[\s*['"]([A-Z0-9_]+)['"]\s*\]"#).unwrap(),
            // Go: os.Getenv("X")
            Regex::new(r#"os\.Getenv\(\s*"([A-Z0-9_]+)"\s*\)"#).unwrap(),
        ]
    })
}

/// Environment-variable knobs referenced in source, deduped by name,
/// pointing at the first file each was found in.
fn detect_config_knobs(root: &Path, files: &[PathBuf]) -> Vec<ConfigKnob> {
    use std::collections::BTreeMap;
    let mut found: BTreeMap<String, String> = BTreeMap::new();
    for f in files {
        let ext = f.extension().and_then(|e| e.to_str()).unwrap_or("");
        if !CODE_EXTS.contains(&ext) {
            continue;
        }
        let Ok(contents) = std::fs::read_to_string(f) else {
            continue;
        };
        for re in env_var_regexes() {
            for cap in re.captures_iter(&contents) {
                let name = cap[1].to_string();
                found.entry(name).or_insert_with(|| rel(root, f));
            }
        }
    }
    found
        .into_iter()
        .map(|(name, where_to_find)| ConfigKnob {
            name,
            where_to_find,
        })
        .collect()
}

/// Render HIDDEN_GEMS.md as markdown.
pub fn render_markdown(report: &EvangelistReport) -> String {
    let mut out = String::new();
    out.push_str("# Hidden gems\n\n");
    out.push_str(
        "_Generated by `chump evangelize` (INFRA-1783) — static read-only scan, no LLM calls._\n\n",
    );
    out.push_str(&format!("target: {}\n\n", report.target_repo.display()));
    out.push_str(&format!(
        "files_scanned: {}{}\n",
        report.files_scanned,
        if report.truncated {
            format!(" (truncated at {})", MAX_FILES_SCANNED)
        } else {
            String::new()
        }
    ));
    out.push_str(&format!("elapsed_ms: {}\n", report.elapsed_ms));
    out.push_str(&format!("cost_usd_cents: {}\n\n", report.cost_usd_cents));

    out.push_str(&format!(
        "## Scripts & tools ({})\n\n",
        report.scripts.len()
    ));
    out.push_str("_Detected via shebang line; description is the first comment line after the shebang, when present._\n\n");
    if report.scripts.is_empty() {
        out.push_str("none detected.\n\n");
    } else {
        for s in &report.scripts {
            out.push_str(&format!("- `{}` — {}\n", s.path, s.description));
        }
        out.push('\n');
    }

    out.push_str(&format!(
        "## Config knobs ({})\n\n",
        report.config_knobs.len()
    ));
    out.push_str("_Environment variables referenced in source (Rust/Python/JS-TS/Go)._\n\n");
    if report.config_knobs.is_empty() {
        out.push_str("none detected.\n\n");
    } else {
        for k in &report.config_knobs {
            out.push_str(&format!(
                "- `{}` — first seen in `{}`\n",
                k.name, k.where_to_find
            ));
        }
        out.push('\n');
    }

    out
}

/// Render the report as a JSON value (used by `chump evangelize --json`).
pub fn render_json(report: &EvangelistReport) -> serde_json::Value {
    serde_json::json!({
        "target_repo": report.target_repo.display().to_string(),
        "files_scanned": report.files_scanned,
        "scripts": report.scripts.iter().map(|s| serde_json::json!({
            "path": s.path,
            "description": s.description,
        })).collect::<Vec<_>>(),
        "config_knobs": report.config_knobs.iter().map(|k| serde_json::json!({
            "name": k.name,
            "where_to_find": k.where_to_find,
        })).collect::<Vec<_>>(),
        "cost_usd_cents": report.cost_usd_cents,
        "elapsed_ms": report.elapsed_ms,
        "truncated": report.truncated,
    })
}

/// Write `<target_repo>/docs/HIDDEN_GEMS.md`. The one write this phase
/// performs — always inside the target's own `docs/` directory.
pub fn write_hidden_gems_md(report: &EvangelistReport) -> Result<PathBuf, EvangelistError> {
    let dir = report.target_repo.join("docs");
    std::fs::create_dir_all(&dir).map_err(|e| EvangelistError {
        class: FailureClass::IoError,
        message: format!("create {}: {}", dir.display(), e),
    })?;
    let path = dir.join("HIDDEN_GEMS.md");
    std::fs::write(&path, render_markdown(report)).map_err(|e| EvangelistError {
        class: FailureClass::IoError,
        message: format!("write {}: {}", path.display(), e),
    })?;
    Ok(path)
}

fn emit_ambient(chump_repo_root: &Path, payload: serde_json::Value) {
    let ambient_path = chump_repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    if let Ok(mut out) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(out, "{}", payload);
    }
}

pub fn emit_started(chump_repo_root: &Path, target_repo: &Path) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "evangelist_started",
            "target_repo": target_repo.display().to_string(),
        }),
    );
}

pub fn emit_completed(
    chump_repo_root: &Path,
    report: &EvangelistReport,
    wrote_hidden_gems_md: bool,
) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "evangelist_completed",
            "target_repo": report.target_repo.display().to_string(),
            "files_scanned": report.files_scanned,
            "scripts_found": report.scripts.len(),
            "config_knobs_found": report.config_knobs.len(),
            "elapsed_ms": report.elapsed_ms,
            "cost_usd_cents": report.cost_usd_cents,
            "wrote_hidden_gems_md": wrote_hidden_gems_md,
        }),
    );
}

pub fn emit_failed(chump_repo_root: &Path, target_repo: &Path, err: &EvangelistError) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "evangelist_failed",
            "target_repo": target_repo.display().to_string(),
            "failure_class": err.class.as_str(),
            "note": err.message,
        }),
    );
}

fn print_usage() {
    println!("Usage: chump evangelize <target-repo-path> [--json]");
    println!();
    println!("INFRA-1783 (INFRA-1746 phase 3). Static, read-only scan of");
    println!("<target-repo-path>: shebang scripts with descriptions, and");
    println!("environment-variable config knobs referenced in source");
    println!("(Rust/Python/JS-TS/Go). Writes <target-repo-path>/docs/HIDDEN_GEMS.md.");
    println!("Zero LLM/API calls (cost_usd_cents=0).");
    println!();
    println!("Options:");
    println!("  --json   print the report as JSON instead of markdown");
}

/// `chump evangelize` subcommand entry point. `args` is everything after `evangelize`.
pub fn run(args: &[String]) -> i32 {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        return 0;
    }
    let mut target_repo: Option<String> = None;
    let mut want_json = false;
    for a in args {
        match a.as_str() {
            "--json" => want_json = true,
            a if !a.starts_with('-') && target_repo.is_none() => {
                target_repo = Some(a.to_string());
            }
            _ => {}
        }
    }
    let target_repo = match target_repo {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!("chump evangelize: missing required argument <target-repo-path>");
            print_usage();
            return 2;
        }
    };

    let chump_repo_root = crate::repo_path::repo_root();
    let cfg = EvangelistConfig {
        target_repo: target_repo.clone(),
    };

    emit_started(&chump_repo_root, &target_repo);
    let report = match run_scan(&cfg) {
        Ok(r) => r,
        Err(e) => {
            emit_failed(&chump_repo_root, &target_repo, &e);
            eprintln!("chump evangelize: {e}");
            return e.class.exit_code();
        }
    };
    if let Err(e) = write_hidden_gems_md(&report) {
        emit_failed(&chump_repo_root, &target_repo, &e);
        eprintln!("chump evangelize: {e}");
        return e.class.exit_code();
    }
    emit_completed(&chump_repo_root, &report, true);

    if want_json {
        println!("{}", render_json(&report));
    } else {
        print!("{}", render_markdown(&report));
        println!(
            "HIDDEN_GEMS.md written to {}",
            target_repo.join("docs/HIDDEN_GEMS.md").display()
        );
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_repo(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-evangelist-test-{}-{}",
            name,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn rejects_missing_path() {
        let cfg = EvangelistConfig {
            target_repo: PathBuf::from("/nonexistent/path/does/not/exist/for/evangelist"),
        };
        let err = run_scan(&cfg).unwrap_err();
        assert_eq!(err.class, FailureClass::PathNotFound);
        assert_eq!(err.class.exit_code(), 2);
        assert!(!err.class.transient());
    }

    #[test]
    fn detects_shebang_scripts_with_description() {
        let dir = fixture_repo("scripts");
        std::fs::create_dir_all(dir.join("scripts")).unwrap();
        std::fs::write(
            dir.join("scripts/deploy.sh"),
            "#!/usr/bin/env bash\n# Deploys the app to production.\necho hi\n",
        )
        .unwrap();
        std::fs::write(dir.join("scripts/nodesc.sh"), "#!/bin/sh\necho hi\n").unwrap();
        std::fs::write(dir.join("notascript.txt"), "no shebang here\n").unwrap();

        let cfg = EvangelistConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        assert_eq!(report.scripts.len(), 2);
        let deploy = report
            .scripts
            .iter()
            .find(|s| s.path == "scripts/deploy.sh")
            .unwrap();
        assert_eq!(deploy.description, "Deploys the app to production.");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn detects_config_knobs_across_languages() {
        let dir = fixture_repo("knobs");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(
            dir.join("src/main.rs"),
            "fn main() { let x = std::env::var(\"RUST_KNOB\"); }\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("app.py"),
            "import os\nx = os.getenv(\"PY_KNOB\")\n",
        )
        .unwrap();
        std::fs::write(dir.join("index.js"), "const x = process.env.JS_KNOB;\n").unwrap();
        std::fs::write(
            dir.join("main.go"),
            "package main\nfunc main() { x := os.Getenv(\"GO_KNOB\") }\n",
        )
        .unwrap();

        let cfg = EvangelistConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let names: Vec<&str> = report
            .config_knobs
            .iter()
            .map(|k| k.name.as_str())
            .collect();
        assert!(names.contains(&"RUST_KNOB"));
        assert!(names.contains(&"PY_KNOB"));
        assert!(names.contains(&"JS_KNOB"));
        assert!(names.contains(&"GO_KNOB"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writes_hidden_gems_md_under_docs() {
        let dir = fixture_repo("write");
        std::fs::write(dir.join("run.sh"), "#!/bin/sh\n# runs things\necho hi\n").unwrap();
        let cfg = EvangelistConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let path = write_hidden_gems_md(&report).unwrap();
        assert_eq!(path, dir.join("docs/HIDDEN_GEMS.md"));
        let contents = std::fs::read_to_string(&path).unwrap();
        assert!(contents.contains("# Hidden gems"));
        assert!(contents.contains("## Scripts & tools"));
        assert!(contents.contains("## Config knobs"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_hidden_gems_md_reports_io_error_when_docs_path_blocked() {
        let dir = fixture_repo("blocked");
        std::fs::write(dir.join("docs"), "not a directory\n").unwrap();
        let cfg = EvangelistConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let err = write_hidden_gems_md(&report).unwrap_err();
        assert_eq!(err.class, FailureClass::IoError);
        assert!(err.class.transient());
        assert_eq!(err.class.exit_code(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn renders_json_with_expected_fields() {
        let dir = fixture_repo("json");
        std::fs::write(dir.join("run.sh"), "#!/bin/sh\necho hi\n").unwrap();
        let cfg = EvangelistConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let json = render_json(&report);
        assert_eq!(json["cost_usd_cents"], 0);
        assert_eq!(json["files_scanned"], report.files_scanned);
        assert!(json["scripts"].is_array());
        assert!(json["config_knobs"].is_array());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
