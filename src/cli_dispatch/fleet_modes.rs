//! Fleet orchestration, level/stop/start, worker status, and capacity CLI subcommands.

#[allow(unused_imports)]
use super::*;
#[allow(unused_imports)]
use crate::*;
#[allow(unused_imports)]
use anyhow::{Context as _, Result};
#[allow(unused_imports)]
use axonerai::agent::Agent;
#[allow(unused_imports)]
use axonerai::file_session_manager::FileSessionManager;
#[allow(unused_imports)]
use axonerai::tool::ToolRegistry;
#[allow(unused_imports)]
use std::env;
#[allow(unused_imports)]
use std::io::{self, IsTerminal, Read, Write};

pub(crate) async fn dispatch_fleet(args: Vec<String>) -> Result<()> {
    if args.get(1).map(String::as_str) == Some("fleet") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let run_fleet_sh = repo_root.join("scripts/dispatch/run-fleet.sh");
        let fleet_status_sh = repo_root.join("scripts/dispatch/fleet-status.sh");
        // EFFECTIVE-025: CLI proxy for META-090 autopilot. Bash orchestrator
        // is the source of truth; this arm forwards subcommand + flags so the
        // operator gets identical UX from `chump fleet autopilot ...` and
        // direct `bash scripts/coord/fleet-autopilot.sh ...`.
        let fleet_autopilot_sh = repo_root.join("scripts/coord/fleet-autopilot.sh");
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };

        // Simple [fleet] section reader for ~/.chump/config.toml.
        let config_toml = std::env::var("HOME")
            .ok()
            .map(std::path::PathBuf::from)
            .map(|h| h.join(".chump/config.toml"))
            .and_then(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_default();
        let cfg = |key: &str| -> Option<String> {
            config_toml
                .lines()
                .find(|l| l.trim_start().starts_with(key))
                .and_then(|l| l.split_once('=').map(|x| x.1))
                .map(|v| v.trim().trim_matches('"').to_string())
                .filter(|v| !v.is_empty())
        };

        match subcmd {
            "start" => {
                let size = flag("--size")
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());
                let model = flag("--model")
                    .or_else(|| cfg("model"))
                    .unwrap_or_else(|| "sonnet".to_string());
                let effort = flag("--effort")
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s,m,l,xl".to_string());
                let domain = flag("--domain")
                    .or_else(|| cfg("domain"))
                    .unwrap_or_default();

                // INFRA-1052: harness selection — pair harness with model so the
                // operator can run `chump fleet start --harness opencode --model sonnet`
                // and have workers spawn opencode-flavored agents. CLAUDE.md INFRA-AUTH
                // precedence applies: CLI flag > env > config.toml > default. The
                // dispatcher half (INFRA-1045) reads FLEET_HARNESS in worker.sh.
                const KNOWN_HARNESSES: &[&str] = &["claude", "opencode", "codex", "manual"];
                let harness = flag("--harness")
                    .or_else(|| {
                        std::env::var("CHUMP_AGENT_HARNESS")
                            .ok()
                            .filter(|v| !v.is_empty())
                    })
                    .or_else(|| cfg("harness"))
                    .unwrap_or_else(|| "claude".to_string());
                if !KNOWN_HARNESSES.contains(&harness.as_str()) {
                    eprintln!(
                        "chump fleet start: unknown --harness '{harness}'. Known: {}",
                        KNOWN_HARNESSES.join(", ")
                    );
                    eprintln!("  (Add a new harness to scripts/dispatch/harnesses/<name>.sh per INFRA-1045.)");
                    std::process::exit(2);
                }

                // Persist last-used config for `chump fleet restart`.
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let last_config = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                let _ = std::fs::create_dir_all(
                    last_config.parent().unwrap_or(std::path::Path::new("/tmp")),
                );
                let _ = std::fs::write(
                    &last_config,
                    serde_json::to_string_pretty(&serde_json::json!({
                        "size": size,
                        "model": model,
                        "harness": harness,
                        "effort": effort,
                        "domain": domain,
                        "session": flag("--session").or_else(|| cfg("session")).unwrap_or_else(|| "chump-fleet".to_string()),
                        "updated_at": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                    }))
                    .unwrap_or_default(),
                );

                // RESILIENT-073: write AUTONOMY_LEVEL=5 so workers see GO
                // before the tmux session launches. Level 5 = full autonomy.
                let al_path = autonomy_level::default_path();
                match autonomy_level::write_level(5, &al_path) {
                    Ok(()) => eprintln!(
                        "chump fleet start: AUTONOMY_LEVEL=5 written to {}",
                        al_path.display()
                    ),
                    Err(e) => {
                        eprintln!("chump fleet start: WARNING: could not write AUTONOMY_LEVEL: {e}")
                    }
                }
                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_MODEL", &model)
                    .env("FLEET_HARNESS", &harness)
                    .env("FLEET_EFFORT_FILTER", &effort)
                    .env("FLEET_DOMAIN_FILTER", &domain)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet start: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            "stop" => {
                // RESILIENT-073: write AUTONOMY_LEVEL=0 FIRST — this is the
                // operator kill switch and must land before any tmux kill so
                // workers that survive the SIGTERM see STOP on their next tick.
                let al_path = autonomy_level::default_path();
                match autonomy_level::write_level(0, &al_path) {
                    Ok(()) => eprintln!(
                        "chump fleet stop: AUTONOMY_LEVEL=0 written to {}",
                        al_path.display()
                    ),
                    Err(e) => {
                        eprintln!("chump fleet stop: WARNING: could not write AUTONOMY_LEVEL: {e}");
                        eprintln!("  Fleet workers may not see the stop signal until the file is writable.");
                    }
                }
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", "0")
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet stop: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // RESILIENT-073: `chump fleet level <N>` — write an arbitrary
            // autonomy level (0 = STOP, 1-5 = graduated go). The graduated
            // dial (EFFECTIVE-086) layers nuance on top; this is the dumb
            // write that every entry-point checks.
            "level" => {
                // EFFECTIVE-086: query-only flags read the current level
                // and report a derived fact rather than writing anything.
                if args.iter().any(|a| a == "--max-workers") {
                    let level =
                        autonomy_level::read_autonomy_level(&autonomy_level::default_path());
                    match level.max_workers() {
                        Some(n) => println!("{n}"),
                        None => println!("unbounded"),
                    }
                    std::process::exit(0);
                }
                let n_str = args.get(3).cloned().unwrap_or_else(|| {
                    // No arg: print current level (name + number) and exit 0.
                    let level =
                        autonomy_level::read_autonomy_level(&autonomy_level::default_path());
                    println!("{} ({})", i64::from(level), level.name());
                    std::process::exit(0);
                });
                let n: i64 = n_str.parse().unwrap_or_else(|_| {
                    eprintln!("chump fleet level: N must be an integer, got '{n_str}'");
                    std::process::exit(2);
                });
                // EFFECTIVE-086: the graduated dial is 0-5 (STOP..UNLEASHED)
                // — reject anything outside that range so the dial can't be
                // set to a value with no defined action set.
                if !(0..=5).contains(&n) {
                    eprintln!(
                        "chump fleet level: N must be 0-5 (0=STOP 1=OBSERVE 2=ASSIST \
                         3=SUPERVISED 4=AUTONOMOUS 5=UNLEASHED), got '{n}'"
                    );
                    std::process::exit(2);
                }
                let al_path = autonomy_level::default_path();
                match autonomy_level::write_level(n, &al_path) {
                    Ok(()) => {
                        let level = autonomy_level::AutonomyLevel::from(n);
                        println!(
                            "AUTONOMY_LEVEL={n} ({}) written to {}",
                            level.name(),
                            al_path.display()
                        );
                    }
                    Err(e) => {
                        eprintln!(
                            "chump fleet level: failed to write {}: {e}",
                            al_path.display()
                        );
                        std::process::exit(1);
                    }
                }
                std::process::exit(0);
            }
            "status" => {
                let want_json = args.iter().any(|a| a == "--json");
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&fleet_status_sh);
                if want_json {
                    cmd.arg("--json");
                } else {
                    cmd.arg("--once");
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet status: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            // CREDIBLE-257 (CREDIBLE-099 slice): harness-neutral verb to list
            // registered workers + live state from the `chump_workers`
            // NATS-KV bucket (CREDIBLE-246 storage layer). Works from any
            // harness — this is a plain CLI subcommand, not Claude-Code-only.
            "workers" => {
                let want_json = args.iter().any(|a| a == "--json");
                let nats_url = std::env::var("CHUMP_NATS_URL")
                    .or_else(|_| std::env::var("NATS_URL"))
                    .unwrap_or_else(|_| chump_coord::DEFAULT_NATS_URL.to_string());

                let connect_result = tokio::time::timeout(
                    std::time::Duration::from_secs(3),
                    async_nats::connect(&nats_url),
                )
                .await;

                let nats = match connect_result {
                    Ok(Ok(n)) => n,
                    Ok(Err(e)) => {
                        eprintln!("chump fleet workers: NATS connect failed ({nats_url}): {e}");
                        std::process::exit(1);
                    }
                    Err(_) => {
                        eprintln!("chump fleet workers: NATS connect timed out ({nats_url})");
                        std::process::exit(1);
                    }
                };
                let js = async_nats::jetstream::new(nats);
                let kv = match chump_coord::presence::init_workers_bucket(&js).await {
                    Ok(kv) => kv,
                    Err(e) => {
                        eprintln!("chump fleet workers: workers KV bucket unavailable: {e}");
                        std::process::exit(1);
                    }
                };

                let mut presences = match chump_coord::presence::list_presence(&kv).await {
                    Ok(p) => p,
                    Err(e) => {
                        eprintln!("chump fleet workers: list_presence failed: {e}");
                        std::process::exit(1);
                    }
                };
                presences.sort_by(|a, b| a.worker_id.cmp(&b.worker_id));

                let now = chrono::Utc::now();
                let today = now.date_naive();

                // ships_today: best-effort — count today's `ship_grade`
                // ambient events whose agent_id matches this worker_id.
                // agent_id (AGENT_ID env) and worker_id (presence session
                // id) are distinct id spaces today, so this only counts
                // when a caller happened to set them equal; it is not a
                // hard guarantee. Loaded once and reused per worker.
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ambient_content = std::fs::read_to_string(&ambient_path).unwrap_or_default();
                let ships_today_for = |worker_id: &str| -> u64 {
                    let mut count = 0u64;
                    for line in ambient_content.lines() {
                        if !line.contains("ship_grade") {
                            continue;
                        }
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                            continue;
                        };
                        if v.get("kind").and_then(|x| x.as_str()) != Some("ship_grade") {
                            continue;
                        }
                        if v.get("agent_id").and_then(|x| x.as_str()) != Some(worker_id) {
                            continue;
                        }
                        let ts_matches_today = v
                            .get("ts")
                            .and_then(|x| x.as_str())
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .map(|dt| dt.with_timezone(&chrono::Utc).date_naive() == today)
                            .unwrap_or(false);
                        if ts_matches_today {
                            count += 1;
                        }
                    }
                    count
                };

                if want_json {
                    let rows: Vec<serde_json::Value> = presences
                        .iter()
                        .map(|p| {
                            let heartbeat_age_s =
                                now.signed_duration_since(p.updated_at).num_seconds().max(0);
                            serde_json::json!({
                                "worker_id": p.worker_id,
                                "backend": p.backend,
                                "machine": p.machine,
                                "skills": p.skills,
                                "harness": p.harness,
                                "current_gap": p.current_gap,
                                "status": p.status,
                                "heartbeat_age_s": heartbeat_age_s,
                                "ships_today": ships_today_for(&p.worker_id),
                            })
                        })
                        .collect();
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({ "workers": rows }))
                            .unwrap_or_else(|_| "{}".to_string())
                    );
                } else if presences.is_empty() {
                    println!(
                        "No registered workers found in NATS-KV bucket '{}'.",
                        chump_coord::presence::WORKERS_BUCKET
                    );
                } else {
                    println!(
                        "{:<24} {:<10} {:<12} {:<20} {:<14} {:<9} {:<9} SKILLS",
                        "WORKER_ID",
                        "BACKEND",
                        "MACHINE",
                        "CURRENT_GAP",
                        "STATUS",
                        "HB_AGE",
                        "SHIPS_2D"
                    );
                    for p in &presences {
                        let heartbeat_age_s =
                            now.signed_duration_since(p.updated_at).num_seconds().max(0);
                        println!(
                            "{:<24} {:<10} {:<12} {:<20} {:<14} {:<9} {:<9} {}",
                            p.worker_id,
                            p.backend,
                            p.machine.as_deref().unwrap_or("-"),
                            p.current_gap.as_deref().unwrap_or("-"),
                            format!("{:?}", p.status).to_lowercase(),
                            format!("{}s", heartbeat_age_s),
                            ships_today_for(&p.worker_id),
                            p.skills.join(","),
                        );
                    }
                }
            }
            "scale" => {
                let n_str = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump fleet scale <N>");
                    std::process::exit(2);
                });
                let n: u32 = n_str.parse().unwrap_or_else(|_| {
                    eprintln!("chump fleet scale: N must be a positive integer, got '{n_str}'");
                    std::process::exit(2);
                });
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());

                // Persist desired size so restarts and monitors can read it.
                let state_dir = repo_root.join(".chump");
                let _ = std::fs::create_dir_all(&state_dir);
                let _ = std::fs::write(state_dir.join("fleet-desired-size"), format!("{n}\n"));

                // Emit ambient event (matches fleet_scale_change schema in CLAUDE.md).
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_request\",\"to\":{n},\"session\":\"{session}\"}}"
                    );
                }

                // Count alive worker windows in the tmux session.
                let current_count: u32 = std::process::Command::new("tmux")
                    .args(["list-windows", "-t", &session, "-F", "#W"])
                    .output()
                    .ok()
                    .map(|o| {
                        String::from_utf8_lossy(&o.stdout)
                            .lines()
                            .filter(|l| l.starts_with("fleet-worker-"))
                            .count() as u32
                    })
                    .unwrap_or(0);

                println!("[fleet scale] session={session} current={current_count} → desired={n}");

                if n > current_count {
                    let worker_sh = repo_root.join("scripts/dispatch/worker.sh");
                    for i in (current_count + 1)..=n {
                        let pane_name = format!("fleet-worker-{i}");
                        let worker_cmd = format!("AGENT_ID={i} bash {}", worker_sh.display());
                        let ok = std::process::Command::new("tmux")
                            .args(["new-window", "-t", &session, "-n", &pane_name, &worker_cmd])
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if ok {
                            println!("[fleet scale] spawned {pane_name}");
                        } else {
                            eprintln!("[fleet scale] WARNING: failed to spawn {pane_name}");
                        }
                    }
                } else if n < current_count {
                    for i in (n + 1)..=current_count {
                        let target = format!("{session}:fleet-worker-{i}");
                        let ok = std::process::Command::new("tmux")
                            .args(["kill-window", "-t", &target])
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if ok {
                            println!("[fleet scale] killed fleet-worker-{i}");
                        } else {
                            println!("[fleet scale] fleet-worker-{i} not found (already stopped)");
                        }
                    }
                } else {
                    println!("[fleet scale] already at {n} workers — no change");
                }
                return Ok(());
            }
            "snapshot" => {
                // `chump fleet snapshot` — INFRA-612
                // Captures current fleet state (leases, locks, queue size, ambient tail)
                // into .chump/restart-snapshots/<ts>.json for later replay.
                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let _ = std::fs::create_dir_all(&snapshots_dir);
                let locks_dir = repo_root.join(".chump-locks");

                let ts = chrono::Utc::now();
                let ts_str = ts.format("%Y%m%d-%H%M%S").to_string();
                let ts_iso = ts.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // Collect active lease files.
                let mut leases: Vec<serde_json::Value> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    leases.push(serde_json::json!({
                                        "filename": path.file_name()
                                            .and_then(|n| n.to_str())
                                            .unwrap_or("unknown"),
                                        "lease": v
                                    }));
                                }
                            }
                        }
                    }
                }

                // Collect last 200 lines of ambient.jsonl.
                let ambient_path = locks_dir.join("ambient.jsonl");
                let ambient_tail: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .rev()
                    .take(200)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                // Fleet desired size.
                let fleet_desired_size: Option<u32> =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok());

                let snapshot = serde_json::json!({
                    "snapshot_id": ts_str,
                    "ts": ts_iso,
                    "fleet_desired_size": fleet_desired_size,
                    "leases": leases,
                    "ambient_tail": ambient_tail
                });

                let out_path = snapshots_dir.join(format!("{ts_str}.json"));
                match std::fs::write(
                    &out_path,
                    serde_json::to_string_pretty(&snapshot).unwrap_or_default(),
                ) {
                    Ok(()) => {
                        println!("[fleet snapshot] wrote {}", out_path.display());
                        println!(
                            "[fleet snapshot] leases={} ambient_events={}",
                            leases.len(),
                            ambient_tail.len()
                        );
                        // Emit ambient event.
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            let _ = writeln!(
                                f,
                                "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_snapshot\",\"snapshot_id\":\"{ts_str}\",\"leases\":{}}}", leases.len()
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("[fleet snapshot] failed to write snapshot: {e}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "restore" => {
                // `chump fleet restore <snapshot-id>` — INFRA-612
                // Replays lease state from a snapshot created by `fleet snapshot`.
                // Useful for diagnostics after a planned restart.
                let snapshot_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump fleet restore <snapshot-id>");
                    eprintln!("  snapshot-id: timestamp like 20260506-191935 or full path");
                    std::process::exit(2);
                });

                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let locks_dir = repo_root.join(".chump-locks");

                // Resolve snapshot path — accept full path or bare ID.
                let snap_path = if std::path::Path::new(&snapshot_id).exists() {
                    std::path::PathBuf::from(&snapshot_id)
                } else {
                    snapshots_dir.join(format!("{snapshot_id}.json"))
                };

                let raw = std::fs::read_to_string(&snap_path).unwrap_or_else(|e| {
                    eprintln!("[fleet restore] cannot read {}: {e}", snap_path.display());
                    std::process::exit(1);
                });
                let snapshot: serde_json::Value = serde_json::from_str(&raw).unwrap_or_else(|e| {
                    eprintln!("[fleet restore] invalid JSON in snapshot: {e}");
                    std::process::exit(1);
                });

                let ts_iso = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let ambient_path = locks_dir.join("ambient.jsonl");
                let _ = std::fs::create_dir_all(&locks_dir);

                // Replay leases — write each back to .chump-locks/<filename>.
                let mut replayed = 0u32;
                if let Some(leases) = snapshot["leases"].as_array() {
                    for entry in leases {
                        let filename = entry["filename"].as_str().unwrap_or("unknown.json");
                        let lease_val = &entry["lease"];
                        if lease_val.is_null() {
                            continue;
                        }
                        let dest = locks_dir.join(filename);
                        if let Ok(content) = serde_json::to_string_pretty(lease_val) {
                            if std::fs::write(&dest, content).is_ok() {
                                println!("[fleet restore] replayed lease → {}", dest.display());
                                replayed += 1;
                            }
                        }
                    }
                }

                // Restore fleet-desired-size if present.
                if let Some(size) = snapshot["fleet_desired_size"].as_u64() {
                    let _ = std::fs::create_dir_all(repo_root.join(".chump"));
                    let _ = std::fs::write(
                        repo_root.join(".chump/fleet-desired-size"),
                        format!("{size}\n"),
                    );
                    println!("[fleet restore] fleet-desired-size → {size}");
                }

                println!("[fleet restore] snapshot={snapshot_id} leases_replayed={replayed}");

                // Emit ambient event.
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_restore\",\"snapshot_id\":\"{snapshot_id}\",\"leases_replayed\":{replayed}}}"
                    );
                }
                return Ok(());
            }
            "audit-pids" => {
                // `chump fleet audit-pids [--apply]` — INFRA-649
                //
                // Checks that claude_pid_count == 2 * worker_count (±1 tolerance).
                // Each worker spawns a `timeout Ns claude -p ...` wrapper + the claude
                // subprocess, so 2 PIDs per worker is the invariant.
                //
                // Without --apply: report only.
                // With --apply:
                //   PIDs > expected+1 → pkill orphans (INFRA-602 sentinel pattern)
                //   PIDs < expected-1 → respawn via fleet-restart.sh (INFRA-611)
                //
                // Emits kind=fleet_pid_invariant to ambient.jsonl with delta + action.
                let apply = args.iter().any(|a| a == "--apply");
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

                let worker_count: u32 =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(0);

                let expected = worker_count * 2;

                // pgrep -c exits 1 when no matches but still prints "0"; handle both.
                let actual: u32 = std::process::Command::new("pgrep")
                    .args(["-c", "-f", "timeout [0-9]*s claude -p "])
                    .output()
                    .ok()
                    .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
                    .unwrap_or(0);

                let delta: i64 = actual as i64 - expected as i64;
                let in_tolerance = delta.abs() <= 1;

                println!(
                    "[fleet audit-pids] worker_count={worker_count} expected_pids={expected} \
                     actual_pids={actual} delta={delta:+} apply={apply}"
                );

                let action = if in_tolerance {
                    println!("[fleet audit-pids] invariant OK (within ±1 tolerance)");
                    "ok"
                } else if !apply {
                    if delta > 0 {
                        println!(
                            "[fleet audit-pids] DRIFT: {delta:+} excess PIDs — run with --apply to prune"
                        );
                    } else {
                        println!(
                            "[fleet audit-pids] DRIFT: {delta} missing PIDs — run with --apply to respawn"
                        );
                    }
                    "drift"
                } else if delta > 0 {
                    // More PIDs than expected → kill orphaned timeout+claude pairs.
                    println!("[fleet audit-pids] --apply: pruning orphan PIDs (delta={delta:+})");
                    let _ = std::process::Command::new("pkill")
                        .args(["-f", "timeout [0-9]*s claude -p "])
                        .status();
                    "pruned"
                } else {
                    // Fewer PIDs than expected → respawn via fleet-restart.sh.
                    println!(
                        "[fleet audit-pids] --apply: respawning fleet to worker_count={worker_count}"
                    );
                    let restart_sh = repo_root.join("scripts/dispatch/fleet-restart.sh");
                    let session = cfg("session").unwrap_or_else(|| "chump-fleet".to_string());
                    let _ = std::process::Command::new("bash")
                        .arg(&restart_sh)
                        .env("FLEET_SIZE", worker_count.to_string())
                        .env("FLEET_SESSION", &session)
                        .status();
                    "respawned"
                };

                // Emit ambient event.
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts}\",\"kind\":\"fleet_pid_invariant\",\
                         \"worker_count\":{worker_count},\"expected\":{expected},\
                         \"actual\":{actual},\"delta\":{delta},\
                         \"apply\":{apply},\"action\":\"{action}\"}}"
                    );
                }
                return Ok(());
            }
            "restart" => {
                // `chump fleet restart` — INFRA-610
                let fleet_restart_sh = repo_root.join("scripts/dispatch/fleet-restart.sh");
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let size_override = flag("--size");

                // 1. Take a before-restart snapshot.
                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let _ = std::fs::create_dir_all(&snapshots_dir);
                let locks_dir = repo_root.join(".chump-locks");
                let ts = chrono::Utc::now();
                let ts_str = ts.format("%Y%m%d-%H%M%S").to_string();
                let ts_iso = ts.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                let mut leases: Vec<serde_json::Value> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    leases.push(serde_json::json!({
                                        "filename": path.file_name()
                                            .and_then(|n| n.to_str())
                                            .unwrap_or("unknown"),
                                        "lease": v
                                    }));
                                }
                            }
                        }
                    }
                }

                let ambient_path = locks_dir.join("ambient.jsonl");
                let ambient_tail: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .rev()
                    .take(200)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                let desired_size: Option<u32> =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok());

                let snapshot = serde_json::json!({
                    "snapshot_id": ts_str,
                    "ts": ts_iso,
                    "kind": "pre_restart",
                    "fleet_desired_size": desired_size,
                    "leases": leases,
                    "ambient_tail": ambient_tail
                });

                let out_path = snapshots_dir.join(format!("{ts_str}.json"));
                match std::fs::write(
                    &out_path,
                    serde_json::to_string_pretty(&snapshot).unwrap_or_default(),
                ) {
                    Ok(()) => {
                        println!("[fleet restart] snapshot saved to {}", out_path.display());
                        println!(
                            "[fleet restart] leases={} ambient_events={}",
                            leases.len(),
                            ambient_tail.len()
                        );
                        let _ = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                            .and_then(|mut f| {
                                writeln!(
                                    f,
                                    "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_restart_snapshot\",\"snapshot_id\":\"{ts_str}\"}}"
                                )
                            });
                    }
                    Err(e) => {
                        eprintln!("[fleet restart] WARNING: failed to save snapshot: {e}");
                    }
                }

                // 2. Resolve fleet size: --size flag > last-fleet-config > desired-size > config.toml > 2
                let size = size_override
                    .or_else(|| {
                        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                        let p = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                        std::fs::read_to_string(&p).ok().and_then(|raw| {
                            serde_json::from_str::<serde_json::Value>(&raw)
                                .ok()
                                .and_then(|v| v["size"].as_str().map(String::from))
                        })
                    })
                    .or_else(|| desired_size.map(|s| s.to_string()))
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());

                // 3. Delegate to fleet-restart.sh
                let status = std::process::Command::new("bash")
                    .arg(&fleet_restart_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet restart: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-721: 60-second operator briefing — 24h ships, pillar mix,
            // stalls, auto-fixed, manual rescues, suggested actions.
            // INFRA-2013: also shows 1h ships as leading indicator; emits
            // fleet_stalled when ships_1h==0 and BLOCKED open PRs >= 2.
            // Wire: FLEET-019 SessionStart hook calls this at session open.
            "brief" => {
                let want_json = args.iter().any(|a| a == "--json");
                let window_secs: i64 = flag("--window")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(86400); // 24 h default

                let now = chrono::Utc::now();
                let now_ts = now.timestamp();
                let cutoff = now_ts - window_secs;
                let cutoff_1h = now_ts - 3600; // INFRA-2013 leading indicator
                let ts_iso = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // INFRA-1355: fleet-wide state (ambient.jsonl, lease files)
                // lives only in the main checkout's .chump-locks/.  Linked
                // worktrees get a sparse .chump-locks/ with only their own
                // session files, so reading it gives ships=0 / stalls=0.
                // Always resolve via git-common-dir so brief shows correct
                // fleet totals regardless of CWD.
                let locks_dir = {
                    let main_root = repo_path::main_checkout_root();
                    let main_locks = main_root.join(".chump-locks");
                    if main_locks.is_dir() {
                        main_locks
                    } else {
                        repo_root.join(".chump-locks")
                    }
                };
                let ambient_path = locks_dir.join("ambient.jsonl");

                // ── Parse ambient.jsonl ──────────────────────────────────
                let events: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                // Filter to window
                let window_events: Vec<&serde_json::Value> = events
                    .iter()
                    .filter(|e| {
                        e.get("ts")
                            .and_then(|v| v.as_str())
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .map(|dt| dt.timestamp() >= cutoff)
                            .unwrap_or(false)
                    })
                    .collect();

                // Count by "kind" sub-field (used in alert-category events)
                let count_kind = |kind: &str| -> usize {
                    window_events
                        .iter()
                        .filter(|e| e.get("kind").and_then(|v| v.as_str()) == Some(kind))
                        .count()
                };

                // CREDIBLE-168: count ACTUAL merges to origin/main (like the shell
                // fleet-brief.sh), NOT ambient "commit" events. Every worker WIP
                // commit + auto-commit across every worktree/session emits a
                // "commit" ambient event, so count_event("commit") over-counted
                // ships ~55x (720 ambient commits vs 13 real merges in 24h),
                // inflating the operator banner to a fictional ~30/hr when the
                // real ship rate is ~0.5/hr — conditioning "healthy, autonomous"
                // when the fleet ships little. git reads local origin/main (no
                // fetch), matching the shell script's window semantics exactly.
                // CREDIBLE-129: `git log ... origin/main` can transiently fail
                // (loose ref mid-gc/pack-refs, a fetch killed mid-transport, a
                // stale index/ref lock from a concurrent git process on the
                // same worktree) — see docs/investigations/CREDIBLE-1107-fleet-brief-subshell-audit.md.
                // The old `.unwrap_or(0)` made that failure bitwise identical
                // to "zero real ships", which produced the false fleet-dead
                // banner. Return `None` on a failed measurement (after one
                // retry, since the race is transient) so callers can print
                // "unavailable" instead of a misleading 0 and skip the
                // stalled/healthy verdicts that a real 0 would otherwise
                // drive.
                let count_merges_since = |cutoff_ts: i64| -> Option<usize> {
                    let cutoff_iso =
                        chrono::DateTime::from_timestamp(cutoff_ts, 0).map(|d| d.to_rfc3339())?;
                    let main_root = repo_path::main_checkout_root();
                    let run_git_log = || -> Option<usize> {
                        let output = std::process::Command::new("git")
                            .args([
                                "-C",
                                &main_root.to_string_lossy(),
                                "log",
                                "--format=%H",
                                &format!("--since={cutoff_iso}"),
                                "origin/main",
                            ])
                            .output()
                            .ok()?;
                        if !output.status.success() {
                            return None;
                        }
                        Some(
                            String::from_utf8_lossy(&output.stdout)
                                .lines()
                                .filter(|l| !l.trim().is_empty())
                                .count(),
                        )
                    };
                    // One retry: the ref-unresolvable window (concurrent
                    // fetch/gc/pack-refs) is typically sub-second.
                    run_git_log().or_else(run_git_log)
                };
                let ships = count_merges_since(cutoff);
                // INFRA-2013: 1h ship count — leading indicator (not subject to 24h rolling lag)
                let ships_1h = count_merges_since(cutoff_1h);
                let ships_measurement_failed = ships.is_none() || ships_1h.is_none();
                let auto_fixed = count_kind("flake_rerun_queued") + count_kind("lint_auto_fix");
                let manual_rescues = count_kind("manual_rescue");
                let fleet_wedges = count_kind("fleet_wedge");
                // INFRA-1247: silent_agent and pr_stuck are surfaced below as
                // "investigate now" operator-action prompts. They must count
                // over the same 30 min window as `alerts(30m)` — not the 24h
                // main window — otherwise the brief shows 24h totals
                // (e.g. 27 silent_agents, 18 pr_stuck) as if they were current
                // alerts, conditioning the operator to ignore the prompts
                // entirely. Before this fix the same healthy fleet that
                // emitted 1 actual recent event in 30 min showed "27 events"
                // because old events from earlier in the day were still in
                // the 24h window.
                let alert_cutoff = now_ts - 30 * 60;
                let count_kind_recent = |kind: &str| -> usize {
                    events
                        .iter()
                        .filter(|e| {
                            e.get("kind").and_then(|v| v.as_str()) == Some(kind)
                                && e.get("ts")
                                    .and_then(|v| v.as_str())
                                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                                    .map(|dt| dt.timestamp() >= alert_cutoff)
                                    .unwrap_or(false)
                        })
                        .count()
                };
                let silent_agents = count_kind_recent("silent_agent");
                let pr_stuck = count_kind_recent("pr_stuck");
                let alerts: usize = events
                    .iter()
                    .filter(|e| {
                        let kind = e.get("kind").and_then(|v| v.as_str()).unwrap_or("");
                        let is_alert = e.get("event").and_then(|v| v.as_str()) == Some("ALERT")
                            || e.get("event").and_then(|v| v.as_str()) == Some("alert")
                            || matches!(
                                kind,
                                "alert"
                                    | "ALERT"
                                    | "pr_stuck"
                                    | "silent_agent"
                                    | "fleet_stalled"
                                    | "silent_fleet_death"
                                    | "slo_breach"
                            );
                        if !is_alert {
                            return false;
                        }
                        e.get("ts")
                            .and_then(|v| v.as_str())
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .map(|dt| {
                                dt.timestamp() >= alert_cutoff && dt.timestamp() <= now_ts + 60
                            })
                            .unwrap_or(false)
                    })
                    .count();

                // Active leases → stall detection (leases older than 4h)
                let stall_threshold = now_ts - 4 * 3600;
                let mut stalls: Vec<String> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    let gap_id = v
                                        .get("gap_id")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("?")
                                        .to_string();
                                    let claimed_at = v
                                        .get("claimed_at")
                                        .and_then(|x| x.as_i64())
                                        .unwrap_or(now_ts);
                                    if claimed_at < stall_threshold {
                                        let age_h = (now_ts - claimed_at) / 3600;
                                        stalls.push(format!("{gap_id} ({age_h}h)"));
                                    }
                                }
                            }
                        }
                    }
                }
                // ── INFRA-2013: fleet stall detection (leading indicator) ────
                // Condition: 0 merges in last 1h AND >= 2 open BLOCKED PRs.
                // "open BLOCKED PRs" is approximated here by pr_stuck events in
                // the last 30 min (the same signal the shell path uses via gh).
                // When condition fires: emit fleet_stalled to ambient.jsonl so
                // watchers (operator-recall, cluster-detector, etc.) can page.
                // CREDIBLE-129: only fire on a REAL 0 — if the git measurement
                // itself failed (ships_1h == None), we don't know the real
                // ship rate, so don't manufacture a stalled verdict from it.
                let fleet_stalled = ships_1h == Some(0) && pr_stuck >= 2;
                if fleet_stalled {
                    let stall_line = format!(
                        "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_stalled\",\"ships_1h\":0,\"blocked_open\":{pr_stuck},\"source\":\"chump-fleet-brief\"}}\n"
                    );
                    let _ = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                        .and_then(|mut f| {
                            use std::io::Write;
                            f.write_all(stall_line.as_bytes())
                        });
                }

                // ── Pillar mix from open P0/P1 gaps ─────────────────────────
                let store_res = gap_store::GapStore::open(&repo_root);
                let mut pillar_counts: std::collections::HashMap<&str, usize> = [
                    ("EFFECTIVE", 0),
                    ("CREDIBLE", 0),
                    ("RESILIENT", 0),
                    ("ZERO-WASTE", 0),
                ]
                .iter()
                .cloned()
                .collect();
                let mut total_pickable = 0usize;
                if let Ok(ref store) = store_res {
                    if let Ok(gaps) = store.list(Some("open")) {
                        for g in &gaps {
                            if !matches!(g.priority.as_str(), "P0" | "P1") {
                                continue;
                            }
                            if !matches!(g.effort.as_str(), "xs" | "s" | "m") {
                                continue;
                            }
                            total_pickable += 1;
                            let t = g.title.to_uppercase();
                            for pillar in &["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"] {
                                if t.contains(pillar) {
                                    *pillar_counts.entry(pillar).or_insert(0) += 1;
                                    break;
                                }
                            }
                        }
                    }
                }

                // ── Suggested actions ────────────────────────────────────
                let mut suggestions: Vec<String> = Vec::new();
                // INFRA-2013: fleet_stalled is the highest-priority signal —
                // surface before wedge/silent_agent so it's not buried.
                if fleet_stalled {
                    suggestions.push(format!(
                        "🔴 STALLED: 0 merges in last 1h with {pr_stuck} stuck PRs — investigate bot-merge contention now"
                    ));
                }
                if fleet_wedges > 0 {
                    suggestions.push(format!(
                        "⚠  {} fleet_wedge event(s) — drop to 2 workers per CLAUDE.md",
                        fleet_wedges
                    ));
                }
                if silent_agents > 1 {
                    suggestions.push(format!(
                        "⚠  {} silent_agent event(s) — investigate lease/picker race",
                        silent_agents
                    ));
                }
                if pr_stuck >= 3 {
                    suggestions.push(format!(
                        "⚠  {} pr_stuck event(s) — diagnose bot-merge contention",
                        pr_stuck
                    ));
                }
                if !stalls.is_empty() {
                    suggestions.push(format!("⚠  Stalled leases: {}", stalls.join(", ")));
                }
                let zw = *pillar_counts.get("ZERO-WASTE").unwrap_or(&0);
                let re = *pillar_counts.get("RESILIENT").unwrap_or(&0);
                if zw < 2 {
                    suggestions.push(format!(
                        "📌 ZERO-WASTE has {zw} pickable gap(s) — file 1-2 to balance"
                    ));
                }
                if re < 2 {
                    suggestions.push(format!(
                        "📌 RESILIENT has {re} pickable gap(s) — file 1-2 to balance"
                    ));
                }
                // CREDIBLE-129 AC #1/#3: a failed ship-count measurement must
                // never present as "0 + healthy" — it's a measurement
                // failure, not a fleet-health verdict, so it takes priority
                // over every other suggestion (including "looks healthy").
                if ships_measurement_failed {
                    suggestions.insert(
                        0,
                        "⚠  ship-count unavailable (git log origin/main failed) — measurement failed, not a fleet-health verdict; re-run or check for a stale ref/index lock".to_string(),
                    );
                }
                // CREDIBLE-120: check SLO breach count before printing "fleet looks healthy".
                let slo_breaches: usize = if let Ok(v) =
                    std::env::var("CHUMP_SLO_BREACH_COUNT_OVERRIDE")
                {
                    v.trim().parse::<usize>().unwrap_or(0)
                } else if let Ok(p) = std::env::var("CHUMP_SLO_STATE_FILE") {
                    std::fs::read_to_string(&p)
                        .ok()
                        .and_then(|raw| {
                            if let Ok(n) = raw.trim().parse::<usize>() {
                                return Some(n);
                            }
                            serde_json::from_str::<serde_json::Value>(&raw)
                                .ok()
                                .and_then(|j| j.get("slo_breaches").and_then(|x| x.as_u64()))
                                .map(|n| n as usize)
                        })
                        .unwrap_or(0)
                } else if std::env::var("CHUMP_FLEET_BRIEF_IN_SLO_PROBE").as_deref() != Ok("1") {
                    std::env::current_exe()
                        .ok()
                        .and_then(|exe| {
                            std::process::Command::new(exe)
                                .args(["health", "--slo-check", "--json"])
                                .env("CHUMP_FLEET_BRIEF_IN_SLO_PROBE", "1")
                                .output()
                                .ok()
                        })
                        .and_then(|out| {
                            serde_json::from_slice::<serde_json::Value>(&out.stdout)
                                .ok()
                                .and_then(|j| j.get("slo_breaches").and_then(|x| x.as_u64()))
                                .map(|n| n as usize)
                        })
                        .unwrap_or(0)
                } else {
                    0
                };
                if slo_breaches > 0 {
                    suggestions.push(format!(
                        "⚠ SLO BREACH: {slo_breaches} breached — chump health --slo-check for detail"
                    ));
                }
                if suggestions.is_empty() {
                    suggestions.push("✓  No urgent actions — fleet looks healthy".to_string());
                }

                if want_json {
                    let out = serde_json::json!({
                        "ts": ts_iso,
                        "window_h": window_secs / 3600,
                        "ships_24h": ships,
                        "ships_1h": ships_1h,
                        "ships_measurement_failed": ships_measurement_failed,
                        "fleet_stalled": fleet_stalled,
                        "auto_fixed": auto_fixed,
                        "manual_rescues": manual_rescues,
                        "stalls_gt_4h": stalls,
                        "fleet_wedges": fleet_wedges,
                        "silent_agents": silent_agents,
                        "pr_stuck": pr_stuck,
                        "alerts": alerts,
                        "pillar_mix": {
                            "EFFECTIVE": pillar_counts.get("EFFECTIVE").copied().unwrap_or(0),
                            "CREDIBLE":  pillar_counts.get("CREDIBLE").copied().unwrap_or(0),
                            "RESILIENT": pillar_counts.get("RESILIENT").copied().unwrap_or(0),
                            "ZERO-WASTE": pillar_counts.get("ZERO-WASTE").copied().unwrap_or(0),
                            "total_pickable": total_pickable,
                        },
                        "suggestions": suggestions,
                        // CREDIBLE-1493: last self-report calibration score.
                        "calibration": commands::calibrate::banner_line(),
                    });
                    println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
                } else {
                    let window_h = window_secs / 3600;
                    println!("═══ Fleet brief (last {window_h}h) ═══");
                    // CREDIBLE-1493 (Phase R R7): how many of the instruments
                    // below agree with ground truth, from the last calibration.
                    println!("{}", commands::calibrate::banner_line());
                    // INFRA-2013: show 1h ships alongside rolling average.
                    // CREDIBLE-129: a failed git measurement prints
                    // "unavailable", never a bare 0 that reads as real data.
                    match (ships, ships_1h) {
                        (Some(s), Some(s1h)) => {
                            println!(
                                "Ships: {s}  (≈{}/hr) | last 1h: {s1h}",
                                if window_h > 0 {
                                    format!("{:.1}", s as f64 / window_h as f64)
                                } else {
                                    "?".to_string()
                                }
                            );
                        }
                        _ => {
                            println!(
                                "Ships: unavailable (git log origin/main failed) | last 1h: unavailable"
                            );
                        }
                    }
                    // INFRA-2013: prominent STALLED banner when condition met
                    if fleet_stalled {
                        eprintln!("*** STALLED: 0 merges in last 1h with {pr_stuck} stuck PRs — investigate now ***");
                    }
                    let eff = pillar_counts.get("EFFECTIVE").copied().unwrap_or(0);
                    let cre = pillar_counts.get("CREDIBLE").copied().unwrap_or(0);
                    let res = pillar_counts.get("RESILIENT").copied().unwrap_or(0);
                    let zw2 = pillar_counts.get("ZERO-WASTE").copied().unwrap_or(0);
                    println!(
                        "Pillars: EFFECTIVE={eff} CREDIBLE={cre} RESILIENT={res} ZERO-WASTE={zw2}  (of {total_pickable} pickable)"
                    );
                    println!(
                        "Stalls > 4h: {}",
                        if stalls.is_empty() {
                            "0".to_string()
                        } else {
                            stalls.join(", ")
                        }
                    );
                    println!("Auto-fixed: {auto_fixed}  flake-rerun+lint");
                    println!("Manual rescues: {manual_rescues}");
                    println!("Alerts(30m): {alerts}");
                    if !suggestions.iter().all(|s| s.starts_with('✓')) {
                        println!("\nActions:");
                        for s in &suggestions {
                            println!("  {s}");
                        }
                    } else {
                        println!("{}", suggestions[0]);
                    }
                }
                return Ok(());
            }
            // INFRA-615: starvation auto-widen.
            // --analyze: reads ambient.jsonl for fleet_starved events in last 1h,
            //            suggests widened FLEET_EFFORT_FILTER / PRIORITY_FILTER.
            // --apply:   writes suggested config to ~/.chump/fleet-config.toml.
            "auto-widen" => {
                let do_apply = args.iter().any(|a| a == "--apply");
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");

                // Read ambient events from the last 3600s (1h).
                let now_secs = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                let horizon = now_secs.saturating_sub(3600);

                let mut starve_count = 0u32;
                if let Ok(content) = std::fs::read_to_string(&ambient_path) {
                    for line in content.lines() {
                        if !line.contains("fleet_starved") {
                            continue;
                        }
                        // Parse ts field to check recency.
                        let ts_secs: Option<u64> = line
                            .split('"')
                            .skip_while(|s| *s != "ts")
                            .nth(2)
                            .and_then(|ts| {
                                // "2026-05-11T22:00:00Z" → epoch seconds (rough parse)
                                chrono::DateTime::parse_from_rfc3339(ts)
                                    .ok()
                                    .map(|dt| dt.timestamp() as u64)
                            });
                        if ts_secs.is_none_or(|t| t >= horizon) {
                            starve_count += 1;
                        }
                    }
                }

                // Derive suggestions based on current config.
                let current_effort = std::env::var("FLEET_EFFORT_FILTER")
                    .ok()
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s".to_string());
                let current_priority = std::env::var("FLEET_PRIORITY_FILTER")
                    .ok()
                    .or_else(|| cfg("priority_filter"))
                    .unwrap_or_else(|| "P0,P1".to_string());

                // Widen effort by appending next tier; widen priority by adding P2.
                let suggested_effort = if current_effort.contains("xl") {
                    // Already unrestricted (no gap-size limit): nothing larger to add.
                    current_effort.clone()
                } else if current_effort.contains('m') {
                    format!("{},l", current_effort.trim_end_matches(",l"))
                } else if current_effort.contains('s') {
                    format!("{},m", current_effort.trim_end_matches(",m"))
                } else {
                    format!("{},s,m", current_effort.trim_end_matches(",s,m"))
                };
                let suggested_priority = if current_priority.contains("P2") {
                    current_priority.clone()
                } else {
                    format!("{},P2", current_priority)
                };

                println!("[auto-widen] fleet_starved events in last 1h: {starve_count}");
                println!("[auto-widen] current effort filter : {current_effort}");
                println!("[auto-widen] current priority filter: {current_priority}");

                if starve_count == 0 {
                    println!("[auto-widen] no starvation detected — no change recommended");
                } else {
                    println!("[auto-widen] suggested effort filter : {suggested_effort}");
                    println!("[auto-widen] suggested priority filter: {suggested_priority}");
                    println!("[auto-widen] reason: {starve_count} starvation event(s) in last 1h");

                    if do_apply {
                        let config_dir = std::path::Path::new(&home).join(".chump");
                        let _ = std::fs::create_dir_all(&config_dir);
                        let fleet_config = config_dir.join("fleet-config.toml");
                        let toml_content = format!(
                            "# INFRA-615: auto-widen applied by 'chump fleet auto-widen --apply'\n\
                             # starve_events_1h = {starve_count}\n\
                             # applied_at = \"{}\"\n\
                             effort = \"{suggested_effort}\"\n\
                             priority_filter = \"{suggested_priority}\"\n",
                            chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
                        );
                        match std::fs::write(&fleet_config, &toml_content) {
                            Ok(_) => {
                                println!(
                                    "[auto-widen] wrote {} → restart fleet to apply",
                                    fleet_config.display()
                                );
                                // Emit ambient event.
                                let ambient_write = repo_root.join(".chump-locks/ambient.jsonl");
                                let event = format!(
                                    "{{\"ts\":\"{}\",\"kind\":\"fleet_auto_widen_applied\",\
                                     \"starve_count\":{starve_count},\
                                     \"effort\":\"{suggested_effort}\",\
                                     \"priority_filter\":\"{suggested_priority}\"}}\n",
                                    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
                                );
                                let _ = std::fs::OpenOptions::new()
                                    .append(true)
                                    .create(true)
                                    .open(&ambient_write)
                                    .and_then(|mut f| {
                                        use std::io::Write;
                                        f.write_all(event.as_bytes())
                                    });
                            }
                            Err(e) => {
                                eprintln!("[auto-widen] failed to write fleet-config.toml: {e}");
                                std::process::exit(1);
                            }
                        }
                    } else {
                        println!(
                            "[auto-widen] run with --apply to write ~/.chump/fleet-config.toml"
                        );
                    }
                }
            }
            // INFRA-2198 (META-128/C7): disk-aware fleet auto-scale.
            // Reads current N workers + disk inventory; scales down 1 when
            // disk < 20 GB, scales up 1 when disk > 60 GB AND ship-rate is
            // healthy.  Max delta 1 per tick.  Run every 5 min via launchd
            // (installer: scripts/dispatch/chump-fleet-autoscale-launchd.sh).
            //
            // Usage: chump fleet auto-scale [--apply] [--json]
            //
            // CHUMP_FLEET_SCALE_LOW_GB   — disk free threshold to scale down (default 20.0)
            // CHUMP_FLEET_SCALE_HIGH_GB  — disk free threshold to scale up   (default 60.0)
            "auto-scale" => {
                let apply = args.iter().any(|a| a == "--apply");
                let as_json = args.iter().any(|a| a == "--json");

                let current_size: u32 =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(2);

                let low_gb: f64 = std::env::var("CHUMP_FLEET_SCALE_LOW_GB")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(20.0);
                let high_gb: f64 = std::env::var("CHUMP_FLEET_SCALE_HIGH_GB")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(60.0);

                // Load disk snapshot (graceful fallback when INFRA-2196 absent).
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let inv_path_override = std::env::var("CHUMP_DISK_INVENTORY_PATH").ok();
                let inv_path = if let Some(ref p) = inv_path_override {
                    std::path::PathBuf::from(p)
                } else {
                    std::path::Path::new(&home).join(".chump/disk-inventory.json")
                };

                let free_gb: Option<f64> = std::fs::read_to_string(&inv_path)
                    .ok()
                    .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
                    .and_then(|v| v["free_gb"].as_f64());

                // Ship-rate health: use fleet_velocity snapshot (1h shipped count).
                let vel = fleet_velocity::snapshot(&repo_root);
                let ship_rate_healthy =
                    vel.rate_per_hour_1h() > 0.0 || vel.rate_per_hour_6h() > 0.0;

                #[derive(Debug)]
                enum AutoScaleAction {
                    ScaleDown { reason: &'static str },
                    ScaleUp { reason: &'static str },
                    NoChange { reason: &'static str },
                }

                let action: AutoScaleAction = match free_gb {
                    None => AutoScaleAction::NoChange {
                        reason:
                            "disk-inventory.json absent — no disk data (INFRA-2193 not running?)",
                    },
                    Some(free) if free < low_gb => AutoScaleAction::ScaleDown {
                        reason: "disk free < low threshold",
                    },
                    Some(free) if free > high_gb && ship_rate_healthy => AutoScaleAction::ScaleUp {
                        reason: "disk free > high threshold AND ship-rate healthy",
                    },
                    Some(free) if free > high_gb => AutoScaleAction::NoChange {
                        reason: "disk free > high threshold but ship-rate zero — not scaling up",
                    },
                    Some(_) => AutoScaleAction::NoChange {
                        reason: "disk headroom within normal range",
                    },
                };

                let (new_size, action_label, reason_str) = match &action {
                    AutoScaleAction::ScaleDown { reason } => {
                        (current_size.saturating_sub(1).max(1), "scale_down", *reason)
                    }
                    AutoScaleAction::ScaleUp { reason } => (current_size + 1, "scale_up", *reason),
                    AutoScaleAction::NoChange { reason } => (current_size, "no_change", *reason),
                };

                let free_gb_display = free_gb
                    .map(|f| format!("{f:.1}"))
                    .unwrap_or_else(|| "N/A".to_string());

                if as_json {
                    println!(
                        "{{\"fleet_auto_scale\":true,\
                         \"action\":\"{action_label}\",\
                         \"current_size\":{current_size},\
                         \"new_size\":{new_size},\
                         \"free_gb\":\"{free_gb_display}\",\
                         \"reason\":\"{reason_str}\"}}"
                    );
                } else {
                    println!(
                        "[fleet auto-scale] action={action_label} current={current_size} → new={new_size}  \
                         free={free_gb_display}GB  reason={reason_str}"
                    );
                }

                if new_size != current_size {
                    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    // Emit ambient event regardless of --apply (the event is the record of intent).
                    if let Ok(mut af) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        let _ = writeln!(
                            af,
                            "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_changed\",\
                             \"from\":{current_size},\"to\":{new_size},\
                             \"reason\":\"auto-scale: {reason_str}\"}}"
                        );
                    }

                    if apply {
                        let _ = std::fs::write(
                            repo_root.join(".chump/fleet-desired-size"),
                            format!("{new_size}\n"),
                        );
                        if !as_json {
                            println!(
                                "[fleet auto-scale] --apply: wrote fleet-desired-size={new_size}"
                            );
                        }
                    } else if !as_json {
                        println!("[fleet auto-scale] dry-run; run with --apply to execute");
                    }
                }

                return Ok(());
            }
            // INFRA-650: fleet auto-prune-down controller.
            // Evaluates 4 conditions and recommends (or applies) a scale-down.
            "auto-resize" => {
                let apply = args.iter().any(|a| a == "--apply");
                let as_json = args.iter().any(|a| a == "--json");
                let current_size: u32 =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(2);

                let decision = fleet_resize::evaluate(&repo_root, current_size);

                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

                match decision {
                    None => {
                        if as_json {
                            println!("{{\"fleet_resize_decision\":\"none\",\"current_size\":{current_size}}}");
                        } else {
                            println!(
                                "[fleet auto-resize] current_size={current_size} — no resize trigger fired"
                            );
                        }
                    }
                    Some(d) => {
                        let trigger_name = format!("{:?}", d.trigger);
                        if as_json {
                            println!(
                                "{{\"fleet_resize_decision\":\"resize\",\"trigger\":\"{trigger_name}\",\
                                 \"current_size\":{current_size},\"recommended_size\":{},\"rationale\":\"{}\"}}",
                                d.recommended_size,
                                d.rationale.replace('"', "'")
                            );
                        } else {
                            println!(
                                "[fleet auto-resize] trigger={trigger_name} \
                                 current={current_size} → recommended={}",
                                d.recommended_size
                            );
                            println!("[fleet auto-resize] rationale: {}", d.rationale);
                        }

                        // Emit ambient event (INFRA-650 AC criterion 4).
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            let _ = writeln!(
                                f,
                                "{{\"ts\":\"{ts}\",\"kind\":\"fleet_resize_decision\",\
                                 \"trigger\":\"{trigger_name}\",\"current_size\":{current_size},\
                                 \"recommended_size\":{},\"rationale\":\"{}\"}}",
                                d.recommended_size,
                                d.rationale.replace('"', "'")
                            );
                        }

                        if apply && d.recommended_size < current_size {
                            println!(
                                "[fleet auto-resize] --apply: scaling from {current_size} to {}",
                                d.recommended_size
                            );
                            // Write desired size.
                            let _ = std::fs::write(
                                repo_root.join(".chump/fleet-desired-size"),
                                format!("{}\n", d.recommended_size),
                            );
                            // Emit fleet_scale_change.
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                let _ = writeln!(
                                    f,
                                    "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_change\",\
                                     \"from\":{current_size},\"to\":{},\"rationale\":\"auto-resize: {trigger_name}\"}}",
                                    d.recommended_size
                                );
                            }
                        } else if !apply {
                            println!("[fleet auto-resize] run with --apply to execute resize");
                        }
                    }
                }
                return Ok(());
            }
            // INFRA-1890: detector escalation tier. Detection + filing logic
            // lives in scripts/coord/escalation-tier.sh (same pattern as
            // other ambient-scanning detectors, e.g. bounced-pr-detector.sh);
            // this arm owns operator-facing suppression state, which is
            // canonical fleet config and belongs in Rust per the Rust-first
            // criteria (mutates .chump/escalation-suppressions.json).
            "escalation" => {
                let suppressions_path = repo_root.join(".chump/escalation-suppressions.json");
                if let Some(rule_id) = flag("--suppress-rule") {
                    let reason = flag("--reason").unwrap_or_else(|| "unspecified".to_string());
                    let _ =
                        std::fs::create_dir_all(suppressions_path.parent().unwrap_or(&repo_root));
                    let mut doc: serde_json::Value = std::fs::read_to_string(&suppressions_path)
                        .ok()
                        .and_then(|s| serde_json::from_str(&s).ok())
                        .unwrap_or_else(|| serde_json::json!({}));
                    let ts_iso = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    doc[&rule_id] = serde_json::json!({
                        "suppressed_at": ts_iso,
                        "reason": reason,
                    });
                    std::fs::write(
                        &suppressions_path,
                        serde_json::to_string_pretty(&doc).unwrap_or_default(),
                    )
                    .unwrap_or_else(|e| {
                        eprintln!(
                            "chump fleet escalation: failed to write {}: {e}",
                            suppressions_path.display()
                        );
                        std::process::exit(1);
                    });
                    println!(
                        "chump fleet escalation: rule '{rule_id}' suppressed (see {})",
                        suppressions_path.display()
                    );
                    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        // scanner-anchor: "kind":"escalation_rule_suppressed_by_operator"
                        let _ = writeln!(
                            f,
                            "{{\"ts\":\"{ts_iso}\",\"kind\":\"escalation_rule_suppressed_by_operator\",\
                             \"rule_id\":\"{rule_id}\"}}"
                        );
                    }
                    return Ok(());
                }
                if let Some(rule_id) = flag("--unsuppress-rule") {
                    let mut doc: serde_json::Value = std::fs::read_to_string(&suppressions_path)
                        .ok()
                        .and_then(|s| serde_json::from_str(&s).ok())
                        .unwrap_or_else(|| serde_json::json!({}));
                    if let Some(obj) = doc.as_object_mut() {
                        obj.remove(&rule_id);
                    }
                    std::fs::write(
                        &suppressions_path,
                        serde_json::to_string_pretty(&doc).unwrap_or_default(),
                    )
                    .unwrap_or_else(|e| {
                        eprintln!(
                            "chump fleet escalation: failed to write {}: {e}",
                            suppressions_path.display()
                        );
                        std::process::exit(1);
                    });
                    println!("chump fleet escalation: rule '{rule_id}' un-suppressed");
                    return Ok(());
                }
                // Default: run one detection cycle now (same script the
                // hourly launchd job / daemon cadence calls).
                let escalation_sh = repo_root.join("scripts/coord/escalation-tier.sh");
                let status = std::process::Command::new("bash")
                    .arg(&escalation_sh)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet escalation: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-827: prune stale linked worktrees (age > CHUMP_WT_MAX_AGE_H AND no open PR)
            "prune-worktrees" => {
                let dry_run = !args.iter().any(|a| a == "--apply");
                let want_json = args.iter().any(|a| a == "--json");
                let max_age_h: u64 = std::env::var("CHUMP_WT_MAX_AGE_H")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(48);
                let max_age_secs = max_age_h * 3600;
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts_now = chrono::Utc::now();
                let ts_iso = ts_now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // Parse `git worktree list --porcelain` output.
                let wt_out = std::process::Command::new("git")
                    .args(["worktree", "list", "--porcelain"])
                    .current_dir(&repo_root)
                    .output()
                    .unwrap_or_else(|e| {
                        eprintln!("[prune-worktrees] git worktree list failed: {e}");
                        std::process::exit(1);
                    });
                let wt_text = String::from_utf8_lossy(&wt_out.stdout);

                // Each worktree block is separated by a blank line.
                struct WtEntry {
                    path: String,
                    branch: String,
                }
                let mut worktrees: Vec<WtEntry> = Vec::new();
                let mut cur_path: Option<String> = None;
                let mut cur_branch: Option<String> = None;
                for line in wt_text.lines() {
                    if line.starts_with("worktree ") {
                        cur_path = Some(line["worktree ".len()..].trim().to_string());
                        cur_branch = None;
                    } else if line.starts_with("branch ") {
                        // branch refs/heads/<name>
                        let b = line["branch ".len()..].trim().to_string();
                        let branch_name = b.strip_prefix("refs/heads/").unwrap_or(&b).to_string();
                        cur_branch = Some(branch_name);
                    } else if line.is_empty() {
                        if let (Some(p), Some(b)) = (cur_path.take(), cur_branch.take()) {
                            worktrees.push(WtEntry { path: p, branch: b });
                        } else {
                            cur_path = None;
                            cur_branch = None;
                        }
                    }
                }
                // Flush last block if file doesn't end with blank line.
                if let (Some(p), Some(b)) = (cur_path, cur_branch) {
                    worktrees.push(WtEntry { path: p, branch: b });
                }

                // Skip the main worktree (first entry).
                let linked: Vec<&WtEntry> = worktrees.iter().skip(1).collect();

                let mut pruned_count: u32 = 0;
                let mut skipped_active_pr: u32 = 0;
                let mut skipped_uncommitted: u32 = 0;
                let mut skipped_young: u32 = 0;
                let mut pruned_paths: Vec<String> = Vec::new();
                let mut dry_run_candidates: Vec<String> = Vec::new();

                let _now_secs = ts_now.timestamp() as u64;

                for wt in &linked {
                    let wt_path = std::path::Path::new(&wt.path);

                    // Age check: use mtime of .git file inside the worktree.
                    let git_file = wt_path.join(".git");
                    let age_secs: u64 = git_file
                        .metadata()
                        .or_else(|_| wt_path.metadata())
                        .ok()
                        .and_then(|m| m.modified().ok())
                        .and_then(|mt| mt.elapsed().ok())
                        .map(|d| d.as_secs())
                        .unwrap_or(0);

                    if age_secs < max_age_secs {
                        skipped_young += 1;
                        continue;
                    }

                    // Uncommitted changes check.
                    let status_out = std::process::Command::new("git")
                        .args(["status", "--porcelain"])
                        .current_dir(wt_path)
                        .output()
                        .ok();
                    let has_dirty = status_out
                        .as_ref()
                        .map(|o| !o.stdout.is_empty())
                        .unwrap_or(false);
                    if has_dirty {
                        skipped_uncommitted += 1;
                        if !want_json {
                            println!(
                                "[prune-worktrees] KEEP (dirty) {}  branch={}",
                                wt.path, wt.branch
                            );
                        }
                        continue;
                    }

                    // Open PR check via gh CLI.
                    let has_open_pr = std::process::Command::new("gh")
                        .args([
                            "pr", "list", "--head", &wt.branch, "--state", "open", "--json",
                            "number", "--jq", "length",
                        ])
                        .output()
                        .ok()
                        .and_then(|o| {
                            String::from_utf8_lossy(&o.stdout)
                                .trim()
                                .parse::<u32>()
                                .ok()
                        })
                        .map(|n| n > 0)
                        .unwrap_or(false);

                    if has_open_pr {
                        skipped_active_pr += 1;
                        if !want_json {
                            println!(
                                "[prune-worktrees] KEEP (open PR) {}  branch={}",
                                wt.path, wt.branch
                            );
                        }
                        continue;
                    }

                    // Stale — eligible for pruning.
                    let age_h = age_secs / 3600;
                    if dry_run {
                        dry_run_candidates.push(wt.path.clone());
                        if !want_json {
                            println!(
                                "[prune-worktrees] WOULD PRUNE (age={}h)  {}  branch={}",
                                age_h, wt.path, wt.branch
                            );
                        }
                    } else {
                        // Remove via git worktree remove --force.
                        let rm_ok = std::process::Command::new("git")
                            .args(["worktree", "remove", "--force", &wt.path])
                            .current_dir(&repo_root)
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if rm_ok {
                            pruned_count += 1;
                            pruned_paths.push(wt.path.clone());
                            if !want_json {
                                println!(
                                    "[prune-worktrees] PRUNED (age={}h)  {}  branch={}",
                                    age_h, wt.path, wt.branch
                                );
                            }
                            // Emit ambient event per pruned worktree.
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                let branch_esc = wt.branch.replace('"', "\\\"");
                                let path_esc = wt.path.replace('"', "\\\"");
                                let _ = writeln!(
                                    f,
                                    "{{\"ts\":\"{ts_iso}\",\"kind\":\"worktree_pruned\",\
                                     \"path\":\"{path_esc}\",\"branch\":\"{branch_esc}\",\"age_h\":{age_h}}}"
                                );
                            }
                        } else {
                            eprintln!("[prune-worktrees] WARNING: failed to remove {}", wt.path);
                        }
                    }
                }

                if want_json {
                    let candidates_json = if dry_run {
                        serde_json::to_string(&dry_run_candidates).unwrap_or_else(|_| "[]".into())
                    } else {
                        serde_json::to_string(&pruned_paths).unwrap_or_else(|_| "[]".into())
                    };
                    println!(
                        "{{\"dry_run\":{dry_run},\"max_age_h\":{max_age_h},\
                         \"pruned\":{pruned_count},\
                         \"skipped_active_pr\":{skipped_active_pr},\
                         \"skipped_uncommitted\":{skipped_uncommitted},\
                         \"skipped_young\":{skipped_young},\
                         \"paths\":{candidates_json}}}"
                    );
                } else if dry_run {
                    println!(
                        "[prune-worktrees] dry-run: {} stale worktrees would be pruned \
                         (skipped: {} active-PR, {} dirty, {} young)",
                        dry_run_candidates.len(),
                        skipped_active_pr,
                        skipped_uncommitted,
                        skipped_young
                    );
                    println!("[prune-worktrees] re-run with --apply to remove");
                } else {
                    println!(
                        "[prune-worktrees] done: pruned={pruned_count} \
                         skipped_active_pr={skipped_active_pr} \
                         skipped_uncommitted={skipped_uncommitted} \
                         skipped_young={skipped_young}"
                    );
                }

                if !dry_run && pruned_count > 0 {
                    // Emit summary ambient event.
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        let _ = writeln!(
                            f,
                            "{{\"ts\":\"{ts_iso}\",\"kind\":\"worktree_prune_summary\",\
                             \"pruned\":{pruned_count},\"skipped_active_pr\":{skipped_active_pr},\
                             \"skipped_uncommitted\":{skipped_uncommitted},\"skipped_young\":{skipped_young}}}"
                        );
                    }
                }

                return Ok(());
            }
            "daemon" => {
                // INFRA-964: long-lived chump-owned scheduler. Reads
                // scripts/coord/system-gap-frequencies.yaml (INFRA-841) and
                // runs each declared task at its interval_s cadence by
                // shelling out to the task's existing script. Emits
                // kind=daemon_tick per invocation so missed cron windows
                // are observable instantly via ambient.jsonl.
                //
                // Replaces the Claude-Code-hosted scheduled-tasks MCP path,
                // which only fires while the host UI is alive (the bug
                // INFRA-964 was filed to capture). OS keeps this daemon
                // alive via launchd/com.chump.fleet-daemon.plist.
                let once = args.iter().any(|a| a == "--once");
                let yaml_path = repo_root.join("scripts/coord/system-gap-frequencies.yaml");
                let yaml_contents = std::fs::read_to_string(&yaml_path).map_err(|e| {
                    anyhow::anyhow!("fleet daemon: cannot read {}: {e}", yaml_path.display())
                })?;

                // Parse the tasks: { name, interval_s, script } from the YAML.
                // We use a minimal pure-Rust parser instead of pulling in
                // serde_yaml to keep the binary slim (same approach as the
                // bash hot-file-lock.sh awk parsing).
                #[derive(Clone, Debug)]
                struct DaemonTask {
                    name: String,
                    interval_s: u64,
                    script: String,
                    optional: bool,
                }
                let mut tasks: Vec<DaemonTask> = Vec::new();
                let mut in_tasks = false;
                let mut cur: Option<DaemonTask> = None;
                for line in yaml_contents.lines() {
                    if line.starts_with("tasks:") {
                        in_tasks = true;
                        continue;
                    }
                    if in_tasks
                        && !line.starts_with(' ')
                        && !line.starts_with('\t')
                        && !line.trim().is_empty()
                    {
                        in_tasks = false;
                    }
                    if !in_tasks {
                        continue;
                    }
                    let trimmed = line.trim_end();
                    // Task header: two-space indent + name: + newline.
                    if let Some(rest) = trimmed.strip_prefix("  ") {
                        if !rest.starts_with(' ') && rest.ends_with(':') {
                            if let Some(t) = cur.take() {
                                tasks.push(t);
                            }
                            let name = rest.trim_end_matches(':').to_string();
                            cur = Some(DaemonTask {
                                name,
                                interval_s: 0,
                                script: String::new(),
                                optional: false,
                            });
                            continue;
                        }
                    }
                    // Fields under the current task (four-space indent).
                    if let Some(t) = cur.as_mut() {
                        if let Some(rest) = trimmed.strip_prefix("    interval_s:") {
                            t.interval_s = rest
                                .split('#')
                                .next()
                                .unwrap_or("")
                                .trim()
                                .parse()
                                .unwrap_or(0);
                        } else if let Some(rest) = trimmed.strip_prefix("    script:") {
                            t.script = rest.trim().to_string();
                        } else if let Some(rest) = trimmed.strip_prefix("    optional:") {
                            t.optional = rest.trim().starts_with("true");
                        }
                    }
                }
                if let Some(t) = cur.take() {
                    tasks.push(t);
                }
                tasks.retain(|t| t.interval_s > 0 && !t.script.is_empty());
                // Filter out tasks whose script doesn't exist on disk when
                // they're marked optional (e.g. gap-gardener.sh stub).
                tasks.retain(|t| {
                    if t.optional && !repo_root.join(&t.script).exists() {
                        eprintln!(
                            "[fleet daemon] skipping optional task {} — script missing: {}",
                            t.name, t.script
                        );
                        false
                    } else {
                        true
                    }
                });

                if tasks.is_empty() {
                    eprintln!(
                        "[fleet daemon] no runnable tasks in {}",
                        yaml_path.display()
                    );
                    return Ok(());
                }

                // Ambient log path (mirrors scripts/coord/opus-curator.sh).
                let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");
                if let Some(parent) = ambient_log.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }

                let emit_tick =
                    |task: &DaemonTask, run_id: &str, exit_code: i32, elapsed_ms: u128| {
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let line = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"daemon_tick\",\
                          \"task\":\"{}\",\"interval_s\":{},\"run_id\":\"{run_id}\",\
                          \"exit_code\":{exit_code},\"elapsed_ms\":{elapsed_ms}}}\n",
                            task.name, task.interval_s
                        );
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_log)
                        {
                            use std::io::Write;
                            let _ = f.write_all(line.as_bytes());
                        }
                    };

                // Run a single tick: shell out to the task's script, capture
                // exit code + elapsed time, emit ambient event. Errors are
                // swallowed (logged) so one bad task doesn't kill the daemon.
                async fn run_tick(
                    task_name: String,
                    script_rel: String,
                    repo_root: std::path::PathBuf,
                ) -> (i32, u128) {
                    let script_path = repo_root.join(&script_rel);
                    let started = std::time::Instant::now();
                    let res = tokio::process::Command::new("bash")
                        .arg(&script_path)
                        .current_dir(&repo_root)
                        .output()
                        .await;
                    let elapsed_ms = started.elapsed().as_millis();
                    match res {
                        Ok(o) => {
                            let code = o.status.code().unwrap_or(-1);
                            if code != 0 {
                                eprintln!(
                                    "[fleet daemon] {} exit={} in {}ms",
                                    task_name, code, elapsed_ms
                                );
                            }
                            (code, elapsed_ms)
                        }
                        Err(e) => {
                            eprintln!(
                                "[fleet daemon] {} spawn failed: {e} ({}ms)",
                                task_name, elapsed_ms
                            );
                            (-1, elapsed_ms)
                        }
                    }
                }

                // Emit daemon_started so observers know the daemon is alive.
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let tasks_csv = tasks
                    .iter()
                    .map(|t| t.name.clone())
                    .collect::<Vec<_>>()
                    .join(",");
                let start_line = format!(
                    "{{\"ts\":\"{ts}\",\"kind\":\"daemon_started\",\
                      \"tasks\":\"{tasks_csv}\",\"mode\":\"{}\"}}\n",
                    if once { "once" } else { "loop" }
                );
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_log)
                {
                    use std::io::Write;
                    let _ = f.write_all(start_line.as_bytes());
                }

                if once {
                    // --once mode: run every task once, sequentially, then exit.
                    // Used by the install script's smoke test + by CI.
                    for t in &tasks {
                        let run_id =
                            format!("{}-{}", std::process::id(), chrono::Utc::now().timestamp());
                        let (exit_code, elapsed_ms) =
                            run_tick(t.name.clone(), t.script.clone(), repo_root.clone()).await;
                        emit_tick(t, &run_id, exit_code, elapsed_ms);
                    }
                    return Ok(());
                }

                // Long-lived loop mode: one tokio interval per declared task.
                eprintln!("[fleet daemon] starting {} tasks (loop mode)", tasks.len());
                let mut handles = Vec::new();
                for t in tasks {
                    let repo_root = repo_root.clone();
                    let ambient_log = ambient_log.clone();
                    handles.push(tokio::spawn(async move {
                        let mut ticker =
                            tokio::time::interval(std::time::Duration::from_secs(t.interval_s));
                        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                        loop {
                            ticker.tick().await;
                            let run_id = format!(
                                "{}-{}",
                                std::process::id(),
                                chrono::Utc::now().timestamp()
                            );
                            let (exit_code, elapsed_ms) =
                                run_tick(t.name.clone(), t.script.clone(), repo_root.clone()).await;
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            let line = format!(
                                "{{\"ts\":\"{ts}\",\"kind\":\"daemon_tick\",\
                                  \"task\":\"{}\",\"interval_s\":{},\
                                  \"run_id\":\"{run_id}\",\
                                  \"exit_code\":{exit_code},\
                                  \"elapsed_ms\":{elapsed_ms}}}\n",
                                t.name, t.interval_s
                            );
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_log)
                            {
                                use std::io::Write;
                                let _ = f.write_all(line.as_bytes());
                            }
                        }
                    }));
                }
                // Hold until any task errors out (none should under normal op).
                for h in handles {
                    let _ = h.await;
                }
                return Ok(());
            }
            // FLEET-037: ergonomic primary verb — like "start" but with an
            // idempotency guard: refuses if the tmux session is already running.
            "up" => {
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());

                // Idempotency: if session already running, bail early with clear guidance.
                let already_running = std::process::Command::new("tmux")
                    .args(["has-session", "-t", &session])
                    .status()
                    .map(|s| s.success())
                    .unwrap_or(false);

                if already_running {
                    eprintln!("[fleet up] session '{session}' is already running.");
                    eprintln!("  Use 'chump fleet status' to see current state.");
                    eprintln!("  Use 'chump fleet scale <N>' to resize.");
                    eprintln!("  Use 'chump fleet down' to stop first, then 'chump fleet up'.");
                    std::process::exit(2);
                }

                // INFRA-1522 (W-007): required-check health gate.
                // Refuse `up` if any required status check has a flake history
                // >20% or last 5 runs all SKIPPED — that's the wedge class
                // that cost ~50 PRs of throughput on 2026-05-25.
                // Bypass: --force flag (emits required_check_health_bypass).
                let want_force = args.iter().any(|a| a == "--force");
                if !want_force {
                    let provider = required_check_health::default_provider();
                    // Probe required checks via `gh api branches/main/protection`.
                    let required_contexts = list_required_contexts();
                    if !required_contexts.is_empty() {
                        let report = required_check_health::evaluate(&required_contexts, &provider);
                        if report.any_unhealthy {
                            required_check_health::emit_warn_for_unhealthy(&report, None);
                            eprintln!("{}", report.refuse_message());
                            eprintln!();
                            eprintln!("  Bypass: chump fleet up --force  (emits audit event)");
                            std::process::exit(2);
                        }
                    }
                } else {
                    // Force-bypass: emit the audit event so the operator
                    // override is captured in ambient.jsonl.
                    let provider = required_check_health::default_provider();
                    let required_contexts = list_required_contexts();
                    if !required_contexts.is_empty() {
                        let report = required_check_health::evaluate(&required_contexts, &provider);
                        if report.any_unhealthy {
                            required_check_health::emit_bypass(
                                &report,
                                "operator --force on fleet up",
                            );
                            eprintln!("[fleet up] --force bypass active — required-check health gate skipped");
                        }
                    }
                }

                // Delegate to the same logic as "start" (shared via the start arm path).
                let size = flag("--size")
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());

                // INFRA-2198: disk-aware gate — consult chump disk plan before
                // allocating N workers.  Falls back gracefully when INFRA-2196
                // (chump disk) is not yet installed.
                let requested_n: u32 = size.parse().unwrap_or(2);
                let accept_wait = std::env::var("CHUMP_FLEET_ACCEPT_WAIT").as_deref() == Ok("1");
                let gate_decision =
                    disk_plan_gate::check("sonnet_dispatch_with_worktree", requested_n, &repo_root);
                let effective_n: u32 = match gate_decision {
                    disk_plan_gate::DiskPlanDecision::Ok => requested_n,
                    disk_plan_gate::DiskPlanDecision::Wait { recommended_n } => {
                        if accept_wait {
                            eprintln!(
                                "[fleet up] WARN: disk headroom low (WAIT) for {} workers; \
                                 CHUMP_FLEET_ACCEPT_WAIT=1 — proceeding.",
                                requested_n
                            );
                            requested_n
                        } else {
                            let safe_n = recommended_n.max(1);
                            eprintln!(
                                "[fleet up] WARN: disk headroom low (WAIT); downsizing \
                                 {} → {} workers. Set CHUMP_FLEET_ACCEPT_WAIT=1 to override.",
                                requested_n, safe_n
                            );
                            // Emit ambient event.
                            let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            if let Ok(mut af) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                let _ = writeln!(
                                    af,
                                    "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_changed\",\
                                     \"from\":{requested_n},\"to\":{safe_n},\
                                     \"reason\":\"disk_budget\"}}"
                                );
                            }
                            safe_n
                        }
                    }
                    disk_plan_gate::DiskPlanDecision::Refuse { recommended_n } => {
                        let safe_n = recommended_n.max(1);
                        eprintln!(
                            "[fleet up] REFUSE: insufficient disk headroom for {} workers; \
                             auto-downsizing to {} (disk budget max-safe-N).",
                            requested_n, safe_n
                        );
                        // Emit ambient event.
                        let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        if let Ok(mut af) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            let _ = writeln!(
                                af,
                                "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_changed\",\
                                 \"from\":{requested_n},\"to\":{safe_n},\
                                 \"reason\":\"disk_budget\"}}"
                            );
                        }
                        safe_n
                    }
                };
                // Override size with the disk-gated value.
                let size = effective_n.to_string();
                let model = flag("--model")
                    .or_else(|| cfg("model"))
                    .unwrap_or_else(|| "sonnet".to_string());
                let effort = flag("--effort")
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s,m,l,xl".to_string());
                let domain = flag("--domain")
                    .or_else(|| cfg("domain"))
                    .unwrap_or_default();

                const KNOWN_HARNESSES_UP: &[&str] = &["claude", "opencode", "codex", "manual"];
                let harness = flag("--harness")
                    .or_else(|| {
                        std::env::var("CHUMP_AGENT_HARNESS")
                            .ok()
                            .filter(|v| !v.is_empty())
                    })
                    .or_else(|| cfg("harness"))
                    .unwrap_or_else(|| "claude".to_string());
                if !KNOWN_HARNESSES_UP.contains(&harness.as_str()) {
                    eprintln!(
                        "chump fleet up: unknown --harness '{harness}'. Known: {}",
                        KNOWN_HARNESSES_UP.join(", ")
                    );
                    eprintln!("  (Add a new harness to scripts/dispatch/harnesses/<name>.sh per INFRA-1045.)");
                    std::process::exit(2);
                }

                // Persist last-used config for restart.
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let last_config = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                let _ = std::fs::create_dir_all(
                    last_config.parent().unwrap_or(std::path::Path::new("/tmp")),
                );
                let _ = std::fs::write(
                    &last_config,
                    serde_json::to_string_pretty(&serde_json::json!({
                        "size": size,
                        "model": model,
                        "harness": harness,
                        "effort": effort,
                        "domain": domain,
                        "session": session,
                        "updated_at": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                    }))
                    .unwrap_or_default(),
                );

                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_MODEL", &model)
                    .env("FLEET_HARNESS", &harness)
                    .env("FLEET_EFFORT_FILTER", &effort)
                    .env("FLEET_DOMAIN_FILTER", &domain)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet up: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-1446: work-discovery query — who is working on a given topic?
            // Usage: chump fleet whoworkson <topic> [--json]
            // Sources: (a) .chump-locks/claim-*.json lease files,
            //          (b) open PR titles/branches via `gh pr list`,
            //          (c) open gap titles/AC in state.db,
            //          (d) recent ambient gap_claimed events.
            // Returns a table (or JSON) sorted by recency, deduped by gap_id.
            "whoworkson" => {
                // Collect <topic> from args after "whoworkson"; skip flags.
                let topic: String = args
                    .iter()
                    .skip(3) // chump fleet whoworkson ...
                    .find(|a| !a.starts_with('-'))
                    .cloned()
                    .unwrap_or_else(|| {
                        eprintln!("Usage: chump fleet whoworkson <topic> [--json]");
                        std::process::exit(2);
                    });
                let want_json = args.iter().any(|a| a == "--json");
                let topic_lc = topic.to_lowercase();

                // ── Result row ────────────────────────────────────────────
                #[derive(Debug)]
                struct WhoRow {
                    kind: String,     // lease | pr | gap | ambient
                    id: String,       // gap_id / PR number / event id
                    claimant: String, // agent / worktree / author
                    since: String,    // ISO timestamp (for sort)
                    matches: String,  // excerpt that triggered the match
                }

                let mut rows: Vec<WhoRow> = Vec::new();
                // Deduplicate by (kind, id) — accumulate seen gap IDs across sources.
                let mut seen_gap_ids: std::collections::HashSet<String> =
                    std::collections::HashSet::new();

                let locks_dir = repo_root.join(".chump-locks");

                // ── (a) Active lease files ────────────────────────────────
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                        // Only claim-*.json lease files.
                        if !name.starts_with("claim-") || !name.ends_with(".json") {
                            continue;
                        }
                        let Ok(raw) = std::fs::read_to_string(&path) else {
                            continue;
                        };
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) else {
                            continue;
                        };
                        let gap_id = v
                            .get("gap_id")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let purpose = v
                            .get("purpose")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let session_id = v
                            .get("session_id")
                            .and_then(|x| x.as_str())
                            .unwrap_or(name)
                            .to_string();
                        let taken_at = v
                            .get("taken_at")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let paths_str = v
                            .get("paths")
                            .and_then(|x| x.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|p| p.as_str())
                                    .collect::<Vec<_>>()
                                    .join(",")
                            })
                            .unwrap_or_default();

                        // Check for topic match (case-insensitive) across gap_id, purpose, paths.
                        let haystack =
                            format!("{} {} {}", gap_id, purpose, paths_str).to_lowercase();
                        if !haystack.contains(topic_lc.as_str()) {
                            continue;
                        }
                        let key = format!("lease:{gap_id}");
                        if seen_gap_ids.contains(&key) {
                            continue;
                        }
                        seen_gap_ids.insert(key);
                        rows.push(WhoRow {
                            kind: "lease".to_string(),
                            id: gap_id.clone(),
                            claimant: session_id,
                            since: taken_at,
                            matches: format!("lease: {name}"),
                        });
                    }
                }

                // ── (b) Open PRs via `gh pr list` ─────────────────────────
                {
                    let gh_out = std::process::Command::new("gh")
                        .args([
                            "pr",
                            "list",
                            "--state",
                            "open",
                            "--json",
                            "number,title,headRefName,createdAt,author",
                            "--limit",
                            "200",
                        ])
                        .current_dir(&repo_root)
                        .output();
                    if let Ok(out) = gh_out {
                        let text = String::from_utf8_lossy(&out.stdout);
                        if let Ok(arr) = serde_json::from_str::<serde_json::Value>(&text) {
                            if let Some(prs) = arr.as_array() {
                                for pr in prs {
                                    let number = pr
                                        .get("number")
                                        .and_then(|x| x.as_i64())
                                        .map(|n| n.to_string())
                                        .unwrap_or_default();
                                    let title = pr
                                        .get("title")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let branch = pr
                                        .get("headRefName")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let created_at = pr
                                        .get("createdAt")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let author = pr
                                        .get("author")
                                        .and_then(|x| x.get("login"))
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("unknown")
                                        .to_string();

                                    let haystack = format!("{} {}", title, branch).to_lowercase();
                                    if !haystack.contains(topic_lc.as_str()) {
                                        continue;
                                    }
                                    // Try to extract gap ID from branch/title.
                                    let gap_id = {
                                        let combined = format!("{} {}", branch, title);
                                        // Pattern: INFRA-NNN, PRODUCT-NNN, etc.
                                        let mut found = String::new();
                                        for word in combined.split_whitespace() {
                                            let w = word.trim_matches(|c: char| {
                                                !c.is_alphanumeric() && c != '-'
                                            });
                                            if w.contains('-') {
                                                let parts: Vec<&str> = w.splitn(2, '-').collect();
                                                if parts.len() == 2
                                                    && parts[0]
                                                        .chars()
                                                        .all(|c| c.is_ascii_uppercase())
                                                    && parts[1].chars().all(|c| c.is_ascii_digit())
                                                    && parts[0].len() >= 3
                                                {
                                                    found = w.to_string();
                                                    break;
                                                }
                                            }
                                        }
                                        if found.is_empty() {
                                            format!("PR#{number}")
                                        } else {
                                            found
                                        }
                                    };
                                    let key = format!("pr:{gap_id}");
                                    if seen_gap_ids.contains(&key) {
                                        continue;
                                    }
                                    seen_gap_ids.insert(key);
                                    rows.push(WhoRow {
                                        kind: "pr".to_string(),
                                        id: gap_id,
                                        claimant: author,
                                        since: created_at,
                                        matches: format!("PR#{number}: {title}"),
                                    });
                                }
                            }
                        }
                    }
                }

                // ── (c) Open gap titles/AC in state.db ───────────────────
                {
                    use chump_gap_store as gap_store;
                    if let Ok(store) = gap_store::GapStore::open(&repo_root) {
                        let _ = store.auto_seed_if_empty();
                        if let Ok(all_gaps) = store.list(Some("open")) {
                            for g in &all_gaps {
                                let haystack =
                                    format!("{} {} {}", g.id, g.title, g.acceptance_criteria)
                                        .to_lowercase();
                                if !haystack.contains(topic_lc.as_str()) {
                                    continue;
                                }
                                let key = format!("gap:{}", g.id);
                                if seen_gap_ids.contains(&key) {
                                    continue;
                                }
                                seen_gap_ids.insert(key);
                                // Use created_at (unix) → ISO string for sort.
                                let since = if g.opened_date.is_empty() {
                                    use chrono::TimeZone;
                                    chrono::Utc
                                        .timestamp_opt(g.created_at, 0)
                                        .single()
                                        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
                                        .unwrap_or_default()
                                } else {
                                    format!("{}T00:00:00Z", g.opened_date)
                                };
                                let excerpt: String = g.title.chars().take(60).collect();
                                rows.push(WhoRow {
                                    kind: "gap".to_string(),
                                    id: g.id.clone(),
                                    claimant: "open (unclaimed)".to_string(),
                                    since,
                                    matches: excerpt,
                                });
                            }
                        }
                    }
                }

                // ── (d) Recent ambient gap_claimed events ─────────────────
                {
                    let ambient_path = locks_dir.join("ambient.jsonl");
                    // Scan last 500 lines for recency.
                    if let Ok(content) = std::fs::read_to_string(&ambient_path) {
                        let recent_lines: Vec<&str> = content
                            .lines()
                            .rev()
                            .take(500)
                            .collect::<Vec<_>>()
                            .into_iter()
                            .rev()
                            .collect();
                        for line in recent_lines {
                            if !line.contains("gap_claimed") {
                                continue;
                            }
                            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                                continue;
                            };
                            let kind_field = v.get("kind").and_then(|x| x.as_str()).unwrap_or("");
                            if kind_field != "gap_claimed" {
                                continue;
                            }
                            let gap_id = v
                                .get("gap_id")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string();
                            let ts = v
                                .get("ts")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string();
                            let session = v
                                .get("session_id")
                                .or_else(|| v.get("session"))
                                .and_then(|x| x.as_str())
                                .unwrap_or("unknown")
                                .to_string();

                            let haystack = format!("{} {}", gap_id, line).to_lowercase();
                            if !haystack.contains(topic_lc.as_str()) {
                                continue;
                            }
                            let key = format!("ambient:{gap_id}");
                            if seen_gap_ids.contains(&key) {
                                continue;
                            }
                            seen_gap_ids.insert(key);
                            rows.push(WhoRow {
                                kind: "ambient".to_string(),
                                id: gap_id,
                                claimant: session,
                                since: ts,
                                matches: "gap_claimed event".to_string(),
                            });
                        }
                    }
                }

                // ── Sort by recency (most recent first) ───────────────────
                rows.sort_by(|a, b| b.since.cmp(&a.since));

                // ── Render ────────────────────────────────────────────────
                if want_json {
                    let out: Vec<serde_json::Value> = rows
                        .iter()
                        .map(|r| {
                            serde_json::json!({
                                "type": r.kind,
                                "id": r.id,
                                "claimant": r.claimant,
                                "since": r.since,
                                "matches": r.matches,
                            })
                        })
                        .collect();
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "topic": topic,
                            "results": out,
                        }))
                        .unwrap_or_default()
                    );
                } else if rows.is_empty() {
                    println!("No active work found matching '{topic}'.");
                } else {
                    // Table: type / id / claimant / since / matches
                    let col_widths = (8usize, 20usize, 28usize, 22usize);
                    println!(
                        "{:<width0$}  {:<width1$}  {:<width2$}  {:<width3$}  MATCHES",
                        "TYPE",
                        "ID",
                        "CLAIMANT",
                        "SINCE",
                        width0 = col_widths.0,
                        width1 = col_widths.1,
                        width2 = col_widths.2,
                        width3 = col_widths.3,
                    );
                    println!("{}", "-".repeat(100));
                    for r in &rows {
                        let since_short: String = r.since.chars().take(19).collect();
                        let claimant_short: String =
                            r.claimant.chars().take(col_widths.2).collect();
                        let id_short: String = r.id.chars().take(col_widths.1).collect();
                        println!(
                            "{:<width0$}  {:<width1$}  {:<width2$}  {:<width3$}  {}",
                            r.kind,
                            id_short,
                            claimant_short,
                            since_short,
                            r.matches,
                            width0 = col_widths.0,
                            width1 = col_widths.1,
                            width2 = col_widths.2,
                            width3 = col_widths.3,
                        );
                    }
                }
                return Ok(());
            }
            // INFRA-1568: broad canary — exec the lane-readiness script.
            // Exits 0 iff every production workflow step passes on the
            // candidate lane; non-zero with a named failing-step list.
            "canary" => {
                let lane = flag("--lane").unwrap_or_default();
                let script = repo_root.join("scripts/setup/test-runner-lane-broad-canary.sh");
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&script);
                if !lane.is_empty() {
                    cmd.arg("--lane").arg(&lane);
                }
                // Pass through --json and --record-baseline if present.
                if args.iter().any(|a| a == "--json") {
                    cmd.arg("--json");
                }
                if args.iter().any(|a| a == "--record-baseline") {
                    cmd.arg("--record-baseline");
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet canary: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            // FLEET-037 + RESILIENT-073: ergonomic primary verb — alias for
            // "stop". Also writes AUTONOMY_LEVEL=0 (kill switch).
            "down" => {
                let al_path = autonomy_level::default_path();
                match autonomy_level::write_level(0, &al_path) {
                    Ok(()) => eprintln!(
                        "chump fleet down: AUTONOMY_LEVEL=0 written to {}",
                        al_path.display()
                    ),
                    Err(e) => {
                        eprintln!("chump fleet down: WARNING: could not write AUTONOMY_LEVEL: {e}")
                    }
                }
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", "0")
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet down: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-1995 (THE FLOOR Phase 2): single-pane fleet pulse.
            // Aggregates floor_temp + fleet_hold + active leases + recent
            // wedge/admin-merge/alert/cluster events into one operator-readable
            // frame. Replaces the 5-surface query workflow.
            "pulse" => {
                let want_json = args.iter().any(|a| a == "--json");
                let repo_root = repo_path::repo_root();
                let pulse = fleet_pulse::build(&repo_root);
                if want_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&pulse).unwrap_or_else(|_| "{}".to_string())
                    );
                } else {
                    print!("{}", fleet_pulse::render_text(&pulse));
                }
                // Exit code: 2 if fleet HOLD active, 1 if HOT, else 0.
                let code = if pulse.fleet_hold.active {
                    2
                } else if matches!(pulse.floor_temp.temp, floor_temp::FloorTemp::Hot) {
                    1
                } else {
                    0
                };
                std::process::exit(code);
            }
            // INFRA-2225: operator surface for the pr-auto-rebase daemon —
            // current BEHIND+armed PR count (from the local GitHub cache,
            // no live `gh` call) plus how long the backlog has been aging.
            "rebase-queue" => {
                let want_json = args.iter().any(|a| a == "--json");
                let repo_root = repo_path::repo_root();
                let status = rebase_queue::build(&repo_root);
                if want_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&status).unwrap_or_else(|_| "{}".to_string())
                    );
                } else {
                    print!("{}", rebase_queue::render_text(&status));
                }
                // Exit 1 when the BEHIND backlog is aging past 15 min — the
                // same saturation signature as the 2026-05-29 overnight
                // incident this gap was filed from.
                let code = if status.backlog_age_secs > 900 { 1 } else { 0 };
                std::process::exit(code);
            }
            "mode" => {
                // INFRA-1718: fleet-mode surface — auth + backend + cost
                // ceiling snapshot so agents stop misrouting work to a
                // broken cascade or an unusable auth path. Read-only, no
                // network/gh calls.
                let want_json = args.iter().any(|a| a == "--json");
                let effort_tier = flag("--effort").unwrap_or_default();
                let mode = fleet_mode::compute(&effort_tier);
                if want_json {
                    println!("{}", fleet_mode::render_json(&mode));
                } else {
                    println!("{}", fleet_mode::render_line(&mode));
                }
                std::process::exit(if mode.auth_usable { 0 } else { 1 });
            }
            "log-triage" => {
                // INFRA-1891: daily structured pass over ambient.jsonl x
                // state.db — replaces the ad-hoc "maybe I should review the
                // logs" habit with a bounded (<=5 finding) Markdown/JSON
                // report the operator gates before filing gaps.
                let want_json = args.iter().any(|a| a == "--json");
                let window_h: u64 = flag("--window-h")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(24);
                let rare_threshold: u64 = flag("--rare-threshold")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(40);

                let cfg = log_triage::TriageConfig {
                    repo_root: repo_root.clone(),
                    window_h,
                    rare_threshold,
                };
                match log_triage::run_triage(&cfg) {
                    Ok(report) => {
                        let scan_date = chrono::Utc::now().format("%Y-%m-%d").to_string();
                        match log_triage::write_report(&repo_root, &report, &scan_date) {
                            Ok(path) => {
                                log_triage::emit_ambient_events(&repo_root, &report);
                                if want_json {
                                    println!("{}", log_triage::render_json(&report));
                                } else {
                                    println!(
                                        "chump fleet log-triage: wrote {} ({} findings, {} parse errors)",
                                        path.display(),
                                        report.findings.len(),
                                        report.parse_errors
                                    );
                                }
                                std::process::exit(0);
                            }
                            Err(e) => {
                                eprintln!("chump fleet log-triage: failed to write report: {e}");
                                std::process::exit(1);
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("chump fleet log-triage: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "doctor" => {
                // INFRA-1595: fleet doctor — Wave 0b autonomy outer loop.
                //
                // Modes:
                //   (default)   diagnose-only (placeholder until INFRA-1427
                //               --strict lands; emits self_doctor_tick).
                //   --heal      auto-fix what's diagnosed. GATED on
                //               CHUMP_FLEET_SELF_DOCTOR_HEAL=true env (opt-in
                //               until INFRA-1541 50-PR observation phase done).
                //   --json      machine-readable output.
                let want_heal = args.iter().any(|a| a == "--heal");
                let want_json = args.iter().any(|a| a == "--json");
                let env_opt_in = std::env::var("CHUMP_FLEET_SELF_DOCTOR_HEAL")
                    .map(|v| v == "true" || v == "1")
                    .unwrap_or(false);

                if want_heal && !env_opt_in {
                    if want_json {
                        println!(
                            "{}",
                            serde_json::json!({
                                "status": "skipped",
                                "reason": "CHUMP_FLEET_SELF_DOCTOR_HEAL not set to true",
                                "hint": "Default-off until INFRA-1541 50-PR observation done."
                            })
                        );
                    } else {
                        eprintln!(
                            "chump fleet doctor --heal: refusing to run.\n  \
                             Heal mode is opt-in. Set CHUMP_FLEET_SELF_DOCTOR_HEAL=true to enable.\n  \
                             Default-off until INFRA-1541 50-PR observation phase completes."
                        );
                    }
                    std::process::exit(0);
                }

                if want_heal {
                    let cfg = fleet_self_doctor::HealConfig::default();
                    let outcome = fleet_self_doctor::run_heal_cycle(&cfg);
                    if want_json {
                        println!(
                            "{}",
                            serde_json::json!({
                                "mode": "heal",
                                "idle": outcome.idle,
                                "daemons_installed": outcome.daemons_installed,
                                "daemons_failed": outcome.daemons_failed,
                                "prs_dispatched": outcome.prs_dispatched
                                    .iter()
                                    .map(|(n, g)| serde_json::json!({"pr": n, "gap_id": g}))
                                    .collect::<Vec<_>>(),
                                "prs_failed": outcome.prs_failed,
                                "budget_hit": outcome.budget_hit,
                            })
                        );
                    } else {
                        println!("chump fleet doctor --heal:");
                        if outcome.idle {
                            println!("  idle — nothing to heal this cycle");
                        }
                        if !outcome.daemons_installed.is_empty() {
                            println!(
                                "  daemons installed: {}",
                                outcome.daemons_installed.join(", ")
                            );
                        }
                        if !outcome.daemons_failed.is_empty() {
                            println!("  daemons FAILED: {}", outcome.daemons_failed.join(", "));
                        }
                        if !outcome.prs_dispatched.is_empty() {
                            println!(
                                "  PRs dispatched: {}",
                                outcome
                                    .prs_dispatched
                                    .iter()
                                    .map(|(n, g)| format!("#{n} ({g})"))
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            );
                        }
                        if outcome.budget_hit {
                            println!(
                                "  BUDGET HIT — operator paged via .chump-locks/operator-action-needed.json"
                            );
                        }
                    }
                    std::process::exit(0);
                }

                // Diagnose-only placeholder. Emits a tick so consumers can
                // see the doctor ran. INFRA-1427 will replace this with the
                // full --strict implementation.
                let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                    kind: "self_doctor_tick".to_string(),
                    source: Some("fleet_self_doctor".to_string()),
                    fields: vec![("status".to_string(), "diagnose_only".to_string())],
                    ..Default::default()
                });

                // INFRA-1522 (W-007): required-check health gate runs in
                // diagnose mode too. Exits 1 on any unhealthy required
                // check so `chump fleet doctor` becomes the trip-wire for
                // the W-007 wedge class (path-filtered SKIPPED, flake rate
                // >20%, etc.).
                let provider = required_check_health::default_provider();
                let required_contexts = list_required_contexts();
                let health_report = if required_contexts.is_empty() {
                    None
                } else {
                    let report = required_check_health::evaluate(&required_contexts, &provider);
                    if report.any_unhealthy {
                        required_check_health::emit_warn_for_unhealthy(&report, None);
                    }
                    Some(report)
                };

                // INFRA-1544: self-hosted runner liveness check — AC #2
                // Query gh api to ensure at least 1 runner is online before
                // refusing to start the fleet.
                let mut runner_check_result: Option<self_hosted_runner_check::RunnerCheckResult> =
                    None;
                match self_hosted_runner_check::check_runner_health() {
                    Ok(result) => {
                        self_hosted_runner_check::emit_runner_status(&result);
                        runner_check_result = Some(result);
                    }
                    Err(e) => {
                        // Runner check failed (e.g., gh api unreachable).
                        // Fail open (allow fleet doctor to continue) since
                        // connectivity issues are transient. Operator will
                        // see the error in the output.
                        if !want_json {
                            eprintln!("self-hosted runner check error: {}", e);
                        }
                    }
                };

                // INFRA-2364: default mode now shells out to the strict
                // health aggregator (INFRA-1427,
                // scripts/coord/fleet-doctor-strict.sh) instead of only
                // running the required-check gate. Falls back cleanly
                // (no-op) when the script isn't present — e.g. isolated
                // test fixtures that aren't a full chump checkout.
                let repo_root_for_strict = repo_path::repo_root();
                let strict_script =
                    repo_root_for_strict.join("scripts/coord/fleet-doctor-strict.sh");
                let strict_timeout_s: u64 = std::env::var("CHUMP_FLEET_DOCTOR_STRICT_TIMEOUT_S")
                    .ok()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(30);

                // (exit_code, duration_ms, failure_class, status)
                let mut strict_outcome: Option<(i32, u128, &'static str, &'static str)> = None;

                if strict_script.is_file() {
                    let start = std::time::Instant::now();
                    let mut cmd = std::process::Command::new("bash");
                    cmd.arg(&strict_script);
                    if want_json {
                        cmd.arg("--json");
                    }
                    match cmd.spawn() {
                        Ok(mut child) => {
                            let deadline = start + std::time::Duration::from_secs(strict_timeout_s);
                            let mut timed_out = false;
                            let wait_status = loop {
                                match child.try_wait() {
                                    Ok(Some(status)) => break Some(status),
                                    Ok(None) => {
                                        if std::time::Instant::now() >= deadline {
                                            let _ = child.kill();
                                            let _ = child.wait();
                                            timed_out = true;
                                            break None;
                                        }
                                        std::thread::sleep(std::time::Duration::from_millis(200));
                                    }
                                    Err(_) => break None,
                                }
                            };
                            let duration_ms = start.elapsed().as_millis();
                            strict_outcome = Some(if timed_out {
                                (124, duration_ms, "transient", "timeout")
                            } else if let Some(status) = wait_status {
                                let code = status.code().unwrap_or(-1);
                                if code == 0 {
                                    (code, duration_ms, "none", "healthy")
                                } else {
                                    (code, duration_ms, "permanent", "unhealthy")
                                }
                            } else {
                                (-1, duration_ms, "transient", "spawn_error")
                            });
                        }
                        Err(_) => {
                            strict_outcome = Some((-1, 0, "transient", "spawn_error"));
                        }
                    }

                    // Cost note (AC #2): this is a deterministic shell
                    // aggregator over local state + `gh`/`git` calls, not an
                    // LLM call — there is no token cost to track. duration_ms
                    // below is the operational cost signal operators care
                    // about (a doctor run that creeps past its historical
                    // p50 is the actionable proxy).
                    if let Some((code, duration_ms, failure_class, status)) = strict_outcome {
                        // scanner-anchor: "kind":"fleet_doctor_strict_tick"
                        let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                            kind: "fleet_doctor_strict_tick".to_string(),
                            source: Some("fleet_self_doctor".to_string()),
                            fields: vec![
                                ("exit_code".to_string(), code.to_string()),
                                ("duration_ms".to_string(), duration_ms.to_string()),
                                ("failure_class".to_string(), failure_class.to_string()),
                                ("status".to_string(), status.to_string()),
                            ],
                            ..Default::default()
                        });
                    }
                }

                if want_json {
                    println!(
                        "{}",
                        serde_json::json!({
                            "mode": "diagnose",
                            "required_check_health": health_report.as_ref().map(|r| serde_json::json!({
                                "any_unhealthy": r.any_unhealthy,
                                "checks": r.checks,
                            })),
                            "self_hosted_runner": runner_check_result.as_ref().map(|r| serde_json::json!({
                                "online_count": r.online_count,
                                "offline_count": r.offline_count,
                                "busy_count": r.busy_count,
                                "total_count": r.total_count,
                                "healthy": r.healthy,
                                "detail": r.detail,
                            })),
                            "strict": strict_outcome.map(|(code, duration_ms, failure_class, status)| serde_json::json!({
                                "exit_code": code,
                                "duration_ms": duration_ms,
                                "failure_class": failure_class,
                                "status": status,
                            })),
                            "note": "diagnose-only; --heal auto-fixes what INFRA-1427 strict + required-check gates surface"
                        })
                    );
                } else {
                    println!("chump fleet doctor: diagnose-only mode (pass --heal to auto-fix).");
                    if let Some(r) = &health_report {
                        if r.any_unhealthy {
                            println!("\n{}", r.refuse_message());
                        } else {
                            println!("  required-check health: {} checks OK", r.checks.len());
                        }
                    }
                    if let Some(r) = &runner_check_result {
                        let status_str = if r.healthy { "✓" } else { "✗" };
                        println!(
                            "  self-hosted runners: {} {} (online={}, offline={}, total={})",
                            status_str, r.detail, r.online_count, r.offline_count, r.total_count
                        );
                    }
                    if let Some((code, duration_ms, failure_class, status)) = strict_outcome {
                        println!(
                            "  strict health ({}): exit={} duration_ms={} failure_class={}",
                            status, code, duration_ms, failure_class
                        );
                    } else if !strict_script.is_file() {
                        println!(
                            "  strict health: skipped (script not found at {})",
                            strict_script.display()
                        );
                    }
                }

                let exit_code = if health_report.as_ref().is_some_and(|r| r.any_unhealthy)
                    || strict_outcome.is_some_and(|(code, ..)| code != 0)
                    || runner_check_result.as_ref().is_some_and(|r| !r.healthy)
                {
                    1
                } else {
                    0
                };
                std::process::exit(exit_code);
            }
            // INFRA-1483: declarative spec primitive (Marcus M-B). Plan
            // shows the gap set without mutating; apply reserves; spec-status
            // aggregates progress by spec_name.
            "plan" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fleet plan <spec.yaml>");
                        std::process::exit(2);
                    }
                };
                match fleet_spec::FleetSpec::from_path(&path) {
                    Ok(spec) => {
                        let plan = spec.plan();
                        if args.iter().any(|a| a == "--json") {
                            println!("{}", serde_json::to_string_pretty(&plan).unwrap());
                        } else {
                            print!("{}", fleet_spec::render_plan(&plan));
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "apply" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fleet apply <spec.yaml> [--dry-run]");
                        std::process::exit(2);
                    }
                };
                let dry_run = args.iter().any(|a| a == "--dry-run");
                match fleet_spec::FleetSpec::from_path(&path) {
                    Ok(spec) => {
                        let plan = spec.plan();
                        println!(
                            "fleet-spec apply: {} gap(s) would be reserved (spec={}, dry_run={dry_run})",
                            plan.len(),
                            spec.name
                        );
                        for (i, g) in plan.iter().enumerate() {
                            if dry_run {
                                println!("  [dry-run] {} | {}", i + 1, g.title);
                                continue;
                            }
                            // Reserve via the chump CLI to keep this dispatch
                            // single-process-friendly. spec_name lives in notes
                            // for `chump fleet spec-status` aggregation.
                            let notes = format!(
                                "spec_name={}\\nvalidation: {}\\nsuccess: {}\\nbindings: {}",
                                g.spec_name,
                                g.validation,
                                g.success,
                                g.bindings
                                    .iter()
                                    .map(|(k, v)| format!("{k}={v}"))
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            );
                            let chump_bin =
                                std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                            let out = std::process::Command::new(&chump_bin)
                                .args([
                                    "gap", "reserve", "--domain", &g.domain, "--title", &g.title,
                                    "--effort", &g.effort, "--notes", &notes,
                                ])
                                .output();
                            match out {
                                Ok(o) if o.status.success() => {
                                    let id = String::from_utf8_lossy(&o.stdout)
                                        .lines()
                                        .find(|l| l.contains("INFRA-") || l.contains("-"))
                                        .map(|s| s.trim().to_string())
                                        .unwrap_or_else(|| "?".to_string());
                                    println!("  [reserved] {} → {}", g.title, id);
                                }
                                Ok(o) => {
                                    eprintln!(
                                        "  [failed] {}: {}",
                                        g.title,
                                        String::from_utf8_lossy(&o.stderr).trim()
                                    );
                                    std::process::exit(1);
                                }
                                Err(e) => {
                                    eprintln!("  [failed] {}: spawn error: {e}", g.title);
                                    std::process::exit(1);
                                }
                            }
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "spec-status" => {
                let name = match args.get(3) {
                    Some(n) => n.clone(),
                    None => {
                        eprintln!("Usage: chump fleet spec-status <spec-name>");
                        std::process::exit(2);
                    }
                };
                // Aggregate via `chump gap list` + grep on the notes column.
                let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                let out = std::process::Command::new(&chump_bin)
                    .args(["gap", "list", "--json"])
                    .output();
                let Ok(o) = out else {
                    eprintln!("error: could not exec chump gap list");
                    std::process::exit(1);
                };
                let needle = format!("spec_name={name}");
                let body = String::from_utf8_lossy(&o.stdout);
                let mut total = 0;
                let mut counts = std::collections::HashMap::<String, usize>::new();
                // Lenient parse: one JSON object per line OR a single array.
                let entries: Vec<serde_json::Value> = if body.trim_start().starts_with('[') {
                    serde_json::from_str(&body).unwrap_or_default()
                } else {
                    body.lines()
                        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                        .collect()
                };
                for e in &entries {
                    let notes = e.get("notes").and_then(|v| v.as_str()).unwrap_or("");
                    if notes.contains(&needle) {
                        total += 1;
                        let status = e
                            .get("status")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown")
                            .to_string();
                        *counts.entry(status).or_insert(0) += 1;
                    }
                }
                if total == 0 {
                    println!("no gaps found for spec {name}");
                    std::process::exit(0);
                }
                println!("fleet-spec status: {name}  ({total} gap(s))");
                for (status, n) in &counts {
                    println!("  {status}: {n}");
                }
                std::process::exit(0);
            }
            // EFFECTIVE-025: chump fleet autopilot — META-090 CLI parity arm.
            // Proxies to scripts/coord/fleet-autopilot.sh (bash orchestrator) with
            // pass-through of subcommand + remaining args. Subcommands:
            // start/stop/status/restart/heartbeat. Default = "status" when no
            // subcommand given (mirrors fleet-autopilot.sh's own default).
            "autopilot" => {
                if !fleet_autopilot_sh.exists() {
                    eprintln!(
                        "chump fleet autopilot: {} not found — META-090 may not be installed",
                        fleet_autopilot_sh.display()
                    );
                    std::process::exit(1);
                }
                let autopilot_sub = args.get(3).map(String::as_str).unwrap_or("status");
                let passthrough: Vec<String> = args.iter().skip(4).cloned().collect();
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&fleet_autopilot_sh).arg(autopilot_sub);
                for a in &passthrough {
                    cmd.arg(a);
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet autopilot: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-2176: open Fleet Scrubber UI in the default browser.
            // Delegates to scripts/dev/chump-fleet-view.sh which handles
            // macOS (`open`) and Linux (`xdg-open`) and the --fixtures flag
            // for dev/demo mode without the server.
            "view" => {
                let view_sh = repo_root.join("scripts/dev/chump-fleet-view.sh");
                if !view_sh.exists() {
                    eprintln!(
                        "chump fleet view: {} not found — INFRA-2176 may not be installed",
                        view_sh.display()
                    );
                    std::process::exit(1);
                }
                let passthrough: Vec<String> = args.iter().skip(3).cloned().collect();
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&view_sh);
                for a in &passthrough {
                    cmd.arg(a);
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet view: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-2239: chump fleet curator-status — one row per curator with
            // role / last_tick_succeeded_at / last_heartbeat_at / state.db_mutations_1h
            // / supervisor_mode / autorestart_flag.
            "curator-status" => {
                let want_json = args.iter().any(|a| a == "--json");
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let state_db = chump_gap_store::store_path::state_db_path(&repo_root); // INFRA-8190
                let _log_dir = repo_root.join(".chump-locks/autopilot-logs");

                // Supervisor config from env (mirrors crate defaults).
                let supervisor_mode = std::env::var("CHUMP_CURATOR_SUPERVISOR_MODE")
                    .unwrap_or_else(|_| "aggressive".to_string());
                let autorestart = std::env::var("CHUMP_CURATOR_SUPERVISOR_AUTORESTART")
                    .map(|v| v != "0" && v != "false")
                    .unwrap_or(true);

                let roles = &[
                    "shepherd",
                    "target",
                    "handoff",
                    "ci-audit",
                    "decompose",
                    "md-links",
                ];

                // Parse last 2000 lines of ambient.jsonl once for heartbeats.
                let ambient_lines: Vec<String> = if ambient_path.exists() {
                    std::fs::read_to_string(&ambient_path)
                        .unwrap_or_default()
                        .lines()
                        .map(|l| l.to_string())
                        .rev()
                        .take(2000)
                        .collect::<Vec<_>>()
                } else {
                    Vec::new()
                };

                // For each role: find latest curator_heartbeat ts.
                let last_heartbeat_for = |role: &str| -> Option<String> {
                    for line in &ambient_lines {
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                            continue;
                        };
                        if v.get("kind").and_then(|k| k.as_str()) == Some("curator_heartbeat")
                            && v.get("role").and_then(|r| r.as_str()) == Some(role)
                        {
                            return v.get("ts").and_then(|t| t.as_str()).map(|s| s.to_string());
                        }
                    }
                    None
                };

                // For each role: find latest curator_failure_paged ts (as last_tick_succeeded proxy).
                // A tick that succeeded = no curator_failure_paged since the last heartbeat.
                // Simplified: last_tick_succeeded = same as last_heartbeat (when healthy).
                let last_failure_for = |role: &str| -> Option<String> {
                    for line in &ambient_lines {
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                            continue;
                        };
                        if v.get("kind").and_then(|k| k.as_str()) == Some("curator_failure_paged")
                            && v.get("role").and_then(|r| r.as_str()) == Some(role)
                        {
                            return v.get("ts").and_then(|t| t.as_str()).map(|s| s.to_string());
                        }
                    }
                    None
                };

                // Query state.db for gap mutations attributed to role's session_id in last 1h.
                let mutations_1h = |role: &str| -> i64 {
                    let Ok(conn) = crate::db_pool::open_sqlite_wal(&state_db) else {
                        return -1;
                    };
                    let has_table: bool = conn.query_row(
                        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='gap_history'",
                        [], |r| r.get::<_, i64>(0),
                    ).unwrap_or(0) > 0;
                    if !has_table {
                        return -1;
                    }
                    let date_str = chrono::Utc::now().format("%Y-%m-%d").to_string();
                    let session_id = format!("curator-opus-{role}-{date_str}");
                    let cutoff = (chrono::Utc::now() - chrono::Duration::hours(1))
                        .format("%Y-%m-%dT%H:%M:%SZ")
                        .to_string();
                    conn.query_row(
                        "SELECT COUNT(*) FROM gap_history WHERE session_id = ?1 AND created_at >= ?2",
                        rusqlite::params![session_id, cutoff],
                        |r| r.get(0),
                    ).unwrap_or(0)
                };

                if want_json {
                    let rows: Vec<serde_json::Value> = roles
                        .iter()
                        .map(|role| {
                            let hb = last_heartbeat_for(role);
                            let fail = last_failure_for(role);
                            let mut_count = mutations_1h(role);
                            // last_tick_succeeded = heartbeat ts when no recent failure, else "degraded".
                            let tick_status = if fail.is_some() {
                                "degraded".to_string()
                            } else {
                                hb.clone().unwrap_or_else(|| "never".to_string())
                            };
                            serde_json::json!({
                                "role": role,
                                "last_tick_succeeded_at": tick_status,
                                "last_heartbeat_at": hb.unwrap_or_else(|| "never".to_string()),
                                "state_db_mutations_1h": mut_count,
                                "supervisor_mode": supervisor_mode,
                                "autorestart": autorestart,
                            })
                        })
                        .collect();
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&rows).unwrap_or_else(|_| "[]".to_string())
                    );
                } else {
                    println!(
                        "{:<12} {:<28} {:<28} {:>12}  {:<12} {:<11}",
                        "ROLE",
                        "LAST_TICK_OK",
                        "LAST_HEARTBEAT",
                        "MUTATIONS_1H",
                        "SUPERVISOR",
                        "AUTORESTART"
                    );
                    println!("{}", "-".repeat(110));
                    for role in roles {
                        let hb = last_heartbeat_for(role);
                        let fail = last_failure_for(role);
                        let mut_count = mutations_1h(role);
                        let tick_str = if fail.is_some() {
                            "DEGRADED".to_string()
                        } else {
                            hb.clone().unwrap_or_else(|| "never".to_string())
                        };
                        let hb_str = hb.unwrap_or_else(|| "never".to_string());
                        let mut_str = if mut_count < 0 {
                            "n/a".to_string()
                        } else {
                            mut_count.to_string()
                        };
                        let restart_str = if autorestart { "on" } else { "off" };
                        println!(
                            "{:<12} {:<28} {:<28} {:>12}  {:<12} {:<11}",
                            role, tick_str, hb_str, mut_str, supervisor_mode, restart_str
                        );
                    }
                }
                return Ok(());
            }
            // ── chump fleet external-repo <status|enable|disable> [--json] (INFRA-8604) ──
            "external-repo" => {
                let rest: Vec<String> = args.iter().skip(3).cloned().collect();
                let rc =
                    chump_coord::worker::capability::handle_fleet_external_repo(&rest, &repo_root);
                if rc != 0 {
                    std::process::exit(rc);
                }
                return Ok(());
            }
            _ => {
                eprintln!(
                    "Usage: chump fleet <up|down|status|scale|start|stop|level|snapshot|restore|restart|audit-pids|brief|auto-widen|auto-scale|auto-resize|prune-worktrees|daemon|whoworkson|canary|doctor|autopilot|plan|apply|spec-status|view|curator-status|external-repo>"
                );
                eprintln!("Kill switch (RESILIENT-073):");
                eprintln!(
                    "  stop        [--session NAME]  write AUTONOMY_LEVEL=0 then kill tmux workers"
                );
                eprintln!(
                    "  start       [--size N] ...    write AUTONOMY_LEVEL=5 then launch workers"
                );
                eprintln!("  level       [N]               write N to AUTONOMY_LEVEL (0=STOP); no arg = print current");
                eprintln!(
                    "              The AUTONOMY_LEVEL file is checked at every work entry-point."
                );
                eprintln!("              Fail-closed: missing/unreadable/corrupt → STOP.");
                eprintln!("Primary verbs:");
                eprintln!("  up          [--size N] [--model M] [--effort xs,s,m] [--domain D]");
                eprintln!("              (like 'start' but refuses if session already running — use 'scale' to resize)");
                eprintln!("  down        [--session NAME]  (alias for stop, also writes AUTONOMY_LEVEL=0)");
                eprintln!("  status      [--json]");
                eprintln!("  scale       N [--session NAME]");
                eprintln!("  autopilot   <start|stop|status|restart|heartbeat> [--json]");
                eprintln!("              -- META-090 single-command operator playbook (10-layer daemon set)");
                eprintln!("Aliases / advanced:");
                eprintln!("  start       [--size N] [--model M] [--effort xs,s,m] [--domain D]  (alias for up, no idempotency check)");
                eprintln!("  stop        [--session NAME]  (alias for down, also writes AUTONOMY_LEVEL=0)");
                eprintln!("  snapshot");
                eprintln!("  restore     <snapshot-id>");
                eprintln!("  restart     [--size N] [--session NAME]  (fleet-restart.sh — graceful reload)");
                eprintln!("  audit-pids  [--apply]");
                eprintln!("  brief       [--json] [--window SECS]");
                eprintln!("  auto-widen  [--apply]  -- widen effort/priority filter on starvation");
                eprintln!(
                    "  auto-scale  [--apply] [--json]  -- disk-aware up/down by 1 per tick (INFRA-2198)"
                );
                eprintln!(
                    "  auto-resize [--apply] [--json]  -- scale down on 4 conditions (INFRA-650)"
                );
                eprintln!("  prune-worktrees [--apply] [--json]  -- prune stale linked worktrees (INFRA-827)");
                eprintln!("  daemon      [--once]  -- long-lived scheduler (INFRA-964); --once runs all tasks once");
                eprintln!("  whoworkson  <topic> [--json]  -- who is working on a given topic (INFRA-1446)");
                eprintln!("  canary      [--lane LABEL] [--json] [--record-baseline]");
                eprintln!(
                    "              -- broad runner-lane canary (INFRA-1568): runs full production"
                );
                eprintln!("                 workflow end-to-end; exit 0 iff every step passes.");
                eprintln!(
                    "  doctor      [--heal] [--json]  -- self-healing autonomy loop (INFRA-1595)"
                );
                eprintln!(
                    "  log-triage  [--window-h N] [--rare-threshold N] [--json]  -- daily ambient x state.db triage report (INFRA-1891)"
                );
                eprintln!(
                    "  view        [--fixtures]  -- open Fleet Scrubber UI in browser (INFRA-2176)"
                );
                eprintln!(
                    "              -- with --fixtures: serves web/fleet-scrubber/ locally, no server needed"
                );
                std::process::exit(2);
            }
        }
    }

    // `chump gap <subcommand>` (INFRA-023) — SQLite-backed gap store.
    //
    // Subcommands: list, reserve, claim, preflight, ship, dump, import
    //
    // Examples:
    //   chump gap list [--status open] [--json]
    //   chump gap reserve --domain INFRA --title "My gap" [--priority P1] [--effort s]
    //   chump gap claim <GAP-ID> [--session <id>] [--worktree <path>]
    //   chump gap preflight <GAP-ID>
    //   chump gap ship <GAP-ID> [--session <id>]
    //   chump gap dump [--out <path>]
    //   chump gap import [--yaml docs/gaps.yaml]

    Box::pin(gap_modes::dispatch_gap_or_tail(args)).await
}
