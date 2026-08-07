//! CREDIBLE-215: mechanical stub detection — `chump verify-reaches`.
//!
//! The deterministic half of anti-stub enforcement (complements the judgment
//! panel CREDIBLE-191, does not replace it). Given a gap that names a source
//! target and a PR/diff claiming to close it, ask almanac whether any changed
//! file has a *resolved import path* to that target, and emit one of three
//! honest verdicts:
//!
//!   * `REACHES`    — a changed file is the target, or transitively imports /
//!                    is imported by it (proves nothing about quality).
//!   * `TEST-ONLY`  — every changed file is a test / fixture / snapshot, yet the
//!                    gap named a *source* target (the CREDIBLE-200 stub shape:
//!                    an added `assert 1 == 1` with no source change).
//!   * `UNRELATED`  — changed files exist, none is a test, none resolves any
//!                    path to the target.
//!
//! Every verdict carries almanac's standing lower-bound caveat — only resolved
//! intra-repo edges walk (roughly 20-40% on large repos) — so `UNRELATED` is a
//! STRONG SIGNAL FOR REVIEW, never an automatic reject. The asymmetry is the
//! point: `REACHES` is weak, but `TEST-ONLY` / `UNRELATED` on a gap that asked
//! for a source fix are exactly the two shapes EFFECTIVE-354 and CREDIBLE-200
//! describe.
//!
//! Wired via `commands::dispatch_external::try_dispatch` under the
//! `verify-reaches` token (NOT `src/main.rs`, which stays a thin switchboard).
//!
//! The classifier (`classify`) is a PURE function — `(target, changed_files,
//! connected) -> Classification` — so it is unit-testable with no process,
//! filesystem, or almanac dependency. The CLI (`run`) is the thin shell that
//! reads the diff, loads the gap, shells to `almanac impact` (timeout-guarded)
//! to build the `connected` set, then calls the classifier.

use std::collections::HashSet;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The three honest verdicts plus `Unknown` (not enough signal to judge).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// A changed file resolves an import path to the target.
    Reaches,
    /// Every changed file is a test/fixture, but the gap named a source target.
    TestOnly,
    /// Changed files exist, none is a test, none reaches the target.
    Unrelated,
    /// Not enough signal to render a reachability verdict (empty diff, or the
    /// gap names no source target). NEVER laundered into a rejection.
    Unknown,
}

impl Verdict {
    /// The literal token printed to stdout — one of these is always present.
    pub fn label(&self) -> &'static str {
        match self {
            Verdict::Reaches => "REACHES",
            Verdict::TestOnly => "TEST-ONLY",
            Verdict::Unrelated => "UNRELATED",
            Verdict::Unknown => "UNKNOWN",
        }
    }
}

/// A verdict plus the citations that justify it and a human-readable reason.
#[derive(Debug, Clone)]
pub struct Classification {
    pub verdict: Verdict,
    /// Files that justify the verdict (the reaching file for REACHES, the test
    /// files for TEST-ONLY, the unrelated changed files for UNRELATED).
    pub citations: Vec<String>,
    pub reason: String,
}

/// Almanac's resolved-edge statistics for the repo, carried on every verdict so
/// the lower-bound caveat is honest and quantified.
#[derive(Debug, Clone, Default)]
pub struct EdgeStats {
    pub resolved: u64,
    pub total: u64,
    /// True when almanac actually answered; false when the binary/index was
    /// unavailable (the caveat still prints, but with an unknown rate).
    pub available: bool,
}

impl EdgeStats {
    fn rate_pct(&self) -> Option<u64> {
        self.resolved.saturating_mul(100).checked_div(self.total)
    }
}

/// Normalize a path for comparison: trim, drop a leading `./`.
fn norm(p: &str) -> String {
    let t = p.trim();
    t.strip_prefix("./").unwrap_or(t).to_string()
}

/// Do two repo-relative paths refer to the same file? Exact after
/// normalization, or one is a path-suffix of the other on a `/` boundary (so a
/// bare-filename target still matches its full repo path, matching almanac's own
/// unique-suffix resolution).
fn paths_equal(a: &str, b: &str) -> bool {
    let (a, b) = (norm(a), norm(b));
    if a == b {
        return true;
    }
    let suffix = |long: &str, short: &str| {
        long.len() > short.len()
            && long.ends_with(short)
            && long.as_bytes()[long.len() - short.len() - 1] == b'/'
    };
    suffix(&a, &b) || suffix(&b, &a)
}

