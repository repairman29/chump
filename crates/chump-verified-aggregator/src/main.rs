//! `chump-verified-aggregator` — basic, non-gating "verified" status service.
//!
//! META-135 (slice of META-131 / see `docs/design/CI_VERIFIED_AGGREGATOR.md`
//! for the full-target design, META-134).
//!
//! This slice only receives and stores per-lane CI status updates. It does
//! NOT aggregate lane verdicts, classify results, or gate anything — that is
//! explicitly out of scope (AC #3) and tracked as follow-up work against the
//! META-134 design.
//!
//! ## Endpoints
//!
//! - `POST /api/lane-status` — store a lane status update
//! - `GET  /api/lane-status?pr=<n>&sha=<sha>` — list stored updates for a PR/sha
//! - `GET  /healthz`
//!
//! ## Env vars
//!
//! - `CHUMP_VERIFIED_AGGREGATOR_PORT` (default `7071`) — port to bind (127.0.0.1 only).
//! - `CHUMP_VERIFIED_AGGREGATOR_DB` (optional) — override `.chump/verified_aggregator.db`.

use std::process::ExitCode;
use std::sync::Arc;

use chump_verified_aggregator::{db::AggregatorStore, routes};

fn resolve_repo_root() -> std::path::PathBuf {
    std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."))
}

fn resolve_db_path() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("CHUMP_VERIFIED_AGGREGATOR_DB") {
        if !p.is_empty() {
            return std::path::PathBuf::from(p);
        }
    }
    resolve_repo_root()
        .join(".chump")
        .join("verified_aggregator.db")
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("chump-verified-aggregator — basic non-gating lane-status service (META-135).");
        println!();
        println!("Usage: chump-verified-aggregator [--port N] [--help] [--version]");
        println!();
        println!("Env vars:");
        println!("  CHUMP_VERIFIED_AGGREGATOR_PORT  (default 7071)");
        println!(
            "  CHUMP_VERIFIED_AGGREGATOR_DB    (default <repo>/.chump/verified_aggregator.db)"
        );
        return ExitCode::SUCCESS;
    }
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("chump-verified-aggregator {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }
    let port_override: Option<u16> = args
        .windows(2)
        .find(|w| w[0] == "--port")
        .and_then(|w| w[1].parse().ok());

    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .try_init();

    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(err) => {
            eprintln!("[chump-verified-aggregator] runtime init failed: {err}");
            return ExitCode::from(1);
        }
    };

    rt.block_on(async {
        match run(port_override).await {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("[chump-verified-aggregator] {err}");
                ExitCode::from(1)
            }
        }
    })
}

async fn run(port_override: Option<u16>) -> anyhow::Result<()> {
    let port: u16 = port_override
        .or_else(|| {
            std::env::var("CHUMP_VERIFIED_AGGREGATOR_PORT")
                .ok()
                .and_then(|p| p.parse().ok())
        })
        .unwrap_or(7071);

    let db_path = resolve_db_path();
    if let Some(parent) = db_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    tracing::info!(port, db = %db_path.display(), "chump-verified-aggregator starting");

    let store = Arc::new(AggregatorStore::open(&db_path)?);
    let router = routes::build_router(store);

    // Localhost only — do NOT bind 0.0.0.0 (security requirement).
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(addr = %addr, "listening");

    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sig) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sig.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => tracing::info!("received SIGINT, shutting down"),
        _ = terminate => tracing::info!("received SIGTERM, shutting down"),
    }
}
