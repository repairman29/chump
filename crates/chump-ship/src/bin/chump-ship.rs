//! `chump-ship` — CLI entry for the cross-platform Chump ship & bot-merge executor.

use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .try_init();

    let code = chump_ship::cli::run_from_itr(std::env::args_os()).await;
    ExitCode::from(code)
}
