//! INFRA-1765 — cross-agent CI-failure lesson propagation.
//!
//! Turns a CI failure (a failing check on a PR) into a structured
//! [`reflection::Reflection`] persisted in the same `chump_reflections` /
//! `chump_improvement_targets` tables (`memory_db`) that agent
//! self-reflection already writes to. Because `briefing::build_briefing`
//! (MEM-007) already reads `reflection_db::load_spawn_lessons` by domain,
//! any lesson captured here is automatically surfaced in the *next*
//! session's briefing for that domain — no separate injection path needed.
//!
//! Failure text is classified into a small taxonomy (transient vs.
//! permanent vs. unknown) so downstream consumers (briefing readers,
//! dashboards) can tell "retry it" apart from "fix the code."
//!
//! Observability (INFRA-1765 AC):
//! - Events: `ci_lesson_captured` (success) / `ci_lesson_capture_failed`
//!   (DB write failed), emitted here to `.chump-locks/ambient.jsonl`. The
//!   `scripts/coord/ci-lesson-propagation.sh` wrapper additionally emits
//!   `ci_lesson_capture_timeout` when it wraps this binary in `timeout
//!   $CAPTURE_TIMEOUT_SECS` and the process itself wedges — see
//!   [`CAPTURE_TIMEOUT_SECS`].
//! - Cost: this path is pure heuristic pattern-matching, no LLM call, so
//!   `cost_usd` is always `0.0` in every emitted event — makes the "$0"
//!   claim auditable rather than just documented.
//! - Failure-class taxonomy: see [`CiFailureClass`].
//! - Smoke test: `scripts/ci/test-ci-lesson-propagation.sh`.

use crate::reflection::{ErrorPattern, ImprovementTarget, OutcomeClass, Priority, Reflection};
use crate::reflection_db;
use std::path::Path;

/// Recommended `timeout <N>` budget (seconds) for the shell wrapper
/// (`scripts/coord/ci-lesson-propagation.sh`) invoking `chump ci-lesson
/// capture`. This call is one heuristic classify + one sqlite insert, so 10s
/// is generous headroom, not an expected duration.
pub const CAPTURE_TIMEOUT_SECS: u64 = 10;

/// Coarse CI-failure taxonomy — the whole point of capturing the lesson is
/// to tell an agent (or a human) whether re-running is worth trying.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CiFailureClass {
    /// Environmental / infra flake — network blip, runner OOM, timeout,
    /// rate limit. Re-running the same code is likely to pass.
    Transient,
    /// A real defect in the diff — compile error, clippy lint, failing
    /// assertion. Re-running will not help; the code must change.
    Permanent,
    /// Didn't match any known pattern — surfaced as-is rather than guessed.
    Unknown,
}

impl CiFailureClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Transient => "transient",
            Self::Permanent => "permanent",
            Self::Unknown => "unknown",
        }
    }
}

/// Classify raw CI failure output (log tail, error message) into a
/// [`CiFailureClass`] via keyword matching. Deliberately conservative:
/// only claims `Permanent` or `Transient` on a recognizable signal, else
/// `Unknown` — a wrong "transient" verdict wastes a retry, a wrong
/// "permanent" verdict wastes a debugging session, so unclassified stays
/// unclassified rather than guessing.
pub fn classify_ci_failure(failure_text: &str) -> CiFailureClass {
    let lower = failure_text.to_lowercase();

    const TRANSIENT_MARKERS: &[&str] = &[
        "connection reset",
        "connection refused",
        "timed out",
        "timeout",
        "temporary failure in name resolution",
        "could not resolve host",
        "network is unreachable",
        "rate limit",
        "429 too many requests",
        "runner has received a shutdown signal",
        "no space left on device",
        "out of memory",
        "oom-killed",
        "flaky",
        "flake",
        "econnreset",
        "the operation was canceled",
        "502 bad gateway",
        "503 service unavailable",
    ];
    const PERMANENT_MARKERS: &[&str] = &[
        "error[e",  // rustc error codes
        "clippy::", // clippy lint
        "assertion failed",
        "assertion `left",
        "test result: failed",
        "panicked at",
        "expected `",
        "mismatched types",
        "cannot find",
        "unresolved import",
        "syntax error",
        "compilation failed",
        "undefined reference",
    ];

    if TRANSIENT_MARKERS.iter().any(|m| lower.contains(m)) {
        return CiFailureClass::Transient;
    }
    if PERMANENT_MARKERS.iter().any(|m| lower.contains(m)) {
        return CiFailureClass::Permanent;
    }
    CiFailureClass::Unknown
}

