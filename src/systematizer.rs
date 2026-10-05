//! `chump systematize <target-repo-path>` — INFRA-1783 (INFRA-1746 phase 4).
//!
//! Static, read-only scan of a target repo. Zero LLM calls, zero network
//! calls, zero mutation of the target's tracked files — the one write this
//! phase performs is `<target-repo-path>/docs/CAPABILITIES_REGISTRY.json`
//! itself (creating `docs/` if it doesn't exist). Sibling of
//! `src/cartographer.rs` (INFRA-1782, phase 2) and `src/evangelist.rs`
//! (INFRA-1783 phase 3): same read-only-sweep-of-a-target-repo shape, but
//! this phase emits a machine-readable primitive inventory instead of a
//! human-facing doc.

use std::path::{Path, PathBuf};
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// Bad or missing target path. Not retryable without operator action.
    PathNotFound,
    /// Filesystem error mid-scan or while writing CAPABILITIES_REGISTRY.json. Retryable.
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
pub struct SystematizerError {
    pub class: FailureClass,
    pub message: String,
}

impl std::fmt::Display for SystematizerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.class.as_str(), self.message)
    }
}

pub struct SystematizerConfig {
    pub target_repo: PathBuf,
}

/// kind values match INFRA-1729's schema: cli | mcp_tool | skill | crate | script.
/// This static scanner only ever detects `cli` and `script`.
#[derive(Debug, Clone)]
pub struct CapabilityEntry {
    pub primitive_id: String,
    pub kind: &'static str,
    pub file_paths: Vec<String>,
    pub purpose_one_line: String,
    pub example_invocation: String,
}

#[derive(Debug, Clone)]
pub struct SystematizerReport {
    pub target_repo: PathBuf,
    pub files_scanned: usize,
    pub entries: Vec<CapabilityEntry>,
    pub cost_usd_cents: u64,
    pub elapsed_ms: u128,
    pub truncated: bool,
}

