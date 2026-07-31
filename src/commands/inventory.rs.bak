//! META-271 / INFRA-2370 — `chump inventory` subcommand.
//!
//! REVIEW-ONLY mode. None of these subcommands files gaps or removes code.
//! `promote` is the only state transition that elevates a finding_class
//! to tier=2 (auto-file eligible), and even then no gap is filed until
//! INFRA-2374 wires the tier-2 machinery.
//!
//! Subcommands:
//!   rebuild                                  full repopulate
//!   show <pr|gap|path>                       artifact/PR detail
//!   debt-report [--tier N] [--class C]       list findings
//!   dead-code                                slice of debt-report (dead-rust-mod + orphan-artifact)
//!   orphans                                  slice of debt-report (orphan-artifact only)
//!   review <id> --classify X [--note "..."]  mark finding REAL_POSITIVE / FALSE_POSITIVE / NEEDS_INVESTIGATION
//!   review-queue [--limit N]                 unreviewed findings, oldest first
//!   class-stats                              per-class totals + tier + RP ratio
//!   promote <finding_class>                  tier 0 → 2 (rejects below thresholds)
//!   demote <finding_class>                   tier → 0 escape hatch
//!
//! All read subcommands support --json.

use crate::inventory::{
    self, backfill_artifact_provenance, class_stats, collect_artifacts, collect_prs_v2,
    demote_class, list_findings, meta_counts, pr_dependent_detectors_disabled, promote_class,
    recompute_activation_with_provenance, repo_root, review_finding, run_detectors_v2,
    write_rebuild_meta, FindingRow, PrCollectionPath, DETECTOR_CLASSES, PR_DEPENDENT_DETECTORS,
};

fn print_help() {
    println!("Usage: chump inventory <subcommand> [args]");
    println!();
    println!("REVIEW-ONLY mode (META-271). No subcommand files gaps or removes code.");
    println!();
    println!("Subcommands:");
    println!("  rebuild                                       full repopulate of inventory DB");
    println!("  show <pr-number|gap-id|path> [--json]         artifact/PR detail (full profile incl. introducing PR)");
    println!("  pr <pr-number> [--json]                       PR + every artifact it shipped + activation health (INFRA-2384)");
    println!("  debt-report [--tier N] [--class C] [--json]   list findings (all tiers default)");
    println!(
        "  dead-code [--json]                            findings: dead-rust-mod + orphan-artifact"
    );
    println!("  orphans [--json]                              findings: orphan-artifact only");
    println!("  review <id> --classify <REAL_POSITIVE|FALSE_POSITIVE|NEEDS_INVESTIGATION> [--note \"...\"]");
    println!("  review-queue [--limit N] [--json]             unreviewed findings, oldest first");
    println!("  class-stats [--json]                          per-class totals + tier + ratio");
    println!("  promote <finding_class>                       tier 0 → 2 (≥10 reviewed, ≥70% RP required)");
    println!("  demote <finding_class>                        tier → 0 escape hatch");
    println!();
    println!("Detector classes ({}):", DETECTOR_CLASSES.len());
    for c in DETECTOR_CLASSES {
        println!("  {}", c);
    }
}

pub fn run(args: &[String]) -> i32 {
    if args.is_empty() {
        print_help();
        return 0;
    }
    match args[0].as_str() {
        "rebuild" => cmd_rebuild(&args[1..]),
        "show" => cmd_show(&args[1..]),
        "pr" => cmd_pr(&args[1..]),
        "debt-report" => cmd_debt_report(&args[1..]),
        "dead-code" => cmd_dead_code(&args[1..]),
        "orphans" => cmd_orphans(&args[1..]),
        "review" => cmd_review(&args[1..]),
        "review-queue" => cmd_review_queue(&args[1..]),
        "class-stats" => cmd_class_stats(&args[1..]),
        "promote" => cmd_promote(&args[1..]),
        "demote" => cmd_demote(&args[1..]),
        "--help" | "-h" | "help" => {
            print_help();
            0
        }
        other => {
            eprintln!("chump inventory: unknown subcommand '{other}'");
            print_help();
            2
        }
    }
}