/// Reuse the ONE canonical test-file heuristic (Gate 2 / CREDIBLE-200).
fn is_test_path(path: &str) -> bool {
    crate::external_verify_merge::is_test_file(path)
}

/// Extract the first source-code target named in a gap's text.
///
/// Scans for path-like tokens ending in a recognized code extension and returns
/// the first one that is NOT a test file. Returns `None` when the text names
/// only test paths (or none) — that is the honest "no source target" case, and
/// the classifier must render UNKNOWN rather than invent a verdict.
///
/// The caller joins the gap's description, acceptance criteria, and notes (in
/// that order) so the "target of record" a gap states up front wins.
pub fn extract_source_target(text: &str) -> Option<String> {
    const CODE_EXTS: &[&str] = &[".rs", ".ts", ".tsx", ".js", ".jsx", ".py", ".go", ".rb"];
    // Split on whitespace and characters that commonly bracket a path in prose
    // (quotes, backticks, parens, commas, colons, semicolons).
    let is_boundary = |c: char| c.is_whitespace() || "`'\"(),;:<>[]{}".contains(c);
    for raw in text.split(is_boundary) {
        let tok = raw.trim().trim_end_matches('.');
        if tok.is_empty() || !tok.contains('/') {
            continue;
        }
        if !CODE_EXTS.iter().any(|e| tok.ends_with(e)) {
            continue;
        }
        if is_test_path(tok) {
            continue;
        }
        return Some(norm(tok));
    }
    None
}

/// PURE classifier — the load-bearing core. No IO, no process, no almanac.
///
/// * `target`        — the source path the gap named, or `None` if it named no
///   source target (tests/fixtures only).
/// * `changed_files` — the diff's `--name-only` paths.
/// * `connected`     — the set of files almanac resolved as connected to the
///   target (its transitive importers). Empty when almanac had no edges.
pub fn classify(
    target: Option<&str>,
    changed_files: &[String],
    connected: &HashSet<String>,
) -> Classification {
    let changed: Vec<&str> = changed_files
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    if changed.is_empty() {
        return Classification {
            verdict: Verdict::Unknown,
            citations: vec![],
            reason: "empty diff — no changed files to classify".to_string(),
        };
    }

    let target = match target {
        Some(t) if !t.trim().is_empty() => norm(t),
        _ => {
            return Classification {
                verdict: Verdict::Unknown,
                citations: vec![],
                reason: "no-target — the gap names no source file (tests/fixtures \
                         only); reachability cannot be judged without a target, so \
                         no verdict is rendered (never an auto-reject)"
                    .to_string(),
            };
        }
    };

    // TEST-ONLY takes precedence over REACHES: a diff whose every file is a test
    // cannot be the source fix the gap asked for, even if a test imports the
    // target. This is the CREDIBLE-200 shape.
    if changed.iter().all(|f| is_test_path(f)) {
        return Classification {
            verdict: Verdict::TestOnly,
            citations: changed.iter().map(|s| s.to_string()).collect(),
            reason: format!(
                "every changed file is a test/fixture/snapshot, but the gap named \
                 source target `{target}` — no source file was changed (the \
                 CREDIBLE-200 stub shape: green CI, empty fix)"
            ),
        };
    }

    // A connected set normalized for membership tests.
    let connected_norm: HashSet<String> = connected.iter().map(|s| norm(s)).collect();

    let mut cites: Vec<String> = Vec::new();
    for f in &changed {
        let nf = norm(f);
        if paths_equal(&nf, &target) || connected_norm.contains(&nf) {
            cites.push(nf);
        }
    }
    if !cites.is_empty() {
        return Classification {
            verdict: Verdict::Reaches,
            citations: cites,
            reason: format!(
                "changed file(s) resolve an intra-repo import path to target `{target}`"
            ),
        };
    }

    Classification {
        verdict: Verdict::Unrelated,
        citations: changed.iter().map(|s| s.to_string()).collect(),
        reason: format!(
            "no changed file has any resolved import path to target `{target}` — a \
             STRONG REVIEW SIGNAL, never an auto-reject (edge resolution is a lower \
             bound; the real path may be unresolved)"
        ),
    }
}

