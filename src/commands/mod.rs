//! META-159: commands module — fleet recv-side v0 voting CLIs.
//! META-154: sibling_status — per-active-lease progress matrix.
//! INFRA-2258: voice — Voice-of-Agent VOA filing subcommand.
//! META-271: inventory — fleet inventory + tech-debt review-only audit CLI.
//! INFRA-2371: config — runtime cascade/privacy/MCP snapshot subcommand.
//! INFRA-2399: author-time helpers — add-env-var, emit-event, install-daemon,
//!             add-path-filter, add-raw-gh-allowlist.
//! INFRA-2405: contract-scan — detect cross-PR state-file/IPC schema mismatch (anti-Bug-1).
//! RESILIENT-059: durable-execution — SQLite-journaled activity wrapper + resume CLI.
//! INFRA-2265: bootstrap — net-new product bootstrap entrypoint (empty dir → first commit + gap).
//! INFRA-5754: inventory-based command self-registration infra (INFRA-1748 slice 1).

pub mod add_env_var;
pub mod add_path_filter;
pub mod add_raw_gh_allowlist;
pub mod bootstrap;
pub mod claim_lint;
pub mod config;
pub mod consensus;
pub mod consensus_ask;
pub mod consensus_tally;
pub mod contract_scan;
pub mod demo;
pub mod dispatch_authoring;
pub mod dispatch_external;
pub mod durable_execution;
pub mod durable_execution_journal;
pub mod durable_resume;
pub mod emit_event;
pub mod install_daemon;
pub mod inventory;
pub mod reachability;
pub mod roadmap_from_vision;
pub mod sibling_status;
pub mod source_resolve;
pub mod swe;
pub mod voice;
pub mod vote;

/// Self-registered subcommand descriptor for the inventory-based command
/// pattern (INFRA-5754, INFRA-1748 slice 1). A module submits one
/// `CommandEntry` via `inventory::submit!`; `try_dispatch()` matches it
/// against `argv[1]` so `main.rs` doesn't need a new `if` arm per command.
pub struct CommandEntry {
    /// Subcommand name as typed on the CLI (matches `argv[1]`).
    pub name: &'static str,
    /// Entry point; receives the args after the subcommand name.
    pub run: fn(&[String]) -> i32,
}

inventory::collect!(CommandEntry);

/// Look up a self-registered command by `argv[1]` and run it. Returns `None`
/// when no module has registered under that name, so callers fall through to
/// the existing per-command `if` chain in `main.rs`.
pub fn try_dispatch(args: &[String]) -> Option<i32> {
    let name = args.get(1)?;
    let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
    inventory::iter::<CommandEntry>()
        .find(|entry| entry.name == name)
        .map(|entry| (entry.run)(&sub_args))
}
