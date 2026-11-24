//! `chump gap` portfolio rebalance, consolidation, impact rating, sync, and help subcommands.

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

#[allow(unused_variables, unreachable_code)]
pub(crate) async fn dispatch_gap_admin(
    args: Vec<String>,
    repo_root: std::path::PathBuf,
    worktree_root: std::path::PathBuf,
    json_out: bool,
    store: gap_store::GapStore,
) -> Result<()> {
    let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
    let flag = |name: &str| -> Option<String> {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    match subcmd {
        "close-decomposed" => {
            // RESILIENT-1364 fix #2: sweep every status='decomposed'
            // umbrella and auto-close (-> done) any whose slices
            // (parsed from its "Decomposed into N slices: ..." notes)
            // are ALL 'done'. Mirrors the outcomes open_children rollup
            // (chump-gap-store) but turns it into an action, since a
            // decomposed umbrella has no other route out of limbo once
            // its slices land — unlike an outcome, which just sits
            // advisory-open. Safe to run repeatedly / on a cron: a
            // parent with any non-done child is a no-op.
            if args
                .iter()
                .skip(3)
                .any(|a| matches!(a.as_str(), "--help" | "-h"))
            {
                println!("Usage: chump gap close-decomposed [--json]");
                println!();
                println!(
                    "Auto-closes decomposed umbrella parents whose child slices are all 'done'."
                );
                return Ok(());
            }
            let json_out = args.iter().skip(3).any(|a| a == "--json");
            let closed = store.auto_close_decomposed_parents()?;
            if json_out {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({ "closed": closed }))
                        .unwrap_or_default()
                );
            } else if closed.is_empty() {
                println!("no decomposed parents ready to auto-close.");
            } else {
                for id in &closed {
                    println!("auto-closed {id}: all child slices done.");
                }
            }
            return Ok(());
        }
        "scaffold-holes" => {
            // EFFECTIVE-440: mechanical hole-finder for the
            // scaffold-and-holes pattern. A scaffold PR merges traits +
            // todo!() holes + failing tests as ONE stable PR; this arm
            // lists every hole as a candidate one-hole-per-gap leaf spec
            // so each fill-this-hole gap is tiny, disjoint, and
            // mechanically verifiable (no LLM call, no ambiguity).
            if args
                .iter()
                .skip(3)
                .any(|a| matches!(a.as_str(), "--help" | "-h"))
            {
                println!(
                        "Usage: chump gap scaffold-holes <GAP-ID> [--path DIR] [--json] [--apply] [--metrics]"
                    );
                println!();
                println!("Scans DIR (default: repo root) for todo!() holes left by a scaffold PR");
                println!("and prints one fill-this-hole leaf-gap spec (title + AC) per hole.");
                println!(
                    "--apply files one leaf gap per hole via chump-gap-store instead of \
                         just printing specs (INFRA-2515 A2A voting still applies to what those \
                         leaf gaps become — this only reserves them)."
                );
                println!(
                    "--metrics compares shipped leaf gaps (depends_on GAP-ID) against a \
                         baseline of shipped open-ended gaps (no depends_on) in the same domain: \
                         mean ship cycle-time and file-collision rate for each group."
                );
                return Ok(());
            }
            let gap_id = match args.get(3) {
                Some(a) if !a.starts_with('-') => a.clone(),
                _ => {
                    eprintln!("Usage: chump gap scaffold-holes <GAP-ID> [--path DIR] [--json]");
                    std::process::exit(1);
                }
            };
            let scan_dir = flag("--path")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| repo_root.clone());
            let as_json = json_out || args.iter().any(|a| a == "--json");
            let do_apply = args.iter().any(|a| a == "--apply");
            let do_metrics = args.iter().any(|a| a == "--metrics");

            if do_metrics {
                let domain = store
                    .get(&gap_id)
                    .ok()
                    .flatten()
                    .map(|g| g.domain)
                    .unwrap_or_else(|| gap_id.split('-').next().unwrap_or("EFFECTIVE").to_string());
                let closed = store.list(Some("closed")).unwrap_or_default();
                let done = store.list(Some("done")).unwrap_or_default();
                let all_closed: Vec<_> = closed.into_iter().chain(done).collect();

                let files_for_pr = |pr: i64| -> Vec<String> {
                    let out = std::process::Command::new("git")
                        .args(["log", "--all", "--merges", "--format=%H"])
                        .arg("--grep")
                        .arg(format!("#{pr}"))
                        .current_dir(&repo_root)
                        .output();
                    let Ok(out) = out else { return Vec::new() };
                    let sha = String::from_utf8_lossy(&out.stdout)
                        .lines()
                        .next()
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    if sha.is_empty() {
                        return Vec::new();
                    }
                    std::process::Command::new("git")
                        .args(["show", "--stat", "--format=", &sha])
                        .current_dir(&repo_root)
                        .output()
                        .map(|o| {
                            String::from_utf8_lossy(&o.stdout)
                                .lines()
                                .filter_map(|l| l.split('|').next())
                                .map(|s| s.trim().to_string())
                                .filter(|s| !s.is_empty())
                                .collect()
                        })
                        .unwrap_or_default()
                };

                let to_metric = |g: &gap_store::GapRow| -> scaffold_holes::GapMetric {
                    let cycle_time_secs = g.closed_at.map(|c| c - g.created_at);
                    let files_touched = g.closed_pr.map(files_for_pr).unwrap_or_default();
                    scaffold_holes::GapMetric {
                        id: g.id.clone(),
                        cycle_time_secs,
                        files_touched,
                    }
                };

                let scaffold_leaves: Vec<_> = all_closed
                    .iter()
                    .filter(|g| g.domain == domain && g.depends_on.contains(&gap_id))
                    .map(to_metric)
                    .collect();
                let open_ended: Vec<_> = all_closed
                    .iter()
                    .filter(|g| {
                        g.domain == domain
                            && !g.depends_on.contains(&gap_id)
                            && (g.depends_on.is_empty() || g.depends_on == "[]")
                    })
                    .map(to_metric)
                    .collect();

                let report =
                    scaffold_holes::compare_scaffold_vs_open_ended(&scaffold_leaves, &open_ended);

                if as_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "parent": gap_id,
                            "scaffold_leaf_count": report.scaffold_leaf_count,
                            "open_ended_count": report.open_ended_count,
                            "scaffold_leaf_mean_cycle_secs": report.scaffold_leaf_mean_cycle_secs,
                            "open_ended_mean_cycle_secs": report.open_ended_mean_cycle_secs,
                            "scaffold_leaf_collision_rate": report.scaffold_leaf_collision_rate,
                            "open_ended_collision_rate": report.open_ended_collision_rate,
                        }))
                        .unwrap_or_default()
                    );
                } else {
                    println!("--- scaffold-and-holes metrics for {gap_id} (domain {domain}) ---");
                    println!(
                        "scaffold leaves: {} shipped, mean cycle {:?}s, collision rate {:.2}",
                        report.scaffold_leaf_count,
                        report.scaffold_leaf_mean_cycle_secs,
                        report.scaffold_leaf_collision_rate
                    );
                    println!(
                        "open-ended:      {} shipped, mean cycle {:?}s, collision rate {:.2}",
                        report.open_ended_count,
                        report.open_ended_mean_cycle_secs,
                        report.open_ended_collision_rate
                    );
                }
                return Ok(());
            }

            let holes = match scaffold_holes::find_todo_holes_in_dir(&scan_dir) {
                Ok(h) => h,
                Err(e) => {
                    eprintln!(
                        "chump gap scaffold-holes: failed to scan {}: {e:#}",
                        scan_dir.display()
                    );
                    std::process::exit(1);
                }
            };

            if do_apply {
                // One leaf gap per hole: tiny, disjoint, mechanically
                // verifiable ("fill this hole, make this test pass").
                // Filing (not just printing) is what turns the scaffold
                // PR into N pickable leaf gaps instead of one open-ended
                // gap the fleet has to interpret.
                let domain = store
                    .get(&gap_id)
                    .ok()
                    .flatten()
                    .map(|g| g.domain)
                    .unwrap_or_else(|| gap_id.split('-').next().unwrap_or("EFFECTIVE").to_string());
                let session_id = crate::ambient_stream::env_session_id()
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                let mut filed_ids: Vec<String> = Vec::new();
                for h in &holes {
                    let (title, ac) = scaffold_holes::hole_to_gap_spec(h, &gap_id);
                    match store.reserve_verified(&domain, &title, "P2", "xs", &session_id) {
                        Ok(new_id) => {
                            let ac_json =
                                serde_json::to_string(&vec![ac]).unwrap_or_else(|_| "[]".into());
                            let _ = store.set_fields(
                                &new_id,
                                gap_store::GapFieldUpdate {
                                    acceptance_criteria: Some(ac_json),
                                    depends_on: Some(
                                        serde_json::to_string(&vec![gap_id.clone()])
                                            .unwrap_or_else(|_| "[]".into()),
                                    ),
                                    notes: Some(format!(
                                        "scaffold-and-holes leaf: {}:{} (parent {})",
                                        h.file.display(),
                                        h.line,
                                        gap_id
                                    )),
                                    ..Default::default()
                                },
                            );
                            filed_ids.push(new_id);
                        }
                        Err(e) => {
                            eprintln!(
                                    "chump gap scaffold-holes: failed to reserve leaf gap for {}:{}: {e:#}",
                                    h.file.display(),
                                    h.line
                                );
                        }
                    }
                }
                if as_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "parent": gap_id,
                            "filed": filed_ids,
                        }))
                        .unwrap_or_default()
                    );
                } else {
                    println!(
                        "--- filed {} leaf gap(s) for {} ---",
                        filed_ids.len(),
                        gap_id
                    );
                    for id in &filed_ids {
                        println!("{id}");
                    }
                }
                return Ok(());
            }

            if as_json {
                let specs: Vec<serde_json::Value> = holes
                    .iter()
                    .map(|h| {
                        let (title, ac) = scaffold_holes::hole_to_gap_spec(h, &gap_id);
                        serde_json::json!({
                            "file": h.file.display().to_string(),
                            "line": h.line,
                            "function": h.function,
                            "nearest_test": h.nearest_test,
                            "title": title,
                            "acceptance_criteria": ac,
                        })
                    })
                    .collect();
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "parent": gap_id,
                        "holes": specs,
                    }))
                    .unwrap_or_default()
                );
            } else if holes.is_empty() {
                println!(
                    "chump gap scaffold-holes: no todo!() holes found under {}",
                    scan_dir.display()
                );
            } else {
                for h in &holes {
                    let (title, _ac) = scaffold_holes::hole_to_gap_spec(h, &gap_id);
                    println!("{title}");
                }
                println!(
                    "--- {} hole(s) found under {} ---",
                    holes.len(),
                    scan_dir.display()
                );
            }
            return Ok(());
        }
        "dep-clean" => {
            let do_apply = args.iter().any(|a| a == "--apply");
            let as_json = json_out || args.iter().any(|a| a == "--json");
            let do_dry_run = !do_apply;

            let all_open = match store.list(Some("open")) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap dep-clean: failed to list open gaps: {e:#}");
                    std::process::exit(1);
                }
            };

            // Build a lookup: gap_id -> status
            let mut status_map: std::collections::HashMap<&str, &str> =
                std::collections::HashMap::new();
            for g in &all_open {
                status_map.insert(g.id.as_str(), "open");
            }
            let all_done = match store.list(Some("done")) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap dep-clean: failed to list done gaps: {e:#}");
                    std::process::exit(1);
                }
            };
            for g in &all_done {
                status_map.insert(g.id.as_str(), "done");
            }

            // Parse depends_on (stored as JSON array like ["X-1","X-2"])
            let parse_deps = |s: &str| -> Vec<String> {
                if s.trim().is_empty() {
                    return Vec::new();
                }
                serde_json::from_str::<Vec<String>>(s).unwrap_or_default()
            };

            let mut results: Vec<serde_json::Value> = Vec::new();
            let mut found_any = false;

            for g in &all_open {
                let deps = parse_deps(&g.depends_on);
                if deps.is_empty() {
                    continue;
                }
                let stale: Vec<String> = deps
                    .iter()
                    .filter(|d| status_map.get(d.as_str()).copied() == Some("done"))
                    .cloned()
                    .collect();
                let clean: Vec<String> = deps
                    .iter()
                    .filter(|d| {
                        let s = status_map.get(d.as_str()).copied();
                        s != Some("done")
                    })
                    .cloned()
                    .collect();

                if stale.is_empty() {
                    if as_json {
                        results.push(serde_json::json!({
                            "gap_id": g.id,
                            "stale_deps": [],
                            "action": "skipped"
                        }));
                    }
                    continue;
                }

                found_any = true;

                if do_apply {
                    // Strip stale deps: keep only clean ones
                    let new_deps = serde_json::to_string(&clean).unwrap_or_else(|_| "[]".into());
                    let update = gap_store::GapFieldUpdate {
                        depends_on: Some(new_deps),
                        ..Default::default()
                    };
                    if let Err(e) = store.set_fields(&g.id, update) {
                        eprintln!("chump gap dep-clean: failed to update {}: {e:#}", g.id);
                        std::process::exit(1);
                    }
                    // Emit ambient event
                    let lock_dir = repo_root.join(".chump-locks");
                    let _ = std::fs::create_dir_all(&lock_dir);
                    let ambient_path = if let Ok(p) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
                        std::path::PathBuf::from(p)
                    } else {
                        lock_dir.join("ambient.jsonl")
                    };
                    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
                    let evt = serde_json::json!({
                        "ts": ts,
                        "kind": "dep_cleaned",
                        "gap_id": g.id,
                        "stripped_deps": stale,
                    });
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&ambient_path)
                    {
                        use std::io::Write as _;
                        let _ = writeln!(f, "{}", evt);
                    }

                    if as_json {
                        results.push(serde_json::json!({
                            "gap_id": g.id,
                            "stale_deps": stale,
                            "action": "stripped"
                        }));
                    } else {
                        println!(
                            "{} depends_on [{}] — stripped {}",
                            g.id,
                            stale.join(", "),
                            clean.join(", ")
                        );
                    }
                } else {
                    // Dry-run mode
                    if as_json {
                        results.push(serde_json::json!({
                            "gap_id": g.id,
                            "stale_deps": stale,
                            "action": "skipped"
                        }));
                    } else {
                        for sd in &stale {
                            println!("{} depends_on {} (done) — will strip", g.id, sd);
                        }
                    }
                }
            }

            if as_json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&results).unwrap_or_default()
                );
            }

            if found_any && do_dry_run {
                eprintln!(
                    "dep-clean: found stale depends_on entries (dry-run; pass --apply to strip)"
                );
                std::process::exit(1);
            }

            if !found_any && !as_json {
                println!("No stale depends_on entries found — all clean.");
            }

            return Ok(());
        }
        // INFRA-635: gap rebalance — P0 budget enforcement + pillar floor check.
        // Reads state.db, identifies violations, suggests or applies corrections.
        "rebalance" => {
            let apply = args.iter().any(|a| a == "--apply");
            let as_json = args.iter().any(|a| a == "--json");

            tracing::info!(apply = apply, "gap-rebalance invoked");

            let all_gaps = match store.list(None) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap rebalance: {e:#}");
                    std::process::exit(1);
                }
            };

            let open_gaps: Vec<&gap_store::GapRow> =
                all_gaps.iter().filter(|g| g.status == "open").collect();

            // ── P0 budget check (CLAUDE.md: ≤ 5 P0s) ────────────────────────
            let p0_budget: usize = 5;
            let mut p0_gaps: Vec<&gap_store::GapRow> = open_gaps
                .iter()
                .filter(|g| g.priority == "P0")
                .copied()
                .collect();
            // Sort oldest first (by opened_date, then id)
            p0_gaps.sort_by(|a, b| a.opened_date.cmp(&b.opened_date).then(a.id.cmp(&b.id)));

            let mut actions: Vec<String> = Vec::new();
            let mut applied: Vec<String> = Vec::new();

            if p0_gaps.len() > p0_budget {
                let excess = p0_gaps.len() - p0_budget;
                let demote_candidates = &p0_gaps[..excess];
                for g in demote_candidates {
                    let rationale = format!(
                        "auto-demoted P0→P1: P0 budget exceeded by {} (max {}), oldest stale P0",
                        excess, p0_budget
                    );
                    actions.push(format!("DEMOTE {} P0→P1  reason: {}", g.id, rationale));
                    if apply {
                        match store.set_fields(
                            &g.id,
                            gap_store::GapFieldUpdate {
                                priority: Some("P1".to_string()),
                                notes: Some(rationale.clone()),
                                ..Default::default()
                            },
                        ) {
                            Ok(_) => applied.push(g.id.clone()),
                            Err(e) => eprintln!("failed to demote {}: {e}", g.id),
                        }
                    }
                }
            }

            // ── Pillar floor check (same logic as pillar-balance) ─────────
            let pickable: Vec<&gap_store::GapRow> = open_gaps
                .iter()
                .filter(|g| {
                    matches!(g.priority.as_str(), "P0" | "P1")
                        && matches!(g.effort.as_str(), "xs" | "s" | "m")
                })
                .copied()
                .collect();

            let total = pickable.len();
            let pillars = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"];
            let mut pillar_counts: std::collections::HashMap<&str, Vec<String>> =
                pillars.iter().map(|p| (*p, Vec::new())).collect();

            for g in &pickable {
                let title_up = g.title.to_uppercase();
                let mut assigned = false;
                for p in &pillars {
                    if title_up.contains(p) {
                        pillar_counts.entry(p).or_default().push(g.id.clone());
                        assigned = true;
                        break;
                    }
                }
                if !assigned {
                    // no-op — OTHER bucket
                }
            }

            // Flag under-floor pillars
            for p in &pillars {
                let n = pillar_counts.get(p).map(|v| v.len()).unwrap_or(0);
                if n < 2 {
                    actions.push(format!(
                            "FILE 1-2 {p} gaps  reason: only {n} pickable (floor=2, CLAUDE.md §pillar-floor)"
                        ));
                }
            }
            // Flag dominant pillars (> 50%)
            if total > 0 {
                for p in &pillars {
                    let n = pillar_counts.get(p).map(|v| v.len()).unwrap_or(0);
                    if n * 2 > total {
                        // Find oldest P1 to suggest demoting to P2
                        let ids = pillar_counts.get(p).cloned().unwrap_or_default();
                        let suggest_demote = ids.first().cloned().unwrap_or_default();
                        actions.push(format!(
                                "DEMOTE {suggest_demote} P1→P2  reason: {p} dominates ({n}/{total} >{:.0}%)",
                                n as f64 / total as f64 * 100.0
                            ));
                        if apply && !suggest_demote.is_empty() {
                            let rationale = format!(
                                "auto-demoted P1→P2: {} dominates at {}/{} pickable",
                                p, n, total
                            );
                            match store.set_fields(
                                &suggest_demote,
                                gap_store::GapFieldUpdate {
                                    priority: Some("P2".to_string()),
                                    notes: Some(rationale),
                                    ..Default::default()
                                },
                            ) {
                                Ok(_) => applied.push(suggest_demote.clone()),
                                Err(e) => eprintln!("failed to demote {suggest_demote}: {e}"),
                            }
                        }
                    }
                }
            }

            // ── Output ────────────────────────────────────────────────────
            if as_json {
                let out = serde_json::json!({
                    "p0_count": p0_gaps.len(),
                    "p0_budget": p0_budget,
                    "total_pickable": total,
                    "actions": actions,
                    "applied": applied,
                    "clean": actions.is_empty(),
                });
                println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
            } else {
                println!(
                    "Gap rebalance: {} open gaps  ({} pickable P0/P1 xs/s/m)  P0={}/{}",
                    open_gaps.len(),
                    total,
                    p0_gaps.len(),
                    p0_budget
                );
                if actions.is_empty() {
                    println!(
                        "\n✓ Registry clean — P0 budget OK, all pillars ≥ 2 pickable, none > 50%."
                    );
                } else {
                    println!("\nSuggested actions:");
                    for a in &actions {
                        println!("  • {a}");
                    }
                    if apply {
                        if applied.is_empty() {
                            println!("\nNo changes applied.");
                        } else {
                            println!("\nApplied: {}", applied.join(", "));
                        }
                    } else {
                        println!("\nRun with --apply to execute.");
                    }
                }
            }

            if !actions.is_empty() && !apply {
                std::process::exit(1);
            }
            return Ok(());
        }
        // INFRA-604: pillar balance report — inventory pickable gaps per pillar,
        // flag imbalance, optionally suggest or apply priority adjustments.
        "pillar-balance" => {
            let as_json = args.iter().any(|a| a == "--json");
            let suggest = args.iter().any(|a| a == "--suggest");
            let apply = args.iter().any(|a| a == "--apply");

            tracing::info!(apply = apply, suggest = suggest, "pillar-balance invoked");

            let all_gaps = match store.list(Some("open")) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap pillar-balance: {e:#}");
                    std::process::exit(1);
                }
            };

            // Pickable = P0|P1, xs|s|m effort
            let pickable: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| {
                    matches!(g.priority.as_str(), "P0" | "P1")
                        && matches!(g.effort.as_str(), "xs" | "s" | "m")
                })
                .collect();

            let total = pickable.len();

            // Classify each gap by pillar using title keyword (plus R&D inventory per CREDIBLE-238).
            let pillars = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"];
            let mut counts: std::collections::HashMap<&str, Vec<String>> =
                pillars.iter().map(|p| (*p, Vec::new())).collect();
            let mut rnd_gaps: Vec<String> = Vec::new();
            let mut other: Vec<String> = Vec::new();

            for g in &pickable {
                let title_up = g.title.to_uppercase();
                if g.domain.eq_ignore_ascii_case("RND")
                    || g.domain.eq_ignore_ascii_case("R&D")
                    || g.id.starts_with("RND-")
                    || title_up.contains("R&D")
                    || title_up.starts_with("RND:")
                {
                    rnd_gaps.push(g.id.clone());
                }
                let mut assigned = false;
                for p in &pillars {
                    if title_up.contains(p) {
                        counts.entry(p).or_default().push(g.id.clone());
                        assigned = true;
                        break;
                    }
                }
                if !assigned {
                    other.push(g.id.clone());
                }
            }

            let mut warnings: Vec<String> = Vec::new();
            for p in &pillars {
                let n = counts.get(p).map(|v| v.len()).unwrap_or(0);
                if n < 2 {
                    warnings.push(format!("UNDER: {p} has only {n} pickable (floor=2)"));
                }
                if total > 0 && n * 2 > total {
                    warnings.push(format!(
                        "OVER: {p} is {n}/{total} (>50%) — demote P2 excess"
                    ));
                }
            }

            // --suggest/--apply: promote oldest P2 gap for under-filled pillars.
            let mut suggestions: Vec<(String, String, String)> = Vec::new(); // (gap_id, old_prio, cmd)
            if suggest || apply {
                let all_open = store.list(Some("open")).unwrap_or_default();
                for p in &pillars {
                    let n = counts.get(p).map(|v| v.len()).unwrap_or(0);
                    if n < 2 {
                        // Find oldest P2 xs/s/m gap with this pillar keyword.
                        let candidate = all_open.iter().find(|g| {
                            g.priority == "P2"
                                && matches!(g.effort.as_str(), "xs" | "s" | "m")
                                && g.title.to_uppercase().contains(p)
                        });
                        if let Some(c) = candidate {
                            suggestions.push((
                                c.id.clone(),
                                "P2".to_string(),
                                format!("chump gap set {} --priority P1  # refill {}", c.id, p),
                            ));
                            if apply {
                                let _ = store.set_fields(
                                    &c.id,
                                    gap_store::GapFieldUpdate {
                                        priority: Some("P1".to_string()),
                                        ..Default::default()
                                    },
                                );
                            }
                        }
                    }
                }
                if !as_json {
                    for (id, old, cmd) in &suggestions {
                        println!(
                            "  {} {id} {old}→P1: {cmd}",
                            if apply { "APPLIED" } else { "SUGGEST" },
                        );
                    }
                }
            }

            let suggestions_ids: Vec<String> =
                suggestions.iter().map(|(id, _, _)| id.clone()).collect();

            if as_json {
                let mut counts_json: std::collections::HashMap<&str, usize> =
                    pillars.iter().map(|p| (*p, counts[p].len())).collect();
                counts_json.insert("R&D", rnd_gaps.len());
                println!(
                    "{}",
                    serde_json::json!({
                        "total_pickable": total,
                        "pillars": counts_json,
                        "rnd": rnd_gaps.len(),
                        "other": other.len(),
                        "warnings": warnings,
                        "suggestions": suggestions_ids,
                    })
                );
            } else {
                println!("[pillar-balance] pickable={total}");
                for p in &pillars {
                    let n = counts[p].len();
                    println!("  {p}: {n}");
                }
                println!("  R&D: {}", rnd_gaps.len());
                println!("  OTHER: {}", other.len());
                if warnings.is_empty() {
                    println!("✓ Balance OK");
                } else {
                    for w in &warnings {
                        println!("  WARN: {w}");
                    }
                }
            }

            if !warnings.is_empty() {
                std::process::exit(1);
            }
            return Ok(());
        }
        // INFRA-636: import gaps from a markdown spec file.
        // Parses headings matching `### REQ-NNN — <title>` and subsections
        // **Priority.** / **What we need.** / **Acceptance.**
        "import-spec" => {
            let path_arg = args.get(3).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap import-spec <path> [--apply] [--dry-run] [--json]");
                std::process::exit(2);
            });
            let apply = args.iter().any(|a| a == "--apply");
            let dry_run = args.iter().any(|a| a == "--dry-run") || !apply;
            let spec_path = std::path::Path::new(&path_arg);
            let content = match std::fs::read_to_string(spec_path) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("import-spec: cannot read {path_arg}: {e}");
                    std::process::exit(1);
                }
            };

            // Parse the spec: collect entries keyed by heading.
            struct SpecEntry {
                req_id: String,
                title: String,
                priority: String,
                description: String,
                acceptance: String,
            }

            fn infer_pillar(title: &str) -> &'static str {
                let t = title.to_uppercase();
                if t.contains("CREDIBLE")
                    || t.contains("OBSERV")
                    || t.contains("METRIC")
                    || t.contains("MEASURE")
                {
                    "CREDIBLE"
                } else if t.contains("EFFECTIVE")
                    || t.contains("USER")
                    || t.contains("DASHBOARD")
                    || t.contains("UX")
                {
                    "EFFECTIVE"
                } else if t.contains("RESILIENT")
                    || t.contains("RECOVER")
                    || t.contains("FAILOVER")
                    || t.contains("RETRY")
                {
                    "RESILIENT"
                } else if t.contains("ZERO-WASTE")
                    || t.contains("WASTE")
                    || t.contains("PRUNE")
                    || t.contains("COST")
                {
                    "ZERO-WASTE"
                } else {
                    "MISSION"
                }
            }

            fn map_priority(raw: &str) -> String {
                let r = raw.trim().to_uppercase();
                if r.starts_with("P0") || r == "CRITICAL" {
                    return "P0".into();
                }
                if r.starts_with("P1") || r == "HIGH" {
                    return "P1".into();
                }
                if r.starts_with("P2") || r == "MEDIUM" {
                    return "P2".into();
                }
                if r.starts_with("P3") || r == "LOW" {
                    return "P3".into();
                }
                "P2".into()
            }

            let mut entries: Vec<SpecEntry> = Vec::new();
            let mut current: Option<SpecEntry> = None;
            let mut in_section: Option<&str> = None;
            let mut buf = String::new();

            for line in content.lines() {
                // Detect `### REQ-NNN — title` headings
                if let Some(rest) = line.strip_prefix("### ") {
                    // Flush previous entry
                    if let Some(ref mut e) = current {
                        match in_section {
                            Some("desc") => e.description = buf.trim().to_string(),
                            Some("ac") => e.acceptance = buf.trim().to_string(),
                            _ => {}
                        }
                    }
                    if let Some(e) = current.take() {
                        entries.push(e);
                    }
                    buf.clear();
                    in_section = None;

                    // Parse "REQ-NNN — title" or plain title
                    let (req_id, title) = if let Some(idx) = rest.find(" \u{2014} ") {
                        (rest[..idx].to_string(), rest[idx + 4..].to_string())
                    } else if let Some(idx) = rest.find(" -- ") {
                        (rest[..idx].to_string(), rest[idx + 4..].to_string())
                    } else {
                        (String::new(), rest.to_string())
                    };
                    current = Some(SpecEntry {
                        req_id,
                        title,
                        priority: "P2".into(),
                        description: String::new(),
                        acceptance: String::new(),
                    });
                } else if line.starts_with("**Priority.**") || line.starts_with("**Priority**: ") {
                    if let Some(ref mut e) = current {
                        // Flush previous section
                        match in_section {
                            Some("desc") => e.description = buf.trim().to_string(),
                            Some("ac") => e.acceptance = buf.trim().to_string(),
                            _ => {}
                        }
                        buf.clear();
                        in_section = Some("priority");
                        // Priority value may be inline
                        let raw = line
                            .trim_start_matches("**Priority.**")
                            .trim_start_matches("**Priority**:")
                            .trim();
                        if !raw.is_empty() {
                            e.priority = map_priority(raw);
                            in_section = None;
                        }
                    }
                } else if line.starts_with("**What we need.**")
                    || line.starts_with("**Description.**")
                {
                    if let Some(ref mut e) = current {
                        match in_section {
                            Some("desc") => e.description = buf.trim().to_string(),
                            Some("ac") => e.acceptance = buf.trim().to_string(),
                            _ => {}
                        }
                        buf.clear();
                        in_section = Some("desc");
                        let rest = line
                            .trim_start_matches("**What we need.**")
                            .trim_start_matches("**Description.**")
                            .trim();
                        if !rest.is_empty() {
                            buf.push_str(rest);
                            buf.push('\n');
                        }
                    }
                } else if line.starts_with("**Acceptance.**") || line.starts_with("**AC.**") {
                    if let Some(ref mut e) = current {
                        match in_section {
                            Some("desc") => e.description = buf.trim().to_string(),
                            Some("ac") => e.acceptance = buf.trim().to_string(),
                            _ => {}
                        }
                        buf.clear();
                        in_section = Some("ac");
                        let rest = line
                            .trim_start_matches("**Acceptance.**")
                            .trim_start_matches("**AC.**")
                            .trim();
                        if !rest.is_empty() {
                            buf.push_str(rest);
                            buf.push('\n');
                        }
                    }
                } else if in_section.is_some() {
                    // Accumulate section content; stop at blank separator or next heading
                    if current.is_some() {
                        if in_section == Some("priority") && !line.trim().is_empty() {
                            if let Some(ref mut e) = current {
                                e.priority = map_priority(line.trim());
                            }
                            in_section = None;
                        } else {
                            buf.push_str(line);
                            buf.push('\n');
                        }
                    }
                }
            }
            // Flush last entry
            if let Some(ref mut e) = current {
                match in_section {
                    Some("desc") => e.description = buf.trim().to_string(),
                    Some("ac") => e.acceptance = buf.trim().to_string(),
                    _ => {}
                }
            }
            if let Some(e) = current.take() {
                entries.push(e);
            }

            if entries.is_empty() {
                eprintln!("import-spec: no gaps found in {path_arg} (expected '### REQ-NNN — title' headings)");
                std::process::exit(1);
            }

            tracing::info!(
                path = path_arg,
                count = entries.len(),
                apply = apply,
                "import-spec"
            );

            let mut filed: Vec<String> = Vec::new();
            let mut skipped: Vec<String> = Vec::new();

            for e in &entries {
                let pillar = infer_pillar(&e.title);
                let full_title = if !e.req_id.is_empty() {
                    format!("{}: {} — {}", pillar, e.req_id, e.title)
                } else {
                    format!("{}: {}", pillar, e.title)
                };
                let ac_json = if e.acceptance.is_empty() {
                    "[]".to_string()
                } else {
                    let parts: Vec<&str> = e
                        .acceptance
                        .lines()
                        .map(str::trim)
                        .filter(|l| !l.is_empty())
                        .collect();
                    serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
                };

                if dry_run {
                    if json_out {
                        let obj = serde_json::json!({
                            "req_id": e.req_id,
                            "title": full_title,
                            "priority": e.priority,
                            "domain": "INFRA",
                            "description": e.description,
                            "acceptance_criteria_preview": e.acceptance,
                            "dry_run": true,
                        });
                        println!("{}", serde_json::to_string_pretty(&obj).unwrap_or_default());
                    } else {
                        println!("[dry-run] {} | INFRA | {}", e.priority, full_title);
                        if !e.description.is_empty() {
                            println!(
                                "          desc: {}",
                                e.description.lines().next().unwrap_or("")
                            );
                        }
                        if !e.acceptance.is_empty() {
                            println!(
                                "          ac:   {}",
                                e.acceptance.lines().next().unwrap_or("")
                            );
                        }
                    }
                    skipped.push(full_title.clone());
                } else {
                    // INFRA-8043: harvest-check filings carry no outcome, so P0/P1 files at P2.
                    match store.reserve(
                        "INFRA",
                        &full_title,
                        gap_store::priority_without_outcome(&e.priority),
                        "m",
                    ) {
                        Ok(id) => {
                            let _ = store.set_fields(
                                &id,
                                gap_store::GapFieldUpdate {
                                    description: if e.description.is_empty() {
                                        None
                                    } else {
                                        Some(e.description.clone())
                                    },
                                    acceptance_criteria: if ac_json == "[]" {
                                        None
                                    } else {
                                        Some(ac_json)
                                    },
                                    ..Default::default()
                                },
                            );
                            if json_out {
                                let obj = serde_json::json!({"id": id, "title": full_title, "priority": e.priority});
                                println!(
                                    "{}",
                                    serde_json::to_string_pretty(&obj).unwrap_or_default()
                                );
                            } else {
                                println!("filed {} | {} | {}", id, e.priority, full_title);
                            }
                            filed.push(id);
                        }
                        Err(err) => {
                            eprintln!("import-spec: failed to reserve '{}': {err:#}", full_title);
                            skipped.push(full_title.clone());
                        }
                    }
                }
            }

            if !dry_run {
                tracing::info!(
                    filed = filed.len(),
                    skipped = skipped.len(),
                    "import-spec complete"
                );
                eprintln!(
                    "import-spec: filed {} gaps, skipped {}",
                    filed.len(),
                    skipped.len()
                );
                // Run rebalance after bulk import per AC (pillar floor + P0 budget).
                if !filed.is_empty() {
                    let _ = std::process::Command::new(
                        std::env::current_exe().unwrap_or_else(|_| "chump".into()),
                    )
                    .args(["gap", "rebalance"])
                    .status();
                }
            }
            return Ok(());
        }
        // INFRA-935: gap consolidate — detect near-duplicate gap titles.
        // INFRA-1435 (2026-05-16): added --apply mode that mechanically
        // archives the higher-ID dup, rewrites depends_on backlinks,
        // writes an audit row, and emits ambient kind=gap_dup_archived.
        //
        // Usage:
        //   chump gap consolidate [--threshold N] [--json]
        //     --threshold N  similarity threshold 0-100 (default 80 advisory,
        //                    90 when --apply is set)
        //     --json         output pairs as JSON array
        //
        //   chump gap consolidate --apply --reason "<text>" [--threshold N]
        //                                                   [--json]
        //     --apply        mutate: archive higher-ID dups, rewrite
        //                    depends_on, write audit + ambient events.
        //                    Refuses if either gap has an active lease.
        //     --reason TEXT  required with --apply (audit-trail message)
        "consolidate" => {
            let apply = args.iter().any(|a| a == "--apply");
            let reason = flag("--reason").unwrap_or_default();
            if apply && reason.trim().is_empty() {
                eprintln!(
                    "chump gap consolidate --apply: requires --reason \"<text>\" \
                         for the audit trail."
                );
                std::process::exit(2);
            }
            let default_threshold = if apply { 90 } else { 80 };
            let threshold: u32 = args
                .iter()
                .position(|a| a == "--threshold")
                .and_then(|i| args.get(i + 1))
                .and_then(|s| s.parse().ok())
                .unwrap_or(default_threshold);
            let as_json = args.iter().any(|a| a == "--json");

            let all_gaps = match store.list(Some("open")) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap consolidate: {e:#}");
                    std::process::exit(1);
                }
            };

            /// Token-overlap similarity (0-100) between two titles.
            fn title_similarity(a: &str, b: &str) -> u32 {
                fn tokens(s: &str) -> std::collections::HashSet<String> {
                    s.to_lowercase()
                        .split(|c: char| !c.is_alphanumeric())
                        .filter(|t| t.len() >= 3)
                        .map(String::from)
                        .collect()
                }
                let ta = tokens(a);
                let tb = tokens(b);
                if ta.is_empty() || tb.is_empty() {
                    return 0;
                }
                let intersection = ta.intersection(&tb).count();
                let union = ta.union(&tb).count();
                ((intersection as f64 / union as f64) * 100.0) as u32
            }

            let mut pairs: Vec<(String, String, u32)> = Vec::new();
            for i in 0..all_gaps.len() {
                for j in (i + 1)..all_gaps.len() {
                    let sim = title_similarity(&all_gaps[i].title, &all_gaps[j].title);
                    if sim >= threshold {
                        pairs.push((all_gaps[i].id.clone(), all_gaps[j].id.clone(), sim));
                    }
                }
            }
            pairs.sort_by_key(|p| std::cmp::Reverse(p.2));

            // INFRA-1435: --apply path. Mutates state.db; defensive
            // against active leases.
            if apply {
                // Read all active leases once; collect referenced gap IDs.
                let lease_dir = repo_root.join(".chump-locks");
                let mut leased_gaps: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                if let Ok(entries) = std::fs::read_dir(&lease_dir) {
                    for e in entries.flatten() {
                        let p = e.path();
                        if p.extension().and_then(|s| s.to_str()) != Some("json") {
                            continue;
                        }
                        if let Ok(text) = std::fs::read_to_string(&p) {
                            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                                if let Some(g) = v.get("gap").and_then(|g| g.as_str()) {
                                    leased_gaps.insert(g.to_string());
                                }
                            }
                        }
                    }
                }

                let operator = std::env::var("USER").unwrap_or_default();
                let ts = chrono::Utc::now().timestamp();
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let mut applied: Vec<(String, String, u32, usize)> = Vec::new(); // (kept, archived, sim, rewrites)
                let mut skipped_leased: Vec<(String, String, String)> = Vec::new(); // (a, b, why)

                for (a, b, sim) in &pairs {
                    // Deterministic kept/archived: keep the LOWER id by
                    // lexicographic order — older IDs have more backlinks
                    // and are more likely to be cited externally.
                    let (kept, archived) = if a < b {
                        (a.clone(), b.clone())
                    } else {
                        (b.clone(), a.clone())
                    };
                    if leased_gaps.contains(&kept) || leased_gaps.contains(&archived) {
                        skipped_leased.push((
                            kept.clone(),
                            archived.clone(),
                            "active lease — refuse to mutate".to_string(),
                        ));
                        continue;
                    }

                    // Rewrite depends_on across all open gaps that point
                    // at the archived ID.
                    let mut rewrites = 0usize;
                    if let Ok(open_gaps) = store.list(Some("open")) {
                        for g in &open_gaps {
                            if g.depends_on.is_empty() || g.id == archived {
                                continue;
                            }
                            let deps = gap_store::parse_json_ac_list(&g.depends_on);
                            if !deps.iter().any(|d| d == &archived) {
                                continue;
                            }
                            let new_deps: Vec<String> = deps
                                .into_iter()
                                .map(|d| if d == archived { kept.clone() } else { d })
                                .collect::<Vec<_>>()
                                .into_iter()
                                .collect::<std::collections::BTreeSet<_>>()
                                .into_iter()
                                .collect();
                            let new_deps_json =
                                serde_json::to_string(&new_deps).unwrap_or_default();
                            let upd = gap_store::GapFieldUpdate {
                                depends_on: Some(new_deps_json),
                                ..Default::default()
                            };
                            if store.set_fields(&g.id, upd).is_ok() {
                                rewrites += 1;
                            }
                        }
                    }

                    // Archive the higher ID. Bypass closed_pr guard
                    // (this is a dup-archive, not a real ship).
                    let archive_notes = format!(
                        "INFRA-1435 dup-archive (similarity {sim}%): keeping {kept}; \
                             reason: {reason}"
                    );
                    let upd = gap_store::GapFieldUpdate {
                        status: Some("done".to_string()),
                        notes: Some(archive_notes),
                        ..Default::default()
                    };
                    // Temporarily set the bypass env so set_fields' INFRA-402
                    // guard accepts the status flip without a closed_pr.
                    // SAFETY: single-threaded CLI; restored before next
                    // iteration. Only main() touches env at this layer.
                    unsafe {
                        std::env::set_var("CHUMP_BYPASS_CLOSED_PR_GUARD", "1");
                    }
                    let archive_result = store.set_fields(&archived, upd);
                    unsafe {
                        std::env::remove_var("CHUMP_BYPASS_CLOSED_PR_GUARD");
                    }
                    if let Err(e) = archive_result {
                        eprintln!(
                                "[consolidate --apply] WARN: archive of {archived} failed: {e:#} — skipping audit/ambient for this pair"
                            );
                        continue;
                    }

                    // Audit row (typed API; creates table on first call).
                    if let Err(e) = store
                        .record_dup_archive(&kept, &archived, *sim, rewrites, &reason, &operator)
                    {
                        eprintln!(
                                "[consolidate --apply] WARN: audit-row write failed for {archived}: {e:#}"
                            );
                    }

                    // Ambient event.
                    if let Some(parent) = ambient_path.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        use std::io::Write;
                        let safe_reason = reason.replace(['"', '\\'], "");
                        let _ = writeln!(
                            f,
                            r#"{{"ts":{ts},"kind":"gap_dup_archived","kept_id":"{kept}","archived_id":"{archived}","similarity_pct":{sim},"depends_on_rewrites":{rewrites},"reason":"{safe_reason}"}}"#
                        );
                    }

                    applied.push((kept, archived, *sim, rewrites));
                }

                if as_json {
                    let arr: Vec<String> = applied
                            .iter()
                            .map(|(k, a, s, r)| {
                                format!(
                                    r#"{{"kept_id":"{k}","archived_id":"{a}","similarity_pct":{s},"depends_on_rewrites":{r}}}"#
                                )
                            })
                            .collect();
                    println!(
                        r#"{{"applied":[{}],"skipped_leased_count":{}}}"#,
                        arr.join(","),
                        skipped_leased.len()
                    );
                } else {
                    println!(
                        "═══ Gap Consolidate --apply (INFRA-1435) ═══ threshold={}% — \
                             {} pair(s) above threshold, {} archived, {} skipped (leased)",
                        threshold,
                        pairs.len(),
                        applied.len(),
                        skipped_leased.len()
                    );
                    for (k, a, s, r) in &applied {
                        println!(
                            "  archived {} → kept {}  (sim {}%, {} depends_on rewritten)",
                            a, k, s, r
                        );
                    }
                    for (k, a, why) in &skipped_leased {
                        println!("  SKIP  {} ↔ {}: {}", k, a, why);
                    }
                }
                return Ok(());
            }

            // Advisory mode (default).
            if as_json {
                let json_pairs: Vec<String> = pairs
                        .iter()
                        .map(|(a, b, sim)| {
                            format!(
                                r#"{{"gap_id_a":"{}","gap_id_b":"{}","similarity_pct":{},"suggested_action":"{}"}}"#,
                                a, b, sim,
                                if *sim >= 90 { "merge" } else { "review" }
                            )
                        })
                        .collect();
                println!("[{}]", json_pairs.join(","));
            } else {
                println!(
                    "═══ Gap Consolidation (INFRA-935) ═══ threshold={}% — {} open gaps scanned",
                    threshold,
                    all_gaps.len()
                );
                if pairs.is_empty() {
                    println!("  (no near-duplicate pairs found — registry clean)");
                } else {
                    println!("  {:>4}  {:>12}  {:>12}  action", "sim%", "gap_a", "gap_b");
                    println!("  ────  ────────────  ────────────  ──────");
                    for (a, b, sim) in &pairs {
                        let action = if *sim >= 90 { "merge" } else { "review" };
                        println!("  {:>3}%  {:>12}  {:>12}  {}", sim, a, b, action);
                    }
                    println!();
                    println!(
                        "  Hint: add --apply --reason \"<text>\" to mutate \
                             (archives higher ID, rewrites depends_on, audits)."
                    );
                }
            }
            return Ok(());
        }

        // FLEET-048: operator impact rating
        "rate" => {
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap rate <GAP-ID> <1-5> [--comment \"text\"] [--pr N]");
                std::process::exit(2);
            });
            let rating_str = args.get(4).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap rate <GAP-ID> <1-5> [--comment \"text\"] [--pr N]");
                std::process::exit(2);
            });
            let rating: u8 = match rating_str.trim().parse::<u8>() {
                Ok(r) if (1..=5).contains(&r) => r,
                _ => {
                    eprintln!("chump gap rate: rating must be 1-5 (got {:?})", rating_str);
                    std::process::exit(2);
                }
            };
            let comment = flag("--comment").unwrap_or_default();
            let pr_number: Option<i64> = flag("--pr").and_then(|s| s.parse::<i64>().ok());

            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
            let pr_json = pr_number
                .map(|n| n.to_string())
                .unwrap_or_else(|| "null".to_string());
            let comment_escaped = comment.replace('\\', "\\\\").replace('"', "\\\"");
            let event = format!(
                "{{\"ts\":\"{ts}\",\"kind\":\"gap_impact_rated\",\
                     \"gap_id\":\"{gap_id}\",\"rating\":{rating},\
                     \"comment\":\"{comment_escaped}\",\"pr_number\":{pr_json}}}\n"
            );
            let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
            match std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(&ambient_path)
            {
                Ok(mut f) => {
                    use std::io::Write;
                    f.write_all(event.as_bytes())
                        .unwrap_or_else(|e| eprintln!("gap rate: write failed: {e}"));
                }
                Err(e) => {
                    eprintln!("gap rate: could not open ambient log: {e}");
                    std::process::exit(1);
                }
            }
            println!("rated {} → {}/5", gap_id, rating);
            if !comment.is_empty() {
                println!("  comment: {}", comment);
            }
            return Ok(());
        }
        // EFFECTIVE-310: `chump gap strike <GAP-ID>` — failure→decompose
        // reflex counter. The worker calls this after a whole-gap failure
        // on chump-local; exit code 10 signals "threshold reached, run
        // the frontier decompose instead of retrying whole".
        "strike" => {
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap strike <GAP-ID> [--backend <name>] [--reset] [--show]");
                eprintln!();
                eprintln!("Increments the per-gap failure strike counter (default backend");
                eprintln!("chump-local). Exits 10 when count >= CHUMP_DECOMPOSE_STRIKE_THRESHOLD");
                eprintln!("(default 2) — the caller should decompose instead of retrying.");
                eprintln!("  --reset   Clear all strikes for the gap (called on clean cycles)");
                eprintln!("  --show    Print the current count without incrementing");
                std::process::exit(2);
            });
            let backend = flag("--backend").unwrap_or_else(|| "chump-local".to_string());
            let threshold: i64 = std::env::var("CHUMP_DECOMPOSE_STRIKE_THRESHOLD")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(2);
            if args.iter().any(|a| a == "--reset") {
                store.clear_strikes(&gap_id)?;
                println!("strikes cleared for {}", gap_id);
                return Ok(());
            }
            let n = if args.iter().any(|a| a == "--show") {
                store.strike_count(&gap_id, &backend)?
            } else {
                store.record_strike(&gap_id, &backend)?
            };
            println!(
                "strikes={} threshold={} gap={} backend={}",
                n, threshold, gap_id, backend
            );
            if !args.iter().any(|a| a == "--show") && n >= threshold {
                std::process::exit(10);
            }
            return Ok(());
        }
        // INFRA-3448: `chump gap route <GAP-ID>` — the discipline router.
        // Reads a stuck gap's SIZE (effort) and failure count (strikes) and
        // recommends the recovery discipline: retry | escalate-model |
        // decompose | flag-human. The OS "knows the difference" between a
        // gap that's too HARD (small/conceptual → stronger model) and one
        // that's too BIG (large → decompose) instead of EFFECTIVE-310's
        // blanket "any strike → decompose".
        "route" => {
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap route <GAP-ID> [--json]");
                eprintln!();
                eprintln!("Recommends the recovery discipline for a stuck gap from effort-size");
                eprintln!("x strikes: retry | escalate-model | decompose | flag-human. Read-only.");
                std::process::exit(2);
            });
            let row = match store.get(&gap_id)? {
                Some(r) => r,
                None => {
                    eprintln!("[route] {gap_id} — not found in state.db");
                    std::process::exit(1);
                }
            };
            let strikes = store
                .strike_count(&gap_id, "chump-local")
                .unwrap_or(0)
                .max(0) as u32;
            let ladder_len = std::env::var("CHUMP_MODEL_ESCALATION_LADDER")
                .ok()
                .map(|l| l.split(',').filter(|s| !s.trim().is_empty()).count() as u32)
                .unwrap_or(1)
                .max(1);
            let discipline = route_stuck_gap(&row.effort, strikes, ladder_len);
            if args.iter().any(|a| a == "--json") {
                println!(
                        "{{\"gap_id\":\"{}\",\"effort\":\"{}\",\"strikes\":{},\"ladder_len\":{},\"discipline\":\"{}\"}}",
                        gap_id,
                        row.effort,
                        strikes,
                        ladder_len,
                        discipline.as_str()
                    );
            } else {
                println!(
                    "[route] {gap_id} effort={} strikes={} → {}",
                    row.effort,
                    strikes,
                    discipline.as_str()
                );
                println!("        {}", discipline.guidance());
            }
            // scanner-anchor: "kind":"gap_discipline_routed"
            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
            let event = format!(
                "{{\"ts\":\"{ts}\",\"kind\":\"gap_discipline_routed\",\"gap_id\":\"{gap_id}\",\
                     \"effort\":\"{}\",\"strikes\":{strikes},\"discipline\":\"{}\"}}\n",
                row.effort,
                discipline.as_str()
            );
            let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(&ambient_path)
            {
                use std::io::Write;
                let _ = f.write_all(event.as_bytes());
            }
            return Ok(());
        }
        // INFRA-2137: `chump gap requeue <GAP-ID>` — move bisect_quarantined
        // → ready_to_ship after operator review.
        "requeue" => {
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap requeue <GAP-ID>");
                eprintln!(
                    "  Moves a bisect_quarantined gap back to ready_to_ship after operator review."
                );
                std::process::exit(2);
            });
            match store.requeue_gap(&gap_id) {
                Ok(()) => {
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    let event = format!(
                        "{{\"ts\":\"{ts}\",\"kind\":\"gap_requeued\",\
                             \"gap_id\":\"{gap_id}\",\"by\":\"operator\"}}\n"
                    );
                    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        use std::io::Write;
                        let _ = f.write_all(event.as_bytes());
                    }
                    println!("requeued {} → ready_to_ship", gap_id);
                    println!("  Run `chump gap show {}` to confirm.", gap_id);
                }
                Err(e) => {
                    eprintln!("chump gap requeue: {e:#}");
                    std::process::exit(1);
                }
            }
            return Ok(());
        }
        // INFRA-1220: operator override to clear a post-close cooldown.
        // Usage: chump gap clear-cooldown <GAP-ID> --reason "text"
        "clear-cooldown" => {
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap clear-cooldown <GAP-ID> --reason \"reason\"");
                std::process::exit(2);
            });
            let reason = flag("--reason").unwrap_or_else(|| {
                eprintln!("chump gap clear-cooldown: --reason is required (audit trail)");
                std::process::exit(2);
            });
            // Invoke the shell script so cooldown logic stays in one place.
            let script = repo_root.join("scripts/coord/gap-cooldown.sh");
            let status = std::process::Command::new("bash")
                .arg(&script)
                .arg("clear")
                .arg(&gap_id)
                .arg("--reason")
                .arg(&reason)
                .env("CHUMP_LOCK_DIR", repo_root.join(".chump-locks"))
                .status();
            match status {
                Ok(s) if s.success() => {
                    println!("cooldown cleared for {} (reason: {})", gap_id, reason);
                    // INFRA-755: emit ambient event for auditability.
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    let reason_esc = reason.replace('\\', "\\\\").replace('"', "\\\"");
                    let event = format!(
                        "{{\"ts\":\"{ts}\",\"kind\":\"gap_cooldown_cleared_cli\",\
                             \"gap_id\":\"{gap_id}\",\"reason\":\"{reason_esc}\"}}\n"
                    );
                    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        use std::io::Write;
                        let _ = f.write_all(event.as_bytes());
                    }
                }
                Ok(s) => {
                    eprintln!(
                        "gap clear-cooldown: script exited {}",
                        s.code().unwrap_or(-1)
                    );
                    std::process::exit(1);
                }
                Err(e) => {
                    eprintln!("gap clear-cooldown: failed to run script: {e}");
                    std::process::exit(1);
                }
            }
            return Ok(());
        }
        // INFRA-2053: `chump gap sync` — state.db -> YAML mirror tooling.
        // Export-only since INFRA-8193 (Phase R R4): state.db is the only
        // truth and docs/gaps/*.yaml never writes back into it.
        //   --check  : dry-run drift report; exits non-zero on drift.
        //   --push   : DB -> YAML. Writes `docs/gaps/<ID>.yaml` for
        //              every gap whose YAML diverges or is missing.
        //              Atomic tempfile + rename per file with serde_yaml
        //              round-trip validation. The export path.
        //   --pull   : RETIRED (hard error, exit 2) — pointed at
        //              `chump store reconcile` (INFRA-8222) and the
        //              insert-only `chump gap import` for empty stores.
        //
        // --dry-run pairs with --push (--check is dry-run by design).
        // --json switches output to a single newline-delimited JSON doc.
        "sync" => {
            let sync_args: Vec<String> = args.to_vec();
            let mode = match gap_store::sync::parse_sync_mode(&sync_args) {
                Ok(m) => m,
                Err(msg) => {
                    eprintln!("{msg}");
                    std::process::exit(2);
                }
            };
            let mode_check = mode == gap_store::sync::SyncMode::Check;
            let mode_push = mode == gap_store::sync::SyncMode::Push;
            let dry_run = args.iter().any(|a| a == "--dry-run");

            // --state-db override resolves to the same env var GapStore reads.
            if let Some(p) = flag("--state-db") {
                std::env::set_var("CHUMP_STATE_DB", p);
            }
            // --gaps-dir override; default `docs/gaps` under the worktree root.
            let gaps_dir_arg = flag("--gaps-dir");
            let gaps_dir = match gaps_dir_arg {
                Some(p) => {
                    let pb = std::path::PathBuf::from(&p);
                    if pb.is_absolute() {
                        pb
                    } else {
                        worktree_root.join(pb)
                    }
                }
                None => worktree_root.join("docs").join("gaps"),
            };

            // Re-open the store after potential CHUMP_STATE_DB override.
            let sync_store = match gap_store::GapStore::open(&worktree_root) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("chump gap sync: cannot open state.db: {e:#}");
                    std::process::exit(1);
                }
            };

            if mode_check {
                match gap_store::sync::sync_check(&sync_store, &gaps_dir) {
                    Ok(report) => {
                        if json_out {
                            let json_entries: Vec<serde_json::Value> = report
                                .entries
                                .iter()
                                .map(|e| {
                                    serde_json::json!({
                                        "gap_id": e.gap_id,
                                        "kind": e.kind.as_str(),
                                        "fields": e.fields,
                                    })
                                })
                                .collect();
                            let summary = serde_json::json!({
                                "mode": "check",
                                "clean": report.is_clean(),
                                "drift_count": report.entries.len(),
                                "entries": json_entries,
                            });
                            println!("{}", summary);
                        } else if report.is_clean() {
                            println!("chump gap sync --check: clean (no drift)");
                        } else {
                            println!(
                                "chump gap sync --check: {} drift entries",
                                report.entries.len()
                            );
                            for e in &report.entries {
                                if e.fields.is_empty() {
                                    println!("  {} | {}", e.gap_id, e.kind.as_str());
                                } else {
                                    println!(
                                        "  {} | {} | fields: {}",
                                        e.gap_id,
                                        e.kind.as_str(),
                                        e.fields.join(",")
                                    );
                                }
                            }
                        }
                        if !report.is_clean() {
                            std::process::exit(1);
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap sync --check: {e:#}");
                        std::process::exit(1);
                    }
                }
            }

            if mode_push {
                match gap_store::sync::sync_push(&sync_store, &gaps_dir, dry_run) {
                    Ok(report) => {
                        if json_out {
                            let summary = serde_json::json!({
                                "mode": "push",
                                "dry_run": dry_run,
                                "inserted": report.inserted,
                                "updated": report.updated,
                                "skipped": report.skipped,
                                "changed_ids": report.changed_ids,
                            });
                            println!("{}", summary);
                        } else {
                            let prefix = if dry_run { "[dry-run] " } else { "" };
                            println!(
                                "{}chump gap sync --push: {} new YAMLs, {} updated, {} unchanged",
                                prefix, report.inserted, report.updated, report.skipped
                            );
                            if !report.changed_ids.is_empty() {
                                println!("  changed: {}", report.changed_ids.join(", "));
                            }
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap sync --push: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            unreachable!("mode selection should be exhaustive after guard above");
        }
        // MISSION-041: `backfill-external-repo [--dry-run | --apply] [--owner-repo <o/r>]`
        // One-shot backfill that scans all gaps and sets skills_required with
        // external_repo:<owner/repo> tags based on title/description heuristics.
        // Default is --dry-run. --apply commits changes. Idempotent.
        "backfill-external-repo" => {
            let dry_run = !args.iter().any(|a| a == "--apply");
            let owner_repo_override = args
                .windows(2)
                .find(|w| w[0] == "--owner-repo")
                .and_then(|w| w.get(1))
                .cloned();

            if dry_run {
                println!("[backfill-external-repo] DRY RUN — use --apply to commit changes");
            }

            let all_gaps = match store.list(None) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap backfill-external-repo: {e:#}");
                    std::process::exit(1);
                }
            };

            // Heuristics (applied in order; first match wins):
            // 1. Title contains BEAST or BEAST-MODE (case-insensitive) → repairman29/BEAST-MODE
            // 2. Description contains repairman29/BEAST-MODE or BEAST-MODE (case-insensitive) → repairman29/BEAST-MODE
            // 3. Description contains literal external_repo:<owner>/<repo> → extract that
            // 4. Default: skip

            let extract_external_repo_from_gap = |gap: &gap_store::GapRow| -> Option<String> {
                // If --owner-repo override provided, apply it to all matched gaps.
                let title_uc = gap.title.to_uppercase();
                let desc_uc = gap.description.to_uppercase();

                // Heuristic 1: title has BEAST or BEAST-MODE.
                if title_uc.contains("BEAST") {
                    return Some(
                        owner_repo_override
                            .clone()
                            .unwrap_or_else(|| "repairman29/BEAST-MODE".to_string()),
                    );
                }

                // Heuristic 2: description mentions BEAST-MODE or repairman29.
                if desc_uc.contains("BEAST-MODE") || desc_uc.contains("REPAIRMAN29") {
                    return Some(
                        owner_repo_override
                            .clone()
                            .unwrap_or_else(|| "repairman29/BEAST-MODE".to_string()),
                    );
                }

                // Heuristic 3: description contains literal external_repo:<owner>/<repo>.
                // Scan the raw (un-uppercased) description for the tag.
                // Skip angle-bracket templates like external_repo:<owner>/<repo>.
                if let Some(pos) = gap.description.find("external_repo:") {
                    let rest = &gap.description[pos + "external_repo:".len()..];
                    // Extract <owner>/<repo> up to next whitespace or comma.
                    let repo_str: String = rest
                        .chars()
                        .take_while(|c| !c.is_whitespace() && *c != ',' && *c != '"')
                        .collect();
                    // Reject angle-bracket templates and empty/invalid strings.
                    if repo_str.contains('/') && !repo_str.is_empty() && !repo_str.starts_with('<')
                    {
                        return Some(owner_repo_override.clone().unwrap_or(repo_str));
                    }
                }

                None
            };

            // Build the plan: for each gap, determine the tag to apply.
            let mut plan: Vec<(String, String, bool)> = Vec::new(); // (gap_id, owner_repo, already_tagged)
            let mut already_tagged = 0usize;
            let mut unmatched = 0usize;
            let mut by_repo: std::collections::HashMap<String, usize> =
                std::collections::HashMap::new();

            for gap in &all_gaps {
                let target_repo = extract_external_repo_from_gap(gap);
                let expected_tag = target_repo.as_ref().map(|r| format!("external_repo:{r}"));

                // Check if already tagged with this specific tag.
                let already_has_tag = expected_tag
                    .as_ref()
                    .map(|tag| {
                        gap.skills_required
                            .split(',')
                            .any(|s| s.trim() == tag.as_str())
                    })
                    .unwrap_or(false);

                match target_repo {
                    Some(repo) if already_has_tag => {
                        already_tagged += 1;
                        let _ = already_has_tag; // suppress lint
                                                 // Count in by_repo for idempotency reporting.
                        *by_repo.entry(repo).or_default() += 0;
                    }
                    Some(repo) => {
                        *by_repo.entry(repo.clone()).or_default() += 1;
                        plan.push((gap.id.clone(), repo, false));
                    }
                    None => {
                        unmatched += 1;
                    }
                }
            }

            // Report plan.
            if by_repo.is_empty() && plan.is_empty() {
                println!("[backfill-external-repo] all matched gaps already tagged (already_tagged={already_tagged}, unmatched={unmatched})");
            } else {
                println!("Backfill plan:");
                let mut sorted_repos: Vec<_> = by_repo.iter().collect();
                sorted_repos.sort_by(|a, b| b.1.cmp(a.1));
                for (repo, cnt) in &sorted_repos {
                    println!("  external_repo:{repo} ← {cnt} gap(s)");
                }
                println!("  already tagged: {already_tagged}");
                println!("  unmatched (skipped): {unmatched}");
                println!("  total to tag: {}", plan.len());
            }

            if dry_run {
                println!();
                println!("[dry-run] no changes written. Re-run with --apply to commit.");
                return Ok(());
            }

            // Apply: for each gap, append external_repo tag to skills_required.
            let mut applied = 0usize;
            let mut errors = 0usize;
            for (gap_id, repo, _) in &plan {
                // Fetch current skills_required to do a CSV append.
                let current_skills = store
                    .get(gap_id)
                    .ok()
                    .flatten()
                    .map(|g| g.skills_required)
                    .unwrap_or_default();
                let tag = format!("external_repo:{repo}");
                let new_skills = if current_skills.trim().is_empty() {
                    tag.clone()
                } else {
                    format!("{},{tag}", current_skills.trim())
                };
                let update = gap_store::GapFieldUpdate {
                    skills_required: Some(new_skills),
                    ..Default::default()
                };
                match store.set_fields(gap_id, update) {
                    Ok(()) => applied += 1,
                    Err(e) => {
                        eprintln!("  WARN: could not tag {gap_id}: {e}");
                        errors += 1;
                    }
                }
            }
            println!();
            println!("applied {applied} tag(s), {errors} error(s)");
            if applied > 0 {
                println!("  Tip: run `chump gap import` to refresh the repos table.");
            }

            // Emit ambient event.
            {
                let lock_dir = repo_root.join(".chump-locks");
                let ambient = lock_dir.join("ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                // scanner-anchor: gap_external_repo_backfilled (MISSION-041)
                let event = format!(
                    r#"{{"ts":"{ts}","kind":"gap_external_repo_backfilled","linked_count":{applied},"errors":{errors},"already_tagged":{already_tagged},"skipped":{unmatched}}}"#,
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
            return Ok(());
        }
        _ => {
            eprintln!("chump gap <subcommand> [options]");
            eprintln!("  list             [--status open|done] [--json]");
            eprintln!("  reserve          --domain D --title T [--priority P1] [--effort s] [--external-repo owner/repo]");
            eprintln!("                     (positional) D title…  — same as --domain / --title");
            eprintln!("  claim            <GAP-ID> [--session ID] [--worktree PATH] [--ttl 3600]");
            eprintln!("  preflight        <GAP-ID>");
            eprintln!("  ship             <GAP-ID> [--session ID] [--update-yaml] [--closed-pr N]");
            eprintln!(
                    "  link-pr          <GAP-ID> <PR-NUMBER> --sha <SHA>  # INFRA-8192: typed gap-to-PR link"
                );
            eprintln!(
                    "  unlink-pr        <GAP-ID> <PR-NUMBER> --reason <text>  # CREDIBLE-1552: remove one gap_prs link"
                );
            eprintln!("  set              <GAP-ID> [--title T] [--description D] [--priority P]");
            eprintln!("                             [--effort E] [--status S] [--notes N]");
            eprintln!(
                    "                             [--source-doc S] [--opened-date D] [--closed-date D] [--closed-pr N]"
                );
            eprintln!("                             [--acceptance-criteria \"a|b|c\"] [--depends-on \"X-1,X-2\"]");
            eprintln!("  decompose        <GAP-ID> [--apply] [--json] [--dry-run] [--no-description] [--external-repo <owner/repo|path>] [--clone-path <path>]  # LLM-assisted slicing");
            eprintln!("  scaffold-holes   <GAP-ID> [--path DIR] [--json]  # mechanical todo!() hole-finder for scaffold-and-holes PRs (EFFECTIVE-440)");
            eprintln!("  dep-clean        [--apply] [--json]  # strip depends_on entries pointing at done gaps");
            eprintln!("  dump             [--out PATH] [--per-file [--out-dir docs/gaps/]]");
            eprintln!("  import           [--yaml docs/gaps.yaml]");
            eprintln!("  restore          --from-sql  # rebuild state.db from a local .chump/state.sql dump (INFRA-538)");
            eprintln!("  audit-priorities [--json]   # PM health check (META-046)");
            eprintln!("  triage           [--json] [--apply]  # INFRA-942: classify non-pickable open gaps by reason");
            eprintln!("  audit-ac         [GAP-ID] [--recent N] [--json]  # COG-052 AC coverage check for closed gaps");
            eprintln!("  audit-ac         --open [--json]                  # INFRA-936: warn on open gaps with empty/TODO AC");
            eprintln!("  consolidate      [--threshold N] [--json]  # INFRA-935 near-duplicate title detection");
            eprintln!("  rate             <GAP-ID> <1-5> [--comment text] [--pr N]  # FLEET-048 operator impact rating");
            eprintln!("  rebalance        [--apply] [--json]  # P0 budget + pillar floor enforcement (INFRA-635)");
            eprintln!(
                "  pillar-balance   [--suggest] [--apply] [--json]  # pillar inventory (INFRA-604)"
            );
            eprintln!("  import-spec      <path> [--apply] [--dry-run] [--json]  # import gaps from markdown spec (INFRA-636)");
            eprintln!("  clear-cooldown   <GAP-ID> --reason \"text\"  # INFRA-1220: operator override for post-close cooldown");
            eprintln!("  requeue          <GAP-ID>                  # INFRA-2137: bisect_quarantined → ready_to_ship after operator review");
            eprintln!("  sync             (--check | --push) [--dry-run] [--json] [--state-db PATH] [--gaps-dir PATH]  (--pull retired: INFRA-8193)");
            eprintln!("                                # INFRA-2053: bidirectional YAML <-> state.db reconciliation");
            eprintln!("  backfill-external-repo [--apply] [--owner-repo owner/repo]");
            eprintln!("                                # MISSION-041: tag gaps with external_repo: in skills_required");
            std::process::exit(2);
        }
    }
    Ok(())
}
