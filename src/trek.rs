//! INFRA-3656 (RIBBON-01): `chump trek "<plain job>"` — the auto-execute
//! Trek entrypoint. Point at a job, walk away, outcome lands.
//!
//! `chump start` (src/main.rs, EFFECTIVE-330) classifies a plain-language ask
//! via [`crate::front_door`] but is print-and-confirm-only by design — it
//! never dispatches. `trek` reuses that same classifier and then ACTUALLY
//! invokes the routed engine in-process:
//!
//!   CREATE    -> `crate::commands::bootstrap::run`
//!   IMPROVE   -> `crate::commands::swe::run` (claim -> dispatch -> auto-merge)
//!   INGEST    -> `crate::ingest::run`
//!   RESCUE / COMPREHEND -> diagnosis-only, no engine to land an outcome with;
//!                          trek refuses honestly rather than faking success.
//!
//! The engine call is behind the [`EngineSpawner`] trait so tests can drive
//! the classify -> spawn decision without actually shelling out / mutating
//! the gap registry.

use crate::front_door::{self, FrontDoorMode, RouteResult};
use std::path::Path;

/// Exit code trek uses when a route was classified but nothing was landed —
/// ambiguous asks, diagnosis-only routes, and refused (no `--yes`) confident
/// routes all use this so callers can distinguish "no Trek outcome" from a
/// real engine failure exit code.
pub const NO_OUTCOME_EXIT: i32 = 2;

/// Abstraction over "run the engine for this mode against this job text".
/// Production uses [`RealEngineSpawner`]; tests substitute a fake that
/// records the call instead of actually dispatching.
pub trait EngineSpawner {
    fn spawn(&self, mode: FrontDoorMode, job: &str) -> i32;
}

/// The real spawner: calls each engine's existing `run(&[String]) -> i32`
/// entry point in-process, exactly as `main()` would for the equivalent
/// direct command.
pub struct RealEngineSpawner;

impl EngineSpawner for RealEngineSpawner {
    fn spawn(&self, mode: FrontDoorMode, job: &str) -> i32 {
        match mode {
            FrontDoorMode::Create => {
                crate::commands::bootstrap::run(&["bootstrap".to_string(), job.to_string()])
            }
            FrontDoorMode::Improve => {
                crate::commands::swe::run(&["swe".to_string(), job.to_string()])
            }
            FrontDoorMode::Ingest => crate::ingest::run(&[job.to_string()]),
            FrontDoorMode::Rescue | FrontDoorMode::Comprehend => {
                // No landing engine exists for these modes (diagnosis-only,
                // per front_door::FrontDoorMode's own doc comment). Callers
                // of `spawn` must not reach here — `run_trek` short-circuits
                // diagnosis-only modes before ever calling the spawner.
                unreachable!("diagnosis-only modes must not be spawned")
            }
        }
    }
}

/// Ambient event kinds. Registered as scanner anchors so the
/// register-without-emit gate sees the literal strings even though the
/// actual emit call below builds them via a match, not a literal.
///
/// # scanner-anchor: "kind":"trek_start"
/// # scanner-anchor: "kind":"trek_outcome"
fn emit_trek_event(repo_root: &Path, kind: &str, fields: serde_json::Value) {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let Some(parent) = ambient_path.parent() else {
        return;
    };
    if !parent.exists() {
        return;
    }
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let mut event = serde_json::json!({ "ts": ts, "kind": kind });
    if let (Some(obj), Some(extra)) = (event.as_object_mut(), fields.as_object()) {
        for (k, v) in extra {
            obj.insert(k.clone(), v.clone());
        }
    }
    if let Ok(mut line) = serde_json::to_string(&event) {
        line.push('\n');
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient_path)
            .and_then(|mut f| {
                use std::io::Write;
                f.write_all(line.as_bytes())
            });
    }
}

