//! chump-coord — CLI for the NATS atomic coordination layer.
//!
//! All commands degrade gracefully when NATS is unreachable (exit 0 with a
//! warning), so shell scripts can use `chump-coord ping` as a guard and fall
//! back to file-based leases when NATS is down.
//!
//! Commands:
//!   ping                       — check NATS reachability (exit 0 = up)
//!   claim <gap-id>             — atomic claim (exit 0 = won, 1 = lost to another session)
//!   release <gap-id>           — release claim
//!   status                     — show all active claims + recent events
//!   emit <type> [key=value …]  — publish a structured event
//!   watch                      — stream live events (ctrl-c to stop)
//!
//! Environment:
//!   CHUMP_NATS_URL             — default nats://127.0.0.1:4222
//!   CHUMP_SESSION_ID           — your session identity (falls back to UUID)
//!   CHUMP_COORD_FILES          — comma-separated file hints for claim command

use anyhow::Result;
use chump_coord::{CoordClient, CoordEvent};
use std::env;

fn session_id() -> String {
    // Priority mirrors gap-claim.sh: explicit > CLAUDE_SESSION_ID > UUID
    env::var("CHUMP_SESSION_ID")
        .or_else(|_| env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| {
            // Stable per-worktree ID from cache file if present
            let wt_cache = std::path::PathBuf::from(
                std::process::Command::new("git")
                    .args(["rev-parse", "--show-toplevel"])
                    .output()
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                    .unwrap_or_default(),
            )
            .join(".chump-locks/.wt-session-id");
            if let Ok(id) = std::fs::read_to_string(&wt_cache) {
                let id = id.trim().to_string();
                if !id.is_empty() {
                    return id;
                }
            }
            uuid::Uuid::new_v4().to_string()
        })
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("help");

    match cmd {
        // ── ping ─────────────────────────────────────────────────────────────
        "ping" => match CoordClient::connect().await {
            Ok(c) if c.ping().await => {
                println!(
                    "[chump-coord] NATS OK ({})",
                    env::var("CHUMP_NATS_URL")
                        .unwrap_or_else(|_| chump_coord::DEFAULT_NATS_URL.to_string())
                );
                std::process::exit(0);
            }
            Ok(_) => {
                eprintln!("[chump-coord] NATS connected but ping failed");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("[chump-coord] NATS unreachable: {}", e);
                std::process::exit(1);
            }
        },

        // ── claim ─────────────────────────────────────────────────────────────
        "claim" => {
            let gap_id = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
                eprintln!("Usage: chump-coord claim <gap-id>");
                std::process::exit(2);
            });
            let sess = session_id();
            let files_env = env::var("CHUMP_COORD_FILES").unwrap_or_default();
            let files: Vec<&str> = files_env
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .collect();

            match CoordClient::connect_or_skip().await {
                None => {
                    // NATS down — can't atomically claim; caller falls back to files.
                    // Exit 0 so gap-claim.sh continues with file-based lease.
                    eprintln!(
                        "[chump-coord] NATS unavailable — skipping atomic claim for {}",
                        gap_id
                    );
                    std::process::exit(0);
                }
                Some(c) => {
                    match c.try_claim_gap_with_files(gap_id, &sess, &files).await {
                        Ok(true) => {
                            println!(
                                "[chump-coord] CLAIMED {} (session={})",
                                gap_id,
                                &sess[..16.min(sess.len())]
                            );
                            // Also emit INTENT to JetStream for real-time fanout
                            let _ = c.emit_intent(&sess, gap_id, &files_env).await;

                            std::process::exit(0);
                        }
                        Ok(false) => {
                            // Find out who holds it
                            let holder = c
                                .gap_claim(gap_id)
                                .await
                                .ok()
                                .flatten()
                                .map(|cl| cl.session_id)
                                .unwrap_or_else(|| "unknown".to_string());
                            eprintln!(
                                "[chump-coord] CONFLICT: {} already claimed by session '{}'",
                                gap_id,
                                &holder[..16.min(holder.len())]
                            );

                            std::process::exit(1);
                        }
                        Err(e) => {
                            eprintln!("[chump-coord] Claim error (falling back to file): {}", e);

                            // Exit 0 — file-based fallback should proceed
                            std::process::exit(0);
                        }
                    }
                }
            }
        }

        // ── release ───────────────────────────────────────────────────────────
        "release" => {
            let gap_id = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
                eprintln!("Usage: chump-coord release <gap-id>");
                std::process::exit(2);
            });
            match CoordClient::connect_or_skip().await {
                None => {
                    eprintln!("[chump-coord] NATS unavailable — can't release {}", gap_id);
                    std::process::exit(0);
                }
                Some(c) => {
                    c.release_gap(gap_id).await?;
                    println!("[chump-coord] RELEASED {}", gap_id);
                }
            }
        }

        // ── status ────────────────────────────────────────────────────────────
        "status" => match CoordClient::connect_or_skip().await {
            None => {
                eprintln!("[chump-coord] NATS unavailable — no atomic claim status");
                std::process::exit(0);
            }
            Some(c) => {
                let claims = c.list_gap_claims().await.unwrap_or_default();
                if claims.is_empty() {
                    println!("[chump-coord] No active atomic gap claims in NATS KV.");
                } else {
                    println!("[chump-coord] Active gap claims ({}):", claims.len());
                    for (gap_id, claim) in &claims {
                        println!(
                            "  {:12}  session={:<20}  claimed={}",
                            gap_id,
                            &claim.session_id[..20.min(claim.session_id.len())],
                            claim.claimed_at
                        );
                        if !claim.files.is_empty() {
                            println!("             files: {}", claim.files.join(", "));
                        }
                    }
                }
            }
        },

        // ── emit ──────────────────────────────────────────────────────────────
        // Usage: chump-coord emit INTENT gap=COG-016 files=src/reflection.rs
        //        chump-coord emit DONE   gap=COG-016 commit=abc123
        //        chump-coord emit STUCK  gap=COG-016 reason="cargo check fails"
        "emit" => {
            let event_type = args.get(2).map(|s| s.to_uppercase()).unwrap_or_else(|| {
                eprintln!("Usage: chump-coord emit <TYPE> [key=value ...]");
                std::process::exit(2);
            });
            let sess = session_id();

            // Parse key=value pairs from remaining args
            let mut gap: Option<String> = None;
            let mut files: Option<String> = None;
            let mut reason: Option<String> = None;
            let mut commit: Option<String> = None;
            let mut kind: Option<String> = None;
            let mut to: Option<String> = None;

            for kv_arg in &args[3..] {
                if let Some((k, v)) = kv_arg.split_once('=') {
                    match k {
                        "gap" => gap = Some(v.to_string()),
                        "files" => files = Some(v.to_string()),
                        "reason" => reason = Some(v.to_string()),
                        "commit" => commit = Some(v.to_string()),
                        "kind" => kind = Some(v.to_string()),
                        "to" => to = Some(v.to_string()),
                        _ => {}
                    }
                }
            }

            let event = CoordEvent {
                event: event_type.clone(),
                session: sess,
                ts: chrono::Utc::now().to_rfc3339(),
                gap,
                files,
                reason,
                commit,
                kind,
                to,
            };

            match CoordClient::connect_or_skip().await {
                None => {
                    eprintln!("[chump-coord] NATS unavailable — event not published to JetStream");
                    std::process::exit(0);
                }
                Some(c) => {
                    c.emit(event).await?;
                    println!("[chump-coord] EMITTED {}", event_type);
                }
            }
        }

        // ── watch ─────────────────────────────────────────────────────────────
        "watch" => {
            use futures::StreamExt;

            match CoordClient::connect_or_skip().await {
                None => {
                    eprintln!("[chump-coord] NATS unavailable — cannot watch events");
                    std::process::exit(1);
                }
                Some(c) => {
                    println!("[chump-coord] Watching chump.events.> (ctrl-c to stop)");
                    let mut sub = c.nats.subscribe("chump.events.>").await?;
                    while let Some(msg) = sub.next().await {
                        let subject = &msg.subject;
                        let payload = String::from_utf8_lossy(&msg.payload);
                        if let Ok(event) = serde_json::from_str::<CoordEvent>(&payload) {
                            println!(
                                "{:25}  {:<12}  session={:<16}  gap={:<12}  {}",
                                event.ts,
                                event.event,
                                &event.session[..16.min(event.session.len())],
                                event.gap.as_deref().unwrap_or("—"),
                                event
                                    .reason
                                    .as_deref()
                                    .or(event.commit.as_deref())
                                    .or(event.files.as_deref())
                                    .unwrap_or("")
                            );
                        } else {
                            println!("{}: {}", subject, payload);
                        }
                    }
                }
            }
        }

        // ── help / default ────────────────────────────────────────────────────
        _ => {
            eprintln!(
                r#"chump-coord — NATS atomic coordination layer (Phase 1)

COMMANDS
  ping                       Check NATS reachability (exit 0 = up)
  claim <gap-id>             Atomic CAS claim (exit 0 = won, 1 = conflict)
  release <gap-id>           Release gap claim
  status                     Show all active NATS KV claims
  emit <TYPE> [key=value …]  Publish event (TYPE: INTENT DONE STUCK WARN ALERT)
  watch                      Stream live events from chump.events.>

ENVIRONMENT
  CHUMP_NATS_URL             NATS server URL (default: nats://127.0.0.1:4222)
  CHUMP_SESSION_ID           Session identity (override)
  CHUMP_COORD_FILES          Comma-separated files for claim (optional)
  CHUMP_GAP_CLAIM_TTL_SECS   Claim TTL seconds (default: 14400 = 4h)
  CHUMP_NATS_TIMEOUT_MS      Connect timeout ms (default: 500)

INTEGRATION
  gap-claim.sh calls 'chump-coord claim' before writing file leases.
  If NATS is unreachable, exit 0 is returned and file-based leases proceed.

  gap-preflight.sh can call 'chump-coord status' to check atomic claims.
  broadcast.sh calls 'chump-coord emit' alongside ambient.jsonl writes.
"#
            );
        }
    }

    Ok(())
}
