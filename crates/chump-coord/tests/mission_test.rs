//! Integration tests for the mission types (INFRA-2247).
//!
//! Coverage:
//! - serde round-trip on `Mission`, `PersistentMission`, `MissionCheckpoint`,
//!   `ObjectiveDependency`, `ReplanStrategy`, `FallbackMode`.
//! - State-machine: legal vs illegal `ObjectiveState` transitions.
//! - `FileBackedMissionStore` save/load/list CRUD against a `tempfile` root.
//! - `AbortOnFailureReplanner` returns `Abort` for both denial and failure.
//!
//! None of these tests require NATS — the mission surface is pure data + a
//! filesystem-backed store, so they run in stock CI.

use chump_coord::mission::{
    AbortOnFailureReplanner, DependencyCondition, FallbackMode, FileBackedMissionStore, Mission,
    MissionCheckpoint, MissionReplanner, MissionStore, Objective, ObjectiveDependency,
    ObjectiveState, PersistentMission, ReplanStrategy,
};
use tempfile::TempDir;

fn sample_mission(id: &str) -> Mission {
    Mission {
        id: id.to_string(),
        name: format!("{}-name", id),
        objectives: vec![
            Objective {
                id: "obj-a".to_string(),
                description: "first step".to_string(),
                resource_cost: 100,
                duration_secs: 30,
                target: None,
                sequence: 0,
            },
            Objective {
                id: "obj-b".to_string(),
                description: "needs approval".to_string(),
                resource_cost: 500,
                duration_secs: 120,
                target: Some("hitl-gate-001".to_string()),
                sequence: 1,
            },
        ],
        fallback_behavior: FallbackMode::SafeShutdown,
        timestamp_issued: "2026-05-30T00:00:00Z".to_string(),
        ttl_seconds: 3600,
        version: 1,
    }
}

#[test]
fn mission_round_trips_through_serde() {
    let m = sample_mission("rt-001");
    let json = serde_json::to_string(&m).expect("serialize");
    let back: Mission = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(m, back);
}

#[test]
fn persistent_mission_round_trips_with_checkpoints() {
    let mut pm = PersistentMission::new(sample_mission("rt-002"));
    pm.checkpoint("obj-a", ObjectiveState::InProgress, "2026-05-30T00:01:00Z")
        .expect("in_progress");
    pm.checkpoint("obj-a", ObjectiveState::Completed, "2026-05-30T00:02:00Z")
        .expect("completed");

    let json = serde_json::to_string(&pm).expect("serialize");
    let back: PersistentMission = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(pm, back);
    assert_eq!(back.current_state("obj-a"), Some(ObjectiveState::Completed));
    assert_eq!(back.current_state("obj-b"), None);
}

#[test]
fn dependency_and_replan_strategy_round_trip() {
    let dep = ObjectiveDependency {
        from: "obj-a".to_string(),
        to: "obj-b".to_string(),
        condition: DependencyCondition::Completed,
    };
    let dep_back: ObjectiveDependency =
        serde_json::from_str(&serde_json::to_string(&dep).unwrap()).unwrap();
    assert_eq!(dep, dep_back);

    let s = ReplanStrategy::RetryWithBackoff { max_attempts: 3 };
    let s_back: ReplanStrategy = serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
    assert_eq!(s, s_back);

    let cp = MissionCheckpoint {
        mission_id: "rt-003".to_string(),
        objective_id: "obj-x".to_string(),
        state: ObjectiveState::Failed,
        ts: "2026-05-30T01:00:00Z".to_string(),
    };
    let cp_back: MissionCheckpoint =
        serde_json::from_str(&serde_json::to_string(&cp).unwrap()).unwrap();
    assert_eq!(cp, cp_back);
}

#[test]
fn state_transitions_legal_paths() {
    use ObjectiveState::*;
    assert!(Pending.can_transition_to(InProgress));
    assert!(Pending.can_transition_to(Skipped));
    assert!(Pending.can_transition_to(Failed));
    assert!(InProgress.can_transition_to(Completed));
    assert!(InProgress.can_transition_to(Failed));
    assert!(InProgress.can_transition_to(Skipped));
    // Replan re-arm path.
    assert!(Failed.can_transition_to(Pending));
}

#[test]
fn state_transitions_illegal_paths() {
    use ObjectiveState::*;
    assert!(!Completed.can_transition_to(InProgress));
    assert!(!Completed.can_transition_to(Pending));
    assert!(!Skipped.can_transition_to(InProgress));
    assert!(!InProgress.can_transition_to(Pending));
    assert!(!Pending.can_transition_to(Completed));
}

#[test]
fn checkpoint_rejects_illegal_transition() {
    let mut pm = PersistentMission::new(sample_mission("ckpt-001"));
    pm.checkpoint("obj-a", ObjectiveState::InProgress, "2026-05-30T00:01:00Z")
        .unwrap();
    pm.checkpoint("obj-a", ObjectiveState::Completed, "2026-05-30T00:02:00Z")
        .unwrap();
    // Completed -> InProgress is not allowed.
    let err = pm
        .checkpoint("obj-a", ObjectiveState::InProgress, "2026-05-30T00:03:00Z")
        .expect_err("illegal");
    assert!(err.to_string().contains("illegal transition"));
}

#[test]
fn checkpoint_rejects_unknown_objective() {
    let mut pm = PersistentMission::new(sample_mission("ckpt-002"));
    let err = pm
        .checkpoint("obj-z", ObjectiveState::InProgress, "2026-05-30T00:01:00Z")
        .expect_err("unknown");
    assert!(err.to_string().contains("not part of mission"));
}

#[test]
fn file_backed_store_save_load_list_crud() {
    let tmp = TempDir::new().expect("tempdir");
    let store = FileBackedMissionStore::new(tmp.path().to_path_buf());

    // list() on empty / nonexistent root returns [].
    assert!(store.list().unwrap().is_empty());

    let pm1 = PersistentMission::new(sample_mission("crud-001"));
    let pm2 = PersistentMission::new(sample_mission("crud-002"));
    store.save(&pm1).expect("save 1");
    store.save(&pm2).expect("save 2");

    let mut ids = store.list().expect("list");
    ids.sort();
    assert_eq!(ids, vec!["crud-001".to_string(), "crud-002".to_string()]);

    let loaded = store.load("crud-001").expect("load 1");
    assert_eq!(loaded, pm1);

    // Save again with a checkpoint appended — load reflects update.
    let mut pm1b = pm1.clone();
    pm1b.checkpoint("obj-a", ObjectiveState::InProgress, "2026-05-30T00:10:00Z")
        .unwrap();
    store.save(&pm1b).expect("save updated");
    let reloaded = store.load("crud-001").expect("reload");
    assert_eq!(reloaded.checkpoints.len(), 1);
    assert_eq!(
        reloaded.current_state("obj-a"),
        Some(ObjectiveState::InProgress)
    );
}

#[test]
fn abort_on_failure_replanner_returns_abort() {
    let m = sample_mission("rpl-001");
    let r = AbortOnFailureReplanner;
    let denied = &m.objectives[0];
    let failed = &m.objectives[1];
    assert_eq!(r.replan_on_denial(&m, denied), ReplanStrategy::Abort);
    assert_eq!(r.replan_on_failure(&m, failed), ReplanStrategy::Abort);
}

#[test]
fn fallback_mode_serializes_as_snake_case() {
    let json = serde_json::to_string(&FallbackMode::QueryAuthority).unwrap();
    assert_eq!(json, "\"query_authority\"");
    let back: FallbackMode = serde_json::from_str(&json).unwrap();
    assert_eq!(back, FallbackMode::QueryAuthority);
}
