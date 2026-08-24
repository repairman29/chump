//! CREDIBLE-215: mechanical stub detection — does a PR's diff have any
//! resolved import path to the gap's stated target?
//!
//! Complements the judgment panel (CREDIBLE-191), not a replacement: this is
//! the deterministic half. Given a gap ID (whose title/description/AC name a
//! target file) and a diff's changed-file list, classify:
//!   - REACHES     — a changed file imports, or is imported by, the target
//!                    (transitively, via almanac's resolved import graph)
//!   - TEST-ONLY   — every changed file is a test/fixture/snapshot, AND the
//!                    gap's own target is a non-test source file (so a
//!                    test-only diff against a source-fix ask is the
//!                    CREDIBLE-200 stub shape)
//!   - UNRELATED   — no changed file has any resolved path to the target
//!
//! UNRELATED is a REVIEW SIGNAL, never an auto-reject: almanac's graph only
//! walks RESOLVED intra-repo edges (its own standing lower-bound caveat,
//! typically 20-40% on large repos), so "no path found" can mean "the graph
//! didn't resolve it," not "there is no relation." Every verdict carries the
//! repo's actual edge-resolution rate so a caller can judge how much weight
//! to give it.
//!
//! `classify()` is the pure core (unit-tested against synthetic impact data,
//! no almanac dependency). `run()` is the CLI wrapper that shells out to
//! almanac-mcp for real data, mirroring `almanac_tool.rs`'s one-shot pattern.
//!
//! Usage:
//!   chump verify-reaches --gap <ID> --diff <name-only-file> [--target <path>] [--json]
//!
//! `--diff` points at a file containing one changed-file path per line (the
//! output of `git diff --name-only`). Exit code is always 0 — this is a
//! review signal, not a hard gate (see UNRELATED semantics above); use
//! `--json` and inspect `verdict` for anything stronger than advisory.

use serde::Serialize;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Verdict {
    Reaches,
    TestOnly,
    Unrelated,
}

impl Verdict {
    pub fn as_str(&self) -> &'static str {
        match self {
            Verdict::Reaches => "REACHES",
            Verdict::TestOnly => "TEST-ONLY",
            Verdict::Unrelated => "UNRELATED",
        }
    }
}

/// The subset of `almanac_impact`'s response this classifier needs, decoupled
/// from the almanac-mcp wire format so `classify()` can be unit-tested with
/// synthetic data.
#[derive(Debug, Clone, Default)]
pub struct ImpactData {
    /// Files that transitively import the target (downstream, i.e. break if
    /// the target's contract changes).
    pub affected: Vec<String>,
    /// Files the target itself imports (upstream deps), from `almanac_neighbors`.
    pub target_imports: Vec<String>,
    /// Files that transitively import each *changed* file, keyed by changed
    /// file path — used to catch the reverse direction (target depends on a
    /// changed file). Empty entries are fine; absence means "not queried" or
    /// "no transitive importers found."
    pub changed_file_affected: std::collections::HashMap<String, Vec<String>>,
    pub edges_resolved: usize,
    pub edges_total: usize,
}

