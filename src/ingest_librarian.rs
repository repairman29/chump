//! INFRA-1781: Phase 1 Librarian audit + triage report (INFRA-1746 phase 1b).
//!
//! `chump ingest` (INFRA-1780/1784) walks the code/runtime/effect triangle
//! for a *target* repo the way `src/audit.rs` (INFRA-1370) does for chump's
//! own EVENT_REGISTRY — except the Librarian phase runs entirely static,
//! read-only heuristics against the target's file tree: it never mutates
//! the target and makes zero network/LLM calls (cost_usd_cents is always 0).
//!
//! Two findings classes:
//!   - dead-code candidates: source files whose stem is never referenced
//!     anywhere else in the tree (naive substring heuristic — false
//!     positives are expected and the report says so).
//!   - redundant scripts: files under `scripts/` (or repo root) with
//!     byte-identical content after trimming trailing whitespace per line.
//!
//! Output: `<target>/.chump-ingest/triage.md`, plus
//! `ingest_librarian_started|completed|failed` ambient events on chump's
//! own stream (the librarian runs *inside* chump, auditing someone else's
//! repo — it is not the target repo's tooling).

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

const SOURCE_EXTS: &[&str] = &["rs", "py", "js", "ts", "go", "sh"];
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
    PathNotFound,
    NotAGitRepo,
    InvalidBudget,
    IoError,
}

impl FailureClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            FailureClass::PathNotFound => "path_not_found",
            FailureClass::NotAGitRepo => "not_a_git_repo",
            FailureClass::InvalidBudget => "invalid_budget",
            FailureClass::IoError => "io_error",
        }
    }

    /// Transient failures are worth a retry (e.g. a momentary IO hiccup);
    /// permanent ones (bad path, not a repo, bad flag) never will be.
    pub fn transient(&self) -> bool {
        matches!(self, FailureClass::IoError)
    }
}

#[derive(Debug)]
pub struct LibrarianError {
    pub class: FailureClass,
    pub message: String,
}

impl std::fmt::Display for LibrarianError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.class.as_str(), self.message)
    }
}

pub struct LibrarianConfig {
    pub target_repo: PathBuf,
    pub budget_usd: f64,
}

#[derive(Debug, Clone)]
pub struct DeadCodeCandidate {
    pub path: String,
    pub stem: String,
}

