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
    self, class_stats, collect_artifacts, collect_prs, demote_class, list_findings, meta_counts,
    promote_class, repo_root, review_finding, run_detectors, write_rebuild_meta, FindingRow,
    DETECTOR_CLASSES,
};

fn print_help() {
    println!("Usage: chump inventory <subcommand> [args]");
    println!();
    println!("REVIEW-ONLY mode (META-271). No subcommand files gaps or removes code.");
    println!();
    println!("Subcommands:");
    println!("  rebuild                                       full repopulate of inventory DB");
    println!("  show <pr-number|gap-id|path>                  artifact/PR detail");
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
    let prs = collect_prs(&conn, &root).unwrap_or_else(|e| {
        eprintln!("[inventory rebuild] collect_prs warn: {e}");
        0
    });
    println!("[inventory rebuild] indexed {prs} PRs");

    println!("[inventory rebuild] collecting artifacts...");
    let artifacts = collect_artifacts(&conn, &root).unwrap_or_else(|e| {
        eprintln!("[inventory rebuild] collect_artifacts warn: {e}");
        0
    });
    println!("[inventory rebuild] indexed {artifacts} artifacts");

    println!("[inventory rebuild] running 9 detectors (tier=0 surface-only)...");
    let n = run_detectors(&conn, &root).unwrap_or_else(|e| {
        eprintln!("[inventory rebuild] detectors warn: {e}");
        0
    });
    println!("[inventory rebuild] {n} findings recorded at tier=0");

    if let Err(e) = write_rebuild_meta(&conn, prs as i64, artifacts as i64) {
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
    // Try as path.
    let row = conn.query_row(
        "SELECT path, class, size_bytes, activation_state, reference_count, introducing_gap
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
            ))
        },
    );
    if let Ok((p, class, size, state, refs, intro)) = row {
        println!("artifact: {p}");
        println!("  class:            {class}");
        println!("  size_bytes:       {size}");
        println!("  activation:       {state}");
        println!("  reference_count:  {refs}");
        println!(
            "  introducing_gap:  {}",
            intro.unwrap_or_else(|| "-".to_string())
        );
        return 0;
    }
    eprintln!("inventory show: '{target}' not found as PR number, gap ID, or path");
    1
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
    println!(
        "{:<28}  {:<5}  {:<7}  {:<9}  {:<5}  eligible",
        "class", "tier", "total", "reviewed", "RP%"
    );
    for s in &stats {
        println!(
            "{:<28}  {:<5}  {:<7}  {:<9}  {:<5.0}  {}",
            s.finding_class,
            s.current_tier,
            s.total_findings,
            s.reviewed_count,
            s.real_positive_ratio * 100.0,
            if s.eligible_for_promotion {
                "yes"
            } else {
                "no"
            },
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
