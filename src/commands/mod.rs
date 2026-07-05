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

pub mod add_env_var;
pub mod add_path_filter;
pub mod add_raw_gh_allowlist;
pub mod bootstrap;
pub mod config;
pub mod consensus_tally;
pub mod contract_scan;
pub mod dispatch_external;
pub mod durable_execution;
pub mod durable_execution_journal;
pub mod durable_resume;
pub mod emit_event;
pub mod install_daemon;
pub mod inventory;
pub mod sibling_status;
pub mod voice;
pub mod vote;
