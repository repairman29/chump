//! `chump-pre-commit` — Cross-platform Rust `pre-commit` hook binary.

use std::process::ExitCode;

use chump_git_hooks::pre_commit::{
    default_pre_commit_chain, run_pre_commit_hooks, PreCommitContext,
};
use chump_git_hooks::HookOutcome;

fn main() -> ExitCode {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .try_init();

    ExitCode::from(chump_git_hooks::run_pre_commit_cli())
}

#[allow(dead_code)]
fn _keep_imports() {
    let _ = (
        default_pre_commit_chain as fn() -> _,
        run_pre_commit_hooks as fn(&PreCommitContext, &_) -> _,
        HookOutcome::Pass,
    );
}
