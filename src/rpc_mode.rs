//! Headless JSONL RPC mode over stdin/stdout.
//!
//! Goal: let external automation drive Chump deterministically:
//! - send `prompt` commands (with optional session_id + bot)
//! - receive a JSONL stream of `AgentEvent` objects (same as web SSE payloads)
//! - resolve tool approvals by sending `approve` commands (request_id + allowed)
//!
//! This intentionally reuses `stream_events::AgentEvent` as the wire event shape.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::io::{self, BufRead, Write};
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::agent_loop::ChumpAgent;
use crate::approval_resolver;
use crate::agent_factory;
use crate::limits;
use crate::stream_events::{self, AgentEvent};
use crate::streaming_provider::StreamingProvider;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RpcCommand {
    /// Start a single agent turn. Events stream to stdout as JSONL lines.
    Prompt {
        message: String,
        #[serde(default)]
        session_id: Option<String>,
        /// "chump" | "mabel"
        #[serde(default)]
        bot: Option<String>,
        /// Optional opaque id echoed back in events envelope.
        #[serde(default)]
        id: Option<String>,
        /// Optional max tool iterations (clamped internally).
        #[serde(default)]
        max_iterations: Option<usize>,
    },
    /// Resolve a pending tool approval request.
    Approve {
        request_id: String,
        allowed: bool,
        #[serde(default)]
        id: Option<String>,
    },
    /// Ping for health / liveness.
    Ping {
        #[serde(default)]
        id: Option<String>,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RpcOut {
    RpcReady {
        protocol: u32,
    },
    Pong {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
    Ack {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
    Error {
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
    /// Wrap an AgentEvent so callers can correlate with a request id (optional).
    Event {
        event: AgentEvent,
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
}

fn append_rpc_jsonl_log_line(line: &str) {
    let Ok(path) = std::env::var("CHUMP_RPC_JSONL_LOG") else {
        return;
    };
    if path.trim().is_empty() {
        return;
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path.trim())
    {
        if let Err(e) = writeln!(f, "{}", line) {
            tracing::warn!("rpc_mode: failed to write JSONL log line: {e}");
        }
    }
}

fn write_jsonl<T: Serialize>(out: &T) -> Result<()> {
    let line = serde_json::to_string(out)?;
    append_rpc_jsonl_log_line(&line);
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{}", line)?;
    stdout.flush()?;
    Ok(())
}

/// Run the JSONL RPC loop. Reads stdin lines; writes stdout lines.
pub async fn run_rpc_loop() -> Result<()> {
    // Protocol marker
    write_jsonl(&RpcOut::RpcReady { protocol: 1 })?;

    // Only allow one active prompt at a time in a single process.
    let active_turn: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));

    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = line.map_err(|e| anyhow!("stdin read error: {}", e))?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let cmd: RpcCommand = match serde_json::from_str(line) {
            Ok(c) => c,
            Err(e) => {
                write_jsonl(&RpcOut::Error {
                    message: format!("invalid json: {}", e),
                    id: None,
                })?;
                continue;
            }
        };

        match cmd {
            RpcCommand::Ping { id } => {
                write_jsonl(&RpcOut::Pong { id })?;
            }

            RpcCommand::Approve {
                request_id,
                allowed,
                id,
            } => {
                let rid = request_id.trim();
                if rid.is_empty() {
                    write_jsonl(&RpcOut::Error {
                        message: "missing request_id".to_string(),
                        id,
                    })?;
                    continue;
                }
                approval_resolver::resolve_approval(rid, allowed);
                write_jsonl(&RpcOut::Ack { id })?;
            }

            RpcCommand::Prompt {
                message,
                session_id,
                bot,
                id,
                max_iterations,
            } => {
                let msg = message.trim().to_string();
                if msg.is_empty() {
                    write_jsonl(&RpcOut::Error {
                        message: "empty message".to_string(),
                        id,
                    })?;
                    continue;
                }
                if let Err(e) = limits::check_message_len(&msg) {
                    write_jsonl(&RpcOut::Error { message: e, id })?;
                    continue;
                }

                // Enforce single active turn.
                {
                    let mut guard = active_turn.lock().await;
                    if *guard {
                        write_jsonl(&RpcOut::Error {
                            message: "turn already in progress".to_string(),
                            id,
                        })?;
                        continue;
                    }
                    *guard = true;
                }

                let sid = session_id
                    .as_deref()
                    .unwrap_or("default")
                    .trim()
                    .to_string();
                let bot = bot.as_deref();
                let max_iterations = max_iterations.unwrap_or(10);

                let (event_tx, mut event_rx) = stream_events::event_channel();
                // Emit the same session-ready event the PWA gets, so clients can persist it.
                if let Err(e) = event_tx.send(AgentEvent::WebSessionReady {
                    session_id: sid.clone(),
                }) {
                    tracing::warn!("rpc_mode: failed to send WebSessionReady event: {e}");
                }

                let built = agent_factory::build_chump_agent_web_components(&sid, bot)?;
                #[cfg(feature = "mistralrs-infer")]
                let streaming_provider = StreamingProvider::new_with_mistral_stream(
                    built.provider,
                    built.mistral_for_stream,
                    event_tx.clone(),
                );
                #[cfg(not(feature = "mistralrs-infer"))]
                let streaming_provider = StreamingProvider::new(built.provider, event_tx.clone());

                let agent = ChumpAgent::new(
                    Box::new(streaming_provider),
                    built.registry,
                    Some(built.system_prompt),
                    Some(built.session_manager),
                    Some(event_tx),
                    max_iterations,
                );

                let active_turn_done = active_turn.clone();
                let msg_clone = msg.clone();
                tokio::spawn(async move {
                    if let Err(e) = agent.run(&msg_clone).await {
                        tracing::warn!("rpc_mode: agent.run failed: {e}");
                    }
                    let mut guard = active_turn_done.lock().await;
                    *guard = false;
                });

                while let Some(ev) = event_rx.recv().await {
                    // Mirror web: emit events as they arrive, but wrap so we can include `id`.
                    let done = matches!(
                        ev,
                        AgentEvent::TurnComplete { .. } | AgentEvent::TurnError { .. }
                    );
                    write_jsonl(&RpcOut::Event {
                        event: ev,
                        id: id.clone(),
                    })?;
                    // Stop once the turn completes or errors.
                    if done {
                        break;
                    }
                }
            }
        }
    }
    Ok(())
}
