//! `chump scan <repo-path> [--max-gaps N]` — INFRA-1882 (2026 demo #2, repo
//! takeover opener).
//!
//! Sister of `chump ingest` (INFRA-1746): where `ingest` runs the full
//! Librarian/Cartographer/Evangelist/Systematizer pipeline behind
//! `--confirm-mutations`, `scan` is the lightweight one-shot opener — walk a
//! sibling repo with a handful of local, read-only heuristics (no GH access,
//! no LLM calls) and file up to `--max-gaps` concrete, actionable gaps
//! straight into the TARGET repo's own `.chump/state.db` (not ours). Pair
//! with `chump fleet-mode --takeover` to run takeover end-to-end.

use chump_gap_store as gap_store;
use std::path::{Path, PathBuf};
use std::time::Instant;

const DEFAULT_MAX_GAPS: usize = 5;
const TODO_MIN_COUNT: usize = 3;
const TODO_SCAN_DIRS: &[&str] = &["src", "lib", "scripts", "docs"];
const TODO_MARKERS: &[&str] = &["TODO", "FIXME", "XXX"];
const SKIP_DIRS: &[&str] = &[
    ".git",
    "target",
    "node_modules",
    ".chump",
    ".chump-locks",
    "dist",
    "build",
    "vendor",
    ".venv",
    "venv",
];

struct Opts {
    repo_path: String,
    max_gaps: usize,
    target_state_db: Option<String>,
}

enum ParseOutcome {
    Ok(Opts),
    Help,
    UsageError(String),
}

pub fn run(args: &[String]) -> i32 {
    match parse_args(args) {
        ParseOutcome::Help => {
            print_usage();
            0
        }
        ParseOutcome::UsageError(msg) => {
            eprintln!("chump scan: {msg}");
            print_usage();
            2
        }
        ParseOutcome::Ok(opts) => run_scan(&opts),
    }
}

fn print_usage() {
    println!("Usage: chump scan <repo-path> [--max-gaps N] [--target-state-db PATH]");
    println!();
    println!("Walk <repo-path> with local, read-only heuristics and file up to");
    println!("--max-gaps (default 5) concrete gaps into the target repo's own");
    println!(".chump/state.db (override with --target-state-db).");
}

fn parse_args(args: &[String]) -> ParseOutcome {
    let mut repo_path: Option<String> = None;
    let mut max_gaps = DEFAULT_MAX_GAPS;
    let mut target_state_db: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => return ParseOutcome::Help,
            "--max-gaps" => {
                let val = match args.get(i + 1) {
                    Some(v) => v,
                    None => return ParseOutcome::UsageError("--max-gaps requires a value".into()),
                };
                match val.parse::<usize>() {
                    Ok(n) if n > 0 => max_gaps = n,
                    _ => {
                        return ParseOutcome::UsageError(format!(
                            "--max-gaps must be a positive integer, got '{val}'"
                        ))
                    }
                }
                i += 2;
            }
            "--target-state-db" => {
                let val = match args.get(i + 1) {
                    Some(v) => v,
                    None => {
                        return ParseOutcome::UsageError(
                            "--target-state-db requires a value".into(),
                        )
                    }
                };
                target_state_db = Some(val.clone());
                i += 2;
            }
            arg if arg.starts_with('-') => {
                return ParseOutcome::UsageError(format!("unknown flag: {arg}"));
            }
            positional => {
                if repo_path.is_none() {
                    repo_path = Some(positional.to_string());
                } else {
                    return ParseOutcome::UsageError(format!(
                        "unexpected extra positional argument: {positional}"
                    ));
                }
                i += 1;
            }
        }
    }

    let repo_path = match repo_path {
        Some(p) => p,
        None => return ParseOutcome::UsageError("missing required <repo-path> argument".into()),
    };

    ParseOutcome::Ok(Opts {
        repo_path,
        max_gaps,
        target_state_db,
    })
}

