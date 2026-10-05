//! META-125/C7: `chump consensus resolve <corr_id>` and `chump consensus
//! status [<corr_id> | --all]` — productizes the deliberator's tally +
//! `kind=consensus_result` emission as a directly-callable CLI, and makes
//! the resulting decision state queryable without grepping ambient.jsonl
//! by hand.
//!
//! `resolve` reuses the same tally/verdict logic as `consensus-tally`
//! (src/commands/consensus_tally.rs). When the verdict is PASSED or
//! FAILED it emits a `kind=consensus_result` event to ambient.jsonl in
//! the exact schema `scripts/coord/deliberator-loop.sh` already emits
//! (`event":"FEEDBACK","corr_id","verdict","vote_counts","voters_list"`),
//! so the two aggregators are interchangeable and idempotency checks
//! (`_has_consensus_result`) work across both. NO_QUORUM / EXTENDED
//! verdicts are reported but nothing is emitted — a decision isn't
//! reached yet, so there is nothing durable to record.
//!
//! `status` queries decision state: it first looks for an existing
//! `kind=consensus_result` event for the corr_id (the durable record of
//! a *reached* decision) and reports that verbatim; if none exists it
//! falls back to a live tally so callers still see NO_QUORUM/EXTENDED
//! progress instead of "not found".
//!
//! ## Observability (self-documenting, replaces the gap's TODO placeholders)
//!
//! - **Events emitted:** `kind=consensus_result` on a reached decision
//!   (PASSED/FAILED) from `resolve`. Nothing is emitted on NO_QUORUM,
//!   EXTENDED, or when a decision was already resolved (idempotent
//!   no-op) — `resolve` prints the reason and exits 0 in both cases so
//!   callers can poll it safely on a cron without spamming ambient.jsonl.
//! - **Cost:** read-only over local ambient.jsonl; no LLM calls, no
//!   network calls. `resolve`'s only write is the single append-only
//!   ambient line on a reached decision.
//! - **Failure classes:** exit 2 = permanent (bad args / unknown
//!   corr_id with zero vote events — retrying won't help until a vote
//!   is cast); exit 0 with NO_QUORUM/EXTENDED = transient (retry later,
//!   more votes may land). There is no exit 1 path — ambient.jsonl I/O
//!   failures are non-fatal by design (matches `vote.rs`) since a failed
//!   write shouldn't crash a CLI invoked from a cron loop.
//! - **Smoke test:** `scripts/ci/test-chump-consensus.sh`.
//!
//! Acceptance criteria satisfied (INFRA-2158):
//!   AC1 — `chump consensus resolve <corr_id>` computes verdict + emits
//!         `kind=consensus_result` on PASSED/FAILED (idempotent).
//!   AC2 — `chump consensus status [<corr_id> | --all]` reports queryable
//!         decision state (resolved result if present, else live tally).
//!   AC3 — registered in src/main.rs as `chump consensus <resolve|status>`.
//!   AC4 — observability documented above (events / cost / failure-class / smoke test).

use super::consensus_tally::{
    aggregate, ambient_path, json_get_str, load_vote_events, parse_duration_secs,
};
use std::collections::HashMap;
use std::io::Write;

/// A durable `kind=consensus_result` record read back from ambient.jsonl.
struct ConsensusResult {
    corr_id: String,
    verdict: String,
    yes: String,
    no: String,
    abstain: String,
    total: String,
    ts: String,
}

