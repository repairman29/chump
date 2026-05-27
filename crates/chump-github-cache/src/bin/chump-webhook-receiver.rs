//! `chump-webhook-receiver` — Phase 1 of INFRA-1999.
//!
//! Axum HTTP server that accepts GitHub webhook deliveries, verifies the
//! HMAC-SHA256 signature, and UPSERTs `pull_request` / `check_run` /
//! `workflow_run` events into `.chump/github_cache.db`.
//!
//! ## Parallel-run with the Python receiver
//!
//! Listens on `$CHUMP_WEBHOOK_RUST_PORT` (default 9876). The Python
//! receiver listens on `$CHUMP_WEBHOOK_PORT` (default 9097). Both run
//! during the 1-week validation window; no DNS/proxy cutover happens in
//! Phase 1. Routes:
//!
//! - `POST /github/webhook` — receive a webhook delivery
//! - `GET  /healthz` — liveness probe
//!
//! ## Env vars
//!
//! - `CHUMP_WEBHOOK_RUST_PORT` (default `9876`) — port to bind.
//! - `CHUMP_WEBHOOK_SECRET` (required) — HMAC-SHA256 key. Empty value
//!   makes every request fail verification (fail-closed).
//! - `CHUMP_CACHE_DB` (optional) — override `.chump/github_cache.db`.
//!
//! ## Phase 1 non-goals
//!
//! Sibling features that the Python receiver carries — auto lease
//! release on merge (`_auto_release_sibling_leases`), auto worktree
//! prune (`_auto_prune_worktree_on_merge`), ambient emission — are
//! NOT ported here. They live in the Python receiver until follow-up
//! sub-gaps port them under META-107.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use chump_github_cache::{webhook::WebhookState, SqliteCache};

fn resolve_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_CACHE_DB") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let root = std::process::Command::new("git")
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
        .unwrap_or_else(|| ".".to_string());
    PathBuf::from(root).join(".chump").join("github_cache.db")
}

fn main() -> ExitCode {
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
            eprintln!("[chump-webhook-receiver] runtime init failed: {err}");
            return ExitCode::from(1);
        }
    };
    rt.block_on(async {
        match run().await {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("[chump-webhook-receiver] {err}");
                ExitCode::from(1)
            }
        }
    })
}

async fn run() -> anyhow::Result<()> {
    let port: u16 = std::env::var("CHUMP_WEBHOOK_RUST_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(9876);
    let secret = std::env::var("CHUMP_WEBHOOK_SECRET").unwrap_or_default();
    if secret.is_empty() {
        tracing::warn!(
            "CHUMP_WEBHOOK_SECRET unset — receiver will fail every request \
             (fail-closed); set the secret to enable processing"
        );
    }
    let db = resolve_db_path();
    let cache = Arc::new(SqliteCache::open(&db)?);
    tracing::info!(
        port,
        db = %db.display(),
        secret_present = !secret.is_empty(),
        "chump-webhook-receiver starting"
    );

    let state = WebhookState { cache, secret };
    let router = chump_github_cache::webhook::router(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
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
