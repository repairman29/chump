//! INFRA-3302 (slice 3 of INFRA-3287 main.rs decomposition): the
//! `chump gap <subcommand>` command group — extracted verbatim (~5985 lines)
//! from main()'s argv chain. `run` is `async` + `Result` to match main()'s
//! context, so the body's process::exit / .await / ? / return all work
//! unchanged. The arm always exits internally (default help arm =
//! process::exit(2)); the trailing Ok(()) preserves the original fall-through.
#![allow(clippy::all, unreachable_code)]

use crate::{
    extract_path_hints, is_acceptance_criteria_vague, is_test_domain, is_vague_ac_entry,
    parse_duration_to_secs, print_priority_hint, repo_path, unix_ts, version, write_yaml_op_marker,
};
use chump_gap_store as gap_store;

/// `chump gap <subcommand>` dispatcher. Moved verbatim from main() (INFRA-3302).
pub async fn run(args: &[String]) -> anyhow::Result<()> {
    let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
    let repo_root = repo_path::repo_root();
    // INFRA-247: per-file YAML mirrors and the .chump/.last-yaml-op
    // freshness marker are *worktree-local* artifacts — they must land
    // in the operator's branch, not the main checkout's. `repo_root`
    // resolves via CHUMP_REPO/CHUMP_HOME (set by the main checkout's
    // .env, which dotenvy walks up to find from any linked worktree),
    // so it points at the main checkout. `worktree_root` uses
    // `git rev-parse --show-toplevel` from CWD, which correctly
    // resolves to the linked worktree the operator is actually in.
    // state.db remains under repo_root (shared canonical state).
    let worktree_root = repo_path::worktree_root();
    let store = match gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("chump gap: cannot open state.db: {e:#}");
            std::process::exit(1);
        }
    };
    let flag = |name: &str| -> Option<String> {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let json_out = args.iter().any(|a| a == "--json");

    match subcmd {
        // INFRA-498: 'chump gap show <ID>' — human-readable per-gap
        // rendering. Replaces `cat docs/gaps/<ID>.yaml` now that those
        // files are deleted.
        "show" => {
            // INFRA-1037: --brief (one-liner), default (status promoted), --field <name>
            let id_pos = args[3..]
                .iter()
                .position(|a| !a.starts_with("--"))
                .map(|i| i + 3);
            let id = id_pos
                .and_then(|p| args.get(p))
                .cloned()
                .unwrap_or_else(|| {
                    eprintln!("Usage: chump gap show <GAP-ID> [--brief|--field <name>]");
                    std::process::exit(2);
                });
            if id.starts_with("--") {
                eprintln!("Usage: chump gap show <GAP-ID> [--brief|--field <name>]");
                std::process::exit(2);
            }
            let brief_mode = args.iter().any(|a| a == "--brief");
            let field_mode = args.windows(2).find_map(|w| {
                if w[0] == "--field" {
                    Some(w[1].clone())
                } else {
                    None
                }
            });

            match store.get(&id) {
                Ok(Some(g)) => {
                    // CREDIBLE-033: parse AC items for rich rendering.
                    let ac_items = gap_store::parse_json_ac_list(&g.acceptance_criteria);
                    let ac_has_todos = ac_items.iter().any(|item| {
                        let up = item.to_uppercase();
                        up.contains("TODO") || item.contains("TBD") || item.contains("<fill in>")
                    });

                    if json_out {
                        // Extend JSON output with schema_version (INFRA-1548),
                        // ac_count + ac_has_todos (CREDIBLE-033),
                        // shipped_in as nested object when present (INFRA-2134).
                        let mut val = serde_json::to_value(&g).unwrap_or_default();
                        if let Some(obj) = val.as_object_mut() {
                            obj.insert(
                                "schema_version".to_string(),
                                serde_json::Value::Number(1.into()),
                            );
                            obj.insert(
                                "ac_count".to_string(),
                                serde_json::Value::Number(ac_items.len().into()),
                            );
                            obj.insert(
                                "ac_has_todos".to_string(),
                                serde_json::Value::Bool(ac_has_todos),
                            );
                            // INFRA-2134: replace the shipped_in string with a
                            // parsed JSON object so consumers get a native object,
                            // not a double-encoded string.
                            if let Some(raw) = &g.shipped_in {
                                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(raw) {
                                    obj.insert("shipped_in".to_string(), parsed);
                                }
                            }
                        }
                        println!("{}", serde_json::to_string_pretty(&val).unwrap_or_default());
                    } else if brief_mode {
                        // --brief: one-line summary
                        let pr_str = g.closed_pr.map(|n| format!("#{}", n)).unwrap_or_default();
                        println!(
                            "[{}] {} — {} {}/{} {}",
                            g.status, g.id, g.title, g.priority, g.effort, pr_str
                        );
                    } else if let Some(ref field) = field_mode {
                        // --field <name>: print just the value, script-friendly
                        let val = match field.as_str() {
                            "id" => g.id.clone(),
                            "domain" => g.domain.clone(),
                            "title" => g.title.clone(),
                            "status" => g.status.clone(),
                            "priority" => g.priority.clone(),
                            "effort" => g.effort.clone(),
                            "description" => g.description.clone(),
                            "acceptance_criteria" => g.acceptance_criteria.clone(),
                            "notes" => g.notes.clone(),
                            "depends_on" => g.depends_on.clone(),
                            "closed_date" => g.closed_date.clone(),
                            "closed_pr" => g.closed_pr.map(|n| n.to_string()).unwrap_or_default(),
                            other => {
                                eprintln!("chump gap show --field: unknown field '{}'", other);
                                std::process::exit(1);
                            }
                        };
                        println!("{}", val.trim());
                    } else {
                        // INFRA-1285: helper to quote YAML scalar strings that need it.
                        // Strings containing ':', '#', leading/trailing whitespace, or
                        // starting with a YAML indicator char are quoted with double-quotes.
                        fn yaml_quote(s: &str) -> String {
                            let needs_quote = s.contains(':')
                                || s.contains('#')
                                || s.contains('"')
                                || s.contains('\\')
                                || s.starts_with(|c: char| {
                                    matches!(
                                        c,
                                        '{' | '}'
                                            | '['
                                            | ']'
                                            | ','
                                            | '&'
                                            | '*'
                                            | '?'
                                            | '|'
                                            | '-'
                                            | '<'
                                            | '>'
                                            | '='
                                            | '!'
                                            | '%'
                                            | '@'
                                            | '`'
                                    )
                                })
                                || s.starts_with(|c: char| c.is_whitespace())
                                || s.ends_with(|c: char| c.is_whitespace())
                                || s.is_empty();
                            if needs_quote {
                                // Escape backslashes and double-quotes inside the string.
                                let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
                                format!("\"{}\"", escaped)
                            } else {
                                s.to_string()
                            }
                        }
                        // Default: status/closed_pr/closed_date promoted before description (INFRA-1037)
                        println!("- id: {}", g.id);
                        println!("  domain: {}", g.domain);
                        println!("  title: {}", yaml_quote(&g.title));
                        println!("  status: {}", g.status);
                        println!("  priority: {}", g.priority);
                        println!("  effort: {}", g.effort);
                        if let Some(pr) = g.closed_pr {
                            println!("  closed_pr: {}", pr);
                        }
                        if !g.closed_date.is_empty() {
                            println!("  closed_date: '{}'", g.closed_date);
                        }
                        if !g.depends_on.is_empty() {
                            println!("  depends_on: [{}]", g.depends_on);
                        }
                        if !g.description.is_empty() {
                            println!("  description: |");
                            for line in g.description.lines() {
                                println!("    {}", line);
                            }
                        }
                        if !ac_items.is_empty() {
                            // CREDIBLE-033: numbered list, WARN prefix on vague items.
                            println!("  acceptance_criteria:");
                            for (i, item) in ac_items.iter().enumerate() {
                                let up = item.to_uppercase();
                                let is_vague = up.contains("TODO")
                                    || item.contains("TBD")
                                    || item.contains("<fill in>");
                                if is_vague {
                                    println!("    {}. WARN: {}", i + 1, item);
                                } else {
                                    println!("    {}. {}", i + 1, item);
                                }
                            }
                            if ac_has_todos {
                                eprintln!(
                                    "WARN: gap {}: acceptance_criteria contains \
                                         incomplete placeholders (TODO/TBD/<fill in>)",
                                    g.id
                                );
                            }
                        } else if !g.acceptance_criteria.trim().is_empty() {
                            // Fallback: raw text when not parseable as JSON list.
                            println!("  acceptance_criteria:");
                            println!("    1. {}", g.acceptance_criteria.trim());
                        }
                        if !g.notes.is_empty() {
                            println!("  notes: |");
                            for line in g.notes.lines() {
                                println!("    {}", line);
                            }
                        }
                        // INFRA-2134: render shipped_in when present.
                        // Only emit for shipped/done gaps; open gaps have NULL.
                        if let Some(raw) = &g.shipped_in {
                            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(raw) {
                                println!("  shipped_in:");
                                // Integration-cycle shape: 5-key form.
                                if let Some(iid) =
                                    parsed.get("integration_id").and_then(|v| v.as_str())
                                {
                                    println!("    integration: {}", iid);
                                }
                                if let Some(ipr) =
                                    parsed.get("integration_pr").and_then(|v| v.as_str())
                                {
                                    println!("    pr: {}", ipr);
                                }
                                if let Some(cc) =
                                    parsed.get("child_commit").and_then(|v| v.as_str())
                                {
                                    // Abbreviate to 7 chars to match AC spec.
                                    println!("    commit: {}", &cc[..cc.len().min(7)]);
                                }
                                if let Some(ms) = parsed.get("merge_sha").and_then(|v| v.as_str()) {
                                    println!("    merge_sha: {}", &ms[..ms.len().min(7)]);
                                }
                                // Per-PR backwards-compat shape: pr_url + merge_sha.
                                if let Some(pu) = parsed.get("pr_url").and_then(|v| v.as_str()) {
                                    println!("    pr: {}", pu);
                                }
                                // merge_sha already handled above (same key in both shapes).
                                // For per-PR shape where integration keys are absent:
                                if parsed.get("integration_id").is_none() {
                                    if let Some(ms) =
                                        parsed.get("merge_sha").and_then(|v| v.as_str())
                                    {
                                        println!("    merge_sha: {}", &ms[..ms.len().min(7)]);
                                    }
                                }
                            }
                        }
                        // CREDIBLE-107: show evidence when present.
                        if let Some(ref ev) = g.evidence {
                            if !ev.trim().is_empty() {
                                println!("  evidence: |");
                                for line in ev.lines() {
                                    println!("    {}", line);
                                }
                            }
                        }
                        // INFRA-1220: show cooldown status if active.
                        let cooldown_file = repo_root
                            .join(".chump-locks/.gap-cooldown")
                            .join(format!("{}.json", g.id));
                        if cooldown_file.exists() {
                            let script = repo_root.join("scripts/coord/gap-cooldown.sh");
                            let _ = std::process::Command::new("bash")
                                .arg(&script)
                                .arg("status")
                                .arg(&g.id)
                                .env("CHUMP_LOCK_DIR", repo_root.join(".chump-locks"))
                                .status();
                        }
                    }
                    return Ok(());
                }
                Ok(None) => {
                    eprintln!("chump gap show: gap {} not found", id);
                    std::process::exit(1);
                }
                Err(e) => {
                    eprintln!("chump gap show: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "list" => {
            let status_filter = flag("--status");
            // INFRA-431: include-test-domains opts back in to SPIKE/TEST*
            // rows. Default is to filter them out of the human-readable
            // output (kept in --json output unconditionally so tooling
            // sees the true state). Surfaces by name in the summary
            // line so the operator KNOWS the filter ran.
            let include_test_domains = args.iter().any(|a| a == "--include-test-domains");
            // EFFECTIVE-023: --domain <D> filters to a single domain;
            // --domain all shows per-domain summary footer.
            let domain_filter = flag("--domain");
            // EFFECTIVE-008: --quiet suppresses all output (exit 0 on success).
            let quiet = args.iter().any(|a| a == "--quiet");
            // EFFECTIVE-008: --format <human|json|csv> — explicit format
            // selector; --json and --format json are equivalent.
            let fmt = flag("--format").unwrap_or_else(|| {
                if json_out {
                    "json".to_string()
                } else {
                    "human".to_string()
                }
            });
            let csv_out = fmt == "csv";
            let json_out = json_out || fmt == "json";
            // EFFECTIVE-018: --since <duration> filters to gaps that had
            // activity (opened or closed) within the given window.
            let since_cutoff: Option<String> = flag("--since").and_then(|s| {
                let secs = parse_duration_to_secs(&s).unwrap_or_else(|| {
                    eprintln!(
                        "chump gap list: invalid --since '{}' (expected 7d, 24h, 30d…)",
                        s
                    );
                    std::process::exit(2);
                });
                let cutoff_ts = unix_ts().saturating_sub(secs);
                use chrono::TimeZone;
                chrono::Utc
                    .timestamp_opt(cutoff_ts as i64, 0)
                    .single()
                    .map(|dt| dt.format("%Y-%m-%d").to_string())
            });
            // INFRA-821: auto-seed state.db on fresh clone before listing.
            let seeded = store.auto_seed_if_empty();
            if seeded > 0 {
                tracing::info!(
                    kind = "gap_db_auto_seeded",
                    imported = seeded,
                    "state.db was empty on open — auto-imported from docs/gaps/"
                );
            }
            match store.list(status_filter.as_deref()) {
                Ok(all_gaps) => {
                    // Apply --since filter before any output path.
                    // Date strings are YYYY-MM-DD, so lexicographic >= works.
                    let gaps: Vec<_> = if let Some(ref cutoff) = since_cutoff {
                        all_gaps
                            .into_iter()
                            .filter(|g| {
                                (!g.opened_date.is_empty()
                                    && g.opened_date.as_str() >= cutoff.as_str())
                                    || (!g.closed_date.is_empty()
                                        && g.closed_date.as_str() >= cutoff.as_str())
                            })
                            .collect()
                    } else {
                        all_gaps
                    };
                    if quiet {
                        // --quiet: no output, just verify the query ran (exit 0).
                        return Ok(());
                    } else if csv_out {
                        // EFFECTIVE-008: CSV format — id,domain,status,priority,effort,title
                        println!("id,domain,status,priority,effort,title");
                        for g in &gaps {
                            let dom = g.id.split('-').next().unwrap_or("?");
                            if !include_test_domains && is_test_domain(dom) {
                                continue;
                            }
                            if let Some(df) = &domain_filter {
                                if df != "all" && dom != df.as_str() {
                                    continue;
                                }
                            }
                            // Escape commas and quotes in title
                            let title_esc = g.title.replace('"', "\"\"");
                            println!(
                                "{},{},{},{},{},\"{}\"",
                                g.id, g.domain, g.status, g.priority, g.effort, title_esc
                            );
                        }
                    } else if json_out {
                        // EFFECTIVE-023: when --domain is set, wrap in
                        // {gaps: [...], domain_summary: {...}} object.
                        // Without --domain, output the plain array as before.
                        if let Some(df) = &domain_filter {
                            let filtered: Vec<&gap_store::GapRow> = gaps
                                .iter()
                                .filter(|g| {
                                    let dom = g.id.split('-').next().unwrap_or("?");
                                    df == "all" || dom == df.as_str()
                                })
                                .collect();
                            // Build domain_summary over the filtered set.
                            let mut ds: std::collections::BTreeMap<
                                String,
                                std::collections::BTreeMap<String, usize>,
                            > = std::collections::BTreeMap::new();
                            for g in &filtered {
                                let dom = g.id.split('-').next().unwrap_or("?").to_string();
                                let entry = ds.entry(dom).or_default();
                                let key = match g.status.as_str() {
                                    "done" => "done",
                                    "in_progress" => "in_progress",
                                    _ => "open",
                                };
                                *entry.entry(key.to_string()).or_insert(0) += 1;
                            }
                            let obj = serde_json::json!({
                                "gaps": filtered,
                                "domain_summary": ds,
                            });
                            println!("{}", serde_json::to_string_pretty(&obj).unwrap_or_default());
                        } else if let Some(ref cutoff) = since_cutoff {
                            // EFFECTIVE-018: wrap with since_cutoff so tooling can inspect the window.
                            let obj = serde_json::json!({
                                "since_cutoff": cutoff,
                                "gaps": gaps,
                            });
                            println!("{}", serde_json::to_string_pretty(&obj).unwrap_or_default());
                        } else {
                            println!(
                                "{}",
                                serde_json::to_string_pretty(&gaps).unwrap_or_default()
                            );
                        }
                    } else {
                        // EFFECTIVE-023: when --domain <D> (not "all"),
                        // print a "Domain: D" header and filter rows.
                        let specific_domain = domain_filter.as_deref().filter(|d| *d != "all");
                        if let Some(d) = specific_domain {
                            println!("Domain: {d}");
                        }

                        // Build filtered view + per-domain counts on the
                        // unfiltered set so the summary + ALERT see the
                        // truth (the SPIKE leak hid because counts were
                        // never inspected by domain).
                        let mut by_domain: std::collections::BTreeMap<String, usize> =
                            std::collections::BTreeMap::new();
                        for g in &gaps {
                            let dom = g.id.split('-').next().unwrap_or("?").to_string();
                            *by_domain.entry(dom).or_insert(0) += 1;
                        }
                        let mut filtered_count = 0usize;
                        let mut filtered_domains: Vec<String> = Vec::new();
                        for g in &gaps {
                            let dom = g.id.split('-').next().unwrap_or("?");
                            if !include_test_domains && is_test_domain(dom) {
                                if !filtered_domains.iter().any(|d| d == dom) {
                                    filtered_domains.push(dom.to_string());
                                }
                                filtered_count += 1;
                                continue;
                            }
                            // EFFECTIVE-023: apply domain filter.
                            if let Some(df) = &domain_filter {
                                if df != "all" && dom != df.as_str() {
                                    continue;
                                }
                            }
                            // EFFECTIVE-024: done gaps append "→ #PR merged YYYY-MM-DD"
                            let done_suffix = if g.status == "done" {
                                match (g.closed_pr, g.closed_date.as_str()) {
                                    (Some(pr), d) if !d.is_empty() => {
                                        format!(" → #{pr} merged {d}")
                                    }
                                    (Some(pr), _) => format!(" → #{pr} merged"),
                                    (None, d) if !d.is_empty() => {
                                        format!(" → merged {d}")
                                    }
                                    _ => String::new(),
                                }
                            } else {
                                String::new()
                            };
                            // INFRA-1259: add warning indicator for vague AC
                            let ac_warn = if is_acceptance_criteria_vague(&g.acceptance_criteria) {
                                " ⚠"
                            } else {
                                ""
                            };
                            println!(
                                "[{}] {} — {} ({}/{}){}{done_suffix}",
                                g.status, g.id, g.title, g.priority, g.effort, ac_warn
                            );
                        }

                        // EFFECTIVE-023: --domain all shows per-domain summary.
                        if domain_filter.as_deref() == Some("all") {
                            // Build per-status counts by domain over ALL gaps.
                            let mut by_dom_status: std::collections::BTreeMap<
                                String,
                                (
                                    usize,
                                    usize,
                                    usize,
                                    std::collections::BTreeMap<String, usize>,
                                ),
                            > = std::collections::BTreeMap::new();
                            for g in &gaps {
                                let dom = g.id.split('-').next().unwrap_or("?").to_string();
                                let entry = by_dom_status.entry(dom).or_insert((
                                    0,
                                    0,
                                    0,
                                    std::collections::BTreeMap::new(),
                                ));
                                match g.status.as_str() {
                                    "done" => entry.1 += 1,
                                    "in_progress" => entry.2 += 1,
                                    _ => {
                                        entry.0 += 1;
                                        *entry.3.entry(g.priority.clone()).or_insert(0) += 1;
                                    }
                                }
                            }
                            println!();
                            for (dom, (open, _done, _in_prog, prios)) in &by_dom_status {
                                let p0 = prios.get("P0").copied().unwrap_or(0);
                                let p1 = prios.get("P1").copied().unwrap_or(0);
                                println!("{dom}: {open} open (P0={p0}, P1={p1})");
                            }
                        } else if domain_filter.is_none() {
                            // Default path (no --domain): existing summary line.
                            // Domain-population ALERT (stderr, unconditional).
                            let total = gaps.len();
                            for (dom, n) in &by_domain {
                                let pct = (*n * 100).checked_div(total).unwrap_or(0);
                                if *n > 100 || pct > 50 {
                                    eprintln!(
                                            "ALERT: domain {} has {} gaps ({}% of total) — likely a test-fixture leak (see INFRA-428)",
                                            dom, n, pct
                                        );
                                }
                            }
                            // Summary line (stdout). Top 5 domains by count.
                            let mut domain_pairs: Vec<(&String, &usize)> =
                                by_domain.iter().collect();
                            domain_pairs.sort_by(|a, b| b.1.cmp(a.1));
                            let top: Vec<String> = domain_pairs
                                .iter()
                                .take(5)
                                .map(|(d, n)| format!("{d}={n}"))
                                .collect();
                            let shown = total - filtered_count;
                            let mut summary = if let Some(ref cutoff) = since_cutoff {
                                format!(
                                        "\n--- {} shown (active since {}) / {} total across {} domains (top: {}) ---",
                                        shown, cutoff, total, by_domain.len(), top.join(" ")
                                    )
                            } else {
                                format!(
                                        "\n--- {} shown / {} total open across {} domains (top: {}) ---",
                                        shown, total, by_domain.len(), top.join(" ")
                                    )
                            };
                            if !filtered_domains.is_empty() {
                                summary.push_str(&format!(
                                        "\n--- filtered out {} test-domain row(s): {} (use --include-test-domains to see) ---",
                                        filtered_count, filtered_domains.join(" ")
                                    ));
                            }
                            println!("{summary}");
                        }
                    }
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap list: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "reserve" => {
            let has_flag_domain = args.iter().any(|a| a == "--domain");
            let domain = flag("--domain").or_else(|| {
                args.get(3).and_then(|a| {
                    if a.starts_with('-') {
                        None
                    } else {
                        Some(a.clone())
                    }
                })
            });
            let domain = domain.unwrap_or_else(|| {
                eprintln!("Usage: chump gap reserve --domain D --title T");
                eprintln!("   or: chump gap reserve D title words…");
                std::process::exit(2);
            });
            let title = flag("--title").unwrap_or_else(|| {
                if has_flag_domain {
                    eprintln!("--title required when using --domain");
                    std::process::exit(2);
                }
                args.get(4..)
                    .map(|tail| tail.join(" "))
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "New gap".into())
            });
            let priority = flag("--priority").unwrap_or_else(|| "P2".into());
            let effort = flag("--effort").unwrap_or_else(|| "m".into());
            let stack_on = flag("--stack-on");
            // CREDIBLE-107: --evidence required for P0/P1 RESILIENT/MISSION/CREDIBLE gaps.
            let reserve_evidence = flag("--evidence");
            let no_evidence_required = args.iter().any(|a| a == "--no-evidence-required");
            // MISSION-008: optional --outcome <id> to assign gap to an outcome at reserve time.
            let reserve_outcome_id = flag("--outcome");
            // MISSION-041: optional --external-repo <owner/repo> to tag the gap
            // with external_repo:<owner/repo> in skills_required at reserve time.
            // Prevents recurrence of the data gap that caused BEAST routing to fail.
            let reserve_external_repo = flag("--external-repo");
            let force = args.iter().any(|a| a == "--force");
            // INFRA-592: --quiet suppresses progress; default emits one-line
            // per phase to stderr so --json piping of stdout is unaffected.
            let quiet = args.iter().any(|a| a == "--quiet");
            // INFRA-2177: --json emits machine-readable {"id":"...","yaml_path":"..."}
            // to stdout so operator scripts can parse without grep.
            let json_out = args.iter().any(|a| a == "--json");
            let why = args.iter().any(|a| a == "--why");
            let skip_obs_acs = args.iter().any(|a| a == "--skip-obs-acs");
            let custom_acceptance_criteria = flag("--acceptance-criteria");

            // INFRA-756: compute acceptance_criteria. Default to 4 obs-AC templates
            // unless --skip-obs-acs is set or --acceptance-criteria is provided.
            let acceptance_criteria_json = match custom_acceptance_criteria {
                Some(raw) => {
                    let parts: Vec<&str> = raw.split('|').collect();
                    serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
                }
                None if !skip_obs_acs => {
                    let obs_acs = vec![
                        "TODO: what events emitted on success/failure/timeout",
                        "TODO: how cost tracked and reported to operator",
                        "TODO: failure-class taxonomy (distinguish transient vs permanent)",
                        "TODO: smoke test command to verify observability",
                    ];
                    serde_json::to_string(&obs_acs).unwrap_or_else(|_| "[]".into())
                }
                _ => "[]".into(),
            };

            // FLEET-029: ambient glance before allocating ID
            if !force && std::env::var("FLEET_029_AMBIENT_GLANCE_SKIP").is_err() {
                use std::process::Command;
                if !quiet {
                    eprint!("checking registry health...");
                }
                let glance_result = Command::new("bash")
                    .arg("scripts/coord/chump-ambient-glance.sh")
                    .arg("--domain")
                    .arg(&domain)
                    .arg("--title")
                    .arg(&title)
                    .arg("--check-prs")
                    .current_dir(repo_path::repo_root())
                    .status();

                if let Ok(status) = glance_result {
                    if !status.success() {
                        eprintln!();
                        eprintln!("[reserve] Potential overlap detected. Pass --force to proceed anyway, or review the matches above.");
                        std::process::exit(1);
                    }
                }
                if !quiet {
                    eprintln!(" ok");
                }
            }

            // ── INFRA-1418: offline-compliance lint at reserve-time ────────────
            // Scan title + description for forbidden-without-fallback patterns
            // from docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md §2. Block unless
            // --force-anti-offline is passed alongside --offline-bypass-reason.
            // Disable: CHUMP_DISABLE_OFFLINE_CHECK=1.
            //
            // History (INFRA-1526): hunk repeatedly dropped by the
            // rust-main-append merge driver during rebases against fast-moving
            // main. Reset to main and re-applied fresh to avoid the driver.
            let offline_check_disabled =
                std::env::var("CHUMP_DISABLE_OFFLINE_CHECK").as_deref() == Ok("1");
            let force_anti_offline = args.iter().any(|a| a == "--force-anti-offline");
            let offline_bypass_reason = flag("--offline-bypass-reason");
            if !offline_check_disabled {
                let patterns: &[(&str, &str, &str, &str)] = &[
                        (
                            "gh-pr-only",
                            r"(?i)gh\s+pr\s+(merge|create|view)[^.]{0,60}\bONLY\b",
                            "hard-pins the path to GitHub even when local-merge-queue exists",
                            "rewrite as 'gh pr X (online) OR local-merge-queue.sh (offline)'",
                        ),
                        (
                            "webhook-only",
                            r"(?i)\b(only|exclusively)[^.]{0,40}\bwebhook|\bwebhook[s]?[^.]{0,30}\bonly\b|\bwebhook-only\b",
                            "local equivalents (post-receive hook, NATS subject) exist for almost every webhook event",
                            "rewrite as 'webhook OR local-equivalent (post-receive hook / NATS subject)'",
                        ),
                        (
                            "gh-actions-required",
                            r"(?i)github\s+actions\s+(must|required|is\s+the\s+gate)",
                            "conflates the executor with correctness; the tests ARE the CI",
                            "split into local-CI (run-local-ci.sh) + remote-CI (.github/workflows/)",
                        ),
                        (
                            "gh-api-blocking",
                            r"(?i)gh\s+api[^.]*\b(blocking|required|gates)\b",
                            "every fleet read should be cache-first per CLAUDE.md",
                            "use cache_lookup_*; gh api fallback only on cache miss",
                        ),
                        (
                            "state-db-coupled-to-network",
                            r"(?i)state\.db[^.]{0,80}\b(ONLY|exclusively)\b[^.]{0,40}\bwebhook|webhook[^.]{0,40}\bwrites?\s+(to\s+)?state\.db",
                            "couples local ground truth to network delivery — breaks Pi mesh + airplane mode",
                            "use proof-of-merge: PROOF_LOCAL_MERGE OR PROOF_WEBHOOK (see INFRA-1392)",
                        ),
                    ];

                let combined = format!(
                    "{}\n{}",
                    title,
                    flag("--description").as_deref().unwrap_or(""),
                );
                let mut hits: Vec<(&str, String, &str, &str)> = Vec::new();
                for entry in patterns {
                    if let Ok(re) = regex::Regex::new(entry.1) {
                        if let Some(m) = re.find(&combined) {
                            hits.push((
                                entry.0,
                                m.as_str().trim_end().to_string(),
                                entry.2,
                                entry.3,
                            ));
                        }
                    }
                }

                if !hits.is_empty() {
                    let ts_now = unix_ts();
                    let ambient_path = worktree_root.join(".chump-locks").join("ambient.jsonl");
                    eprintln!();
                    for (name, snippet, why, fix) in &hits {
                        eprintln!("OFFLINE_CHECK FAIL: \"{snippet}\"");
                        eprintln!("  pattern : {name}");
                        eprintln!("  why     : {why}");
                        eprintln!("  fix     : {fix}");
                        eprintln!("  see     : docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md §2");
                    }

                    if force_anti_offline {
                        let reason = offline_bypass_reason.as_deref().unwrap_or("").trim();
                        if reason.is_empty() {
                            eprintln!();
                            eprintln!(
                                    "[reserve] --force-anti-offline requires --offline-bypass-reason \"<text>\"."
                                );
                            eprintln!(
                                    "  Example: --offline-bypass-reason \"RUBRIC §4 case 1: intrinsically network-dependent\""
                                );
                            std::process::exit(2);
                        }
                        let _ = store.record_offline_bypass(
                            title.as_str(),
                            reason,
                            std::env::var("USER").unwrap_or_default().as_str(),
                        );
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
                            let safe_title = title.replace(['"', '\\'], "");
                            let _ = writeln!(
                                f,
                                r#"{{"ts":"{ts_now}","kind":"gap_offline_bypass","title":"{safe_title}","reason":"{safe_reason}","hits":{}}}"#,
                                hits.len()
                            );
                        }
                        eprintln!();
                        eprintln!(
                                "[reserve] --force-anti-offline accepted ({} hit(s)). Audit row written.",
                                hits.len()
                            );
                    } else {
                        eprintln!();
                        eprintln!(
                                "[reserve] BLOCK: gap text trips offline-compliance lint ({} pattern hit(s)).",
                                hits.len()
                            );
                        eprintln!("          Either rewrite per the suggestions above, OR pass");
                        eprintln!(
                            "          --force-anti-offline --offline-bypass-reason \"<text>\""
                        );
                        eprintln!("          Bypass entirely (CI / bulk imports): CHUMP_DISABLE_OFFLINE_CHECK=1");
                        if let Some(parent) = ambient_path.parent() {
                            let _ = std::fs::create_dir_all(parent);
                        }
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            use std::io::Write;
                            let safe_title = title.replace(['"', '\\'], "");
                            let _ = writeln!(
                                f,
                                r#"{{"ts":"{ts_now}","kind":"gap_offline_check_block","title":"{safe_title}","hits":{}}}"#,
                                hits.len()
                            );
                        }
                        std::process::exit(1);
                    }
                }
            }

            // ── INFRA-1149: reserve-time title similarity check ───────────────
            // INFRA-1982: Demoted from BLOCK to WARN-only at >= 0.85.
            //
            // Rationale: title-similarity is a poor proxy for the real
            // failure (duplicate PRs). Authors learned to bypass
            // CHUMP_GAP_RESERVE_NO_SIMILARITY=1 reflexively, defeating the
            // audit value. The real guard is the open-PR check at claim
            // time (INFRA-1982). This gate is now pure telemetry — it
            // emits gap_reserve_similarity_warn for both thresholds so the
            // operator can see the pattern in ambient.jsonl, but it never
            // blocks or prompts for stdin.
            //
            // Bypass env kept for backward compat: CHUMP_GAP_RESERVE_NO_SIMILARITY=1
            // still suppresses the check entirely (useful in bulk imports).
            let force_duplicate = args.iter().any(|a| a == "--force-duplicate");
            let similarity_enabled =
                std::env::var("CHUMP_GAP_RESERVE_NO_SIMILARITY").as_deref() != Ok("1");
            if similarity_enabled && !force_duplicate {
                let warn_threshold: f64 = std::env::var("CHUMP_GAP_RESERVE_SIMILARITY_WARN")
                    .ok()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0.65);
                // block_threshold retained for ambient event label; no longer exits.
                let block_threshold: f64 = std::env::var("CHUMP_GAP_RESERVE_SIMILARITY_BLOCK")
                    .ok()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0.85);
                match store.similarity_candidates(&title, 3, 30) {
                    Ok(candidates) if !candidates.is_empty() => {
                        let top_score = candidates[0].3;
                        let top_id = &candidates[0].0;
                        if top_score >= warn_threshold {
                            let ambient_path =
                                worktree_root.join(".chump-locks").join("ambient.jsonl");
                            eprintln!();
                            eprintln!(
                                "[reserve] INFRA-1149: title similarity check — proposed: \"{}\"",
                                title
                            );
                            for (cid, ctitle, cstatus, cscore) in &candidates {
                                eprintln!(
                                    "  {:.2}  {} ({}) — \"{}\"",
                                    cscore, cid, cstatus, ctitle
                                );
                            }
                            // Emit ambient event
                            let ts = {
                                use std::time::{SystemTime, UNIX_EPOCH};
                                SystemTime::now()
                                    .duration_since(UNIX_EPOCH)
                                    .map(|d| d.as_secs())
                                    .unwrap_or(0)
                            };
                            // INFRA-1982: both warn and block thresholds now
                            // emit a warn event and continue without blocking.
                            if top_score >= block_threshold {
                                eprintln!(
                                        "[reserve] WARN (score {:.2} ≥ {:.2}): high similarity to {} — \
                                         check for duplicate work (open-PR gate fires at claim time).",
                                        top_score, block_threshold, top_id
                                    );
                                let _ = std::fs::OpenOptions::new()
                                        .append(true)
                                        .create(true)
                                        .open(&ambient_path)
                                        .and_then(|mut f| {
                                            use std::io::Write;
                                            writeln!(f,
                                                r#"{{"ts":"{ts}","kind":"gap_reserve_similarity_warn","proposed_title":"{title}","top_match_id":"{top_id}","top_match_score":{top_score:.3}}}"#
                                            )
                                        });
                                // No exit — INFRA-1982: similarity is advisory only.
                            } else {
                                eprintln!(
                                        "[reserve] WARN (score {:.2} ≥ {:.2}): potential overlap with {}.",
                                        top_score, warn_threshold, top_id
                                    );
                                let _ = std::fs::OpenOptions::new()
                                        .append(true)
                                        .create(true)
                                        .open(&ambient_path)
                                        .and_then(|mut f| {
                                            use std::io::Write;
                                            writeln!(f,
                                                r#"{{"ts":"{ts}","kind":"gap_reserve_similarity_warn","proposed_title":"{title}","top_match_id":"{top_id}","top_match_score":{top_score:.3}}}"#
                                            )
                                        });
                            }
                        }
                    }
                    Ok(_) => {} // no candidates above threshold
                    Err(e) => {
                        // Non-fatal: warn but don't block filing
                        if !quiet {
                            eprintln!("[reserve] similarity check skipped (db error): {e}");
                        }
                    }
                }
            }

            // ── INFRA-1152: pillar-balance guard ─────────────────────────────────
            // Parse proposed pillar from title prefix, then check current
            // open-pickable distribution and warn/block overweighted pillars.
            // Bypass: CHUMP_PILLAR_BALANCE_DISABLE=1 or --force-pillar flag.
            let force_pillar = args.iter().any(|a| a == "--force-pillar");
            let pillar_balance_disabled =
                std::env::var("CHUMP_PILLAR_BALANCE_DISABLE").as_deref() == Ok("1");
            if !pillar_balance_disabled && !force {
                // Extract pillar from title prefix (e.g. "RESILIENT: ..." → "RESILIENT")
                let proposed_pillar = {
                    let prefixes = [
                        "RESILIENT",
                        "EFFECTIVE",
                        "CREDIBLE",
                        "ZERO-WASTE",
                        "MISSION",
                    ];
                    let title_up = title.to_uppercase();
                    prefixes
                        .iter()
                        .find(|&&p| {
                            title_up.starts_with(&format!("{}:", p))
                                    || title_up.starts_with(&format!("{} -", p))
                                    || title_up.starts_with(&format!("{}-", p))
                                    // allow "ZERO-WASTE: " or "ZERO_WASTE: " spellings
                                    || title_up.starts_with(&format!("{}:", p.replace('-', "_")))
                        })
                        .map(|&p| p.to_string())
                };

                if let Some(proposed_pillar) = proposed_pillar {
                    // Build pillar distribution from open gaps with non-TODO ACs
                    let all_open = store.list(Some("open")).unwrap_or_default();
                    let mut pillar_counts: std::collections::HashMap<String, usize> =
                        std::collections::HashMap::new();
                    let mut total_pickable: usize = 0;
                    for g in &all_open {
                        // "Pickable" heuristic: has non-empty ACs that aren't all TODOs
                        let acs = gap_store::parse_json_ac_list(&g.acceptance_criteria);
                        let has_real_acs = !acs.is_empty()
                            && acs.iter().any(|ac| !ac.trim_start().starts_with("TODO"));
                        if !has_real_acs {
                            continue;
                        }
                        total_pickable += 1;
                        // Infer pillar from gap title prefix
                        let g_up = g.title.to_uppercase();
                        let pillar = if g_up.starts_with("EFFECTIVE") {
                            "EFFECTIVE"
                        } else if g_up.starts_with("CREDIBLE") {
                            "CREDIBLE"
                        } else if g_up.starts_with("ZERO-WASTE") || g_up.starts_with("ZERO_WASTE") {
                            "ZERO-WASTE"
                        } else if g_up.starts_with("RESILIENT") {
                            "RESILIENT"
                        } else if g_up.starts_with("MISSION") {
                            "MISSION"
                        } else {
                            "UNTAGGED"
                        };
                        *pillar_counts.entry(pillar.to_string()).or_insert(0) += 1;
                    }

                    if total_pickable > 0 {
                        let proposed_count =
                            *pillar_counts.get(proposed_pillar.as_str()).unwrap_or(&0);
                        // After this reserve, proposed count would be +1
                        let new_count = proposed_count + 1;
                        let new_total = total_pickable + 1;
                        let new_ratio = new_count as f64 / new_total as f64;

                        let warn_threshold: f64 = std::env::var("CHUMP_PILLAR_BALANCE_WARN")
                            .ok()
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(0.35);
                        let block_threshold: f64 = std::env::var("CHUMP_PILLAR_BALANCE_BLOCK")
                            .ok()
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(0.50);

                        // Find under-fed pillars (< 10%)
                        let underfed_threshold = 0.10;
                        let mut underfed: Vec<String> = [
                            "EFFECTIVE",
                            "CREDIBLE",
                            "ZERO-WASTE",
                            "RESILIENT",
                            "MISSION",
                        ]
                        .iter()
                        .filter(|&&p| {
                            let cnt = *pillar_counts.get(p).unwrap_or(&0) as f64;
                            cnt / (total_pickable as f64) < underfed_threshold
                        })
                        .map(|&p| p.to_string())
                        .collect();
                        underfed.retain(|p| p != proposed_pillar.as_str());

                        if new_ratio >= block_threshold && !force_pillar {
                            eprintln!(
                                    "[reserve] PILLAR BLOCKED (INFRA-1152): {} would be {:.0}% of open-pickable gaps (threshold {:.0}%).",
                                    proposed_pillar,
                                    new_ratio * 100.0,
                                    block_threshold * 100.0,
                                );
                            eprintln!(
                                "[reserve]   Current distribution ({} pickable gaps):",
                                total_pickable
                            );
                            let mut sorted_pillars: Vec<_> = pillar_counts.iter().collect();
                            sorted_pillars.sort_by(|a, b| b.1.cmp(a.1));
                            for (p, cnt) in &sorted_pillars {
                                eprintln!(
                                    "[reserve]     {:12} {:3} ({:.0}%)",
                                    p,
                                    cnt,
                                    (**cnt as f64) / (total_pickable as f64) * 100.0
                                );
                            }
                            if !underfed.is_empty() {
                                eprintln!(
                                    "[reserve]   Under-fed pillars (< {:.0}%): {}",
                                    underfed_threshold * 100.0,
                                    underfed.join(", ")
                                );
                            }
                            eprintln!("[reserve]   To override: add --force-pillar, or set CHUMP_PILLAR_BALANCE_DISABLE=1");
                            // Emit ambient event
                            let emit_path = worktree_root.join("scripts/dev/ambient-emit.sh");
                            if emit_path.exists() {
                                let _ = std::process::Command::new("bash")
                                    .arg(&emit_path)
                                    .arg("pillar_balance_block")
                                    .arg(format!("pillar={proposed_pillar}"))
                                    .arg(format!("ratio={new_ratio:.2}"))
                                    .arg(format!("total_pickable={total_pickable}"))
                                    .current_dir(&worktree_root)
                                    .status();
                            }
                            std::process::exit(1);
                        } else if new_ratio >= warn_threshold {
                            eprintln!(
                                    "[reserve] PILLAR WARN (INFRA-1152): {} will be {:.0}% of open-pickable gaps (warn at {:.0}%).",
                                    proposed_pillar,
                                    new_ratio * 100.0,
                                    warn_threshold * 100.0,
                                );
                            eprintln!(
                                "[reserve]   Current distribution ({} pickable gaps):",
                                total_pickable
                            );
                            let mut sorted_pillars: Vec<_> = pillar_counts.iter().collect();
                            sorted_pillars.sort_by(|a, b| b.1.cmp(a.1));
                            for (p, cnt) in &sorted_pillars {
                                eprintln!(
                                    "[reserve]     {:12} {:3} ({:.0}%)",
                                    p,
                                    cnt,
                                    (**cnt as f64) / (total_pickable as f64) * 100.0
                                );
                            }
                            if !underfed.is_empty() {
                                eprintln!(
                                    "[reserve]   Under-fed: {}. Consider filing an {} gap instead.",
                                    underfed.join(", "),
                                    underfed[0]
                                );
                            }
                            // Emit ambient event
                            let emit_path = worktree_root.join("scripts/dev/ambient-emit.sh");
                            if emit_path.exists() {
                                let _ = std::process::Command::new("bash")
                                    .arg(&emit_path)
                                    .arg("pillar_balance_warn")
                                    .arg(format!("pillar={proposed_pillar}"))
                                    .arg(format!("ratio={new_ratio:.2}"))
                                    .arg(format!("total_pickable={total_pickable}"))
                                    .current_dir(&worktree_root)
                                    .status();
                            }
                            // Warn only — do not exit; reserve proceeds
                        }
                    }
                }
            }
            // ── end INFRA-1152 ───────────────────────────────────────────────────

            // ── INFRA-2424: fleet-paused does NOT block gap reserve ─────────────
            // Gaps are inert until claimed. Filing a gap never starts work, burns
            // budget, or causes a waste event. Blocking reserve during slo_breach
            // was the wrong layer — daemons needed CHUMP_IGNORE_WASTE_PAUSE=1 just
            // to file follow-up gaps, which is absurd.
            //
            // The correct enforcement point is chump claim (src/commands/gap.rs or
            // atomic_claim.rs): claim checks fleet-paused and refuses with a clear
            // "fleet is paused" message. Reserve is unconditional.
            //
            // Historical: INFRA-1607 placed the guard here; INFRA-2424 removes it.
            // ── end INFRA-2424 ───────────────────────────────────────────────────

            // ── CREDIBLE-107: evidence gate for P0/P1 RESILIENT/MISSION/CREDIBLE ──
            // Agents routinely file P0/P1 substrate gaps based on 4 lines of source
            // reading and a plausible-sounding theory without empirical verification.
            // This gate makes the evidence a hard requirement for the highest-stakes
            // gaps so the filing artifact carries the diagnosis, not just the theory.
            {
                let enforce_domains = ["RESILIENT", "MISSION", "CREDIBLE"];
                let enforce_priorities = ["P0", "P1"];
                let domain_upper = domain.to_uppercase();
                let needs_evidence = enforce_domains.contains(&domain_upper.as_str())
                    && enforce_priorities.contains(&priority.as_str());

                if needs_evidence {
                    let bypass_env =
                        std::env::var("CHUMP_GAP_RESERVE_NO_EVIDENCE").as_deref() == Ok("1");
                    let evidence_text = reserve_evidence.as_deref().unwrap_or("").trim();

                    if evidence_text.is_empty() && !no_evidence_required && !bypass_env {
                        eprintln!();
                        eprintln!(
                                "chump gap: P0/P1 RESILIENT/MISSION/CREDIBLE gaps require --evidence (per CREDIBLE-106 hardening)."
                            );
                        eprintln!("Evidence must include: COMMAND, OUTPUT, THEORY, ALT.");
                        eprintln!("See docs/process/DURABLE_FIX_DOCTRINE.md §pre-workaround-test.");
                        eprintln!(
                                "Bypass: --no-evidence-required (adds audit trailer), or CHUMP_GAP_RESERVE_NO_EVIDENCE=1."
                            );
                        std::process::exit(1);
                    }

                    if (evidence_text.is_empty()) && (no_evidence_required || bypass_env) {
                        // Bypass path — emit audit event so the pattern is visible.
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let ambient_path = worktree_root.join(".chump-locks").join("ambient.jsonl");
                        let safe_domain = domain.replace(['"', '\\'], "");
                        let safe_title = title.replace(['"', '\\'], "");
                        let bypass_reason = if no_evidence_required {
                            "--no-evidence-required flag"
                        } else {
                            "CHUMP_GAP_RESERVE_NO_EVIDENCE=1"
                        };
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            use std::io::Write;
                            let _ = writeln!(
                                f,
                                r#"{{"ts":"{ts}","kind":"gap_reserved_no_evidence","priority":"{priority}","domain":"{safe_domain}","title":"{safe_title}","bypass_reason":"{bypass_reason}"}}"#
                            );
                        }
                        if !quiet {
                            eprintln!(
                                    "[reserve] WARN: gap_reserved_no_evidence emitted (bypass={bypass_reason})"
                                );
                        }
                    }
                }
            }
            // ── end CREDIBLE-107 evidence gate ──────────────────────────────────────

            // INFRA-216: use reserve_verified so sibling sessions on the
            // same host (shared .chump-locks/) detect and resolve ID
            // collisions within the 200ms verification window.
            let session_id = crate::ambient_stream::env_session_id()
                .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
            if !quiet {
                eprint!("reserving ID...");
            }
            match store.reserve_verified(&domain, &title, &priority, &effort, &session_id) {
                Ok(id) => {
                    if !quiet {
                        eprintln!(" done {id}");
                    }

                    // INFRA-756: set acceptance_criteria if not empty (default obs-ACs or custom)
                    if acceptance_criteria_json != "[]" {
                        let update = gap_store::GapFieldUpdate {
                            acceptance_criteria: Some(acceptance_criteria_json),
                            ..Default::default()
                        };
                        if let Err(e) = store.set_fields(&id, update) {
                            if !quiet {
                                eprintln!("warning: failed to set acceptance_criteria: {e}");
                            }
                        }
                    }

                    // MISSION-008: set outcome_id when --outcome was passed.
                    // Advisory-only FK; never gates gap close.
                    if let Some(ref oid) = reserve_outcome_id {
                        let update = gap_store::GapFieldUpdate {
                            outcome_id: Some(oid.clone()),
                            ..Default::default()
                        };
                        if let Err(e) = store.set_fields(&id, update) {
                            if !quiet {
                                eprintln!("warning: failed to set outcome_id: {e}");
                            }
                        }
                    }

                    // CREDIBLE-107: store evidence when provided (non-empty).
                    if let Some(ref ev) = reserve_evidence {
                        let ev = ev.trim();
                        if !ev.is_empty() {
                            let update = gap_store::GapFieldUpdate {
                                evidence: Some(ev.to_string()),
                                ..Default::default()
                            };
                            if let Err(e) = store.set_fields(&id, update) {
                                if !quiet {
                                    eprintln!("warning: failed to store evidence: {e}");
                                }
                            }
                        }
                    }

                    // MISSION-041: set skills_required external_repo tag when
                    // --external-repo <owner/repo> was passed. This prevents the
                    // data gap that caused BEAST routing to fail (description text
                    // is not parsed by the picker; skills_required is the routing key).
                    if let Some(ref ext_repo) = reserve_external_repo {
                        let tag = format!("external_repo:{ext_repo}");
                        let update = gap_store::GapFieldUpdate {
                            skills_required: Some(tag.clone()),
                            ..Default::default()
                        };
                        if let Err(e) = store.set_fields(&id, update) {
                            if !quiet {
                                eprintln!("warning: failed to set external_repo tag: {e}");
                            }
                        } else if !quiet {
                            eprintln!("[reserve] tagged with {tag}");
                        }
                    }

                    // INFRA-061 (M3): when --stack-on is passed, emit the
                    // bot-merge.sh hint so dispatchers (and humans) know
                    // to chain. Goes to stderr so the bare gap id stays
                    // on stdout (existing scripted callers parse it).
                    if let Some(prev) = stack_on {
                        eprintln!(
                                "[gap reserve] stack hint — ship with: scripts/coord/bot-merge.sh --gap {id} --stack-on {prev} --auto-merge"
                            );
                    }
                    // INFRA-228 (post-INFRA-188 cutover, 2026-05-02):
                    // also write the per-file YAML mirror at
                    // docs/gaps/<ID>.yaml. Without this, every
                    // `chump gap reserve` call required a follow-up
                    // hand-edit (or CHUMP_ALLOW_UNREGISTERED_GAP=1
                    // bypass) before bot-merge.sh's gap-preflight.sh
                    // would let the work ship — observed mid-flight on
                    // INFRA-227 itself. Best-effort: SQLite (state.db)
                    // is canonical, so a write failure is logged but
                    // doesn't fail the reserve.
                    // INFRA-247: write to the linked worktree, not the main checkout.
                    // INFRA-498: per-file YAML mirrors deleted from the
                    // repo as redundant with .chump/state.sql. We keep
                    // the dump_per_file_single call gated on directory
                    // existence — if the operator re-creates docs/gaps/
                    // (e.g. for offline browsing), the write resumes.
                    // Default: directory doesn't exist, write is a no-op.
                    if why {
                        eprintln!(
                                "reserved {id} — why: collision-free atomic ID pick from domain {domain} pool (INFRA-216 verification window)"
                            );
                    }
                    // INFRA-1428: write YAML to MAIN repo's docs/gaps/, not the current
                    // linked worktree. `repo_root` resolves via CHUMP_REPO / CHUMP_HOME /
                    // git common-dir to the main checkout. Writing to `worktree_root` (the
                    // previous behaviour) means the YAML is only visible in that one
                    // linked worktree; other workers and origin/main never see it
                    // (#2063 cascade pattern: 840 LOC of cockpit work + 2 rescue PRs lost).
                    // Fallback to worktree_root only if main repo's docs/gaps/ doesn't
                    // exist (detached operator, fresh clone, etc.).
                    let main_gaps_dir = repo_root.join("docs").join("gaps");
                    let wt_gaps_dir = worktree_root.join("docs").join("gaps");
                    let (per_file_dir, yaml_git_root, yaml_target) = if main_gaps_dir.exists() {
                        (main_gaps_dir, repo_root.clone(), "main_repo")
                    } else if wt_gaps_dir.exists() {
                        eprintln!(
                                "[reserve] WARNING (INFRA-1428): main repo docs/gaps/ not found at {}; falling back to linked worktree. Set CHUMP_REPO/CHUMP_HOME to avoid this.",
                                repo_root.display()
                            );
                        (wt_gaps_dir, worktree_root.clone(), "worktree_fallback")
                    } else {
                        // No-op path. state.db is canonical, state.sql is
                        // the tracked mirror. Use 'chump gap show <ID>'
                        // for per-gap human-readable rendering.
                        if json_out {
                            println!("{{\"id\":\"{id}\",\"yaml_path\":\"\"}}");
                        } else {
                            println!("{}", id);
                        }
                        return Ok(());
                    };
                    match store.dump_per_file_single(&id, &per_file_dir) {
                        Ok(true) => {
                            let yaml_path = per_file_dir.join(format!("{id}.yaml"));
                            eprintln!("wrote {}", yaml_path.display());
                            write_yaml_op_marker(&worktree_root, "reserve");

                            // INFRA-484: auto-stage the YAML mirror so it
                            // rides along on the next commit. Pre-fix:
                            // chump gap reserve wrote the YAML untracked,
                            // so linked worktrees (fleet workers) created
                            // from origin/main never saw it. The 2026-05-05
                            // sonnet fleet wedge is the canonical incident:
                            // workers got "(gap YAML not found)" prompts,
                            // had to discover from state.db (also not in
                            // linked worktree), got stuck, and burned 600s
                            // × N cycles to 0-byte output.
                            //
                            // Staging makes the YAML part of the next PR's
                            // diff so origin/main and all linked worktrees
                            // pick it up.
                            //
                            // Best-effort: warns on failure but never
                            // blocks the reserve. Bypass with
                            // CHUMP_RESERVE_NO_AUTOSTAGE=1 for genuine
                            // detached / read-only operator workflows.
                            // INFRA-1354: emit warning when git add fails
                            // so operators notice the staging gap instead
                            // of discovering it via orphan-PR-closer.
                            if std::env::var("CHUMP_RESERVE_NO_AUTOSTAGE").as_deref() != Ok("1") {
                                // INFRA-1428: git -C points at yaml_git_root (main repo or
                                // worktree fallback) so the YAML is staged in the right
                                // index, not the linked worktree's separate index.
                                match std::process::Command::new("git")
                                    .arg("-C")
                                    .arg(&yaml_git_root)
                                    .arg("add")
                                    .arg(&yaml_path)
                                    .status()
                                {
                                    Ok(s) if s.success() => {
                                        if !quiet {
                                            eprintln!("[reserve] staged {}", yaml_path.display());
                                        }
                                    }
                                    Ok(s) => {
                                        eprintln!(
                                                "[reserve] warning: git add {} exited {}; yaml is written but unstaged — commit manually to avoid orphan-PR-closer killing in-flight PRs",
                                                yaml_path.display(), s
                                            );
                                    }
                                    Err(e) => {
                                        eprintln!(
                                                "[reserve] warning: git add {} failed ({e}); yaml is written but unstaged — commit manually to avoid orphan-PR-closer killing in-flight PRs",
                                                yaml_path.display()
                                            );
                                    }
                                }
                            }
                            // INFRA-1428: emit gap_yaml_written so fleet-brief and the
                            // orphan-PR-closer can see where the YAML landed (main_repo vs
                            // worktree_fallback). Direct append; the EmitArgs path would
                            // double-resolve repo_root here.
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            let yaml_event = format!(
                                    "{{\"ts\":\"{ts}\",\"kind\":\"gap_yaml_written\",\"gap_id\":\"{id}\",\"path\":\"{}\",\"target\":\"{yaml_target}\"}}\n",
                                    yaml_path.display()
                                );
                            let ambient_path =
                                worktree_root.join(".chump-locks").join("ambient.jsonl");
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .create(true)
                                .append(true)
                                .open(&ambient_path)
                            {
                                use std::io::Write;
                                let _ = f.write_all(yaml_event.as_bytes());
                            }
                        }
                        Ok(false) => {} // no-op write
                        Err(e) => {
                            eprintln!("warning: dump-per-file write failed for {id}: {e}")
                        }
                    }
                    // INFRA-2177: --json emits {id, yaml_path} for operator scripts.
                    if json_out {
                        let yaml_path_str = per_file_dir
                            .join(format!("{id}.yaml"))
                            .display()
                            .to_string()
                            .replace('\\', "/");
                        println!("{{\"id\":\"{id}\",\"yaml_path\":\"{yaml_path_str}\"}}");
                    } else {
                        println!("{}", id);
                    }
                    return Ok(());
                }
                Err(e) => {
                    if !quiet {
                        eprintln!(); // end the "reserving ID..." line
                    }
                    eprintln!("chump gap reserve: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "claim" => {
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap claim <GAP-ID>");
                std::process::exit(2);
            });
            let force = args.iter().any(|a| a == "--force");
            let why = args.iter().any(|a| a == "--why");

            // FLEET-029: ambient glance before claiming
            if !force && std::env::var("FLEET_029_AMBIENT_GLANCE_SKIP").is_err() {
                use std::process::Command;
                if let Ok(Some(gap_row)) = store.get(&gap_id) {
                    let glance_result = Command::new("bash")
                        .arg("scripts/coord/chump-ambient-glance.sh")
                        .arg("--domain")
                        .arg(&gap_row.domain)
                        .arg("--title")
                        .arg(&gap_row.title)
                        .arg("--check-prs")
                        .current_dir(repo_path::repo_root())
                        .status();

                    if let Ok(status) = glance_result {
                        if !status.success() {
                            eprintln!();
                            eprintln!("[claim] Potential overlap detected for {gap_id}. Pass --force to proceed anyway.");
                            std::process::exit(1);
                        }
                    }
                }
            }

            let session_id = flag("--session")
                .or_else(|| crate::ambient_stream::env_session_id())
                .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
            // INFRA-1032: derive worktree from CWD basename when --worktree absent/empty
            let worktree = flag("--worktree")
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| {
                    std::env::current_dir()
                        .ok()
                        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
                        .unwrap_or_default()
                });
            let ttl: i64 = flag("--ttl").and_then(|s| s.parse().ok()).unwrap_or(3600);
            match store.claim(&gap_id, &session_id, &worktree, ttl) {
                Ok(()) => {
                    println!("claimed {} for session {}", gap_id, session_id);
                    if why {
                        eprintln!(
                                "claimed {gap_id} — why: gap open and unclaimed, session={session_id}, TTL={ttl}s"
                            );
                    }
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap claim: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "preflight" => {
            // INFRA-1238: trap --help before positional validation.
            if args
                .iter()
                .skip(3)
                .any(|a| matches!(a.as_str(), "--help" | "-h"))
            {
                println!(
                    "Usage: chump gap preflight <GAP-ID>\n\n\
                         Check whether a gap is pickable (open, unclaimed, in state.db).\n\
                         Exits 0 if pickable, 1 if blocked, 2 on usage error."
                );
                return Ok(());
            }
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                println!("Usage: chump gap preflight <GAP-ID>");
                std::process::exit(2);
            });
            match store.preflight(&gap_id) {
                Ok(gap_store::PreflightResult::Available) => {
                    println!("[preflight] OK {} — open and unclaimed.", gap_id);
                    // INFRA-1886: soft pre-claim suggestion. If target
                    // is not P0 and CHUMP_PREFLIGHT_NO_SUGGEST is unset,
                    // surface up to 3 higher-priority unclaimed gaps as
                    // advisory. Doesn't change exit code; just nudges
                    // picker toward what's actually starved.
                    if std::env::var("CHUMP_PREFLIGHT_NO_SUGGEST").as_deref() != Ok("1") {
                        print_priority_hint(&store, &gap_id, &repo_root);
                    }
                    return Ok(());
                }
                Ok(gap_store::PreflightResult::Done) => {
                    eprintln!("[preflight] FAIL {} — already done.", gap_id);
                    std::process::exit(1);
                }
                Ok(gap_store::PreflightResult::Claimed(s)) => {
                    eprintln!(
                        "[preflight] FAIL {} — live-claimed by session {}.",
                        gap_id, s
                    );
                    std::process::exit(1);
                }
                Ok(gap_store::PreflightResult::NotFound) => {
                    eprintln!("[preflight] WARN {} — not found in state.db (run `chump gap import` first).", gap_id);
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap preflight: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "ship" => {
            // INFRA-1238: trap --help before positional validation.
            if args
                .iter()
                .skip(3)
                .any(|a| matches!(a.as_str(), "--help" | "-h"))
            {
                println!(
                        "Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N] [--session ID]\n\n\
                         Mark a gap as done. Updates state.db (canonical), optionally mirrors to YAML.\n\n\
                         Options:\n  \
                           --update-yaml      Mirror status flip to docs/gaps/<ID>.yaml (destructive bulk-YAML; INFRA-825 staleness guard applies)\n  \
                           --closed-pr N      Stamp PR number on the row (required by INFRA-107 closed_pr integrity guard for YAML mirror)\n  \
                           --session ID       Session ID to record on the ship event (default derived)\n  \
                           --why              Print explanation alongside the flip\n  \
                           -h, --help         Show this help"
                    );
                return Ok(());
            }
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                eprintln!("Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N]");
                std::process::exit(2);
            });
            let session_id = flag("--session")
                .or_else(|| crate::ambient_stream::env_session_id())
                .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
            let update_yaml = args.iter().any(|a| a == "--update-yaml");
            let why = args.iter().any(|a| a == "--why");
            // INFRA-156: --closed-pr N stamps the closure PR number on the
            // row at ship time. Required by the INFRA-107 closed_pr
            // integrity guard for any status:done flip in YAML; passing
            // it here keeps state.db and gaps.yaml in agreement.
            let closed_pr: Option<i64> = match flag("--closed-pr") {
                Some(s) => match s.trim().parse::<i64>() {
                    Ok(n) if n > 0 => Some(n),
                    _ => {
                        eprintln!(
                            "chump gap ship: --closed-pr expects a positive integer (got {:?})",
                            s
                        );
                        std::process::exit(2);
                    }
                },
                None => None,
            };
            // INFRA-1007: staleness gate — belt-and-suspenders for the CLAUDE.md
            // "rebase if > 15 commits behind" rule. bot-merge.sh has this gate for
            // the push path; the manual `chump gap ship` path needs the same check.
            let stale_threshold: u64 = std::env::var("CHUMP_GAP_SHIP_STALE_THRESHOLD")
                .ok()
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or(15);
            if std::env::var("CHUMP_GAP_SHIP_SKIP_STALE_CHECK").as_deref() != Ok("1") {
                let _ = std::process::Command::new("git")
                    .args(["fetch", "origin", "main", "--quiet"])
                    .current_dir(&worktree_root)
                    .stderr(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .status();
                let behind: u64 = std::process::Command::new("git")
                    .args(["rev-list", "--count", "HEAD..origin/main"])
                    .current_dir(&worktree_root)
                    .output()
                    .ok()
                    .filter(|o| o.status.success())
                    .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
                    .unwrap_or(0);
                if behind > stale_threshold {
                    eprintln!(
                        "chump gap ship: branch is {behind} commits behind origin/main \
                             (threshold {stale_threshold}). Rebase before shipping."
                    );
                    eprintln!("  Recover: git fetch && git rebase origin/main, then retry.");
                    eprintln!("  Override: CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 chump gap ship ...");
                    let branch = std::process::Command::new("git")
                        .args(["rev-parse", "--abbrev-ref", "HEAD"])
                        .current_dir(&worktree_root)
                        .output()
                        .ok()
                        .filter(|o| o.status.success())
                        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                        .unwrap_or_else(|| "unknown".to_string());
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
                    let _ = std::fs::create_dir_all(amb.parent().unwrap_or(&repo_root));
                    let event = format!(
                        "{{\"ts\":\"{ts}\",\"kind\":\"stale_branch_blocked\",\
                             \"branch\":\"{branch}\",\"behind\":{behind},\
                             \"threshold\":{stale_threshold},\"phase\":\"gap-ship\"}}\n"
                    );
                    use std::io::Write as _;
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&amb)
                    {
                        let _ = f.write_all(event.as_bytes());
                    }
                    std::process::exit(3);
                }
            }
            match store.ship(&gap_id, &session_id, closed_pr) {
                Ok(()) => {
                    println!("shipped {}", gap_id);
                    if why {
                        let pr_note = closed_pr
                            .map(|n| format!(", closed-pr=#{n}"))
                            .unwrap_or_default();
                        eprintln!(
                                "shipped {gap_id} — why: status flipped to done{pr_note}, session={session_id}"
                            );
                    }
                    // INFRA-1144: atomically close orphan PRs for this gap
                    // (complements INFRA-1139 sweeper). Emits orphan_pr_closed_at_ship
                    // events for each closure.
                    if let Ok(closed_prs) = store.close_orphan_prs(&gap_id, closed_pr, &repo_root) {
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        for (pr_num, reason) in closed_prs {
                            let closed_pr_str =
                                closed_pr.map(|n| n.to_string()).unwrap_or_default();
                            let event = format!(
                                    "{{\"ts\":\"{ts}\",\"kind\":\"orphan_pr_closed_at_ship\",\
                                     \"gap\":\"{gap_id}\",\"pr\":{pr_num},\"ship_pr\":{closed_pr_str},\
                                     \"reason\":\"{reason}\"}}\n"
                                );
                            let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");
                            let _ = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_log)
                                .and_then(|mut f| {
                                    use std::io::Write;
                                    f.write_all(event.as_bytes())
                                });
                            if why {
                                eprintln!("  closed orphan PR #{pr_num} ({reason})");
                            }
                        }
                    }
                    // INFRA-1200: write-ahead log cleanup. On ship, stamp
                    // .chump-plans/<gap-id>/SHIPPED_AT so the 7-day GC pass
                    // can find and remove stale patch directories. Also sweep
                    // any existing directories already past the grace period.
                    {
                        let plans_base = repo_root.join(".chump-plans");
                        let gap_plans = plans_base.join(&gap_id);
                        if gap_plans.is_dir() {
                            let marker = gap_plans.join("SHIPPED_AT");
                            let ts = unix_ts().to_string();
                            let _ = std::fs::write(&marker, &ts);
                        }
                        // GC: remove any .chump-plans/<dir>/ with SHIPPED_AT > 7d old.
                        const GRACE_SECS: u64 = 7 * 24 * 3600;
                        let now_ts = unix_ts();
                        let mut removed_count: u64 = 0;
                        if let Ok(rd) = std::fs::read_dir(&plans_base) {
                            for entry in rd.flatten() {
                                let marker = entry.path().join("SHIPPED_AT");
                                if let Ok(contents) = std::fs::read_to_string(&marker) {
                                    if let Ok(ship_ts) = contents.trim().parse::<u64>() {
                                        if now_ts.saturating_sub(ship_ts) > GRACE_SECS
                                            && std::fs::remove_dir_all(entry.path()).is_ok()
                                        {
                                            removed_count += 1;
                                        }
                                    }
                                }
                            }
                        }
                        if removed_count > 0 {
                            let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");
                            let event = format!(
                                "{{\"ts\":\"{}\",\"kind\":\"chump_plans_gc\",\
                                     \"gap\":\"{gap_id}\",\"removed_count\":{removed_count}}}\n",
                                chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ"),
                            );
                            let _ = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_log)
                                .and_then(|mut f| {
                                    use std::io::Write;
                                    f.write_all(event.as_bytes())
                                });
                        }
                    }
                    // INFRA-994: auto-close orphaned PRs whose title still
                    // references this gap ID. Runs close-superseded-prs.sh
                    // in the background so it doesn't block the ship command.
                    // CHUMP_SKIP_SUPERSEDED_CLOSE=1 disables (e.g. in tests
                    // that don't want real gh calls).
                    if std::env::var("CHUMP_SKIP_SUPERSEDED_CLOSE").as_deref() != Ok("1") {
                        let helper = worktree_root
                            .join("scripts")
                            .join("coord")
                            .join("close-superseded-prs.sh");
                        if helper.exists() {
                            let _ = std::process::Command::new("bash")
                                .arg(&helper)
                                .arg(&gap_id)
                                .current_dir(&worktree_root)
                                .spawn(); // fire-and-forget
                        }
                    }
                    if update_yaml {
                        // INFRA-148: warn if this binary predates the most recent
                        // gap_store-affecting commit on the repo's HEAD before mutating
                        // the YAML mirror. Pre-INFRA-147 binaries silently stripped the
                        // meta: preamble (~20k-line corruption observed 2026-04-27); a
                        // fresh build catches that and similar future serialization
                        // changes.
                        //
                        // INFRA-825 (2026-05-11): upgraded from warn to hard-fail
                        // for this single-gap path too — PR #1444 silently reverted
                        // META-044 because a stale binary regenerated YAMLs from a
                        // stale state.db. CHUMP_ALLOW_STALE_DESTRUCTIVE=1 is the
                        // audited override; otherwise the operation refuses.
                        match version::fail_if_stale_for_destructive(
                            &repo_root,
                            "gap ship --update-yaml",
                        ) {
                            version::DestructiveStalenessOutcome::Refuse => {
                                return Err(anyhow::anyhow!(
                                        "refused: chump gap ship --update-yaml on stale binary (INFRA-825). \
                                         Rebuild with `cargo install --path . --bin chump --force` \
                                         or override with CHUMP_ALLOW_STALE_DESTRUCTIVE=1."
                                    ));
                            }
                            version::DestructiveStalenessOutcome::Proceed
                            | version::DestructiveStalenessOutcome::OverrideAccepted => {}
                        }
                        // INFRA-229 (post-INFRA-188 cutover, 2026-05-02):
                        // write the per-file YAML mirror at
                        // docs/gaps/<ID>.yaml instead of the deleted
                        // monolithic docs/gaps.yaml. The pre-INFRA-188
                        // path here would have silently re-created the
                        // monolithic file on every successful ship,
                        // resurrecting the very file INFRA-188 deleted.
                        // Behavior change: callers that pass
                        // `--update-yaml` now get a single per-file
                        // write, not a full-registry regen.
                        // INFRA-247: write to the linked worktree, not the main checkout.
                        // INFRA-498: gated on directory existence — when
                        // docs/gaps/ is absent (the post-deletion state),
                        // this becomes a no-op. state.db is canonical.
                        let per_file_dir = worktree_root.join("docs").join("gaps");
                        if !per_file_dir.exists() {
                            return Ok(());
                        }
                        match store.dump_per_file_single(&gap_id, &per_file_dir) {
                            Ok(true) => {
                                let yaml_path = per_file_dir.join(format!("{gap_id}.yaml"));
                                eprintln!("wrote {}", yaml_path.display());
                                write_yaml_op_marker(&worktree_root, "ship");

                                // INFRA-486: same auto-stage pattern as
                                // INFRA-484 (gap reserve). The YAML mirror
                                // regenerated by ship --update-yaml needs
                                // to be staged so it rides along with the
                                // close commit. Pre-fix: bot-merge.sh's
                                // auto-close path manually `git add`s it
                                // separately, but the manual recovery
                                // path (operator runs ship by hand after
                                // bot-merge wedge) leaves it untracked.
                                //
                                // Bypass: CHUMP_SHIP_NO_AUTOSTAGE=1.
                                if std::env::var("CHUMP_SHIP_NO_AUTOSTAGE").as_deref() != Ok("1") {
                                    let _ = std::process::Command::new("git")
                                        .arg("-C")
                                        .arg(&worktree_root)
                                        .arg("add")
                                        .arg(&yaml_path)
                                        .stderr(std::process::Stdio::null())
                                        .stdout(std::process::Stdio::null())
                                        .status();
                                }
                            }
                            Ok(false) => {} // no-op write — content unchanged
                            Err(e) => {
                                eprintln!("warning: dump-per-file write failed: {e}")
                            }
                        }
                    }
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap ship: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "set" | "update" | "modify" | "edit" | "change" => {
            // INFRA-1036: 'set' and natural-language aliases for gap mutation.
            // CREDIBLE-016: unknown-flag detection — if the positional GAP-ID slot
            // starts with "--", the operator forgot the ID or passed a bad flag.
            let gap_set_usage = || {
                eprintln!(
                    "Usage: chump gap set <GAP-ID> [--title T] [--description D] [--priority P]"
                );
                eprintln!("                          [--effort E] [--status S] [--notes N] [--add-note TEXT]");
                eprintln!("                          [--source-doc S] [--opened-date D] [--closed-date D]");
                eprintln!("                          [--closed-pr N] [--acceptance-criteria BULLET ...] [--depends-on \"X,Y\"]");
                eprintln!(
                    "                          [--skills-required SKS] [--preferred-backend BE]"
                );
                eprintln!("                          [--preferred-machine MACH] [--estimated-minutes MIN] [--required-model MODEL]");
                eprintln!("                          [--outcome OUTCOME-ID]  (MISSION-008: advisory FK, never gates close)");
                eprintln!("  Note: --add-note TEXT appends '[ISO-timestamp] TEXT' to existing notes; --notes OVERWRITES.");
                eprintln!("  INFRA-1799: --acceptance-criteria accepts repeated flags — one AC bullet per occurrence.");
                eprintln!("              Example (preferred, no escape needed for pipes):");
                eprintln!("                chump gap set X --acceptance-criteria 'recipient <gap-id|session-id|all-opus> resolves'\\");
                eprintln!("                              --acceptance-criteria 'second bullet'");
                eprintln!("              Legacy single-flag delimiter form (deprecated, emits ambient warning):");
                eprintln!("                chump gap set X --acceptance-criteria 'a|b|c'");
            };
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                gap_set_usage();
                std::process::exit(2);
            });
            if gap_id.starts_with("--") {
                eprintln!(
                    "Error: unknown flag {:?}. Did you forget the GAP-ID?",
                    gap_id
                );
                gap_set_usage();
                std::process::exit(2);
            }
            // INFRA-2022: support positional `<field_name> <value>` as an alias
            // for `--<flag-name> <value>`. Operators naturally type:
            //   chump gap set INFRA-NNN acceptance_criteria "text"
            // but the parser only recognises `--acceptance-criteria`. Without
            // this normalisation the positional field name is silently ignored,
            // leaving whatever placeholder the gap was reserved with intact —
            // a footgun that bit the wizard 6+ times on 2026-05-25.
            //
            // Strategy: build a mutable local args shadow so the existing
            // `flag(...)` closure (which captures the outer immutable `args`)
            // is NOT affected. We then re-define a local `flag_local` that
            // reads from the mutable shadow.  Only the `gap set` arm needs
            // this — other subcommands stay on the shared closure.
            //
            // Supported positional aliases (snake_case or kebab-case):
            //   acceptance_criteria / acceptance-criteria → --acceptance-criteria
            //   title                                     → --title
            //   description                               → --description
            //   priority                                  → --priority
            //   effort                                    → --effort
            //   status                                    → --status
            //   notes                                     → --notes
            //   depends_on / depends-on                   → --depends-on
            //   source_doc / source-doc                   → --source-doc
            //   opened_date / opened-date                 → --opened-date
            //   closed_date / closed-date                 → --closed-date
            //   closed_pr / closed-pr                     → --closed-pr
            //   skills_required / skills-required         → --skills-required
            //   preferred_backend / preferred-backend     → --preferred-backend
            //   preferred_machine / preferred-machine     → --preferred-machine
            //   estimated_minutes / estimated-minutes     → --estimated-minutes
            //   required_model / required-model           → --required-model
            let positional_field_map: &[(&str, &str)] = &[
                ("acceptance_criteria", "--acceptance-criteria"),
                ("acceptance-criteria", "--acceptance-criteria"),
                ("title", "--title"),
                ("description", "--description"),
                ("priority", "--priority"),
                ("effort", "--effort"),
                ("status", "--status"),
                ("notes", "--notes"),
                ("depends_on", "--depends-on"),
                ("depends-on", "--depends-on"),
                ("source_doc", "--source-doc"),
                ("source-doc", "--source-doc"),
                ("opened_date", "--opened-date"),
                ("opened-date", "--opened-date"),
                ("closed_date", "--closed-date"),
                ("closed-date", "--closed-date"),
                ("closed_pr", "--closed-pr"),
                ("closed-pr", "--closed-pr"),
                ("skills_required", "--skills-required"),
                ("skills-required", "--skills-required"),
                ("preferred_backend", "--preferred-backend"),
                ("preferred-backend", "--preferred-backend"),
                ("preferred_machine", "--preferred-machine"),
                ("preferred-machine", "--preferred-machine"),
                ("estimated_minutes", "--estimated-minutes"),
                ("estimated-minutes", "--estimated-minutes"),
                ("required_model", "--required-model"),
                ("required-model", "--required-model"),
                ("outcome_id", "--outcome"),
                ("outcome-id", "--outcome"),
            ];
            // Normalise: rewrite bare positional field name at args[4] to its
            // canonical `--flag` form in a local mutable shadow. We only apply
            // this when no `--<flag>` args are already present (to avoid
            // ambiguity in mixed usage). An unrecognised bare positional at
            // args[4] with a trailing value at args[5] is an error (typo guard).
            let mut args_local: Vec<String> = args.to_vec();
            let has_existing_flags = args_local[4..].iter().any(|a| a.starts_with("--"));
            if !has_existing_flags {
                if let Some(field_arg) = args_local.get(4).cloned() {
                    if let Some((_, flag_name)) = positional_field_map
                        .iter()
                        .find(|(alias, _)| *alias == field_arg.as_str())
                    {
                        // Rewrite bare field name to canonical --flag form.
                        // The value at args[5] stays put and is picked up by
                        // flag_local() automatically.
                        args_local[4] = flag_name.to_string();
                    } else if !field_arg.is_empty()
                        && args_local.get(5).is_some()
                        && !field_arg.starts_with('-')
                    {
                        // Unknown bare positional with a trailing value — typo.
                        // Error out so the operator knows the update was lost.
                        eprintln!(
                            "chump gap set: unrecognised positional field name {:?}. \
                                 Use --<flag> form (see usage above).",
                            field_arg
                        );
                        gap_set_usage();
                        std::process::exit(2);
                    }
                }
            }
            // Local flag() that reads from args_local (the normalised shadow).
            let flag_local = |name: &str| -> Option<String> {
                args_local
                    .iter()
                    .position(|a| a == name)
                    .and_then(|i| args_local.get(i + 1))
                    .cloned()
            };
            // INFRA-1799: --acceptance-criteria parsing has two forms:
            //   (preferred) repeated `--acceptance-criteria BULLET` flags
            //               → each value is one AC bullet, NO pipe-splitting,
            //                 so literal '|' in a bullet survives intact.
            //   (legacy)    single `--acceptance-criteria "a|b|c"` value
            //               → pipe-split into multiple bullets, with
            //                 kind=chump_gap_set_legacy_delim emitted so the
            //                 curator can migrate callers gradually.
            // Backward compat: a single occurrence with no pipe is identical
            // under both forms (one bullet either way), so no warning fires.
            let ac_flag_values: Vec<String> = {
                let mut vals = Vec::new();
                let mut i = 0usize;
                while i < args_local.len() {
                    if args_local[i] == "--acceptance-criteria" {
                        if let Some(v) = args_local.get(i + 1) {
                            vals.push(v.clone());
                            i += 2;
                            continue;
                        }
                    }
                    i += 1;
                }
                vals
            };
            let acceptance_criteria = if ac_flag_values.is_empty() {
                None
            } else if ac_flag_values.len() == 1 && ac_flag_values[0].contains('|') {
                // Legacy single-flag delimited form — split + emit deprecation event.
                let raw = &ac_flag_values[0];
                let parts: Vec<&str> = raw.split('|').collect();
                let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                    kind: "chump_gap_set_legacy_delim".to_string(),
                    source: Some("chump_gap_set".to_string()),
                    gap: Some(gap_id.clone()),
                    fields: vec![
                        ("bullet_count".to_string(), parts.len().to_string()),
                        (
                            "note".to_string(),
                            "use repeated --acceptance-criteria flags to avoid pipe-split"
                                .to_string(),
                        ),
                    ],
                    ..Default::default()
                });
                Some(serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into()))
            } else {
                // Repeated-flag form (or a single value with no pipe): each
                // flag occurrence is exactly one bullet, no splitting.
                Some(serde_json::to_string(&ac_flag_values).unwrap_or_else(|_| "[]".into()))
            };
            let depends_on = flag_local("--depends-on").map(|raw| {
                let parts: Vec<&str> = raw
                    .split(',')
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .collect();
                serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
            });
            // INFRA-156: --closed-pr N as Option<i64>. Empty string clears
            // (Some(0) is an explicit "unset" signal we reject); positive
            // integer sets. The INFRA-107 guard rejects status:done with
            // missing/non-numeric closed_pr at commit time, so this is the
            // canonical way to satisfy it from the CLI rather than
            // hand-editing YAML.
            let closed_pr: Option<i64> = match flag_local("--closed-pr") {
                Some(s) => match s.trim().parse::<i64>() {
                    Ok(n) if n > 0 => Some(n),
                    _ => {
                        eprintln!(
                            "chump gap set: --closed-pr expects a positive integer (got {:?})",
                            s
                        );
                        std::process::exit(2);
                    }
                },
                None => None,
            };
            // EFFECTIVE-020: --add-note appends a timestamped entry to the
            // existing notes without overwriting. Format per entry:
            //   "[YYYY-MM-DDTHH:MM:SSZ] <text>"
            // Multiple notes are newline-separated. The --notes flag still
            // overwrites the entire field; --add-note only appends.
            let notes: Option<String> = if let Some(add_text) = flag_local("--add-note") {
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let new_entry = format!("[{}] {}", ts, add_text);
                // Fetch current notes and append.
                let existing = match store.get(&gap_id) {
                    Ok(Some(g)) if !g.notes.is_empty() => g.notes,
                    _ => String::new(),
                };
                let combined = if existing.is_empty() {
                    new_entry
                } else {
                    format!("{}\n{}", existing, new_entry)
                };
                Some(combined)
            } else {
                flag_local("--notes")
            };

            let update = gap_store::GapFieldUpdate {
                title: flag_local("--title"),
                description: flag_local("--description"),
                priority: flag_local("--priority"),
                effort: flag_local("--effort"),
                status: flag_local("--status"),
                acceptance_criteria,
                depends_on,
                notes,
                source_doc: flag_local("--source-doc"),
                opened_date: flag_local("--opened-date"),
                closed_date: flag_local("--closed-date"),
                closed_pr,
                skills_required: flag_local("--skills-required"),
                preferred_backend: flag_local("--preferred-backend"),
                preferred_machine: flag_local("--preferred-machine"),
                estimated_minutes: flag_local("--estimated-minutes"),
                required_model: flag_local("--required-model"),
                // MISSION-008: advisory FK to outcomes table; never gates close.
                outcome_id: flag_local("--outcome"),
                // CREDIBLE-107: evidence blob for P0/P1 RESILIENT/MISSION/CREDIBLE gaps.
                evidence: flag_local("--evidence"),
            };
            match store.set_fields(&gap_id, update) {
                Ok(()) => {
                    println!("updated {}", gap_id);
                    // INFRA-470: state.db is canonical; the per-file YAML
                    // at docs/gaps/<ID>.yaml is a render of the DB. Without
                    // an auto-regen here, `chump gap set --notes "X"`
                    // mutates only state.db and leaves docs/gaps/<ID>.yaml
                    // stale — the same drift class INFRA-460 fixed for
                    // status propagation on import. Mirror the `ship`
                    // path: write the per-file YAML and stamp the
                    // .last-yaml-op freshness marker so the pre-commit
                    // raw-YAML guard recognizes the regenerated file as
                    // canonical.
                    let _ = version::warn_if_stale_for_gap_mutation(&repo_root);
                    // INFRA-498: gated on directory existence — no-op
                    // when docs/gaps/ is absent (post-deletion state).
                    let per_file_dir = worktree_root.join("docs").join("gaps");
                    if !per_file_dir.exists() {
                        return Ok(());
                    }
                    match store.dump_per_file_single(&gap_id, &per_file_dir) {
                        Ok(true) => {
                            eprintln!(
                                "wrote {}",
                                per_file_dir.join(format!("{gap_id}.yaml")).display()
                            );
                            write_yaml_op_marker(&worktree_root, "set");
                        }
                        Ok(false) => {
                            // Content unchanged — still stamp the marker
                            // so a follow-up `git add docs/gaps/<ID>.yaml`
                            // within 5 min for an unrelated reason isn't
                            // blocked by the raw-YAML guard.
                            write_yaml_op_marker(&worktree_root, "set");
                        }
                        Err(e) => {
                            eprintln!("warning: dump-per-file write failed: {e}")
                        }
                    }
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap set: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "dump" => {
            let out_path = flag("--out");
            // INFRA-188 v0 (2026-05-02): --per-file emits one file per
            // gap at <out_dir>/<ID>.yaml instead of a monolithic dump.
            // --out-dir overrides the default `docs/gaps/`.
            let per_file = args.iter().any(|a| a == "--per-file");
            let out_dir_flag = flag("--out-dir");

            // INFRA-148 + INFRA-825 (2026-05-11): for --per-file (true
            // bulk regen — writes every gap's YAML) hard-fail if the
            // binary is stale. PR #1444's silent META-044 revert was
            // caused by exactly this code path running with a stale
            // binary. --out PATH (single file dump) stays at warn-only
            // since it doesn't bulk-regen the gap registry.
            if out_path.is_some() && !per_file {
                let _ = version::warn_if_stale_for_gap_mutation(&repo_root);
            }
            if per_file {
                match version::fail_if_stale_for_destructive(&repo_root, "gap dump --per-file") {
                    version::DestructiveStalenessOutcome::Refuse => {
                        return Err(anyhow::anyhow!(
                            "refused: chump gap dump --per-file on stale binary (INFRA-825). \
                                 Rebuild with `cargo install --path . --bin chump --force` \
                                 or override with CHUMP_ALLOW_STALE_DESTRUCTIVE=1."
                        ));
                    }
                    version::DestructiveStalenessOutcome::Proceed
                    | version::DestructiveStalenessOutcome::OverrideAccepted => {}
                }
            }

            // ── INFRA-188 v0: --per-file path ────────────────────────────
            if per_file {
                let dir_str = out_dir_flag.unwrap_or_else(|| "docs/gaps".to_string());
                let dir = std::path::PathBuf::from(&dir_str);
                // INFRA-247: relative path resolves under the linked worktree,
                // not the main checkout. Absolute path is honored verbatim.
                let dir_abs = if dir.is_absolute() {
                    dir
                } else {
                    worktree_root.join(dir)
                };
                match store.dump_per_file(&dir_abs) {
                    Ok((written, skipped)) => {
                        eprintln!(
                            "wrote {} file(s) to {} ({} unchanged)",
                            written,
                            dir_abs.display(),
                            skipped
                        );
                        // INFRA-094 marker: this dir is also a canonical
                        // chump-CLI yaml op surface.
                        write_yaml_op_marker(&worktree_root, "dump --per-file");
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap dump --per-file: {e:#}");
                        std::process::exit(1);
                    }
                }
            }

            // INFRA-147: when --out points at an existing file, preserve its
            // meta: preamble. For stdout or new files there is no source to
            // preserve from — bare dump is correct.
            let result = match out_path.as_deref() {
                Some(p) => match std::fs::read_to_string(p) {
                    Ok(source) => store.dump_yaml_with_meta(&source),
                    Err(_) => store.dump_yaml(),
                },
                None => store.dump_yaml(),
            };
            match result {
                Ok(yaml) => {
                    if let Some(path) = out_path {
                        std::fs::write(&path, &yaml).unwrap_or_else(|e| {
                            eprintln!("write error: {e}");
                            std::process::exit(1);
                        });
                        eprintln!("wrote {}", path);
                        // INFRA-094: mark this as a chump-CLI yaml op so the
                        // pre-commit hook recognizes the gaps.yaml diff as
                        // canonical (not a raw hand-edit). INFRA-247: marker
                        // goes to the linked worktree's .chump/.last-yaml-op,
                        // matching where the staged YAML edits sit.
                        write_yaml_op_marker(&worktree_root, "dump");
                    } else {
                        print!("{}", yaml);
                    }
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap dump: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "import" => {
            let yaml_path = flag("--yaml").unwrap_or_else(|| "docs/gaps.yaml".into());
            // INFRA-821: derive repo root from --yaml path. When the user passes
            // an absolute path (e.g. /abs/repo/docs/gaps.yaml), strip the trailing
            // docs/gaps.yaml or docs/gaps component to recover the repo root instead
            // of using "/" which causes 0-inserted silently.
            let root = {
                let p = std::path::Path::new(&yaml_path);
                if p.is_absolute() {
                    // Strip known suffixes to recover repo root.
                    let stripped = yaml_path
                        .strip_suffix("/docs/gaps.yaml")
                        .or_else(|| yaml_path.strip_suffix("/docs/gaps"))
                        .map(std::path::PathBuf::from);
                    if let Some(r) = stripped {
                        r
                    } else if p.is_dir() {
                        // Treat the absolute path itself as the repo root.
                        p.to_path_buf()
                    } else {
                        eprintln!(
                            "chump gap import: cannot derive repo root from --yaml {:?}.\n\
                                 Expected path ending in docs/gaps.yaml or docs/gaps/.\n\
                                 Hint: omit --yaml to import from current repo root ({}).",
                            yaml_path,
                            repo_root.display()
                        );
                        std::process::exit(1);
                    }
                } else {
                    repo_root.clone()
                }
            };
            // INFRA-1434: title-similarity guard at import time. Closes
            // the YAML-import bypass that let INFRA-1267/1268 land as
            // 100% identical-title duplicates. Mirrors INFRA-1149
            // reserve-time check; same default 0.85 block threshold.
            //
            // Disable: CHUMP_GAP_IMPORT_NO_SIMILARITY=1 (CI / bulk imports)
            // Tune:    CHUMP_GAP_IMPORT_SIMILARITY_BLOCK (default 0.85)
            let block_threshold: Option<f64> =
                if std::env::var("CHUMP_GAP_IMPORT_NO_SIMILARITY").as_deref() == Ok("1") {
                    None
                } else {
                    Some(
                        std::env::var("CHUMP_GAP_IMPORT_SIMILARITY_BLOCK")
                            .ok()
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(0.85),
                    )
                };
            match store.import_from_yaml_with_similarity(&root, block_threshold) {
                Ok((ins, skip, backfilled, blocked)) => {
                    let backfill_msg = if backfilled > 0 {
                        format!(", {backfilled} closed_pr values backfilled from YAML")
                    } else {
                        String::new()
                    };
                    let blocked_msg = if blocked > 0 {
                        format!(
                            ", {blocked} blocked by title-similarity (INFRA-1434; \
                                 see ambient.jsonl kind=gap_import_similarity_block)"
                        )
                    } else {
                        String::new()
                    };
                    eprintln!(
                        "import complete: {ins} inserted, {skip} skipped (already present)\
                             {backfill_msg}{blocked_msg}."
                    );
                    // Non-zero exit when any row was blocked so CI scripts
                    // can detect partial imports. Bypass via env var above.
                    if blocked > 0 {
                        std::process::exit(1);
                    }
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap import: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        // INFRA-538: rebuild state.db from .chump/state.sql when the DB
        // is corrupted. Backs up existing DB first, then replays YAML.
        "restore" => {
            let from_sql = args.iter().any(|a| a == "--from-sql");
            if !from_sql {
                eprintln!("Usage: chump gap restore --from-sql");
                eprintln!("       Rebuilds .chump/state.db from .chump/state.sql (YAML mirror).");
                std::process::exit(2);
            }
            let sql_path = repo_root.join(".chump").join("state.sql");
            if !sql_path.exists() {
                eprintln!(
                    "chump gap restore: {} not found — nothing to restore from",
                    sql_path.display()
                );
                std::process::exit(1);
            }
            let db_path = gap_store::GapStore::db_path(&repo_root);
            // Back up existing DB before clobbering it.
            if db_path.exists() {
                let bak = db_path.with_extension("db.bak");
                std::fs::copy(&db_path, &bak).unwrap_or_else(|e| {
                    eprintln!("chump gap restore: could not back up state.db: {e}");
                    std::process::exit(1);
                });
                eprintln!("backed up {} → {}", db_path.display(), bak.display());
                // Remove the corrupted DB so GapStore::open creates a fresh one.
                std::fs::remove_file(&db_path).unwrap_or_else(|e| {
                    eprintln!("chump gap restore: could not remove corrupted state.db: {e}");
                    std::process::exit(1);
                });
            }
            let mut fresh_store = match gap_store::GapStore::open(&repo_root) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("chump gap restore: could not open fresh state.db: {e:#}");
                    std::process::exit(1);
                }
            };
            match fresh_store.restore_from_state_sql(&sql_path) {
                Ok(n) => {
                    println!(
                        "chump gap restore: rebuilt state.db from {} — {} gap(s) restored",
                        sql_path.display(),
                        n
                    );
                }
                Err(e) => {
                    eprintln!("chump gap restore: restore failed: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        // INFRA-586: PM health signal for META-046 curation.
        // Checks: P0 ages, vague (no AC) pickable, double-encoded
        // depends_on, missing-dep refs, open-with-closed-pr, race-*
        // test pollution. Exits non-zero if P0 >5, any P0 stuck >7d,
        // or any vague pickable gap exists.
        "audit-priorities" => {
            let now_secs = unix_ts() as i64;
            let all_gaps = match store.list(None) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap audit-priorities: {e:#}");
                    std::process::exit(1);
                }
            };

            let p0_open: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| g.priority == "P0" && g.status == "open")
                .collect();
            let p0_count = p0_open.len();
            // INFRA-627: auto-filed P0s (from pr-triage-bot) are exempt
            // from the P0 >5 budget — they represent real CI failures the
            // fleet must attack first and should not be demoted by the
            // operator-curation rule.
            let auto_filed_marker = "auto-filed by pr-triage-bot";
            let p0_auto_filed: Vec<&gap_store::GapRow> = p0_open
                .iter()
                .filter(|g| g.notes.contains(auto_filed_marker))
                .copied()
                .collect();
            let p0_manual_count = p0_count - p0_auto_filed.len();

            let p0_stuck: Vec<(&gap_store::GapRow, i64)> = p0_open
                .iter()
                .filter_map(|g| {
                    let age_days = (now_secs - g.created_at) / 86400;
                    if age_days > 7 {
                        Some((*g, age_days))
                    } else {
                        None
                    }
                })
                .collect();

            let vague_pickable: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| g.status == "open" && g.acceptance_criteria.trim().is_empty())
                .collect();

            let double_encoded: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| {
                    let d = g.depends_on.trim();
                    !d.is_empty() && d != "[]" && d.starts_with('"')
                })
                .collect();

            let all_ids: std::collections::HashSet<&str> =
                all_gaps.iter().map(|g| g.id.as_str()).collect();
            let mut missing_dep_pairs: Vec<(String, String)> = Vec::new();
            for g in &all_gaps {
                if let Ok(serde_json::Value::Array(arr)) =
                    serde_json::from_str::<serde_json::Value>(&g.depends_on)
                {
                    for v in arr {
                        if let serde_json::Value::String(dep_id) = v {
                            if !all_ids.contains(dep_id.as_str()) {
                                missing_dep_pairs.push((g.id.clone(), dep_id));
                            }
                        }
                    }
                }
            }

            // RESEARCH-001: scan docs/process/RESEARCH_INTEGRITY.md for gap ID
            // references that have no corresponding docs/gaps/<ID>.yaml.
            let phantom_doc_refs: Vec<(String, String)> = {
                let repo_root = repo_path::repo_root();
                let ri_path = repo_root.join("docs/process/RESEARCH_INTEGRITY.md");
                if let Ok(content) = std::fs::read_to_string(&ri_path) {
                    // Strip fenced code blocks before scanning.
                    let re_fence = regex::Regex::new(r"(?s)```.*?```").unwrap();
                    let stripped = re_fence.replace_all(&content, "");
                    // Strip inline backtick spans.
                    let re_tick = regex::Regex::new(r"`[^`]+`").unwrap();
                    let stripped = re_tick.replace_all(&stripped, "");
                    // Match gap IDs: known-domain prefix + digits.
                    let re_id = regex::Regex::new(
                            r"\b(EVAL|RESEARCH|INFRA|META|FLEET|COG|CREDIBLE|EFFECTIVE|RESILIENT|ZERO-WASTE|MISSION|DOC)-\d+\b"
                        ).unwrap();
                    let gaps_dir = repo_root.join("docs/gaps");
                    let mut seen = std::collections::HashSet::new();
                    let mut phantoms: Vec<(String, String)> = Vec::new();
                    for cap in re_id.captures_iter(&stripped) {
                        let id = cap[0].to_string();
                        if seen.contains(&id) {
                            continue;
                        }
                        seen.insert(id.clone());
                        if !all_ids.contains(id.as_str()) {
                            // Also check filesystem in case the YAML exists but isn't
                            // imported into state.db yet.
                            let yaml = gaps_dir.join(format!("{id}.yaml"));
                            if !yaml.exists() {
                                phantoms
                                    .push(("docs/process/RESEARCH_INTEGRITY.md".to_string(), id));
                            }
                        }
                    }
                    phantoms
                } else {
                    Vec::new()
                }
            };

            let open_with_closed_pr: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| g.status == "open" && g.closed_pr.is_some())
                .collect();

            let race_pollution: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| g.status == "open" && g.title.to_lowercase().starts_with("race-"))
                .collect();

            let done_with_closed_pr: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| g.status == "done" && g.closed_pr.is_some())
                .collect();

            // MISSION-008: outcome-aware P0 budget view (additive — existing per-gap
            // checks remain intact; this is an advisory overlay alongside them).
            let p0_outcomes = store.list_p0_outcomes().unwrap_or_default();

            // MISSION-030: --by-outcome flag — per-outcome gap counts + orphan rate.
            let by_outcome = args.iter().any(|a| a == "--by-outcome");

            // CREDIBLE-107: --flag-empty-evidence — list P0/P1 RESILIENT/MISSION/CREDIBLE
            // gaps that have a NULL/empty evidence column (filed before the gate or via bypass).
            let flag_empty_evidence = args.iter().any(|a| a == "--flag-empty-evidence");
            let enforce_domains_ev = ["RESILIENT", "MISSION", "CREDIBLE"];
            let enforce_priorities_ev = ["P0", "P1"];
            let missing_evidence: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| {
                    g.status == "open"
                        && enforce_priorities_ev.contains(&g.priority.as_str())
                        && enforce_domains_ev.contains(&g.domain.to_uppercase().as_str())
                        && g.evidence
                            .as_deref()
                            .map(|e| e.trim().is_empty())
                            .unwrap_or(true)
                })
                .collect();

            if json_out {
                let mut report = serde_json::json!({
                    "p0_count": p0_count,
                    "p0_manual_count": p0_manual_count,
                    "p0_auto_filed_count": p0_auto_filed.len(),
                    "p0_stuck_7d": p0_stuck.len(),
                    "vague_pickable": vague_pickable.len(),
                    "double_encoded_depends_on": double_encoded.len(),
                    "missing_dep_refs": missing_dep_pairs.len(),
                    "phantom_doc_refs": phantom_doc_refs.len(),
                    "open_with_closed_pr": open_with_closed_pr.len(),
                    "done_with_closed_pr": done_with_closed_pr.len(),
                    "race_test_pollution": race_pollution.len(),
                    "p0_gaps": p0_open.iter().map(|g| {
                        let age_days = (now_secs - g.created_at) / 86400;
                        let auto_filed = g.notes.contains(auto_filed_marker);
                        serde_json::json!({"id": g.id, "title": g.title, "age_days": age_days, "auto_filed": auto_filed})
                    }).collect::<Vec<_>>(),
                    // MISSION-008: outcome-aware layer (advisory, alongside per-gap budget)
                    "p0_outcomes_count": p0_outcomes.len(),
                    "p0_outcomes": p0_outcomes.iter().map(|o| {
                        serde_json::json!({"id": o.id, "title": o.title, "priority": o.priority})
                    }).collect::<Vec<_>>(),
                    // CREDIBLE-107: evidence audit
                    "missing_evidence_count": missing_evidence.len(),
                    "missing_evidence": missing_evidence.iter().take(5).map(|g| {
                        serde_json::json!({"id": g.id, "priority": g.priority, "domain": g.domain, "title": g.title})
                    }).collect::<Vec<_>>(),
                });
                // MISSION-030: inject by-outcome rollup into JSON when flag set.
                if by_outcome {
                    let outcomes = store.list_outcomes().unwrap_or_default();
                    let open_gaps: Vec<_> =
                        all_gaps.iter().filter(|g| g.status == "open").collect();
                    let total_open = open_gaps.len();
                    let linked_open = open_gaps
                        .iter()
                        .filter(|g| g.outcome_id.as_deref().map(|s| !s.is_empty()) == Some(true))
                        .count();
                    let orphan_rate = linked_open
                        .checked_mul(100)
                        .and_then(|n| n.checked_div(total_open))
                        .map(|pct_linked| 100usize.saturating_sub(pct_linked))
                        .unwrap_or(0);
                    let per_outcome: Vec<serde_json::Value> = outcomes
                        .iter()
                        .map(|o| {
                            let o_open = open_gaps
                                .iter()
                                .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                                .count();
                            let o_done = all_gaps
                                .iter()
                                .filter(|g| {
                                    g.status == "done"
                                        && g.outcome_id.as_deref() == Some(o.id.as_str())
                                })
                                .count();
                            let o_total = all_gaps
                                .iter()
                                .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                                .count();
                            serde_json::json!({
                                "outcome_id": o.id,
                                "title": o.title,
                                "priority": o.priority,
                                "open_gaps": o_open,
                                "done_gaps": o_done,
                                "total_gaps": o_total,
                            })
                        })
                        .collect();
                    if let serde_json::Value::Object(ref mut map) = report {
                        map.insert(
                            "by_outcome".into(),
                            serde_json::json!({
                                "outcomes_registered": outcomes.len(),
                                "open_gaps_total": total_open,
                                "open_gaps_linked": linked_open,
                                "open_gaps_orphaned": total_open - linked_open,
                                "mission_orphan_rate_pct": orphan_rate,
                                "per_outcome": per_outcome,
                            }),
                        );
                    }
                }
                println!(
                    "{}",
                    serde_json::to_string_pretty(&report).unwrap_or_default()
                );
            } else {
                println!("=== gap audit-priorities ===");
                println!();
                println!(
                    "P0 open gaps: {} ({} manual, {} auto-filed by pr-triage-bot)",
                    p0_count,
                    p0_manual_count,
                    p0_auto_filed.len()
                );
                for g in &p0_open {
                    let age_days = (now_secs - g.created_at) / 86400;
                    let stuck = if age_days > 7 { " *** STUCK" } else { "" };
                    let marker = if g.notes.contains(auto_filed_marker) {
                        " [auto-filed]"
                    } else {
                        ""
                    };
                    println!(
                        "  {} — {} ({}d old{}{})",
                        g.id, g.title, age_days, stuck, marker
                    );
                }
                println!();
                println!("Vague (no AC) pickable: {}", vague_pickable.len());
                for g in &vague_pickable {
                    println!("  {} — {} ({})", g.id, g.title, g.priority);
                }
                println!();
                println!("Double-encoded depends_on: {}", double_encoded.len());
                for g in &double_encoded {
                    println!("  {} — depends_on={}", g.id, g.depends_on);
                }
                println!();
                println!("Missing-dep refs: {}", missing_dep_pairs.len());
                for (id, dep) in &missing_dep_pairs {
                    println!("  {} → {} (not in registry)", id, dep);
                }
                println!();
                println!(
                    "Phantom doc refs (RESEARCH_INTEGRITY.md): {}",
                    phantom_doc_refs.len()
                );
                for (doc, id) in &phantom_doc_refs {
                    println!("  {} cites {} — no docs/gaps/{}.yaml found", doc, id, id);
                    tracing::warn!(
                        kind = "phantom_doc_ref_detected",
                        doc = doc.as_str(),
                        gap_id = id.as_str(),
                        "RESEARCH_INTEGRITY.md cites {} but docs/gaps/{}.yaml not found",
                        id,
                        id
                    );
                }
                println!();
                println!("Open with closed_pr set: {}", open_with_closed_pr.len());
                for g in &open_with_closed_pr {
                    println!(
                        "  {} — {} (closed_pr=#{})",
                        g.id,
                        g.title,
                        g.closed_pr.unwrap_or(0)
                    );
                }
                println!();
                println!("Done with closed_pr set: {}", done_with_closed_pr.len());
                for g in &done_with_closed_pr {
                    println!(
                        "  {} — {} (closed_pr=#{})",
                        g.id,
                        g.title,
                        g.closed_pr.unwrap_or(0)
                    );
                }
                println!();
                println!("race-* test pollution (open): {}", race_pollution.len());
                for g in &race_pollution {
                    println!("  {} — {}", g.id, g.title);
                }
                // CREDIBLE-107: --flag-empty-evidence section.
                if flag_empty_evidence {
                    println!();
                    println!(
                            "=== P0/P1 RESILIENT/MISSION/CREDIBLE gaps missing evidence (CREDIBLE-107) ==="
                        );
                    if missing_evidence.is_empty() {
                        println!("  (all enforced gaps have evidence — good)");
                    } else {
                        println!(
                            "Missing evidence: {} gap(s) (filed before gate or via bypass):",
                            missing_evidence.len()
                        );
                        for g in missing_evidence.iter().take(5) {
                            println!("  {} [{}] {} — {}", g.id, g.priority, g.domain, g.title);
                        }
                        if missing_evidence.len() > 5 {
                            println!("  ... and {} more", missing_evidence.len() - 5);
                        }
                        println!("  Backfill with: chump gap set <ID> --evidence \"COMMAND: ...\"");
                    }
                }
                // MISSION-008: outcome-aware P0 budget view (advisory alongside per-gap checks).
                println!();
                println!("=== Outcome-aware P0 budget (MISSION-008, advisory) ===");
                if p0_outcomes.is_empty() {
                    println!("  (no P0 outcomes registered — `chump outcome bootstrap` to seed)");
                } else {
                    println!("P0 open outcomes: {}", p0_outcomes.len());
                    for o in &p0_outcomes {
                        println!("  {} — {}", o.id, o.title);
                    }
                }
                // MISSION-030: --by-outcome human-readable section.
                if by_outcome {
                    println!();
                    println!("=== Outcome mission-orphan report (MISSION-030) ===");
                    let outcomes = store.list_outcomes().unwrap_or_default();
                    if outcomes.is_empty() {
                        println!("  (no outcomes registered — run `chump outcome bootstrap`)");
                    } else {
                        let open_gaps: Vec<_> =
                            all_gaps.iter().filter(|g| g.status == "open").collect();
                        let total_open = open_gaps.len();
                        let linked_open = open_gaps
                            .iter()
                            .filter(|g| {
                                g.outcome_id.as_deref().map(|s| !s.is_empty()) == Some(true)
                            })
                            .count();
                        let orphan_rate = 100usize
                            - linked_open
                                .checked_mul(100)
                                .and_then(|n| n.checked_div(total_open))
                                .unwrap_or(0);
                        println!(
                                "Outcomes registered: {}  |  open gaps: {}  linked: {}  orphaned: {}  orphan-rate: {}%",
                                outcomes.len(),
                                total_open,
                                linked_open,
                                total_open - linked_open,
                                orphan_rate,
                            );
                        println!();
                        println!("Per-outcome breakdown:");
                        for o in &outcomes {
                            let o_open = open_gaps
                                .iter()
                                .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                                .count();
                            let o_done = all_gaps
                                .iter()
                                .filter(|g| {
                                    g.status == "done"
                                        && g.outcome_id.as_deref() == Some(o.id.as_str())
                                })
                                .count();
                            println!(
                                "  {} [{}] open={} done={} — {}",
                                o.id, o.priority, o_open, o_done, o.title
                            );
                        }
                    }
                }
            }

            let mut fail_reasons: Vec<String> = Vec::new();
            // INFRA-627: auto-filed P0s exempt from budget — count only manual ones.
            if p0_manual_count > 5 {
                fail_reasons.push(format!(
                    "P0 manual count {} > 5 (plus {} auto-filed, exempt)",
                    p0_manual_count,
                    p0_auto_filed.len()
                ));
            }
            if !p0_stuck.is_empty() {
                fail_reasons.push(format!("{} P0 gap(s) stuck >7d", p0_stuck.len()));
            }
            if !vague_pickable.is_empty() {
                fail_reasons.push(format!(
                    "{} vague (no AC) pickable gap(s)",
                    vague_pickable.len()
                ));
            }
            if !done_with_closed_pr.is_empty() {
                fail_reasons.push(format!(
                    "{} done gap(s) with closed_pr set — review closure consistency",
                    done_with_closed_pr.len()
                ));
            }
            if fail_reasons.is_empty() {
                return Ok(());
            }
            for r in &fail_reasons {
                eprintln!("FAIL: {}", r);
            }
            std::process::exit(1);
        }
        // INFRA-942: classify every open gap by why it is non-pickable and
        // emit a ranked action list.
        // Reasons: false-dep | too-large | vague-ac | low-priority
        // Actions: strip-dep | decompose | add-ac | demote
        // --json   → machine-readable array output
        // --apply  → execute auto-fixable actions (strip false-deps, demote P2→P3)
        "triage" => {
            // INFRA-1238: trap --help.
            if args
                .iter()
                .skip(3)
                .any(|a| matches!(a.as_str(), "--help" | "-h"))
            {
                println!(
                        "Usage: chump gap triage [--json] [--apply]\n\n\
                         Classify every open gap by why it is non-pickable and emit ranked action list.\n\
                         Reasons: too-large, false-dep, vague-ac, low-priority.\n\n\
                         Options:\n  \
                           --json    Emit JSON; default is a human table\n  \
                           --apply   Execute recommended actions (decompose/strip-dep/add-ac/demote); default is dry-run\n  \
                           -h, --help  Show this help"
                    );
                return Ok(());
            }
            let as_json = args.iter().any(|a| a == "--json");
            let apply = args.iter().any(|a| a == "--apply");

            let all_gaps = match store.list(None) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap triage: {e:#}");
                    std::process::exit(1);
                }
            };

            let now_secs = unix_ts() as i64;

            let status_by_id: std::collections::HashMap<&str, &str> = all_gaps
                .iter()
                .map(|g| (g.id.as_str(), g.status.as_str()))
                .collect();

            // Set of gap IDs referenced in any depends_on — used to detect
            // whether a large gap has been broken into sub-parts.
            let mut dep_target_ids: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            for g in &all_gaps {
                if let Ok(serde_json::Value::Array(arr)) =
                    serde_json::from_str::<serde_json::Value>(&g.depends_on)
                {
                    for v in &arr {
                        if let serde_json::Value::String(dep_id) = v {
                            dep_target_ids.insert(dep_id.clone());
                        }
                    }
                }
            }

            #[derive(serde::Serialize)]
            struct TriageItem {
                id: String,
                title: String,
                reason: String,
                recommended_action: String,
                detail: String,
            }

            let open_gaps: Vec<&gap_store::GapRow> =
                all_gaps.iter().filter(|g| g.status == "open").collect();

            let mut items: Vec<TriageItem> = Vec::new();

            for gap in &open_gaps {
                // 1. false-dep
                if let Ok(serde_json::Value::Array(arr)) =
                    serde_json::from_str::<serde_json::Value>(&gap.depends_on)
                {
                    for v in &arr {
                        if let serde_json::Value::String(dep_id) = v {
                            if status_by_id.get(dep_id.as_str()).copied() == Some("done") {
                                items.push(TriageItem {
                                    id: gap.id.clone(),
                                    title: gap.title.chars().take(70).collect(),
                                    reason: "false-dep".to_string(),
                                    recommended_action: "strip-dep".to_string(),
                                    detail: format!("depends_on {} which is done", dep_id),
                                });
                            }
                        }
                    }
                }

                // 2. too-large
                let effort_lower = gap.effort.to_lowercase();
                if (effort_lower == "l" || effort_lower == "xl")
                    && !dep_target_ids.contains(&gap.id)
                {
                    items.push(TriageItem {
                        id: gap.id.clone(),
                        title: gap.title.chars().take(70).collect(),
                        reason: "too-large".to_string(),
                        recommended_action: "decompose".to_string(),
                        detail: format!("effort={}, no sub-gaps filed yet", gap.effort),
                    });
                }

                // 3. vague-ac
                {
                    let ac_items = gap_store::parse_json_ac_list(&gap.acceptance_criteria);
                    let vague_reason =
                        if gap.acceptance_criteria.trim().is_empty() || ac_items.is_empty() {
                            Some("empty acceptance_criteria")
                        } else if ac_items.iter().any(|item| is_vague_ac_entry(item)) {
                            // INFRA-1878: use stub-detection helper so entries that
                            // merely mention "TODO" in passing are not flagged.
                            Some("acceptance_criteria contains TODO/TBD placeholder")
                        } else {
                            None
                        };
                    if let Some(detail) = vague_reason {
                        items.push(TriageItem {
                            id: gap.id.clone(),
                            title: gap.title.chars().take(70).collect(),
                            reason: "vague-ac".to_string(),
                            recommended_action: "add-ac".to_string(),
                            detail: detail.to_string(),
                        });
                    }
                }

                // 4. low-priority: P2/P3 idle >90d
                let age_days = (now_secs - gap.created_at) / 86400;
                if (gap.priority == "P2" || gap.priority == "P3") && age_days > 90 {
                    items.push(TriageItem {
                        id: gap.id.clone(),
                        title: gap.title.chars().take(70).collect(),
                        reason: "low-priority".to_string(),
                        recommended_action: "demote".to_string(),
                        detail: format!(
                            "priority={}, {}d old — consider closing or demoting further",
                            gap.priority, age_days
                        ),
                    });
                }
            }

            // --apply: execute auto-fixable actions
            if apply {
                let mut applied: std::collections::HashSet<(String, String)> =
                    std::collections::HashSet::new();
                for item in &items {
                    let key = (item.id.clone(), item.reason.clone());
                    if applied.contains(&key) {
                        continue;
                    }
                    applied.insert(key);
                    match item.reason.as_str() {
                        "false-dep" => match store.get(&item.id) {
                            Ok(Some(cur_gap)) => {
                                if let Ok(serde_json::Value::Array(arr)) =
                                    serde_json::from_str::<serde_json::Value>(&cur_gap.depends_on)
                                {
                                    let remaining: Vec<String> = arr
                                        .iter()
                                        .filter_map(|v| {
                                            if let serde_json::Value::String(dep_id) = v {
                                                if status_by_id.get(dep_id.as_str()).copied()
                                                    != Some("done")
                                                {
                                                    Some(dep_id.clone())
                                                } else {
                                                    None
                                                }
                                            } else {
                                                None
                                            }
                                        })
                                        .collect();
                                    let new_deps = serde_json::to_string(&remaining)
                                        .unwrap_or_else(|_| "[]".to_string());
                                    let mut update = gap_store::GapFieldUpdate::default();
                                    update.depends_on = Some(new_deps);
                                    match store.set_fields(&item.id, update) {
                                        Ok(()) => eprintln!(
                                            "triage --apply: stripped done deps from {}",
                                            item.id
                                        ),
                                        Err(e) => eprintln!(
                                            "triage --apply: strip-dep on {} failed: {e:#}",
                                            item.id
                                        ),
                                    }
                                }
                            }
                            Ok(None) => {}
                            Err(e) => {
                                eprintln!("triage --apply: get {} failed: {e:#}", item.id)
                            }
                        },
                        "low-priority" => {
                            if let Some(gap) = open_gaps.iter().find(|g| g.id == item.id) {
                                if gap.priority == "P2" {
                                    let gap_age = (now_secs - gap.created_at) / 86400;
                                    let mut update = gap_store::GapFieldUpdate::default();
                                    update.priority = Some("P3".to_string());
                                    match store.set_fields(&item.id, update) {
                                        Ok(()) => eprintln!(
                                            "triage --apply: demoted {} P2→P3 ({}d old)",
                                            item.id, gap_age
                                        ),
                                        Err(e) => eprintln!(
                                            "triage --apply: demote {} failed: {e:#}",
                                            item.id
                                        ),
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }

            // Observability — emit triage summary so fleet-brief / waste-tally
            // can track registry health over time (INFRA-755 observability-budget).
            let false_dep_n = items.iter().filter(|i| i.reason == "false-dep").count();
            let too_large_n = items.iter().filter(|i| i.reason == "too-large").count();
            let vague_ac_n = items.iter().filter(|i| i.reason == "vague-ac").count();
            let low_pri_n = items.iter().filter(|i| i.reason == "low-priority").count();
            tracing::info!(
                open_checked = open_gaps.len(),
                actionable = items.len(),
                false_dep = false_dep_n,
                too_large = too_large_n,
                vague_ac = vague_ac_n,
                low_priority = low_pri_n,
                apply_mode = apply,
                "infra942 gap triage complete"
            );

            if as_json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&items).unwrap_or_default()
                );
            } else {
                println!(
                    "=== gap triage ({} open gaps, {} actionable) ===",
                    open_gaps.len(),
                    items.len()
                );
                println!();
                if items.is_empty() {
                    println!("All open gaps are clean — no triage needed.");
                } else {
                    let col_id = items.iter().map(|i| i.id.len()).max().unwrap_or(6).max(6);
                    let col_reason = items
                        .iter()
                        .map(|i| i.reason.len())
                        .max()
                        .unwrap_or(12)
                        .max(12);
                    let col_action = items
                        .iter()
                        .map(|i| i.recommended_action.len())
                        .max()
                        .unwrap_or(18)
                        .max(18);
                    println!(
                        "{:<id_w$}  {:<r_w$}  {:<a_w$}  detail",
                        "id",
                        "reason",
                        "recommended-action",
                        id_w = col_id,
                        r_w = col_reason,
                        a_w = col_action
                    );
                    println!("{}", "-".repeat(col_id + col_reason + col_action + 30));
                    for item in &items {
                        println!(
                            "{:<id_w$}  {:<r_w$}  {:<a_w$}  {}",
                            item.id,
                            item.reason,
                            item.recommended_action,
                            item.detail,
                            id_w = col_id,
                            r_w = col_reason,
                            a_w = col_action
                        );
                    }
                    println!();
                    if apply {
                        println!("(--apply: false-dep strip and P2→P3 demotion executed above)");
                    } else {
                        println!("Run with --apply to auto-fix false-dep and low-priority items.");
                        println!("Run with --json for machine-readable output.");
                    }
                }
            }

            if !items.is_empty() {
                std::process::exit(1);
            }
        }
        "audit-ac" => {
            // COG-052: check whether closed gaps' AC items were demonstrated in their PR diff.
            // INFRA-936: --open mode scans open gaps for vague/missing/TODO AC.
            // Usage: chump gap audit-ac [GAP-ID] [--recent N] [--open] [--json]
            //   GAP-ID     — audit one gap; must have closed_pr set
            //   --recent N — audit N most recently closed gaps (default 20 if no GAP-ID)
            //   --open     — INFRA-936: check open gaps for empty/TODO acceptance_criteria
            //   --json     — machine-readable output
            let as_json = args.iter().any(|a| a == "--json");
            let check_open = args.iter().any(|a| a == "--open");

            let all_gaps = match store.list(None) {
                Ok(g) => g,
                Err(e) => {
                    eprintln!("chump gap audit-ac: {e:#}");
                    std::process::exit(1);
                }
            };

            // ── INFRA-936: --open mode ─────────────────────────────────────────────
            if check_open {
                #[derive(serde::Serialize)]
                struct VagueGap {
                    id: String,
                    title: String,
                    reason: String, // "empty" | "todo_placeholder"
                }

                let open_gaps: Vec<&gap_store::GapRow> =
                    all_gaps.iter().filter(|g| g.status == "open").collect();

                let mut vague: Vec<VagueGap> = Vec::new();
                for gap in &open_gaps {
                    let ac_items = gap_store::parse_json_ac_list(&gap.acceptance_criteria);
                    let reason = if gap.acceptance_criteria.trim().is_empty() || ac_items.is_empty()
                    {
                        Some("empty")
                    } else if ac_items.iter().any(|item| {
                        let lower = item.to_lowercase();
                        lower.contains("todo")
                            || lower.trim() == "tbd"
                            || lower.trim() == "n/a"
                            || lower.trim() == "tbc"
                    }) {
                        Some("todo_placeholder")
                    } else {
                        None
                    };

                    if let Some(r) = reason {
                        vague.push(VagueGap {
                            id: gap.id.clone(),
                            title: gap.title.chars().take(80).collect(),
                            reason: r.to_string(),
                        });
                    }
                }

                tracing::info!(
                    open_checked = open_gaps.len(),
                    vague_count = vague.len(),
                    "infra936 audit-ac --open complete"
                );

                if as_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&vague).unwrap_or_default()
                    );
                } else {
                    println!(
                        "=== gap audit-ac --open ({} open gaps checked) ===",
                        open_gaps.len()
                    );
                    println!();
                    if vague.is_empty() {
                        println!("All open gaps have concrete acceptance criteria.");
                    } else {
                        for v in &vague {
                            println!("[{}] {}  {}", v.reason, v.id, v.title);
                        }
                        println!();
                        println!("Vague open gaps: {}/{}", vague.len(), open_gaps.len());
                    }
                }

                if !vague.is_empty() {
                    std::process::exit(1);
                } else {
                    std::process::exit(0);
                }
            } else {
                // ── existing COG-052 closed-gap AC coverage check ──────────────────────

                let recent_n: usize = args
                    .iter()
                    .position(|a| a == "--recent")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(20);

                // Collect target gaps: either the specified one or the N most-recently closed.
                let specific_id = args.get(3).filter(|a| !a.starts_with('-')).cloned();

                let targets: Vec<&gap_store::GapRow> = if let Some(ref id) = specific_id {
                    all_gaps
                        .iter()
                        .filter(|g| g.id.eq_ignore_ascii_case(id))
                        .collect()
                } else {
                    let mut closed: Vec<&gap_store::GapRow> = all_gaps
                        .iter()
                        .filter(|g| g.status == "done" && g.closed_pr.is_some())
                        .collect();
                    // Most-recently closed first (use closed_at unix timestamp).
                    closed.sort_by(|a, b| {
                        let ta = a.closed_at.unwrap_or(a.created_at);
                        let tb = b.closed_at.unwrap_or(b.created_at);
                        tb.cmp(&ta)
                    });
                    closed.truncate(recent_n);
                    closed
                };

                if targets.is_empty() {
                    eprintln!("chump gap audit-ac: no matching gaps found");
                    std::process::exit(1);
                }

                // Common stop-words to skip when keyword-matching AC text against diffs.
                const STOP: &[&str] = &[
                    "the", "and", "for", "that", "this", "with", "when", "from", "not", "are",
                    "all", "any", "each", "have", "must", "will", "but", "via", "can", "into",
                    "also", "then", "run", "use", "set", "add", "new", "its", "may", "per", "has",
                    "been",
                ];

                #[derive(serde::Serialize)]
                struct AcItem {
                    text: String,
                    matched: bool,
                    matched_terms: Vec<String>,
                    missing_terms: Vec<String>,
                }
                #[derive(serde::Serialize)]
                struct GapAcResult {
                    id: String,
                    title: String,
                    closed_pr: i64,
                    ac_items: Vec<AcItem>,
                    coverage_pct: u8,
                    diverged: bool,
                }

                let mut results: Vec<GapAcResult> = Vec::new();

                for gap in &targets {
                    let pr_num = match gap.closed_pr {
                        Some(n) => n,
                        None => continue,
                    };

                    // Fetch PR diff via gh CLI.
                    let diff_out = std::process::Command::new("gh")
                        .args(["pr", "diff", &pr_num.to_string()])
                        .output();
                    let diff_text = match diff_out {
                        Ok(o) if o.status.success() => {
                            String::from_utf8_lossy(&o.stdout).to_lowercase()
                        }
                        _ => {
                            if !as_json {
                                eprintln!(
                                    "[audit-ac] WARN: could not fetch diff for PR #{pr_num} \
                                     (gh not available or PR closed); skipping {}",
                                    gap.id
                                );
                            }
                            continue;
                        }
                    };

                    let ac_items_raw: Vec<String> =
                        gap_store::parse_json_ac_list(&gap.acceptance_criteria);
                    let mut item_results: Vec<AcItem> = Vec::new();
                    let mut total_terms = 0usize;
                    let mut total_matched = 0usize;

                    for ac_text in &ac_items_raw {
                        // Extract meaningful keywords (>= 4 chars, not stop-words).
                        let terms: Vec<String> = ac_text
                            .split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-')
                            .filter(|t| t.len() >= 4)
                            .map(|t| t.to_lowercase())
                            .filter(|t| !STOP.contains(&t.as_str()))
                            .collect::<std::collections::HashSet<_>>()
                            .into_iter()
                            .collect();

                        let matched_terms: Vec<String> = terms
                            .iter()
                            .filter(|t| diff_text.contains(t.as_str()))
                            .cloned()
                            .collect();
                        let missing_terms: Vec<String> = terms
                            .iter()
                            .filter(|t| !diff_text.contains(t.as_str()))
                            .cloned()
                            .collect();

                        let item_matched =
                            !terms.is_empty() && matched_terms.len() * 2 >= terms.len(); // ≥50% terms found

                        total_terms += terms.len();
                        total_matched += matched_terms.len();

                        item_results.push(AcItem {
                            text: ac_text.clone(),
                            matched: item_matched,
                            matched_terms,
                            missing_terms,
                        });
                    }

                    let coverage_pct = (total_matched * 100)
                        .checked_div(total_terms)
                        .map(|v| v.min(100) as u8)
                        .unwrap_or(100u8);
                    let diverged = coverage_pct < 50;

                    results.push(GapAcResult {
                        id: gap.id.clone(),
                        title: gap.title.chars().take(80).collect(),
                        closed_pr: pr_num,
                        ac_items: item_results,
                        coverage_pct,
                        diverged,
                    });
                }

                let diverged_total = results.iter().filter(|r| r.diverged).count();
                tracing::info!(
                    gaps_checked = results.len(),
                    diverged = diverged_total,
                    "cog052 audit-ac complete"
                );

                if as_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&results).unwrap_or_default()
                    );
                } else {
                    println!("=== gap audit-ac ({} gaps checked) ===", results.len());
                    println!();
                    let mut diverged_count = 0usize;
                    for r in &results {
                        let flag = if r.diverged { " *** DIVERGED" } else { "" };
                        println!(
                            "{} (PR #{}) — {}% coverage{}",
                            r.id, r.closed_pr, r.coverage_pct, flag
                        );
                        if r.diverged {
                            diverged_count += 1;
                            for item in &r.ac_items {
                                if !item.matched {
                                    println!(
                                        "  MISS: {}",
                                        if item.text.len() > 100 {
                                            format!("{}…", &item.text[..100])
                                        } else {
                                            item.text.clone()
                                        }
                                    );
                                    if !item.missing_terms.is_empty() {
                                        println!(
                                            "        missing terms: {}",
                                            item.missing_terms.join(", ")
                                        );
                                    }
                                }
                            }
                        }
                    }
                    println!();
                    println!(
                        "Diverged (< 50% AC coverage in diff): {}/{}",
                        diverged_count,
                        results.len()
                    );
                    if diverged_count > 0 {
                        std::process::exit(1);
                    }
                }
            } // end else (COG-052 closed-gap path)
        }
        "decompose" => {
            // INFRA-1238: trap --help before positional validation.
            if args
                .iter()
                .skip(3)
                .any(|a| matches!(a.as_str(), "--help" | "-h"))
            {
                println!("Usage: chump gap decompose <GAP-ID> [--apply] [--verify] [--json] [--dry-run] [--no-description] [--external-repo <owner/repo|path>] [--clone-path <path>]");
                println!();
                println!("Suggests xs/s slices for a large (m/l) gap using the provider cascade.");
                println!(
                        "  --verify                  Validate slices via a stronger model before filing"
                    );
                println!(
                    "  --apply                   File the suggested slices and demote the parent"
                );
                println!("  --json                    Output suggestions as JSON");
                println!(
                    "  --dry-run                 Print the full LLM prompt without calling the LLM"
                );
                println!(
                        "  --no-description          Skip injecting the gap description into the prompt"
                    );
                println!("  --external-repo <value>   Decompose against an external repo.");
                println!("                            Value: 'owner/repo' (looked up under ~/.chump/external/<owner>/<repo>/)");
                println!("                            or an absolute path to a clone.");
                println!(
                        "  --clone-path <path>       Override the resolved clone path (used with --external-repo)."
                    );
                println!("  -h, --help                Show this help");
                return Ok(());
            }
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap decompose <GAP-ID> [--apply] [--verify] [--json] [--dry-run] [--no-description] [--external-repo <owner/repo|path>] [--clone-path <path>]");
                    eprintln!();
                    eprintln!(
                        "Suggests xs/s slices for a large (m/l) gap using the provider cascade."
                    );
                    eprintln!("  --verify                  Validate slices via a stronger model before filing");
                    eprintln!("  --apply                   File the suggested slices and demote the parent");
                    eprintln!("  --json                    Output suggestions as JSON");
                    eprintln!("  --dry-run                 Print the full LLM prompt without calling the LLM");
                    eprintln!("  --no-description          Skip injecting the gap description into the prompt");
                    eprintln!("  --external-repo <value>   Decompose against an external repo (owner/repo or absolute path)");
                    eprintln!("  --clone-path <path>       Override the resolved clone path");
                    eprintln!();
                    eprintln!("Verify model: set CHUMP_VERIFY_API_BASE + CHUMP_VERIFY_MODEL,");
                    eprintln!("  or falls back to ANTHROPIC_API_KEY with claude-sonnet-4-6.");
                    std::process::exit(2);
                });
            let apply = args.iter().any(|a| a == "--apply");
            let verify = args.iter().any(|a| a == "--verify");
            let dry_run = args.iter().any(|a| a == "--dry-run");
            let no_description = args.iter().any(|a| a == "--no-description");

            // INFRA-2112: --external-repo <owner/repo|absolute-path> flag.
            // Resolves to a clone path; injects external context into the
            // LLM prompt; tags filed sub-gaps with
            // `skills_required: external_repo:<owner/repo>`.
            let external_repo: Option<String> = args
                .iter()
                .position(|a| a == "--external-repo")
                .and_then(|i| args.get(i + 1))
                .cloned();

            // --clone-path overrides the automatic resolution.
            let clone_path_override: Option<std::path::PathBuf> = args
                .iter()
                .position(|a| a == "--clone-path")
                .and_then(|i| args.get(i + 1))
                .map(std::path::PathBuf::from);

            // Resolve the external clone path and canonical tag for
            // skills_required injection.
            //
            // Tag format (INFRA-2116 schema): `external_repo:<owner>/<repo>`
            // where <owner>/<repo> is the canonical slash-form.  For an
            // absolute-path value we derive a best-effort tag using the
            // last two path components.
            let (external_clone_root, external_repo_tag): (
                Option<std::path::PathBuf>,
                Option<String>,
            ) = if let Some(ref repo_val) = external_repo {
                let (resolved_path, tag) = if repo_val.starts_with('/') {
                    // Absolute path form — use as-is, derive tag from last 2 components.
                    let p = std::path::PathBuf::from(repo_val);
                    let mut comps: Vec<String> = p
                        .components()
                        .map(|c| c.as_os_str().to_string_lossy().into_owned())
                        .collect();
                    comps.retain(|c| !c.is_empty());
                    let tag_suffix = if comps.len() >= 2 {
                        format!("{}/{}", comps[comps.len() - 2], comps[comps.len() - 1])
                    } else {
                        comps.last().cloned().unwrap_or_else(|| repo_val.clone())
                    };
                    (p, format!("external_repo:{tag_suffix}"))
                } else {
                    // owner/repo form — resolve under ~/.chump/external/
                    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
                    let default_path = std::path::PathBuf::from(&home)
                        .join(".chump")
                        .join("external")
                        .join(repo_val);
                    (default_path, format!("external_repo:{repo_val}"))
                };

                // --clone-path overrides the resolved path but keeps the tag.
                let final_path = clone_path_override.clone().unwrap_or(resolved_path);

                if !dry_run && !final_path.exists() {
                    eprintln!(
                        "chump gap decompose: external repo clone not found at {}",
                        final_path.display()
                    );
                    eprintln!(
                        "  Clone it first: git clone https://github.com/{repo_val} {}",
                        final_path.display()
                    );
                    std::process::exit(1);
                }
                (Some(final_path), Some(tag))
            } else {
                (clone_path_override.clone(), None)
            };
            let parent = match store.get(&gap_id) {
                Ok(Some(g)) => g,
                Ok(None) => {
                    eprintln!("chump gap decompose: gap {gap_id} not found");
                    std::process::exit(1);
                }
                Err(e) => {
                    eprintln!("chump gap decompose: {e:#}");
                    std::process::exit(1);
                }
            };
            if parent.status != "open" {
                eprintln!(
                    "chump gap decompose: {gap_id} is not open (status={})",
                    parent.status
                );
                std::process::exit(1);
            }
            let effort_lc = parent.effort.to_lowercase();
            if effort_lc == "xs" || effort_lc == "s" {
                eprintln!(
                    "chump gap decompose: {gap_id} is already effort={} — nothing to decompose",
                    parent.effort
                );
                std::process::exit(0);
            }

            if !dry_run {
                eprintln!("decomposing {gap_id} ({}) via LLM...", parent.title);
            }
            // INFRA-2112 observability: emit when external-repo mode is active so
            // fleet-brief and watchdogs can confirm the path ran.
            if let Some(ref tag) = external_repo_tag {
                tracing::info!(
                    gap_id = %gap_id,
                    external_repo_tag = %tag,
                    clone_path = ?external_clone_root,
                    "infra2112 decompose external-repo mode active"
                );
            }
            let provider = crate::provider_cascade::build_provider();
            let ac_display = if parent.acceptance_criteria.trim().is_empty()
                || parent.acceptance_criteria.trim() == "[]"
            {
                "(none)".to_string()
            } else {
                parent.acceptance_criteria.clone()
            };

            let system_prompt = "You are a project management assistant for a software project. \
                    Your job is to decompose large gaps (tasks) into smaller, independently shippable slices. \
                    Each slice must be xs (< 1 hour) or s (1-4 hours) effort. \
                    Each slice needs crisp, testable acceptance criteria. \
                    Output ONLY a JSON array of objects with these fields: \
                    {\"title\": \"...\", \"effort\": \"xs|s\", \"priority\": \"P1|P2\", \"acceptance_criteria\": [\"...\", \"...\"], \"depends_on\": []}. \
                    The depends_on field should reference other slices by their 0-based index in the array (e.g. [0] means depends on the first slice). \
                    Do not include any text outside the JSON array.".to_string();

            // Build the description context block.
            // When a filing agent writes architecture notes / rough slice
            // plan into the description, that text is the richest signal
            // available at claim time.  Inject it prominently — not buried
            // inline — so the LLM treats it as primary decomposition
            // guidance rather than incidental metadata.
            //
            // --no-description suppresses this for stale descriptions.
            let description_block = if no_description || parent.description.is_empty() {
                String::new()
            } else {
                format!(
                    "\nAdditional context from filing agent:\n{}\n\n\
                         Use this context to inform the decomposition, especially \
                         regarding which files to touch and what the rough \
                         implementation shape looks like.",
                    parent.description
                )
            };

            // ── INFRA-1719: structured AST shape ───────────────────────
            //
            // Pull file-path-like tokens out of the description + notes
            // and run the tree-sitter crawler on them. The resulting
            // structured map gives the LLM a deterministic view of the
            // codebase shape (top-level symbols, imports, doc lines)
            // instead of forcing a subprocess-walk path that returned
            // raw file bodies. ~30% fewer prompt tokens on >=5-file gaps.
            //
            // INFRA-2112: When --external-repo is set, crawl the external
            // clone instead of the current Chump working tree.
            //
            // Override via CHUMP_DECOMPOSE_AST=0 — drops the block. Used
            // when running on a non-source repo or for cost comparisons.
            let ast_block = if std::env::var("CHUMP_DECOMPOSE_AST")
                .ok()
                .map(|v| v == "0" || v.eq_ignore_ascii_case("false"))
                .unwrap_or(false)
            {
                String::new()
            } else {
                // Use the external clone root when provided; otherwise fall
                // back to the Chump working tree.
                let repo_root = external_clone_root.clone().unwrap_or_else(|| {
                    std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
                });
                let mut hint_text = String::new();
                hint_text.push_str(&parent.description);
                hint_text.push('\n');
                hint_text.push_str(&parent.notes);
                let candidates = extract_path_hints(&hint_text, &repo_root);
                if candidates.is_empty() {
                    // No hint paths surfaced — skip the crawl to avoid
                    // spending IO walking the entire repo unnecessarily.
                    String::new()
                } else {
                    match chump_ast_crawler::crawl_paths(&repo_root, &candidates) {
                        Ok(shape) => {
                            // Budget shaping: keep the block under ~6 KiB
                            // which empirically maps to <1.5K tokens on
                            // GPT-style BPE tokenizers (4 chars/token rule
                            // of thumb).
                            let block = shape.to_prompt_block(6 * 1024);
                            if block.trim().is_empty() {
                                String::new()
                            } else {
                                format!(
                                        "\n\nStructured codebase shape (deterministic AST pre-step, INFRA-1719):\n\
                                         The following symbols/imports were extracted from the paths referenced in the \
                                         description above. Use them — together with the AC — to decide which files each \
                                         slice should touch. Do not invent paths that aren't listed here.\n\n{block}",
                                    )
                            }
                        }
                        Err(e) => {
                            eprintln!("chump gap decompose: AST crawl skipped ({e:#})");
                            String::new()
                        }
                    }
                }
            };

            // ── INFRA-2112: external-repo context header ────────────────
            //
            // When --external-repo is set, prepend a header to the user
            // message so the LLM knows it is generating slices that will
            // reference files in the external repo, not the Chump tree.
            // The header also surfaces the resolved clone path so the
            // operator can verify the right checkout is being used.
            let external_repo_header = if let (Some(ref tag), Some(ref clone_root)) =
                (&external_repo_tag, &external_clone_root)
            {
                format!(
                    "EXTERNAL REPO MODE (INFRA-2112):\n\
                         Repo tag : {tag}\n\
                         Clone path: {}\n\
                         The sub-gaps you propose must reference files and symbols \
                         from the external repo above, not from the Chump internal tree.\n\
                         Each filed sub-gap will be tagged with `skills_required: {tag}` \
                         so picker routing can target workers with the right checkout.\n\n",
                    clone_root.display()
                )
            } else {
                String::new()
            };

            let user_msg = format!(
                "{external_repo_header}\
                     Decompose this gap into xs/s slices:\n\n\
                     ID: {}\n\
                     Domain: {}\n\
                     Title: {}\n\
                     Priority: {}\n\
                     Effort: {}\n\
                     Acceptance Criteria: {}\n\
                     Notes: {}{}{}",
                parent.id,
                parent.domain,
                parent.title,
                parent.priority,
                parent.effort,
                ac_display,
                if parent.notes.is_empty() {
                    "(none)"
                } else {
                    &parent.notes
                },
                description_block,
                ast_block,
            );

            // --dry-run: print the full prompt and exit without calling
            // the LLM.  Lets agents inspect exactly what context is being
            // used before committing to an LLM call.
            if dry_run {
                // INFRA-2112: when --external-repo is set, show the
                // resolved clone path before the prompts so the operator
                // can confirm the right checkout is in use.
                if let Some(ref clone_root) = external_clone_root {
                    eprintln!(
                        "=== dry-run: external-repo mode ===\nresolved clone path: {}",
                        clone_root.display()
                    );
                    eprintln!();
                }
                eprintln!("=== dry-run: system prompt ===");
                eprintln!("{system_prompt}");
                eprintln!();
                eprintln!("=== dry-run: user message ===");
                eprintln!("{user_msg}");
                return Ok(());
            }

            let user_content = user_msg.clone();

            // ── INFRA-2173: truncation-aware LLM call with retry ────────
            //
            // Large umbrella gaps (l-class, 8+ AC, ~3K char description)
            // can exhaust a 4096-token budget mid-JSON, producing a parse
            // failure.  Strategy:
            //   1. Call with initial budget (4096).
            //   2. If stop_reason is MaxTokens OR the raw text ends without
            //      a closing ']', double the budget and retry (up to 16384).
            //   3. On final failure, attempt partial recovery: scan for
            //      complete objects before the truncation point and import
            //      the parseable prefix as "partial decomposition recovered".

            #[derive(Debug, serde::Deserialize)]
            struct SliceSuggestion {
                title: String,
                effort: String,
                priority: String,
                acceptance_criteria: Vec<String>,
                #[serde(default)]
                depends_on: Vec<usize>,
            }

            /// Heuristic: response is likely truncated if it ends without
            /// a closing ']' after the last JSON content character.
            fn looks_truncated(text: &str) -> bool {
                let trimmed = text.trim_end();
                !trimmed.ends_with(']') && text.contains('[')
            }

            /// Attempt to recover complete JSON objects from a truncated
            /// array string.  Scans from the start and keeps objects that
            /// parse cleanly, stopping before the first broken one.
            fn recover_partial_slices(raw: &str) -> Vec<SliceSuggestion> {
                let start = match raw.find('[') {
                    Some(i) => i + 1,
                    None => return vec![],
                };
                let content = &raw[start..];
                let mut recovered = Vec::new();
                let mut depth: i32 = 0;
                let mut obj_start: Option<usize> = None;
                let chars: Vec<char> = content.chars().collect();
                let mut i = 0;
                while i < chars.len() {
                    match chars[i] {
                        '{' => {
                            if depth == 0 {
                                obj_start = Some(i);
                            }
                            depth += 1;
                        }
                        '}' => {
                            depth -= 1;
                            if depth == 0 {
                                if let Some(start_idx) = obj_start {
                                    let candidate: String = chars[start_idx..=i].iter().collect();
                                    if let Ok(s) =
                                        serde_json::from_str::<SliceSuggestion>(&candidate)
                                    {
                                        recovered.push(s);
                                    }
                                    obj_start = None;
                                }
                            }
                        }
                        _ => {}
                    }
                    i += 1;
                }
                recovered
            }

            const MAX_TOKENS_INITIAL: u32 = 4096;
            const MAX_TOKENS_RETRY: u32 = 8192;
            const MAX_TOKENS_FINAL: u32 = 16384;
            let token_budgets = [MAX_TOKENS_INITIAL, MAX_TOKENS_RETRY, MAX_TOKENS_FINAL];

            let mut suggestions: Vec<SliceSuggestion> = Vec::new();
            let mut partial_recovery = false;

            'retry: for (attempt, &budget) in token_budgets.iter().enumerate() {
                let msgs = vec![axonerai::provider::Message {
                    role: "user".into(),
                    content: user_content.clone(),
                }];
                let resp = match provider
                    .complete(msgs, None, Some(budget), Some(system_prompt.clone()))
                    .await
                {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("chump gap decompose: LLM call failed: {e:#}");
                        std::process::exit(1);
                    }
                };
                let truncated_by_provider =
                    resp.stop_reason == axonerai::provider::StopReason::MaxTokens;
                let raw_text = resp.text.unwrap_or_default();

                if looks_truncated(&raw_text) || truncated_by_provider {
                    eprintln!(
                        "chump gap decompose: response truncated at budget={budget} \
                             (stop_reason={:?}); {}",
                        if truncated_by_provider {
                            "MaxTokens"
                        } else {
                            "heuristic"
                        },
                        if attempt + 1 < token_budgets.len() {
                            format!("retrying with budget={}", token_budgets[attempt + 1])
                        } else {
                            "attempting partial recovery".to_string()
                        }
                    );
                    // Not the last attempt — try again with bigger budget.
                    if attempt + 1 < token_budgets.len() {
                        continue 'retry;
                    }
                    // Final attempt also truncated — recover partial prefix.
                    let recovered = recover_partial_slices(&raw_text);
                    if recovered.is_empty() {
                        eprintln!(
                            "chump gap decompose: failed to parse LLM response as JSON \
                                 after {} attempts; partial recovery found no complete objects",
                            token_budgets.len()
                        );
                        eprintln!(
                            "Raw response (first 500 chars): {}",
                            &raw_text[..raw_text.len().min(500)]
                        );
                        std::process::exit(1);
                    }
                    eprintln!(
                        "chump gap decompose: partial decomposition recovered — \
                             {} of potentially more slices parsed before truncation",
                        recovered.len()
                    );
                    suggestions = recovered;
                    partial_recovery = true;
                    break 'retry;
                }

                // No truncation — parse normally.
                let json_start = raw_text.find('[').unwrap_or(0);
                let json_end = raw_text.rfind(']').map(|i| i + 1).unwrap_or(raw_text.len());
                let json_owned = raw_text[json_start..json_end].to_owned();

                match serde_json::from_str(&json_owned) {
                    Ok(s) => {
                        suggestions = s;
                        break 'retry;
                    }
                    Err(e) => {
                        eprintln!("chump gap decompose: failed to parse LLM response as JSON: {e}");
                        eprintln!(
                            "Raw response (first 500 chars): {}",
                            &raw_text[..raw_text.len().min(500)]
                        );
                        std::process::exit(1);
                    }
                }
            }

            if partial_recovery {
                eprintln!(
                    "chump gap decompose: WARNING — partial decomposition only; \
                         review and re-run with a larger model or --no-description \
                         to get remaining slices"
                );
            }

            if suggestions.is_empty() {
                eprintln!("chump gap decompose: LLM returned no slices");
                std::process::exit(1);
            }

            // ── Verification pass (--verify) ────────────────────────────
            //
            // Route each slice through a stronger model to check:
            //   1. Is effort truly xs/s?
            //   2. Are ACs testable (not vague)?
            //   3. Does it overlap with sibling slices?
            //   4. Does it map back to the parent gap's intent?
            //
            // The verifier can revise title/ACs or reject a slice entirely.
            // Uses CHUMP_VERIFY_API_BASE + CHUMP_VERIFY_MODEL, or falls
            // back to ANTHROPIC_API_KEY with claude-sonnet.
            #[derive(Debug, serde::Deserialize)]
            struct VerifyVerdict {
                pass: bool,
                reason: String,
                #[serde(default)]
                revised_title: Option<String>,
                #[serde(default)]
                revised_effort: Option<String>,
                #[serde(default)]
                revised_acceptance_criteria: Option<Vec<String>>,
            }

            let suggestions = if verify {
                let verify_provider: Option<Box<dyn axonerai::provider::Provider + Send + Sync>> = {
                    let vbase = std::env::var("CHUMP_VERIFY_API_BASE")
                        .ok()
                        .filter(|s| !s.is_empty());
                    let vmodel = std::env::var("CHUMP_VERIFY_MODEL")
                        .ok()
                        .filter(|s| !s.is_empty());
                    let vkey = std::env::var("CHUMP_VERIFY_API_KEY")
                        .ok()
                        .filter(|s| !s.is_empty());
                    if let (Some(base), Some(model)) = (vbase, vmodel) {
                        let key = vkey.unwrap_or_default();
                        Some(Box::new(crate::local_openai::LocalOpenAIProvider::new(
                            base, key, model,
                        )))
                    } else if let Ok(api_key) = std::env::var("ANTHROPIC_API_KEY") {
                        if !api_key.is_empty() {
                            let model = "claude-sonnet-4-6".to_string();
                            Some(Box::new(crate::local_openai::LocalOpenAIProvider::new(
                                "https://api.anthropic.com/v1".to_string(),
                                api_key,
                                model,
                            )))
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                };

                match verify_provider {
                    None => {
                        eprintln!("chump gap decompose: --verify requested but no verify model available.");
                        eprintln!(
                            "Set CHUMP_VERIFY_API_BASE + CHUMP_VERIFY_MODEL, or ANTHROPIC_API_KEY."
                        );
                        std::process::exit(1);
                    }
                    Some(vp) => {
                        eprintln!(
                            "verifying {} slices via stronger model...",
                            suggestions.len()
                        );

                        let siblings_summary: String = suggestions
                            .iter()
                            .enumerate()
                            .map(|(i, s)| {
                                format!(
                                    "[{i}] {} ({}) — {:?}",
                                    s.title, s.effort, s.acceptance_criteria
                                )
                            })
                            .collect::<Vec<_>>()
                            .join("\n");

                        let mut verified: Vec<SliceSuggestion> = Vec::new();
                        let mut rejected = 0usize;

                        for (i, s) in suggestions.into_iter().enumerate() {
                            let verify_system = "You are a senior engineering reviewer. \
                                    You verify whether a proposed task slice is well-defined and shippable. \
                                    For each slice, check: \
                                    (1) Is the effort estimate realistic? xs means < 1 hour, s means 1-4 hours. \
                                    (2) Are the acceptance criteria testable and specific (not vague)? \
                                    (3) Does this slice overlap with any sibling slices? \
                                    (4) Does it map back to the parent gap's intent? \
                                    Output ONLY a JSON object: \
                                    {\"pass\": true/false, \"reason\": \"...\", \
                                    \"revised_title\": \"...\" (optional, only if title needs fixing), \
                                    \"revised_effort\": \"xs|s\" (optional, only if effort is wrong), \
                                    \"revised_acceptance_criteria\": [\"...\"] (optional, only if ACs need tightening)}. \
                                    Do not include any text outside the JSON object.".to_string();

                            let verify_msg = format!(
                                "Parent gap: {} — {}\nParent ACs: {}\n\n\
                                     All proposed sibling slices:\n{}\n\n\
                                     Verify this slice:\n\
                                     [{i}] Title: {}\n\
                                     Effort: {}\n\
                                     Priority: {}\n\
                                     Acceptance Criteria: {:?}",
                                parent.id,
                                parent.title,
                                ac_display,
                                siblings_summary,
                                s.title,
                                s.effort,
                                s.priority,
                                s.acceptance_criteria,
                            );

                            let vmsg = vec![axonerai::provider::Message {
                                role: "user".into(),
                                content: verify_msg,
                            }];

                            match vp
                                .complete(vmsg, None, Some(1024), Some(verify_system))
                                .await
                            {
                                Ok(vresp) => {
                                    let vtext = vresp.text.unwrap_or_default();
                                    let vj_start = vtext.find('{').unwrap_or(0);
                                    let vj_end =
                                        vtext.rfind('}').map(|j| j + 1).unwrap_or(vtext.len());
                                    let vj = &vtext[vj_start..vj_end];

                                    match serde_json::from_str::<VerifyVerdict>(vj) {
                                        Ok(verdict) => {
                                            if verdict.pass {
                                                let final_slice = SliceSuggestion {
                                                    title: verdict.revised_title.unwrap_or(s.title),
                                                    effort: verdict
                                                        .revised_effort
                                                        .unwrap_or(s.effort),
                                                    priority: s.priority,
                                                    acceptance_criteria: verdict
                                                        .revised_acceptance_criteria
                                                        .unwrap_or(s.acceptance_criteria),
                                                    depends_on: s.depends_on,
                                                };
                                                eprintln!("  [{i}] PASS: {}", verdict.reason);
                                                verified.push(final_slice);
                                            } else {
                                                eprintln!("  [{i}] REJECTED: {}", verdict.reason);
                                                rejected += 1;
                                            }
                                        }
                                        Err(_) => {
                                            eprintln!("  [{i}] WARN: could not parse verdict, keeping slice as-is");
                                            verified.push(s);
                                        }
                                    }
                                }
                                Err(e) => {
                                    eprintln!("  [{i}] WARN: verify call failed ({e:#}), keeping slice as-is");
                                    verified.push(s);
                                }
                            }
                        }

                        if rejected > 0 {
                            eprintln!(
                                "verification: {} passed, {} rejected",
                                verified.len(),
                                rejected
                            );
                        }

                        if verified.is_empty() {
                            eprintln!("chump gap decompose: all slices rejected by verifier");
                            std::process::exit(1);
                        }
                        verified
                    }
                }
            } else {
                suggestions
            };

            if json_out {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!(suggestions
                        .iter()
                        .enumerate()
                        .map(|(i, s)| {
                            serde_json::json!({
                                "index": i,
                                "title": s.title,
                                "effort": s.effort,
                                "priority": s.priority,
                                "acceptance_criteria": s.acceptance_criteria,
                                "depends_on": s.depends_on,
                            })
                        })
                        .collect::<Vec<_>>()))
                    .unwrap_or_default()
                );
            } else if !apply {
                eprintln!();
                eprintln!("Suggested slices for {} ({}):", parent.id, parent.title);
                eprintln!();
                for (i, s) in suggestions.iter().enumerate() {
                    let deps_str = if s.depends_on.is_empty() {
                        String::new()
                    } else {
                        format!(
                            " (depends on: {})",
                            s.depends_on
                                .iter()
                                .map(|d| format!("slice {d}"))
                                .collect::<Vec<_>>()
                                .join(", ")
                        )
                    };
                    eprintln!(
                        "  [{i}] {} ({}/{}){}",
                        s.title, s.priority, s.effort, deps_str
                    );
                    for ac in &s.acceptance_criteria {
                        eprintln!("      - {ac}");
                    }
                    eprintln!();
                }
                eprintln!("Run with --apply to file these slices and demote the parent to P2.");
            }

            if apply {
                let session_id = crate::ambient_stream::env_session_id()
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                let mut filed_ids: Vec<String> = Vec::new();

                for s in &suggestions {
                    let slice_title = format!(
                        "{}: {} ({} slice)",
                        parent.domain.to_uppercase(),
                        s.title,
                        parent.id
                    );
                    let effort = if s.effort == "xs" || s.effort == "s" {
                        s.effort.clone()
                    } else {
                        "s".to_string()
                    };
                    let priority = if s.priority == "P1" || s.priority == "P2" {
                        s.priority.clone()
                    } else {
                        "P1".to_string()
                    };

                    match store.reserve_verified(
                        &parent.domain,
                        &slice_title,
                        &priority,
                        &effort,
                        &session_id,
                    ) {
                        Ok(new_id) => {
                            let ac_json = serde_json::to_string(&s.acceptance_criteria)
                                .unwrap_or_else(|_| "[]".into());

                            // INFRA-2112: when --external-repo is set,
                            // merge the external_repo tag into the sub-gap's
                            // skills_required.  Format per INFRA-2116 schema:
                            // `external_repo:<owner>/<repo>`.
                            // If the gap already has skills from the LLM
                            // suggestion, append; otherwise set directly.
                            let skills_update: Option<String> = external_repo_tag.clone();

                            let _ = store.set_fields(
                                &new_id,
                                gap_store::GapFieldUpdate {
                                    acceptance_criteria: Some(ac_json),
                                    skills_required: skills_update,
                                    ..Default::default()
                                },
                            );

                            let gaps_dir = worktree_root.join("docs/gaps");
                            if gaps_dir.is_dir() {
                                let yaml_path = gaps_dir.join(format!("{}.yaml", new_id));
                                let _ = store.dump_per_file_single(&new_id, &gaps_dir);
                                let _ = std::process::Command::new("git")
                                    .args(["add", &yaml_path.to_string_lossy()])
                                    .current_dir(&worktree_root)
                                    .status();
                            }

                            eprintln!("  filed {new_id}: {slice_title}");
                            filed_ids.push(new_id);
                        }
                        Err(e) => {
                            eprintln!("  ERROR filing slice '{}': {e:#}", s.title);
                        }
                    }
                }

                // Resolve inter-slice depends_on using filed IDs
                for (i, s) in suggestions.iter().enumerate() {
                    if !s.depends_on.is_empty() && i < filed_ids.len() {
                        let dep_ids: Vec<String> = s
                            .depends_on
                            .iter()
                            .filter_map(|&idx| filed_ids.get(idx).cloned())
                            .collect();
                        if !dep_ids.is_empty() {
                            let deps_json =
                                serde_json::to_string(&dep_ids).unwrap_or_else(|_| "[]".into());
                            let _ = store.set_fields(
                                &filed_ids[i],
                                gap_store::GapFieldUpdate {
                                    depends_on: Some(deps_json),
                                    ..Default::default()
                                },
                            );
                        }
                    }
                }

                // Demote parent to P2
                let _ = store.set_fields(
                    &gap_id,
                    gap_store::GapFieldUpdate {
                        priority: Some("P2".into()),
                        notes: Some(format!(
                            "Decomposed into {} slices: {}",
                            filed_ids.len(),
                            filed_ids.join(", ")
                        )),
                        ..Default::default()
                    },
                );
                eprintln!();
                eprintln!(
                    "Decomposed {gap_id} into {} slices. Parent demoted to P2.",
                    filed_ids.len()
                );

                if json_out {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "parent": gap_id,
                            "slices": filed_ids,
                        }))
                        .unwrap_or_default()
                    );
                } else {
                    println!("{}", filed_ids.join("\n"));
                }
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

            // Classify each gap by pillar using title keyword.
            let pillars = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"];
            let mut counts: std::collections::HashMap<&str, Vec<String>> =
                pillars.iter().map(|p| (*p, Vec::new())).collect();
            let mut other: Vec<String> = Vec::new();

            for g in &pickable {
                let title_up = g.title.to_uppercase();
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
                let counts_json: std::collections::HashMap<&str, usize> =
                    pillars.iter().map(|p| (*p, counts[p].len())).collect();
                println!(
                    "{}",
                    serde_json::json!({
                        "total_pickable": total,
                        "pillars": counts_json,
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
                    match store.reserve("INFRA", &full_title, &e.priority, "m") {
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
        // INFRA-2053: `chump gap sync` — bidirectional YAML <-> state.db
        // reconciliation. Three modes (mutually exclusive):
        //   --check  : dry-run drift report; exits non-zero on drift.
        //   --pull   : YAML -> DB. Recovers from `chump gap reserve`
        //              TODO-AC overwrites (INFRA-2022 class) and from
        //              the `gap_drift_orphan` class (state.db rows w/o
        //              YAML mirror). Atomic INSERT/UPDATE per gap.
        //   --push   : DB -> YAML. Writes `docs/gaps/<ID>.yaml` for
        //              every open + in-progress gap whose YAML diverges
        //              or is missing. Atomic tempfile + rename per file
        //              with serde_yaml round-trip validation.
        //
        // --dry-run pairs with --pull and --push (--check is dry-run by
        // design). --json switches output to a single newline-delimited
        // JSON document.
        "sync" => {
            let mode_check = args.iter().any(|a| a == "--check");
            let mode_pull = args.iter().any(|a| a == "--pull");
            let mode_push = args.iter().any(|a| a == "--push");
            let dry_run = args.iter().any(|a| a == "--dry-run");
            let modes = [mode_check, mode_pull, mode_push]
                .iter()
                .filter(|m| **m)
                .count();
            if modes == 0 {
                eprintln!(
                    "Usage: chump gap sync (--check | --pull | --push) [--dry-run] [--json] \
                         [--state-db PATH] [--gaps-dir PATH]\n\
                         \n\
                         --check  drift report; exits non-zero on drift (no mutations)\n\
                         --pull   YAML -> DB (recovers from TODO-AC overwrites)\n\
                         --push   DB -> YAML for open + in-progress gaps\n\
                         --dry-run  preview pull/push without writes"
                );
                std::process::exit(2);
            }
            if modes > 1 {
                eprintln!("chump gap sync: --check, --pull, --push are mutually exclusive");
                std::process::exit(2);
            }

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

            if mode_pull {
                match gap_store::sync::sync_pull(&sync_store, &gaps_dir, dry_run) {
                    Ok(report) => {
                        if json_out {
                            let summary = serde_json::json!({
                                "mode": "pull",
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
                                "{}chump gap sync --pull: {} inserted, {} updated, {} unchanged",
                                prefix, report.inserted, report.updated, report.skipped
                            );
                            if !report.changed_ids.is_empty() {
                                println!("  changed: {}", report.changed_ids.join(", "));
                            }
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap sync --pull: {e:#}");
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
            eprintln!("  set              <GAP-ID> [--title T] [--description D] [--priority P]");
            eprintln!("                             [--effort E] [--status S] [--notes N]");
            eprintln!(
                    "                             [--source-doc S] [--opened-date D] [--closed-date D] [--closed-pr N]"
                );
            eprintln!("                             [--acceptance-criteria \"a|b|c\"] [--depends-on \"X-1,X-2\"]");
            eprintln!("  decompose        <GAP-ID> [--apply] [--json] [--dry-run] [--no-description] [--external-repo <owner/repo|path>] [--clone-path <path>]  # LLM-assisted slicing");
            eprintln!("  dep-clean        [--apply] [--json]  # strip depends_on entries pointing at done gaps");
            eprintln!("  dump             [--out PATH] [--per-file [--out-dir docs/gaps/]]");
            eprintln!("  import           [--yaml docs/gaps.yaml]");
            eprintln!("  restore          --from-sql  # rebuild state.db from .chump/state.sql (INFRA-538)");
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
            eprintln!("  sync             (--check | --pull | --push) [--dry-run] [--json] [--state-db PATH] [--gaps-dir PATH]");
            eprintln!("                                # INFRA-2053: bidirectional YAML <-> state.db reconciliation");
            eprintln!("  backfill-external-repo [--apply] [--owner-repo owner/repo]");
            eprintln!("                                # MISSION-041: tag gaps with external_repo: in skills_required");
            std::process::exit(2);
        }
    }

    Ok(())
}