#[derive(Debug, Clone)]
struct Finding {
    title: String,
    description: String,
    acceptance_criteria: String,
    priority: &'static str,
    effort: &'static str,
}

fn run_scan(opts: &Opts) -> i32 {
    let start = Instant::now();
    let target = PathBuf::from(&opts.repo_path);

    if !target.is_dir() {
        eprintln!(
            "chump scan: '{}' does not exist or is not a directory",
            target.display()
        );
        return 1;
    }
    if !target.join(".git").exists() {
        eprintln!("chump scan: '{}' is not a git repository", target.display());
        return 1;
    }

    let mut findings = Vec::new();
    findings.extend(scan_todo_markers(&target));
    findings.extend(scan_missing_top_level_files(&target));
    findings.extend(scan_failing_tests(&target));
    findings.extend(scan_gitignore_gaps(&target));

    let total_findings = findings.len();
    findings.truncate(opts.max_gaps);

    let store = match open_target_store(&target, opts.target_state_db.as_deref()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("chump scan: opening target state.db: {e:#}");
            return 1;
        }
    };

    let mut filed_ids = Vec::new();
    for finding in &findings {
        match file_gap(&store, finding) {
            Ok(id) => filed_ids.push(id),
            Err(e) => {
                eprintln!("chump scan: filing gap '{}': {e:#}", finding.title);
            }
        }
    }

    let chump_repo_root = crate::repo_path::repo_root();
    emit_scan_complete(
        &chump_repo_root,
        &target,
        filed_ids.len(),
        total_findings,
        start.elapsed().as_millis(),
    );

    println!(
        "chump scan: {} finding(s), filed {} gap(s) into {}",
        total_findings,
        filed_ids.len(),
        target.join(".chump").join("state.db").display()
    );
    for id in &filed_ids {
        println!("  {id}");
    }

    0
}

/// Opens (or creates) the gap store rooted at `target`'s own `.chump/`
/// directory. `--target-state-db` overrides via `CHUMP_STATE_DB`, mirroring
/// `gap_store::GapStore::db_path`'s existing env-var honor path — scoped to
/// this single call since `chump scan` is a one-shot, single-threaded run.
fn open_target_store(
    target: &Path,
    target_state_db: Option<&str>,
) -> anyhow::Result<gap_store::GapStore> {
    if let Some(path) = target_state_db {
        let prev = std::env::var("CHUMP_STATE_DB").ok();
        std::env::set_var("CHUMP_STATE_DB", path);
        let result = gap_store::GapStore::open(target);
        match prev {
            Some(p) => std::env::set_var("CHUMP_STATE_DB", p),
            None => std::env::remove_var("CHUMP_STATE_DB"),
        }
        result
    } else {
        gap_store::GapStore::open(target)
    }
}

fn file_gap(store: &gap_store::GapStore, finding: &Finding) -> anyhow::Result<String> {
    let id = store.reserve("INFRA", &finding.title, finding.priority, finding.effort)?;
    let update = gap_store::GapFieldUpdate {
        description: Some(finding.description.clone()),
        acceptance_criteria: Some(finding.acceptance_criteria.clone()),
        ..Default::default()
    };
    store.set_fields(&id, update)?;
    Ok(id)
}

// ── Heuristic 1: TODO/FIXME/XXX comment density ─────────────────────────────