/// Resolve the `almanac` CLI binary: `CHUMP_ALMANAC_BIN`, then common checkout
/// locations, then `PATH`. Absent binary → `None` (the check degrades to an
/// unavailable-edge caveat rather than a hard failure).
fn almanac_bin() -> Option<String> {
    if let Ok(b) = std::env::var("CHUMP_ALMANAC_BIN") {
        if Path::new(&b).is_file() {
            return Some(b);
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        format!("{home}/Projects/almanac/target/release/almanac"),
        format!("{home}/Projects/almanac/target/debug/almanac"),
    ];
    if let Some(hit) = candidates.into_iter().find(|c| Path::new(c).is_file()) {
        return Some(hit);
    }
    // PATH lookup.
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            let cand = Path::new(dir).join("almanac");
            if cand.is_file() {
                return Some(cand.to_string_lossy().into_owned());
            }
        }
    }
    None
}

/// Run a command with a wall-clock timeout, returning its captured output or
/// `None` on spawn error / timeout (the child is killed).
fn run_with_timeout(mut cmd: Command, secs: u64) -> Option<std::process::Output> {
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().ok()?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().ok(),
            Ok(None) => {
                if start.elapsed().as_secs() >= secs {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(_) => return None,
        }
    }
}

/// Shell to `almanac impact <target> <repo> --json` (timeout-guarded) and return
/// the set of files that transitively import the target, plus the repo's
/// resolved-edge statistics. On any failure returns an empty set with
/// `available: false` — the caller still emits the caveat, just without a rate.
fn resolve_connected(target: &str, repo: &str) -> (HashSet<String>, EdgeStats) {
    let mut out = HashSet::new();
    let mut stats = EdgeStats::default();

    let Some(bin) = almanac_bin() else {
        return (out, stats);
    };
    let mut cmd = Command::new(bin);
    cmd.args(["impact", target, repo, "--json"]);
    let Some(output) = run_with_timeout(cmd, 20) else {
        return (out, stats);
    };
    if !output.status.success() {
        return (out, stats);
    }
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&output.stdout) else {
        return (out, stats);
    };

    stats.available = true;
    stats.resolved = v
        .get("edges_resolved")
        .and_then(|x| x.as_u64())
        .unwrap_or(0);
    stats.total = v.get("edges_total").and_then(|x| x.as_u64()).unwrap_or(0);

    if let Some(levels) = v.get("levels").and_then(|x| x.as_array()) {
        for lvl in levels {
            if let Some(files) = lvl.get("files").and_then(|x| x.as_array()) {
                for f in files {
                    if let Some(s) = f.as_str() {
                        out.insert(norm(s));
                    }
                }
            }
        }
    }
    (out, stats)
}

/// Load a gap's combined text (description, then acceptance criteria, then
/// notes) from the canonical store. Best-effort — `None` when the store can't
/// be opened or the ID is absent.
fn load_gap_text(gap_id: &str) -> Option<String> {
    let repo_root = crate::repo_path::repo_root();
    let store = chump_gap_store::GapStore::open(&repo_root).ok()?;
    let row = store.get(gap_id).ok().flatten()?;
    let ac = match serde_json::from_str::<Vec<String>>(&row.acceptance_criteria) {
        Ok(list) => list.join("\n"),
        Err(_) => row.acceptance_criteria.clone(),
    };
    Some(format!("{}\n{}\n{}", row.description, ac, row.notes))
}

/// Read a `--name-only` diff file into a list of changed paths (one per line,
/// blanks dropped).
fn read_diff_file(path: &str) -> std::io::Result<Vec<String>> {
    let body = std::fs::read_to_string(path)?;
    Ok(body
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect())
}

fn arg_value<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
}

const USAGE: &str = "usage: chump verify-reaches --gap <ID> --diff <name-only-file> \
                     [--target <src/path>] [--repo <slug>] [--json]";

