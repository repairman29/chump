//! `chump gap` dump/import/restore, AC & priority audits, triage, and LLM decomposition.

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

pub(crate) async fn dispatch_gap_audit(
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
            // RESILIENT-1651 AC2: when `--yaml <path>` is explicitly supplied,
            // resolve and import EXACTLY that file or directory — never ignore
            // `<path>` and silently import `repo_root/docs/gaps` instead, and
            // refuse a missing path with a non-zero exit.
            let explicit_yaml = flag("--yaml");
            let target_path = if let Some(ref yaml_arg) = explicit_yaml {
                let p = std::path::PathBuf::from(yaml_arg);
                if p.exists() || p.is_absolute() {
                    p
                } else {
                    let cand = repo_root.join(&p);
                    if cand.exists() {
                        cand
                    } else {
                        p
                    }
                }
            } else {
                repo_root.clone()
            };
            if explicit_yaml.is_some() && !target_path.exists() {
                eprintln!(
                    "chump gap import: --yaml path '{}' does not exist",
                    target_path.display()
                );
                std::process::exit(1);
            }

            // INFRA-1434: title-similarity guard at import time.
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
            match store.import_from_yaml_path_with_similarity(
                &target_path,
                &repo_root,
                block_threshold,
            ) {
                Ok((ins, skip, backfilled, blocked, failed)) => {
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
                    let failed_msg = if failed > 0 {
                        format!(", {failed} failed")
                    } else {
                        String::new()
                    };
                    eprintln!(
                        "import complete: {ins} inserted, {skip} skipped (already present)\
                             {failed_msg}{backfill_msg}{blocked_msg}."
                    );
                    // Non-zero exit when any row was blocked or failed so callers
                    // never see success after a partial or malformed import.
                    if blocked > 0 || failed > 0 {
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
        // INFRA-538 / RESILIENT-1651: rebuild state.db from a LOCAL
        // .chump/state.sql dump (YAML gap dump or SQLite .dump).
        "restore" => {
            let from_sql = args.iter().any(|a| a == "--from-sql");
            if !from_sql {
                eprintln!("Usage: chump gap restore --from-sql");
                eprintln!(
                        "       Rebuilds .chump/state.db from a local .chump/state.sql dump (untracked since INFRA-8193)."
                    );
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
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap restore: restore failed: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        // INFRA-3495 (COTG-3.2): anti-over-claim watchdog. The gardener/
        // audit-priorities audit OPEN gaps; this audits DONE gaps for
        // hollowness — re-runs pr_ac_coverage against each closed gap's PR
        // and flags any whose acceptance bullets shipped uncovered+unwaived
        // (umbrella-done != actually-done). Emits over_claim_suspected and
        // exits non-zero if any over-claim is found. Bounded to 100 done
        // gaps (each check fetches its PR via gh).
        "audit-done" => match crate::done_auditor::audit(&repo_root, 100) {
            Ok(report) => {
                print!("{}", report.render());
                if report.failing() {
                    std::process::exit(1);
                }
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump gap audit-done: {e:#}");
                std::process::exit(1);
            }
        },
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
                    let age_days = gap_age_days(&g.opened_date, g.created_at, now_secs);
                    if age_days > 7 {
                        Some((*g, age_days))
                    } else {
                        None
                    }
                })
                .collect();

            // INFRA-1611: open P0/P1 gaps with no (or placeholder) opened_date
            // are invisible to the aging census above — flag them so the
            // fleet can see coverage gaps instead of silently treating them
            // as "0d old".
            let is_placeholder_opened_date = |d: &str| {
                let d = d.trim();
                d.is_empty() || d == "0000-00-00" || d == "1970-01-01" || d == "TODO"
            };
            let missing_opened_date_p0p1: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| {
                    g.status == "open"
                        && (g.priority == "P0" || g.priority == "P1")
                        && is_placeholder_opened_date(&g.opened_date)
                })
                .collect();

            // INFRA-2984: was `.trim().is_empty()` only, so a non-empty
            // but non-verifiable AC (e.g. `["verify it works"]`, as
            // INFRA-2984 itself shipped with) passed this gate silently.
            // Route through the same is_acceptance_criteria_vague() used
            // by `gap list`/`gap preflight` so all three surfaces agree.
            let vague_pickable: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| {
                    g.status == "open" && is_acceptance_criteria_vague(&g.acceptance_criteria)
                })
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

            // RESEARCH-001 / CREDIBLE-095: scan docs/process/RESEARCH_INTEGRITY.md for gap ID
            // references that have no corresponding docs/gaps/<ID>.yaml, honoring
            // `phantom_ref_allowlist: [...]` in YAML frontmatter for historical/synthetic IDs.
            let phantom_doc_refs: Vec<(String, String)> = {
                let repo_root = repo_path::repo_root();
                let ri_path = repo_root.join("docs/process/RESEARCH_INTEGRITY.md");
                if let Ok(content) = std::fs::read_to_string(&ri_path) {
                    // CREDIBLE-095: parse phantom_ref_allowlist from YAML frontmatter.
                    let mut allowlist_prefixes: Vec<String> = Vec::new();
                    let mut allowlist_exact: std::collections::HashSet<String> =
                        std::collections::HashSet::new();
                    if let Some(rest) = content.strip_prefix("---\n") {
                        if let Some(end_idx) = rest.find("\n---") {
                            let fm = &rest[..end_idx];
                            for line in fm.lines() {
                                let trimmed = line.trim();
                                if let Some(val) = trimmed.strip_prefix("phantom_ref_allowlist:") {
                                    let inner =
                                        val.trim().trim_start_matches('[').trim_end_matches(']');
                                    for item in inner.split(',') {
                                        let pat = item.trim().trim_matches('"').trim_matches('\'');
                                        if pat.is_empty() {
                                            continue;
                                        }
                                        if let Some(prefix) = pat.strip_suffix('*') {
                                            allowlist_prefixes.push(prefix.to_string());
                                        } else {
                                            allowlist_exact.insert(pat.to_string());
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Strip YAML frontmatter before scanning body for gap IDs.
                    let body = if let Some(rest) = content.strip_prefix("---\n") {
                        if let Some(end_idx) = rest.find("\n---") {
                            &rest[end_idx + 4..]
                        } else {
                            content.as_str()
                        }
                    } else {
                        content.as_str()
                    };
                    // Strip fenced code blocks before scanning.
                    let re_fence = regex::Regex::new(r"(?s)```.*?```").unwrap();
                    let stripped = re_fence.replace_all(body, "");
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
                        if allowlist_exact.contains(&id)
                            || allowlist_prefixes.iter().any(|p| id.starts_with(p))
                        {
                            continue;
                        }
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

            // CREDIBLE-225: placeholder-title pollution — gaps filed with a
            // throwaway/scratch title (e.g. "tmp", "test", "wip") carry no
            // real intent, so their AC ends up genericized around the
            // literal title text (see CREDIBLE-225 itself: title "tmp",
            // AC reading "The change described by \"tmp\" is implemented
            // ..."). is_acceptance_criteria_vague() doesn't catch these
            // since the AC field is non-empty — this is a title-level check.
            let placeholder_titles = [
                "tmp",
                "temp",
                "test",
                "testing",
                "wip",
                "asdf",
                "xxx",
                "foo",
                "todo",
                "placeholder",
                "scratch",
                "untitled",
            ];
            let placeholder_pollution: Vec<&gap_store::GapRow> = all_gaps
                .iter()
                .filter(|g| {
                    g.status == "open"
                        && placeholder_titles.contains(&g.title.trim().to_lowercase().as_str())
                })
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

            // INFRA-902: CREDIBLE pillar-balance analysis — shells out to
            // scripts/ops/pillar-balance-check.sh (see AC 5) and folds its
            // JSON result into this report. Runs the *fixture* binary
            // (this same `chump` process) via CHUMP_BIN so the script
            // never silently falls back to a stale PATH `chump`.
            let pillar_balance: serde_json::Value = {
                let script_path =
                    repo_path::repo_root().join("scripts/ops/pillar-balance-check.sh");
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&script_path).arg("--json");
                if let Ok(self_bin) = std::env::current_exe() {
                    cmd.env("CHUMP_BIN", self_bin);
                }
                match cmd.output() {
                    Ok(out) => {
                        let stdout = String::from_utf8_lossy(&out.stdout);
                        serde_json::from_str(stdout.trim()).unwrap_or_else(|_| {
                                serde_json::json!({"error": "pillar-balance-check.sh produced no parseable output"})
                            })
                    }
                    Err(e) => {
                        serde_json::json!({"error": format!("failed to run pillar-balance-check.sh: {e}")})
                    }
                }
            };

            if json_out {
                let mut report = serde_json::json!({
                    "p0_count": p0_count,
                    "pillar_balance": pillar_balance,
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
                    "placeholder_title_pollution": placeholder_pollution.len(),
                    "p0_gaps": p0_open.iter().map(|g| {
                        let age_days = gap_age_days(&g.opened_date, g.created_at, now_secs);
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
                    // INFRA-1611: opened_date coverage on open P0/P1 gaps
                    "missing_opened_date_p0p1_count": missing_opened_date_p0p1.len(),
                    "missing_opened_date_p0p1": missing_opened_date_p0p1.iter().map(|g| {
                        serde_json::json!({"id": g.id, "priority": g.priority, "title": g.title})
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
                    let age_days = gap_age_days(&g.opened_date, g.created_at, now_secs);
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
                println!(
                    "Missing/placeholder opened_date on open P0/P1: {}",
                    missing_opened_date_p0p1.len()
                );
                for g in &missing_opened_date_p0p1 {
                    println!("  {} — {} ({})", g.id, g.title, g.priority);
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
                println!();
                println!(
                    "placeholder-title pollution (open): {}",
                    placeholder_pollution.len()
                );
                for g in &placeholder_pollution {
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
                // INFRA-902: pillar-balance-check.sh result.
                println!();
                println!("=== Pillar balance (INFRA-902) ===");
                if let Some(err) = pillar_balance.get("error").and_then(|v| v.as_str()) {
                    println!("  (unavailable: {})", err);
                } else {
                    let total = pillar_balance
                        .get("total_pickable")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                    println!("  total pickable: {}", total);
                    if let Some(counts) = pillar_balance.get("counts").and_then(|v| v.as_object()) {
                        for (pillar, count) in counts {
                            println!("    {:<12} {}", pillar, count);
                        }
                    }
                    if let Some(alerts) = pillar_balance.get("alerts").and_then(|v| v.as_array()) {
                        if alerts.is_empty() {
                            println!("  (pillars balanced — no alerts)");
                        } else {
                            for a in alerts {
                                println!("  ALERT: {}", a);
                            }
                        }
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
            // INFRA-8711: done_with_closed_pr counts EVERY gap that was
            // ever shipped normally (status=done, closed_pr=N is the
            // expected post-ship state, not drift) — it was never a
            // verified check that the PR is actually merged on GitHub
            // (that requires a gh API call, done by the dedicated
            // test-gap-closure-consistency.sh / premature-closure-watch.sh
            // daemon per GAP_REGISTRY_INVARIANTS.md I-1). Gating the exit
            // code on it made audit-priorities — and therefore
            // fleet-doctor-strict.sh's gap-drift check — permanently FAIL
            // once any gap had ever shipped. Kept as an informational
            // JSON/text field only; real premature-closure detection
            // stays with the GitHub-verified daemon.
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
        // EFFECTIVE-386: AC-writer — generate SPECIFIC, testable acceptance
        // criteria for a gap (the binding input the Gate-4 AC-judge needs).
        "write-ac" => {
            let gap_id = args.get(3).cloned().unwrap_or_default();
            if gap_id.is_empty() || gap_id == "--help" || gap_id == "-h" {
                println!("Usage: chump gap write-ac <GAP-ID> [--apply]");
                println!(
                    "  Generate SPECIFIC, testable acceptance criteria for the gap via the LLM."
                );
                println!(
                        "  --apply   Persist them via `chump gap set --acceptance-criteria` (else dry-run print)."
                    );
                println!("  Model: CHUMP_AC_WRITER_MODEL, else CHUMP_AC_JUDGE_MODEL, else opus.");
                if gap_id.is_empty() {
                    std::process::exit(2);
                }
                return Ok(());
            }
            let apply = args.iter().any(|a| a == "--apply");
            // EFFECTIVE-388: generate WITH repo grounding so the model names files
            // that actually exist (the ungrounded path hallucinated src/lib/gate.rs
            // etc. on EFFECTIVE-372).
            match crate::pr_ac_coverage::generate_ac_for_gap(&gap_id) {
                Ok(bullets) => {
                    println!(
                        "[write-ac] {gap_id}: {} acceptance criterion(s) generated:",
                        bullets.len()
                    );
                    for (i, b) in bullets.iter().enumerate() {
                        println!("  {}. {b}", i + 1);
                    }
                    // EFFECTIVE-388: flag any cited path that does NOT exist on disk
                    // (a task may legitimately create a new file, so WARN, don't drop).
                    let mut ghost_paths: Vec<String> = Vec::new();
                    for b in &bullets {
                        for p in crate::pr_ac_coverage::cited_paths(b) {
                            if !std::path::Path::new(&p).exists()
                                && !ghost_paths.iter().any(|g| g == &p)
                            {
                                ghost_paths.push(p);
                            }
                        }
                    }
                    if !ghost_paths.is_empty() {
                        eprintln!(
                                "[write-ac] ⚠ {} cited path(s) do NOT exist on disk (verify — may be new files, or hallucinated): {}",
                                ghost_paths.len(),
                                ghost_paths.join(", ")
                            );
                    }
                    if apply {
                        let self_bin = std::env::current_exe()
                            .map(|p| p.to_string_lossy().to_string())
                            .unwrap_or_else(|_| "chump".to_string());
                        let mut set_args: Vec<String> =
                            vec!["gap".into(), "set".into(), gap_id.clone()];
                        for b in &bullets {
                            set_args.push("--acceptance-criteria".into());
                            set_args.push(b.clone());
                        }
                        let ok = std::process::Command::new(&self_bin)
                            .args(&set_args)
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if ok {
                            println!("[write-ac] applied to {gap_id} via `chump gap set`.");
                        } else {
                            eprintln!("[write-ac] failed to apply AC to {gap_id}");
                            std::process::exit(1);
                        }
                    } else {
                        println!(
                            "[write-ac] dry-run — pass --apply to persist via `chump gap set`."
                        );
                    }
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("[write-ac] could not generate AC for {gap_id}: {e}");
                    std::process::exit(1);
                }
            }
        }
        "migrate-decomposed" => {
            if args
                .iter()
                .skip(2)
                .any(|a| matches!(a.as_str(), "--help" | "-h"))
            {
                println!("Usage: chump gap migrate-decomposed");
                println!();
                println!(
                    "Migrates legacy decomposed umbrellas from open/blocked/in-progress status"
                );
                println!("to decomposed status (RESILIENT-1382/RESILIENT-1383).");
                println!();
                println!("Prints a summary: total gaps inspected, migrated, and skipped.");
                println!("Returns non-zero exit code on unexpected errors.");
                return Ok(());
            }

            match store.migrate_decomposed_umbrellas() {
                Ok(log_entries) => {
                    let total = log_entries.len();
                    let migrated = log_entries
                        .iter()
                        .filter(|e| e.migration_status == "MIGRATED")
                        .count();
                    let skipped = total - migrated;

                    println!("Migration complete:");
                    println!("  Total gaps inspected: {}", total);
                    println!("  Migrated: {}", migrated);
                    println!(
                        "  Skipped (already decomposed or no eligible children): {}",
                        skipped
                    );

                    if migrated > 0 {
                        println!("\nDetails:");
                        for entry in &log_entries {
                            if entry.migration_status == "MIGRATED" {
                                println!(
                                    "  ✓ {} — {} children ({} terminal, {} non-terminal)",
                                    entry.gap_id,
                                    entry.child_count,
                                    entry.terminal_children,
                                    entry.non_terminal_children
                                );
                            }
                        }
                    }

                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump gap migrate-decomposed: {e:#}");
                    std::process::exit(1);
                }
            }
        }
        "decompose" => {
            // INFRA-1238: trap --help before positional validation.
            if args
                .iter()
                .skip(3)
                .any(|a| matches!(a.as_str(), "--help" | "-h"))
            {
                println!("Usage: chump gap decompose <GAP-ID> [--backend auto|cascade|claude] [--apply] [--verify] [--json] [--dry-run] [--no-description] [--external-repo <owner/repo|path>] [--clone-path <path>]");
                println!();
                println!("Suggests xs/s slices for a large (m/l) gap using the selected backend.");
                println!("  --backend <value>         LLM backend: auto (cascade then claude -p),");
                println!(
                        "                            cascade (local/cloud only), or claude (claude -p only)."
                    );
                println!(
                        "                            Default: the node's CHUMP_WORK_BACKEND routing config, else auto."
                    );
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
                println!();
                println!("Exit codes: 0 success/nothing-to-do, 1 not-open error,");
                println!("  11 refused — parent already has open child slices (INFRA-8067).");
                return Ok(());
            }
            let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap decompose <GAP-ID> [--backend auto|cascade|claude] [--apply] [--verify] [--json] [--dry-run] [--no-description] [--external-repo <owner/repo|path>] [--clone-path <path>]");
                    eprintln!();
                    eprintln!(
                        "Suggests xs/s slices for a large (m/l) gap using the selected backend."
                    );
                    eprintln!("  --backend <value>         auto (cascade then claude -p) | cascade | claude");
                    eprintln!("  --verify                  Validate slices via a stronger model before filing");
                    eprintln!("  --apply                   File the suggested slices and demote the parent");
                    eprintln!("  --json                    Output suggestions as JSON");
                    eprintln!("  --dry-run                 Print the full LLM prompt without calling the LLM");
                    eprintln!("  --no-description          Skip injecting the gap description into the prompt");
                    eprintln!("  --external-repo <value>   Decompose against an external repo (owner/repo or absolute path)");
                    eprintln!("  --clone-path <path>       Override the resolved clone path");
                    eprintln!();
                    eprintln!("Verify model: set CHUMP_VERIFY_API_BASE + CHUMP_VERIFY_MODEL,");
                    eprintln!("  or falls back to the shared provider cascade (INFRA-3464).");
                    std::process::exit(2);
                });
            let apply = args.iter().any(|a| a == "--apply");
            let verify = args.iter().any(|a| a == "--verify");
            let dry_run = args.iter().any(|a| a == "--dry-run");
            let no_description = args.iter().any(|a| a == "--no-description");

            // INFRA-8573: --backend selects the LLM backend (auto | cascade
            // | claude). When omitted, the node's routing config
            // (CHUMP_WORK_BACKEND, the same seam `chump dispatch` reads)
            // decides; default is auto (cascade first, then `claude -p`).
            let backend_flag: Option<String> = args
                .iter()
                .position(|a| a == "--backend")
                .and_then(|i| args.get(i + 1))
                .cloned();
            let decompose_backend = match crate::decompose_backend::DecomposeBackend::resolve(
                backend_flag.as_deref(),
            ) {
                Ok(b) => b,
                Err(e) => {
                    eprintln!("chump gap decompose: {e:#}");
                    std::process::exit(2);
                }
            };

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

            // INFRA-8067: refuse to re-slice a parent that already has
            // open child slices — root-cause fix for RESILIENT-1437 (the
            // gap-store's slice-bloat: the EFFECTIVE-310 decompose
            // reflex in scripts/dispatch/worker.sh re-slicing the same
            // parent gap repeatedly). The RESILIENT-1364 guard above
            // (parent.status != "open") only blocks a SECOND run once
            // the FIRST run finished cleanly and wrote
            // status=decomposed. A run that filed slices but was
            // interrupted before that final write (crash, kill -9,
            // wedge) leaves the parent looking "fresh" — still
            // status=open, no "Decomposed into" notes marker — so every
            // subsequent strike-threshold hit re-decomposes it into
            // another near-duplicate batch of slices. Counting slices
            // directly off the title convention `"... (<parent> slice)"`
            // (and depends_on) rather than the parent's own notes
            // bookkeeping catches exactly that orphaned-slices case.
            let open_slice_count = store.count_open_slices(&gap_id).unwrap_or(0);
            if open_slice_count >= 1 {
                eprintln!(
                        "decompose: {gap_id} already has {open_slice_count} open slice(s); refusing to re-slice"
                    );
                if json_out {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "parent": gap_id,
                            "refused": true,
                            "reason": "already_has_open_slices",
                            "open_slice_count": open_slice_count,
                        }))
                        .unwrap_or_default()
                    );
                }
                // Distinct exit code: callers (EFFECTIVE-310 reflex in
                // scripts/dispatch/worker.sh) must treat 11 as "refused,
                // do not reset strikes" — separate from 0 (success/
                // nothing-to-do) and 1 (hard error) above.
                std::process::exit(11);
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
            // INFRA-8573: route through the selected decompose backend so a
            // node with no local/cloud cascade (e.g. cuphead, Ollama absent)
            // still reaches an LLM via `claude -p`, and so a total failure
            // lists every provider tried in order.
            if !dry_run {
                eprintln!("chump gap decompose: backend={}", decompose_backend.label());
            }
            let decompose_model = std::env::var("CHUMP_DECOMPOSE_MODEL")
                .ok()
                .filter(|m| !m.is_empty());
            let provider = crate::decompose_backend::build_decompose_provider(
                decompose_backend,
                decompose_model,
            );
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
                        // Explicit operator override — honor it (legit direct).
                        let key = vkey.unwrap_or_default();
                        Some(Box::new(crate::local_openai::LocalOpenAIProvider::new(
                            base, key, model,
                        )))
                    } else {
                        // INFRA-3464: default to the shared cascade instead of a bespoke
                        // LocalOpenAIProvider pointed straight at the Anthropic endpoint.
                        // The cascade brings the full auth ladder (incl OAuth), 429 backoff,
                        // and slot fallback — and works for OAuth-only fleets, which the
                        // old ANTHROPIC_API_KEY-only path did not. (Closes debt site #5 of
                        // the LLM-service-fragmentation audit; reviewer done in INFRA-3462.)
                        Some(crate::provider_cascade::build_provider())
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

            // ── INFRA-1823 AC4: harvest pre-flight ──────────────────────
            //
            // Before slices are printed/filed, check the arsenal catalog
            // for prior art matching this gap so the implementing worker
            // sees it instead of re-inventing a primitive that already
            // exists elsewhere in the fleet. Best-effort: a missing
            // catalog (no `chump harvest scan` run yet) is not fatal to
            // decompose, it just means no citation is attached.
            let harvest_overlap: Option<String> = {
                let mut hit = None;
                let mut candidates = vec![gap_id.clone()];
                candidates.extend(
                    parent
                        .title
                        .split_whitespace()
                        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()).to_string())
                        .filter(|w| w.len() >= 5)
                        .take(4),
                );
                for topic in candidates {
                    if topic.is_empty() {
                        continue;
                    }
                    if let Some((found, text)) = harvester_cli::capture_check(&topic) {
                        if found && !text.is_empty() {
                            hit = Some(format!("[chump harvest check '{topic}']\n{text}"));
                            break;
                        }
                    }
                }
                hit
            };
            if let Some(ref overlap) = harvest_overlap {
                eprintln!();
                eprintln!("=== harvest pre-flight: prior-art overlap found ===");
                eprintln!("{overlap}");
                eprintln!("=== end harvest pre-flight ===");
            }

            if json_out {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "harvest_overlap": harvest_overlap,
                        "slices": suggestions
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
                        .collect::<Vec<_>>(),
                    }))
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
                    // INFRA-8043: slices inherit the parent's outcome; with none
                    // they file at P2 (P0/P1 require an outcome, MISSION-045).
                    let slice_outcome = parent.outcome_id.clone().filter(|o| !o.trim().is_empty());
                    let priority =
                        gap_store::effective_filing_priority(&priority, slice_outcome.as_deref())
                            .to_string();

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

                            // INFRA-1823 AC4: carry the harvest citation
                            // onto every filed sub-gap's notes so the
                            // implementing worker sees the prior art
                            // without having to re-run the check.
                            let notes_update: Option<String> = harvest_overlap.clone();

                            let _ = store.set_fields(
                                &new_id,
                                gap_store::GapFieldUpdate {
                                    acceptance_criteria: Some(ac_json),
                                    skills_required: skills_update,
                                    notes: notes_update,
                                    outcome_id: slice_outcome.clone(),
                                    ..Default::default()
                                },
                            );

                            // ZERO-WASTE-020: YAML mirrors retired —
                            // state.db is canonical. decompose no longer
                            // writes a per-file docs/gaps/<ID>.yaml mirror
                            // for filed sub-gaps.

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

                // RESILIENT-1364: demote parent to P2 AND take it out of
                // the pick pool. Before this fix the parent stayed
                // status='open' after decompose, so `chump gap list
                // --status open` (what every worker/curator picks from)
                // kept re-surfacing the umbrella itself alongside its own
                // slices — a worker would grab it, fail (it isn't
                // implementable, it's a tracking gap), and INFRA-3832
                // auto-blocked it 3 cycles later. status='decomposed' is
                // registered in gap_status_registry and is simply never
                // 'open', so no picker-side filter change is needed.
                let _ = store.set_fields(
                    &gap_id,
                    gap_store::GapFieldUpdate {
                        priority: Some("P2".into()),
                        status: Some("decomposed".into()),
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
                        "Decomposed {gap_id} into {} slices. Parent demoted to P2 and marked decomposed (out of the pick pool; auto-closes once every slice ships — see `chump gap close-decomposed`).",
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

        _ => {
            return Box::pin(gap_admin_modes::dispatch_gap_admin(
                args,
                repo_root,
                worktree_root,
                json_out,
                store,
            ))
            .await;
        }
    }
    Ok(())
}