// ─── rebuild ────────────────────────────────────────────────────────────────

fn cmd_rebuild(_args: &[String]) -> i32 {
    let root = repo_root();
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[inventory rebuild] open_db failed: {e}");
            return 1;
        }
    };
    println!("[inventory rebuild] collecting PRs...");
    let pr_result = collect_prs_v2(&conn, &root).unwrap_or_else(|e| {
        eprintln!("[inventory rebuild] collect_prs warn: {e}");
        inventory::PrCollectionResult {
            indexed: 0,
            auth_source: inventory::AuthSource::Missing,
            used_path: PrCollectionPath::Skipped,
            fallback_to_cli: false,
        }
    });
    let path_label = match pr_result.used_path {
        PrCollectionPath::RestCurl => "rest",
        PrCollectionPath::GhCli => "gh-cli",
        PrCollectionPath::Skipped => "skipped",
    };
    let fallback_tag = if pr_result.fallback_to_cli {
        " (rest→cli fallback)"
    } else {
        ""
    };
    println!(
        "[inventory rebuild] pr_index: {} indexed from {} (auth={}){}",
        pr_result.indexed,
        path_label,
        pr_result.auth_source.label(),
        fallback_tag,
    );

    println!("[inventory rebuild] collecting artifacts...");
    let artifacts = collect_artifacts(&conn, &root).unwrap_or_else(|e| {
        eprintln!("[inventory rebuild] collect_artifacts warn: {e}");
        0
    });
    println!("[inventory rebuild] indexed {artifacts} artifacts");

    let prs_available = pr_result.auth_source.is_available() && pr_result.indexed > 0;

    // INFRA-2384: backfill artifact → PR provenance once pr_index is populated.
    if prs_available {
        println!(
            "[inventory rebuild] backfilling artifact provenance (git-log A walk + PR bisect)..."
        );
        match backfill_artifact_provenance(&conn, &root) {
            Ok(r) => {
                let linked_pct = if r.artifacts_total == 0 {
                    0.0
                } else {
                    100.0 * (r.introducing_pr_linked as f64) / (r.artifacts_total as f64)
                };
                println!(
                    "[inventory rebuild] provenance: {}/{} linked ({:.1}%), {} with gap_id, {} unlinkable",
                    r.introducing_pr_linked,
                    r.artifacts_total,
                    linked_pct,
                    r.introducing_gap_linked,
                    r.unlinkable_provenance,
                );
            }
            Err(e) => eprintln!("[inventory rebuild] backfill warn: {e}"),
        }
        println!("[inventory rebuild] recomputing activation_state with PR provenance...");
        match recompute_activation_with_provenance(&conn, &root) {
            Ok(n) => println!("[inventory rebuild] activation recomputed for {n} artifact(s)"),
            Err(e) => eprintln!("[inventory rebuild] recompute warn: {e}"),
        }
    }

    if !prs_available {
        println!(
            "[inventory rebuild] WARN: PR backfill unavailable — disabling {} PR-dependent detector(s): {}",
            PR_DEPENDENT_DETECTORS.len(),
            PR_DEPENDENT_DETECTORS.join(", "),
        );
    }
    println!("[inventory rebuild] running detectors (tier=0 surface-only)...");
    let n = run_detectors_v2(&conn, &root, prs_available).unwrap_or_else(|e| {
        eprintln!("[inventory rebuild] detectors warn: {e}");
        0
    });
    println!("[inventory rebuild] {n} findings recorded at tier=0");

    if let Err(e) = write_rebuild_meta(&conn, pr_result.indexed as i64, artifacts as i64) {
        eprintln!("[inventory rebuild] meta-write warn: {e}");
    }

    let (pr_total, art_total, find_total) = meta_counts(&conn).unwrap_or((0, 0, 0));
    println!(
        "[inventory rebuild] totals: prs={pr_total} artifacts={art_total} findings={find_total}"
    );
    println!("[inventory rebuild] REVIEW-ONLY mode: no gaps filed, no actions taken.");
    println!("[inventory rebuild] next: chump inventory debt-report --tier 0");
    0
}