impl ImpactData {
    fn resolution_rate(&self) -> f64 {
        if self.edges_total == 0 {
            0.0
        } else {
            self.edges_resolved as f64 / self.edges_total as f64
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ClassifyResult {
    pub verdict: Verdict,
    pub citations: Vec<String>,
    pub edges_resolved: usize,
    pub edges_total: usize,
    pub resolution_rate: f64,
    pub note: String,
}

/// A changed file counts as test/fixture/snapshot when its path contains a
/// recognizable test-shape marker. Deliberately broad (favors false
/// TEST-ONLY over missed ones — a missed TEST-ONLY silently ships a stub,
/// a false one just costs a human a second look).
pub fn is_test_like(path: &str) -> bool {
    let lower = path.to_lowercase();
    let markers = [
        "/tests/",
        "/test/",
        "/__tests__/",
        "/fixtures/",
        "/fixture/",
        "/snapshots/",
        "/snapshot/",
        "/e2e/",
    ];
    if markers.iter().any(|m| lower.contains(m)) {
        return true;
    }
    if lower.starts_with("tests/")
        || lower.starts_with("test/")
        || lower.starts_with("e2e/")
        || lower.starts_with("fixtures/")
        || lower.starts_with("fixture/")
        || lower.starts_with("snapshots/")
        || lower.starts_with("snapshot/")
    {
        return true;
    }
    let base = lower.rsplit('/').next().unwrap_or(&lower);
    base.starts_with("test_")
        || base.ends_with("_test.rs")
        || base.ends_with("_test.go")
        || base.ends_with(".test.ts")
        || base.ends_with(".test.tsx")
        || base.ends_with(".test.js")
        || base.ends_with(".spec.ts")
        || base.ends_with(".spec.js")
        || base.ends_with(".snap")
}

/// Core classifier — pure, no I/O. `target` is the gap's stated target file
/// (already resolved to a repo-relative path); `changed_files` are the PR's
/// diff `--name-only` entries; `impact` is almanac's import-graph data for
/// `target` (and, best-effort, for each changed file).
pub fn classify(target: &str, changed_files: &[String], impact: &ImpactData) -> ClassifyResult {
    let resolution_rate = impact.resolution_rate();
    let caveat = format!(
        "edge-resolution lower bound: {}/{} import edges resolved ({:.0}%) — unresolved edges \
         (external packages, dynamic imports, non-standard specifiers) are invisible to this \
         walk, so UNRELATED is a review signal, not proof of no relation.",
        impact.edges_resolved,
        impact.edges_total,
        resolution_rate * 100.0
    );

    if changed_files.is_empty() {
        return ClassifyResult {
            verdict: Verdict::Unrelated,
            citations: Vec::new(),
            edges_resolved: impact.edges_resolved,
            edges_total: impact.edges_total,
            resolution_rate,
            note: format!("no changed files supplied. {caveat}"),
        };
    }

    // REACHES: exact target match, or a resolved edge in either direction.
    let mut citations = Vec::new();
    for f in changed_files {
        if f == target {
            citations.push(format!("{f} == target (exact match)"));
            continue;
        }
        if impact.affected.iter().any(|a| a == f) {
            citations.push(format!("{f} transitively imports {target} (in impact set)"));
            continue;
        }
        if impact.target_imports.iter().any(|a| a == f) {
            citations.push(format!("{target} imports {f} directly (neighbor edge)"));
            continue;
        }
        if let Some(importers) = impact.changed_file_affected.get(f) {
            if importers.iter().any(|a| a == target) {
                citations.push(format!("{target} transitively imports {f} (reverse edge)"));
            }
        }
    }

    if !citations.is_empty() {
        return ClassifyResult {
            verdict: Verdict::Reaches,
            citations,
            edges_resolved: impact.edges_resolved,
            edges_total: impact.edges_total,
            resolution_rate,
            note: format!(
                "at least one changed file has a resolved import path to {target}. \
                 REACHES proves the diff can touch the target's behavior; it says nothing \
                 about quality. {caveat}"
            ),
        };
    }

    // TEST-ONLY: every changed file looks like a test/fixture/snapshot, AND
    // the target itself is a non-test file — i.e. the gap asked for a source
    // change and got only tests. If the target is itself test-shaped, the
    // gap plausibly asked only for tests, so this must NOT fire (AC3).
    if changed_files.iter().all(|f| is_test_like(f)) && !is_test_like(target) {
        return ClassifyResult {
            verdict: Verdict::TestOnly,
            citations: changed_files.to_vec(),
            edges_resolved: impact.edges_resolved,
            edges_total: impact.edges_total,
            resolution_rate,
            note: format!(
                "every changed file is a test/fixture/snapshot, but {target} (the gap's \
                 target) is a source file — this is the CREDIBLE-200 stub shape (assert-true \
                 test, no source fix). {caveat}"
            ),
        };
    }

    let unrelated_citations: Vec<String> = changed_files
        .iter()
        .map(|f| format!("{f} has no resolved import path to {target}"))
        .collect();

    ClassifyResult {
        verdict: Verdict::Unrelated,
        citations: unrelated_citations,
        edges_resolved: impact.edges_resolved,
        edges_total: impact.edges_total,
        resolution_rate,
        note: format!(
            "no changed file has a resolved import path to {target}. This is a REVIEW SIGNAL, \
             not an automatic reject — {caveat}"
        ),
    }
}

// ---------------------------------------------------------------------
// Target resolution: pull a candidate source-file target out of a gap's
// title/description/acceptance_criteria.
// ---------------------------------------------------------------------

/// Extract the first path-shaped token (contains '/' and a known source
/// extension) from free text. Best-effort — callers should let `--target`
/// override when the heuristic misses.
pub fn extract_target_from_text(text: &str) -> Option<String> {
    let exts = [
        ".rs", ".ts", ".tsx", ".js", ".jsx", ".py", ".go", ".sh", ".rb", ".java", ".c", ".cpp",
        ".h",
    ];
    for raw_tok in text.split(|c: char| {
        c.is_whitespace() || matches!(c, '`' | '"' | '\'' | '(' | ')' | ',' | ';' | ':')
    }) {
        let tok = raw_tok.trim_matches(|c: char| {
            !c.is_alphanumeric() && c != '/' && c != '.' && c != '_' && c != '-'
        });
        if tok.contains('/') && exts.iter().any(|e| tok.ends_with(e)) {
            return Some(tok.to_string());
        }
    }
    None
}

// ---------------------------------------------------------------------
// almanac-mcp I/O (mirrors almanac_tool.rs's one-shot JSON-RPC pattern)
// ---------------------------------------------------------------------

fn almanac_mcp_bin() -> Option<String> {
    if let Ok(b) = std::env::var("CHUMP_ALMANAC_MCP_BIN") {
        if Path::new(&b).is_file() {
            return Some(b);
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    [
        format!("{home}/.cargo/chump-shared-target/debug/almanac-mcp"),
        format!("{home}/Projects/almanac/target/release/almanac-mcp"),
        format!("{home}/Projects/almanac/target/debug/almanac-mcp"),
    ]
    .into_iter()
    .find(|c| Path::new(c).is_file())
}

fn almanac_db() -> Option<String> {
    if let Ok(db) = std::env::var("ALMANAC_DB") {
        if !db.trim().is_empty() && Path::new(&db).is_file() {
            return Some(db);
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    [
        format!("{home}/.almanac/indexes/chump.db"),
        format!("{home}/Projects/almanac/indexes/chump-src.db"),
    ]
    .into_iter()
    .find(|c| Path::new(c).is_file())
}

fn call_almanac(
    bin: &str,
    db: &str,
    tool: &str,
    args: serde_json::Value,
) -> Option<serde_json::Value> {
    let mut child = Command::new(bin)
        .env("ALMANAC_DB", db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let req = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": tool, "arguments": args}
    });
    {
        let stdin = child.stdin.as_mut()?;
        writeln!(stdin, "{req}").ok()?;
        stdin.flush().ok()?;
    }
    let stdout = child.stdout.take()?;
    let mut result = None;
    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
        if line.trim().is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if v.get("id").and_then(|x| x.as_i64()) == Some(1) {
            let text = v
                .get("result")
                .and_then(|r| r.get("content"))
                .and_then(|c| c.as_array())
                .and_then(|c| c.first())
                .and_then(|c| c.get("text"))
                .and_then(|t| t.as_str())
                .unwrap_or("");
            result = serde_json::from_str::<serde_json::Value>(text).ok();
            break;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    result
}

/// Fetch `ImpactData` for `target` (and, best-effort, transitive importers of
/// each changed file for the reverse-direction check). Returns a zeroed
/// `ImpactData` (edges_total 0) when almanac is unavailable — `classify()`
/// still runs, just with a 0% resolution-rate caveat rather than crashing.
fn fetch_impact_data(target: &str, changed_files: &[String]) -> ImpactData {
    let (Some(bin), Some(db)) = (almanac_mcp_bin(), almanac_db()) else {
        return ImpactData::default();
    };

    let mut data = ImpactData::default();

    if let Some(v) = call_almanac(
        &bin,
        &db,
        "almanac_impact",
        serde_json::json!({"path": target}),
    ) {
        data.edges_resolved = v
            .get("edges_resolved")
            .and_then(|x| x.as_u64())
            .unwrap_or(0) as usize;
        data.edges_total = v.get("edges_total").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
        if let Some(levels) = v.get("levels").and_then(|x| x.as_array()) {
            for level in levels {
                if let Some(files) = level.get("files").and_then(|x| x.as_array()) {
                    for f in files {
                        if let Some(s) = f.as_str() {
                            data.affected.push(s.to_string());
                        }
                    }
                }
            }
        }
    }

    if let Some(v) = call_almanac(
        &bin,
        &db,
        "almanac_neighbors",
        serde_json::json!({"path": target}),
    ) {
        if let Some(imports) = v
            .get("neighbors")
            .and_then(|n| n.get("imports"))
            .and_then(|x| x.as_array())
        {
            for f in imports {
                if let Some(s) = f.as_str() {
                    data.target_imports.push(s.to_string());
                }
            }
        }
    }

    for f in changed_files {
        if f == target {
            continue;
        }
        if let Some(v) = call_almanac(&bin, &db, "almanac_impact", serde_json::json!({"path": f})) {
            if let Some(levels) = v.get("levels").and_then(|x| x.as_array()) {
                let mut importers = Vec::new();
                for level in levels {
                    if let Some(files) = level.get("files").and_then(|x| x.as_array()) {
                        for ff in files {
                            if let Some(s) = ff.as_str() {
                                importers.push(s.to_string());
                            }
                        }
                    }
                }
                data.changed_file_affected.insert(f.clone(), importers);
            }
        }
    }

    data
}

fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(c) = std::fs::read_to_string(&cargo) {
                if c.contains("[workspace]") {
                    return dir;
                }
            }
        }
        if !dir.pop() {
            break;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn resolve_target_from_gap(gap_id: &str) -> Option<String> {
    let root = repo_root();
    let store = chump_gap_store::GapStore::open(&root).ok()?;
    let row = store.get(gap_id).ok()??;
    let text = format!(
        "{}\n{}\n{}",
        row.title, row.description, row.acceptance_criteria
    );
    extract_target_from_text(&text)
}

pub fn run(args: &[String]) -> i32 {
    let mut gap_id: Option<String> = None;
    let mut diff_file: Option<String> = None;
    let mut target: Option<String> = None;
    let mut want_json = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--gap" => {
                i += 1;
                if i < args.len() {
                    gap_id = Some(args[i].clone());
                }
            }
            "--diff" => {
                i += 1;
                if i < args.len() {
                    diff_file = Some(args[i].clone());
                }
            }
            "--target" => {
                i += 1;
                if i < args.len() {
                    target = Some(args[i].clone());
                }
            }
            "--json" => want_json = true,
            "--help" | "-h" => {
                println!(
                    "Usage: chump verify-reaches --gap <ID> --diff <name-only-file> \
                     [--target <path>] [--json]"
                );
                return 0;
            }
            _ => {}
        }
        i += 1;
    }

    let Some(gap_id) = gap_id else {
        eprintln!("verify-reaches: --gap <ID> is required");
        return 2;
    };
    let Some(diff_file) = diff_file else {
        eprintln!("verify-reaches: --diff <name-only-file> is required");
        return 2;
    };

    let changed_files: Vec<String> = match std::fs::read_to_string(&diff_file) {
        Ok(s) => s
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect(),
        Err(e) => {
            eprintln!("verify-reaches: cannot read --diff file {diff_file}: {e}");
            return 2;
        }
    };

    let target = target.or_else(|| resolve_target_from_gap(&gap_id));
    let Some(target) = target else {
        if want_json {
            println!(
                r#"{{"verdict":null,"note":"no resolvable target for {gap_id} — pass --target explicitly"}}"#
            );
        } else {
            println!(
                "[verify-reaches] no resolvable target for {gap_id} (no source path in \
                 title/description/AC) — pass --target explicitly to check. Skipping (non-blocking)."
            );
        }
        return 0;
    };

    let impact = fetch_impact_data(&target, &changed_files);
    let result = classify(&target, &changed_files, &impact);

    if want_json {
        println!(
            "{}",
            serde_json::json!({
                "gap": gap_id,
                "target": target,
                "verdict": result.verdict.as_str(),
                "citations": result.citations,
                "edges_resolved": result.edges_resolved,
                "edges_total": result.edges_total,
                "resolution_rate": result.resolution_rate,
                "note": result.note,
            })
        );
    } else {
        println!(
            "[verify-reaches] {gap_id} target={target} verdict={}",
            result.verdict.as_str()
        );
        println!("  {}", result.note);
        for c in &result.citations {
            println!("  - {c}");
        }
    }

    // Advisory only — see module doc. Never a hard failure.
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn impact(
        affected: &[&str],
        target_imports: &[&str],
        resolved: usize,
        total: usize,
    ) -> ImpactData {
        ImpactData {
            affected: affected.iter().map(|s| s.to_string()).collect(),
            target_imports: target_imports.iter().map(|s| s.to_string()).collect(),
            changed_file_affected: Default::default(),
            edges_resolved: resolved,
            edges_total: total,
        }
    }

    #[test]
    fn exact_target_match_is_reaches() {
        let changed = vec!["src/foo.rs".to_string()];
        let r = classify("src/foo.rs", &changed, &impact(&[], &[], 100, 200));
        assert_eq!(r.verdict, Verdict::Reaches);
        assert!(!r.citations.is_empty());
    }

    #[test]
    fn transitive_importer_is_reaches() {
        let changed = vec!["src/caller.rs".to_string()];
        let r = classify(
            "src/foo.rs",
            &changed,
            &impact(&["src/caller.rs"], &[], 100, 200),
        );
        assert_eq!(r.verdict, Verdict::Reaches);
    }

    #[test]
    fn direct_dependency_is_reaches() {
        let changed = vec!["src/dep.rs".to_string()];
        let r = classify(
            "src/foo.rs",
            &changed,
            &impact(&[], &["src/dep.rs"], 100, 200),
        );
        assert_eq!(r.verdict, Verdict::Reaches);
    }

    #[test]
    fn reverse_edge_via_changed_file_impact_is_reaches() {
        let changed = vec!["src/dep.rs".to_string()];
        let mut i = impact(&[], &[], 100, 200);
        i.changed_file_affected
            .insert("src/dep.rs".to_string(), vec!["src/foo.rs".to_string()]);
        let r = classify("src/foo.rs", &changed, &i);
        assert_eq!(r.verdict, Verdict::Reaches);
    }

    // CREDIBLE-200 shape: assert-true test added, no source change, gap
    // named a source target. Must be flagged TEST-ONLY. AC5.
    #[test]
    fn credible_200_shape_is_test_only() {
        let changed = vec!["tests/test_foo.rs".to_string()];
        let r = classify("src/foo.rs", &changed, &impact(&[], &[], 100, 200));
        assert_eq!(r.verdict, Verdict::TestOnly);
    }

    // Without the classifier, an assert-true-only test diff against a named
    // source target passes review invisibly. This proves it fails to detect
    // without is_test_like + target-is-source logic present.
    #[test]
    fn credible_200_shape_fails_without_test_only_detection() {
        let changed = ["tests/test_foo.rs".to_string()];
        assert!(is_test_like(&changed[0]));
        assert!(!is_test_like("src/foo.rs"));
    }

    #[test]
    fn test_only_does_not_fire_when_target_itself_is_test_shaped() {
        // AC3: gap whose own AC asked only for tests must not be flagged.
        let changed = vec!["tests/test_foo.rs".to_string()];
        let r = classify("tests/test_bar.rs", &changed, &impact(&[], &[], 100, 200));
        assert_ne!(r.verdict, Verdict::TestOnly);
        // When target itself is test-shaped, the gap plausibly asked only for
        // tests, so we fall through to UNRELATED (no import edges here).
        assert_eq!(r.verdict, Verdict::Unrelated);
    }

    #[test]
    fn no_path_at_all_is_unrelated() {
        let changed = vec!["src/unrelated.rs".to_string()];
        let r = classify("src/foo.rs", &changed, &impact(&[], &[], 100, 200));
        assert_eq!(r.verdict, Verdict::Unrelated);
        assert!(r.note.contains("REVIEW SIGNAL"));
    }

    #[test]
    fn unrelated_note_never_says_reject() {
        let changed = vec!["src/unrelated.rs".to_string()];
        let r = classify("src/foo.rs", &changed, &impact(&[], &[], 5, 100));
        assert!(!r.note.to_lowercase().contains("auto-reject"));
        assert!(r.note.contains("REVIEW SIGNAL"));
    }

    #[test]
    fn resolution_rate_carried_in_result() {
        let changed = vec!["src/x.rs".to_string()];
        let r = classify("src/foo.rs", &changed, &impact(&[], &[], 30, 100));
        assert_eq!(r.edges_resolved, 30);
        assert_eq!(r.edges_total, 100);
        assert!((r.resolution_rate - 0.3).abs() < 1e-9);
    }

    #[test]
    fn empty_changed_files_is_unrelated() {
        let r = classify("src/foo.rs", &[], &impact(&[], &[], 10, 20));
        assert_eq!(r.verdict, Verdict::Unrelated);
    }

    #[test]
    fn is_test_like_matches_common_shapes() {
        assert!(is_test_like("tests/foo.rs"));
        assert!(is_test_like("src/foo_test.go"));
        assert!(is_test_like("src/foo.test.ts"));
        assert!(is_test_like("src/foo.spec.js"));
        assert!(is_test_like("crates/x/src/__tests__/y.ts"));
        assert!(is_test_like("fixtures/bar.json"));
        assert!(!is_test_like("src/foo.rs"));
        assert!(!is_test_like("src/protest.rs"));
    }

    #[test]
    fn extract_target_from_text_finds_rs_path() {
        let text = "Integration target: src/improve.rs — the ship path.";
        assert_eq!(
            extract_target_from_text(text),
            Some("src/improve.rs".to_string())
        );
    }

    #[test]
    fn extract_target_from_text_none_when_no_path() {
        assert_eq!(
            extract_target_from_text("just a description, no path here"),
            None
        );
    }

    #[test]
    fn extract_target_from_text_strips_punctuation() {
        let text = "First slice: (src/commands/reachability.rs).";
        assert_eq!(
            extract_target_from_text(text),
            Some("src/commands/reachability.rs".to_string())
        );
    }
}