#[derive(Debug, Clone)]
pub struct RedundantScriptGroup {
    pub paths: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct LibrarianReport {
    pub target_repo: PathBuf,
    pub files_scanned: usize,
    pub dead_code_candidates: Vec<DeadCodeCandidate>,
    pub redundant_scripts: Vec<RedundantScriptGroup>,
    pub cost_usd_cents: u64,
    pub elapsed_ms: u128,
    pub truncated: bool,
}

/// Validate inputs and run the sweep. Read-only: never writes inside
/// `target_repo` (the caller decides whether/where to persist the report).
pub fn run_sweep(cfg: &LibrarianConfig) -> Result<LibrarianReport, LibrarianError> {
    if !cfg.budget_usd.is_finite() || cfg.budget_usd <= 0.0 {
        return Err(LibrarianError {
            class: FailureClass::InvalidBudget,
            message: format!(
                "budget_usd must be a positive number, got {}",
                cfg.budget_usd
            ),
        });
    }
    if !cfg.target_repo.exists() {
        return Err(LibrarianError {
            class: FailureClass::PathNotFound,
            message: format!("{} does not exist", cfg.target_repo.display()),
        });
    }
    if !cfg.target_repo.join(".git").exists() {
        return Err(LibrarianError {
            class: FailureClass::NotAGitRepo,
            message: format!("{} has no .git directory", cfg.target_repo.display()),
        });
    }

    let start = Instant::now();
    let mut files: Vec<PathBuf> = Vec::new();
    let mut truncated = false;
    collect_files(&cfg.target_repo, &mut files, &mut truncated);

    let dead_code_candidates = find_dead_code_candidates(&cfg.target_repo, &files);
    let redundant_scripts = find_redundant_scripts(&cfg.target_repo, &files);

    Ok(LibrarianReport {
        target_repo: cfg.target_repo.clone(),
        files_scanned: files.len(),
        dead_code_candidates,
        redundant_scripts,
        cost_usd_cents: 0, // static heuristics only — zero LLM/API calls
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

fn find_dead_code_candidates(root: &Path, files: &[PathBuf]) -> Vec<DeadCodeCandidate> {
    let source_files: Vec<&PathBuf> = files
        .iter()
        .filter(|p| {
            p.extension()
                .and_then(|e| e.to_str())
                .map(|e| SOURCE_EXTS.contains(&e))
                .unwrap_or(false)
        })
        .collect();

    // Concatenate every file's contents once so each stem is checked against
    // the whole tree without re-reading per candidate.
    let mut haystacks: Vec<(PathBuf, String)> = Vec::with_capacity(files.len());
    for f in files {
        if let Ok(contents) = std::fs::read_to_string(f) {
            haystacks.push((f.clone(), contents));
        }
    }

    let mut candidates = Vec::new();
    for f in &source_files {
        let stem = match f.file_stem().and_then(|s| s.to_str()) {
            Some(s) if s.len() >= 3 => s.to_string(),
            _ => continue, // too short to search meaningfully (e.g. "lib", "mod" false-positive-prone) — skip
        };
        let referenced = haystacks
            .iter()
            .any(|(path, contents)| path != *f && contents.contains(stem.as_str()));
        if !referenced {
            candidates.push(DeadCodeCandidate {
                path: rel(root, f),
                stem,
            });
        }
    }
    candidates.sort_by(|a, b| a.path.cmp(&b.path));
    candidates
}

fn find_redundant_scripts(root: &Path, files: &[PathBuf]) -> Vec<RedundantScriptGroup> {
    let mut by_hash: HashMap<String, Vec<String>> = HashMap::new();
    for f in files {
        let is_script = f.components().any(|c| c.as_os_str() == "scripts")
            || f.extension().and_then(|e| e.to_str()) == Some("sh");
        if !is_script {
            continue;
        }
        let contents = match std::fs::read_to_string(f) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let normalized: String = contents
            .lines()
            .map(str::trim_end)
            .collect::<Vec<_>>()
            .join("\n");
        if normalized.trim().is_empty() {
            continue;
        }
        let mut hasher = Sha256::new();
        hasher.update(normalized.as_bytes());
        let digest = hasher.finalize();
        let hash = digest
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect::<String>();
        by_hash.entry(hash).or_default().push(rel(root, f));
    }
    let mut groups: Vec<RedundantScriptGroup> = by_hash
        .into_values()
        .filter(|paths| paths.len() > 1)
        .map(|mut paths| {
            paths.sort();
            RedundantScriptGroup { paths }
        })
        .collect();
    groups.sort_by(|a, b| a.paths.first().cmp(&b.paths.first()));
    groups
}

fn rel(root: &Path, p: &Path) -> String {
    p.strip_prefix(root)
        .unwrap_or(p)
        .to_string_lossy()
        .replace('\\', "/")
}

/// Render the triage report as markdown.
pub fn render_markdown(report: &LibrarianReport) -> String {
    let mut out = String::new();
    out.push_str("# Librarian triage report\n\n");
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
        "## Dead-code candidates ({})\n\n",
        report.dead_code_candidates.len()
    ));
    out.push_str("_Heuristic: source file stem never appears in any other file in the tree. Naive substring match — verify before deleting._\n\n");
    if report.dead_code_candidates.is_empty() {
        out.push_str("none found.\n\n");
    } else {
        for c in &report.dead_code_candidates {
            out.push_str(&format!("- `{}`\n", c.path));
        }
        out.push('\n');
    }

    out.push_str(&format!(
        "## Redundant scripts ({} groups)\n\n",
        report.redundant_scripts.len()
    ));
    out.push_str("_Heuristic: byte-identical content (trailing-whitespace-trimmed) across two or more files under `scripts/` or with a `.sh` extension._\n\n");
    if report.redundant_scripts.is_empty() {
        out.push_str("none found.\n\n");
    } else {
        for g in &report.redundant_scripts {
            out.push_str(&format!("- {}\n", g.paths.join(" == ")));
        }
        out.push('\n');
    }

    out
}

/// Write the triage report to `<target>/.chump-ingest/triage.md`. This is
/// the one write the Librarian phase performs — always inside the target's
/// own `.chump-ingest/` scratch directory, never touching tracked files.
pub fn write_triage_report(report: &LibrarianReport) -> Result<PathBuf, LibrarianError> {
    let dir = report.target_repo.join(".chump-ingest");
    std::fs::create_dir_all(&dir).map_err(|e| LibrarianError {
        class: FailureClass::IoError,
        message: format!("create {}: {}", dir.display(), e),
    })?;
    let path = dir.join("triage.md");
    std::fs::write(&path, render_markdown(report)).map_err(|e| LibrarianError {
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
            "kind": "ingest_librarian_started",
            "target_repo_path": target_repo.display().to_string(),
        }),
    );
}

pub fn emit_completed(chump_repo_root: &Path, report: &LibrarianReport) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "ingest_librarian_completed",
            "target_repo_path": report.target_repo.display().to_string(),
            "files_scanned": report.files_scanned,
            "dead_code_candidate_count": report.dead_code_candidates.len(),
            "redundant_script_group_count": report.redundant_scripts.len(),
            "cost_usd_cents": report.cost_usd_cents,
            "elapsed_ms": report.elapsed_ms,
        }),
    );
}

