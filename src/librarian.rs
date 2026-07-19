//! INFRA-1781: Phase 1 Librarian audit + triage report (INFRA-1746 phase 1b).
//!
//! Walks a target repo (any repo — not necessarily this one) and produces a
//! triage report at `<target>/.chump-ingest/triage.md`: file/extension
//! census, largest files, and TODO/FIXME density. This is the "read-only
//! sweep" leg of `chump ingest`; INFRA-1780 (CLI) and INFRA-1784
//! (orchestration) wire it into the full ingest pipeline.
//!
//! Observability contract (this gap's AC):
//! - events: `librarian_audit_started` / `librarian_audit_complete` /
//!   `librarian_audit_failed`, always in that pairing (started, then exactly
//!   one of complete/failed).
//! - cost: rough token-based USD estimate over scanned file bytes, reported
//!   in `librarian_audit_complete.cost_usd_cents` and returned in
//!   `TriageReport::cost_usd_cents`.
//! - failure taxonomy: `LibrarianError::Transient` (retryable — I/O errors
//!   reading a file mid-walk) vs `LibrarianError::Permanent` (retrying won't
//!   help — target path missing or not a directory).
//! - smoke test: `scripts/ci/test-librarian-audit-smoke.sh`.

use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// Failure taxonomy (AC #3): distinguishes retryable conditions from ones
/// where retrying the same input will not help.
#[derive(Debug, Clone)]
pub enum LibrarianError {
    /// Retryable: a transient I/O error while walking the tree (e.g. a file
    /// vanished between listing and reading, permission hiccup).
    Transient(String),
    /// Not retryable: the input itself is invalid (missing path, not a
    /// directory).
    Permanent(String),
}

impl LibrarianError {
    pub fn as_str(&self) -> &'static str {
        match self {
            LibrarianError::Transient(_) => "transient",
            LibrarianError::Permanent(_) => "permanent",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            LibrarianError::Transient(m) | LibrarianError::Permanent(m) => m,
        }
    }
}

impl fmt::Display for LibrarianError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({})", self.message(), self.as_str())
    }
}

impl std::error::Error for LibrarianError {}

/// One file's contribution to the census.
#[derive(Debug, Clone)]
struct FileStat {
    rel_path: String,
    bytes: u64,
    todo_count: u64,
}

/// Result of a Phase 1 Librarian sweep.
#[derive(Debug, Clone)]
pub struct TriageReport {
    pub target_repo: PathBuf,
    pub report_path: PathBuf,
    pub files_scanned: u64,
    pub bytes_scanned: u64,
    pub todo_count: u64,
    pub ext_census: Vec<(String, u64)>,
    pub largest_files: Vec<(String, u64)>,
    pub elapsed_ms: u128,
    pub cost_usd_cents: u64,
}

const SKIP_DIRS: &[&str] = &[
    ".git",
    "target",
    "node_modules",
    ".chump-locks",
    ".chump-ingest",
    "dist",
    "build",
];

/// Rough token estimate: 1 token ~= 4 bytes for source text. Mirrors the
/// convention in src/orchestrate.rs.
fn estimate_tokens(bytes: u64) -> u64 {
    (bytes / 4).max(1)
}

/// Rough cost estimate in USD cents, using haiku-class per-token pricing
/// since the sweep is read-only pattern matching, not generation.
fn estimate_cost_usd_cents(tokens: u64) -> u64 {
    // ~$0.25 / 1M input tokens (haiku-class) => cents = tokens * 0.25 / 1e6 * 100
    let cents = (tokens as f64) * 0.25 / 1_000_000.0 * 100.0;
    cents.ceil().max(1.0) as u64
}

