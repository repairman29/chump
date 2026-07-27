//! `chump cartograph <target-repo-path>` — INFRA-1782 (INFRA-1746 phase 2).
//!
//! Static, read-only scan of a target repo. Zero LLM calls, zero network
//! calls, zero mutation of the target's tracked files — the one write this
//! phase performs is `<target-repo-path>/docs/ARCHITECTURE.md` itself
//! (creating `docs/` if it doesn't exist). Sibling of `src/ingest_librarian.rs`
//! (INFRA-1781, phase 1b): same read-only-sweep-of-a-target-repo shape, but
//! this phase maps *structure* (languages, modules, entry points, hot paths)
//! instead of triaging dead code.

use std::collections::BTreeMap;
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
const HOT_PATH_TOP_N: usize = 15;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// Bad or missing target path. Not retryable without operator action.
    PathNotFound,
    /// Filesystem error mid-scan or while writing ARCHITECTURE.md. Retryable.
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
pub struct CartographError {
    pub class: FailureClass,
    pub message: String,
}

impl std::fmt::Display for CartographError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.class.as_str(), self.message)
    }
}

pub struct CartographConfig {
    pub target_repo: PathBuf,
}

#[derive(Debug, Clone)]
pub struct EntryPoint {
    pub path: String,
    pub language: &'static str,
    pub note: String,
}

#[derive(Debug, Clone)]
pub struct HotPathEntry {
    pub path: String,
    pub lines: usize,
}

#[derive(Debug, Clone)]
pub struct CartographReport {
    pub target_repo: PathBuf,
    pub files_scanned: usize,
    /// (language, file count), sorted by count desc then name.
    pub language_mix: Vec<(String, usize)>,
    /// Top-level entries of the target repo; directories suffixed with `/`.
    pub module_map: Vec<String>,
    pub entry_points: Vec<EntryPoint>,
    /// Largest source files by line count, descending.
    pub hot_paths: Vec<HotPathEntry>,
    pub cost_usd_cents: u64,
    pub elapsed_ms: u128,
    pub truncated: bool,
}

