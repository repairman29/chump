//! INFRA-1782: Phase 2 Cartographer — `chump cartograph <path>` generates
//! `<target>/docs/ARCHITECTURE.md` for an arbitrary target repo: topology
//! (top-level module map), language mix, detected entry points, and hot
//! paths (largest source files by line count).
//!
//! This is a static, read-only, zero-cost scan — no LLM calls — so it can
//! ship ahead of the full `chump ingest` orchestration (INFRA-1780/1784)
//! and be wired in as a phase once that CLI lands.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// Directories skipped during the scan — build output, VCS metadata, and
/// dependency trees that would otherwise drown the module map.
const SKIP_DIRS: &[&str] = &[
    ".git",
    ".chump-locks",
    ".chump",
    "target",
    "node_modules",
    "dist",
    "build",
    ".venv",
    "venv",
    "__pycache__",
    ".next",
    "vendor",
];

/// Filename patterns recognised as language entry points (day-1 language
/// coverage per INFRA-1746 notes: Rust, Python, JS/TS, Go, Bash).
const ENTRY_POINT_NAMES: &[&str] = &[
    "main.rs",
    "main.py",
    "__main__.py",
    "index.js",
    "index.ts",
    "main.go",
    "main.sh",
    "cli.py",
    "app.py",
    "server.js",
    "server.ts",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// Retryable — e.g. a transient filesystem error mid-scan.
    Transient,
    /// Not retryable without operator action — e.g. path doesn't exist or
    /// isn't a directory.
    Permanent,
}

impl FailureClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            FailureClass::Transient => "transient",
            FailureClass::Permanent => "permanent",
        }
    }
}

#[derive(Debug)]
pub struct CartographerError {
    pub class: FailureClass,
    pub message: String,
}

impl std::fmt::Display for CartographerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.class.as_str(), self.message)
    }
}

/// One top-level module (directory) in the target repo.
#[derive(Debug, Clone)]
pub struct ModuleEntry {
    pub name: String,
    pub file_count: usize,
}

/// A candidate hot path — a large source file, ranked by line count.
#[derive(Debug, Clone)]
pub struct HotPath {
    pub rel_path: String,
    pub lines: usize,
}

#[derive(Debug, Clone)]
pub struct CartographerReport {
    pub target_repo: PathBuf,
    pub modules: Vec<ModuleEntry>,
    pub languages: Vec<(String, usize)>, // (extension, file_count), sorted desc
    pub entry_points: Vec<String>,       // rel paths
    pub hot_paths: Vec<HotPath>,         // top N by line count, desc
    pub files_scanned: usize,
    pub elapsed_ms: u128,
    /// Static scan — no LLM tokens spent. Kept as a field (rather than
    /// omitted) so callers/observability treat cost tracking uniformly
    /// across all ingest phases even when a phase happens to cost $0.
    pub cost_usd_cents: u64,
}

/// Walk `target_repo` and build a [`CartographerReport`]. Read-only —
/// never writes inside `target_repo` during the scan.
pub fn scan(target_repo: &Path) -> Result<CartographerReport, CartographerError> {
    let started = Instant::now();
    if !target_repo.exists() {
        return Err(CartographerError {
            class: FailureClass::Permanent,
            message: format!("target repo path does not exist: {}", target_repo.display()),
        });
    }
    if !target_repo.is_dir() {
        return Err(CartographerError {
            class: FailureClass::Permanent,
            message: format!(
                "target repo path is not a directory: {}",
                target_repo.display()
            ),
        });
    }

    let mut modules: Vec<ModuleEntry> = Vec::new();
    let mut lang_counts: HashMap<String, usize> = HashMap::new();
    let mut entry_points: Vec<String> = Vec::new();
    let mut hot_paths: Vec<HotPath> = Vec::new();
    let mut files_scanned = 0usize;

    // Top-level module map: one entry per top-level directory, with a
    // recursive file count.
    let top_entries = std::fs::read_dir(target_repo).map_err(|e| CartographerError {
        class: FailureClass::Transient,
        message: format!("read_dir {}: {}", target_repo.display(), e),
    })?;
    for entry in top_entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.')
            && name != "."
            && (!path.is_dir() || SKIP_DIRS.contains(&name.as_str()))
        {
            continue;
        }
        if path.is_dir() {
            if SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            let file_count = count_files_recursive(&path);
            modules.push(ModuleEntry { name, file_count });
        }
    }
    modules.sort_by_key(|m| std::cmp::Reverse(m.file_count));

    // Full recursive walk for language mix, entry points, and hot paths.
    walk_for_stats(
        target_repo,
        target_repo,
        &mut lang_counts,
        &mut entry_points,
        &mut hot_paths,
        &mut files_scanned,
    )
    .map_err(|e| CartographerError {
        class: FailureClass::Transient,
        message: e,
    })?;

    hot_paths.sort_by_key(|h| std::cmp::Reverse(h.lines));
    hot_paths.truncate(10);

    let mut languages: Vec<(String, usize)> = lang_counts.into_iter().collect();
    languages.sort_by_key(|(_, count)| std::cmp::Reverse(*count));

    entry_points.sort();

    Ok(CartographerReport {
        target_repo: target_repo.to_path_buf(),
        modules,
        languages,
        entry_points,
        hot_paths,
        files_scanned,
        elapsed_ms: started.elapsed().as_millis(),
        cost_usd_cents: 0,
    })
}

