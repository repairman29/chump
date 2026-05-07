//! INFRA-647: Failure-mode catalog reader.
//!
//! Loads `docs/process/FAILURE_MODES.yaml` and matches a job name / log text
//! against the catalog to produce a structured classification decision.
//!
//! ## CLI
//!
//! `chump classify-failure [--job NAME] [--log FILE|-] [--json]`
//!
//! Outputs the best-matching catalog entry (or a fallback classification when
//! no entry matches) as JSON so `pr-triage-bot.yml` can read it with `jq`.
//!
//! ## Programmatic API
//!
//! ```ignore
//! let catalog = FailureCatalog::load(Path::new("docs/process/FAILURE_MODES.yaml"))?;
//! if let Some(m) = catalog.classify(job_name, log_text) {
//!     println!("{} → {} / {}", m.id, m.classification, m.auto_action);
//! }
//! ```

use std::io::Read as _;
use std::path::Path;

use serde::Deserialize;

// ── YAML schema ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct CatalogFile {
    #[allow(dead_code)]
    version: u32,
    failures: Vec<CatalogEntry>,
}

#[derive(Debug, Deserialize, Clone)]
struct CatalogEntry {
    id: String,
    pattern: String,
    #[serde(default = "default_match_on")]
    match_on: String,
    classification: String,
    auto_action: String,
    confidence: f64,
    #[serde(default)]
    examples: Vec<String>,
    #[serde(default)]
    notes: Option<String>,
}

fn default_match_on() -> String {
    "either".to_string()
}

// ── Public types ──────────────────────────────────────────────────────────────

/// A resolved catalog match.
#[derive(Debug, Clone)]
pub struct CatalogMatch {
    pub id: String,
    pub classification: String,
    pub auto_action: String,
    pub confidence: f64,
    pub examples: Vec<String>,
    pub notes: Option<String>,
}