fn scan_todo_markers(target: &Path) -> Vec<Finding> {
    let mut per_file: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();

    for dir_name in TODO_SCAN_DIRS {
        let dir = target.join(dir_name);
        if !dir.is_dir() {
            continue;
        }
        walk_files(&dir, &mut |path| {
            let Ok(contents) = std::fs::read_to_string(path) else {
                return;
            };
            let count = contents
                .lines()
                .filter(|line| TODO_MARKERS.iter().any(|m| line.contains(m)))
                .count();
            if count > 0 {
                let rel = path
                    .strip_prefix(target)
                    .unwrap_or(path)
                    .display()
                    .to_string();
                *per_file.entry(rel).or_insert(0) += count;
            }
        });
    }

    per_file
        .into_iter()
        .filter(|(_, count)| *count >= TODO_MIN_COUNT)
        .map(|(rel_path, count)| Finding {
            title: format!("Resolve {count} TODO/FIXME/XXX markers in {rel_path}"),
            description: format!(
                "chump scan found {count} TODO/FIXME/XXX comments in {rel_path}. \
                 Each represents an acknowledged-but-unaddressed gap in the code."
            ),
            acceptance_criteria: format!(
                "1. Every TODO/FIXME/XXX in {rel_path} is either resolved (code change) \
                 or converted into its own tracked gap with a link back in the comment.\n\
                 2. Re-running `chump scan` on this repo no longer counts {rel_path} \
                 among files with >= {TODO_MIN_COUNT} markers."
            ),
            priority: "P2",
            effort: "s",
        })
        .collect()
}

fn walk_files(dir: &Path, visit: &mut impl FnMut(&Path)) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or_default();
            if SKIP_DIRS.contains(&name) {
                continue;
            }
            walk_files(&path, visit);
        } else if path.is_file() {
            visit(&path);
        }
    }
}

// ── Heuristic 2: missing top-level files ────────────────────────────────────

fn scan_missing_top_level_files(target: &Path) -> Vec<Finding> {
    let mut findings = Vec::new();

    if !target.join("LICENSE").exists() && !target.join("LICENSE.md").exists() {
        findings.push(Finding {
            title: "Add a LICENSE file to the repo root".to_string(),
            description: "chump scan found no LICENSE or LICENSE.md at the repo root. \
                Without one, the terms under which the code can be used are undefined."
                .to_string(),
            acceptance_criteria: "1. A LICENSE (or LICENSE.md) file exists at the repo root \
                naming a specific license.\n\
                2. README.md references the chosen license."
                .to_string(),
            priority: "P3",
            effort: "xs",
        });
    }

    if !target.join("README.md").exists() {
        findings.push(Finding {
            title: "Add a README.md to the repo root".to_string(),
            description: "chump scan found no README.md at the repo root. \
                New contributors have no entry point describing what the project does \
                or how to build/run it."
                .to_string(),
            acceptance_criteria: "1. README.md exists at the repo root.\n\
                2. It covers: what the project is, how to build it, how to run it."
                .to_string(),
            priority: "P2",
            effort: "xs",
        });
    }

    let workflows_dir = target.join(".github").join("workflows");
    let has_ci_workflow = workflows_dir.is_dir()
        && std::fs::read_dir(&workflows_dir)
            .map(|entries| {
                entries.flatten().any(|e| {
                    let name = e.file_name();
                    let name = name.to_string_lossy();
                    name.ends_with(".yml") || name.ends_with(".yaml")
                })
            })
            .unwrap_or(false);
    if !has_ci_workflow {
        findings.push(Finding {
            title: "Add a CI workflow under .github/workflows/".to_string(),
            description: "chump scan found no .yml/.yaml workflow file under \
                .github/workflows/. There is no automated build/test gate on pushes or PRs."
                .to_string(),
            acceptance_criteria: "1. .github/workflows/ contains at least one workflow \
                file that runs the project's build and test suite on push/PR.\n\
                2. The workflow passes on the current default branch."
                .to_string(),
            priority: "P1",
            effort: "s",
        });
    }

    findings
}

// ── Heuristic 3: failing test suite ─────────────────────────────────────────

