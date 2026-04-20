//! MEM-010 — Entity resolution accuracy test
//!
//! Tests the entity linker in memory_graph.rs against the 30-pair test set defined in
//! docs/eval/MEM-010-entity-resolution-test-set.yaml.
//!
//! The "linker" under test is the `clean_entity` normalization path: two surface
//! forms that normalize to the same string are considered linked; forms that
//! normalize to different strings are considered distinct entities.
//!
//! Acceptance gate: precision >= 0.85.
//! If precision < 0.85, the test logs a sub-gap recommendation (MEM-010a) and fails.
//!
//! Run:
//!   cargo test --test entity_resolution_accuracy -- --nocapture
//!
//! Part of the MEM-008 regression fixture set.

use serde::Deserialize;
use std::path::PathBuf;

// ── Test set schema ─────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct TestSet {
    pairs: Vec<EntityPair>,
}

#[derive(Debug, Deserialize)]
struct EntityPair {
    id: String,
    entity_a: String,
    entity_b: String,
    should_link: bool,
    reason: String,
}

// ── Entity normalization (mirrors memory_graph::clean_entity) ────────────────
//
// Must stay in sync with src/memory_graph.rs `clean_entity`. If that function
// changes, update this mirror and re-run the test set.

fn clean_entity(s: &str) -> String {
    let s = s.trim();
    let s = s.trim_start_matches(|c: char| !c.is_alphanumeric());
    let s = s.trim_end_matches(|c: char| !c.is_alphanumeric());
    let lower = s.to_lowercase();
    let lower = lower
        .trim_start_matches("the ")
        .trim_start_matches("a ")
        .trim_start_matches("an ");
    lower.to_string()
}

/// The linker decision: two surface forms are "linked" iff they normalize to
/// the same string via clean_entity.
fn entities_link(a: &str, b: &str) -> bool {
    clean_entity(a) == clean_entity(b)
}

// ── Load fixture ────────────────────────────────────────────────────────────

fn load_test_set() -> TestSet {
    // Locate the fixture relative to the workspace root.
    // CARGO_MANIFEST_DIR points to the crate root during tests.
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set when running cargo test");
    let fixture_path = PathBuf::from(&manifest_dir)
        .join("docs")
        .join("eval")
        .join("MEM-010-entity-resolution-test-set.yaml");

    let yaml_text = std::fs::read_to_string(&fixture_path).unwrap_or_else(|e| {
        panic!(
            "Could not read entity resolution fixture at {}: {}",
            fixture_path.display(),
            e
        )
    });

    serde_yaml::from_str(&yaml_text)
        .unwrap_or_else(|e| panic!("Failed to parse entity resolution fixture YAML: {}", e))
}

// ── Precision / recall calculation ──────────────────────────────────────────
//
// Framing:
//   - Positive class = "should link" (should_link: true)
//   - Negative class = "should not link" (should_link: false)
//
// For each pair, the linker emits a binary prediction (link / not-link).
//
//   TP = pair is should_link:true  AND linker says link
//   FP = pair is should_link:false AND linker says link  (false alarm)
//   FN = pair is should_link:true  AND linker says not-link (miss)
//   TN = pair is should_link:false AND linker says not-link
//
// precision = TP / (TP + FP)   — of all things the linker *calls* linked, how many truly are?
// recall    = TP / (TP + FN)   — of all things that truly should link, how many does the linker catch?

#[derive(Debug, Default)]
struct Metrics {
    tp: usize,
    fp: usize,
    fn_: usize,
    tn: usize,
}

impl Metrics {
    fn precision(&self) -> f64 {
        let denom = self.tp + self.fp;
        if denom == 0 {
            1.0 // vacuously precise when nothing is predicted positive
        } else {
            self.tp as f64 / denom as f64
        }
    }

    fn recall(&self) -> f64 {
        let denom = self.tp + self.fn_;
        if denom == 0 {
            1.0 // vacuously recalls everything when there are no positives
        } else {
            self.tp as f64 / denom as f64
        }
    }