impl CatalogMatch {
    fn to_json(&self) -> String {
        let examples_json: Vec<String> = self
            .examples
            .iter()
            .map(|e| format!(r#""{}""#, json_escape(e)))
            .collect();
        let notes_json = match &self.notes {
            Some(n) => format!(r#""{}""#, json_escape(n)),
            None => "null".to_string(),
        };
        format!(
            r#"{{"id":"{}","classification":"{}","auto_action":"{}","confidence":{},"examples":[{}],"notes":{}}}"#,
            json_escape(&self.id),
            json_escape(&self.classification),
            json_escape(&self.auto_action),
            self.confidence,
            examples_json.join(","),
            notes_json,
        )
    }
}

/// Loaded and compiled failure catalog.
pub struct FailureCatalog {
    entries: Vec<(CatalogEntry, regex::Regex)>,
}

impl FailureCatalog {
    /// Load catalog from YAML file. Returns an empty catalog on parse failure
    /// so callers degrade gracefully rather than crashing.
    pub fn load(path: &Path) -> Self {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("failure_catalog: cannot read {}: {}", path.display(), e);
                return Self {
                    entries: Vec::new(),
                };
            }
        };
        let file: CatalogFile = match serde_yaml::from_str(&text) {
            Ok(f) => f,
            Err(e) => {
                eprintln!(
                    "failure_catalog: YAML parse error in {}: {}",
                    path.display(),
                    e
                );
                return Self {
                    entries: Vec::new(),
                };
            }
        };
        let mut entries = Vec::new();
        for entry in file.failures {
            match regex::Regex::new(&entry.pattern) {
                Ok(re) => entries.push((entry, re)),
                Err(e) => {
                    eprintln!("failure_catalog: bad regex in entry '{}': {}", entry.id, e);
                }
            }
        }
        Self { entries }
    }

    /// Classify a failure given an optional job name and optional log text.
    /// Returns the highest-confidence matching entry, or `None` when no entry
    /// matches (caller should fall back to heuristic classification).
    pub fn classify(&self, job_name: &str, log: &str) -> Option<CatalogMatch> {
        let mut best: Option<(f64, CatalogMatch)> = None;
        for (entry, re) in &self.entries {
            let matched = match entry.match_on.as_str() {
                "job_name" => re.is_match(job_name),
                "log" => re.is_match(log),
                _ => re.is_match(job_name) || re.is_match(log),
            };
            if matched {
                let score = entry.confidence;
                if best
                    .as_ref()
                    .is_none_or(|(best_score, _)| score > *best_score)
                {
                    best = Some((
                        score,
                        CatalogMatch {
                            id: entry.id.clone(),
                            classification: entry.classification.clone(),
                            auto_action: entry.auto_action.clone(),
                            confidence: entry.confidence,
                            examples: entry.examples.clone(),
                            notes: entry.notes.clone(),
                        },
                    ));
                }
            }
        }
        best.map(|(_, m)| m)
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

// ── CLI entry point ──────────────────────────────────────────────────────────

/// `chump classify-failure [--job NAME] [--log FILE|-] [--json]`
///
/// Prints the best-matching catalog entry as JSON. Always exits 0 so the
/// workflow step never fails on a classification miss (returns fallback JSON).
pub fn run_classify(args: &[String]) {
    let flag = |name: &str| -> Option<String> {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };

    let job_name = flag("--job").unwrap_or_default();
    let log_file = flag("--log");
    let want_json = args.iter().any(|a| a == "--json");

    let log_text: String = match log_file.as_deref() {
        None => String::new(),
        Some("-") => {
            let mut s = String::new();
            let _ = std::io::stdin().read_to_string(&mut s);
            s
        }
        Some(path) => std::fs::read_to_string(path).unwrap_or_default(),
    };

    let catalog_path = catalog_yaml_path();
    let catalog = FailureCatalog::load(&catalog_path);
    if catalog.is_empty() && !catalog_path.exists() {
        eprintln!(
            "classify-failure: catalog not found at {} — using empty catalog",
            catalog_path.display()
        );
    }

    let result = catalog.classify(&job_name, &log_text).unwrap_or_else(|| {
        // Fallback: ci_summary heuristic → translate to catalog shape.
        let classification = ci_summary_fallback(&job_name, &log_text);
        let auto_action = match classification {
            "lint" => "fix",
            "flake" => "rerun",
            "infra-broken" => "escalate",
            "test-coupling" | "real-bug" => "file_gap",
            _ => "file_gap",
        };
        CatalogMatch {
            id: "fallback-heuristic".to_string(),
            classification: classification.to_string(),
            auto_action: auto_action.to_string(),
            confidence: 0.5,
            examples: Vec::new(),
            notes: Some("no catalog entry matched; used ci_summary heuristic".to_string()),
        }
    });

    if want_json {
        println!("{}", result.to_json());
    } else {
        println!(
            "id={} class={} action={} confidence={:.2}",
            result.id, result.classification, result.auto_action, result.confidence
        );
    }
}

// ── Path helper ──────────────────────────────────────────────────────────────

fn catalog_yaml_path() -> std::path::PathBuf {
    // Prefer repo-relative path so the binary works from any worktree.
    let candidates = [
        std::path::PathBuf::from("docs/process/FAILURE_MODES.yaml"),
        crate::repo_path::repo_root().join("docs/process/FAILURE_MODES.yaml"),
    ];
    for c in &candidates {
        if c.exists() {
            return c.clone();
        }
    }
    candidates[1].clone()
}

// ── Fallback: mirror ci_summary.rs heuristics ────────────────────────────────

fn ci_summary_fallback<'a>(job_name: &str, log: &str) -> &'a str {
    let lower_log = log.to_lowercase();
    let lower_job = job_name.to_lowercase();
    if lower_job == "clippy" || lower_job == "fmt" {
        return "lint";
    }
    if lower_log.contains("no space left on device")
        || lower_log.contains("rustup: error")
        || lower_log.contains("runner has received a shutdown signal")
        || lower_log.contains("rate limit exceeded")
        || lower_log.contains("tls handshake timeout")
    {
        return "infra-broken";
    }
    if lower_log.contains("snapshot mismatch")
        || lower_log.contains("snapshot differs")
        || lower_log.contains(".snap")
        || lower_log.contains("golden file")
    {
        return "test-coupling";
    }
    if lower_log.contains("econnreset")
        || lower_log.contains("signal: killed")
        || lower_log.contains("oom killer")
        || lower_log.contains("operation timed out")
    {
        return "flake";
    }
    "real-bug"
}

// ── JSON helper ──────────────────────────────────────────────────────────────

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c => out.push(c),
        }
    }
    out
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn test_catalog() -> FailureCatalog {
        let yaml = r#"
version: 1
failures:
  - id: fmt_fail
    pattern: "^fmt$"
    match_on: job_name
    classification: lint
    auto_action: fix
    confidence: 1.0
    examples: ["cargo fmt check"]
  - id: snapshot_mismatch
    pattern: "(?i)snapshot mismatch"
    match_on: log
    classification: test-coupling
    auto_action: file_gap
    confidence: 0.92
    examples: ["insta snapshot diff"]
  - id: runner_oom
    pattern: "(?i)signal: killed"
    match_on: log
    classification: flake
    auto_action: rerun
    confidence: 0.82
    examples: ["OOM kill"]
  - id: disk_full
    pattern: "(?i)no space left on device"
    match_on: log
    classification: infra-broken
    auto_action: escalate
    confidence: 0.99
    examples: ["disk full on runner"]
"#;
        let tmpf =
            std::env::temp_dir().join(format!("failure_catalog_test_{}.yaml", std::process::id()));
        std::fs::write(&tmpf, yaml).unwrap();
        let cat = FailureCatalog::load(&tmpf);
        let _ = std::fs::remove_file(&tmpf);
        cat
    }