fn walk(dir: &Path, out: &mut Vec<FileStat>, root: &Path) -> Result<(), LibrarianError> {
    let entries = fs::read_dir(dir)
        .map_err(|e| LibrarianError::Transient(format!("read_dir {}: {e}", dir.display())))?;
    for entry in entries {
        let entry =
            entry.map_err(|e| LibrarianError::Transient(format!("dir entry: {e}")))?;
        let path = entry.path();
        let file_name = entry.file_name();
        let name = file_name.to_string_lossy();
        if path.is_dir() {
            if SKIP_DIRS.contains(&name.as_ref()) || name.starts_with('.') {
                continue;
            }
            walk(&path, out, root)?;
            continue;
        }
        let meta = match fs::metadata(&path) {
            Ok(m) => m,
            // A file vanishing mid-walk is transient, not fatal to the sweep.
            Err(_) => continue,
        };
        let bytes = meta.len();
        let todo_count = if bytes < 2_000_000 {
            fs::read_to_string(&path)
                .map(|s| {
                    s.matches("TODO").count() as u64 + s.matches("FIXME").count() as u64
                })
                .unwrap_or(0)
        } else {
            0
        };
        let rel_path = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .to_string();
        out.push(FileStat {
            rel_path,
            bytes,
            todo_count,
        });
    }
    Ok(())
}

/// Run the Phase 1 Librarian sweep against `target_repo` and write the
/// triage report to `<target_repo>/.chump-ingest/triage.md`.
///
/// Emits `librarian_audit_started` before the walk and exactly one of
/// `librarian_audit_complete` / `librarian_audit_failed` after, to
/// `<chump_repo_root>/.chump-locks/ambient.jsonl` (or
/// `CHUMP_AMBIENT_IN_PROMPT` when set, for test isolation).
pub fn run_audit(
    target_repo: &Path,
    chump_repo_root: &Path,
) -> Result<TriageReport, LibrarianError> {
    let start = Instant::now();
    emit_ambient_event(
        chump_repo_root,
        "librarian_audit_started",
        &[("target_repo", &target_repo.display().to_string())],
    );

    if !target_repo.exists() || !target_repo.is_dir() {
        let err = LibrarianError::Permanent(format!(
            "target repo path does not exist or is not a directory: {}",
            target_repo.display()
        ));
        emit_failure(chump_repo_root, target_repo, &err, start.elapsed().as_millis());
        return Err(err);
    }

    let mut files = Vec::new();
    if let Err(err) = walk(target_repo, &mut files, target_repo) {
        emit_failure(chump_repo_root, target_repo, &err, start.elapsed().as_millis());
        return Err(err);
    }

    let files_scanned = files.len() as u64;
    let bytes_scanned: u64 = files.iter().map(|f| f.bytes).sum();
    let todo_count: u64 = files.iter().map(|f| f.todo_count).sum();

    let mut ext_counts: std::collections::HashMap<String, u64> =
        std::collections::HashMap::new();
    for f in &files {
        let ext = Path::new(&f.rel_path)
            .extension()
            .map(|e| e.to_string_lossy().to_string())
            .unwrap_or_else(|| "(no ext)".to_string());
        *ext_counts.entry(ext).or_insert(0) += 1;
    }
    let mut ext_census: Vec<(String, u64)> = ext_counts.into_iter().collect();
    ext_census.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    ext_census.truncate(15);

    let mut by_size: Vec<(String, u64)> =
        files.iter().map(|f| (f.rel_path.clone(), f.bytes)).collect();
    by_size.sort_by_key(|f| std::cmp::Reverse(f.1));
    by_size.truncate(10);

    let elapsed_ms = start.elapsed().as_millis();
    let tokens = estimate_tokens(bytes_scanned);
    let cost_usd_cents = estimate_cost_usd_cents(tokens);

    let ingest_dir = target_repo.join(".chump-ingest");
    fs::create_dir_all(&ingest_dir).map_err(|e| {
        LibrarianError::Transient(format!("create {}: {e}", ingest_dir.display()))
    })?;
    let report_path = ingest_dir.join("triage.md");
    let body = render_triage_md(
        target_repo,
        files_scanned,
        bytes_scanned,
        todo_count,
        &ext_census,
        &by_size,
    );
    fs::write(&report_path, &body)
        .map_err(|e| LibrarianError::Transient(format!("write {}: {e}", report_path.display())))?;

    emit_ambient_event(
        chump_repo_root,
        "librarian_audit_complete",
        &[
            ("target_repo", &target_repo.display().to_string()),
            ("files_scanned", &files_scanned.to_string()),
            ("todo_count", &todo_count.to_string()),
            ("elapsed_ms", &elapsed_ms.to_string()),
            ("cost_usd_cents", &cost_usd_cents.to_string()),
            ("report_path", &report_path.display().to_string()),
        ],
    );

    Ok(TriageReport {
        target_repo: target_repo.to_path_buf(),
        report_path,
        files_scanned,
        bytes_scanned,
        todo_count,
        ext_census,
        largest_files: by_size,
        elapsed_ms,
        cost_usd_cents,
    })
}

