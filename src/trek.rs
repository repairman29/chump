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
use chump_coord::mission::{
    FallbackMode, Mission, MissionStore, Objective, ObjectiveState, PersistentMission,
};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

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

/// Monotonic counter mixed into generated mission ids so two treks issued
/// within the same process in the same microsecond (parallel tests, or a
/// tight dispatch loop) still get distinct `FileBackedMissionStore` keys.
static TREK_MISSION_SEQ: AtomicU64 = AtomicU64::new(0);

/// Small struct encoded into the synthetic `"run"` objective's
/// `description` field — the only free-form string slot on [`Objective`].
/// `chump trek --list` / `status <id>` decode it back out to print mode +
/// outcome pointer without needing a schema change to the shared
/// `chump-coord` mission types.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct TrekMeta {
    mode: String,
    outcome_pointer: String,
}

fn now_rfc3339() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// Build the initial `Pending` [`PersistentMission`] for a trek run — one
/// mission per invocation, one synthetic objective (`"run"`) representing
/// "classify -> spawn the routed engine".
fn build_mission(job: &str) -> PersistentMission {
    let seq = TREK_MISSION_SEQ.fetch_add(1, Ordering::Relaxed);
    let id = format!(
        "trek-{}-{}-{}",
        chrono::Utc::now().format("%Y%m%dT%H%M%S%.6f"),
        std::process::id(),
        seq
    );
    let objective = Objective {
        id: "run".to_string(),
        description: serde_json::to_string(&TrekMeta::default()).unwrap_or_default(),
        resource_cost: 0,
        duration_secs: 0,
        target: None,
        sequence: 0,
    };
    let mission = Mission {
        id,
        name: job.to_string(),
        objectives: vec![objective],
        fallback_behavior: FallbackMode::SafeShutdown,
        timestamp_issued: now_rfc3339(),
        ttl_seconds: 0,
        version: 1,
    };
    PersistentMission::new(mission)
}

fn set_objective_meta(pm: &mut PersistentMission, mode: &str, outcome_pointer: &str) {
    if let Some(obj) = pm.mission.objectives.get_mut(0) {
        let meta = TrekMeta {
            mode: mode.to_string(),
            outcome_pointer: outcome_pointer.to_string(),
        };
        obj.description = serde_json::to_string(&meta).unwrap_or_default();
    }
}

/// Decode the mode + outcome pointer previously written by [`set_objective_meta`].
/// Falls back to an empty/`"unknown"` struct rather than failing — `--list`
/// and `status` are read paths and must not die on a malformed record.
fn decode_meta(pm: &PersistentMission) -> TrekMeta {
    pm.mission
        .objectives
        .first()
        .and_then(|o| serde_json::from_str::<TrekMeta>(&o.description).ok())
        .unwrap_or_default()
}

/// One-line summary for `chump trek --list`.
pub fn format_mission_summary(pm: &PersistentMission) -> String {
    let meta = decode_meta(pm);
    let state = pm
        .current_state("run")
        .map(|s| format!("{s:?}"))
        .unwrap_or_else(|| "Unknown".to_string());
    let outcome = if meta.outcome_pointer.is_empty() {
        "-".to_string()
    } else {
        meta.outcome_pointer
    };
    format!(
        "{}  job={:?}  mode={}  state={}  outcome={}",
        pm.mission.id, pm.mission.name, meta.mode, state, outcome
    )
}

