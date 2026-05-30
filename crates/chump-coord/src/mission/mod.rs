//! # mission — public Mission / PersistentMission / Replanner surface
//!
//! Public-interface types for the upcoming Mission orchestrator (META-164,
//! "Rainbow-6 squad system"). This crate ships only the **shapes** — type
//! definitions, the persistent envelope, the replanner trait, and a
//! file-backed default store. The orchestrator daemon, the mission-aware
//! picker, the CLI surface, and the PWA visualization plug into these
//! shapes in later slices; once this module lands, those become incremental
//! wiring instead of design work.
//!
//! ## Why the types are split into two sub-modules
//!
//! - [`persistence`] owns the data: [`Mission`], [`Objective`],
//!   [`PersistentMission`], the [`ObjectiveState`] machine,
//!   [`MissionCheckpoint`] history, dependency edges, the
//!   [`MissionStore`] trait, and the [`FileBackedMissionStore`] impl.
//! - [`replanning`] owns the behavior policy: the [`MissionReplanner`]
//!   trait, the [`ReplanStrategy`] enum, and the
//!   [`AbortOnFailureReplanner`] default.
//!
//! Splitting them keeps the data types stable as policy evolves — a new
//! replanner impl never needs a schema change.
//!
//! ## Design notes (derived from established Rust mission-execution prior art)
//!
//! The shapes here are adapted for agent-fleet semantics:
//!
//! - `resource_cost` is a **token-budget** estimate, not a physical energy
//!   value. It aligns with the budget enforcement path tracked under
//!   INFRA-2090.
//! - `Objective::target` is the **HITL approval gate reference**
//!   (aligns with INFRA-1813) — a `None` means no approval required;
//!   a `Some(_)` means the approver checks the target for scope.
//! - `FallbackMode` maps directly to curator behaviors and is preserved
//!   verbatim from the original surface so prior consumers stay legible.
//!
//! Physical-only fields (geo, bounding boxes, obstacle catalogs) are
//! deliberately omitted; they remain in a private extension crate.
//!
//! ## Quick example
//!
//! ```rust
//! use chump_coord::mission::{
//!     FallbackMode, FileBackedMissionStore, Mission, MissionStore, Objective,
//!     PersistentMission,
//! };
//!
//! let m = Mission {
//!     id: "demo-001".to_string(),
//!     name: "demo".to_string(),
//!     objectives: vec![Objective {
//!         id: "step-a".to_string(),
//!         description: "warm cache".to_string(),
//!         resource_cost: 200,
//!         duration_secs: 60,
//!         target: None,
//!         sequence: 0,
//!     }],
//!     fallback_behavior: FallbackMode::SafeShutdown,
//!     timestamp_issued: "2026-05-30T00:00:00Z".to_string(),
//!     ttl_seconds: 3600,
//!     version: 1,
//! };
//! let pm = PersistentMission::new(m);
//! let store = FileBackedMissionStore::new(std::env::temp_dir().join("chump-mission-doctest"));
//! store.save(&pm).unwrap();
//! let _ids = store.list().unwrap();
//! ```

pub mod persistence;
pub mod replanning;

pub use persistence::{
    DependencyCondition, FallbackMode, FileBackedMissionStore, Mission, MissionCheckpoint,
    MissionStore, Objective, ObjectiveDependency, ObjectiveState, PersistentMission,
};
pub use replanning::{AbortOnFailureReplanner, MissionReplanner, ReplanStrategy};