// ─── show ───────────────────────────────────────────────────────────────────

fn cmd_show(args: &[String]) -> i32 {
    if args.is_empty() {
        eprintln!("Usage: chump inventory show <pr-number|gap-id|path>");
        return 2;
    }
    let target = &args[0];
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };

    // Try PR number first.
    if let Ok(n) = target.parse::<i64>() {
        let row = conn.query_row(
            "SELECT pr_number, title, state, gap_id, domain, merged_at, additions, deletions, files_changed
             FROM pr_index WHERE pr_number=?1",
            rusqlite::params![n],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, Option<i64>>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                    r.get::<_, i64>(8)?,
                ))
            },
        );
        if let Ok((num, title, state, gap, domain, merged, add, del, changed)) = row {
            println!("PR #{num}");
            println!("  title:        {title}");
            println!("  state:        {state}");
            println!("  gap_id:       {}", gap.unwrap_or_else(|| "-".to_string()));
            println!(
                "  domain:       {}",
                domain.unwrap_or_else(|| "-".to_string())
            );
            println!(
                "  merged_at:    {}",
                merged
                    .map(|t| t.to_string())
                    .unwrap_or_else(|| "-".to_string())
            );
            println!("  +{add} -{del} ({changed} files)");
            return 0;
        }
    }
    // Try as gap_id.
    let prs: Vec<(i64, String, String)> = {
        let mut stmt = match conn.prepare(
            "SELECT pr_number, title, state FROM pr_index WHERE gap_id=?1 ORDER BY pr_number",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("prepare failed: {e}");
                return 1;
            }
        };
        let mapped = stmt.query_map(rusqlite::params![target], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        });
        match mapped {
            Ok(it) => it.filter_map(|r| r.ok()).collect(),
            Err(_) => Vec::new(),
        }
    };
    if !prs.is_empty() {
        println!("PRs for gap {target}:");
        for (n, t, s) in prs {
            println!("  #{n} [{s}] {t}");
        }
        return 0;
    }
    // Try as path — full INFRA-2384 profile w/ introducing PR.
    let json = has_flag(args, "--json");
    if let Some(rc) = show_artifact_path(&conn, target, json) {
        return rc;
    }
    eprintln!("inventory show: '{target}' not found as PR number, gap ID, or path");
    1
}

