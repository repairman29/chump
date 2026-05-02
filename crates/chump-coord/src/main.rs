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
//!   work-board <sub> [args …]  — FLEET-008 shared subtask queue (post|list|claim|complete|fail|show)
//!   help-request <sub> [args …] — FLEET-010 help-seeking protocol (post|list|claim|complete|fail|show)
//!
//! Environment:
//!   CHUMP_NATS_URL             — default nats://127.0.0.1:4222
//!   CHUMP_SESSION_ID           — your session identity (falls back to UUID)
//!   CHUMP_COORD_FILES          — comma-separated file hints for claim command

use anyhow::Result;
use chump_coord::help_request::{BlockerType, HelpRequest, HelpStatus};
use chump_coord::work_board::{Requirement, Subtask, SubtaskStatus, TransitionMiss};
use chump_coord::{CoordClient, CoordEvent};
use std::env;

fn print_transition_miss(verb: &str, id: &str, miss: &TransitionMiss) {
    match miss {
        TransitionMiss::NotFound => {
            eprintln!("[chump-coord] cannot {} {}: not found", verb, id);
        }
        TransitionMiss::StaleRevision => {
            eprintln!(
                "[chump-coord] cannot {} {}: another agent updated it first (stale revision)",
                verb, id
            );
        }
        TransitionMiss::WrongState(s) => {
            eprintln!(
                "[chump-coord] cannot {} {}: subtask is in state {:?}, not the expected state",
                verb, id, s
            );
        }
        TransitionMiss::NotClaimHolder { holder, caller } => {
            eprintln!(
                "[chump-coord] cannot {} {}: claim is held by {} but caller is {}",
                verb, id, holder, caller
            );
        }
    }
}

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

        // ── work-board ────────────────────────────────────────────────────────
        // Usage:
        //   chump-coord work-board post <parent-gap> <task-class> "<title>" [--decomposable] [--description "..."] [--est-secs N]
        //   chump-coord work-board list [--status open|claimed|completed|failed|all]
        //   chump-coord work-board claim <subtask-id>
        //   chump-coord work-board complete <subtask-id> [--commit <sha-or-pr>]
        //   chump-coord work-board fail <subtask-id> --reason "..."
        //   chump-coord work-board show <subtask-id>
        "work-board" => {
            let sub = args.get(2).map(|s| s.as_str()).unwrap_or("");
            let client = match CoordClient::connect_or_skip().await {
                Some(c) => c,
                None => {
                    eprintln!(
                        "[chump-coord] NATS unavailable — work-board requires a reachable broker"
                    );
                    std::process::exit(1);
                }
            };
            match sub {
                "post" => {
                    let parent_gap = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord work-board post <parent-gap> <task-class> \"<title>\" [flags…]");
                        std::process::exit(2);
                    });
                    let task_class = args.get(4).cloned().unwrap_or_else(|| {
                        eprintln!("Missing <task-class>");
                        std::process::exit(2);
                    });
                    let title = args.get(5).cloned().unwrap_or_else(|| {
                        eprintln!("Missing \"<title>\"");
                        std::process::exit(2);
                    });
                    // Optional flags after the positionals.
                    let mut description = String::new();
                    let mut decomposable = false;
                    let mut est_secs: Option<u32> = None;
                    let mut required_model: Option<String> = None;
                    let mut min_vram: Option<u32> = None;
                    let mut i = 6;
                    while i < args.len() {
                        match args[i].as_str() {
                            "--decomposable" => decomposable = true,
                            "--description" => {
                                i += 1;
                                description = args.get(i).cloned().unwrap_or_default();
                            }
                            "--est-secs" => {
                                i += 1;
                                est_secs = args.get(i).and_then(|s| s.parse().ok());
                            }
                            "--model" => {
                                i += 1;
                                required_model = args.get(i).cloned();
                            }
                            "--min-vram-gb" => {
                                i += 1;
                                min_vram = args.get(i).and_then(|s| s.parse().ok());
                            }
                            other => {
                                eprintln!("Unknown flag: {}", other);
                                std::process::exit(2);
                            }
                        }
                        i += 1;
                    }
                    let req = Requirement {
                        task_class,
                        required_model_family: required_model,
                        min_vram_gb: min_vram,
                        min_inference_speed_tok_per_sec: None,
                        estimated_duration_sec: est_secs,
                        decomposable,
                    };
                    let mut subtask = Subtask::new(&parent_gap, &title, &session_id(), req);
                    subtask.description = description;
                    client.post_subtask(&subtask).await?;
                    println!("{}", subtask.subtask_id);
                }
                "list" => {
                    let mut filter: Option<SubtaskStatus> = Some(SubtaskStatus::Open);
                    let mut i = 3;
                    while i < args.len() {
                        match args[i].as_str() {
                            "--status" => {
                                i += 1;
                                filter = match args.get(i).map(|s| s.as_str()) {
                                    Some("open") => Some(SubtaskStatus::Open),
                                    Some("claimed") => Some(SubtaskStatus::Claimed),
                                    Some("completed") => Some(SubtaskStatus::Completed),
                                    Some("failed") => Some(SubtaskStatus::Failed),
                                    Some("all") => None,
                                    Some(other) => {
                                        eprintln!("Unknown status: {}", other);
                                        std::process::exit(2);
                                    }
                                    None => Some(SubtaskStatus::Open),
                                };
                            }
                            other => {
                                eprintln!("Unknown flag: {}", other);
                                std::process::exit(2);
                            }
                        }
                        i += 1;
                    }
                    let subtasks = client.list_subtasks(filter).await?;
                    if subtasks.is_empty() {
                        println!("[chump-coord] No subtasks match.");
                    } else {
                        println!(
                            "{:<22} {:<14} {:<10} {:<22} title",
                            "subtask_id", "parent_gap", "status", "task_class"
                        );
                        for s in subtasks {
                            println!(
                                "{:<22} {:<14} {:<10} {:<22} {}",
                                s.subtask_id,
                                s.parent_gap,
                                format!("{:?}", s.status).to_lowercase(),
                                s.requirement.task_class,
                                s.title
                            );
                        }
                    }
                }
                "claim" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord work-board claim <subtask-id>");
                        std::process::exit(2);
                    });
                    let sess = session_id();
                    match client.claim_subtask(&id, &sess).await? {
                        Ok(s) => {
                            println!(
                                "[chump-coord] CLAIMED {} (parent={}, task_class={})",
                                s.subtask_id, s.parent_gap, s.requirement.task_class
                            );
                        }
                        Err(miss) => {
                            print_transition_miss("claim", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "complete" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!(
                            "Usage: chump-coord work-board complete <subtask-id> [--commit <sha>]"
                        );
                        std::process::exit(2);
                    });
                    let mut commit: Option<String> = None;
                    let mut i = 4;
                    while i < args.len() {
                        if args[i] == "--commit" {
                            i += 1;
                            commit = args.get(i).cloned();
                        }
                        i += 1;
                    }
                    let sess = session_id();
                    match client
                        .complete_subtask(&id, &sess, commit.as_deref())
                        .await?
                    {
                        Ok(s) => println!(
                            "[chump-coord] COMPLETED {} (parent={})",
                            s.subtask_id, s.parent_gap
                        ),
                        Err(miss) => {
                            print_transition_miss("complete", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "fail" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!(
                            "Usage: chump-coord work-board fail <subtask-id> --reason \"...\""
                        );
                        std::process::exit(2);
                    });
                    let mut reason = String::new();
                    let mut i = 4;
                    while i < args.len() {
                        if args[i] == "--reason" {
                            i += 1;
                            reason = args.get(i).cloned().unwrap_or_default();
                        }
                        i += 1;
                    }
                    if reason.is_empty() {
                        eprintln!("--reason is required");
                        std::process::exit(2);
                    }
                    let sess = session_id();
                    match client.fail_subtask(&id, &sess, &reason).await? {
                        Ok(s) => {
                            println!("[chump-coord] FAILED {} (reason={})", s.subtask_id, reason)
                        }
                        Err(miss) => {
                            print_transition_miss("fail", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "show" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord work-board show <subtask-id>");
                        std::process::exit(2);
                    });
                    match client.get_subtask(&id).await? {
                        Some(s) => println!("{}", serde_json::to_string_pretty(&s)?),
                        None => {
                            eprintln!("[chump-coord] not found: {}", id);
                            std::process::exit(1);
                        }
                    }
                }
                _ => {
                    eprintln!(
                        "Usage: chump-coord work-board {{post|list|claim|complete|fail|show}} …"
                    );
                    std::process::exit(2);
                }
            }
        }

        // ── help-request (FLEET-010) ─────────────────────────────────────────
        // Usage:
        //   chump-coord help-request post <blocker-type> "<description>" \
        //       [--parent-subtask SUBTASK-…] [--parent-gap FLEET-…] \
        //       [--needed-capability "..."] [--blocking]
        //   chump-coord help-request list [--status open|claimed|completed|failed|all] \
        //       [--parent-subtask SUBTASK-…] [--parent-gap FLEET-…]
        //   chump-coord help-request claim    <help-id>
        //   chump-coord help-request complete <help-id> [--resolution "..."]
        //   chump-coord help-request fail     <help-id> --reason "..."
        //   chump-coord help-request show     <help-id>
        "help-request" => {
            let sub = args.get(2).map(|s| s.as_str()).unwrap_or("");
            let client = match CoordClient::connect_or_skip().await {
                Some(c) => c,
                None => {
                    eprintln!(
                        "[chump-coord] NATS unavailable — help-request requires a reachable broker"
                    );
                    std::process::exit(1);
                }
            };
            match sub {
                "post" => {
                    let blocker_arg = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request post <blocker-type> \"<description>\" [flags…]");
                        eprintln!("  blocker-type: timeout | missing_capability | unknown_task_class | other");
                        std::process::exit(2);
                    });
                    let description = args.get(4).cloned().unwrap_or_else(|| {
                        eprintln!("Missing \"<description>\"");
                        std::process::exit(2);
                    });
                    let blocker_type = match blocker_arg.as_str() {
                        "timeout" => BlockerType::Timeout,
                        "missing_capability" => BlockerType::MissingCapability,
                        "unknown_task_class" => BlockerType::UnknownTaskClass,
                        "other" => BlockerType::Other,
                        other => {
                            eprintln!(
                                "Unknown blocker-type: {} (expected timeout|missing_capability|unknown_task_class|other)",
                                other
                            );
                            std::process::exit(2);
                        }
                    };
                    let mut req = HelpRequest::new(blocker_type, &description, &session_id());
                    let mut i = 5;
                    while i < args.len() {
                        match args[i].as_str() {
                            "--parent-subtask" => {
                                i += 1;
                                if let Some(v) = args.get(i) {
                                    req.parent_subtask = Some(v.clone());
                                }
                            }
                            "--parent-gap" => {
                                i += 1;
                                if let Some(v) = args.get(i) {
                                    req.parent_gap = Some(v.clone());
                                }
                            }
                            "--needed-capability" => {
                                i += 1;
                                if let Some(v) = args.get(i) {
                                    req.needed_capability = Some(v.clone());
                                }
                            }
                            "--blocking" => req.blocking = true,
                            other => {
                                eprintln!("Unknown flag: {}", other);
                                std::process::exit(2);
                            }
                        }
                        i += 1;
                    }
                    client.post_help_request(&req).await?;
                    println!("{}", req.help_id);
                }
                "list" => {
                    let mut filter_status: Option<HelpStatus> = Some(HelpStatus::Open);
                    let mut filter_parent_subtask: Option<String> = None;
                    let mut filter_parent_gap: Option<String> = None;
                    let mut i = 3;
                    while i < args.len() {
                        match args[i].as_str() {
                            "--status" => {
                                i += 1;
                                filter_status = match args.get(i).map(|s| s.as_str()) {
                                    Some("open") => Some(HelpStatus::Open),
                                    Some("claimed") => Some(HelpStatus::Claimed),
                                    Some("completed") => Some(HelpStatus::Completed),
                                    Some("failed") => Some(HelpStatus::Failed),
                                    Some("all") => None,
                                    Some(other) => {
                                        eprintln!("Unknown status: {}", other);
                                        std::process::exit(2);
                                    }
                                    None => Some(HelpStatus::Open),
                                };
                            }
                            "--parent-subtask" => {
                                i += 1;
                                filter_parent_subtask = args.get(i).cloned();
                            }
                            "--parent-gap" => {
                                i += 1;
                                filter_parent_gap = args.get(i).cloned();
                            }
                            other => {
                                eprintln!("Unknown flag: {}", other);
                                std::process::exit(2);
                            }
                        }
                        i += 1;
                    }
                    let reqs = client
                        .list_help_requests(
                            filter_status,
                            filter_parent_subtask.as_deref(),
                            filter_parent_gap.as_deref(),
                        )
                        .await?;
                    if reqs.is_empty() {
                        println!("[chump-coord] No help requests match.");
                    } else {
                        println!(
                            "{:<14} {:<10} {:<22} {:<14} {:<14} description",
                            "help_id", "status", "blocker_type", "parent_gap", "parent_sub"
                        );
                        for r in reqs {
                            println!(
                                "{:<14} {:<10} {:<22} {:<14} {:<14} {}",
                                r.help_id,
                                format!("{:?}", r.status).to_lowercase(),
                                format!("{:?}", r.blocker_type).to_lowercase(),
                                r.parent_gap.unwrap_or_else(|| "—".to_string()),
                                r.parent_subtask.unwrap_or_else(|| "—".to_string()),
                                r.description
                            );
                        }
                    }
                }
                "claim" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request claim <help-id>");
                        std::process::exit(2);
                    });
                    let sess = session_id();
                    match client.claim_help_request(&id, &sess).await? {
                        Ok(r) => println!(
                            "[chump-coord] CLAIMED {} (blocker={:?}, description={})",
                            r.help_id, r.blocker_type, r.description
                        ),
                        Err(miss) => {
                            print_transition_miss("claim", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "complete" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request complete <help-id> [--resolution \"…\"]");
                        std::process::exit(2);
                    });
                    let mut resolution: Option<String> = None;
                    let mut i = 4;
                    while i < args.len() {
                        if args[i] == "--resolution" {
                            i += 1;
                            resolution = args.get(i).cloned();
                        }
                        i += 1;
                    }
                    let sess = session_id();
                    match client
                        .complete_help_request(&id, &sess, resolution.as_deref())
                        .await?
                    {
                        Ok(r) => println!(
                            "[chump-coord] COMPLETED {} (resolution={})",
                            r.help_id,
                            r.resolution.as_deref().unwrap_or("—")
                        ),
                        Err(miss) => {
                            print_transition_miss("complete", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "fail" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request fail <help-id> --reason \"…\"");
                        std::process::exit(2);
                    });
                    let mut reason = String::new();
                    let mut i = 4;
                    while i < args.len() {
                        if args[i] == "--reason" {
                            i += 1;
                            reason = args.get(i).cloned().unwrap_or_default();
                        }
                        i += 1;
                    }
                    if reason.is_empty() {
                        eprintln!("--reason is required");
                        std::process::exit(2);
                    }
                    let sess = session_id();
                    match client.fail_help_request(&id, &sess, &reason).await? {
                        Ok(r) => println!("[chump-coord] FAILED {} (reason={})", r.help_id, reason),
                        Err(miss) => {
                            print_transition_miss("fail", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "show" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request show <help-id>");
                        std::process::exit(2);
                    });
                    match client.get_help_request(&id).await? {
                        Some(r) => println!("{}", serde_json::to_string_pretty(&r)?),
                        None => {
                            eprintln!("[chump-coord] not found: {}", id);
                            std::process::exit(1);
                        }
                    }
                }
                _ => {
                    eprintln!(
                        "Usage: chump-coord help-request {{post|list|claim|complete|fail|show}} …"
                    );
                    std::process::exit(2);
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
  work-board <sub> [args …]  FLEET-008 shared subtask queue
                             post <parent-gap> <task-class> "<title>" [--decomposable] [--description "..."] [--est-secs N] [--model <fam>] [--min-vram-gb N]
                             list   [--status open|claimed|completed|failed|all]
                             claim    <subtask-id>
                             complete <subtask-id> [--commit <sha-or-pr>]
                             fail     <subtask-id> --reason "..."
                             show     <subtask-id>
  help-request <sub> [args …] FLEET-010 help-seeking protocol
                             post <blocker-type> "<description>" [--parent-subtask SUBTASK-…] [--parent-gap FLEET-…] [--needed-capability "…"] [--blocking]
                                  blocker-type: timeout|missing_capability|unknown_task_class|other
                             list   [--status open|claimed|completed|failed|all] [--parent-subtask …] [--parent-gap …]
                             claim    <help-id>
                             complete <help-id> [--resolution "…"]
                             fail     <help-id> --reason "…"
                             show     <help-id>

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