fn emit_failure(
    chump_repo_root: &Path,
    target_repo: &Path,
    err: &LibrarianError,
    elapsed_ms: u128,
) {
    emit_ambient_event(
        chump_repo_root,
        "librarian_audit_failed",
        &[
            ("target_repo", &target_repo.display().to_string()),
            ("failure_class", err.as_str()),
            ("message", err.message()),
            ("elapsed_ms", &elapsed_ms.to_string()),
        ],
    );
}

fn render_triage_md(
    target_repo: &Path,
    files_scanned: u64,
    bytes_scanned: u64,
    todo_count: u64,
    ext_census: &[(String, u64)],
    largest_files: &[(String, u64)],
) -> String {
    let mut out = String::new();
    out.push_str("# Triage report — Phase 1 Librarian sweep\n\n");
    out.push_str(&format!("Target: `{}`\n\n", target_repo.display()));
    out.push_str(&format!(
        "- Files scanned: {files_scanned}\n- Bytes scanned: {bytes_scanned}\n- TODO/FIXME markers: {todo_count}\n\n"
    ));
    out.push_str("## File census by extension\n\n");
    for (ext, count) in ext_census {
        out.push_str(&format!("- .{ext}: {count}\n"));
    }
    out.push_str("\n## Largest files\n\n");
    for (path, bytes) in largest_files {
        out.push_str(&format!("- {path} ({bytes} bytes)\n"));
    }
    out
}

/// Emit a structured event to ambient.jsonl for fleet observability.
/// Mirrors the convention in src/orchestrate.rs::emit_ambient_event.
fn emit_ambient_event(repo_root: &Path, kind: &str, fields: &[(&str, &str)]) {
    let ambient = if let Ok(path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        Path::new(&path).to_path_buf()
    } else {
        let lock_dir = repo_root.join(".chump-locks");
        let _ = fs::create_dir_all(&lock_dir);
        lock_dir.join("ambient.jsonl")
    };
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut map = serde_json::Map::new();
    map.insert("ts".into(), serde_json::Value::String(ts));
    map.insert("kind".into(), serde_json::Value::String(kind.into()));
    for (k, v) in fields {
        map.insert((*k).into(), serde_json::Value::String((*v).into()));
    }
    let event = serde_json::Value::Object(map).to_string();
    use std::io::Write as _;
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&ambient) {
        let _ = writeln!(f, "{event}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-librarian-test-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn permanent_error_on_missing_target() {
        let chump_root = temp_dir("chump-root-missing");
        let missing = chump_root.join("does-not-exist");
        let err = run_audit(&missing, &chump_root).unwrap_err();
        assert_eq!(err.as_str(), "permanent");
        let _ = fs::remove_dir_all(&chump_root);
    }

    #[test]
    fn writes_triage_report_and_emits_events() {
        let chump_root = temp_dir("chump-root-ok");
        let target = temp_dir("target-ok");
        fs::write(target.join("main.rs"), "// TODO: fix this\nfn main() {}\n").unwrap();
        fs::write(target.join("README.md"), "hello\n").unwrap();

        let ambient_path = chump_root.join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_IN_PROMPT", &ambient_path);
        let report = run_audit(&target, &chump_root).unwrap();
        std::env::remove_var("CHUMP_AMBIENT_IN_PROMPT");

        assert_eq!(report.files_scanned, 2);
        assert_eq!(report.todo_count, 1);
        assert!(report.report_path.exists());
        assert!(report.cost_usd_cents >= 1);

        let events = fs::read_to_string(&ambient_path).unwrap();
        assert!(events.contains("librarian_audit_started"));
        assert!(events.contains("librarian_audit_complete"));

        let _ = fs::remove_dir_all(&chump_root);
        let _ = fs::remove_dir_all(&target);
    }
}