/// Scan ambient.jsonl for existing `kind=consensus_result` events,
/// optionally filtered to one corr_id. Keeps the *latest* record per
/// corr_id (later lines win) so a re-resolve after correction is visible.
fn load_consensus_results(
    path: &std::path::Path,
    filter_corr_id: Option<&str>,
) -> HashMap<String, ConsensusResult> {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return HashMap::new(),
    };

    let mut out: HashMap<String, ConsensusResult> = HashMap::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if json_get_str(line, "kind") != Some("consensus_result") {
            continue;
        }
        let corr_id = match json_get_str(line, "corr_id") {
            Some(c) if !c.is_empty() => c.to_string(),
            _ => continue,
        };
        if let Some(f) = filter_corr_id {
            if corr_id != f {
                continue;
            }
        }
        let verdict = json_get_str(line, "verdict")
            .unwrap_or("UNKNOWN")
            .to_string();
        let ts = json_get_str(line, "ts").unwrap_or("").to_string();
        // vote_counts is a nested object; pull yes/no/abstain/total out of it
        // with the same flat-scan helper (works fine since keys are unique
        // per line regardless of nesting depth).
        let yes = json_get_str(line, "yes").unwrap_or("0").to_string();
        let no = json_get_str(line, "no").unwrap_or("0").to_string();
        let abstain = json_get_str(line, "abstain").unwrap_or("0").to_string();
        let total = json_get_str(line, "total").unwrap_or("0").to_string();

        out.insert(
            corr_id.clone(),
            ConsensusResult {
                corr_id,
                verdict,
                yes,
                no,
                abstain,
                total,
                ts,
            },
        );
    }
    out
}

/// Vote tally counts, bundled so `emit_consensus_result` stays under
/// clippy's too-many-arguments threshold.
struct VoteCounts {
    yes: u32,
    no: u32,
    abstain: u32,
    total: u32,
}

/// Emit a `kind=consensus_result` event matching the schema
/// `scripts/coord/deliberator-loop.sh::_emit_kind` already writes, so
/// both aggregators produce interchangeable, idempotency-compatible
/// records.
fn emit_consensus_result(
    ambient_path: &std::path::Path,
    corr_id: &str,
    verdict: &str,
    counts: &VoteCounts,
    session_id: &str,
) -> anyhow::Result<()> {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let escaped_corr = corr_id.replace('\\', "\\\\").replace('"', "\\\"");
    let escaped_session = session_id.replace('\\', "\\\\").replace('"', "\\\"");
    let VoteCounts {
        yes,
        no,
        abstain,
        total,
    } = *counts;
    let line = format!(
        r#"{{"ts":"{ts}","kind":"consensus_result","session":"{escaped_session}","event":"FEEDBACK","corr_id":"{escaped_corr}","verdict":"{verdict}","vote_counts":{{"yes":{yes},"no":{no},"abstain":{abstain},"total":{total}}},"voters_list":[]}}"#
    );
    // scanner-anchor: "kind":"consensus_result"
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)?;
    writeln!(f, "{line}")?;
    Ok(())
}

/// `chump consensus resolve <corr_id> [--since <dur>]`
fn run_resolve(args: &[String]) -> i32 {
    if args.is_empty() {
        eprintln!("Usage: chump consensus resolve <corr_id> [--since <dur>]");
        return 2;
    }
    let corr_id = &args[0];

    let mut since_str: Option<String> = None;
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--since" {
            i += 1;
            if i < args.len() {
                since_str = Some(args[i].clone());
            }
        }
        i += 1;
    }
    let since_secs = since_str
        .as_deref()
        .and_then(parse_duration_secs)
        .unwrap_or(86400);

    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let path = ambient_path();

    // Idempotency: already-resolved decisions are not re-emitted.
    let existing = load_consensus_results(&path, Some(corr_id));
    if let Some(r) = existing.get(corr_id.as_str()) {
        println!(
            "corr_id={corr_id}  verdict={verdict}  (already resolved at {ts}, not re-emitted)",
            verdict = r.verdict,
            ts = r.ts
        );
        return 0;
    }

    let events = load_vote_events(&path, since_secs, now_secs, Some(corr_id.as_str()));
    if events.is_empty() {
        eprintln!("no vote events found for corr_id={corr_id}");
        return 2;
    }

    let react_weight: f64 = std::env::var("CHUMP_CONSENSUS_REACT_WEIGHT")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.3);

    let tallies = aggregate(&events, react_weight);
    let t = match tallies.get(corr_id.as_str()) {
        Some(t) => t,
        None => {
            eprintln!("no vote events found for corr_id={corr_id}");
            return 2;
        }
    };

    let verdict = t.verdict(now_secs);
    println!(
        "corr_id={corr_id}  yes={yes}  no={no}  abstain={abstain}  total={total}  verdict={verdict}",
        yes = t.yes,
        no = t.no,
        abstain = t.abstain,
        total = t.total(),
    );

    if verdict == "PASSED" || verdict == "FAILED" {
        let session_id =
            std::env::var("CHUMP_SESSION_ID").unwrap_or_else(|_| "unknown".to_string());
        let counts = VoteCounts {
            yes: t.yes,
            no: t.no,
            abstain: t.abstain,
            total: t.total(),
        };
        match emit_consensus_result(&path, corr_id, verdict, &counts, &session_id) {
            Ok(()) => println!("  → emitted kind=consensus_result verdict={verdict}"),
            Err(e) => eprintln!("  warn: failed to emit kind=consensus_result: {e}"),
        }
    } else {
        println!("  → verdict={verdict}: not a reached decision, nothing emitted");
    }

    0
}