/// Result of a successful capture, returned to the caller for logging/tests.
#[derive(Debug, Clone)]
pub struct CaptureResult {
    pub reflection_id: i64,
    pub class: CiFailureClass,
}

/// Build the reflection + improvement target for a CI failure and persist it
/// to `memory_db`, then emit the matching ambient event
/// (`ci_lesson_captured` on success, `ci_lesson_capture_failed` on a DB
/// error). This call is a single heuristic classify + one sqlite insert —
/// no network I/O — so it runs synchronously; the caller (the
/// `scripts/coord/ci-lesson-propagation.sh` wrapper) is responsible for the
/// [`CAPTURE_TIMEOUT_SECS`]-bounded `timeout(1)` wrapper that emits
/// `ci_lesson_capture_timeout` if this process itself wedges.
pub fn capture_ci_lesson(
    repo_root: &Path,
    domain: &str,
    check_name: &str,
    pr_ref: &str,
    failure_text: &str,
) -> Result<CaptureResult, String> {
    match capture_ci_lesson_inner(domain, check_name, pr_ref, failure_text) {
        Ok(res) => {
            // scanner-anchor: "kind":"ci_lesson_captured"
            emit_ambient_event(
                repo_root,
                "ci_lesson_captured",
                &[
                    ("check", check_name),
                    ("pr_ref", pr_ref),
                    ("domain", domain),
                    ("class", res.class.as_str()),
                    ("reflection_id", &res.reflection_id.to_string()),
                    ("cost_usd", "0.0"),
                ],
            );
            Ok(res)
        }
        Err(reason) => {
            // scanner-anchor: "kind":"ci_lesson_capture_failed"
            emit_ambient_event(
                repo_root,
                "ci_lesson_capture_failed",
                &[
                    ("check", check_name),
                    ("pr_ref", pr_ref),
                    ("reason", &reason),
                    ("cost_usd", "0.0"),
                ],
            );
            Err(reason)
        }
    }
}

fn capture_ci_lesson_inner(
    domain: &str,
    check_name: &str,
    pr_ref: &str,
    failure_text: &str,
) -> Result<CaptureResult, String> {
    let class = classify_ci_failure(failure_text);
    let error_pattern = match class {
        CiFailureClass::Transient => ErrorPattern::ExternalFailure,
        CiFailureClass::Permanent => ErrorPattern::ToolFailure,
        CiFailureClass::Unknown => ErrorPattern::Other,
    };

    let directive = match class {
        CiFailureClass::Transient => format!(
            "CI check '{check_name}' failed with a transient signal — retry before debugging \
             (last seen on {pr_ref})"
        ),
        CiFailureClass::Permanent => format!(
            "CI check '{check_name}' failed with a real defect signal — fix the diff, don't \
             retry (last seen on {pr_ref})"
        ),
        CiFailureClass::Unknown => format!(
            "CI check '{check_name}' failed with an unrecognized pattern — inspect the log \
             before assuming retry-safe (last seen on {pr_ref})"
        ),
    };

    let truncated: String = failure_text.chars().take(500).collect();
    let reflection = Reflection {
        id: None,
        episode_id: None,
        intended_goal: format!("Land a PR passing CI check '{check_name}'"),
        observed_outcome: format!("CI check '{check_name}' failed: {truncated}"),
        outcome_class: OutcomeClass::Failure,
        error_pattern: Some(error_pattern),
        improvements: vec![ImprovementTarget {
            directive,
            priority: match class {
                CiFailureClass::Permanent => Priority::High,
                CiFailureClass::Transient => Priority::Medium,
                CiFailureClass::Unknown => Priority::Low,
            },
            scope: if domain.trim().is_empty() {
                None
            } else {
                Some(domain.trim().to_lowercase())
            },
            actioned_as: None,
        }],
        hypothesis: format!(
            "{}classified as {} via keyword heuristic",
            reflection_db::CI_LESSON_HYPOTHESIS_MARKER,
            class.as_str()
        ),
        surprisal_at_reflect: None,
        confidence_at_reflect: None,
        created_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    };

    reflection_db::save_reflection(&reflection, None)
        .map(|reflection_id| CaptureResult {
            reflection_id,
            class,
        })
        .map_err(|e| format!("save_reflection failed: {e}"))
}