    fn f1(&self) -> f64 {
        let p = self.precision();
        let r = self.recall();
        if p + r == 0.0 {
            0.0
        } else {
            2.0 * p * r / (p + r)
        }
    }

    fn total(&self) -> usize {
        self.tp + self.fp + self.fn_ + self.tn
    }

    fn correct(&self) -> usize {
        self.tp + self.tn
    }

    fn accuracy(&self) -> f64 {
        if self.total() == 0 {
            0.0
        } else {
            self.correct() as f64 / self.total() as f64
        }
    }
}

// ── Main test ────────────────────────────────────────────────────────────────

#[test]
fn entity_resolution_precision_recall() {
    let test_set = load_test_set();
    assert!(
        !test_set.pairs.is_empty(),
        "Test set must not be empty — check docs/eval/MEM-010-entity-resolution-test-set.yaml"
    );

    let mut metrics = Metrics::default();
    let mut failures: Vec<String> = Vec::new();

    for pair in &test_set.pairs {
        let predicted_link = entities_link(&pair.entity_a, &pair.entity_b);
        let a_norm = clean_entity(&pair.entity_a);
        let b_norm = clean_entity(&pair.entity_b);

        match (pair.should_link, predicted_link) {
            (true, true) => metrics.tp += 1,
            (false, true) => {
                metrics.fp += 1;
                failures.push(format!(
                    "  [FALSE POSITIVE] {} — predicted LINK, expected NOT-LINK\n    \
                     a={:?} -> {:?}\n    b={:?} -> {:?}\n    reason: {}",
                    pair.id,
                    pair.entity_a,
                    a_norm,
                    pair.entity_b,
                    b_norm,
                    pair.reason.trim()
                ));
            }
            (true, false) => {
                metrics.fn_ += 1;
                failures.push(format!(
                    "  [FALSE NEGATIVE] {} — predicted NOT-LINK, expected LINK\n    \
                     a={:?} -> {:?}\n    b={:?} -> {:?}\n    reason: {}",
                    pair.id,
                    pair.entity_a,
                    a_norm,
                    pair.entity_b,
                    b_norm,
                    pair.reason.trim()
                ));
            }
            (false, false) => metrics.tn += 1,
        }
    }

    // ── Report ───────────────────────────────────────────────────────────────

    println!("\n=== MEM-010 Entity Resolution Accuracy ===");
    println!(
        "Test set: {} pairs ({} should-link, {} should-not-link)",
        metrics.total(),
        metrics.tp + metrics.fn_,
        metrics.fp + metrics.tn
    );
    println!(
        "Correct predictions: {}/{}",
        metrics.correct(),
        metrics.total()
    );
    println!();
    println!(
        "TP={} FP={} FN={} TN={}",
        metrics.tp, metrics.fp, metrics.fn_, metrics.tn
    );
    println!("Precision : {:.3}", metrics.precision());
    println!("Recall    : {:.3}", metrics.recall());
    println!("F1        : {:.3}", metrics.f1());
    println!("Accuracy  : {:.3}", metrics.accuracy());

    if !failures.is_empty() {
        println!("\n--- Misclassifications ({}) ---", failures.len());
        for f in &failures {
            println!("{f}");
        }
    }

    // ── Acceptance gate ──────────────────────────────────────────────────────

    let precision = metrics.precision();
    let recall = metrics.recall();

    if precision < 0.85 {
        println!(
            "\n[MEM-010 RECOMMENDATION] precision={:.3} < 0.85 threshold.",
            precision
        );
        println!("  -> File sub-gap MEM-010a: 'context disambiguation for entity linker'.");
        println!("  -> Root cause: clean_entity normalization cannot resolve cross-form aliases");
        println!("     (e.g. underscore vs space, nickname vs formal name).");
        println!(
            "  -> Suggested fix: add fuzzy normalization (edit distance ≤2 or token-set overlap)"
        );
        println!("     in a new `entity_link` function that wraps clean_entity.");

        // Write sub-gap recommendation to a file for the gaps.yaml gardener
        let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
        let rec_path =
            PathBuf::from(&manifest_dir).join("docs/eval/MEM-010-subgap-recommendation.txt");
        let _ = std::fs::write(
            &rec_path,
            format!(
                "MEM-010a recommendation (auto-generated by entity_resolution_accuracy test)\n\
                 \n\
                 precision={:.3} recall={:.3} (measured on 30-pair test set)\n\
                 \n\
                 Proposed sub-gap: MEM-010a\n\
                 Title: context disambiguation for entity linker\n\
                 Description: precision < 0.85 on the MEM-010 entity resolution test set.\n\
                 The clean_entity normalizer resolves case and leading articles but cannot\n\
                 link underscore-form vs space-form identifiers, or informal nicknames to\n\
                 formal names. Add fuzzy normalization (token-set overlap or edit distance)\n\
                 to the entity linker to close the gap.\n\
                 Priority: P2\n\
                 Effort: s\n",
                precision, recall,
            ),
        );

        panic!(
            "MEM-010: entity resolution precision {:.3} < 0.85 — sub-gap MEM-010a needed. \
             See docs/eval/MEM-010-subgap-recommendation.txt",
            precision
        );
    }

    println!(
        "\n[MEM-010 PASS] precision={:.3} >= 0.85, recall={:.3}",
        precision, recall
    );
}