/// Validate the target and run the static scan. Never writes to disk —
/// the caller decides whether/when to call `write_capabilities_registry_json`.
pub fn run_scan(cfg: &SystematizerConfig) -> Result<SystematizerReport, SystematizerError> {
    if !cfg.target_repo.exists() || !cfg.target_repo.is_dir() {
        return Err(SystematizerError {
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

    let mut entries = detect_cli_entries(&cfg.target_repo, &files);
    entries.extend(detect_script_entries(&cfg.target_repo, &files));
    entries.sort_by(|a, b| a.primitive_id.cmp(&b.primitive_id));

    Ok(SystematizerReport {
        target_repo: cfg.target_repo.clone(),
        files_scanned: files.len(),
        entries,
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

/// kind=cli primitives: Rust binary crates (`main.rs` under a `[[bin]]`-shaped
/// path or the crate root) and package.json `bin` entries.
fn detect_cli_entries(root: &Path, files: &[PathBuf]) -> Vec<CapabilityEntry> {
    let mut out: Vec<CapabilityEntry> = Vec::new();
    for f in files {
        let file_name = f.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if file_name == "main.rs" {
            let rel_path = rel(root, f);
            let primitive_id = rel_path
                .trim_end_matches("main.rs")
                .trim_end_matches('/')
                .replace(['/', '_'], "-")
                .to_lowercase();
            let primitive_id = if primitive_id.is_empty() {
                "root-binary".to_string()
            } else {
                primitive_id
            };
            out.push(CapabilityEntry {
                primitive_id: format!("cli-{primitive_id}"),
                kind: "cli",
                file_paths: vec![rel_path.clone()],
                purpose_one_line: format!("Rust binary entry point at {rel_path}"),
                example_invocation: format!("cargo run --bin <name> -- --help  # see {rel_path}"),
            });
        } else if file_name == "package.json" {
            let Ok(contents) = std::fs::read_to_string(f) else {
                continue;
            };
            let Ok(json) = serde_json::from_str::<serde_json::Value>(&contents) else {
                continue;
            };
            let rel_path = rel(root, f);
            let pkg_name = json
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            match json.get("bin") {
                Some(serde_json::Value::String(bin)) => {
                    out.push(CapabilityEntry {
                        primitive_id: format!("cli-{}", pkg_name.to_lowercase()),
                        kind: "cli",
                        file_paths: vec![rel_path.clone(), bin.clone()],
                        purpose_one_line: format!("npm bin entry for package {pkg_name}"),
                        example_invocation: format!("npx {pkg_name} --help"),
                    });
                }
                Some(serde_json::Value::Object(map)) => {
                    for (bin_name, target) in map {
                        if let Some(target) = target.as_str() {
                            out.push(CapabilityEntry {
                                primitive_id: format!("cli-{}", bin_name.to_lowercase()),
                                kind: "cli",
                                file_paths: vec![rel_path.clone(), target.to_string()],
                                purpose_one_line: format!(
                                    "npm bin entry {bin_name} for package {pkg_name}"
                                ),
                                example_invocation: format!("npx {bin_name} --help"),
                            });
                        }
                    }
                }
                _ => {}
            }
        }
    }
    out
}

/// kind=script primitives: shebang scripts under `scripts/`.
fn detect_script_entries(root: &Path, files: &[PathBuf]) -> Vec<CapabilityEntry> {
    let mut out: Vec<CapabilityEntry> = Vec::new();
    for f in files {
        let ext = f.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext != "sh" && ext != "bash" && ext != "py" {
            continue;
        }
        let rel_path = rel(root, f);
        if !rel_path.starts_with("scripts/") {
            continue;
        }
        let Ok(contents) = std::fs::read_to_string(f) else {
            continue;
        };
        if !contents.starts_with("#!") {
            continue;
        }
        let file_name = f.file_name().and_then(|s| s.to_str()).unwrap_or("script");
        let primitive_id = file_name
            .trim_end_matches(".sh")
            .trim_end_matches(".bash")
            .trim_end_matches(".py")
            .replace('_', "-")
            .to_lowercase();
        out.push(CapabilityEntry {
            primitive_id: format!("script-{primitive_id}"),
            kind: "script",
            file_paths: vec![rel_path.clone()],
            purpose_one_line: format!("executable script at {rel_path}"),
            example_invocation: format!("./{rel_path}"),
        });
    }
    out
}

/// Render the report as a JSON value matching the docs/CAPABILITIES_REGISTRY.json
/// shape (INFRA-1729): one entry per primitive with primitive_id, kind,
/// file_paths, purpose_one_line, when_to_use, example_invocation, version.
pub fn render_json(report: &SystematizerReport) -> serde_json::Value {
    serde_json::json!({
        "target_repo": report.target_repo.display().to_string(),
        "files_scanned": report.files_scanned,
        "cost_usd_cents": report.cost_usd_cents,
        "elapsed_ms": report.elapsed_ms,
        "truncated": report.truncated,
        "capabilities": report.entries.iter().map(|e| serde_json::json!({
            "primitive_id": e.primitive_id,
            "kind": e.kind,
            "file_paths": e.file_paths,
            "purpose_one_line": e.purpose_one_line,
            "when_to_use": "(operator-curated field — not auto-detected by static scan)",
            "example_invocation": e.example_invocation,
            "version": "unversioned",
        })).collect::<Vec<_>>(),
    })
}

/// Write `<target_repo>/docs/CAPABILITIES_REGISTRY.json`. The one write
/// this phase performs — always inside the target's own `docs/` directory.
pub fn write_capabilities_registry_json(
    report: &SystematizerReport,
) -> Result<PathBuf, SystematizerError> {
    let dir = report.target_repo.join("docs");
    std::fs::create_dir_all(&dir).map_err(|e| SystematizerError {
        class: FailureClass::IoError,
        message: format!("create {}: {}", dir.display(), e),
    })?;
    let path = dir.join("CAPABILITIES_REGISTRY.json");
    let json = render_json(report);
    let rendered = serde_json::to_string_pretty(&json).map_err(|e| SystematizerError {
        class: FailureClass::IoError,
        message: format!("serialize registry: {}", e),
    })?;
    std::fs::write(&path, rendered).map_err(|e| SystematizerError {
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
            "kind": "systematizer_started",
            "target_repo": target_repo.display().to_string(),
        }),
    );
}

pub fn emit_completed(
    chump_repo_root: &Path,
    report: &SystematizerReport,
    wrote_capabilities_registry_json: bool,
) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "systematizer_completed",
            "target_repo": report.target_repo.display().to_string(),
            "files_scanned": report.files_scanned,
            "capabilities_found": report.entries.len(),
            "elapsed_ms": report.elapsed_ms,
            "cost_usd_cents": report.cost_usd_cents,
            "wrote_capabilities_registry_json": wrote_capabilities_registry_json,
        }),
    );
}

pub fn emit_failed(chump_repo_root: &Path, target_repo: &Path, err: &SystematizerError) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "systematizer_failed",
            "target_repo": target_repo.display().to_string(),
            "failure_class": err.class.as_str(),
            "note": err.message,
        }),
    );
}

fn print_usage() {
    println!("Usage: chump systematize <target-repo-path> [--json]");
    println!();
    println!("INFRA-1783 (INFRA-1746 phase 4). Static, read-only scan of");
    println!("<target-repo-path>: kind=cli primitives (Rust bin entry points,");
    println!("npm package.json bin entries) and kind=script primitives");
    println!("(shebang scripts under scripts/). Writes");
    println!("<target-repo-path>/docs/CAPABILITIES_REGISTRY.json.");
    println!("Zero LLM/API calls (cost_usd_cents=0).");
    println!();
    println!("Options:");
    println!("  --json   print the report as JSON (same shape as the written file)");
}

