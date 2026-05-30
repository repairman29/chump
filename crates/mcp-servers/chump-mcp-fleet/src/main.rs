//! chump-mcp-fleet — MCP server binary entry point.
//!
//! Gates on `CHUMP_FLEET_WIRE_V1=1`; exits 0 with an informational message if
//! the flag is absent so callers that haven't opted in don't need to gate.
//!
//! Transport selection:
//! - `--socket` flag OR `CHUMP_FLEET_TRANSPORT=socket` → Unix socket mode
//! - default → stdio mode (Claude Code `mcpServers` launch)

use anyhow::Result;
use tracing::info;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialise tracing to stderr so stdout stays clean for JSON-RPC traffic.
    // RUST_LOG controls verbosity; default is INFO.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    // Feature flag gate (AC: CHUMP_FLEET_WIRE_V1=1 required)
    if std::env::var("CHUMP_FLEET_WIRE_V1").as_deref() != Ok("1") {
        eprintln!(
            "[chump-mcp-fleet] CHUMP_FLEET_WIRE_V1 not set — server not started. \
             Set CHUMP_FLEET_WIRE_V1=1 to enable the fleet MCP surface (META-167-h)."
        );
        return Ok(());
    }

    let args: Vec<String> = std::env::args().collect();
    let use_socket = args.iter().any(|a| a == "--socket")
        || std::env::var("CHUMP_FLEET_TRANSPORT").as_deref() == Ok("socket");

    info!(
        version = env!("CARGO_PKG_VERSION"),
        transport = if use_socket { "unix_socket" } else { "stdio" },
        "chump-mcp-fleet initialising"
    );

    if use_socket {
        chump_mcp_fleet::server::run_unix_socket().await
    } else {
        chump_mcp_fleet::server::run_stdio().await
    }
}