    #[test]
    fn infra647_classify_fmt_by_job_name() {
        let cat = test_catalog();
        let m = cat.classify("fmt", "").unwrap();
        assert_eq!(m.id, "fmt_fail");
        assert_eq!(m.classification, "lint");
        assert_eq!(m.auto_action, "fix");
        assert!((m.confidence - 1.0).abs() < 1e-9);
    }

    #[test]
    fn infra647_classify_snapshot_mismatch() {
        let cat = test_catalog();
        let m = cat
            .classify("cargo-test", "FAILED: snapshot mismatch for render.snap")
            .unwrap();
        assert_eq!(m.id, "snapshot_mismatch");
        assert_eq!(m.classification, "test-coupling");
    }

    #[test]
    fn infra647_classify_flake_oom() {
        let cat = test_catalog();
        let m = cat
            .classify("cargo-test", "signal: killed\ncargo build failed")
            .unwrap();
        assert_eq!(m.id, "runner_oom");
        assert_eq!(m.auto_action, "rerun");
    }

    #[test]
    fn infra647_classify_infra_broken() {
        let cat = test_catalog();
        let m = cat
            .classify("cargo-test", "error: No space left on device (os error 28)")
            .unwrap();
        assert_eq!(m.id, "disk_full");
        assert_eq!(m.classification, "infra-broken");
        assert_eq!(m.auto_action, "escalate");
    }

    #[test]
    fn infra647_classify_no_match_returns_none() {
        let cat = test_catalog();
        let m = cat.classify("some-job", "some unrelated log text");
        // Should return None — caller applies fallback.
        assert!(m.is_none());
    }

    #[test]
    fn infra647_highest_confidence_wins() {
        // disk_full (0.99) should beat runner_oom (0.82) when both match.
        let cat = test_catalog();
        let log = "signal: killed\nNo space left on device";
        let m = cat.classify("cargo-test", log).unwrap();
        assert_eq!(m.id, "disk_full", "higher confidence entry should win");
    }

    #[test]
    fn infra647_fallback_heuristic_lint() {
        assert_eq!(ci_summary_fallback("fmt", ""), "lint");
        assert_eq!(ci_summary_fallback("clippy", ""), "lint");
    }

    #[test]
    fn infra647_fallback_heuristic_infra() {
        let log = "error: No space left on device (os error 28)";
        assert_eq!(ci_summary_fallback("cargo-test", log), "infra-broken");
    }

    #[test]
    fn infra647_to_json_valid() {
        let m = CatalogMatch {
            id: "fmt_fail".to_string(),
            classification: "lint".to_string(),
            auto_action: "fix".to_string(),
            confidence: 1.0,
            examples: vec!["cargo fmt".to_string()],
            notes: None,
        };
        let json = m.to_json();
        assert!(json.contains(r#""id":"fmt_fail""#));
        assert!(json.contains(r#""classification":"lint""#));
        assert!(json.contains(r#""auto_action":"fix""#));
        assert!(json.contains(r#""confidence":1"#));
    }

    #[test]
    fn infra647_empty_catalog_on_bad_path() {
        let cat = FailureCatalog::load(Path::new("/nonexistent/FAILURE_MODES.yaml"));
        assert!(cat.is_empty());
    }

    #[test]
    fn infra647_catalog_len_matches_entries() {
        let cat = test_catalog();
        assert_eq!(cat.len(), 4);
    }
}