/// `chump systematize` subcommand entry point. `args` is everything after `systematize`.
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
            eprintln!("chump systematize: missing required argument <target-repo-path>");
            print_usage();
            return 2;
        }
    };

    let chump_repo_root = crate::repo_path::repo_root();
    let cfg = SystematizerConfig {
        target_repo: target_repo.clone(),
    };

    emit_started(&chump_repo_root, &target_repo);
    let report = match run_scan(&cfg) {
        Ok(r) => r,
        Err(e) => {
            emit_failed(&chump_repo_root, &target_repo, &e);
            eprintln!("chump systematize: {e}");
            return e.class.exit_code();
        }
    };
    if let Err(e) = write_capabilities_registry_json(&report) {
        emit_failed(&chump_repo_root, &target_repo, &e);
        eprintln!("chump systematize: {e}");
        return e.class.exit_code();
    }
    emit_completed(&chump_repo_root, &report, true);

    let json = render_json(&report);
    if want_json {
        println!("{json}");
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(&json).unwrap_or_default()
        );
        println!(
            "CAPABILITIES_REGISTRY.json written to {}",
            target_repo
                .join("docs/CAPABILITIES_REGISTRY.json")
                .display()
        );
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_repo(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-systematizer-test-{}-{}",
            name,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn rejects_missing_path() {
        let cfg = SystematizerConfig {
            target_repo: PathBuf::from("/nonexistent/path/does/not/exist/for/systematizer"),
        };
        let err = run_scan(&cfg).unwrap_err();
        assert_eq!(err.class, FailureClass::PathNotFound);
        assert_eq!(err.class.exit_code(), 2);
        assert!(!err.class.transient());
    }

    #[test]
    fn detects_rust_bin_and_npm_bin_entries() {
        let dir = fixture_repo("cli");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/main.rs"), "fn main() {}\n").unwrap();
        std::fs::write(
            dir.join("package.json"),
            r#"{"name":"mytool","bin":{"mytool":"./bin/mytool.js"}}"#,
        )
        .unwrap();

        let cfg = SystematizerConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let ids: Vec<&str> = report
            .entries
            .iter()
            .map(|e| e.primitive_id.as_str())
            .collect();
        assert!(ids.iter().any(|id| id.starts_with("cli-")));
        assert!(report
            .entries
            .iter()
            .any(|e| e.primitive_id == "cli-mytool"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn detects_shebang_scripts_under_scripts_dir_only() {
        let dir = fixture_repo("scripts");
        std::fs::create_dir_all(dir.join("scripts")).unwrap();
        std::fs::write(
            dir.join("scripts/deploy.sh"),
            "#!/usr/bin/env bash\necho hi\n",
        )
        .unwrap();
        std::fs::create_dir_all(dir.join("other")).unwrap();
        std::fs::write(dir.join("other/notincluded.sh"), "#!/bin/sh\necho hi\n").unwrap();

        let cfg = SystematizerConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        assert!(report
            .entries
            .iter()
            .any(|e| e.primitive_id == "script-deploy" && e.kind == "script"));
        assert!(!report
            .entries
            .iter()
            .any(|e| e.primitive_id.contains("notincluded")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writes_capabilities_registry_json_under_docs() {
        let dir = fixture_repo("write");
        std::fs::write(dir.join("main.rs"), "fn main() {}\n").unwrap();
        let cfg = SystematizerConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let path = write_capabilities_registry_json(&report).unwrap();
        assert_eq!(path, dir.join("docs/CAPABILITIES_REGISTRY.json"));
        let contents = std::fs::read_to_string(&path).unwrap();
        let json: serde_json::Value = serde_json::from_str(&contents).unwrap();
        assert!(json["capabilities"].is_array());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_capabilities_registry_json_reports_io_error_when_docs_path_blocked() {
        let dir = fixture_repo("blocked");
        std::fs::write(dir.join("docs"), "not a directory\n").unwrap();
        let cfg = SystematizerConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let err = write_capabilities_registry_json(&report).unwrap_err();
        assert_eq!(err.class, FailureClass::IoError);
        assert!(err.class.transient());
        assert_eq!(err.class.exit_code(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn renders_json_with_expected_fields() {
        let dir = fixture_repo("json");
        std::fs::write(dir.join("main.rs"), "fn main() {}\n").unwrap();
        let cfg = SystematizerConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let json = render_json(&report);
        assert_eq!(json["cost_usd_cents"], 0);
        assert_eq!(json["files_scanned"], report.files_scanned);
        assert!(json["capabilities"].is_array());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