fn count_files_recursive(dir: &Path) -> usize {
    let mut count = 0usize;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            if path.is_dir() {
                count += count_files_recursive(&path);
            } else {
                count += 1;
            }
        }
    }
    count
}

#[allow(clippy::too_many_arguments)]
fn walk_for_stats(
    root: &Path,
    dir: &Path,
    lang_counts: &mut HashMap<String, usize>,
    entry_points: &mut Vec<String>,
    hot_paths: &mut Vec<HotPath>,
    files_scanned: &mut usize,
) -> Result<(), String> {
    let entries =
        std::fs::read_dir(dir).map_err(|e| format!("read_dir {}: {}", dir.display(), e))?;
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') && path.is_dir() {
            continue;
        }
        if path.is_dir() {
            if SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            walk_for_stats(
                root,
                &path,
                lang_counts,
                entry_points,
                hot_paths,
                files_scanned,
            )?;
            continue;
        }
        *files_scanned += 1;
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            *lang_counts.entry(ext.to_string()).or_insert(0) += 1;
        }
        let rel = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .to_string();
        if ENTRY_POINT_NAMES.contains(&name.as_str()) {
            entry_points.push(rel.clone());
        }
        if is_source_ext(path.extension().and_then(|e| e.to_str())) {
            if let Ok(contents) = std::fs::read_to_string(&path) {
                let lines = contents.lines().count();
                hot_paths.push(HotPath {
                    rel_path: rel,
                    lines,
                });
            }
        }
    }
    Ok(())
}

fn is_source_ext(ext: Option<&str>) -> bool {
    matches!(
        ext,
        Some("rs")
            | Some("py")
            | Some("js")
            | Some("ts")
            | Some("tsx")
            | Some("jsx")
            | Some("go")
            | Some("sh")
            | Some("yaml")
            | Some("yml")
    )
}

/// Render the report as ARCHITECTURE.md markdown.
pub fn render_markdown(report: &CartographerReport) -> String {
    let mut out = String::new();
    out.push_str("# Architecture\n\n");
    out.push_str(&format!(
        "_Generated by `chump cartograph` (INFRA-1782) — {} files scanned in {}ms._\n\n",
        report.files_scanned, report.elapsed_ms
    ));

    out.push_str("## Language mix\n\n");
    if report.languages.is_empty() {
        out.push_str("_no source files detected_\n\n");
    } else {
        for (ext, count) in &report.languages {
            out.push_str(&format!("- `.{}` — {} files\n", ext, count));
        }
        out.push('\n');
    }

    out.push_str("## Module map\n\n");
    if report.modules.is_empty() {
        out.push_str("_no top-level modules detected_\n\n");
    } else {
        for m in &report.modules {
            out.push_str(&format!("- `{}/` — {} files\n", m.name, m.file_count));
        }
        out.push('\n');
    }

    out.push_str("## Entry points\n\n");
    if report.entry_points.is_empty() {
        out.push_str(
            "_none detected from the day-1 language list (Rust, Python, JS/TS, Go, Bash)_\n\n",
        );
    } else {
        for e in &report.entry_points {
            out.push_str(&format!("- `{}`\n", e));
        }
        out.push('\n');
    }

    out.push_str("## Hot paths (largest source files)\n\n");
    if report.hot_paths.is_empty() {
        out.push_str("_no source files detected_\n\n");
    } else {
        for h in &report.hot_paths {
            out.push_str(&format!("- `{}` — {} lines\n", h.rel_path, h.lines));
        }
        out.push('\n');
    }

    out
}

