//! INFRA-1549: `chump claim-paths <file...> [--ttl N] [--heartbeat] [--gap <id>]`
//!
//! CLI wrapper around `crates/chump-agent-lease::claim_paths` — the missing
//! invocation surface that lets a Claude Code `PreToolUse` Edit|Write hook
//! (which sees individual file edits, unlike `scripts/dispatch/worker.sh`
//! which only sees the coarse gap-level `.chump-locks/<session>.json` lease)
//! participate in path-level lease coordination.
//!
//! Layering (see docs/process/CLAUDE_GOTCHAS.md):
//!   - gap-level lease (`.chump-locks/<session>.json` via `chump claim`) —
//!     coarse-grained worker-to-worker coordination across the fleet.
//!   - path-level lease (this command, `crates/chump-agent-lease`) — nests
//!     under the session's gap-level lease, coordinates individual
//!     Edit/Write calls within a session's live worktree.
//!
//! Exit codes: 0 = claimed (or heartbeat sent). Non-zero = collision; stderr
//! carries a `LEASE_OVERLAP gap=<other-gap> session=<other-session>` line so
//! callers (the PreToolUse hook, tests) can parse the holder without
//! re-reading `.chump-locks/*.json` themselves.

use chump_agent_lease::{self, current_session_id, list_active};

fn print_usage() {
    eprintln!(
        "Usage: chump claim-paths <file...> [--ttl SECS] [--gap GAP-ID]\n       chump claim-paths --heartbeat [--ttl SECS]"
    );
}

/// Find a live lease held by another session that overlaps `path`, returning
/// (holder_session_id, holder_gap_id) so the caller can print LEASE_OVERLAP.
fn find_overlap(path: &str, my_session_id: &str) -> Option<(String, String)> {
    let candidate = path.trim_start_matches("./").trim_end_matches('/');
    for lease in list_active() {
        if lease.session_id == my_session_id {
            continue;
        }
        let overlaps = lease.paths.iter().any(|p| {
            let p = p.trim_end_matches('/');
            p == "**" || candidate == p || candidate.starts_with(&format!("{p}/")) || p.starts_with(&format!("{candidate}/"))
        });
        if overlaps {
            let gap = lease.gap_id.clone().unwrap_or_else(|| "unknown".to_string());
            return Some((lease.session_id.clone(), gap));
        }
    }
    None
}

fn run_heartbeat(ttl: u64) -> i32 {
    let session_id = current_session_id();
    let leases = list_active();
    let mine = leases.into_iter().find(|l| l.session_id == session_id);
    match mine {
        Some(mut lease) => match chump_agent_lease::heartbeat(&mut lease, Some(ttl)) {
            Ok(()) => {
                chump_agent_lease::ambient_emit(
                    "lease_heartbeat",
                    &[("session", &session_id), ("ttl_secs", &ttl.to_string())],
                );
                println!("heartbeat ok for session {session_id}");
                0
            }
            Err(e) => {
                eprintln!("chump claim-paths --heartbeat: {e:#}");
                1
            }
        },
        None => {
            // No active lease to heartbeat is not an error — session may not
            // have claimed any paths yet this cycle. Worker.sh calls this
            // unconditionally every cycle.
            0
        }
    }
}

pub fn run(args: &[String]) -> i32 {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        return 0;
    }

    let mut ttl: u64 = chump_agent_lease::DEFAULT_TTL_SECS;
    let mut gap_id: Option<String> = None;
    let mut paths: Vec<String> = Vec::new();
    let mut heartbeat = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--ttl" => {
                if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u64>().ok()) {
                    ttl = v;
                    i += 1;
                }
            }
            "--gap" => {
                if let Some(v) = args.get(i + 1) {
                    gap_id = Some(v.clone());
                    i += 1;
                }
            }
            "--heartbeat" => heartbeat = true,
            other => paths.push(other.to_string()),
        }
        i += 1;
    }

    if heartbeat {
        return run_heartbeat(ttl);
    }

    if paths.is_empty() {
        print_usage();
        return 2;
    }

    let session_id = current_session_id();

    // Check for a collision against every requested path BEFORE calling
    // claim_paths, so we can surface the LEASE_OVERLAP line with the
    // holder's gap_id (claim_paths itself only returns a session id).
    for p in &paths {
        if let Some((holder_session, holder_gap)) = find_overlap(p, &session_id) {
            eprintln!("LEASE_OVERLAP gap={holder_gap} session={holder_session}");
            chump_agent_lease::ambient_emit(
                "lease_overlap",
                &[
                    ("path", p.as_str()),
                    ("holder_session", &holder_session),
                    ("holder_gap", &holder_gap),
                ],
            );
            return 1;
        }
    }

    let purpose = gap_id
        .clone()
        .map(|g| format!("path-lease for {g}"))
        .unwrap_or_else(|| "path-lease (PreToolUse Edit|Write hook)".to_string());
    let path_refs: Vec<&str> = paths.iter().map(String::as_str).collect();

    let claim_result = if let Some(gap) = &gap_id {
        chump_agent_lease::claim_gap(gap, &path_refs, ttl, &purpose)
    } else {
        chump_agent_lease::claim_paths(&path_refs, ttl, &purpose)
    };

    match claim_result {
        Ok(_lease) => {
            chump_agent_lease::ambient_emit(
                "lease_acquired",
                &[
                    ("paths", &paths.join(",")),
                    ("ttl_secs", &ttl.to_string()),
                    ("gap", gap_id.as_deref().unwrap_or("")),
                ],
            );
            println!("claimed {} path(s) for session {session_id}", paths.len());
            0
        }
        Err(e) => {
            // claim_paths raced us between the manual check above and its own
            // internal check — treat as overlap too.
            eprintln!("LEASE_OVERLAP gap=unknown session=unknown ({e:#})");
            chump_agent_lease::ambient_emit("lease_overlap", &[("paths", &paths.join(","))]);
            1
        }
    }
}
