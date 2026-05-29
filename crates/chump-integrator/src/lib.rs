//! # chump-integrator
//!
//! META-124 integration daemon: batches `ready_to_ship` gaps through a
//! preflight gate before committing to SHIP. Phase 1 is **dry-run only** —
//! the daemon stops after preflight and logs what it *would* have shipped.
//!
//! ## Lifecycle (steps 1-5, Phase 1)
//!
//! ```text
//! CLAIM  → lock the integration slot in NATS KV (atomic CAS)
//! SELECT → pick candidates from work-board / state.db (cycle::select)
//! MERGE  → git fetch + merge --no-ff per candidate (cycle::merge_branch)
//! PREFLIGHT → shell-out to `chump preflight` or cross-build-linux.sh
//! DECISION → in dry-run: log manifest + emit ambient event; in live: SHIP (C8)
//! ```
//!
//! Steps 6 (SHIP/BISECT) and 7 (CLEANUP) are deferred to INFRA-2136.
//!
//! ## Environment knobs
//!
//! | Variable | Default | Purpose |
//! |---|---|---|
//! | `CHUMP_INTEGRATOR_CADENCE_MIN` | `30` | Poll interval in minutes |
//! | `CHUMP_INTEGRATOR_POLL_S` | `15` | NATS work-board poll interval in seconds |
//! | `CHUMP_INTEGRATOR_VOLUME_THRESHOLD` | `5` | Min candidates before a cycle fires |
//! | `CHUMP_INTEGRATOR_LOC_BUDGET` | `1500` | Max total LOC across batch |
//! | `CHUMP_INTEGRATOR_MAX_BATCH` | `10` | Hard cap on batch size |
//! | `CHUMP_INTEGRATOR_PREFLIGHT_TIMEOUT_S` | `480` | Preflight command timeout |
//! | `CHUMP_INTEGRATOR_DRY_RUN` | `1` | 1 = dry-run (Phase 1 default); 0 = live |
//!
//! ## Cross-references
//!
//! - INFRA-2130 — parent C2 gap (daemon skeleton + lifecycle)
//! - INFRA-2171 — C2a cycle::select module
//! - INFRA-2172 — C2b cycle::merge_branch module
//! - INFRA-2132 — ambient event kinds registered
//! - INFRA-2136 — C8 SHIP/BISECT step (Phase 2)
//! - INFRA-2135 — Batched-Under trailer spec

pub mod config;
pub mod cycle;
pub mod daemon;
pub mod policy;

pub use config::IntegratorConfig;
pub use daemon::IntegratorDaemon;