/// Render as JSON for tooling.
pub fn render_json(report: &CartographerReport) -> serde_json::Value {
    serde_json::json!({
        "ts": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        "target_repo": report.target_repo.display().to_string(),
        "files_scanned": report.files_scanned,
        "elapsed_ms": report.elapsed_ms,
        "cost_usd_cents": report.cost_usd_cents,
        "languages": report.languages.iter().map(|(ext, count)| serde_json::json!({"ext": ext, "count": count})).collect::<Vec<_>>(),
        "modules": report.modules.iter().map(|m| serde_json::json!({"name": m.name, "file_count": m.file_count})).collect::<Vec<_>>(),
        "entry_points": report.entry_points,
        "hot_paths": report.hot_paths.iter().map(|h| serde_json::json!({"rel_path": h.rel_path, "lines": h.lines})).collect::<Vec<_>>(),
    })
}

/// Write `<target_repo>/docs/ARCHITECTURE.md`. Creates `docs/` if missing.
pub fn write_architecture_md(report: &CartographerReport) -> std::io::Result<PathBuf> {
    let docs_dir = report.target_repo.join("docs");
    std::fs::create_dir_all(&docs_dir)?;
    let out_path = docs_dir.join("ARCHITECTURE.md");
    std::fs::write(&out_path, render_markdown(report))?;
    Ok(out_path)
}

/// Emit `kind=cartographer_started|cartographer_completed|cartographer_failed`
/// to `<coordinating_repo>/.chump-locks/ambient.jsonl`. `coordinating_repo`
/// is the Chump checkout doing the ingest (not the target repo being
/// cartographed — the target repo may not have a `.chump-locks/` dir).
pub fn emit_ambient(coordinating_repo: &Path, kind: &str, fields: serde_json::Value) {
    let ambient_path = coordinating_repo.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let mut payload = serde_json::json!({
        "ts": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        "kind": kind,
    });
    if let (Some(obj), Some(extra)) = (payload.as_object_mut(), fields.as_object()) {
        for (k, v) in extra {
            obj.insert(k.clone(), v.clone());
        }
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{}", payload);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_repo(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-cartographer-{}-{}",
            name,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::create_dir_all(dir.join("tests")).unwrap();
        std::fs::write(dir.join("src/main.rs"), "fn main() {}\n// a comment\n").unwrap();
        std::fs::write(dir.join("src/lib.rs"), "pub fn helper() {}\n".repeat(50)).unwrap();
        std::fs::write(dir.join("tests/smoke.rs"), "#[test]\nfn t() {}\n").unwrap();
        dir
    }

    #[test]
    fn scan_missing_path_is_permanent_failure() {
        let dir = std::env::temp_dir().join("chump-cartographer-does-not-exist-xyz");
        let _ = std::fs::remove_dir_all(&dir);
        let err = scan(&dir).unwrap_err();
        assert_eq!(err.class, FailureClass::Permanent);
    }

    #[test]
    fn scan_detects_entry_point_and_modules() {
        let dir = fixture_repo("basic");
        let report = scan(&dir).unwrap();
        assert!(report.entry_points.iter().any(|e| e.ends_with("main.rs")));
        assert!(report.modules.iter().any(|m| m.name == "src"));
        assert!(report.modules.iter().any(|m| m.name == "tests"));
        assert!(report.files_scanned >= 3);
        assert_eq!(report.cost_usd_cents, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn scan_ranks_hot_paths_by_line_count() {
        let dir = fixture_repo("hotpaths");
        let report = scan(&dir).unwrap();
        assert_eq!(
            report
                .hot_paths
                .first()
                .unwrap()
                .rel_path
                .replace('\\', "/"),
            "src/lib.rs"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_architecture_md_creates_docs_dir() {
        let dir = fixture_repo("write");
        let report = scan(&dir).unwrap();
        let out_path = write_architecture_md(&report).unwrap();
        assert!(out_path.exists());
        let contents = std::fs::read_to_string(&out_path).unwrap();
        assert!(contents.contains("# Architecture"));
        assert!(contents.contains("main.rs"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_json_includes_cost_and_failure_fields() {
        let dir = fixture_repo("json");
        let report = scan(&dir).unwrap();
        let json = render_json(&report);
        assert_eq!(json["cost_usd_cents"], 0);
        assert!(json["files_scanned"].as_u64().unwrap() >= 3);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn emit_ambient_writes_jsonl_line() {
        let dir =
            std::env::temp_dir().join(format!("chump-cartographer-ambient-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        emit_ambient(
            &dir,
            "cartographer_completed",
            serde_json::json!({"target_repo": "x"}),
        );
        let contents = std::fs::read_to_string(dir.join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(contents.contains("cartographer_completed"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
