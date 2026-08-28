//! `chump-bandwidth-gate` — INFRA-1804.
//!
//! Wires `chump_coord::mesh::BandwidthBudget` into the existing
//! `chump_gh` self-throttle (`scripts/coord/lib/github.sh`,
//! `_chump_gh_preempt_if_low`). The shell throttle already token-buckets
//! calls-per-minute via a python-managed JSON window file; this binary is
//! a drop-in gate that speaks the same "proceed or defer" contract but
//! tracks state through `BandwidthBudget` instead, so the mesh types
//! ported in this gap have a real caller rather than sitting as
//! dead-on-arrival library code.
//!
//! Adaptation note (per AC2): the budget's unit is framed as "calls" for
//! this CLI (one call = 1 unit against `--max-calls-per-min`), which is
//! the same "bytes -> tokens/calls" re-framing documented on
//! `BandwidthBudget` in `mesh.rs`.
//!
//! ## CLI surface
//!
//! ```text
//! chump-bandwidth-gate --state-file PATH --max-calls-per-min N [--cost N] [--criticality critical|background]
//! ```
//!
//! - `critical` (default): always exits 0 (proceed), matching
//!   `_chump_gh_preempt_if_low`'s existing critical-calls-never-preempted
//!   rule — critical callers don't even deduct against the budget.
//! - `background`: deducts `--cost` (default 1) from the window budget.
//!   Exits 0 (proceed) if the budget can afford it, exits 1 (defer) if
//!   not. The window resets automatically once `window_seconds` has
//!   elapsed since `window_start`.
//!
//! State persists as the `BandwidthBudget` fields (JSON) at
//! `--state-file` across invocations — one file per script/api_class,
//! same granularity as the existing `.gh-throttle-window.<class>` files.
//!
//! ## Compatibility shim
//!
//! This binary is opt-in via `CHUMP_BANDWIDTH_GATE_RUST=1` in
//! `scripts/coord/lib/github.sh` — unset/0 keeps the existing
//! `CHUMP_GH_MAX_CALLS_PER_MIN`-driven python path untouched. `--max-calls-per-min`
//! is expected to be sourced from that same env var by the caller, so both
//! paths honor one knob.

use chump_coord::mesh::BandwidthBudget;
use std::env;
use std::fs;
use std::process::ExitCode;

fn parse_args(argv: &[String]) -> Option<(String, usize, usize, String)> {
    let mut state_file: Option<String> = None;
    let mut max_calls_per_min: Option<usize> = None;
    let mut cost: usize = 1;
    let mut criticality = "critical".to_string();

    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "--state-file" => {
                state_file = argv.get(i + 1).cloned();
                i += 2;
            }
            "--max-calls-per-min" => {
                max_calls_per_min = argv.get(i + 1).and_then(|s| s.parse().ok());
                i += 2;
            }
            "--cost" => {
                cost = argv.get(i + 1).and_then(|s| s.parse().ok()).unwrap_or(1);
                i += 2;
            }
            "--criticality" => {
                criticality = argv
                    .get(i + 1)
                    .cloned()
                    .unwrap_or_else(|| "critical".to_string());
                i += 2;
            }
            _ => {
                i += 1;
            }
        }
    }

    Some((state_file?, max_calls_per_min?, cost, criticality))
}

/// Load an existing budget from `path`, or start a fresh one sized to
/// `max_calls_per_min` over a 60s window. Also resets the window if it has
/// expired, mirroring the python window-drop-older-than-60s behavior.
fn load_or_init(path: &str, max_calls_per_min: usize) -> BandwidthBudget {
    let window_seconds = 60u32;

    if let Ok(raw) = fs::read_to_string(path) {
        if let Ok(mut budget) = serde_json::from_str::<BandwidthBudget>(&raw) {
            // Re-sizing the cap (env var changed since last run) always
            // takes the new total; only the elapsed-window check decides
            // whether `remaining` resets.
            budget.total = max_calls_per_min;
            let expired = chrono::DateTime::parse_from_rfc3339(&budget.window_start)
                .map(|start| {
                    let elapsed =
                        chrono::Utc::now().signed_duration_since(start.with_timezone(&chrono::Utc));
                    elapsed.num_seconds() >= i64::from(window_seconds)
                })
                .unwrap_or(true);
            if expired {
                budget.reset();
            }
            if budget.remaining > budget.total {
                budget.remaining = budget.total;
            }
            return budget;
        }
    }

    BandwidthBudget::new(max_calls_per_min, window_seconds)
}

fn main() -> ExitCode {
    let argv: Vec<String> = env::args().collect();
    let Some((state_file, max_calls_per_min, cost, criticality)) = parse_args(&argv) else {
        eprintln!(
            "usage: chump-bandwidth-gate --state-file PATH --max-calls-per-min N [--cost N] [--criticality critical|background]"
        );
        return ExitCode::FAILURE;
    };

    // Critical calls are never gated — matches _chump_gh_preempt_if_low's
    // existing "criticality=critical always proceeds" rule. No budget
    // deduction, no state write.
    if criticality != "background" {
        return ExitCode::SUCCESS;
    }

    let mut budget = load_or_init(&state_file, max_calls_per_min);
    let can_proceed = budget.can_send(cost);
    if can_proceed {
        budget.deduct(cost);
    }

    if let Some(parent) = std::path::Path::new(&state_file).parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(serialized) = serde_json::to_string(&budget) {
        let _ = fs::write(&state_file, serialized);
    }

    if can_proceed {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}
