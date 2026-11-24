//! Roadmap, PR triage/rescue, paramedic, session, dashboard, and cascade CLI subcommands.

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

pub(crate) async fn dispatch_pr_roadmap(args: Vec<String>) -> Result<()> {
    if args.get(1).map(String::as_str) == Some("roadmap-status") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump roadmap-status [--json] [--exit-on-drift] [--top-starved N]");
            println!();
            println!("Reads docs/ROADMAP.md and shows 🟢/🟡/🔴 progress per weekly outcome.");
            println!("Lists implementing gaps with shipped/in-flight/open counts cross-referenced");
            println!("against state.db.");
            println!();
            println!("Options:");
            println!("  --json            output in JSON format");
            println!("  --exit-on-drift   exit 1 if starved outcomes, untraced P0/P1 gaps, or outcome-table");
            println!("                    drift found (META-1045: a live outcome with a definition of done");
            println!(
                "                    but no open gaps, or whose open gaps are all unpickable)"
            );
            println!(
                "  --top-starved N   limit starved_outcomes output to N entries (default: all)"
            );
            println!();
            println!("Exit codes:");
            println!("  0 — no drift detected (or --exit-on-drift not set)");
            println!("  1 — drift detected when --exit-on-drift is set");
            println!();
            println!("Examples:");
            println!("  chump roadmap-status");
            println!("  chump roadmap-status --json | jq .starved_outcomes");
            println!("  chump roadmap-status --exit-on-drift  # CI gate");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let exit_on_drift = args.iter().any(|a| a == "--exit-on-drift");

        // Parse --top-starved N
        let top_starved: usize = args
            .windows(2)
            .find(|w| w[0] == "--top-starved")
            .and_then(|w| w[1].parse::<usize>().ok())
            .unwrap_or(usize::MAX);

        let repo_root = repo_path::repo_root();
        let report = roadmap_status::build_report(&repo_root);

        // INFRA-1145: emit ambient event when drift detected and --exit-on-drift set
        if exit_on_drift && report.has_drift() {
            let lock_dir = repo_root.join(".chump-locks");
            let ambient = lock_dir.join("ambient.jsonl");
            if let Ok(ts_out) = std::process::Command::new("date")
                .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                .output()
            {
                let ts_str = String::from_utf8_lossy(&ts_out.stdout).trim().to_string();
                let starved_json: Vec<String> = report
                    .starved_outcomes
                    .iter()
                    .map(|w| w.to_string())
                    .collect();
                let untraced_json: Vec<String> = report
                    .untraced_p0
                    .iter()
                    .map(|id| format!(r#""{id}""#))
                    .collect();
                let outcome_drift_json: Vec<String> = report
                    .outcome_drift
                    .iter()
                    .map(|d| format!(r#""{}""#, d.outcome_id))
                    .collect();
                let event = format!(
                    r#"{{"ts":"{ts}","kind":"roadmap_drift_detected","starved_outcomes":[{s}],"untraced_p0":[{u}],"outcome_drift":[{o}]}}"#,
                    ts = ts_str,
                    s = starved_json.join(","),
                    u = untraced_json.join(","),
                    o = outcome_drift_json.join(","),
                );
                let _ = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&ambient)
                    .and_then(|mut f| {
                        use std::io::Write;
                        writeln!(f, "{}", event)
                    });
            }
        }

        if want_json {
            println!("{}", report.render_json_with_opts(top_starved));
        } else {
            print!("{}", report.render_text_with_opts(top_starved));
        }

        if exit_on_drift && report.has_drift() {
            eprintln!(
                "[roadmap-status] DRIFT: {} starved outcome(s), {} untraced P0/P1 gap(s), {} outcome-table drift(s)",
                report.starved_outcomes.len(),
                report.untraced_p0.len(),
                report.outcome_drift.len()
            );
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump roadmap-pillar-score [--json]` (META-409, META-152 slice)
    // Parses docs/ROADMAP.md into lanes (## sections), counts pillar
    // mentions per lane, and ranks lanes by alignment with the pillar(s)
    // most starved of open gaps (the "bottleneck" pillars).
    if args.get(1).map(String::as_str) == Some("roadmap-pillar-score") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump roadmap-pillar-score [--json]");
            println!();
            println!("Parses docs/ROADMAP.md into lanes (## sections) and scores each lane");
            println!("by how strongly it aligns with the pillar(s) currently most starved");
            println!("of open gaps (per roadmap-status pillar_coverage).");
            println!();
            println!("Options:");
            println!("  --json   output in JSON format");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let repo_root = repo_path::repo_root();
        let scores = roadmap_pillar_score::build_report(&repo_root);

        if want_json {
            println!("{}", roadmap_pillar_score::render_json(&scores));
        } else {
            print!("{}", roadmap_pillar_score::render_text(&scores));
        }
        return Ok(());
    }

    // `chump fleet-status` (INFRA-494) — single-command operator
    // dashboard combining active leases, last-24h shipped/abandoned,
    // last-24h waste tally summary, and recent fleet wedges.
    // `chump ambient-rotate` (INFRA-941) — rotate ambient.jsonl if over threshold.
    if args.get(1).map(String::as_str) == Some("ambient-rotate") {
        let repo_root = repo_path::repo_root();
        let ambient = repo_root.join(".chump-locks/ambient.jsonl");
        let threshold_mb = std::env::var("CHUMP_AMBIENT_MAX_MB")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(50);
        let size_mb = std::fs::metadata(&ambient)
            .map(|m| m.len() / (1024 * 1024))
            .unwrap_or(0);
        if crate::ambient_rotate::rotate_if_needed(&ambient) {
            println!(
                "rotated: ambient.jsonl ({} MB) → ambient.jsonl.1 (threshold {} MB)",
                size_mb, threshold_mb
            );
        } else {
            println!(
                "no-op: ambient.jsonl is {} MB (threshold {} MB)",
                size_mb, threshold_mb
            );
        }
        return Ok(());
    }

    if args.get(1).map(String::as_str) == Some("fleet-status") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump fleet-status");
            println!();
            println!("Single-command operator dashboard combining active leases, last-24h");
            println!("shipped/abandoned, last-24h waste tally summary, and recent fleet wedges.");
            println!();
            println!("Example:");
            println!("  chump fleet-status");
            return Ok(());
        }
        let repo_root = repo_path::repo_root();
        let status = fleet_status::snapshot(&repo_root);
        print!("{}", status.render_text());
        return Ok(());
    }

    // `chump plan` (INFRA-1021) — rank the open gap backlog and recommend the
    // next N to dispatch. Library implementation lives in crates/chump-planner;
    // v0.1 supports --format table and --reconcile-threshold; --explain,
    // --graph, json and mermaid are v0.2.
    if args.get(1).map(String::as_str) == Some("plan") {
        return run_plan_subcommand(&args);
    }

    // `chump fleet-velocity` (INFRA-566) — ships/hour over 1h/6h/24h
    // windows plus a forecast of hours until the open gap queue empties.
    // Helps the operator decide when to file more gaps vs let fleet idle.
    if args.get(1).map(String::as_str) == Some("fleet-velocity") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump fleet-velocity");
            println!();
            println!("Ships/hour over 1h/6h/24h windows plus a forecast of hours until the open");
            println!("gap queue empties. Helps decide when to file more gaps vs let fleet idle.");
            println!();
            println!("Example:");
            println!("  chump fleet-velocity");
            return Ok(());
        }
        let repo_root = repo_path::repo_root();
        let snap = fleet_velocity::snapshot(&repo_root);
        print!("{}", snap.render_text());
        return Ok(());
    }

    // `chump fanout <plan|apply|status>` (INFRA-1484) — cross-repo fan-out
    // primitive (Marcus M-B continuation). Sibling of `chump fleet plan/apply`
    // from INFRA-1483: where that fans out by parameter inside one repo, this
    // fans out across N repos. One repo = one reserved gap. AC#4 sandboxing
    // graceful-degrades in v1 (env hints surfaced, not enforced) — lands as
    // real container isolation under INFRA-1454.
    // `chump rollup <fanout-group> [--semantic] [--json]` (INFRA-1455) —
    // Marcus M-B converge step. Takes the fanout_group name set by
    // `chump fanout apply` (INFRA-1484), pulls the closed PR per gap, and
    // clusters by file-list Jaccard into named "Strategy A/B/..." classes
    // so the operator sees "12 PRs converged on Strategy A" instead of a
    // 40-PR firehose.
    if args.get(1).map(String::as_str) == Some("rollup") {
        let name = match args.get(2) {
            Some(n) => n.clone(),
            None => {
                eprintln!("Usage: chump rollup <fanout-group> [--semantic] [--json]");
                eprintln!();
                eprintln!("  Converges PRs from a chump fanout group into named strategy classes.");
                eprintln!(
                    "  --semantic enables Jaccard-similarity clustering across touched files."
                );
                eprintln!("  --json emits structured output.");
                std::process::exit(2);
            }
        };
        let semantic = args.iter().any(|a| a == "--semantic");
        let json_out = args.iter().any(|a| a == "--json");
        match rollup_cmd::run(&name, semantic, json_out) {
            Ok(()) => std::process::exit(0),
            Err(e) => {
                eprintln!("chump rollup: {e}");
                std::process::exit(1);
            }
        }
    }

    if args.get(1).map(String::as_str) == Some("fanout") {
        let sub = args.get(2).map(String::as_str).unwrap_or("");
        if sub.is_empty() || sub == "help" || sub == "--help" {
            println!(
                "Usage: chump fanout <plan|apply|status> <spec.yaml | name> [--dry-run] [--json] [--reference <commit-sha-or-PR-N>]"
            );
            println!();
            println!("Cross-repo fan-out (INFRA-1484, Marcus M-B). One operator command,");
            println!("N repos, N isolated gaps. Spec format:");
            println!();
            println!("  name: shared-lib-bump");
            println!("  intent: |");
            println!("    Bump shared-lib to v2.0 in this service.");
            println!("  repos:");
            println!("    - path: ../service-a");
            println!("    - path: ../service-b");
            println!("  validation: ./scripts/test-integration.sh");
            println!("  success: integration suite passes");
            println!();
            println!("Subcommands:");
            println!("  plan   <spec.yaml>             dry-run; render the per-repo gap set");
            println!(
                "  apply  <spec.yaml> [--dry-run] reserve one gap per repo (fanout_group=<name>)"
            );
            println!("  status <name>                  aggregate reserved gaps by fanout_group");
            println!();
            println!("Flags:");
            println!("  --reference <commit-sha-or-PR-N>  INFRA-1935 (Marcus M-B): commit SHA or PR number");
            println!(
                "                                    to use as reference implementation. PR-N is"
            );
            println!("                                    resolved to merge commit SHA via REST (not GraphQL).");
            println!("                                    Injected into per-worktree agent dispatch payload.");
            return Ok(());
        }

        // INFRA-1935: parse --reference <value> from any position in args.
        // Consume the flag + its value so subcommand parsers see a clean arg list.
        let reference_raw: Option<String> = {
            let pos = args.iter().position(|a| a == "--reference");
            pos.and_then(|i| args.get(i + 1).cloned())
        };

        // Resolve PR-N → merge commit SHA via REST (not GraphQL — fleet exhausted).
        // Any value that is all digits is treated as a PR number.
        // Commit SHAs and git refs (HEAD~1, main, etc.) are passed through verbatim.
        let reference_sha: Option<String> = match &reference_raw {
            None => None,
            Some(v) if v.chars().all(|c| c.is_ascii_digit()) => {
                // PR number — resolve to merge commit SHA via REST.
                let repo_slug = std::env::var("CHUMP_GITHUB_REPO")
                    .unwrap_or_else(|_| "repairman29/chump".to_string());
                let api_url = format!("repos/{repo_slug}/pulls/{v}");
                let out = std::process::Command::new("gh")
                    .args(["api", &api_url, "--jq", ".merge_commit_sha"])
                    .output();
                match out {
                    Ok(o) if o.status.success() => {
                        let sha = String::from_utf8_lossy(&o.stdout).trim().to_string();
                        if sha.is_empty() || sha == "null" {
                            eprintln!("warning: PR #{v} has no merge commit SHA (not merged yet?); using PR number as-is");
                            Some(v.clone())
                        } else {
                            eprintln!("--reference PR #{v} resolved to {sha}");
                            Some(sha)
                        }
                    }
                    Ok(o) => {
                        eprintln!(
                            "warning: could not resolve PR #{v} via gh api: {}; using PR number as-is",
                            String::from_utf8_lossy(&o.stderr).trim()
                        );
                        Some(v.clone())
                    }
                    Err(e) => {
                        eprintln!(
                            "warning: could not exec gh to resolve PR #{v}: {e}; using as-is"
                        );
                        Some(v.clone())
                    }
                }
            }
            Some(v) => Some(v.clone()), // commit SHA or git ref — pass through
        };

        match sub {
            "plan" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!(
                            "Usage: chump fanout plan <spec.yaml> [--reference <sha-or-PR-N>]"
                        );
                        std::process::exit(2);
                    }
                };
                let spec_dir = path
                    .parent()
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| std::path::PathBuf::from("."));
                match fleet_fanout::FanoutSpec::from_path(&path) {
                    Ok(mut spec) => {
                        spec.reference = reference_sha;
                        let plan = spec.plan(&spec_dir);
                        if args.iter().any(|a| a == "--json") {
                            println!("{}", serde_json::to_string_pretty(&plan).unwrap());
                        } else {
                            print!("{}", fleet_fanout::render_plan(&plan));
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
                        eprintln!("Usage: chump fanout apply <spec.yaml> [--dry-run]");
                        std::process::exit(2);
                    }
                };
                let spec_dir = path
                    .parent()
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| std::path::PathBuf::from("."));
                let dry_run = args.iter().any(|a| a == "--dry-run");
                match fleet_fanout::FanoutSpec::from_path(&path) {
                    Ok(mut spec) => {
                        spec.reference = reference_sha;
                        let plan = spec.plan(&spec_dir);
                        println!(
                            "fanout apply: {} repo(s) (group={}, dry_run={dry_run})",
                            plan.len(),
                            spec.name
                        );
                        for (i, g) in plan.iter().enumerate() {
                            if dry_run {
                                println!(
                                    "  [dry-run] {} | {} → {}",
                                    i + 1,
                                    g.repo_label,
                                    g.target_repo
                                );
                                for w in &g.env_isolation_warnings {
                                    println!("            ⚠ {w}");
                                }
                                continue;
                            }
                            if !std::path::Path::new(&g.target_repo).exists() {
                                eprintln!(
                                    "  [failed] {}: target_repo not found: {} (v1: clone the repo first; auto-clone lands with a follow-up)",
                                    g.repo_label, g.target_repo
                                );
                                std::process::exit(1);
                            }
                            let notes = fleet_fanout::build_gap_notes(g);
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
                                    let body = String::from_utf8_lossy(&o.stdout);
                                    let id = body
                                        .lines()
                                        .find_map(|l| {
                                            let t = l.trim();
                                            // gap reserve prints lines like:
                                            //   "Reserved INFRA-NNN" or "INFRA-NNN"
                                            t.split_whitespace()
                                                .find(|w| {
                                                    w.contains('-')
                                                        && w.split('-').nth(1).is_some_and(|n| {
                                                            n.chars().all(|c| c.is_ascii_digit())
                                                        })
                                                })
                                                .map(String::from)
                                        })
                                        .unwrap_or_else(|| "?".to_string());
                                    println!(
                                        "  [reserved] {} ({}) → {}",
                                        g.repo_label, g.target_repo, id
                                    );
                                    for w in &g.env_isolation_warnings {
                                        println!("             ⚠ {w}");
                                    }
                                }
                                Ok(o) => {
                                    eprintln!(
                                        "  [failed] {}: {}",
                                        g.repo_label,
                                        String::from_utf8_lossy(&o.stderr).trim()
                                    );
                                    std::process::exit(1);
                                }
                                Err(e) => {
                                    eprintln!("  [failed] {}: spawn error: {e}", g.repo_label);
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
            "status" => {
                let name = match args.get(3) {
                    Some(n) => n.clone(),
                    None => {
                        eprintln!("Usage: chump fanout status <name>");
                        std::process::exit(2);
                    }
                };
                let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                let out = std::process::Command::new(&chump_bin)
                    .args(["gap", "list", "--json"])
                    .output();
                let Ok(o) = out else {
                    eprintln!("error: could not exec chump gap list");
                    std::process::exit(1);
                };
                let body = String::from_utf8_lossy(&o.stdout);
                let report = fleet_fanout::aggregate_status(&body, &name);
                if args.iter().any(|a| a == "--json") {
                    println!("{}", serde_json::to_string_pretty(&report).unwrap());
                } else {
                    print!("{}", report.render_text());
                }
                std::process::exit(0);
            }
            other => {
                eprintln!("chump fanout: unknown subcommand '{other}'");
                eprintln!("Try: chump fanout <plan|apply|status> [args…]");
                std::process::exit(2);
            }
        }
    }

    // `chump waste-tally [--since 24h|7d|...] [--json]`
    // (INFRA-488) — Zero Waste mission pillar measurement primitive.
    // Aggregates ALERT events from .chump-locks/ambient.jsonl that match
    // the waste taxonomy (fleet_wedge, fleet_starved, lease_expired_server,
    // reaper_silent, queue_stuck, ambient_oversize, pr_stuck, silent_agent,
    // lease_overlap, edit_burst) and prints a per-kind tally with rough
    // cost estimates where measurable. No new event emissions in MVP.
    if args.get(1).map(String::as_str) == Some("waste-tally") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!(
                "Usage: chump waste-tally [--since WINDOW] [--json] [--domain|--by-domain] [--tokens] [--by-close-reason] [--emit-ambient]"
            );
            println!();
            println!("Zero-Waste pillar measurement. Tallies waste events from ambient.jsonl");
            println!("(fleet_wedge, fleet_starved, pr_stuck, silent_agent, lease_overlap, …)");
            println!("with per-kind counts and rough cost estimates.");
            println!();
            println!("Options:");
            println!(
                "  --since T          time window: 24h, 7d, 60m, or raw seconds  [default: 24h]"
            );
            println!("  --json             output in JSON format");
            println!(
                "  --domain           break down waste by gap domain (exits 1 if any domain >40%)"
            );
            println!("  --by-domain        alias for --domain (back-compat)");
            println!("  --tokens           include token-cost estimates");
            println!("  --by-close-reason  classify closed-not-merged PRs by close-comment pattern (INFRA-998)");
            println!("                     Categories: superseded, duplicate_claim, stale_branch,");
            println!("                     scratch_commit, ci_fail_orphan, staging_branch, other");
            println!(
                "  --emit-ambient     with --by-close-reason: write kind=waste_category_report"
            );
            println!("                     to ambient.jsonl (for weekly cron)");
            println!();
            println!("Example:");
            println!("  chump waste-tally --since 7d");
            println!("  chump waste-tally --window 2h   # alias accepted by fleet scaling gate");
            println!("  chump waste-tally --by-close-reason --since 7d --json");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        // INFRA-934: --domain is the canonical flag; --by-domain remains for back-compat.
        let by_domain = args.iter().any(|a| a == "--by-domain" || a == "--domain");
        let want_tokens = args.iter().any(|a| a == "--tokens");
        // INFRA-998: PR-closure-reason categorization.
        let by_close_reason = args.iter().any(|a| a == "--by-close-reason");
        let emit_ambient = args.iter().any(|a| a == "--emit-ambient");

        // Parse "24h" / "7d" / "60m" / raw seconds.
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump waste-tally: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });

        let repo_root = repo_path::repo_root();
        // INFRA-998: close-reason mode. Mutually exclusive with --domain.
        if by_close_reason {
            let report = waste_tally::build_close_reason_report(since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            if emit_ambient {
                report.emit_ambient(&repo_root);
            }
            return Ok(());
        }
        if by_domain {
            let report = waste_tally::build_domain_report(&repo_root, since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            // INFRA-934: exit non-zero if any single domain exceeds 40% of total token spend.
            if let Some(breach) = report.any_domain_exceeds(40.0) {
                eprintln!(
                    "chump waste-tally: domain '{}' is {:.1}% of total token spend (threshold 40%)",
                    breach.domain, breach.pct_of_total
                );
                std::process::exit(1);
            }
        } else {
            let report = waste_tally::build_report(&repo_root, since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else if want_tokens {
                print!("{}", report.render_text_tokens());
            } else {
                print!("{}", report.render_text());
            }
        }
        return Ok(());
    }

    // `chump pr-coupling-cost <PR#> [--diff-files f1,f2,...] [--json]`
    // (INFRA-595) — CREDIBLE: per-PR coupling-tax measurement.
    // Reads .github/workflows/ci.yml dorny/paths-filter rules; for each file
    // in the PR diff prints a table of {file, jobs_triggered}.
    // --diff-files accepts a comma-separated override (for tests/offline use).
    if args.get(1).map(String::as_str) == Some("pr-coupling-cost") {
        let pr_number: Option<u64> = args.get(2).and_then(|s| s.parse().ok());
        let want_json = args.iter().any(|a| a == "--json");

        let diff_files_override: Option<Vec<String>> = args
            .iter()
            .position(|a| a == "--diff-files")
            .and_then(|i| args.get(i + 1))
            .map(|s| s.split(',').map(|f| f.trim().to_string()).collect());

        let diff_files: Vec<String> = if let Some(files) = diff_files_override {
            files
        } else if let Some(pr) = pr_number {
            pr_coupling_cost::fetch_pr_files(pr)
        } else {
            eprintln!("Usage: chump pr-coupling-cost <PR#> [--diff-files f1,f2,...] [--json]");
            std::process::exit(2);
        };

        let repo_root = repo_path::repo_root();
        let ci_yml_path = repo_root.join(".github/workflows/ci.yml");
        let ci_yml = std::fs::read_to_string(&ci_yml_path).unwrap_or_else(|e| {
            eprintln!(
                "chump pr-coupling-cost: cannot read {}: {e}",
                ci_yml_path.display()
            );
            std::process::exit(1);
        });

        let report = pr_coupling_cost::build_report(pr_number, &diff_files, &ci_yml);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        return Ok(());
    }

    // `chump pr cut <N> --reason "<text>"` (INFRA-8221 / RESILIENT-1607): the one
    // deliberate-close verb. Thin arm; logic in commands::pr_cut.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("cut")
    {
        std::process::exit(commands::pr_cut::run_cli(
            &args[3..],
            &repo_path::repo_root(),
        ));
    }

    // `chump pr explain-block <PR#> [--json]` (INFRA-1416) — reads the
    // status-check rollup + cross-refs other open PRs failing the same
    // checks, then names the next mechanical action per row. Replaces
    // the ~6× manual `gh pr view ... statusCheckRollup` digging the
    // operator was doing per stuck PR.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("explain-block")
    {
        let pr_number: Option<u64> = args.get(3).and_then(|s| s.parse().ok());
        let pr_number = match pr_number {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump pr explain-block <PR#> [--json]");
                std::process::exit(2);
            }
        };
        let json_out = args.iter().any(|a| a == "--json");
        match pr_explain::run(pr_number, json_out) {
            Ok(()) => std::process::exit(0),
            Err(e) => {
                eprintln!("chump pr explain-block: {e}");
                std::process::exit(1);
            }
        }
    }

    // `chump pr blame-file <path> [--json] [--db <path>]` (INFRA-1445) —
    // CREDIBLE: combines git log on the path with GitHub squash-merge
    // history (via .chump/github_cache.db) so the operator sees fixes
    // that landed via a squash-merged/cherry-picked PR that plain
    // `git log -- <path>` alone missed.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("blame-file")
    {
        let path = match args.get(3) {
            Some(p) if !p.starts_with("--") => p.clone(),
            _ => {
                eprintln!("Usage: chump pr blame-file <path> [--json] [--db <path>]");
                std::process::exit(2);
            }
        };
        let json_out = args.iter().any(|a| a == "--json");
        let repo_root = repo_path::repo_root();
        let db_path = args
            .iter()
            .position(|a| a == "--db")
            .and_then(|i| args.get(i + 1))
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| repo_root.join(".chump").join("github_cache.db"));
        match pr_blame_file::run(&repo_root, &db_path, &path) {
            Ok(rows) => {
                if json_out {
                    println!("{}", pr_blame_file::render_json(&path, &rows)?);
                } else {
                    print!("{}", pr_blame_file::render_text(&path, &rows));
                }
            }
            Err(e) => {
                eprintln!("chump pr blame-file: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump pr fix-clippy <PR#> [--dry-run]`
    // (INFRA-618) — ZERO-WASTE: auto-fix obvious clippy lints on a PR branch.
    // Targets: manual_split_once, unused_variables, redundant_clone, single_match.
    // Safety: refuses if --fix touches >3 files or diff looks non-trivial.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("fix-clippy")
    {
        let pr_number: Option<u64> = args.get(3).and_then(|s| s.parse().ok());
        let pr_number = match pr_number {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump pr fix-clippy <PR#> [--dry-run]");
                std::process::exit(2);
            }
        };
        let dry_run = args.iter().any(|a| a == "--dry-run");
        let repo_root = repo_path::repo_root();
        match pr_fix_clippy::fix_clippy(pr_number, &repo_root, dry_run) {
            Ok(r) => {
                if !r.dry_run {
                    println!(
                        "chump pr fix-clippy: PR #{} fixed — {} files, {} lines.",
                        r.pr_number, r.files_changed, r.lines_changed
                    );
                }
            }
            Err(e) => {
                eprintln!("chump pr fix-clippy: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump pr triage [--rerun-flakes] [--rebase-dirty] [--json]`
    // (INFRA-605) — EFFECTIVE: scan all open PRs, classify, report CI health.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("triage")
    {
        let opts = pr_triage::TriageOptions {
            rerun_flakes: args.iter().any(|a| a == "--rerun-flakes"),
            rebase_dirty: args.iter().any(|a| a == "--rebase-dirty"),
            json: args.iter().any(|a| a == "--json"),
        };
        match pr_triage::run_triage(&opts) {
            Ok(report) => {
                if opts.json {
                    print!("{}", pr_triage::render_json(&report));
                } else {
                    print!("{}", pr_triage::render_text(&report));
                }
            }
            Err(e) => {
                eprintln!("chump pr triage: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump pr ac-coverage <PR#> [--advisory]`
    // (INFRA-1541) — CREDIBLE: pre-merge AC coverage gate
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("ac-coverage")
    {
        let pr_number: Option<u64> = args.get(3).and_then(|s| s.parse().ok());
        let pr_number = match pr_number {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump pr ac-coverage <PR#>");
                std::process::exit(2);
            }
        };
        // EFFECTIVE-373 (COTG): `--gap <ID>` scores the PR against that gap's REAL
        // acceptance criteria via run_with_ac — external-PR safe (no title-parse
        // NoGapRef). `--repo <owner/name>` for a PR in another repo. CHUMP_AC_JUDGE_LLM=1
        // turns on the LLM judge. Without --gap it falls back to the title-parse run().
        let gap_flag = args
            .iter()
            .position(|a| a == "--gap")
            .and_then(|i| args.get(i + 1))
            .cloned();
        let repo_flag = args
            .iter()
            .position(|a| a == "--repo")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_default();
        let coverage = match &gap_flag {
            Some(gid) => {
                let bullets = pr_ac_coverage::load_ac_bullets(gid).unwrap_or_default();
                pr_ac_coverage::run_with_ac(&repo_flag, pr_number, gid, &bullets)
            }
            None => pr_ac_coverage::run(pr_number),
        };
        match coverage {
            Ok(result) => {
                // print JSON summary
                println!("{}", pr_ac_coverage::render_json(&result));
                if result.status == pr_ac_coverage::CoverageStatus::Miss
                    && std::env::var("CHUMP_AC_GATE_ADVISORY").as_deref() != Ok("true")
                {
                    std::process::exit(1);
                }
            }
            Err(e) => {
                eprintln!("chump pr ac-coverage: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump paramedic triage|execute|daemon [--dry-run] [--interval-secs N] [--budget-secs N] [--plan F]`
    // (INFRA-1375) — RESILIENT: rule-engine PR rescue daemon.
    // triage  — read PR state, emit JSON action plan (read-only)
    // execute — run one triage→execute cycle with optional --plan <file>
    // daemon  — loop triage→execute every --interval-secs (default 600)
    if args.get(1).map(String::as_str) == Some("paramedic") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let dry_run = args.iter().any(|a| a == "--dry-run");

        if subcmd == "help" || args.iter().any(|a| a == "--help") {
            println!("Usage: chump paramedic <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!("  triage               Read PR state and emit JSON action plan (read-only).");
            println!("  execute [--plan F]   Run one triage→execute cycle. --plan reads from file");
            println!("                       instead of re-triaging.");
            println!("  daemon               Loop triage→execute forever. Single-instance via PID");
            println!("                       file at .chump-locks/paramedic.lock.");
            println!(
                "  smoke-test           INFRA-1645: quick observability check — dummy LLM call,"
            );
            println!("                       prints a cost_report JSON line, exits 0.");
            println!();
            println!("Options:");
            println!("  --dry-run            Print actions; do not actually run gh commands.");
            println!("  --interval-secs N    Daemon loop interval in seconds (default: 600).");
            println!("  --budget-secs N      Per-PR action budget in seconds (default: 90).");
            println!("  --plan F             Path to JSON plan file (execute only).");
            println!();
            println!("Examples:");
            println!("  chump paramedic triage");
            println!("  chump paramedic triage | chump paramedic execute --plan /dev/stdin");
            println!("  chump paramedic daemon --interval-secs 300 --dry-run");
            println!("  chump paramedic smoke-test");
            return Ok(());
        }

        // `chump paramedic --smoke-test` (AC §3 flag form, in addition to
        // the `smoke-test` subcommand above).
        if args.iter().any(|a| a == "--smoke-test") {
            if let Err(e) = paramedic::smoke_test(&repo_root) {
                eprintln!("chump paramedic smoke-test: {e}");
                std::process::exit(1);
            }
            return Ok(());
        }

        match subcmd {
            "triage" => match paramedic::triage(&repo_root, dry_run) {
                Ok(plan) => {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&plan).unwrap_or_default()
                    );
                }
                Err(e) => {
                    eprintln!("chump paramedic triage: {e}");
                    std::process::exit(1);
                }
            },
            "execute" => {
                let budget_secs = args
                    .iter()
                    .position(|a| a == "--budget-secs")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(90);

                // Optionally read plan from --plan <file>; otherwise triage first.
                let plan_path = args
                    .iter()
                    .position(|a| a == "--plan")
                    .and_then(|i| args.get(i + 1));

                let plan = if let Some(path) = plan_path {
                    let raw = std::fs::read_to_string(path)
                        .with_context(|| format!("reading plan from {path}"))?;
                    serde_json::from_str::<paramedic::ActionPlan>(&raw)
                        .context("parsing plan JSON")?
                } else {
                    paramedic::triage(&repo_root, dry_run)?
                };

                if let Err(e) = paramedic::execute(&plan, &repo_root, dry_run, budget_secs) {
                    eprintln!("chump paramedic execute: {e}");
                    std::process::exit(1);
                }
            }
            "daemon" => {
                let interval_secs = args
                    .iter()
                    .position(|a| a == "--interval-secs")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(600);

                if let Err(e) = paramedic::daemon(interval_secs, &repo_root, dry_run) {
                    eprintln!("chump paramedic daemon: {e}");
                    std::process::exit(1);
                }
            }
            "smoke-test" => {
                if let Err(e) = paramedic::smoke_test(&repo_root) {
                    eprintln!("chump paramedic smoke-test: {e}");
                    std::process::exit(1);
                }
            }
            other => {
                eprintln!("chump paramedic: unknown subcommand '{other}'");
                eprintln!("Run 'chump paramedic help' for usage.");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump health-digest [--since 7d] [--json] [--emit] [--webhook]`
    // (INFRA-646) — RESILIENT: weekly health digest. Summarises ships count,
    // ship rate, waste $ by class, top-3 burning gaps, P0 compliance, pillar
    // balance, SLO breaches, and EFFECTIVE productizations for the past 7 days.
    // --emit appends a weekly_health_digest event to ambient.jsonl.
    // --webhook POSTs to CHUMP_WEBHOOK_URL (if set).
    if args.get(1).map(String::as_str) == Some("health-digest") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump health-digest [--since WINDOW] [--json] [--emit] [--webhook]");
            println!();
            println!("Weekly markdown digest with P0/P1 gap counts, waste rate, ship rate,");
            println!("and fleet wedge warnings. Suitable for team standup or operator review.");
            println!();
            println!("Options:");
            println!("  --since T   time window: 7d, 14d, 24h  [default: 7d]");
            println!("  --json      output in JSON format");
            println!("  --emit      write event to ambient.jsonl");
            println!("  --webhook   POST to CHUMP_WEBHOOK_URL");
            println!();
            println!("Example:");
            println!("  chump health-digest --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "7d".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let do_emit = args.iter().any(|a| a == "--emit");
        let do_webhook = args.iter().any(|a| a == "--webhook");
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump health-digest: invalid --since '{}' (expected like 7d, 14d, 24h)",
                since_arg
            );
            std::process::exit(2);
        });
        let repo_root = repo_path::repo_root();
        let summary = health::build_week_summary(&repo_root, since_secs);
        if want_json {
            println!("{}", summary.render_json());
        } else {
            print!("{}", summary.render_text());
        }
        if do_emit {
            health::emit_to_ambient(&repo_root, &summary);
        }
        if do_webhook {
            let delivered = health::deliver_webhook(&summary);
            if !delivered {
                eprintln!("chump health-digest: webhook delivery skipped or failed (check CHUMP_WEBHOOK_URL)");
            }
        }
        return Ok(());
    }

    // `chump ship-quality [--since 24h|7d|...] [--json]`
    // (INFRA-537) — per-agent ship-quality grade. Aggregates ship_grade
    // events emitted by bot-merge.sh into per-model and per-agent tables
    // showing clippy_ok%, test_added%, and rebase_clean% pass rates.
    // Empirical basis for FLEET_MODEL routing decisions (sonnet vs haiku).
    if args.get(1).map(String::as_str) == Some("ship-quality") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump ship-quality [--since WINDOW] [--json]");
            println!();
            println!("Per-agent ship-quality grade: clippy_ok%, test_added%, rebase_clean%.");
            println!("Aggregates ship_grade events from ambient.jsonl by model and agent.");
            println!("Use for FLEET_MODEL routing decisions (sonnet vs haiku).");
            println!();
            println!("Options:");
            println!("  --since T   time window: 24h, 7d, 60m  [default: 24h]");
            println!("  --json      output in JSON format");
            println!();
            println!("Example:");
            println!("  chump ship-quality --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump ship-quality: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });
        let repo_root = repo_path::repo_root();
        let report = ship_quality::build_report(&repo_root, since_secs);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        return Ok(());
    }

    // `chump rebase-stuck [--pr <N>] [--apply] [--json]`
    // (INFRA-607) — RESILIENT: detect DIRTY PRs and attempt auto-rebase.
    // Safety gate: only auto-resolves conflicts in <3 files AND <20 lines
    // AND no test-touching files. --apply force-pushes with-lease.
    if args.get(1).map(String::as_str) == Some("rebase-stuck") {
        let sub_args: Vec<String> = args[2..].to_vec();
        let exit_code = rebase_stuck::run(&sub_args);
        std::process::exit(exit_code);
    }

    // `chump ci-summary [--since 24h|7d|...] [--json]`
    // (INFRA-506) — CI observability primitive. Reads gh run list + failed
    // job logs for the window and classifies failures as flake /
    // test-coupling / real-bug / infra-broken. Output mirrors waste-tally:
    // per-class count + sample diagnostic lines.
    if args.get(1).map(String::as_str) == Some("ci-summary") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!(
                "Usage: chump ci-summary [--since WINDOW] [--json] [--emit-alert] [--threshold N]"
            );
            println!();
            println!("CI observability: reads gh run list and classifies failures as flake /");
            println!("test-coupling / real-bug / infra-broken. Output mirrors waste-tally.");
            println!();
            println!("Options:");
            println!("  --since T       time window: 24h, 7d, 60m  [default: 24h]");
            println!("  --json          output in JSON format");
            println!("  --emit-alert    write ambient alert if failure rate > threshold");
            println!("  --threshold N   failure-rate % for alert trigger  [default: 10]");
            println!();
            println!("Example:");
            println!("  chump ci-summary --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let emit_alert = args.iter().any(|a| a == "--emit-alert");
        let threshold_pct: u64 = args
            .iter()
            .position(|a| a == "--threshold")
            .and_then(|i| args.get(i + 1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(10);

        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump ci-summary: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });

        let report = ci_summary::build_report(since_secs);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        if emit_alert {
            let ambient_path = repo_path::repo_root().join(".chump-locks/ambient.jsonl");
            if report.emit_ambient_alert(threshold_pct, &ambient_path) {
                eprintln!(
                    "ci-summary: ALERT emitted — failure rate {}% exceeds {}% threshold",
                    report.failure_rate_pct(),
                    threshold_pct
                );
            }
        }
        return Ok(());
    }

    // `chump classify-failure [--job NAME] [--log FILE|-] [--json]`  (INFRA-647)
    // Reads docs/process/FAILURE_MODES.yaml and classifies a CI failure.
    // pr-triage-bot.yml calls this to decide: fix | rerun | file_gap | escalate.
    if args.get(1).map(String::as_str) == Some("classify-failure") {
        failure_catalog::run_classify(&args[2..]);
        return Ok(());
    }

    // `chump session-track --start <GAP-ID>` / `--end <GAP-ID> --outcome <s|a|t>`
    // (INFRA-477) — per-session cost ledger MVP. Writes session_start +
    // session_end events to ambient.jsonl. Briefing surfaces aggregate
    // stats for past sessions in the same domain so the next session
    // sees how long similar work has historically taken.
    if args.get(1).map(String::as_str) == Some("session-track") {
        let st_flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let session_id =
            crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
        let repo_root = repo_path::repo_root();
        if let Some(gap_id) = st_flag("--start") {
            session_ledger::emit_session_start(&repo_root, &session_id, &gap_id);
            let dashboard_url = std::env::var("CHUMP_WEB_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:3000".to_string());
            println!(
                "session_start logged: gap={} session={}\ndashboard: {}",
                gap_id, session_id, dashboard_url
            );
            return Ok(());
        }
        if let Some(gap_id) = st_flag("--end") {
            let outcome_str = st_flag("--outcome").unwrap_or_else(|| {
                eprintln!(
                    "chump session-track --end: missing --outcome <shipped|abandoned|starved>"
                );
                std::process::exit(2);
            });
            let outcome = session_ledger::Outcome::from_str(&outcome_str)
                .unwrap_or_else(|| {
                    eprintln!("chump session-track --end: unknown outcome '{}' (expected shipped|abandoned|starved)", outcome_str);
                    std::process::exit(2);
                });
            // INFRA-534: optional token counts for cost telemetry.
            let tokens = match (
                st_flag("--input-tokens").and_then(|s| s.parse::<u64>().ok()),
                st_flag("--output-tokens").and_then(|s| s.parse::<u64>().ok()),
                st_flag("--cache-read-tokens").and_then(|s| s.parse::<u64>().ok()),
            ) {
                (Some(i), Some(o), cache) => Some(session_ledger::TokenCounts {
                    input_tokens: i,
                    output_tokens: o,
                    cache_read_tokens: cache.unwrap_or(0),
                }),
                _ => None,
            };
            session_ledger::emit_session_end(&repo_root, &session_id, &gap_id, outcome, tokens);
            println!(
                "session_end logged: gap={} outcome={}",
                gap_id,
                outcome.as_str()
            );
            return Ok(());
        }
        eprintln!("Usage: chump session-track --start <GAP-ID>");
        eprintln!(
            "       chump session-track --end <GAP-ID> --outcome <shipped|abandoned|starved>"
        );
        std::process::exit(2);
    }

    // `chump session-export [--session-id <ID>]` (INFRA-616) — emit a handoff
    // snapshot to ~/.chump/sessions/<session-id>.md so the next Opus
    // orchestrator session can resume with full context via session-resume.
    if args.get(1).map(String::as_str) == Some("session-export") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump session-export [--session-id ID]");
            println!();
            println!("Export the current session transcript to ~/.chump/sessions/<ID>.md");
            println!("for handoff to the next orchestrator session via 'chump session-resume'.");
            println!();
            println!("Options:");
            println!("  --session-id ID   session ID to export  [default: $CHUMP_SESSION_ID]");
            println!();
            println!("Example:");
            println!("  chump session-export");
            println!("  chump session-export --session-id abc123");
            return Ok(());
        }
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let session_id = flag("--session-id")
            .or_else(|| crate::ambient_stream::env_session_id())
            .unwrap_or_else(|| {
                // Fall back to a timestamp-based ID so exports are never lost.
                format!("session-{}", unix_ts())
            });
        let repo_root = repo_path::repo_root();
        let export = session_export::build_export(&session_id, &repo_root);
        let md = export.render_md();

        let out_path = session_export::export_path(&session_id);
        if let Some(parent) = out_path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                eprintln!(
                    "chump session-export: cannot create {}: {e:#}",
                    parent.display()
                );
                std::process::exit(1);
            }
        }
        if let Err(e) = std::fs::write(&out_path, &md) {
            eprintln!(
                "chump session-export: cannot write {}: {e:#}",
                out_path.display()
            );
            std::process::exit(1);
        }
        println!("session-export written: {}", out_path.display());
        print!("{}", md);
        return Ok(());
    }

    // `chump session-resume <session-id>` (INFRA-616) — read a prior export
    // and print it to stdout for injection into the new session's context.
    if args.get(1).map(String::as_str) == Some("session-resume") {
        let session_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump session-resume <session-id>");
            std::process::exit(2);
        });
        let path = session_export::export_path(&session_id);
        let content = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            eprintln!(
                "chump session-resume: cannot read {}: {e:#}",
                path.display()
            );
            std::process::exit(1);
        });
        print!("{}", content);
        return Ok(());
    }

    // `chump dashboard` (INFRA-063 / M5) — print the cycle-time dashboard:
    // `chump reflect-delta <GAP-ID> "<text>"` (COG-042) — record what
    // this session did *differently* than past attempts on the gap's
    // class. Pure additive: writes a `delta_recorded` event to
    // ambient.jsonl. Briefing surfaces these for similar gaps so the
    // next session sees how the previous attempt's approach differed.
    if args.get(1).map(String::as_str) == Some("reflect-delta") {
        let gap_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        });
        if gap_id.starts_with("--") {
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        }
        let text = args.get(3).cloned().unwrap_or_else(|| {
            eprintln!("chump reflect-delta: missing the delta text");
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        });
        let session_id =
            crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
        let repo_root = repo_path::repo_root();
        reflect_delta::emit_delta_recorded(&repo_root, &session_id, &gap_id, &text);
        println!("recorded delta for {} (session={})", gap_id, session_id);
        return Ok(());
    }

    // PRs landed today/week, median PR-open time, dispatcher backend split,
    // top 5 stale linked worktrees. Pure read aggregator over `gh` + `git`.
    if args.get(1).map(String::as_str) == Some("dashboard") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump dashboard");
            println!();
            println!("Print the cycle-time dashboard: active leases, gap queue depth,");
            println!("recent ship/abandon events, and provider health.");
            println!();
            println!("Example:");
            println!("  chump dashboard");
            return Ok(());
        }
        if let Err(e) = dashboard::print_dashboard() {
            eprintln!("chump dashboard: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump cascade stats [--json]` (INFRA-269) — per-slot cascade traffic
    // table from chump_provider_quality. Companion to the
    // 40-cascade-consumption-report.sh overnight script: this is the
    // on-demand human-facing equivalent. Pure read; safe to run anytime.
    if args.get(1).map(String::as_str) == Some("cascade")
        && args.get(2).map(String::as_str) == Some("stats")
    {
        let json_out = args.iter().any(|a| a == "--json");
        if let Err(e) = cascade_stats::print_stats(json_out) {
            eprintln!("chump cascade stats: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // PRODUCT-015: every non-init session start is a candidate d2-return. The
    // emitter no-ops unless install happened > 24h ago and d2 hasn't fired yet.
    activation::emit_return_d2_if_due();

    // `chump --recipe <path> [--<param> <value> ...]` (COMP-008) — run a packaged
    // workflow from a YAML recipe file.
    //
    // A recipe declares its required env vars, required tools, named parameters
    // with defaults, and an ordered list of steps. Each step is a command with
    // {{param}} substitutions in its args. See docs/process/CHUMP_RECIPES.md for schema
    // and recipes/ for bundled examples.
    //
    // Parameter overrides are collected from the remaining args as flag-value
    // pairs: `--model claude-haiku-4-5 --n 20`. Underscore ↔ hyphen are both
    // accepted as parameter name separators.
    //
    // Exit codes: 0 on success, 1 on recipe error, 2 on usage error.
    if let Some(pos) = args.iter().position(|a| a == "--recipe") {
        let path_str = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if path_str.is_empty() || path_str.starts_with("--") {
            eprintln!("Usage: chump --recipe <path.yaml> [--<param> <value> ...]");
            std::process::exit(2);
        }
        // Collect remaining key=value pairs (skip --recipe <path> at pos and pos+1)
        let mut param_overrides: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        let mut i = pos + 2;
        while i < args.len() {
            let flag = &args[i];
            if flag.starts_with("--") {
                let key = flag.trim_start_matches('-').replace('-', "_");
                if let Some(val) = args.get(i + 1) {
                    if !val.starts_with("--") {
                        param_overrides.insert(key, val.clone());
                        i += 2;
                        continue;
                    }
                }
                // boolean flag with no value — treat as "true"
                param_overrides.insert(key, "true".to_string());
            }
            i += 1;
        }
        let recipe_path = std::path::Path::new(path_str);
        let repo_root = repo_path::repo_root();
        // Resolve recipe path: if relative, try relative to repo root first
        let resolved_path = if recipe_path.is_absolute() {
            recipe_path.to_path_buf()
        } else {
            let candidate = repo_root.join(recipe_path);
            if candidate.exists() {
                candidate
            } else {
                recipe_path.to_path_buf()
            }
        };
        match recipe::run_recipe(&resolved_path, &param_overrides, &repo_root) {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump --recipe: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump dispatch <GAP-ID>` (INFRA-191 Phase 1+2) — atomic ship cycle:
    // preflight → claim → (work) → ship → release.
    //
    // Phase 1 wraps gap-preflight.sh, gap-claim.sh, bot-merge.sh.
    // Phase 2 adds --backend headless / exec-gap (spawns `claude -p` or
    // `chump --execute-gap`). Phase 3 ports ship() to native Rust.
    // See docs/design/INFRA-191-chump-dispatch.md.
    //
    // Examples:
    //   chump dispatch INFRA-191                              # interactive (default)
    //   chump dispatch INFRA-191 --auto-merge                 # arm merge queue
    //   chump dispatch INFRA-191 --auto-merge --skip-tests    # for doc PRs
    //   chump dispatch INFRA-191 --paths "src/dispatch.rs"    # narrow lease scope
    //   chump dispatch INFRA-191 --backend headless \
    //       --prompt "ship the gap" --model claude-sonnet-4-6 # spawn `claude -p`
    //   chump dispatch INFRA-191 --backend exec-gap           # spawn `chump --execute-gap`
    // INFRA-392: subcommands route/scoreboard/simulate are handled later in
    // this file. Without this guard, args[2]="route" (etc.) was treated as a
    // gap-id and routed through gap-preflight + bot-merge — making
    // `chump dispatch route INFRA-191` claim a phantom gap named "route"
    // instead of printing a routing cascade.
    const DISPATCH_SUBCOMMANDS: &[&str] = &["route", "scoreboard", "simulate", "cost-report"];
    if args.get(1).map(String::as_str) == Some("dispatch")
        && !args
            .get(2)
            .map(|s| DISPATCH_SUBCOMMANDS.contains(&s.as_str()))
            .unwrap_or(false)
    {
        let gap_id = match args.get(2) {
            Some(g) if !g.starts_with('-') => g.clone(),
            _ => {
                eprintln!(
                    "Usage: chump dispatch <GAP-ID> [--auto-merge] [--skip-tests] [--paths X,Y] [--backend BACKEND] [--model M] [--prompt P] [--repair] [--print-prompt]"
                );
                std::process::exit(2);
            }
        };
        let auto_merge = args.iter().any(|a| a == "--auto-merge");
        let skip_tests = args.iter().any(|a| a == "--skip-tests");
        // CREDIBLE-1589: explicit opt-in to repair an already-open PR. When a PR
        // is open for the gap, this flag (not the ambient
        // CHUMP_CLAIM_ALLOW_DUPLICATE_PR env default) is what admits the dispatch
        // as a REPAIR onto the PR head branch via the gate below.
        let repair_flag = args.iter().any(|a| a == "--repair");
        if args.iter().any(|a| a == "--dry-run") {
            std::env::set_var("CHUMP_DISPATCH_EXTERNAL_DRY_RUN", "1");
        }
        let paths = args
            .iter()
            .position(|a| a == "--paths")
            .and_then(|i| args.get(i + 1))
            .cloned();
        let backend = args
            .iter()
            .position(|a| a == "--backend")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .or_else(|| std::env::var("CHUMP_DISPATCH_BACKEND").ok())
            .unwrap_or_else(|| "interactive".into());
        let model = args
            .iter()
            .position(|a| a == "--model")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_default();
        let prompt = args
            .iter()
            .position(|a| a == "--prompt")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_default();

        let repo_root = repo_path::repo_root();

        // CREDIBLE-1577 / CREDIBLE-1526 AC5: refuse --auto-merge with exit 2
        // BEFORE spawning any agent when --paths or the branch diff vs
        // origin/main touches a ship-gate file. No env override.
        if let Err(hit) = dispatch::check_workspace_auto_merge_gate(
            &repo_root,
            &gap_id,
            auto_merge,
            paths.as_deref(),
        ) {
            eprintln!(
                "REFUSED: chump dispatch will not run with --auto-merge — gap {gap_id} touches gate file {hit} (CREDIBLE-1577 / CREDIBLE-1526 AC5). Re-run without --auto-merge so the PR lands through the review organ."
            );
            std::process::exit(2);
        }

        // INFRA-8199: run the INFRA-1982 open-PR check BEFORE spawning any
        // work backend. An open PR refuses (PR number + head branch printed)
        // unless CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1, which turns the cycle into
        // a repair on the PR head branch. Logic lives in dispatch_repair.
        // `--print-prompt` prints the resolved mode + prompt and exits 0
        // without spawning anything (operator preview; CI fixture surface).
        let print_prompt = args.iter().any(|a| a == "--print-prompt");
        let is_external_gap = !repair_flag
            && dispatch_repair::load_canonical_gap(&repo_root, &gap_id)
                .ok()
                .and_then(|row| {
                    dispatch::external_repo_target_from_skills(&row.skills_required)
                        .or_else(|| dispatch::external_repo_target_from_skills(&row.notes))
                })
                .is_some();
        let spawns_work = backend != "interactive" && backend != "claude" && !is_external_gap;
        let open_pr = if spawns_work {
            match dispatch_repair::open_pr_gate(&repo_root, &gap_id, repair_flag) {
                Ok(pr) => pr,
                Err(refusal) => {
                    eprintln!("{refusal}");
                    std::process::exit(1);
                }
            }
        } else {
            None
        };
        let mut mode = match &open_pr {
            Some(pr) => {
                // CREDIBLE-1589: report the actual trigger — the explicit
                // --repair flag is the documented path; the env bypass is legacy.
                let via = if repair_flag {
                    "--repair".to_string()
                } else {
                    format!("{}=1", dispatch_repair::ALLOW_DUP_ENV)
                };
                eprintln!(
                    "[dispatch] {via} and open PR #{} exists: repairing on {}",
                    pr.number, pr.head_branch
                );
                dispatch::DispatchMode::Repair {
                    head_branch: pr.head_branch.clone(),
                }
            }
            None => dispatch::DispatchMode::Work,
        };

        // INFRA-8220: layer-aware default model/budget when --model is omitted.
        // Inspect the gap's footprint (--paths lease scope + description path
        // hints): Rust under src/ or crates/ → opus + 3600s; shell/yaml/md only
        // → sonnet + 1800s. A concrete `model:` on the gap's matched
        // docs/dispatch/routing.yaml route still overrides. Logic lives in
        // dispatch_model_defaults; this arm stays thin (resolve → set → log).
        let model = if model.is_empty() {
            let canonical_root = repo_path::main_checkout_root();
            let gap_row = chump_gap_store::GapStore::open(&canonical_root)
                .ok()
                .and_then(|store| store.get(&gap_id).ok().flatten());
            let description = gap_row
                .as_ref()
                .map(|r| r.description.clone())
                .unwrap_or_default();
            // routing.yaml override: a matched route whose first candidate pins
            // a concrete `model:` wins over the footprint heuristic.
            let routing_override = gap_row.as_ref().and_then(|r| {
                chump_orchestrator::dispatch::select_candidates_for_gap(
                    &canonical_root,
                    &gap_id,
                    &r.priority,
                    &r.effort,
                )
                .into_iter()
                .find_map(|c| c.model)
            });
            match dispatch_model_defaults::select_default_model(
                paths.as_deref(),
                &description,
                routing_override.as_deref(),
            ) {
                Some(sel) => {
                    eprintln!(
                        "[dispatch] layer-aware default: model={} budget={}s ({})",
                        sel.model, sel.budget_secs, sel.reason
                    );
                    // Honor an operator-set budget or effort-scaled canonical gap budget;
                    // only fall back to the layer default when neither is set.
                    if std::env::var_os("CHUMP_SUBAGENT_BUDGET_S").is_none()
                        && std::env::var_os("CHUMP_DISPATCH_TIMEOUT_SECS").is_none()
                        && dispatch_repair::load_canonical_gap(&repo_root, &gap_id).is_err()
                    {
                        std::env::set_var("CHUMP_SUBAGENT_BUDGET_S", sel.budget_secs.to_string());
                    }
                    dispatch_model_defaults::emit_dispatch_model_selected(&gap_id, &sel);
                    sel.model
                }
                None => model,
            }
        } else {
            model
        };
        let work = match backend.as_str() {
            "interactive" => dispatch::WorkBackend::Interactive,
            // EFFECTIVE: `--backend claude` is a historical alias for `interactive` — it
            // does NOT run a model (the caller must have already made the edits). On a
            // fresh node this silently no-op'd the work (found 2026-08-09). Keep the
            // behavior (test-pr-cost-telemetry.sh relies on it) but WARN loudly and point
            // at headless, so the trap isn't silent.
            "claude" => {
                eprintln!(
                    "[dispatch] note: --backend claude == interactive — dispatch does NOT run the \
                     model, so no code gets written unless the caller already made the changes. To \
                     have chump write the code with Claude, use: --backend headless"
                );
                dispatch::WorkBackend::Interactive
            }
            "headless" => {
                // EFFECTIVE: auto-build the work prompt from the gap when --prompt is
                // omitted, so `chump dispatch <GAP> --backend headless` works with no
                // hand-written prompt (parity with `chump --execute-gap`).
                let work_prompt = if prompt.trim().is_empty() {
                    eprintln!(
                        "[dispatch] no --prompt given; auto-building the work prompt from gap {gap_id}"
                    );
                    // INFRA-8199: repair brief when a PR is open; decompose
                    // --dry-run + stop when the description asks for it;
                    // never self-directed decomposition.
                    // RESILIENT-1494: when actually spawning (not --print-prompt),
                    // require the gap to exist in the canonical store and fail loud
                    // rather than spawning claude -p on an empty/fallback prompt.
                    let (kind, built) = if print_prompt {
                        dispatch_repair::build_auto_prompt(&gap_id, &repo_root, open_pr.as_ref())
                    } else {
                        match dispatch_repair::build_auto_prompt_checked(
                            &gap_id,
                            &repo_root,
                            open_pr.as_ref(),
                        ) {
                            Ok(pair) => pair,
                            Err(e) => {
                                eprintln!("chump dispatch: {e}");
                                std::process::exit(1);
                            }
                        }
                    };
                    if kind == dispatch_repair::AutoPromptKind::DecomposeReview {
                        mode = dispatch::DispatchMode::ReviewOnly;
                    }
                    eprintln!("[dispatch] auto-prompt kind={kind:?}");
                    built
                } else {
                    prompt.clone()
                };
                if print_prompt {
                    println!("[dispatch] mode={mode:?}\n{work_prompt}");
                    return Ok(());
                }
                dispatch::WorkBackend::Headless {
                    model: model.clone(),
                    prompt: work_prompt,
                }
            }
            "exec-gap" | "chump-local" /* alias */ => {
                if print_prompt {
                    println!("[dispatch] mode={mode:?} (exec-gap builds its own prompt)");
                    return Ok(());
                }
                dispatch::WorkBackend::ExecGap
            }
            other => {
                eprintln!(
                    "chump dispatch: unknown --backend {other:?}; expected one of: interactive, claude, headless, exec-gap"
                );
                std::process::exit(2);
            }
        };
        let opts = dispatch::DispatchOptions {
            gap_id: &gap_id,
            work,
            auto_merge,
            skip_tests,
            paths: paths.as_deref(),
            repo_root,
            mode,
        };

        match dispatch::run(opts) {
            Ok(outcome) => {
                println!(
                    "[dispatch] {} branch={} duration={}s",
                    outcome.gap_id, outcome.branch, outcome.duration_secs
                );
                match outcome.result {
                    dispatch::ShipResult::Shipped { pr_number } => {
                        println!("[dispatch] shipped PR #{pr_number}");
                        return Ok(());
                    }
                    // CREDIBLE-1506: an armed+pending PR is a success (exit 0).
                    // The merge lands on green CI; the gap's auto-close belongs
                    // to the reconciler after ship_landed, not to dispatch.
                    dispatch::ShipResult::Armed { pr_number } => {
                        println!(
                            "[dispatch] armed PR #{pr_number} — auto-merge pending, will land on green CI"
                        );
                        return Ok(());
                    }
                    dispatch::ShipResult::Blocked { reason } => {
                        eprintln!("[dispatch] blocked: {reason}");
                        std::process::exit(1);
                    }
                    dispatch::ShipResult::Aborted { error } => {
                        eprintln!("[dispatch] aborted: {error}");
                        std::process::exit(1);
                    }
                }
            }
            Err(e) => {
                eprintln!("[dispatch] failed: {e:#}");
                // INFRA-8198: print a matching "exit=" line on this path too
                // (previously only the Ok(outcome) branch's single-exit-point
                // print in dispatch::run() did) — a run() failure before that
                // point (preflight/claim/worktree setup) spawned no work
                // child, so child_pid=0/child_alive_at_exit=false here is
                // always correct, not just "happens to be false".
                eprintln!(
                    "[dispatch] {gap_id} exit=1 reason=early-failure:{e:#} child_pid=0 child_alive_at_exit=false"
                );
                std::process::exit(1);
            }
        }
    }

    // `chump fleet <start|stop|status|scale>` (INFRA-596)
    // Wraps scripts/dispatch/run-fleet.sh + fleet-status.sh so operators
    // don't need to remember FLEET_SIZE/FLEET_EFFORT_FILTER/CHUMP_REPO env vars.
    // Reads defaults from ~/.chump/config.toml [fleet] section when present.

    Box::pin(fleet_modes::dispatch_fleet(args)).await
}