// ── Regression guard (subset check) ─────────────────────────────────────────
//
// Quick smoke test: run clean_entity on a few canonical pairs to catch
// regressions if the normalization logic in memory_graph.rs is changed.

#[test]
fn clean_entity_normalization_regression() {
    // pairs: (input, expected_normalized)
    let cases: &[(&str, &str)] = &[
        ("Alice Nguyen", "alice nguyen"),
        ("the parser team", "parser team"),
        ("The Parser Team", "parser team"),
        ("an infra-oncall rotation", "infra-oncall rotation"),
        ("A SQLite backend", "sqlite backend"),
        ("ChumpCore", "chumpcore"),
        ("chump-heartbeat", "chump-heartbeat"),
        ("MEM-006", "mem-006"),
        ("infra-merge-queue", "infra-merge-queue"),
        ("  The Rust Dispatcher  ", "rust dispatcher"),
        ("the merge queue", "merge queue"),
        ("PR #52", "pr #52"),
    ];

    for (input, expected) in cases {
        let got = clean_entity(input);
        assert_eq!(
            &got, expected,
            "clean_entity({:?}) = {:?}, want {:?}",
            input, got, expected
        );
    }
}

// ── Known-limitation documentation test ──────────────────────────────────────
//
// Documents the cases where the current linker is KNOWN to fall short.
// These tests do NOT fail the suite — they are marked #[ignore] and exist to
// make the limitation visible in the test output.
//
// When MEM-010a ships (fuzzy normalization), flip these to regular #[test]
// and remove the #[ignore].

#[test]
#[ignore = "MEM-010a: underscore vs space not resolved by current clean_entity — file MEM-010a to fix"]
fn known_limitation_underscore_vs_space() {
    // "memory_db" and "memory db" refer to the same module but clean_entity
    // cannot resolve this without fuzzy matching.
    assert_eq!(
        clean_entity("memory_db"),
        clean_entity("memory db"),
        "MEM-010a: expected underscore and space forms to link after fuzzy normalization"
    );
}

#[test]
#[ignore = "MEM-010a: nickname vs formal name not resolved without semantic lookup"]
fn known_limitation_nickname_vs_formal() {
    // "the watcher" -> "watcher" and "chump-heartbeat" are the same service
    // but require semantic knowledge (not just string normalization) to link.
    assert_eq!(
        clean_entity("the watcher"),
        clean_entity("chump-heartbeat"),
        "MEM-010a: expected nickname 'watcher' to link to formal name 'chump-heartbeat' \
         after semantic entity resolution"
    );
}