/// Validate the target and run the static scan. Never writes to disk —
/// the caller decides whether/when to call `write_architecture_md`.
pub fn run_scan(cfg: &CartographConfig) -> Result<CartographReport, CartographError> {
    if !cfg.target_repo.exists() || !cfg.target_repo.is_dir() {
        return Err(CartographError {
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

    let language_mix = compute_language_mix(&files);
    let module_map = compute_module_map(&cfg.target_repo)?;
    let entry_points = detect_entry_points(&cfg.target_repo, &files);
    let hot_paths = compute_hot_paths(&cfg.target_repo, &files);

    Ok(CartographReport {
        target_repo: cfg.target_repo.clone(),
        files_scanned: files.len(),
        language_mix,
        module_map,
        entry_points,
        hot_paths,
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

fn language_for_ext(ext: &str) -> Option<&'static str> {
    match ext {
        "rs" => Some("Rust"),
        "py" => Some("Python"),
        "js" | "jsx" | "mjs" | "cjs" => Some("JavaScript"),
        "ts" | "tsx" => Some("TypeScript"),
        "go" => Some("Go"),
        "sh" | "bash" => Some("Bash"),
        _ => None,
    }
}

fn compute_language_mix(files: &[PathBuf]) -> Vec<(String, usize)> {
    let mut counts: BTreeMap<&'static str, usize> = BTreeMap::new();
    for f in files {
        if let Some(lang) = f
            .extension()
            .and_then(|e| e.to_str())
            .and_then(language_for_ext)
        {
            *counts.entry(lang).or_insert(0) += 1;
        }
    }
    let mut mix: Vec<(String, usize)> = counts
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
    mix.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    mix
}

fn compute_module_map(root: &Path) -> Result<Vec<String>, CartographError> {
    let read = std::fs::read_dir(root).map_err(|e| CartographError {
        class: FailureClass::IoError,
        message: format!("read_dir {}: {}", root.display(), e),
    })?;
    let mut entries: Vec<String> = Vec::new();
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        if path.is_dir() {
            if SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            entries.push(format!("{}/", name));
        } else {
            entries.push(name);
        }
    }
    entries.sort();
    Ok(entries)
}

fn detect_entry_points(root: &Path, files: &[PathBuf]) -> Vec<EntryPoint> {
    let mut points: Vec<EntryPoint> = Vec::new();
    for f in files {
        let file_name = f.file_name().and_then(|s| s.to_str()).unwrap_or("");
        let ext = f.extension().and_then(|e| e.to_str()).unwrap_or("");
        let rel_path = rel(root, f);
        match ext {
            "rs" if file_name == "main.rs" => {
                points.push(EntryPoint {
                    path: rel_path,
                    language: "Rust",
                    note: "binary entry point (main.rs)".to_string(),
                });
            }
            "py" => {
                if file_name == "__main__.py" {
                    points.push(EntryPoint {
                        path: rel_path,
                        language: "Python",
                        note: "package entry point (__main__.py)".to_string(),
                    });
                } else if let Ok(contents) = std::fs::read_to_string(f) {
                    if contents.contains("if __name__ == \"__main__\"")
                        || contents.contains("if __name__ == '__main__'")
                    {
                        points.push(EntryPoint {
                            path: rel_path,
                            language: "Python",
                            note: "script entry point (__main__ guard)".to_string(),
                        });
                    }
                }
            }
            "go" => {
                if let Ok(contents) = std::fs::read_to_string(f) {
                    if contents.contains("package main") && contents.contains("func main(") {
                        points.push(EntryPoint {
                            path: rel_path,
                            language: "Go",
                            note: "package main entry point".to_string(),
                        });
                    }
                }
            }
            "sh" | "bash" => {
                if let Ok(contents) = std::fs::read_to_string(f) {
                    if contents.starts_with("#!") {
                        points.push(EntryPoint {
                            path: rel_path,
                            language: "Bash",
                            note: "executable script (shebang)".to_string(),
                        });
                    }
                }
            }
            _ if file_name == "package.json" => {
                if let Ok(contents) = std::fs::read_to_string(f) {
                    if let Ok(json) = serde_json::from_str::<serde_json::Value>(&contents) {
                        if let Some(main) = json.get("main").and_then(|v| v.as_str()) {
                            points.push(EntryPoint {
                                path: rel_path.clone(),
                                language: "JavaScript/TypeScript",
                                note: format!("package.json main: {main}"),
                            });
                        }
                        match json.get("bin") {
                            Some(serde_json::Value::String(bin)) => {
                                points.push(EntryPoint {
                                    path: rel_path.clone(),
                                    language: "JavaScript/TypeScript",
                                    note: format!("package.json bin: {bin}"),
                                });
                            }
                            Some(serde_json::Value::Object(map)) => {
                                for (name, target) in map {
                                    if let Some(target) = target.as_str() {
                                        points.push(EntryPoint {
                                            path: rel_path.clone(),
                                            language: "JavaScript/TypeScript",
                                            note: format!("package.json bin.{name}: {target}"),
                                        });
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            _ => {}
        }
    }
    points.sort_by(|a, b| a.path.cmp(&b.path).then_with(|| a.note.cmp(&b.note)));
    points
}

fn compute_hot_paths(root: &Path, files: &[PathBuf]) -> Vec<HotPathEntry> {
    let mut sized: Vec<HotPathEntry> = files
        .iter()
        .filter(|f| {
            f.extension()
                .and_then(|e| e.to_str())
                .map(|e| language_for_ext(e).is_some())
                .unwrap_or(false)
        })
        .filter_map(|f| {
            std::fs::read_to_string(f).ok().map(|c| HotPathEntry {
                path: rel(root, f),
                lines: c.lines().count(),
            })
        })
        .collect();
    sized.sort_by(|a, b| b.lines.cmp(&a.lines).then_with(|| a.path.cmp(&b.path)));
    sized.truncate(HOT_PATH_TOP_N);
    sized
}

fn rel(root: &Path, p: &Path) -> String {
    p.strip_prefix(root)
        .unwrap_or(p)
        .to_string_lossy()
        .replace('\\', "/")
}

/// Render ARCHITECTURE.md as markdown.
pub fn render_markdown(report: &CartographReport) -> String {
    let mut out = String::new();
    out.push_str("# Architecture map\n\n");
    out.push_str(
        "_Generated by `chump cartograph` (INFRA-1782) — static read-only scan, no LLM calls._\n\n",
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

    out.push_str("## Language mix\n\n");
    if report.language_mix.is_empty() {
        out.push_str("no recognized source files found.\n\n");
    } else {
        for (lang, count) in &report.language_mix {
            out.push_str(&format!("- {lang}: {count} file(s)\n"));
        }
        out.push('\n');
    }

    out.push_str("## Top-level module map\n\n");
    if report.module_map.is_empty() {
        out.push_str("(empty)\n\n");
    } else {
        for m in &report.module_map {
            out.push_str(&format!("- `{m}`\n"));
        }
        out.push('\n');
    }

    out.push_str(&format!(
        "## Entry points ({})\n\n",
        report.entry_points.len()
    ));
    out.push_str("_Detected via filename convention + content heuristics for Rust/Python/JS-TS/Go/Bash. False negatives are expected for unconventional layouts._\n\n");
    if report.entry_points.is_empty() {
        out.push_str("none detected.\n\n");
    } else {
        for e in &report.entry_points {
            out.push_str(&format!("- `{}` [{}] — {}\n", e.path, e.language, e.note));
        }
        out.push('\n');
    }

    out.push_str(&format!(
        "## Hot paths — largest source files by line count (top {})\n\n",
        HOT_PATH_TOP_N
    ));
    if report.hot_paths.is_empty() {
        out.push_str("none found.\n\n");
    } else {
        for h in &report.hot_paths {
            out.push_str(&format!("- `{}` — {} lines\n", h.path, h.lines));
        }
        out.push('\n');
    }

    out
}

/// Render the report as a JSON value (used by `chump cartograph --json`).
pub fn render_json(report: &CartographReport) -> serde_json::Value {
    serde_json::json!({
        "target_repo": report.target_repo.display().to_string(),
        "files_scanned": report.files_scanned,
        "language_mix": report.language_mix.iter().map(|(lang, count)| serde_json::json!({"language": lang, "files": count})).collect::<Vec<_>>(),
        "module_map": report.module_map,
        "entry_points": report.entry_points.iter().map(|e| serde_json::json!({
            "path": e.path,
            "language": e.language,
            "note": e.note,
        })).collect::<Vec<_>>(),
        "hot_paths": report.hot_paths.iter().map(|h| serde_json::json!({
            "path": h.path,
            "lines": h.lines,
        })).collect::<Vec<_>>(),
        "cost_usd_cents": report.cost_usd_cents,
        "elapsed_ms": report.elapsed_ms,
        "truncated": report.truncated,
    })
}

/// Write `<target_repo>/docs/ARCHITECTURE.md`. The one write this phase
/// performs — always inside the target's own `docs/` directory.
pub fn write_architecture_md(report: &CartographReport) -> Result<PathBuf, CartographError> {
    let dir = report.target_repo.join("docs");
    std::fs::create_dir_all(&dir).map_err(|e| CartographError {
        class: FailureClass::IoError,
        message: format!("create {}: {}", dir.display(), e),
    })?;
    let path = dir.join("ARCHITECTURE.md");
    std::fs::write(&path, render_markdown(report)).map_err(|e| CartographError {
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
            "kind": "cartographer_started",
            "target_repo": target_repo.display().to_string(),
        }),
    );
}

pub fn emit_completed(
    chump_repo_root: &Path,
    report: &CartographReport,
    wrote_architecture_md: bool,
) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "cartographer_completed",
            "target_repo": report.target_repo.display().to_string(),
            "files_scanned": report.files_scanned,
            "elapsed_ms": report.elapsed_ms,
            "cost_usd_cents": report.cost_usd_cents,
            "wrote_architecture_md": wrote_architecture_md,
        }),
    );
}

pub fn emit_failed(chump_repo_root: &Path, target_repo: &Path, err: &CartographError) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "cartographer_failed",
            "target_repo": target_repo.display().to_string(),
            "failure_class": err.class.as_str(),
            "note": err.message,
        }),
    );
}

fn print_usage() {
    println!("Usage: chump cartograph <target-repo-path> [--json]");
    println!();
    println!("INFRA-1782 (INFRA-1746 phase 2). Static, read-only scan of");
    println!("<target-repo-path>: language mix, top-level module map, detected");
    println!("entry points (Rust/Python/JS-TS/Go/Bash), and hot paths (largest");
    println!("source files by line count). Writes <target-repo-path>/docs/ARCHITECTURE.md.");
    println!("Zero LLM/API calls (cost_usd_cents=0).");
    println!();
    println!("Options:");
    println!("  --json   print the report as JSON instead of markdown");
}

/// `chump cartograph` subcommand entry point. `args` is everything after `cartograph`.
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
            eprintln!("chump cartograph: missing required argument <target-repo-path>");
            print_usage();
            return 2;
        }
    };

    let chump_repo_root = crate::repo_path::repo_root();
    let cfg = CartographConfig {
        target_repo: target_repo.clone(),
    };

    emit_started(&chump_repo_root, &target_repo);
    let report = match run_scan(&cfg) {
        Ok(r) => r,
        Err(e) => {
            emit_failed(&chump_repo_root, &target_repo, &e);
            eprintln!("chump cartograph: {e}");
            return e.class.exit_code();
        }
    };
    if let Err(e) = write_architecture_md(&report) {
        emit_failed(&chump_repo_root, &target_repo, &e);
        eprintln!("chump cartograph: {e}");
        return e.class.exit_code();
    }
    emit_completed(&chump_repo_root, &report, true);

    if want_json {
        println!("{}", render_json(&report));
    } else {
        print!("{}", render_markdown(&report));
        println!(
            "ARCHITECTURE.md written to {}",
            target_repo.join("docs/ARCHITECTURE.md").display()
        );
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_repo(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-cartographer-test-{}-{}",
            name,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn rejects_missing_path() {
        let cfg = CartographConfig {
            target_repo: PathBuf::from("/nonexistent/path/does/not/exist/for/cartographer"),
        };
        let err = run_scan(&cfg).unwrap_err();
        assert_eq!(err.class, FailureClass::PathNotFound);
        assert_eq!(err.class.exit_code(), 2);
        assert!(!err.class.transient());
    }

    #[test]
    fn rejects_path_that_is_a_file() {
        let dir = fixture_repo("notadir");
        let file_path = dir.join("im-a-file");
        std::fs::write(&file_path, "hi").unwrap();
        let cfg = CartographConfig {
            target_repo: file_path,
        };
        let err = run_scan(&cfg).unwrap_err();
        assert_eq!(err.class, FailureClass::PathNotFound);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn detects_rust_python_go_bash_entry_points() {
        let dir = fixture_repo("entrypoints");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/main.rs"), "fn main() {}\n").unwrap();
        std::fs::create_dir_all(dir.join("pkg")).unwrap();
        std::fs::write(
            dir.join("pkg/cli.py"),
            "def run():\n    pass\n\nif __name__ == \"__main__\":\n    run()\n",
        )
        .unwrap();
        std::fs::create_dir_all(dir.join("cmd")).unwrap();
        std::fs::write(
            dir.join("cmd/server.go"),
            "package main\n\nfunc main() {}\n",
        )
        .unwrap();
        std::fs::create_dir_all(dir.join("scripts")).unwrap();
        std::fs::write(dir.join("scripts/run.sh"), "#!/usr/bin/env bash\necho hi\n").unwrap();
        std::fs::write(
            dir.join("package.json"),
            r#"{"name":"x","main":"index.js","bin":{"x":"./bin/x.js"}}"#,
        )
        .unwrap();

        let cfg = CartographConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let langs: Vec<&str> = report.entry_points.iter().map(|e| e.language).collect();
        assert!(langs.contains(&"Rust"));
        assert!(langs.contains(&"Python"));
        assert!(langs.contains(&"Go"));
        assert!(langs.contains(&"Bash"));
        assert!(report
            .entry_points
            .iter()
            .any(|e| e.language == "JavaScript/TypeScript" && e.note.contains("main: index.js")));
        assert!(report
            .entry_points
            .iter()
            .any(|e| e.language == "JavaScript/TypeScript" && e.note.contains("bin.x")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn module_map_lists_top_level_entries_only() {
        let dir = fixture_repo("modulemap");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::create_dir_all(dir.join("docs")).unwrap();
        std::fs::write(dir.join("README.md"), "hi\n").unwrap();
        std::fs::write(dir.join("src/deep.rs"), "// nested, not top-level\n").unwrap();

        let cfg = CartographConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        assert!(report.module_map.contains(&"src/".to_string()));
        assert!(report.module_map.contains(&"docs/".to_string()));
        assert!(report.module_map.contains(&"README.md".to_string()));
        assert!(!report.module_map.iter().any(|m| m.contains("deep.rs")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hot_paths_ranked_by_line_count_descending() {
        let dir = fixture_repo("hotpaths");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/small.rs"), "fn a() {}\n").unwrap();
        let big = "// line\n".repeat(500);
        std::fs::write(dir.join("src/big.rs"), &big).unwrap();

        let cfg = CartographConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        assert_eq!(report.hot_paths.first().unwrap().path, "src/big.rs");
        assert!(report.hot_paths.first().unwrap().lines > 400);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writes_architecture_md_under_docs() {
        let dir = fixture_repo("write");
        std::fs::write(dir.join("main.rs"), "fn main() {}\n").unwrap();
        let cfg = CartographConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let path = write_architecture_md(&report).unwrap();
        assert_eq!(path, dir.join("docs/ARCHITECTURE.md"));
        let contents = std::fs::read_to_string(&path).unwrap();
        assert!(contents.contains("# Architecture map"));
        assert!(contents.contains("## Language mix"));
        assert!(contents.contains("## Entry points"));
        assert!(contents.contains("## Hot paths"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_architecture_md_reports_io_error_when_docs_path_blocked() {
        let dir = fixture_repo("blocked");
        // Create `docs` as a *file* so `create_dir_all` fails — this is the
        // transient/IoError path exercised mid-write (AC4).
        std::fs::write(dir.join("docs"), "not a directory\n").unwrap();
        let cfg = CartographConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let err = write_architecture_md(&report).unwrap_err();
        assert_eq!(err.class, FailureClass::IoError);
        assert!(err.class.transient());
        assert_eq!(err.class.exit_code(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn renders_json_with_expected_fields() {
        let dir = fixture_repo("json");
        std::fs::write(dir.join("main.rs"), "fn main() {}\n").unwrap();
        let cfg = CartographConfig {
            target_repo: dir.clone(),
        };
        let report = run_scan(&cfg).unwrap();
        let json = render_json(&report);
        assert_eq!(json["cost_usd_cents"], 0);
        assert_eq!(json["files_scanned"], report.files_scanned);
        assert!(json["language_mix"].is_array());
        assert!(json["entry_points"].is_array());
        assert!(json["hot_paths"].is_array());
        assert!(json["module_map"].is_array());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