/// INFRA-2384: print the full artifact profile (class, size, activation,
/// introducing PR row, last-modified ts, referenced_from sample).
/// Returns Some(rc) if the path was found in artifact_index; None otherwise.
fn show_artifact_path(conn: &rusqlite::Connection, target: &str, json: bool) -> Option<i32> {
    type ArtRow = (
        String,
        String,
        i64,
        String,
        i64,
        Option<String>,
        Option<String>,
        Option<i64>,
        Option<String>,
        i64,
    );
    let row: ArtRow = conn
        .query_row(
            "SELECT path, class, size_bytes, activation_state, reference_count,
                    referenced_from, introducing_gap, introducing_pr, notes,
                    last_modified_at
             FROM artifact_index WHERE path=?1",
            rusqlite::params![target],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, Option<String>>(5)?,
                    r.get::<_, Option<String>>(6)?,
                    r.get::<_, Option<i64>>(7)?,
                    r.get::<_, Option<String>>(8)?,
                    r.get::<_, i64>(9)?,
                ))
            },
        )
        .ok()?;
    let (
        path,
        class,
        size,
        state,
        refs,
        referenced_from,
        intro_gap,
        intro_pr,
        notes,
        last_modified_at,
    ) = row;

    // Resolve the introducing PR row if any.
    type PrRow = (String, String, Option<i64>, Option<String>);
    let pr_row: Option<PrRow> = intro_pr.and_then(|pr| {
        conn.query_row(
            "SELECT title, state, merged_at, author FROM pr_index WHERE pr_number=?1",
            rusqlite::params![pr],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<i64>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                ))
            },
        )
        .ok()
    });

    let referrers: Vec<String> = referenced_from
        .as_deref()
        .and_then(|s| serde_json::from_str::<Vec<String>>(s).ok())
        .unwrap_or_default();

    if json {
        let obj = serde_json::json!({
            "path": path,
            "class": class,
            "size_bytes": size,
            "activation_state": state,
            "reference_count": refs,
            "referenced_from": referrers,
            "introducing_pr": intro_pr,
            "introducing_gap": intro_gap,
            "introducing_pr_title": pr_row.as_ref().map(|r| &r.0),
            "introducing_pr_state": pr_row.as_ref().map(|r| &r.1),
            "introducing_pr_merged_at": pr_row.as_ref().and_then(|r| r.2),
            "introducing_pr_author": pr_row.as_ref().and_then(|r| r.3.clone()),
            "last_modified_at": last_modified_at,
            "notes": notes,
        });
        match serde_json::to_string_pretty(&obj) {
            Ok(s) => println!("{s}"),
            Err(_) => println!("{{}}"),
        }
        return Some(0);
    }

    println!("Artifact: {path}");
    println!("  Class:           {class}");
    println!("  Size:            {size} bytes");
    println!("  Activation:      {state} ({} callers)", refs);
    println!();
    println!("Introduced by:");
    if let (Some(pr_n), Some((title, pr_state, merged_at, author))) = (intro_pr, pr_row) {
        let gap = intro_gap.as_deref().unwrap_or("-");
        println!("  PR #{pr_n} ({gap}) \"{title}\"");
        println!("  State:           {pr_state}");
        if let Some(m) = merged_at {
            println!("  Merged:          {}", format_ts_iso(m));
        }
        println!(
            "  Author:          {}",
            author.unwrap_or_else(|| "-".to_string())
        );
    } else if let Some(pr_n) = intro_pr {
        println!("  PR #{pr_n} (details not in pr_index)");
    } else {
        println!("  (provenance backfill couldn't link — pr_index may be empty or this artifact pre-dates the oldest indexed PR)");
    }

    println!();
    println!("Recent activity:");
    if last_modified_at > 0 {
        println!("  Last modified:   {}", format_ts_iso(last_modified_at));
    } else {
        println!("  Last modified:   (no git history recorded)");
    }
    if !referrers.is_empty() {
        let preview = referrers.iter().take(5).cloned().collect::<Vec<_>>();
        println!("  Referenced from: {} files", referrers.len());
        for r in preview {
            println!("    - {r}");
        }
        if referrers.len() > 5 {
            println!("    (+{} more)", referrers.len() - 5);
        }
    } else {
        println!("  Referenced from: (no callers found)");
    }
    if let Some(n) = notes {
        if !n.is_empty() {
            println!("  Notes:           {n}");
        }
    }
    Some(0)
}

