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
//! - `GET /api/dashboard-summary` (INFRA-1883)
//! - `GET /api/gaps` (RESILIENT-1030, authed) — open-gap queue state.
//! - `POST /api/gap` (authed) — reserve/set/ship gap mutation.
//! - `POST /api/mission` (authed) — external mission intake.
//! - `WS  /api/live`
//!
//! ## Env vars
//!
//! - `CHUMP_FLEET_SERVER_PORT` (default `7070`) — port to bind.
//! - `CHUMP_FLEET_SERVER_BIND` (default `127.0.0.1`, RESILIENT-1030) —
//!   bind address. Set to a tailnet IP (e.g. the host's `100.x.y.z`
//!   Tailscale address) to expose the create API + fleet-server to the
//!   operator's other machines instead of only localhost. The mutating
//!   routes (`/api/mission`, `/api/gap`) and the new `/api/gaps` read route
//!   are already fail-closed behind `CHUMP_BATPHONE_TOKEN`; binding wider
//!   than localhost does NOT add auth to the other (unauthenticated)
//!   dashboard/events/segments routes, so only bind non-localhost on a
//!   private tailnet, never a public interface.
//! - `CHUMP_FLEET_DB` (optional) — override `.chump/fleet_events.db`.
//! - `CHUMP_REPO_ROOT` (optional) — override the repo root for dashboard-summary reads.

use std::process::ExitCode;
use std::sync::Arc;

use chump_fleet_server::{dashboard, db, routes, segmenter};

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

/// RESILIENT-1030: resolve the bind address from `CHUMP_FLEET_SERVER_BIND`,
/// falling back to localhost-only when unset, empty, or unparseable.
/// Pure and unit-testable so the fallback-on-bad-input behavior is covered
/// without spinning up a real listener.
fn resolve_bind_ip(env_val: Option<&str>) -> std::net::IpAddr {
    env_val
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .and_then(|s| s.parse().ok())
        .unwrap_or(std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1)))
}

fn resolve_db_path() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("CHUMP_FLEET_DB") {
        if !p.is_empty() {
            return std::path::PathBuf::from(p);
        }
    }
    resolve_repo_root().join(".chump").join("fleet_events.db")
}

fn main() -> ExitCode {
    // INFRA-2205: minimal hand-rolled CLI arg parsing — no clap dep.
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!(
            "chump-fleet-server — fleet visualization HTTP + WebSocket query server (INFRA-2175)."
        );
        println!();
        println!("Usage: chump-fleet-server [--port N] [--help] [--version]");
        println!();
        println!("Env vars:");
        println!("  CHUMP_FLEET_SERVER_PORT  (default 7070)");
        println!("  CHUMP_FLEET_SERVER_BIND  (default 127.0.0.1; RESILIENT-1030 tailnet exposure)");
        println!("  CHUMP_FLEET_DB           (default <repo>/.chump/fleet_events.db)");
        println!(
            "  CHUMP_FLEET_SCRUBBER_DIR (default <repo>/web/fleet-scrubber; mounted at /scrubber)"
        );
        return ExitCode::SUCCESS;
    }
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("chump-fleet-server {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }
    // Optional --port N (alternative to CHUMP_FLEET_SERVER_PORT env var).
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
            eprintln!("[chump-fleet-server] runtime init failed: {err}");
            return ExitCode::from(1);
        }
    };

    rt.block_on(async {
        match run(port_override).await {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("[chump-fleet-server] {err}");
                ExitCode::from(1)
            }
        }
    })
}

async fn run(port_override: Option<u16>) -> anyhow::Result<()> {
    let port: u16 = port_override
        .or_else(|| {
            std::env::var("CHUMP_FLEET_SERVER_PORT")
                .ok()
                .and_then(|p| p.parse().ok())
        })
        .unwrap_or(7070);

    let db_path = resolve_db_path();

    // Repo root for dashboard-summary reads (ambient.jsonl, github_cache.db,
    // .chump-locks/claim-*.json). `CHUMP_REPO_ROOT` overrides the git probe.
    let repo_root = if let Ok(p) = std::env::var("CHUMP_REPO_ROOT") {
        if !p.is_empty() {
            std::path::PathBuf::from(p)
        } else {
            dashboard::repo_root()
        }
    } else {
        dashboard::repo_root()
    };

    tracing::info!(
        port,
        db = %db_path.display(),
        repo_root = %repo_root.display(),
        "chump-fleet-server starting"
    );

    let store = Arc::new(db::FleetStore::open(&db_path)?);

    // Spawn the background segmenter task (runs every 10s).
    let seg_store = Arc::clone(&store);
    tokio::spawn(async move {
        segmenter::run_segmenter_loop(seg_store).await;
    });

    let router = routes::build_router(Arc::clone(&store), repo_root);

    // RESILIENT-1030: bind address is now configurable via
    // CHUMP_FLEET_SERVER_BIND (defaults to localhost-only, unchanged from
    // before). Set it to a tailnet IP to expose the authed mutating routes
    // + /api/gaps beyond localhost — see the module doc comment above for
    // the caveat about the still-unauthenticated dashboard/events routes.
    let bind_env = std::env::var("CHUMP_FLEET_SERVER_BIND").ok();
    let ip = resolve_bind_ip(bind_env.as_deref());
    let addr = std::net::SocketAddr::from((ip, port));
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

#[cfg(test)]
mod tests {
    use super::*;

    // RESILIENT-1030: CHUMP_FLEET_SERVER_BIND lets the operator expose the
    // fleet-server on a tailnet IP; unset/empty/garbage must still fall
    // back to the safe localhost-only default.
    #[test]
    fn resolve_bind_ip_defaults_to_localhost_when_unset() {
        assert_eq!(
            resolve_bind_ip(None),
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1))
        );
    }

    #[test]
    fn resolve_bind_ip_defaults_to_localhost_when_empty_or_garbage() {
        assert_eq!(
            resolve_bind_ip(Some("")),
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1))
        );
        assert_eq!(
            resolve_bind_ip(Some("not-an-ip")),
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1))
        );
    }

    #[test]
    fn resolve_bind_ip_honors_a_configured_tailnet_ip() {
        assert_eq!(
            resolve_bind_ip(Some("100.64.1.2")),
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(100, 64, 1, 2))
        );
    }
}