/// Multi-line detail for `chump trek status <id>`.
pub fn format_mission_detail(pm: &PersistentMission) -> String {
    let meta = decode_meta(pm);
    let state = pm
        .current_state("run")
        .map(|s| format!("{s:?}"))
        .unwrap_or_else(|| "Unknown".to_string());
    let outcome = if meta.outcome_pointer.is_empty() {
        "-".to_string()
    } else {
        meta.outcome_pointer
    };
    format!(
        "id: {}\njob: {}\nmode: {}\nstate: {}\noutcome: {}\nissued: {}",
        pm.mission.id, pm.mission.name, meta.mode, state, outcome, pm.mission.timestamp_issued
    )
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
    mission_store: &dyn MissionStore,
) -> TrekOutcome {
    let route = front_door::classify(job);
    emit_trek_event(
        repo_root,
        "trek_start",
        serde_json::json!({ "input_len": job.len(), "route": front_door::ambient_kind(&route) }),
    );

    // INFRA-3658 (RIBBON-03): persist one Mission record per trek run so a
    // walked-away operator can see what the run produced via `chump trek
    // --list` / `status <id>`. Pending is written before we know the route
    // outcome; every branch below transitions it to a terminal state.
    let mut pm = build_mission(job);
    let _ = pm.checkpoint("run", ObjectiveState::Pending, &now_rfc3339());
    let _ = mission_store.save(&pm);

    let outcome = match &route {
        RouteResult::Ambiguous { .. } => {
            let question = front_door::confirm_line(&route);
            set_objective_meta(&mut pm, "AMBIGUOUS", &question);
            let _ = pm.checkpoint("run", ObjectiveState::Skipped, &now_rfc3339());
            let _ = mission_store.save(&pm);
            TrekOutcome::Ambiguous {
                question: question.clone(),
            }
        }
        RouteResult::Confident { mode, .. }
            if matches!(mode, FrontDoorMode::Rescue | FrontDoorMode::Comprehend) =>
        {
            let message = format!(
                "{} is diagnosis-only — trek has no engine that lands an outcome for it. \
                 Run `{}` yourself; there is no Trek outcome to report.",
                mode.label(),
                mode.engine_command()
            );
            set_objective_meta(&mut pm, mode.label(), &message);
            let _ = pm.checkpoint("run", ObjectiveState::Skipped, &now_rfc3339());
            let _ = mission_store.save(&pm);
            TrekOutcome::DiagnosisOnly {
                mode: mode.label(),
                message,
            }
        }
        RouteResult::Confident { mode, .. } if !yes => {
            let question = format!(
                "{} Re-run with --yes to have trek dispatch it.",
                front_door::confirm_line(&route)
            );
            set_objective_meta(&mut pm, mode.label(), &question);
            let _ = pm.checkpoint("run", ObjectiveState::Skipped, &now_rfc3339());
            let _ = mission_store.save(&pm);
            TrekOutcome::NeedsConfirmation { question }
        }
        RouteResult::Confident { mode, .. } => {
            set_objective_meta(&mut pm, mode.label(), "running");
            let _ = pm.checkpoint("run", ObjectiveState::InProgress, &now_rfc3339());
            let _ = mission_store.save(&pm);

            let exit_code = spawner.spawn(*mode, job);

            let outcome_pointer = format!("{} engine exit_code={}", mode.label(), exit_code);
            set_objective_meta(&mut pm, mode.label(), &outcome_pointer);
            let next_state = if exit_code == 0 {
                ObjectiveState::Completed
            } else {
                ObjectiveState::Failed
            };
            let _ = pm.checkpoint("run", next_state, &now_rfc3339());
            let _ = mission_store.save(&pm);

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

    fn scratch_mission_store() -> chump_coord::mission::FileBackedMissionStore {
        // Unique root per call -> tests running concurrently in the same
        // process never see each other's records.
        static SCRATCH_SEQ: AtomicU64 = AtomicU64::new(0);
        let seq = SCRATCH_SEQ.fetch_add(1, Ordering::Relaxed);
        chump_coord::mission::FileBackedMissionStore::new(std::env::temp_dir().join(format!(
            "chump-trek-test-missions-{}-{}",
            std::process::id(),
            seq
        )))
    }

    #[test]
    fn confident_improve_with_yes_spawns_the_engine() {
        let spawner = FakeSpawner::new(0);
        let root = scratch_repo_root();
        let store = scratch_mission_store();
        let outcome = run_trek(
            &root,
            "can you fix the login bug and improve the error message",
            true,
            &spawner,
            &store,
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
        let store = scratch_mission_store();
        let outcome = run_trek(
            &root,
            "can you fix the login bug and improve the error message",
            false,
            &spawner,
            &store,
        );
        assert!(matches!(outcome, TrekOutcome::NeedsConfirmation { .. }));
        assert_eq!(outcome.exit_code(), NO_OUTCOME_EXIT);
        assert!(spawner.calls.borrow().is_empty());
    }

    #[test]
    fn ambiguous_job_asks_and_does_not_spawn() {
        let spawner = FakeSpawner::new(0);
        let root = scratch_repo_root();
        let store = scratch_mission_store();
        let outcome = run_trek(&root, "hello there", true, &spawner, &store);
        assert!(matches!(outcome, TrekOutcome::Ambiguous { .. }));
        assert_eq!(outcome.exit_code(), NO_OUTCOME_EXIT);
        assert!(spawner.calls.borrow().is_empty());
    }

    #[test]
    fn diagnosis_only_route_exits_nonzero_without_spawning() {
        let spawner = FakeSpawner::new(0);
        let root = scratch_repo_root();
        let store = scratch_mission_store();
        let outcome = run_trek(
            &root,
            "help me, my app is broken and won't start",
            true,
            &spawner,
            &store,
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
        let store = scratch_mission_store();
        let outcome = run_trek(
            &root,
            "I have a new idea for a tool that renames photos by date",
            true,
            &spawner,
            &store,
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

    #[test]
    fn completed_run_persists_mission_with_outcome_pointer_that_reloads_identically() {
        let spawner = FakeSpawner::new(0);
        let root = scratch_repo_root();
        let store = scratch_mission_store();

        let outcome = run_trek(
            &root,
            "can you fix the login bug and improve the error message",
            true,
            &spawner,
            &store,
        );
        assert_eq!(
            outcome,
            TrekOutcome::Landed {
                mode: "IMPROVE",
                exit_code: 0
            }
        );

        let ids = store.list().unwrap_or_default();
        assert_eq!(ids.len(), 1, "expected exactly one mission record");
        let mission_id = ids[0].clone();

        let pm = store.load(&mission_id).expect("load persisted mission");
        assert_eq!(pm.current_state("run"), Some(ObjectiveState::Completed));
        let meta = decode_meta(&pm);
        assert_eq!(meta.mode, "IMPROVE");
        assert!(
            !meta.outcome_pointer.is_empty(),
            "outcome pointer must be non-empty on a completed run"
        );

        // Reloads identically.
        let reloaded = store.load(&mission_id).expect("reload persisted mission");
        assert_eq!(pm, reloaded);
    }

    #[test]
    fn failed_run_transitions_to_failed_state() {
        let spawner = FakeSpawner::new(1);
        let root = scratch_repo_root();
        let store = scratch_mission_store();

        let outcome = run_trek(
            &root,
            "I have a new idea for a tool that renames photos by date",
            true,
            &spawner,
            &store,
        );
        assert_eq!(outcome.exit_code(), 1);

        let ids = store.list().unwrap_or_default();
        assert_eq!(ids.len(), 1, "expected exactly one mission record");
        let pm = store.load(&ids[0]).expect("load persisted mission");
        assert_eq!(pm.current_state("run"), Some(ObjectiveState::Failed));
    }
}