pub fn emit_failed(chump_repo_root: &Path, target_repo: &Path, err: &LibrarianError) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        serde_json::json!({
            "ts": ts,
            "kind": "ingest_librarian_failed",
            "target_repo_path": target_repo.display().to_string(),
            "failure_class": err.class.as_str(),
            "transient": err.class.transient(),
            "message": err.message,
        }),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_repo(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-librarian-test-{}-{}",
            name,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        dir
    }

    #[test]
    fn rejects_missing_path() {
        let cfg = LibrarianConfig {
            target_repo: PathBuf::from("/nonexistent/path/does/not/exist"),
            budget_usd: 10.0,
        };
        let err = run_sweep(&cfg).unwrap_err();
        assert_eq!(err.class, FailureClass::PathNotFound);
        assert!(!err.class.transient());
    }

    #[test]
    fn rejects_non_git_dir() {
        let dir =
            std::env::temp_dir().join(format!("chump-librarian-nogit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let cfg = LibrarianConfig {
            target_repo: dir.clone(),
            budget_usd: 10.0,
        };
        let err = run_sweep(&cfg).unwrap_err();
        assert_eq!(err.class, FailureClass::NotAGitRepo);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_invalid_budget() {
        let dir = fixture_repo("badbudget");
        let cfg = LibrarianConfig {
            target_repo: dir.clone(),
            budget_usd: -1.0,
        };
        let err = run_sweep(&cfg).unwrap_err();
        assert_eq!(err.class, FailureClass::InvalidBudget);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn finds_dead_code_candidate() {
        let dir = fixture_repo("deadcode");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(
            dir.join("src/main.rs"),
            "mod widget_helper;\nfn main() { widget_helper::run(); }\n",
        )
        .unwrap();
        std::fs::write(dir.join("src/widget_helper.rs"), "pub fn run() {}\n").unwrap();
        std::fs::write(
            dir.join("src/unreferenced_widget.rs"),
            "pub fn nothing_calls_this() {}\n",
        )
        .unwrap();
        let cfg = LibrarianConfig {
            target_repo: dir.clone(),
            budget_usd: 10.0,
        };
        let report = run_sweep(&cfg).unwrap();
        assert!(report
            .dead_code_candidates
            .iter()
            .any(|c| c.path == "src/unreferenced_widget.rs"));
        assert!(!report
            .dead_code_candidates
            .iter()
            .any(|c| c.path == "src/widget_helper.rs"));
        assert_eq!(report.cost_usd_cents, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn finds_redundant_scripts() {
        let dir = fixture_repo("redundant");
        std::fs::create_dir_all(dir.join("scripts")).unwrap();
        std::fs::create_dir_all(dir.join("scripts/legacy")).unwrap();
        let body = "#!/bin/bash\necho hello\n";
        std::fs::write(dir.join("scripts/greet.sh"), body).unwrap();
        std::fs::write(dir.join("scripts/legacy/greet_old.sh"), body).unwrap();
        let cfg = LibrarianConfig {
            target_repo: dir.clone(),
            budget_usd: 10.0,
        };
        let report = run_sweep(&cfg).unwrap();
        assert_eq!(report.redundant_scripts.len(), 1);
        assert_eq!(report.redundant_scripts[0].paths.len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writes_triage_report_under_chump_ingest() {
        let dir = fixture_repo("write");
        let cfg = LibrarianConfig {
            target_repo: dir.clone(),
            budget_usd: 10.0,
        };
        let report = run_sweep(&cfg).unwrap();
        let path = write_triage_report(&report).unwrap();
        assert_eq!(path, dir.join(".chump-ingest/triage.md"));
        let contents = std::fs::read_to_string(&path).unwrap();
        assert!(contents.contains("Librarian triage report"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn no_mutation_outside_chump_ingest_dir_on_sweep_alone() {
        // run_sweep is read-only; only write_triage_report touches disk.
        let dir = fixture_repo("readonly");
        std::fs::write(dir.join("README.md"), "hello\n").unwrap();
        let before = std::fs::read_to_string(dir.join("README.md")).unwrap();
        let cfg = LibrarianConfig {
            target_repo: dir.clone(),
            budget_usd: 10.0,
        };
        let _ = run_sweep(&cfg).unwrap();
        let after = std::fs::read_to_string(dir.join("README.md")).unwrap();
        assert_eq!(before, after);
        assert!(!dir.join(".chump-ingest").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
