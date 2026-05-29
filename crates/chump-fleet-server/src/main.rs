//! `chump-fleet-server` — Fleet visualization HTTP + WebSocket query server.
//!
//! INFRA-2175 / INFRA-2164 sub-slice b.
//!
//! ## Endpoints
//!
//! - `GET /api/events?from=<ts_ms>&to=<ts_ms>&limit=<N>&offset=<N>`
//! - `GET /api/segments?from=<ts_ms>&to=<ts_ms>`
//! - `GET /api/sessions/active`
//! - `GET /api/trace/pr/:n`
//! - `WS  /api/live`
//!
//! ## Env vars
//!
//! - `CHUMP_FLEET_SERVER_PORT` (default `7070`) — port to bind (always 127.0.0.1).
//! - `CHUMP_FLEET_DB` (optional) — override `.chump/fleet_events.db`.

use std::process::ExitCode;
use std::sync::Arc;

mod db;
mod routes;
mod segmenter;

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
    if let Ok(p) = std::env::var("CHUMP_FLEET_DB") {
        if !p.is_empty() {
            return std::path::PathBuf::from(p);
        }
    }
    resolve_repo_root().join(".chump").join("fleet_events.db")
}

/// Resolve the directory the scrubber SPA lives in.
///
/// Order: `CHUMP_FLEET_SCRUBBER_DIR` env override → `<repo-root>/web/fleet-scrubber`.
/// Returns `None` when the resolved directory does not exist on disk so the
/// router silently skips the mount instead of 500-ing on startup. INFRA-2189.
fn resolve_scrubber_dir() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var("CHUMP_FLEET_SCRUBBER_DIR") {
        if !p.is_empty() {
            let pb = std::path::PathBuf::from(p);
            return pb.is_dir().then_some(pb);
        }
    }
    let candidate = resolve_repo_root().join("web").join("fleet-scrubber");
    candidate.is_dir().then_some(candidate)
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
            eprintln!("[chump-fleet-server] runtime init failed: {err}");
            return ExitCode::from(1);
        }
    };

    rt.block_on(async {
        match run().await {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("[chump-fleet-server] {err}");
                ExitCode::from(1)
            }
        }
    })
}

async fn run() -> anyhow::Result<()> {
    let port: u16 = std::env::var("CHUMP_FLEET_SERVER_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(7070);

    let db_path = resolve_db_path();
    tracing::info!(
        port,
        db = %db_path.display(),
        "chump-fleet-server starting"
    );

    let store = Arc::new(db::FleetStore::open(&db_path)?);

    // Spawn the background segmenter task (runs every 10s).
    let seg_store = Arc::clone(&store);
    tokio::spawn(async move {
        segmenter::run_segmenter_loop(seg_store).await;
    });

    let scrubber_dir = resolve_scrubber_dir();
    if let Some(ref d) = scrubber_dir {
        tracing::info!(scrubber_dir = %d.display(), "scrubber SPA mounted at /scrubber");
    } else {
        tracing::warn!("scrubber dir not found — /scrubber will 404 (set CHUMP_FLEET_SCRUBBER_DIR to override)");
    }
    let router = routes::build_router(Arc::clone(&store), scrubber_dir);

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