/// CLI entrypoint for `chump verify-reaches`.
///
/// Advisory by design: a verdict is a REVIEW SIGNAL, so a rendered verdict
/// always exits 0. Only a usage/IO error exits non-zero (2).
pub fn run(args: &[String]) -> i32 {
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("{USAGE}");
        println!("\nEmits exactly one of REACHES / TEST-ONLY / UNRELATED / UNKNOWN.");
        println!("Every verdict carries almanac's resolved-edge lower bound; UNRELATED");
        println!("is a strong review signal, NEVER an automatic reject (CREDIBLE-215).");
        return 0;
    }

    let Some(gap_id) = arg_value(args, "--gap") else {
        eprintln!("error: --gap is required\n{USAGE}");
        return 2;
    };
    let Some(diff_path) = arg_value(args, "--diff") else {
        eprintln!("error: --diff is required\n{USAGE}");
        return 2;
    };
    let json_out = args.iter().any(|a| a == "--json");
    let repo = arg_value(args, "--repo").unwrap_or("chump");

    let changed_files = match read_diff_file(diff_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("error: cannot read --diff file `{diff_path}`: {e}");
            return 2;
        }
    };

    // Target: explicit --target wins; else extract from the gap's text.
    let gap_text = load_gap_text(gap_id);
    let target: Option<String> = arg_value(args, "--target")
        .map(norm)
        .or_else(|| gap_text.as_deref().and_then(extract_source_target));

    // Build the connected set + edge stats from almanac (skip when there is no
    // target — no point querying, and the verdict is UNKNOWN anyway).
    let (connected, stats) = match target.as_deref() {
        Some(t) => resolve_connected(t, repo),
        None => (HashSet::new(), EdgeStats::default()),
    };

    let result = classify(target.as_deref(), &changed_files, &connected);

    // The caveat line ALWAYS carries the literal "resolved intra-repo edges".
    let caveat = match (stats.available, stats.rate_pct()) {
        (true, Some(pct)) => format!(
            "{}/{} resolved intra-repo edges ({}% resolution rate) — a LOWER BOUND; \
             UNRELATED is a review signal, never an auto-reject",
            stats.resolved, stats.total, pct
        ),
        _ => "resolved intra-repo edges unavailable (almanac not reachable) — treat \
              any non-REACHES verdict as a review signal, never an auto-reject"
            .to_string(),
    };

    if json_out {
        let obj = serde_json::json!({
            "gap": gap_id,
            "verdict": result.verdict.label(),
            "target": target,
            "changed_files": changed_files,
            "citations": result.citations,
            "reason": result.reason,
            "edges_resolved": stats.resolved,
            "edges_total": stats.total,
            "edges_available": stats.available,
            "caveat": caveat,
        });
        println!("{}", serde_json::to_string_pretty(&obj).unwrap_or_default());
    } else {
        println!("verify-reaches {gap_id}");
        println!("  verdict : {}", result.verdict.label());
        if let Some(t) = &target {
            println!("  target  : {t}");
        } else {
            println!("  target  : (none — gap names no source file)");
        }
        if !result.citations.is_empty() {
            println!("  cites   : {}", result.citations.join(", "));
        }
        println!("  why     : {}", result.reason);
        println!("  edges   : {caveat}");
    }

    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(items: &[&str]) -> HashSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    // AC5 / task test #1: the CREDIBLE-200 shape — a diff containing only an
    // added assert-true test file, against a gap naming a SOURCE target, must be
    // TEST-ONLY (NOT REACHES). Fails without the change.
    #[test]
    fn reachability_credible_200_shape_is_test_only() {
        let target = Some("src/improve.rs");
        let changed = vec!["tests/stub_assert_true_test.rs".to_string()];
        let connected = set(&[]);
        let c = classify(target, &changed, &connected);
        assert_eq!(
            c.verdict,
            Verdict::TestOnly,
            "assert-true test + source target must be TEST-ONLY, got {:?}: {}",
            c.verdict,
            c.reason
        );
        assert_ne!(c.verdict, Verdict::Reaches);
        assert!(c
            .citations
            .contains(&"tests/stub_assert_true_test.rs".to_string()));
    }

    // TEST-ONLY precedence: even when a test file *does* import the target, a
    // diff whose every file is a test is still TEST-ONLY — no source changed.
    #[test]
    fn reachability_all_tests_even_if_linked_is_test_only() {
        let target = Some("src/improve.rs");
        let changed = vec!["tests/improve_it_test.rs".to_string()];
        // Pretend almanac linked the test to the target.
        let connected = set(&["tests/improve_it_test.rs"]);
        let c = classify(target, &changed, &connected);
        assert_eq!(c.verdict, Verdict::TestOnly);
    }

    // AC2 / task test #2: gap AC mentions ONLY tests + no source target →
    // UNKNOWN(no-target). No false verdict is invented.
    #[test]
    fn reachability_no_source_target_is_unknown() {
        let changed = vec!["tests/some_new_test.rs".to_string()];
        let connected = set(&[]);
        let c = classify(None, &changed, &connected);
        assert_eq!(
            c.verdict,
            Verdict::Unknown,
            "no target must yield UNKNOWN, got {:?}",
            c.verdict
        );
        assert!(c.reason.contains("no-target"));
    }

    // The target extractor must return None when the gap text names only test
    // paths — that is what feeds the UNKNOWN(no-target) case above.
    #[test]
    fn reachability_extract_target_tests_only_is_none() {
        let text = "AC: add a test at `tests/foo_test.rs` and a fixture at \
                    tests/fixtures/bar.rs proving the behavior.";
        assert_eq!(extract_source_target(text), None);
    }

    // The target extractor picks the first NON-test source path.
    #[test]
    fn reachability_extract_target_picks_first_source_path() {
        let text = "Integration target of record: src/improve.rs — the external \
                    ship path. First slice: src/commands/reachability.rs.";
        assert_eq!(
            extract_source_target(text),
            Some("src/improve.rs".to_string())
        );
    }

    // AC4a: an almanac-linked changed source file → REACHES, with the file cited.
    #[test]
    fn reachability_linked_source_file_reaches_with_citation() {
        let target = Some("src/improve.rs");
        let changed = vec!["src/external_verify_merge.rs".to_string()];
        let connected = set(&["src/external_verify_merge.rs", "src/dashboard.rs"]);
        let c = classify(target, &changed, &connected);
        assert_eq!(c.verdict, Verdict::Reaches);
        assert!(
            c.citations
                .contains(&"src/external_verify_merge.rs".to_string()),
            "REACHES must cite the linking file"
        );
    }

    // AC4b: an UNLINKED changed source file (not a test, not connected) →
    // UNRELATED.
    #[test]
    fn reachability_unlinked_source_file_is_unrelated() {
        let target = Some("src/improve.rs");
        let changed = vec!["src/some_island_module.rs".to_string()];
        let connected = set(&["src/other.rs"]);
        let c = classify(target, &changed, &connected);
        assert_eq!(c.verdict, Verdict::Unrelated);
    }

    // The changed file that IS the target reaches it trivially (the AC3 live
    // case: diff lists src/improve.rs, target is src/improve.rs).
    #[test]
    fn reachability_changed_file_is_target_reaches() {
        let target = Some("src/improve.rs");
        let changed = vec!["src/improve.rs".to_string()];
        let connected = set(&[]);
        let c = classify(target, &changed, &connected);
        assert_eq!(c.verdict, Verdict::Reaches);
        assert!(c.citations.contains(&"src/improve.rs".to_string()));
    }

    // Empty diff → UNKNOWN, never a false verdict.
    #[test]
    fn reachability_empty_diff_is_unknown() {
        let c = classify(Some("src/improve.rs"), &[], &set(&[]));
        assert_eq!(c.verdict, Verdict::Unknown);
    }

    // Mixed diff (a source + a test) with the source linked → REACHES, not
    // TEST-ONLY (not all files are tests).
    #[test]
    fn reachability_mixed_source_and_test_reaches() {
        let target = Some("src/improve.rs");
        let changed = vec![
            "src/external_verify_merge.rs".to_string(),
            "tests/it_test.rs".to_string(),
        ];
        let connected = set(&["src/external_verify_merge.rs"]);
        let c = classify(target, &changed, &connected);
        assert_eq!(c.verdict, Verdict::Reaches);
    }

    // Suffix path matching: a bare-filename target still matches its full path.
    #[test]
    fn reachability_suffix_path_match() {
        assert!(paths_equal("src/improve.rs", "improve.rs"));
        assert!(paths_equal("improve.rs", "src/improve.rs"));
        assert!(!paths_equal("src/improve.rs", "src/improve2.rs"));
        assert!(!paths_equal("src/aimprove.rs", "improve.rs"));
    }

    #[test]
    fn reachability_verdict_labels_are_stable() {
        assert_eq!(Verdict::Reaches.label(), "REACHES");
        assert_eq!(Verdict::TestOnly.label(), "TEST-ONLY");
        assert_eq!(Verdict::Unrelated.label(), "UNRELATED");
        assert_eq!(Verdict::Unknown.label(), "UNKNOWN");
    }
}