/// Result of a `chump trek` run — mirrors the exit-code contract but keeps
/// the reason machine-readable for `--json` / tests.
#[derive(Debug, PartialEq, Eq)]
pub enum TrekOutcome {
    /// Engine ran; carries its exit code (0 = success, nonzero = engine failure).
    Landed { mode: &'static str, exit_code: i32 },
    /// Route was confident but `--yes` wasn't passed — refused, asked.
    NeedsConfirmation { question: String },
    /// Route was ambiguous — refused, asked.
    Ambiguous { question: String },
    /// Route was confident but diagnosis-only (Rescue/Comprehend) — no
    /// engine exists to land an outcome. Honest non-zero, not false success.
    DiagnosisOnly { mode: &'static str, message: String },
}

impl TrekOutcome {
    pub fn exit_code(&self) -> i32 {
        match self {
            TrekOutcome::Landed { exit_code, .. } => *exit_code,
            TrekOutcome::NeedsConfirmation { .. }
            | TrekOutcome::Ambiguous { .. }
            | TrekOutcome::DiagnosisOnly { .. } => NO_OUTCOME_EXIT,
        }
    }
}

/// Drive the classify -> (confirm) -> spawn pipeline for a plain-language
/// job description. `yes` mirrors `--yes`: a Confident route only actually
/// dispatches the engine when true; otherwise trek refuses and asks, same
/// as an Ambiguous route, rather than silently executing on first ask.
pub fn run_trek(
    repo_root: &Path,
    job: &str,
    yes: bool,
    spawner: &dyn EngineSpawner,
) -> TrekOutcome {
    let route = front_door::classify(job);
    emit_trek_event(
        repo_root,
        "trek_start",
        serde_json::json!({ "input_len": job.len(), "route": front_door::ambient_kind(&route) }),
    );

    let outcome = match &route {
        RouteResult::Ambiguous { .. } => {
            let question = front_door::confirm_line(&route);
            TrekOutcome::Ambiguous {
                question: question.clone(),
            }
        }
        RouteResult::Confident { mode, .. }
            if matches!(mode, FrontDoorMode::Rescue | FrontDoorMode::Comprehend) =>
        {
            TrekOutcome::DiagnosisOnly {
                mode: mode.label(),
                message: format!(
                    "{} is diagnosis-only — trek has no engine that lands an outcome for it. \
                     Run `{}` yourself; there is no Trek outcome to report.",
                    mode.label(),
                    mode.engine_command()
                ),
            }
        }
        RouteResult::Confident { mode, .. } if !yes => TrekOutcome::NeedsConfirmation {
            question: format!(
                "{} Re-run with --yes to have trek dispatch it.",
                front_door::confirm_line(&route)
            ),
        },
        RouteResult::Confident { mode, .. } => {
            let exit_code = spawner.spawn(*mode, job);
            TrekOutcome::Landed {
                mode: mode.label(),
                exit_code,
            }
        }
    };

    let outcome_fields = match &outcome {
        TrekOutcome::Landed { mode, exit_code } => serde_json::json!({
            "status": "landed",
            "mode": mode,
            "engine_exit_code": exit_code,
        }),
        TrekOutcome::NeedsConfirmation { question } => serde_json::json!({
            "status": "needs_confirmation",
            "question": question,
        }),
        TrekOutcome::Ambiguous { question } => serde_json::json!({
            "status": "ambiguous",
            "question": question,
        }),
        TrekOutcome::DiagnosisOnly { mode, message } => serde_json::json!({
            "status": "diagnosis_only",
            "mode": mode,
            "message": message,
        }),
    };
    emit_trek_event(repo_root, "trek_outcome", outcome_fields);

    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct FakeSpawner {
        calls: RefCell<Vec<(String, String)>>,
        exit_code: i32,
    }

    impl FakeSpawner {
        fn new(exit_code: i32) -> Self {
            Self {
                calls: RefCell::new(Vec::new()),
                exit_code,
            }
        }
    }

    impl EngineSpawner for FakeSpawner {
        fn spawn(&self, mode: FrontDoorMode, job: &str) -> i32 {
            self.calls
                .borrow_mut()
                .push((mode.label().to_string(), job.to_string()));
            self.exit_code
        }
    }

    fn scratch_repo_root() -> std::path::PathBuf {
        // No .chump-locks dir -> emit_trek_event's parent.exists() check
        // short-circuits to a no-op, so tests don't touch the real ambient
        // stream regardless of cwd.
        std::env::temp_dir().join("chump-trek-test-nonexistent")
    }

    #[test]
    fn confident_improve_with_yes_spawns_the_engine() {
        let spawner = FakeSpawner::new(0);
        let root = scratch_repo_root();
        let outcome = run_trek(
            &root,
            "can you fix the login bug and improve the error message",
            true,
            &spawner,
        );
        assert_eq!(
            outcome,
            TrekOutcome::Landed {
                mode: "IMPROVE",
                exit_code: 0
            }
        );
        assert_eq!(outcome.exit_code(), 0);
        assert_eq!(spawner.calls.borrow().len(), 1);
        assert_eq!(spawner.calls.borrow()[0].0, "IMPROVE");
    }

    #[test]
    fn confident_without_yes_refuses_and_does_not_spawn() {
        let spawner = FakeSpawner::new(0);
        let root = scratch_repo_root();
        let outcome = run_trek(
            &root,
            "can you fix the login bug and improve the error message",
            false,
            &spawner,
        );
        assert!(matches!(outcome, TrekOutcome::NeedsConfirmation { .. }));
        assert_eq!(outcome.exit_code(), NO_OUTCOME_EXIT);
        assert!(spawner.calls.borrow().is_empty());
    }

    #[test]
    fn ambiguous_job_asks_and_does_not_spawn() {
        let spawner = FakeSpawner::new(0);
        let root = scratch_repo_root();
        let outcome = run_trek(&root, "hello there", true, &spawner);
        assert!(matches!(outcome, TrekOutcome::Ambiguous { .. }));
        assert_eq!(outcome.exit_code(), NO_OUTCOME_EXIT);
        assert!(spawner.calls.borrow().is_empty());
    }

    #[test]
    fn diagnosis_only_route_exits_nonzero_without_spawning() {
        let spawner = FakeSpawner::new(0);
        let root = scratch_repo_root();
        let outcome = run_trek(
            &root,
            "help me, my app is broken and won't start",
            true,
            &spawner,
        );
        match &outcome {
            TrekOutcome::DiagnosisOnly { mode, .. } => assert_eq!(*mode, "RESCUE"),
            other => panic!("expected DiagnosisOnly, got {other:?}"),
        }
        assert_eq!(outcome.exit_code(), NO_OUTCOME_EXIT);
        assert!(spawner.calls.borrow().is_empty());
    }

    #[test]
    fn engine_failure_exit_code_propagates_honestly() {
        let spawner = FakeSpawner::new(1);
        let root = scratch_repo_root();
        let outcome = run_trek(
            &root,
            "I have a new idea for a tool that renames photos by date",
            true,
            &spawner,
        );
        assert_eq!(
            outcome,
            TrekOutcome::Landed {
                mode: "CREATE",
                exit_code: 1
            }
        );
        assert_eq!(outcome.exit_code(), 1);
    }
}
