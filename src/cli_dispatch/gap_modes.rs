//! Core `chump gap` registry CRUD, reservation, claim, preflight, and ship subcommands.

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

pub(crate) async fn dispatch_gap_or_tail(args: Vec<String>) -> Result<()> {
    if args.get(1).map(String::as_str) == Some("gap") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");

        // INFRA-8061: the UNIVERSAL gap-intake filer — one portable filing path
        // (POST CHUMP_GAP_URL, durable local spool + retry). Needs no local
        // store, no tailscale, no SSH; usable from the Mac, cuphead, cloud
        // ephemeral agents, and a stranger running their own chump. Handled
        // before any store/worktree resolution below since it writes only over
        // HTTP + a local spool file.
        if subcmd == "file" {
            match gap_file::run(&args).await {
                Ok(()) => std::process::exit(0),
                Err(e) => {
                    eprintln!("chump gap file: {e}");
                    std::process::exit(1);
                }
            }
        }

        let repo_root = repo_path::repo_root();
        // INFRA-8190 (Phase R R4): print the ONE resolved gap-store path and
        // why, WITHOUT opening (and so creating) it. Operators and the
        // gap-store-single-source gate compare this across processes.
        if subcmd == "store-path" {
            let r = gap_store::store_path::resolve(&repo_root);
            if args.iter().any(|a| a == "--json") {
                println!(
                    "{}",
                    serde_json::json!({
                        "path": r.path.display().to_string(),
                        "source": r.source.as_str(),
                        "reason": r.reason(),
                        "checkout": r.checkout.as_ref().map(|c| c.display().to_string()),
                        "repo_root": repo_root.display().to_string(),
                        "exists": r.path.exists(),
                    })
                );
            } else {
                println!("{}", r.path.display());
                eprintln!("source: {} ({})", r.source.as_str(), r.reason());
            }
            std::process::exit(0);
        }
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
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let json_out = args.iter().any(|a| a == "--json");

        // CREDIBLE-1565: every state-changing `chump gap` verb (set, ship,
        // link-pr, unlink-pr, reserve) rejects unknown flags with exit code 2
        // and handles --help/-h with exit code 0 BEFORE opening state.db or
        // routing to the canonical server, so zero writes occur.
        match validate_gap_mutation_args(subcmd, args.get(3..).unwrap_or(&[])) {
            Ok(GapMutationArgCheck::Help(usage)) => {
                println!("{usage}");
                return Ok(());
            }
            Ok(GapMutationArgCheck::Valid) => {}
            Err(msg) => {
                eprintln!("{msg}");
                std::process::exit(2);
            }
        }

        // A client explicitly configured for canonical-server mode must not
        // touch its local state.db before routing. Otherwise a corrupt or
        // stale Mac replica can block the very recovery path intended to
        // replace it. The server performs the normal validation and mutation
        // against its own managed checkout; failures are deliberately
        // fail-closed below.
        if gap_route::canonical_server_mode()
            && matches!(
                subcmd,
                "reserve" | "set" | "update" | "modify" | "edit" | "change" | "ship"
            )
        {
            let server_base = std::env::var(gap_route::GAP_SERVER_ENV)
                .unwrap_or_default()
                .trim()
                .to_string();
            if server_base.is_empty() {
                eprintln!(
                    "chump gap: CHUMP_GAP_SERVER_MODE=canonical requires a non-empty CHUMP_GAP_SERVER; refusing a local write to prevent split gap state"
                );
                std::process::exit(2);
            }
            let token = std::env::var(gap_route::BATPHONE_TOKEN_ENV).unwrap_or_default();
            let routed = match subcmd {
                "reserve" => {
                    let has_flag_domain = args.iter().any(|a| a == "--domain");
                    let domain = flag("--domain").or_else(|| {
                        args.get(3)
                            .and_then(|arg| (!arg.starts_with('-')).then(|| arg.clone()))
                    });
                    let domain = domain.unwrap_or_else(|| {
                        eprintln!("Usage: chump gap reserve --domain D --title T");
                        std::process::exit(2);
                    });
                    let title = flag("--title").unwrap_or_else(|| {
                        if has_flag_domain {
                            eprintln!("--title required when using --domain");
                            std::process::exit(2);
                        }
                        args.get(4..)
                            .map(|tail| tail.join(" "))
                            .filter(|value| !value.is_empty())
                            .unwrap_or_else(|| "New gap".into())
                    });
                    let ac_vals = collect_acceptance_criteria_flag_values(&args, 3);
                    let acceptance_criteria = if ac_vals.is_empty() {
                        None
                    } else if ac_vals.len() == 1 && ac_vals[0].contains('|') {
                        Some(
                            ac_vals[0]
                                .split('|')
                                .map(str::to_string)
                                .collect::<Vec<_>>(),
                        )
                    } else {
                        Some(ac_vals)
                    };
                    let body = gap_route::GapMutationBody {
                        op: "reserve".into(),
                        domain: Some(domain),
                        title: Some(title),
                        priority: flag("--priority"),
                        effort: flag("--effort"),
                        outcome: flag("--outcome"),
                        evidence: flag("--evidence"),
                        acceptance_criteria,
                        external_repo: flag("--external-repo"),
                        force: Some(args.iter().any(|arg| arg == "--force")),
                        skip_obs_acs: Some(args.iter().any(|arg| arg == "--skip-obs-acs")),
                        ..Default::default()
                    };
                    gap_route::route_gap_mutation(&server_base, &token, &body).await
                }
                "ship" => {
                    let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N]");
                        std::process::exit(2);
                    });
                    let closed_pr = match flag("--closed-pr") {
                        Some(value) => match value.trim().parse::<i64>() {
                            Ok(value) if value > 0 => Some(value),
                            _ => {
                                eprintln!(
                                    "chump gap ship: --closed-pr expects a positive integer (got {:?})",
                                    value
                                );
                                std::process::exit(2);
                            }
                        },
                        None => None,
                    };
                    let session = flag("--session")
                        .or_else(crate::ambient_stream::env_session_id)
                        .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                    let body = gap_route::GapMutationBody {
                        op: "ship".into(),
                        gap_id: Some(gap_id),
                        closed_pr,
                        session: Some(session),
                        ..Default::default()
                    };
                    gap_route::route_gap_mutation(&server_base, &token, &body).await
                }
                "set" | "update" | "modify" | "edit" | "change" => {
                    let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump gap set <GAP-ID> [--title T] [--description D] [--priority P]");
                        std::process::exit(2);
                    });
                    if gap_id.starts_with("--") {
                        eprintln!(
                            "Error: unknown flag {:?}. Did you forget the GAP-ID?",
                            gap_id
                        );
                        std::process::exit(2);
                    }
                    let acceptance_values: Vec<String> =
                        collect_acceptance_criteria_flag_values(&args, 4);
                    let acceptance_criteria =
                        if acceptance_values.len() == 1 && acceptance_values[0].contains('|') {
                            Some(
                                acceptance_values[0]
                                    .split('|')
                                    .map(str::to_string)
                                    .collect(),
                            )
                        } else if acceptance_values.is_empty() {
                            None
                        } else {
                            Some(acceptance_values)
                        };
                    let closed_pr = match flag("--closed-pr") {
                        Some(value) => match value.trim().parse::<i64>() {
                            Ok(value) if value > 0 => Some(value),
                            _ => {
                                eprintln!(
                                    "chump gap set: --closed-pr expects a positive integer (got {:?})",
                                    value
                                );
                                std::process::exit(2);
                            }
                        },
                        None => None,
                    };
                    let body = gap_route::GapMutationBody {
                        op: "set".into(),
                        gap_id: Some(gap_id),
                        title: flag("--title"),
                        description: flag("--description"),
                        priority: flag("--priority"),
                        effort: flag("--effort"),
                        status: flag("--status"),
                        outcome: flag("--outcome"),
                        acceptance_criteria,
                        depends_on: flag("--depends-on"),
                        notes: flag("--notes"),
                        add_note: flag("--add-note"),
                        source_doc: flag("--source-doc"),
                        opened_date: flag("--opened-date"),
                        closed_date: flag("--closed-date"),
                        closed_pr,
                        skills_required: flag("--skills-required"),
                        preferred_backend: flag("--preferred-backend"),
                        preferred_machine: flag("--preferred-machine"),
                        estimated_minutes: flag("--estimated-minutes"),
                        required_model: flag("--required-model"),
                        evidence: flag("--evidence"),
                        artifact_type: flag("--artifact-type"),
                        ..Default::default()
                    };
                    gap_route::route_gap_mutation(&server_base, &token, &body).await
                }
                _ => unreachable!("canonical mutation subcommand already matched"),
            };
            match routed {
                Ok(result) => {
                    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                        kind: "gap_mutation_routed_to_server".to_string(),
                        source: Some(format!("chump_gap_{}", result.op)),
                        gap: Some(result.gap_id.clone()),
                        fields: vec![
                            ("op".to_string(), result.op.clone()),
                            ("server".to_string(), server_base),
                            ("behind".to_string(), "unverified-canonical".to_string()),
                        ],
                        ..Default::default()
                    });
                    match result.op.as_str() {
                        "reserve" if json_out => {
                            println!("{{\"id\":\"{}\",\"yaml_path\":\"\"}}", result.gap_id)
                        }
                        "reserve" => println!("{}", result.gap_id),
                        "ship" => println!("shipped {}", result.gap_id),
                        _ => println!("updated {}", result.gap_id),
                    }
                    return Ok(());
                }
                Err(error) => {
                    eprintln!(
                        "chump gap: canonical fleet-server routing failed ({error:#}); refusing a local write to prevent split gap state"
                    );
                    std::process::exit(1);
                }
            }
        }

        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump gap: cannot open state.db: {e:#}");
                std::process::exit(1);
            }
        };

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
                            up.contains("TODO")
                                || item.contains("TBD")
                                || item.contains("<fill in>")
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
                                    if let Ok(parsed) =
                                        serde_json::from_str::<serde_json::Value>(raw)
                                    {
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
                                "closed_pr" => {
                                    g.closed_pr.map(|n| n.to_string()).unwrap_or_default()
                                }
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
                                    if let Some(ms) =
                                        parsed.get("merge_sha").and_then(|v| v.as_str())
                                    {
                                        println!("    merge_sha: {}", &ms[..ms.len().min(7)]);
                                    }
                                    // Per-PR backwards-compat shape: pr_url + merge_sha.
                                    if let Some(pu) = parsed.get("pr_url").and_then(|v| v.as_str())
                                    {
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
                // INFRA-8124: --priority <P> filters to a single priority (P0, P1, P2, P3).
                let priority_filter = flag("--priority");
                // INFRA-8124: --effort <E> filters to a single effort (xs, s, m, l).
                let effort_filter = flag("--effort");
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
                // INFRA-3687 part 3: loud, non-blocking staleness warning.
                // stderr only — stdout is script-parsed (--json/--csv/plain
                // ids), so this must never appear there and must never
                // block the read. Deliberately doesn't force a fetch (this
                // is a hot/frequent read path); it reports against whatever
                // origin/main ref this checkout already knows.
                if let Some(behind) = store.behind_origin_main() {
                    if behind > 0 {
                        eprintln!(
                            "\u{26A0} gap list may be STALE: checkout is {behind} commit(s) \
                             behind origin/main — run `git pull` for canonical state."
                        );
                    }
                }
                match store.list(status_filter.as_deref()) {
                    Ok(all_gaps) => {
                        // Apply filters before any output path.
                        // INFRA-8124: filter by priority and effort if specified.
                        let gaps: Vec<_> = all_gaps
                            .into_iter()
                            .filter(|g| {
                                if let Some(ref pf) = priority_filter {
                                    if g.priority != *pf {
                                        return false;
                                    }
                                }
                                if let Some(ref ef) = effort_filter {
                                    if g.effort != *ef {
                                        return false;
                                    }
                                }
                                // Apply --since filter.
                                // Date strings are YYYY-MM-DD, so lexicographic >= works.
                                if let Some(ref cutoff) = since_cutoff {
                                    (!g.opened_date.is_empty()
                                        && g.opened_date.as_str() >= cutoff.as_str())
                                        || (!g.closed_date.is_empty()
                                            && g.closed_date.as_str() >= cutoff.as_str())
                                } else {
                                    true
                                }
                            })
                            .collect();
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
                                println!(
                                    "{}",
                                    serde_json::to_string_pretty(&obj).unwrap_or_default()
                                );
                            } else if let Some(ref cutoff) = since_cutoff {
                                // EFFECTIVE-018: wrap with since_cutoff so tooling can inspect the window.
                                let obj = serde_json::json!({
                                    "since_cutoff": cutoff,
                                    "gaps": gaps,
                                });
                                println!(
                                    "{}",
                                    serde_json::to_string_pretty(&obj).unwrap_or_default()
                                );
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
                                let ac_warn =
                                    if is_acceptance_criteria_vague(&g.acceptance_criteria) {
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
            // `chump gap pillar-share` (CREDIBLE-072) — one-line 7-day
            // per-pillar merge share, flagging pillars over the reserve-time
            // cap and EFFECTIVE/CREDIBLE under the floor.
            "pillar-share" => {
                let rows = store.list(None).unwrap_or_default();
                let shares = pillar_cap::compute_shares(
                    rows.iter().map(|g| {
                        (
                            g.title.as_str(),
                            g.domain.as_str(),
                            g.status.as_str(),
                            g.closed_at,
                        )
                    }),
                    chrono::Utc::now().timestamp(),
                );
                println!("{}", shares.status_line());
            }
            // INFRA-8043: one-time triage of open P1 gaps that have no outcome
            // (MISSION-045 requires one). Demotes them to P2 with an audit note;
            // dry-run unless --apply. Idempotent.
            "triage-unanchored" => {
                let apply = args.iter().any(|a| a == "--apply");
                match store.demote_unanchored_p1(!apply) {
                    Ok(ids) => {
                        let verb = if apply { "demoted" } else { "would demote" };
                        for id in &ids {
                            println!("{verb} {id}: P1 -> P2 (no outcome)");
                        }
                        println!(
                            "[triage-unanchored] {} open P1 gap(s) without an outcome {}",
                            ids.len(),
                            if apply {
                                "demoted to P2"
                            } else {
                                "(dry-run; pass --apply)"
                            }
                        );
                    }
                    Err(e) => {
                        eprintln!("chump gap triage-unanchored failed: {e:#}");
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
                let mut priority = flag("--priority").unwrap_or_else(|| "P2".into());
                let p0_override_reason = flag("--p0-override").or_else(|| flag("--cap-override"));
                let reserve_description = flag("--description").unwrap_or_default();
                let all_rows_for_reserve = store.list(None).unwrap_or_default();

                // ── CREDIBLE-1543 AC3: slice / sub-gap priority clamp to parent umbrella ──
                if p0_override_reason.is_none() {
                    if let Some((parent_id, parent_prio)) = detect_parent_slice_priority_clamp(
                        &title,
                        &reserve_description,
                        &priority,
                        &all_rows_for_reserve,
                    ) {
                        if !args.iter().any(|a| a == "--quiet") {
                            eprintln!(
                                "[reserve] CREDIBLE-1543: clamping slice priority {priority} -> {parent_prio} to match parent {parent_id} (pass --p0-override <reason> to override)"
                            );
                        }
                        priority = parent_prio;
                    }
                }

                // ── CREDIBLE-1543 AC1/AC2: open P0 budget (5) admission guard ────────────
                let mut pending_p0_override: Option<(usize, String)> = None;
                if priority == "P0" {
                    let open_p0_count = count_open_manual_p0s(&all_rows_for_reserve, None);
                    if open_p0_count >= OPEN_P0_BUDGET {
                        match p0_override_reason.as_deref().map(str::trim) {
                            Some(reason) if !reason.is_empty() => {
                                pending_p0_override = Some((open_p0_count, reason.to_string()));
                            }
                            _ => {
                                eprintln!(
                                    "chump gap reserve: open P0 budget ({OPEN_P0_BUDGET}) exceeded — currently {open_p0_count} open P0 gaps (CREDIBLE-1543)."
                                );
                                eprintln!(
                                    "Demote or close an existing P0 first, file at P1/P2, or pass --p0-override <reason> (audited to ambient.jsonl)."
                                );
                                std::process::exit(1);
                            }
                        }
                    }
                }

                // ── CREDIBLE-072: per-pillar weekly merge-share cap / floor ─────
                // A NEW gap in a pillar that already holds >30% of the last 7
                // days' merges is demoted to P2; when EFFECTIVE+CREDIBLE are
                // under 50% combined, a NEW gap in either is bumped one tier
                // (P0 bumps held to the P0 budget). `--cap-override <reason>`
                // keeps the requested priority and is logged. Every decision
                // other than "keep" emits kind=pillar_cap_demote.
                let mut pillar_cap_event: Option<String> = None;
                if pillar_cap::enabled() {
                    if let Some(pillar) = pillar_cap::pillar_of(&title, &domain) {
                        let rows = store.list(None).unwrap_or_default();
                        let shares = pillar_cap::compute_shares(
                            rows.iter().map(|g| {
                                (
                                    g.title.as_str(),
                                    g.domain.as_str(),
                                    g.status.as_str(),
                                    g.closed_at,
                                )
                            }),
                            chrono::Utc::now().timestamp(),
                        );
                        let open_p0 = rows
                            .iter()
                            .filter(|g| g.status == "open" && g.priority == "P0")
                            .count();
                        let cap_override = flag("--cap-override");
                        let decision = pillar_cap::decide(pillar, &priority, &shares, open_p0);
                        let (decision_label, new_priority) = match (&cap_override, &decision) {
                            (_, pillar_cap::Decision::Keep) => ("keep", None),
                            (Some(_), _) => ("override", None),
                            (None, pillar_cap::Decision::Demote { to })
                            | (None, pillar_cap::Decision::Bump { to }) => {
                                (decision.label(), Some(to.to_string()))
                            }
                        };
                        if decision_label != "keep" {
                            let from = priority.clone();
                            let to = new_priority.clone().unwrap_or_else(|| priority.clone());
                            if !args.iter().any(|a| a == "--quiet") {
                                eprintln!(
                                    "[reserve] CREDIBLE-072: {pillar} is {:.0}% of 7d merges — {decision_label} {from} → {to}",
                                    shares.pct(pillar)
                                );
                            }
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            let reason = cap_override
                                .clone()
                                .unwrap_or_default()
                                .replace(['"', '\\'], "");
                            // gap_id is filled in once the reserve succeeds.
                            pillar_cap_event = Some(format!(
                                r#"{{"ts":"{ts}","kind":"pillar_cap_demote","gap_id":"{{GAP_ID}}","pillar":"{pillar}","current_share":{:.1},"decision":"{decision_label}","from":"{from}","to":"{to}","override_reason":"{reason}"}}"#,
                                shares.pct(pillar)
                            ));
                        }
                        if let Some(p) = new_priority {
                            priority = p;
                        }
                    }
                }
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
                let reserve_ac_values = collect_acceptance_criteria_flag_values(&args, 3);
                let custom_acceptance_criteria = if reserve_ac_values.is_empty() {
                    None
                } else {
                    Some(reserve_ac_values)
                };

                // INFRA-756 / CREDIBLE-1558: compute acceptance_criteria. Default to 4 obs-AC templates
                // unless --skip-obs-acs is set or --acceptance-criteria is provided.
                let acceptance_criteria_json = match custom_acceptance_criteria {
                    Some(vals) => {
                        if vals.len() == 1 && vals[0].contains('|') {
                            let parts: Vec<&str> = vals[0].split('|').collect();
                            serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
                        } else {
                            serde_json::to_string(&vals).unwrap_or_else(|_| "[]".into())
                        }
                    }
                    None if !skip_obs_acs => {
                        // EFFECTIVE-294: concrete, claimable default AC (no TODO
                        // placeholders) so a reserved gap is immediately pickable.
                        // The old obs-AC TODO template left ~32% of the open queue
                        // unclaimable. The title carries the *what*; these carry the
                        // *done-bar*. For gap-specific AC, run `chump gap decompose`.
                        let acs = default_acceptance_criteria(&title, &domain);
                        serde_json::to_string(&acs).unwrap_or_else(|_| "[]".into())
                    }
                    _ => "[]".into(),
                };

                // ── CREDIBLE-1270: acceptance-criteria gate for P0/P1 ──────────────
                // A P0/P1 gap with empty acceptance_criteria is unpickable in
                // practice (audit-priorities already flags "vague pickable" gaps —
                // this closes the gate at file time instead of catching it after
                // the fact). Only the explicit `[]` case (--skip-obs-acs with no
                // --acceptance-criteria) trips the gate; the default obs-AC
                // template above already fills acceptance_criteria_json for the
                // common path, so this fires rarely. Bypass: --no-ac-required
                // (audited to ambient.jsonl), same shape as MISSION-045 below.
                {
                    let no_ac_required = args.iter().any(|a| a == "--no-ac-required");
                    let enforce_priorities = ["P0", "P1"];
                    if enforce_priorities.contains(&priority.as_str())
                        && acceptance_criteria_json == "[]"
                    {
                        if !no_ac_required {
                            eprintln!();
                            eprintln!(
                                "chump gap reserve: P0/P1 gaps require acceptance criteria (CREDIBLE-1270)."
                            );
                            eprintln!(
                                "Pass --acceptance-criteria \"bullet one|bullet two\" (or drop --skip-obs-acs to use the default template)."
                            );
                            eprintln!(
                                "Bypass: --no-ac-required (audited). P2/P3 gaps are unaffected."
                            );
                            std::process::exit(1);
                        }
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let ambient_path = worktree_root.join(".chump-locks").join("ambient.jsonl");
                        let safe_domain = domain.replace(['"', '\\'], "");
                        let safe_title = title.replace(['"', '\\'], "");
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            use std::io::Write;
                            let _ = writeln!(
                                f,
                                r#"{{"ts":"{ts}","kind":"ac_gate_bypassed","priority":"{priority}","domain":"{safe_domain}","title":"{safe_title}","bypass_reason":"--no-ac-required flag"}}"#
                            );
                        }
                        if !quiet {
                            eprintln!(
                                "[reserve] WARN: ac_gate_bypassed emitted (bypass=--no-ac-required flag)"
                            );
                        }
                    }
                }
                // ── end CREDIBLE-1270 acceptance-criteria gate ──────────────────────

                // FLEET-029: ambient glance before allocating ID
                if !force && std::env::var("FLEET_029_AMBIENT_GLANCE_SKIP").is_err() {
                    let glance_script =
                        repo_path::repo_root().join("scripts/coord/chump-ambient-glance.sh");
                    if glance_script.is_file() {
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
                            eprintln!(
                                "          Either rewrite per the suggestions above, OR pass"
                            );
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
                // ZERO-WASTE-045: near-matches surfaced by either the state.db
                // check below or the Almanac-corpus check further down get
                // accumulated here, then written into the new gap's `notes`
                // field after reserve succeeds — so a later audit can see the
                // dupe was *considered*, not missed (AC2).
                let mut dedupe_considered: Vec<String> = Vec::new();
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
                                eprintln!("[reserve] INFRA-1149: title similarity check — proposed: \"{}\"", title);
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
                                    dedupe_considered.push(format!(
                                        "state.db near-match {top_id} (score {top_score:.2})"
                                    ));
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
                                    dedupe_considered.push(format!(
                                        "state.db near-match {top_id} (score {top_score:.2})"
                                    ));
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

                // ── ZERO-WASTE-045: Almanac-corpus dedupe check ──────────────────────
                // The state.db check above only sees `open` gaps + `done` gaps closed
                // within the last 30 days. Almanac's index already holds all 3,489+
                // rows under docs/gaps/ (open AND long-shipped), so query it too — the
                // DOC-082 failures this gap fixes were all re-filing something already
                // SHIPPED, not something open. AC4: never a silent skip — if Almanac
                // isn't reachable, say so loudly rather than pretending the corpus was
                // searched.
                if similarity_enabled {
                    let ambient_path = worktree_root.join(".chump-locks").join("ambient.jsonl");
                    let ts = unix_ts();
                    if !crate::almanac_tool::almanac_available() {
                        eprintln!(
                            "[reserve] ZERO-WASTE-045: Almanac dedupe check DID NOT RUN (almanac \
                             unavailable) — dedupe coverage is limited to state.db's open + \
                             30-day-closed window; long-shipped duplicates will not be caught."
                        );
                        let _ = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                            .and_then(|mut f| {
                                use std::io::Write;
                                writeln!(
                                    f,
                                    r#"{{"ts":"{ts}","kind":"gap_reserve_dedupe_check_skipped","reason":"almanac_unavailable"}}"#
                                )
                            });
                    } else {
                        match crate::almanac_tool::search_gap_corpus(&title) {
                            Err(e) => {
                                eprintln!(
                                    "[reserve] ZERO-WASTE-045: Almanac dedupe check DID NOT RUN \
                                     (search error: {e}) — dedupe coverage is limited to \
                                     state.db's open + 30-day-closed window."
                                );
                                let _ = std::fs::OpenOptions::new()
                                    .append(true)
                                    .create(true)
                                    .open(&ambient_path)
                                    .and_then(|mut f| {
                                        use std::io::Write;
                                        writeln!(
                                            f,
                                            r#"{{"ts":"{ts}","kind":"gap_reserve_dedupe_check_skipped","reason":"almanac_search_error"}}"#
                                        )
                                    });
                            }
                            Ok(output) => {
                                let candidate_ids =
                                    crate::almanac_tool::extract_gap_ids_from_search_output(
                                        &output,
                                    );
                                let warn_threshold: f64 =
                                    std::env::var("CHUMP_GAP_RESERVE_SIMILARITY_WARN")
                                        .ok()
                                        .and_then(|v| v.parse().ok())
                                        .unwrap_or(0.65);
                                let hits = gap_store::shipped_gap_dedupe_candidates(
                                    &worktree_root,
                                    &title,
                                    &candidate_ids,
                                    warn_threshold,
                                );
                                if !hits.is_empty() {
                                    eprintln!();
                                    eprintln!(
                                        "[reserve] ZERO-WASTE-045: Almanac corpus dedupe check — \
                                         proposed: \"{}\"",
                                        title
                                    );
                                    for (hid, htitle, hstatus, hscore) in &hits {
                                        eprintln!(
                                            "  {:.2}  {} ({}) — \"{}\"  [docs/gaps/{}.yaml]",
                                            hscore, hid, hstatus, htitle, hid
                                        );
                                        dedupe_considered.push(format!(
                                            "almanac near-match {hid} status={hstatus} (score {hscore:.2})"
                                        ));
                                        let safe_title = title.replace(['"', '\\'], "");
                                        let _ = std::fs::OpenOptions::new()
                                            .append(true)
                                            .create(true)
                                            .open(&ambient_path)
                                            .and_then(|mut f| {
                                                use std::io::Write;
                                                writeln!(
                                                    f,
                                                    r#"{{"ts":"{ts}","kind":"gap_reserve_almanac_dedupe_hit","proposed_title":"{safe_title}","match_id":"{hid}","match_status":"{hstatus}","match_score":{hscore:.3}}}"#
                                                )
                                            });
                                    }
                                    if force_duplicate {
                                        eprintln!(
                                            "[reserve] --force-duplicate: proceeding despite the \
                                             above; recorded in the new gap's notes for audit."
                                        );
                                    } else {
                                        eprintln!(
                                            "[reserve] advisory only — proceeding. Pass \
                                             --force-duplicate to record an explicit override, or \
                                             investigate the match(es) above first."
                                        );
                                    }
                                }
                            }
                        }
                    }
                }

                // ── INFRA-6701: recently-merged-PR overlap advisory ──────────────────
                // The state.db (INFRA-1149) and Almanac (ZERO-WASTE-045) checks above
                // catch duplicate *gaps*; the FLEET-029 ambient glance catches overlap
                // with *open* PRs. None of them folds a new gap against PRs that
                // recently MERGED — the exact shape of the "already shipped, just
                // closing the gap" bookkeeping-PR class (INFRA-6701 convergence audit:
                // 12 such PRs in 6 days; gap store growing ~18:1 vs drain). Advisory
                // ONLY: it links the likely-duplicate merged PR(s) and records them in
                // the new gap's notes so a human/curator can supersede or dismiss. It
                // NEVER exits — gaps are truth; we surface duplicates, we do not
                // throttle generation.
                if similarity_enabled {
                    let window_days: i64 = std::env::var("CHUMP_GAP_RESERVE_MERGED_PR_WINDOW_DAYS")
                        .ok()
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(7);
                    let merged_pr_warn_threshold: f64 =
                        std::env::var("CHUMP_GAP_RESERVE_SIMILARITY_WARN")
                            .ok()
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(0.65);
                    let pr_hits = gap_store::recently_merged_pr_dedupe_candidates(
                        &worktree_root,
                        &title,
                        window_days,
                        merged_pr_warn_threshold,
                    );
                    if !pr_hits.is_empty() {
                        let ambient_path = worktree_root.join(".chump-locks").join("ambient.jsonl");
                        let ts = unix_ts();
                        eprintln!();
                        eprintln!(
                            "[reserve] INFRA-6701: recently-merged-PR overlap — proposed: \"{}\"",
                            title
                        );
                        for (num, ptitle, merged_at, score) in &pr_hits {
                            eprintln!(
                                "  {:.2}  PR #{} (merged {}) — \"{}\"",
                                score, num, merged_at, ptitle
                            );
                            dedupe_considered.push(format!(
                                "merged-PR near-match #{num} (score {score:.2}, merged {merged_at})"
                            ));
                            let safe_title = title.replace(['"', '\\'], "");
                            let safe_ptitle = ptitle.replace(['"', '\\'], "");
                            let safe_merged = merged_at.replace(['"', '\\'], "");
                            // scanner-anchor: "kind":"gap_reserve_merged_pr_overlap"
                            let _ = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                                .and_then(|mut f| {
                                    use std::io::Write;
                                    writeln!(
                                        f,
                                        r#"{{"ts":"{ts}","kind":"gap_reserve_merged_pr_overlap","proposed_title":"{safe_title}","match_pr":{num},"match_title":"{safe_ptitle}","match_score":{score:.3},"merged_at":"{safe_merged}"}}"#
                                    )
                                });
                        }
                        eprintln!(
                            "[reserve] advisory only — proceeding. Check whether the above \
                             already ships this work before claiming; pass --force-duplicate to \
                             record an explicit override."
                        );
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
                            } else if g_up.starts_with("ZERO-WASTE")
                                || g_up.starts_with("ZERO_WASTE")
                            {
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

                        // EFFECTIVE-294: percentage thresholds are meaningless on a
                        // tiny pool — with < 10 pickable gaps the second same-pillar
                        // reserve is already "≥50% of pool" and gets blocked, which
                        // breaks fresh `chump bootstrap` repos and every CI fixture
                        // DB (surfaced when concrete default AC made fixture gaps
                        // pickable). The gate exists to correct drift in a mature
                        // queue, not to police the first handful of gaps.
                        let min_pool_for_balance: usize =
                            std::env::var("CHUMP_PILLAR_BALANCE_MIN_POOL")
                                .ok()
                                .and_then(|v| v.parse().ok())
                                .unwrap_or(10);
                        if total_pickable >= min_pool_for_balance {
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
                                    eprintln!("[reserve]   Under-fed: {}. Consider filing an {} gap instead.", underfed.join(", "), underfed[0]);
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
                            eprintln!(
                                "See docs/process/DURABLE_FIX_DOCTRINE.md §pre-workaround-test."
                            );
                            eprintln!(
                                "Bypass: --no-evidence-required (adds audit trailer), or CHUMP_GAP_RESERVE_NO_EVIDENCE=1."
                            );
                            std::process::exit(1);
                        }

                        if (evidence_text.is_empty()) && (no_evidence_required || bypass_env) {
                            // Bypass path — emit audit event so the pattern is visible.
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            let ambient_path =
                                worktree_root.join(".chump-locks").join("ambient.jsonl");
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

                // ── MISSION-045: outcome gate for P0/P1 (anti-bloat keystone) ──
                // Every P0/P1 gap must trace to a real outcome (a row in the
                // outcomes table). Filing a high-priority gap with no outcome is
                // how the backlog fills with self-referential meta-work — the
                // 2026-07-26 bankruptcy closed 798 such untraced gaps. P2/P3 stay
                // permissionless (exploratory). Bypass: --no-outcome-required,
                // audited so the pattern stays visible. (No env-var bypass — the
                // EFFECTIVE-094 debt-ceiling forbids adding new bypass vars; the
                // audited CLI flag is the only escape hatch.)
                //
                // Empty-outcomes skip: if the outcomes table is empty, there is
                // nothing to trace to, so the gate is vacuous — enforce only once
                // at least one outcome exists (always true in the real repo, which
                // carries MISSION-010/CREDIBLE-000/… ). This keeps every
                // seed-a-fixture test green with zero bypass vars, while the gate
                // stays fully live in production.
                {
                    let enforce_priorities = ["P0", "P1"];
                    if enforce_priorities.contains(&priority.as_str()) {
                        let no_outcome_required = args.iter().any(|a| a == "--no-outcome-required");
                        let has_outcomes = store
                            .list_outcomes()
                            .map(|o| !o.is_empty())
                            .unwrap_or(false);
                        let oid = reserve_outcome_id
                            .as_deref()
                            .unwrap_or("")
                            .trim()
                            .to_string();
                        let outcome_valid =
                            !oid.is_empty() && matches!(store.get_outcome(&oid), Ok(Some(_)));

                        if oid.is_empty() && !no_outcome_required && has_outcomes {
                            eprintln!();
                            eprintln!(
                                "chump gap: P0/P1 gaps require --outcome <id> (MISSION-045 anti-bloat gate)."
                            );
                            eprintln!("Every high-priority gap must trace to a real outcome:");
                            if let Ok(outs) = store.list_outcomes() {
                                for o in outs.iter().take(12) {
                                    eprintln!("  {}  {}", o.id, o.title);
                                }
                            }
                            eprintln!(
                                "Bypass: --no-outcome-required (audited). P2/P3 need no outcome."
                            );
                            std::process::exit(1);
                        }
                        if !oid.is_empty() && !outcome_valid {
                            eprintln!();
                            eprintln!("chump gap: --outcome '{oid}' is not a valid outcome id.");
                            eprintln!(
                                "Run `chump outcome list` for valid outcomes, or create one first."
                            );
                            std::process::exit(1);
                        }
                        if oid.is_empty() && no_outcome_required {
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            let ambient_path =
                                worktree_root.join(".chump-locks").join("ambient.jsonl");
                            let safe_domain = domain.replace(['"', '\\'], "");
                            let safe_title = title.replace(['"', '\\'], "");
                            let bypass_reason = "--no-outcome-required flag";
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                use std::io::Write;
                                let _ = writeln!(
                                    f,
                                    r#"{{"ts":"{ts}","kind":"outcome_gate_bypassed","priority":"{priority}","domain":"{safe_domain}","title":"{safe_title}","bypass_reason":"{bypass_reason}"}}"#
                                );
                            }
                            if !quiet {
                                eprintln!(
                                    "[reserve] WARN: outcome_gate_bypassed (bypass={bypass_reason})"
                                );
                            }
                        }
                    }
                }
                // ── end MISSION-045 outcome gate ────────────────────────────────────────

                // ── RESILIENT-069: farmer readiness gate (gap-reserve admission guard) ──
                // RED = farmer has positive evidence of trouble — admit no NEW
                // claims (reserve is how new work enters the pickable queue).
                // The Farmer's own recovery routes around this: it acts via
                // launchctl/rm directly, never through `chump gap reserve`.
                // Bypass: --force (same flag already used for the ambient-
                // glance overlap check above).
                if !force {
                    let fs = farmer_status::compute(&repo_path::repo_root());
                    if !fs.green {
                        eprintln!("chump gap reserve: farmer status RED — no new claims admitted.");
                        for r in &fs.reasons {
                            eprintln!("  - {r}");
                        }
                        eprintln!("Run `chump farmer status` for detail. Bypass: --force");
                        std::process::exit(1);
                    }
                }
                // ── end farmer readiness gate ────────────────────────────────────────────

                // ── INFRA-3689: route to fleet-server when opted in + stale ──────────────
                // Mac-independence of canonical gap state: when CHUMP_GAP_SERVER is set
                // AND this checkout's local `main` is verifiably behind origin/main, a
                // local `reserve` would write to a non-canonical replica. Delegate to the
                // fleet-server's `POST /api/gap` (running on owned iron with a canonical
                // checkout) instead of writing state.db here. Unset CHUMP_GAP_SERVER (the
                // default) leaves this whole block a no-op — fleet nodes stay local-first.
                if let Ok(server_base) = std::env::var(gap_route::GAP_SERVER_ENV) {
                    let server_base = server_base.trim().to_string();
                    if !server_base.is_empty() {
                        let behind = store.behind_origin_main();
                        let canonical_mode = gap_route::canonical_server_mode();
                        if gap_route::should_route_to_server(behind, true, canonical_mode) {
                            if !quiet {
                                eprintln!(
                                    "[reserve] routing to fleet-server (mode={}, local main behind={} commit(s)); CHUMP_GAP_SERVER={} — not writing local state.db",
                                    if canonical_mode { "canonical" } else { "stale-only" },
                                    behind.unwrap_or(0),
                                    server_base
                                );
                            }
                            let token =
                                std::env::var(gap_route::BATPHONE_TOKEN_ENV).unwrap_or_default();
                            let ac_list: Option<Vec<String>> = if acceptance_criteria_json != "[]" {
                                serde_json::from_str(&acceptance_criteria_json).ok()
                            } else {
                                None
                            };
                            let body = gap_route::GapMutationBody {
                                op: "reserve".into(),
                                domain: Some(domain.clone()),
                                title: Some(title.clone()),
                                priority: Some(priority.clone()),
                                effort: Some(effort.clone()),
                                outcome: reserve_outcome_id.clone(),
                                evidence: reserve_evidence.clone(),
                                acceptance_criteria: ac_list,
                                external_repo: reserve_external_repo.clone(),
                                force: Some(force),
                                skip_obs_acs: Some(skip_obs_acs),
                                ..Default::default()
                            };
                            match gap_route::route_gap_mutation(&server_base, &token, &body).await {
                                Ok(result) => {
                                    let _ =
                                        crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                                            kind: "gap_mutation_routed_to_server".to_string(),
                                            source: Some("chump_gap_reserve".to_string()),
                                            gap: Some(result.gap_id.clone()),
                                            fields: vec![
                                                ("op".to_string(), "reserve".to_string()),
                                                ("server".to_string(), server_base.clone()),
                                                (
                                                    "behind".to_string(),
                                                    behind.unwrap_or(0).to_string(),
                                                ),
                                            ],
                                            ..Default::default()
                                        });
                                    if json_out {
                                        println!(
                                            "{{\"id\":\"{}\",\"yaml_path\":\"\"}}",
                                            result.gap_id
                                        );
                                    } else {
                                        println!("{}", result.gap_id);
                                    }
                                    if why {
                                        eprintln!(
                                            "reserved {} — why: routed to fleet-server ({}) because local checkout is non-canonical (INFRA-3689): {}",
                                            result.gap_id, server_base, result.detail
                                        );
                                    }
                                    return Ok(());
                                }
                                Err(e) => {
                                    if canonical_mode {
                                        eprintln!(
                                            "[reserve] fleet-server routing failed ({e:#}); canonical mode refuses a local reserve to prevent split gap state"
                                        );
                                        std::process::exit(1);
                                    }
                                    // Stale-only mode preserves its original compatibility
                                    // behavior; reserve_verified below independently blocks
                                    // a stale/unverifiable canonical local write.
                                    eprintln!("[reserve] fleet-server routing failed ({e:#}); falling through to local reserve path");
                                }
                            }
                        }
                    }
                }
                // ── end INFRA-3689 fleet-server routing ──────────────────────────────────

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
                        if let Some((open_p0_count, ref reason)) = pending_p0_override {
                            emit_p0_budget_override(&worktree_root, &id, open_p0_count, reason);
                        }

                        // ZERO-WASTE-045 AC2: any near-match surfaced above (state.db or
                        // Almanac corpus) gets written into the new gap's notes, so a
                        // later audit can see the dupe was considered, not missed —
                        // regardless of whether --force-duplicate was used to proceed.
                        if !dedupe_considered.is_empty() {
                            let note = format!(
                                "DEDUPE-CHECK (ZERO-WASTE-045): {} considered at reserve time{}.",
                                dedupe_considered.join("; "),
                                if force_duplicate {
                                    " — proceeded via --force-duplicate"
                                } else {
                                    " — proceeded (advisory-only, no override flag used)"
                                }
                            );
                            let update = gap_store::GapFieldUpdate {
                                notes: Some(note),
                                ..Default::default()
                            };
                            if let Err(e) = store.set_fields(&id, update) {
                                if !quiet {
                                    eprintln!("warning: failed to record dedupe-check notes: {e}");
                                }
                            }
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
                        if why {
                            eprintln!(
                                "reserved {id} — why: collision-free atomic ID pick from domain {domain} pool (INFRA-216 verification window)"
                            );
                        }
                        // ZERO-WASTE-020: YAML mirrors retired — state.db is
                        // canonical (INFRA-8193: .chump/state.sql left git).
                        // `chump gap reserve` no longer writes a per-file
                        // docs/gaps/<ID>.yaml mirror (the INFRA-228/1428
                        // write-and-autostage path this replaced is gone).
                        // Use `chump gap show <ID>` for human-readable
                        // per-gap inspection.
                        // CREDIBLE-072: audit the pillar-cap decision with the real id.
                        if let Some(line) = pillar_cap_event.take() {
                            let line = line.replace("{GAP_ID}", &id);
                            let ambient_path =
                                worktree_root.join(".chump-locks").join("ambient.jsonl");
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                use std::io::Write as _;
                                let _ = writeln!(f, "{line}");
                            }
                        }
                        if json_out {
                            println!("{{\"id\":\"{id}\",\"yaml_path\":\"\"}}");
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
                    let glance_script =
                        repo_path::repo_root().join("scripts/coord/chump-ambient-glance.sh");
                    if glance_script.is_file() {
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
                }

                // INFRA-2360: pre-claim disk-plan check. A claim provisions a worktree
                // (isolated target dir); REFUSE blocks it, WAIT warns, --force overrides.
                match disk_plan_gate::check_for_claim(&repo_path::repo_root(), force) {
                    disk_plan_gate::ClaimDiskGate::Proceed => {}
                    disk_plan_gate::ClaimDiskGate::Warn(msg) => eprintln!("[claim] {msg}"),
                    disk_plan_gate::ClaimDiskGate::Refuse(msg) => {
                        eprintln!("chump gap claim: {msg}");
                        std::process::exit(1);
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

                // RESILIENT-190: cross-machine collision guard. When a NATS
                // broker is configured (CHUMP_NATS_URL), acquire a cluster-wide
                // atomic claim BEFORE the local flock so two machines never pick
                // the same gap. Degrades to local-only if NATS is unreachable
                // (connect_or_skip). Escape hatch: CHUMP_CLAIM_NO_NATS=1. --force
                // bypasses (recovery). Same-session holds stay idempotent.
                let nats_claim: Option<chump_coord::CoordClient> = if !force
                    && std::env::var("CHUMP_NATS_URL").is_ok()
                    && std::env::var("CHUMP_CLAIM_NO_NATS").is_err()
                {
                    match chump_coord::CoordClient::connect_or_skip().await {
                        Some(coord) => match coord.try_claim_gap(&gap_id, &session_id).await {
                            Ok(true) => Some(coord),
                            Ok(false) => {
                                // Already held in the cluster — us (re-entrant) or another machine?
                                match coord.gap_claim(&gap_id).await {
                                    Ok(Some(held)) if held.session_id == session_id => Some(coord),
                                    Ok(Some(held)) => {
                                        eprintln!(
                                            "chump gap claim: {gap_id} already claimed by session {} on another machine (NATS-KV) — skipping",
                                            held.session_id
                                        );
                                        std::process::exit(1);
                                    }
                                    _ => Some(coord),
                                }
                            }
                            Err(e) => {
                                eprintln!("[chump-coord] cluster claim check failed ({e:#}) — proceeding local-only");
                                None
                            }
                        },
                        None => None,
                    }
                } else {
                    None
                };

                // INFRA-8193: the INFRA-3002 self-heal (sync the missing row
                // from the tracked .chump/state.sql and retry) is gone with the
                // file. Its premise, a linked worktree holding a stale
                // snapshot store, no longer holds: worktrees resolve to their
                // main checkout's state.db (INFRA-8190). A gap missing here is
                // missing from the one store; reconcile stores with
                // `chump store reconcile` (INFRA-8222).
                let claim_result = store.claim(&gap_id, &session_id, &worktree, ttl);

                match claim_result {
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
                        // Roll back the cluster claim so a local failure doesn't
                        // wedge the gap cluster-wide until the KV TTL expires.
                        if let Some(coord) = &nats_claim {
                            let _ = coord.release_gap(&gap_id).await;
                        }
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
                        // INFRA-2472: local state.db only reflects claims this
                        // machine has seen (synced via periodic coherence-sync
                        // commits). Consult the shared NATS registry too — it
                        // sees claims other machines took that haven't landed
                        // in a sync commit yet. Fail-open: NATS unconfigured
                        // or unreachable means no signal, not "must be free".
                        let self_session = std::env::var("CHUMP_SESSION_ID").ok();
                        if let Some(holder) = atomic_claim::shared_registry_whois(&gap_id) {
                            if self_session.as_deref() != Some(holder.as_str()) {
                                eprintln!(
                                    "[preflight] FAIL {} — live-claimed by session {} in the shared NATS registry (INFRA-2472; invisible to local state.db).",
                                    gap_id, holder
                                );
                                std::process::exit(1);
                            }
                        }
                        // CREDIBLE-1613: Refuse re-claim when an open PR already exists
                        // for this gap in gap_prs OR via `gh pr list --state open --json number,headRefName`.
                        if !dispatch_repair::allow_duplicate_pr_from_env() {
                            let mut open_pr: Option<(u64, String)> =
                                store.list_prs_for_gap(&gap_id).ok().and_then(|rows| {
                                    rows.into_iter()
                                        .find(|r| {
                                            r.state.eq_ignore_ascii_case("open") && r.pr_number > 0
                                        })
                                        .map(|r| (r.pr_number as u64, r.head_sha))
                                });
                            if open_pr.is_none() {
                                open_pr = dispatch_repair::find_open_pr_by_branch_prefix(
                                    &repo_root, &gap_id,
                                );
                            }
                            if let Some((pr_number, head_ref)) = open_pr {
                                let _ = store.link_pr(&gap_id, pr_number as i64, &head_ref);
                                dispatch_repair::emit_gap_reclaimed_with_open_pr(
                                    &repo_root, &gap_id, pr_number, &head_ref,
                                );
                                eprintln!(
                                    "[preflight] FAIL {} — open PR #{} (head_ref={}) already exists for this gap (CREDIBLE-1613).",
                                    gap_id, pr_number, head_ref
                                );
                                std::process::exit(1);
                            }
                        }
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
                        // INFRA-3446: recognize self-ownership. When the live
                        // lease belongs to THIS session (CHUMP_SESSION_ID), the
                        // caller is shipping its OWN claimed work — that's
                        // pickable, not a conflict. Without this, the fleet's own
                        // ship path (execute_gap free_tier_ship → bot-merge →
                        // `chump gap preflight`) rejected every gap as
                        // "live-claimed by <the very session shipping it>",
                        // blocking chump from shipping on itself. A FOREIGN
                        // session still fails (don't stomp another worker's claim).
                        let self_session = std::env::var("CHUMP_SESSION_ID").ok();
                        if preflight_claim_is_self(self_session.as_deref(), &s) {
                            println!(
                                "[preflight] OK {} — claimed by this session (self).",
                                gap_id
                            );
                            return Ok(());
                        }
                        eprintln!(
                            "[preflight] FAIL {} — live-claimed by session {}.",
                            gap_id, s
                        );
                        std::process::exit(1);
                    }
                    Ok(gap_store::PreflightResult::NotFound) => {
                        // CREDIBLE-1486: NotFound exits non-zero so callers that
                        // gate on exit code alone (e.g. `chump dispatch`'s
                        // preflight step) never treat a MISSING gap as pickable.
                        // INFRA-8193: the old self-heal from the tracked
                        // .chump/state.sql is gone with the file; worktrees share
                        // their main checkout's store (INFRA-8190), so a gap
                        // absent here is absent from the one store.
                        eprintln!(
                            "[preflight] FAIL {} — not found in state.db (reconcile stores with `chump store reconcile`, INFRA-8222).",
                            gap_id
                        );
                        std::process::exit(1);
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
                        "Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N] [--external-repo owner/name] [--session ID]\n\n\
                         Mark a gap as done. Updates state.db (canonical), optionally mirrors to YAML.\n\n\
                         Options:\n  \
                           --update-yaml               Mirror status flip to docs/gaps/<ID>.yaml (destructive bulk-YAML; INFRA-825 staleness guard applies)\n  \
                           --closed-pr N               Stamp PR number on the row (required by INFRA-107 closed_pr integrity guard for YAML mirror)\n  \
                           --external-repo owner/name  Verify PR N merged in owner/name (required for external_repo:X gaps, CREDIBLE-1579)\n  \
                           --session ID                Session ID to record on the ship event (default derived)\n  \
                           --why                       Print explanation alongside the flip\n  \
                           -h, --help                  Show this help"
                    );
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N] [--external-repo owner/name]");
                    std::process::exit(2);
                });
                let external_repo = flag("--external-repo");
                let session_id = flag("--session")
                    .or_else(|| crate::ambient_stream::env_session_id())
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                // PHASE-R R1 (CREDIBLE-1491): re-ship of a terminal gap is a no-op
                // before any gate, fetch, YAML mirror or ambient emit runs.
                if let Ok(Some(st)) = store.already_terminal(&gap_id) {
                    println!("shipped {gap_id} (already {st}; no-op, PHASE-R R1)");
                    return Ok(());
                }
                // MISSION-045: close-side outcome gate — refuse to flip a P0/P1 gap
                // to done without an outcome_id. Backstop for the reserve gate
                // (catches gaps that pre-date it). Bypass: --no-outcome-required
                // (audited). P2/P3 unaffected — permissionless.
                if let Ok(Some(g)) = store.get(&gap_id) {
                    let is_p01 = matches!(g.priority.as_str(), "P0" | "P1");
                    let traced = g
                        .outcome_id
                        .as_deref()
                        .map(|s| !s.trim().is_empty())
                        .unwrap_or(false);
                    let bypass = args.iter().any(|a| a == "--no-outcome-required");
                    // Empty-outcomes skip (mirrors the reserve gate): a DB with no
                    // outcomes has nothing to trace to, so the gate is vacuous.
                    let has_outcomes = store
                        .list_outcomes()
                        .map(|o| !o.is_empty())
                        .unwrap_or(false);
                    if is_p01 && !traced && !bypass && has_outcomes {
                        eprintln!();
                        eprintln!(
                            "chump gap ship: P0/P1 gap {gap_id} has no outcome_id (MISSION-045 close gate)."
                        );
                        eprintln!(
                            "Link it first: chump outcome link {gap_id} --outcome <id>  (see: chump outcome list)"
                        );
                        eprintln!("Bypass: --no-outcome-required (audited).");
                        std::process::exit(1);
                    }
                    if is_p01 && !traced && bypass {
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let ambient_path = worktree_root.join(".chump-locks").join("ambient.jsonl");
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            use std::io::Write;
                            let _ = writeln!(
                                f,
                                r#"{{"ts":"{ts}","kind":"outcome_gate_bypassed","phase":"ship","gap_id":"{gap_id}"}}"#
                            );
                        }
                    }
                }
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
                        eprintln!(
                            "  Override: CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 chump gap ship ..."
                        );
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
                // ── INFRA-3689: route to fleet-server when opted in + stale ──────────────
                // Same gate as `chump gap reserve`/`set` — see reserve's comment for
                // rationale. Uses repo_root's local `main` (the canonical replica),
                // distinct from the CHUMP_GAP_SHIP_STALE_THRESHOLD gate above which
                // checks the current worktree's HEAD.
                //
                // CREDIBLE-1551 (Phase R R2, AC2) KNOWN LIMITATION — DO NOT fix here
                // (RESILIENT-1650 owns it): when this routes to the fleet-server, the
                // `ship` op is forwarded, but `chump gap link-pr` has no server-routing
                // path — it only ever writes the LOCAL state.db. So on a stale client
                // whose ships are forwarded, the gap_prs row the ship FK-gate requires
                // lives on the client while the ship executes on the server, and a
                // correctly-linked close would be refused server-side. The ship-gate
                // itself is correct; the split is a link-pr routing gap tracked by
                // RESILIENT-1650. Documented in the CREDIBLE-1551 PR body + here so the
                // next reader does not "fix" the ship-gate thinking it is the bug.
                if let Ok(server_base) = std::env::var(gap_route::GAP_SERVER_ENV) {
                    let server_base = server_base.trim().to_string();
                    if !server_base.is_empty() {
                        let behind = store.behind_origin_main();
                        let canonical_mode = gap_route::canonical_server_mode();
                        if gap_route::should_route_to_server(behind, true, canonical_mode) {
                            eprintln!(
                                "[gap ship] routing to fleet-server (mode={}, local main behind={} commit(s)); CHUMP_GAP_SERVER={} — not writing local state.db",
                                if canonical_mode { "canonical" } else { "stale-only" },
                                behind.unwrap_or(0),
                                server_base
                            );
                            let token =
                                std::env::var(gap_route::BATPHONE_TOKEN_ENV).unwrap_or_default();
                            let body = gap_route::GapMutationBody {
                                op: "ship".into(),
                                gap_id: Some(gap_id.clone()),
                                closed_pr,
                                session: Some(session_id.clone()),
                                ..Default::default()
                            };
                            match gap_route::route_gap_mutation(&server_base, &token, &body).await {
                                Ok(result) => {
                                    let _ =
                                        crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                                            kind: "gap_mutation_routed_to_server".to_string(),
                                            source: Some("chump_gap_ship".to_string()),
                                            gap: Some(result.gap_id.clone()),
                                            fields: vec![
                                                ("op".to_string(), "ship".to_string()),
                                                ("server".to_string(), server_base.clone()),
                                                (
                                                    "behind".to_string(),
                                                    behind.unwrap_or(0).to_string(),
                                                ),
                                            ],
                                            ..Default::default()
                                        });
                                    let _ = crate::doctor::gap_cmd::emit_gap_shipped(
                                        &repo_root,
                                        &result.gap_id,
                                        &session_id,
                                        closed_pr,
                                    );
                                    println!("shipped {}", result.gap_id);
                                    return Ok(());
                                }
                                Err(e) => {
                                    if canonical_mode {
                                        eprintln!(
                                            "[gap ship] fleet-server routing failed ({e:#}); canonical mode refuses a local ship to prevent split gap state"
                                        );
                                        std::process::exit(1);
                                    }
                                    eprintln!("[gap ship] fleet-server routing failed ({e:#}); falling through to local ship path");
                                }
                            }
                        }
                    }
                }
                // ── end INFRA-3689 fleet-server routing ──────────────────────────────────
                // CREDIBLE-1489: closed_pr must be the PR that actually merged this
                // gap's work. With no --closed-pr, resolve it from the PR cache by
                // the current branch; with an explicit one, warn when the cached PR
                // never references the gap (the bogus-closure class: closed_pr
                // pointing at an unrelated PR). Advisory — never blocks the ship.
                let closed_pr = match closed_pr {
                    Some(n) => {
                        if external_repo.is_none()
                            && chump_gap_store::pr_references_gap(&repo_root, &gap_id, n)
                                == Some(false)
                        {
                            eprintln!(
                                "[gap ship] WARNING: PR #{n} does not reference {gap_id} in its title/branch — closed_pr may point at an unrelated PR (run scripts/ops/closed-pr-integrity-check.py)"
                            );
                        }
                        Some(n)
                    }
                    None if external_repo.is_some() => None,
                    None => {
                        let branch = std::process::Command::new("git")
                            .args(["rev-parse", "--abbrev-ref", "HEAD"])
                            .current_dir(&worktree_root)
                            .output()
                            .ok()
                            .filter(|o| o.status.success())
                            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
                        let found = branch
                            .filter(|b| !b.is_empty() && b != "HEAD" && b != "main")
                            .and_then(|b| chump_gap_store::merged_pr_for_branch(&repo_root, &b));
                        if let Some(n) = found {
                            // CREDIBLE-1551 (Phase R R2, AC2): a closed_pr the CLI
                            // auto-resolves is held to the SAME gap_prs FK gate as an
                            // explicit --closed-pr — `store.ship` refuses unless a
                            // gap_prs row links #{n} to this gap. Say so here so the
                            // refusal that follows is not mysterious ("I never passed
                            // --closed-pr"): the merge was auto-detected, and it still
                            // needs the typed link.
                            eprintln!("[gap ship] closed_pr auto-resolved from the PR that merged this branch: #{n} (CREDIBLE-1551: this close requires a gap_prs link #{n} -> {gap_id}; if refused, run `chump gap link-pr {gap_id} {n} --sha <merge-sha>` then retry)");
                        }
                        found
                    }
                };
                match crate::doctor::gap_cmd::ship_gap(
                    &store,
                    &repo_root,
                    &gap_id,
                    &session_id,
                    closed_pr,
                    external_repo.as_deref(),
                ) {
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
                        // ZERO-WASTE-059: dedup-check + AC-hygiene scan runs in the
                        // SAME op as the ship, so a stale/duplicate sibling or a
                        // vague-AC gap in this domain surfaces immediately instead
                        // of needing a later standalone reconcile-stale-gap PR.
                        // Advisory only — never blocks or fails the ship.
                        if let Ok(Some(shipped_gap)) = store.get(&gap_id) {
                            let similarity_threshold: f64 =
                                std::env::var("CHUMP_GAP_SHIP_HYGIENE_SIMILARITY")
                                    .ok()
                                    .and_then(|s| s.trim().parse().ok())
                                    .unwrap_or(0.65);
                            if let Ok(report) = store.queue_hygiene_check_on_ship(
                                &gap_id,
                                &shipped_gap.title,
                                &shipped_gap.domain,
                                similarity_threshold,
                            ) {
                                if !report.is_clean() {
                                    let ts =
                                        chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                                    let event = serde_json::json!({
                                        "ts": ts,
                                        "kind": "ship_queue_hygiene_flagged",
                                        "gap": gap_id,
                                        "dup_candidates": report.dup_candidates.iter()
                                            .map(|(id, title, _, score)| serde_json::json!({"id": id, "title": title, "score": score}))
                                            .collect::<Vec<_>>(),
                                        "vague_ac_gaps": report.vague_ac_gaps.iter()
                                            .map(|(id, title)| serde_json::json!({"id": id, "title": title}))
                                            .collect::<Vec<_>>(),
                                    });
                                    let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");
                                    let _ = std::fs::OpenOptions::new()
                                        .append(true)
                                        .create(true)
                                        .open(&ambient_log)
                                        .and_then(|mut f| {
                                            use std::io::Write;
                                            writeln!(f, "{event}")
                                        });
                                    for (id, title, _, score) in &report.dup_candidates {
                                        eprintln!(
                                            "  [hygiene] possible duplicate still open: {id} ({title}, score={score:.2})"
                                        );
                                    }
                                    for (id, title) in &report.vague_ac_gaps {
                                        eprintln!(
                                            "  [hygiene] vague-AC gap in domain {}: {id} ({title})",
                                            shipped_gap.domain
                                        );
                                    }
                                }
                            }
                        }
                        // INFRA-1144: atomically close orphan PRs for this gap
                        // (complements INFRA-1139 sweeper). Emits orphan_pr_closed_at_ship
                        // events for each closure.
                        if let Ok(closed_prs) =
                            store.close_orphan_prs(&gap_id, closed_pr, &repo_root)
                        {
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
                        // ZERO-WASTE-056 + INFRA-247: write <worktree_root>/docs/gaps/<ID>.yaml
                        // ATOMICALLY by default so the YAML closure lands in the WORK PR
                        // (not canonical `main` when in a linked worktree); pass
                        // `--no-update-yaml` for post-merge host sweeps on `main`.
                        let _ = update_yaml;
                        let no_update_yaml = args.iter().any(|a| a == "--no-update-yaml");
                        match store.sync_yaml_for_ship(
                            &gap_id,
                            &worktree_root,
                            no_update_yaml,
                            external_repo.as_deref(),
                        ) {
                            Ok(true) => {
                                println!("  synced docs/gaps/{}.yaml (status=done)", gap_id)
                            }
                            Ok(false) => {}
                            Err(e) => eprintln!(
                                "chump gap ship: warning — could not sync docs/gaps/{}.yaml: {e:#}",
                                gap_id
                            ),
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap ship: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // INFRA-8192 (Phase R R2, first slice): write the gap-to-PR link
            // as a typed row at PR-open time, instead of only being
            // recoverable later by parsing the PR title. bot-merge.sh calls
            // this right after `gh pr create` succeeds.
            "link-pr" => {
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap link-pr <GAP-ID> <PR-NUMBER> --sha <SHA> [--multi] [--move]\n\n\
                         Record a typed gap-to-PR link in state.db (gap_prs table).\n\
                         Idempotent: re-running with the same GAP-ID/PR-NUMBER updates head_sha.\n\
                         CREDIBLE-1559: refuses to add a second gap to a PR unless --multi is passed,\n\
                         or --move is passed to re-scope the PR (unlinking the previous gap)."
                    );
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!(
                        "Usage: chump gap link-pr <GAP-ID> <PR-NUMBER> --sha <SHA> [--multi] [--move]"
                    );
                    std::process::exit(2);
                });
                let pr_number: i64 = args
                    .get(4)
                    .and_then(|s| s.parse::<i64>().ok())
                    .filter(|n| *n > 0)
                    .unwrap_or_else(|| {
                        eprintln!(
                            "chump gap link-pr: PR-NUMBER must be a positive integer (got {:?})",
                            args.get(4)
                        );
                        std::process::exit(2);
                    });
                let head_sha = flag("--sha").unwrap_or_else(|| {
                    eprintln!(
                        "Usage: chump gap link-pr <GAP-ID> <PR-NUMBER> --sha <SHA> [--multi] [--move]"
                    );
                    std::process::exit(2);
                });
                let multi = args.iter().skip(3).any(|a| a == "--multi");
                let move_link = args.iter().skip(3).any(|a| a == "--move");
                match store.link_pr_opts(&gap_id, pr_number, &head_sha, multi, move_link) {
                    Ok(()) => {
                        println!("linked {gap_id} -> PR #{pr_number} ({head_sha})");
                    }
                    Err(e) => {
                        eprintln!("chump gap link-pr: {e:#}");
                        std::process::exit(1);
                    }
                }
                // CREDIBLE-1551: return so the handled subcommand does not fall
                // through to main's "unknown subcommand 'gap'" catch-all (which
                // would exit 2). Pre-existing latent bug — link-pr was only ever
                // called best-effort (`>/dev/null 2>&1`) by bot-merge, so the
                // spurious exit 2 was never observed; the manual link-pr paths
                // added for AC2 call it under `set -e`, so the return matters.
                return Ok(());
            }
            // CREDIBLE-1552 (Phase R R2): remove ONE gap_prs row through the
            // store (single-writer). Undoes a mislinked gap→PR edge — e.g. a
            // slice PR linked to the umbrella instead of its own slice gap.
            // Emits kind=gap_pr_unlinked carrying the reason.
            "unlink-pr" => {
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap unlink-pr <GAP-ID> <PR-NUMBER> --reason <text>\n\n\
                         Remove one typed gap-to-PR link from state.db (gap_prs table).\n\
                         Idempotent: removing a link that does not exist is a no-op (exit 0)."
                    );
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap unlink-pr <GAP-ID> <PR-NUMBER> --reason <text>");
                    std::process::exit(2);
                });
                let pr_number: i64 = args
                    .get(4)
                    .and_then(|s| s.parse::<i64>().ok())
                    .filter(|n| *n > 0)
                    .unwrap_or_else(|| {
                        eprintln!(
                            "chump gap unlink-pr: PR-NUMBER must be a positive integer (got {:?})",
                            args.get(4)
                        );
                        std::process::exit(2);
                    });
                let reason = flag("--reason").unwrap_or_else(|| {
                    eprintln!("chump gap unlink-pr: --reason <text> is required");
                    std::process::exit(2);
                });
                match store.unlink_pr(&gap_id, pr_number, &reason) {
                    Ok(0) => {
                        println!("no gap_prs link {gap_id} -> PR #{pr_number} to remove (no-op)");
                    }
                    Ok(_) => {
                        println!("unlinked {gap_id} -> PR #{pr_number} (reason: {reason})");
                    }
                    Err(e) => {
                        eprintln!("chump gap unlink-pr: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            // CREDIBLE-1551 (Phase R R2, AC2): reverse of link-pr — print the
            // gap IDs that a typed gap_prs row links to a PR number, newest
            // first, one per line. This is the FK-backed replacement for parsing
            // gap IDs out of a merged PR's title/body: the two legacy title-regex
            // closers (stale-pr-reaper's INFRA-674 ghost block and
            // chump-pr-triage's `--apply ship-gap`) now resolve the gap to close
            // from here instead of a title regex, so the no-title-closer
            // allowlist empties to true zero.
            "gaps-for-pr" => {
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap gaps-for-pr <PR-NUMBER>\n\n\
                         Print the gap IDs linked to PR-NUMBER in the gap_prs table\n\
                         (newest first, one per line). The typed FK replacement for\n\
                         parsing gap IDs out of a PR title/body when closing a gap."
                    );
                    return Ok(());
                }
                let pr_number: i64 = args
                    .get(3)
                    .and_then(|s| s.parse::<i64>().ok())
                    .filter(|n| *n > 0)
                    .unwrap_or_else(|| {
                        eprintln!(
                            "chump gap gaps-for-pr: PR-NUMBER must be a positive integer (got {:?})",
                            args.get(3)
                        );
                        std::process::exit(2);
                    });
                match store.gaps_for_pr(pr_number) {
                    Ok(gaps) => {
                        if json_out {
                            println!("{}", serde_json::to_string(&gaps)?);
                        } else {
                            for g in gaps {
                                println!("{g}");
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("chump gap gaps-for-pr: {e:#}");
                        std::process::exit(1);
                    }
                }
                // CREDIBLE-1551: return so this subcommand does not fall through
                // to main's "unknown subcommand 'gap'" catch-all (exit 2) — same
                // latent bug fixed for link-pr just above.
                return Ok(());
            }
            "reconcile-merged" => {
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap reconcile-merged [--dry-run] [--json]\n\n\
                         Close open gaps whose typed `gap_prs` link points to a PR marked\n\
                         MERGED in `.chump/github_cache.db`, routing every transition through\n\
                         the receipt-gated `GapStore::ship` path (CREDIBLE-1550)."
                    );
                    return Ok(());
                }
                for extra in args.iter().skip(3) {
                    if !matches!(extra.as_str(), "--dry-run" | "--json") {
                        eprintln!(
                            "chump gap reconcile-merged: unknown argument {extra:?} (expected --dry-run or --json)"
                        );
                        std::process::exit(2);
                    }
                }
                let dry_run = args.iter().skip(3).any(|a| a == "--dry-run");
                match store.reconcile_merged_pr_links(&repo_root, dry_run) {
                    Ok(closed) => {
                        if !dry_run {
                            for (gid, pr_num) in &closed {
                                let _ = crate::doctor::gap_cmd::emit_gap_shipped(
                                    &repo_root,
                                    gid,
                                    "reconcile-merged",
                                    Some(*pr_num),
                                );
                            }
                        }
                        if json_out {
                            let payload: Vec<_> = closed
                                .iter()
                                .map(|(gid, pr)| {
                                    serde_json::json!({
                                        "gap_id": gid,
                                        "pr_number": pr,
                                        "dry_run": dry_run,
                                    })
                                })
                                .collect();
                            println!("{}", serde_json::to_string(&payload)?);
                        } else if closed.is_empty() {
                            println!("reconcile-merged: 0 merged gap_prs links pending closure");
                        } else {
                            for (gid, pr) in &closed {
                                if dry_run {
                                    println!("[dry-run] would ship {gid} (merged PR #{pr})");
                                } else {
                                    println!("shipped {gid} (merged PR #{pr})");
                                }
                            }
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap reconcile-merged: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // EFFECTIVE-038: A2A L2 task-suspension. `suspend` moves a gap
            // into status=waiting_operator carrying a structured question
            // payload — used when an agent hits auth_required (missing
            // credential, RESILIENT-054's silent-death mode) or an
            // ambiguous input_required decision instead of guessing wrong
            // or filing a disconnected follow-up gap.
            "suspend" => {
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap suspend <GAP-ID> --kind input_required|auth_required --question TEXT [--context JSON]\n\n\
                         Suspends the gap into status=waiting_operator, carrying a structured\n\
                         question payload. `chump gap respond <ID> --answer JSON` resumes it\n\
                         from exactly the status it was in before suspending."
                    );
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap suspend <GAP-ID> --kind K --question TEXT");
                    std::process::exit(2);
                });
                let kind = flag("--kind").unwrap_or_else(|| {
                    eprintln!("chump gap suspend: --kind input_required|auth_required is required");
                    std::process::exit(2);
                });
                let question = flag("--question").unwrap_or_else(|| {
                    eprintln!("chump gap suspend: --question TEXT is required");
                    std::process::exit(2);
                });
                let context = flag("--context");
                match store.suspend_waiting(&gap_id, &kind, &question, context.as_deref()) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"id":"{gap_id}","status":"waiting_operator","kind":"{kind}"}}"#
                            );
                        } else {
                            println!(
                                "{gap_id} suspended → waiting_operator (kind={kind}). Respond with: chump gap respond {gap_id} --answer '<json>'"
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("chump gap suspend: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // EFFECTIVE-038: resumes a waiting_operator gap with the
            // operator's answer, restoring the status it paused from.
            "respond" => {
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap respond <GAP-ID> --answer JSON\n\n\
                         Resumes a gap suspended via `chump gap suspend`. Restores the status\n\
                         the gap held immediately before suspension and appends the Q/A pair\n\
                         to notes as an audit trail."
                    );
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap respond <GAP-ID> --answer JSON");
                    std::process::exit(2);
                });
                let answer = flag("--answer").unwrap_or_else(|| {
                    eprintln!("chump gap respond: --answer JSON is required");
                    std::process::exit(2);
                });
                match store.respond_gap(&gap_id, &answer) {
                    Ok(resumed_status) => {
                        if json_out {
                            println!(r#"{{"id":"{gap_id}","resumed_status":"{resumed_status}"}}"#);
                        } else {
                            println!("{gap_id} resumed → status={resumed_status}");
                        }
                    }
                    Err(e) => {
                        eprintln!("chump gap respond: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "close" => {
                // RESILIENT-119: first-class triage-close. Unlike `chump gap
                // ship`, this path never expects a PR — it flips status
                // directly and does NOT run the clean/current-worktree
                // (INFRA-2423) or proof-of-merge (INFRA-1392) guards, since
                // those exist to protect real PR-ships, not this path.
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap close <GAP-ID> --reason <superseded|wontfix|obsolete|duplicate> [--session ID]\n\n\
                         Triage-close a gap that will never ship a PR. Updates state.db (canonical).\n\
                         Does NOT require a clean/current worktree or a merge commit naming the gap —\n\
                         those guards are for `chump gap ship`, not triage-closes.\n\n\
                         Options:\n  \
                           --reason R    Required. One of: superseded, wontfix, obsolete, duplicate\n  \
                           --session ID  Session ID to record on the close event (default derived)\n  \
                           -h, --help    Show this help"
                    );
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap close <GAP-ID> --reason <superseded|wontfix|obsolete|duplicate>");
                    std::process::exit(2);
                });
                let reason = flag("--reason").unwrap_or_else(|| {
                    eprintln!(
                        "chump gap close: --reason is required (superseded|wontfix|obsolete|duplicate)"
                    );
                    std::process::exit(2);
                });
                let session_id = flag("--session")
                    .or_else(|| crate::ambient_stream::env_session_id())
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                match store.close(&gap_id, &session_id, &reason) {
                    Ok(()) => {
                        println!("closed {} (reason={})", gap_id, reason);
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap close: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "set" | "update" | "modify" | "edit" | "change" => {
                // INFRA-1036: 'set' and natural-language aliases for gap mutation.
                // CREDIBLE-016: unknown-flag detection — if the positional GAP-ID slot
                // starts with "--", the operator forgot the ID or passed a bad flag.
                let gap_set_usage = || {
                    eprintln!("Usage: chump gap set <GAP-ID> [--title T] [--description D] [--priority P]");
                    eprintln!("                          [--effort E] [--status S] [--notes N] [--add-note TEXT]");
                    eprintln!("                          [--source-doc S] [--opened-date D] [--closed-date D]");
                    eprintln!("                          [--closed-pr N] [--acceptance-criteria BULLET ...] [--depends-on \"X,Y\"]");
                    eprintln!("                          [--skills-required SKS] [--preferred-backend BE]");
                    eprintln!("                          [--preferred-machine MACH] [--estimated-minutes MIN] [--required-model MODEL]");
                    eprintln!("                          [--outcome OUTCOME-ID]  (MISSION-008: advisory FK, never gates close)");
                    eprintln!("  Note: --add-note TEXT appends '[ISO-timestamp] TEXT' to existing notes; --notes OVERWRITES.");
                    eprintln!("  INFRA-1799: --acceptance-criteria accepts repeated flags — one AC bullet per occurrence.");
                    eprintln!("              Example (preferred, no escape needed for pipes):");
                    eprintln!("                chump gap set X --acceptance-criteria 'recipient <gap-id|session-id|all-opus> resolves'\\");
                    eprintln!(
                        "                              --acceptance-criteria 'second bullet'"
                    );
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
                    ("artifact_type", "--artifact-type"),
                    ("artifact-type", "--artifact-type"),
                ];
                // Normalise: rewrite bare positional field name at args[4] to its
                // canonical `--flag` form in a local mutable shadow. We only apply
                // this when no `--<flag>` args are already present (to avoid
                // ambiguity in mixed usage). An unrecognised bare positional at
                // args[4] with a trailing value at args[5] is an error (typo guard).
                let mut args_local: Vec<String> = args.clone();
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
                let ac_flag_values: Vec<String> =
                    collect_acceptance_criteria_flag_values(&args_local, 4);
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

                // ── INFRA-3689: route to fleet-server when opted in + stale ──────────────
                // Same gate as `chump gap reserve` — see its comment for rationale.
                if let Ok(server_base) = std::env::var(gap_route::GAP_SERVER_ENV) {
                    let server_base = server_base.trim().to_string();
                    if !server_base.is_empty() {
                        let behind = store.behind_origin_main();
                        let canonical_mode = gap_route::canonical_server_mode();
                        if gap_route::should_route_to_server(behind, true, canonical_mode) {
                            eprintln!(
                                "[gap set] routing to fleet-server (mode={}, local main behind={} commit(s)); CHUMP_GAP_SERVER={} — not writing local state.db",
                                if canonical_mode { "canonical" } else { "stale-only" },
                                behind.unwrap_or(0),
                                server_base
                            );
                            let token =
                                std::env::var(gap_route::BATPHONE_TOKEN_ENV).unwrap_or_default();
                            let ac_list: Vec<String> = acceptance_criteria
                                .as_deref()
                                .and_then(|s| serde_json::from_str::<Vec<String>>(s).ok())
                                .unwrap_or_default();
                            let body = gap_route::GapMutationBody {
                                op: "set".into(),
                                gap_id: Some(gap_id.clone()),
                                title: flag_local("--title"),
                                description: flag_local("--description"),
                                priority: flag_local("--priority"),
                                effort: flag_local("--effort"),
                                status: flag_local("--status"),
                                outcome: flag_local("--outcome"),
                                acceptance_criteria: if ac_list.is_empty() {
                                    None
                                } else {
                                    Some(ac_list)
                                },
                                depends_on: flag_local("--depends-on"),
                                // Send the operator's raw intent. `notes` above is
                                // the local-path value (and may contain a stale
                                // client's copy); the server must calculate
                                // `--add-note` against its own canonical row.
                                notes: flag_local("--notes"),
                                add_note: flag_local("--add-note"),
                                source_doc: flag_local("--source-doc"),
                                opened_date: flag_local("--opened-date"),
                                closed_date: flag_local("--closed-date"),
                                closed_pr,
                                skills_required: flag_local("--skills-required"),
                                preferred_backend: flag_local("--preferred-backend"),
                                preferred_machine: flag_local("--preferred-machine"),
                                estimated_minutes: flag_local("--estimated-minutes"),
                                required_model: flag_local("--required-model"),
                                evidence: flag_local("--evidence"),
                                artifact_type: flag_local("--artifact-type"),
                                ..Default::default()
                            };
                            match gap_route::route_gap_mutation(&server_base, &token, &body).await {
                                Ok(result) => {
                                    let _ =
                                        crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                                            kind: "gap_mutation_routed_to_server".to_string(),
                                            source: Some("chump_gap_set".to_string()),
                                            gap: Some(result.gap_id.clone()),
                                            fields: vec![
                                                ("op".to_string(), "set".to_string()),
                                                ("server".to_string(), server_base.clone()),
                                                (
                                                    "behind".to_string(),
                                                    behind.unwrap_or(0).to_string(),
                                                ),
                                            ],
                                            ..Default::default()
                                        });
                                    println!("updated {}", result.gap_id);
                                    return Ok(());
                                }
                                Err(e) => {
                                    if canonical_mode {
                                        eprintln!(
                                            "[gap set] fleet-server routing failed ({e:#}); canonical mode refuses a local set to prevent split gap state"
                                        );
                                        std::process::exit(1);
                                    }
                                    eprintln!("[gap set] fleet-server routing failed ({e:#}); falling through to local set path");
                                }
                            }
                        }
                    }
                }
                // ── end INFRA-3689 fleet-server routing ──────────────────────────────────

                // CREDIBLE-1558 AC3: Refuse to replace existing non-vague acceptance_criteria
                // with a shorter list unless `--replace-ac` is explicitly passed.
                let replace_ac = args_local.iter().any(|a| a == "--replace-ac");
                if let Some(ref new_ac_json) = acceptance_criteria {
                    if let Ok(Some(existing_gap)) = store.get(&gap_id) {
                        let old_list =
                            gap_store::parse_json_ac_list(&existing_gap.acceptance_criteria);
                        let new_list = gap_store::parse_json_ac_list(new_ac_json);
                        let old_count = old_list.len();
                        let new_count = new_list.len();
                        let old_is_vague = old_list.is_empty()
                            || old_list.iter().all(|item| is_vague_ac_entry(item));
                        if !old_is_vague && new_count < old_count && !replace_ac {
                            eprintln!(
                                "chump gap set: refusing to overwrite acceptance_criteria on {gap_id} with a shorter list (old count: {old_count}, new count: {new_count}) (CREDIBLE-1558). Pass --replace-ac to confirm intentional replacement or pass all bullets."
                            );
                            std::process::exit(1);
                        }
                    }
                }

                // CREDIBLE-1543 AC1/AC2: Enforce open P0 budget (5) on `chump gap set --priority P0`.
                if flag_local("--priority").as_deref() == Some("P0") {
                    let already_p0 = store
                        .get(&gap_id)
                        .ok()
                        .flatten()
                        .map(|g| g.priority == "P0")
                        .unwrap_or(false);
                    if !already_p0 {
                        let all_gaps = store.list(None).unwrap_or_default();
                        let open_p0_count = count_open_manual_p0s(&all_gaps, Some(&gap_id));
                        if open_p0_count >= OPEN_P0_BUDGET {
                            match flag_local("--p0-override").as_deref().map(str::trim) {
                                Some(reason) if !reason.is_empty() => {
                                    emit_p0_budget_override(
                                        &worktree_root,
                                        &gap_id,
                                        open_p0_count,
                                        reason,
                                    );
                                }
                                _ => {
                                    eprintln!(
                                        "chump gap set: open P0 budget ({OPEN_P0_BUDGET}) exceeded — currently {open_p0_count} open P0 gaps; refusing to promote {gap_id} to P0 (CREDIBLE-1543)."
                                    );
                                    eprintln!(
                                        "Demote or close an existing P0 first, or pass --p0-override <reason> (audited to ambient.jsonl)."
                                    );
                                    std::process::exit(1);
                                }
                            }
                        }
                    }
                }

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
                    // EFFECTIVE-363: artifact_type (code | doc | release-note | copy | ...).
                    artifact_type: flag_local("--artifact-type"),
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        println!("updated {}", gap_id);
                        // ZERO-WASTE-020: YAML mirrors retired — state.db is
                        // canonical (INFRA-8193: .chump/state.sql left git).
                        // `chump gap set` no longer regenerates a per-file
                        // docs/gaps/<ID>.yaml mirror (the INFRA-470 auto-regen
                        // this replaced is gone). Use `chump gap show <ID>`
                        // for human-readable per-gap inspection.
                        let _ = version::warn_if_stale_for_gap_mutation(&repo_root);
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap set: {e:#}");
                        std::process::exit(1);
                    }
                }
            }

            _ => {
                return Box::pin(gap_audit_modes::dispatch_gap_audit(
                    args,
                    repo_root,
                    worktree_root,
                    json_out,
                    store,
                ))
                .await;
            }
        }
        return Ok(());
    }

    Box::pin(runtime_modes::dispatch_runtime_tail(args)).await
}