fn format_ts_iso(ts: i64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp(ts, 0)
        .map(|dt| dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
        .unwrap_or_else(|| ts.to_string())
}

// ─── pr <N> ─────────────────────────────────────────────────────────────────

fn cmd_pr(args: &[String]) -> i32 {
    if args.is_empty() {
        eprintln!("Usage: chump inventory pr <pr-number> [--json]");
        return 2;
    }
    let n: i64 = match args[0].parse() {
        Ok(n) => n,
        Err(_) => {
            eprintln!("error: pr number must be integer (got '{}')", args[0]);
            return 2;
        }
    };
    let json = has_flag(args, "--json");
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    type PrRow = (
        String,
        String,
        Option<String>,
        Option<String>,
        Option<i64>,
        Option<String>,
    );
    let pr_row: Option<PrRow> = conn
        .query_row(
            "SELECT title, state, gap_id, domain, merged_at, author
             FROM pr_index WHERE pr_number=?1",
            rusqlite::params![n],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<i64>>(4)?,
                    r.get::<_, Option<String>>(5)?,
                ))
            },
        )
        .ok();
    let (title, state, gap_id, _domain, merged_at, author) = match pr_row {
        Some(r) => r,
        None => {
            eprintln!("inventory pr: PR #{n} not found in pr_index");
            return 1;
        }
    };

    // Load every artifact this PR introduced.
    type ArtifactRow = (String, String, String, i64);
    let mut artifacts: Vec<ArtifactRow> = Vec::new();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT path, class, activation_state, reference_count
         FROM artifact_index WHERE introducing_pr=?1
         ORDER BY path",
    ) {
        if let Ok(mapped) = stmt.query_map(rusqlite::params![n], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        }) {
            for r in mapped.flatten() {
                artifacts.push(r);
            }
        }
    }

    // Activation health roll-up.
    let mut counts = std::collections::HashMap::<String, usize>::new();
    for (_p, _c, state, _refs) in &artifacts {
        *counts.entry(state.clone()).or_insert(0) += 1;
    }
    let total = artifacts.len();
    let referenced = *counts.get("referenced").unwrap_or(&0);
    let dormant = *counts.get("dormant").unwrap_or(&0);
    let orphan = *counts.get("orphan").unwrap_or(&0);
    let unknown = *counts.get("unknown").unwrap_or(&0);

    if json {
        let arr: Vec<serde_json::Value> = artifacts
            .iter()
            .map(|(p, c, s, r)| {
                serde_json::json!({
                    "path": p,
                    "class": c,
                    "activation_state": s,
                    "reference_count": r,
                })
            })
            .collect();
        let obj = serde_json::json!({
            "pr_number": n,
            "title": title,
            "state": state,
            "gap_id": gap_id,
            "merged_at": merged_at,
            "author": author,
            "artifacts_total": total,
            "activation_health": {
                "referenced": referenced,
                "dormant": dormant,
                "orphan": orphan,
                "unknown": unknown,
            },
            "artifacts": arr,
        });
        match serde_json::to_string_pretty(&obj) {
            Ok(s) => println!("{s}"),
            Err(_) => println!("{{}}"),
        }
        return 0;
    }

    let merged_label = merged_at
        .map(|t| {
            chrono::DateTime::<chrono::Utc>::from_timestamp(t, 0)
                .map(|dt| dt.format("%Y-%m-%d").to_string())
                .unwrap_or_else(|| t.to_string())
        })
        .unwrap_or_else(|| "-".to_string());
    println!("PR #{n} ({state} {merged_label})");
    println!("  Title:  {title}");
    println!(
        "  Gap:    {} [{}]",
        gap_id.as_deref().unwrap_or("-"),
        gap_id
            .as_deref()
            .and_then(|g| g.split('-').next())
            .unwrap_or("-")
    );
    println!("  Author: {}", author.unwrap_or_else(|| "-".to_string()));
    println!();
    if total == 0 {
        println!("No artifacts linked to this PR.");
        println!("(Either the backfill couldn't link any rows yet, or this PR landed only deletions / modifications.)");
        return 0;
    }
    println!(
        "Shipped {total} artifact{}:",
        if total == 1 { "" } else { "s" }
    );
    for (path, _class, st, refs) in &artifacts {
        let mark = match st.as_str() {
            "referenced" => "ok ",
            "dormant" => "?  ",
            "orphan" => "x  ",
            _ => "?  ",
        };
        let trailing = match st.as_str() {
            "referenced" => format!("({} callers)", refs),
            "dormant" => format!("({} caller{})", refs, if *refs == 1 { "" } else { "s" }),
            "orphan" => "(0 callers)".to_string(),
            _ => "(provenance backfill couldn't link)".to_string(),
        };
        println!("  {mark} {:<10} {path} {trailing}", st);
    }
    println!();
    println!(
        "Activation health: {}/{total} referenced, {}/{total} dormant, {}/{total} orphan, {}/{total} unknown",
        referenced, dormant, orphan, unknown
    );
    0
}

