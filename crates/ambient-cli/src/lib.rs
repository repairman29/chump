//! # chump-ambient-cli
//!
//! Schema-enforced, multi-writer, append-only structured telemetry for local-first apps.
//!
//! ## What it is, mechanically
//!
//! - **One JSONL file** at `.chump-locks/ambient.jsonl` (or `$CHUMP_AMBIENT_LOG`).
//! - **One event per line**, kind-discriminated, with `ts` injected automatically.
//! - **Append is atomic** under advisory file locking; many writers, one log.
//! - **Schema is the file** — `EVENT_REGISTRY.yaml` declares allowed `kind` values
//!   and required fields; downstream tooling never has to defend against tag explosion
//!   because the registry is the gate.
//! - **Tail is just a file read** — no broker, no collector, no daemon.
//!
//! ## What's in this crate
//!
//! - [`ambient_emit`] — the write side: `emit(&EmitArgs)` appends a schema-valid line.
//! - [`ambient_stream`] — the read side: parse, filter, format recent events.
//! - [`ambient_rotate`] — size-bounded rotation so the log doesn't grow without bound.
//!
//! ## Standalone usage
//!
//! ```text
//! $ ambient emit cycle_end --field rc=0 --field used_ms=842
//! $ ambient tail
//! $ ambient --help
//! ```
//!
//! ## Library usage
//!
//! ```no_run
//! use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
//!
//! let args = EmitArgs {
//!     kind: "cycle_end".into(),
//!     fields: vec![("rc".into(), "0".into())],
//!     ..Default::default()
//! };
//! emit(&args).unwrap();
//! ```

pub mod ambient_emit;
pub mod ambient_rotate;
pub mod ambient_stream;