fn scan_failing_tests(target: &Path) -> Vec<Finding> {
    let (cmd, args): (&str, &[&str]) = if target.join("Cargo.toml").exists() {
        ("cargo", &["test", "--workspace"])
    } else if target.join("package.json").exists() {
        ("npm", &["test"])
    } else {
        return Vec::new();
    };

    let output = match std::process::Command::new(cmd)
        .args(args)
        .current_dir(target)
        .output()
    {
        Ok(o) => o,
        Err(_) => return Vec::new(), // tool not installed — not a finding chump scan can act on
    };

    if output.status.success() {
        return Vec::new();
    }

    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let failed_count = count_failures(&combined, cmd);

    vec![Finding {
        title: format!("Fix {failed_count} failing test(s) in {}", target.display()),
        description: format!(
            "chump scan ran `{cmd} {}` in {} and it exited non-zero \
             ({failed_count} failure(s) detected).",
            args.join(" "),
            target.display()
        ),
        acceptance_criteria: format!(
            "1. `{cmd} {}` exits 0 in {}.\n\
             2. No test is skipped/ignored solely to make the suite pass.",
            args.join(" "),
            target.display()
        ),
        priority: "P1",
        effort: "m",
    }]
}

/// Best-effort failure count from raw test-runner output. Falls back to 1
/// (the finding still gets filed; the exact count is a nicety, not the gate).
fn count_failures(output: &str, cmd: &str) -> usize {
    if cmd == "cargo" {
        for line in output.lines() {
            // e.g. "test result: FAILED. 3 passed; 2 failed; 0 ignored"
            if let Some(idx) = line.find(" failed") {
                let prefix = &line[..idx];
                if let Some(n) = prefix
                    .rsplit(' ')
                    .next()
                    .and_then(|s| s.parse::<usize>().ok())
                {
                    if n > 0 {
                        return n;
                    }
                }
            }
        }
    } else {
        for line in output.lines() {
            // jest/npm: "Tests: 2 failed, 3 passed, 5 total"
            if let Some(idx) = line.find(" failed") {
                let prefix = &line[..idx];
                if let Some(n) = prefix
                    .rsplit(&[' ', ','][..])
                    .next()
                    .and_then(|s| s.trim().parse::<usize>().ok())
                {
                    if n > 0 {
                        return n;
                    }
                }
            }
        }
    }
    1
}

// ── Heuristic 4: .gitignore missing common entries ──────────────────────────

fn scan_gitignore_gaps(target: &Path) -> Vec<Finding> {
    const COMMON_PATTERNS: &[&str] = &["target/", "node_modules/", ".DS_Store"];

    let gitignore_path = target.join(".gitignore");
    let existing = std::fs::read_to_string(&gitignore_path).unwrap_or_default();
    let exclude_path = target.join(".git").join("info").join("exclude");
    let existing_exclude = std::fs::read_to_string(&exclude_path).unwrap_or_default();
    let combined = format!("{existing}\n{existing_exclude}");

    let missing: Vec<&str> = COMMON_PATTERNS
        .iter()
        .filter(|p| {
            let bare = p.trim_end_matches('/');
            !combined
                .lines()
                .any(|l| l.trim() == **p || l.trim() == bare)
        })
        .copied()
        .collect();

    if missing.is_empty() {
        return Vec::new();
    }

    vec![Finding {
        title: format!(".gitignore is missing {} common pattern(s)", missing.len()),
        description: format!(
            "chump scan found .gitignore (and .git/info/exclude) missing common \
             ignore patterns: {}. Build artifacts and OS cruft risk being committed.",
            missing.join(", ")
        ),
        acceptance_criteria: format!(
            "1. .gitignore contains an entry for each of: {}.\n\
             2. `git status` is clean of any already-tracked file matching those \
             patterns (untrack them if any slipped in).",
            missing.join(", ")
        ),
        priority: "P3",
        effort: "xs",
    }]
}

// ── Ambient emit ─────────────────────────────────────────────────────────────

fn emit_scan_complete(
    chump_repo_root: &Path,
    target: &Path,
    gaps_filed: usize,
    total_findings: usize,
    elapsed_ms: u128,
) {
    let ambient_path = chump_repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let payload = serde_json::json!({
        "ts": ts,
        "kind": "chump_scan_complete",
        "target_path": target.display().to_string(),
        "gaps_filed": gaps_filed,
        "total_findings": total_findings,
        "elapsed_ms": elapsed_ms,
    });
    if let Ok(mut out) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(out, "{payload}");
    }
}