// ─── debt-report / dead-code / orphans / review-queue ───────────────────────

fn parse_int_flag(args: &[String], name: &str) -> Option<i64> {
    let mut i = 0;
    while i < args.len() {
        if args[i] == name && i + 1 < args.len() {
            return args[i + 1].parse::<i64>().ok();
        }
        i += 1;
    }
    None
}

fn parse_str_flag(args: &[String], name: &str) -> Option<String> {
    let mut i = 0;
    while i < args.len() {
        if args[i] == name && i + 1 < args.len() {
            return Some(args[i + 1].clone());
        }
        i += 1;
    }
    None
}

fn has_flag(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn print_findings(rows: &[FindingRow], json: bool) {
    if json {
        let obj = serde_json::json!({"findings": rows});
        match serde_json::to_string_pretty(&obj) {
            Ok(s) => println!("{s}"),
            Err(_) => println!("{{}}"),
        }
        return;
    }
    if rows.is_empty() {
        println!("(no findings)");
        return;
    }
    println!(
        "{:<6}  {:<28}  {:<6}  {:<8}  detail",
        "id", "class", "tier", "review"
    );
    for r in rows {
        let review = r
            .operator_classification
            .as_deref()
            .map(|c| match c {
                "REAL_POSITIVE" => "RP",
                "FALSE_POSITIVE" => "FP",
                "NEEDS_INVESTIGATION" => "NI",
                _ => "?",
            })
            .unwrap_or("-");
        println!(
            "{:<6}  {:<28}  {:<6}  {:<8}  {}",
            r.finding_id, r.finding_class, r.tier, review, r.detail
        );
    }
    println!();
    println!("({} findings)", rows.len());
}

fn cmd_debt_report(args: &[String]) -> i32 {
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    let tier = parse_int_flag(args, "--tier");
    let class = parse_str_flag(args, "--class");
    let limit = parse_int_flag(args, "--limit");
    let json = has_flag(args, "--json");
    let rows = match list_findings(&conn, tier, class.as_deref(), false, limit) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("list_findings failed: {e}");
            return 1;
        }
    };
    print_findings(&rows, json);
    0
}

fn cmd_dead_code(args: &[String]) -> i32 {
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    let json = has_flag(args, "--json");
    let limit = parse_int_flag(args, "--limit");
    let mut all = Vec::new();
    for class in ["dead-rust-mod", "orphan-artifact"] {
        let rows = match list_findings(&conn, None, Some(class), false, limit) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("list_findings failed: {e}");
                return 1;
            }
        };
        all.extend(rows);
    }
    print_findings(&all, json);
    0
}

fn cmd_orphans(args: &[String]) -> i32 {
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    let json = has_flag(args, "--json");
    let limit = parse_int_flag(args, "--limit");
    let rows = match list_findings(&conn, None, Some("orphan-artifact"), false, limit) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("list_findings failed: {e}");
            return 1;
        }
    };
    print_findings(&rows, json);
    0
}

fn cmd_review_queue(args: &[String]) -> i32 {
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    let limit = parse_int_flag(args, "--limit");
    let json = has_flag(args, "--json");
    let rows = match list_findings(&conn, None, None, true, limit) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("list_findings failed: {e}");
            return 1;
        }
    };
    print_findings(&rows, json);
    0
}

// ─── review ─────────────────────────────────────────────────────────────────