/// Append a structured event to `ambient.jsonl` for fleet observability,
/// mirroring the established per-module `emit_ambient_event` pattern (see
/// `src/orchestrate.rs`). Drops empty-value fields so callers can pass a
/// fixed-shape slice without conditionally omitting keys.
fn emit_ambient_event(repo_root: &Path, kind: &str, fields: &[(&str, &str)]) {
    let ambient = if let Ok(path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        Path::new(&path).to_path_buf()
    } else {
        let lock_dir = repo_root.join(".chump-locks");
        let _ = std::fs::create_dir_all(&lock_dir);
        lock_dir.join("ambient.jsonl")
    };
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut map = serde_json::Map::new();
    map.insert("ts".into(), serde_json::Value::String(ts));
    map.insert("kind".into(), serde_json::Value::String(kind.into()));
    for (k, v) in fields {
        if v.is_empty() {
            continue;
        }
        map.insert((*k).into(), serde_json::Value::String((*v).into()));
    }
    let event = serde_json::Value::Object(map).to_string();
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{event}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_transient_markers() {
        assert_eq!(
            classify_ci_failure("Error: connection reset by peer during fetch"),
            CiFailureClass::Transient
        );
        assert_eq!(
            classify_ci_failure("curl: (28) Operation timed out after 30000 milliseconds"),
            CiFailureClass::Transient
        );
    }

    #[test]
    fn classifies_permanent_markers() {
        assert_eq!(
            classify_ci_failure("error[E0308]: mismatched types"),
            CiFailureClass::Permanent
        );
        assert_eq!(
            classify_ci_failure("thread 'main' panicked at 'assertion failed: x == y'"),
            CiFailureClass::Permanent
        );
    }

    #[test]
    fn classifies_unknown_when_no_marker_matches() {
        assert_eq!(
            classify_ci_failure("something vague happened"),
            CiFailureClass::Unknown
        );
    }

    #[test]
    #[serial_test::serial(reflection_db)]
    fn capture_writes_reflection_and_scopes_by_domain() {
        let tmp = tempfile::tempdir().unwrap();
        reflection_db::set_test_db_root(Some(tmp.path().to_path_buf()));
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path()
                .join("ambient.jsonl")
                .to_string_lossy()
                .to_string(),
        );

        let res = capture_ci_lesson(
            tmp.path(),
            "infra",
            "fast-checks",
            "PR#1234",
            "error[E0308]: mismatched types, expected `String`, found `&str`",
        )
        .expect("capture should succeed");
        assert_eq!(res.class, CiFailureClass::Permanent);

        let lessons = reflection_db::load_ci_lessons("infra", 5);
        assert!(
            lessons.iter().any(|l| l.directive.contains("fast-checks")),
            "expected captured lesson to be loadable via load_ci_lessons, got {lessons:?}"
        );

        let ambient_path = tmp.path().join("ambient.jsonl");
        let contents = std::fs::read_to_string(&ambient_path).unwrap_or_default();
        assert!(contents.contains("\"kind\":\"ci_lesson_captured\""));

        std::env::remove_var("CHUMP_AMBIENT_IN_PROMPT");
        reflection_db::set_test_db_root(None);
    }
}