/// `chump consensus status [<corr_id> | --all] [--since <dur>]`
fn run_status(args: &[String]) -> i32 {
    let mut corr_id: Option<String> = None;
    let mut show_all = false;
    let mut since_str: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--all" => show_all = true,
            "--since" => {
                i += 1;
                if i < args.len() {
                    since_str = Some(args[i].clone());
                }
            }
            other if !other.starts_with("--") && corr_id.is_none() => {
                corr_id = Some(other.to_string());
            }
            _ => {}
        }
        i += 1;
    }

    if corr_id.is_none() && !show_all {
        eprintln!("Usage: chump consensus status <corr_id> | --all [--since <dur>]");
        return 2;
    }

    let path = ambient_path();
    let results = load_consensus_results(&path, corr_id.as_deref());

    if !results.is_empty() {
        let mut keys: Vec<&String> = results.keys().collect();
        keys.sort();
        for key in keys {
            let r = &results[key];
            println!(
                "corr_id={corr_id}  verdict={verdict}  yes={yes}  no={no}  abstain={abstain}  total={total}  resolved_at={ts}",
                corr_id = r.corr_id,
                verdict = r.verdict,
                yes = r.yes,
                no = r.no,
                abstain = r.abstain,
                total = r.total,
                ts = r.ts,
            );
        }
        if corr_id.is_some() {
            return 0;
        }
    }

    // Fall back to live tally for corr_ids with no durable consensus_result
    // yet (still accumulating votes) — this is what makes status "queryable
    // decision state" rather than a lookup that dead-ends before a decision
    // is reached.
    let since_secs = since_str
        .as_deref()
        .and_then(parse_duration_secs)
        .unwrap_or(86400);
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let react_weight: f64 = std::env::var("CHUMP_CONSENSUS_REACT_WEIGHT")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.3);

    let events = load_vote_events(&path, since_secs, now_secs, corr_id.as_deref());
    if events.is_empty() {
        if results.is_empty() {
            println!("no decision state found");
            return corr_id.map_or(0, |_| 2);
        }
        return 0;
    }

    let tallies = aggregate(&events, react_weight);
    let mut keys: Vec<&String> = tallies.keys().collect();
    keys.sort();
    for key in keys {
        // Don't double-print corr_ids that already had a durable result above.
        if results.contains_key(key) {
            continue;
        }
        let t = &tallies[key];
        println!(
            "corr_id={key}  verdict={verdict}  yes={yes}  no={no}  abstain={abstain}  total={total}  (pending — no durable consensus_result yet)",
            verdict = t.verdict(now_secs),
            yes = t.yes,
            no = t.no,
            abstain = t.abstain,
            total = t.total(),
        );
    }

    0
}

pub fn run(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        Some("resolve") => run_resolve(&args[1..]),
        Some("status") => run_status(&args[1..]),
        _ => {
            eprintln!("Usage: chump consensus <resolve|status> ...");
            2
        }
    }
}