fn cmd_review(args: &[String]) -> i32 {
    if args.is_empty() {
        eprintln!("Usage: chump inventory review <finding-id> --classify <REAL_POSITIVE|FALSE_POSITIVE|NEEDS_INVESTIGATION> [--note \"...\"]");
        return 2;
    }
    let id = match args[0].parse::<i64>() {
        Ok(n) => n,
        Err(_) => {
            eprintln!("error: <finding-id> must be an integer (got '{}')", args[0]);
            return 2;
        }
    };
    let cls = match parse_str_flag(args, "--classify") {
        Some(c) => c,
        None => {
            eprintln!("error: --classify is required");
            return 2;
        }
    };
    let note = parse_str_flag(args, "--note");
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    match review_finding(&conn, id, &cls, note.as_deref()) {
        Ok(()) => {
            println!("[inventory review] finding {id} classified as {cls}");
            0
        }
        Err(e) => {
            eprintln!("review failed: {e}");
            1
        }
    }
}

// ─── class-stats ────────────────────────────────────────────────────────────

fn cmd_class_stats(args: &[String]) -> i32 {
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    let json = has_flag(args, "--json");
    let stats = match class_stats(&conn) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("class_stats failed: {e}");
            return 1;
        }
    };
    if json {
        let obj = serde_json::json!({"classes": stats});
        match serde_json::to_string_pretty(&obj) {
            Ok(s) => println!("{s}"),
            Err(_) => println!("{{}}"),
        }
        return 0;
    }
    let disabled = pr_dependent_detectors_disabled(&conn);
    println!(
        "{:<28}  {:<5}  {:<10}  {:<9}  {:<5}  eligible",
        "class", "tier", "total", "reviewed", "RP%"
    );
    for s in &stats {
        let is_disabled = disabled && PR_DEPENDENT_DETECTORS.contains(&s.finding_class.as_str());
        let total_col = if is_disabled {
            "DISABLED".to_string()
        } else {
            s.total_findings.to_string()
        };
        let eligible = if is_disabled {
            "n/a (gh auth missing)".to_string()
        } else if s.eligible_for_promotion {
            "yes".to_string()
        } else {
            "no".to_string()
        };
        println!(
            "{:<28}  {:<5}  {:<10}  {:<9}  {:<5.0}  {}",
            s.finding_class,
            s.current_tier,
            total_col,
            s.reviewed_count,
            s.real_positive_ratio * 100.0,
            eligible,
        );
    }
    if disabled {
        println!();
        println!(
            "note: {} detector(s) DISABLED — gh auth missing on last rebuild. \
             Set GH_TOKEN or run `gh auth login` then `chump inventory rebuild`.",
            PR_DEPENDENT_DETECTORS.len(),
        );
    }
    0
}

// ─── promote / demote ───────────────────────────────────────────────────────

fn cmd_promote(args: &[String]) -> i32 {
    if args.is_empty() {
        eprintln!("Usage: chump inventory promote <finding_class>");
        return 2;
    }
    let cls = &args[0];
    let by = std::env::var("CHUMP_OPERATOR")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "operator".to_string());
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    match promote_class(&conn, cls, &by) {
        Ok(()) => {
            println!("[inventory promote] finding_class '{cls}' elevated to tier 2");
            println!("[inventory promote] note: tier-2 auto-file machinery ships with INFRA-2374");
            println!("[inventory promote] until then, this is only a capability marker — no gaps will be filed");
            0
        }
        Err(e) => {
            eprintln!("[inventory promote] rejected: {e}");
            1
        }
    }
}

fn cmd_demote(args: &[String]) -> i32 {
    if args.is_empty() {
        eprintln!("Usage: chump inventory demote <finding_class>");
        return 2;
    }
    let cls = &args[0];
    let by = std::env::var("CHUMP_OPERATOR")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "operator".to_string());
    let conn = match inventory::open_db() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("open_db failed: {e}");
            return 1;
        }
    };
    match demote_class(&conn, cls, &by) {
        Ok(()) => {
            println!("[inventory demote] finding_class '{cls}' returned to tier 0");
            0
        }
        Err(e) => {
            eprintln!("[inventory demote] failed: {e}");
            1
        }
    }
}
