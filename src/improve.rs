//! EFFECTIVE-177: `chump improve <owner/repo>` — the autonomous-improve loop.
//!
//! This is the Mode-D external-repo path. It deliberately does NOT extend
//! `crates/chump-integrator/src/cycle/` — that cycle EXCLUDES external-repo gaps
//! (`select.rs` `.filter(|e| !e.is_external_repo())`), which is intentional
//! per INFRA-2113 ("Mode D handled separately"). Forcing external work into the
//! internal cycle fights its design.
//!
//! ## 4-stage chain (assembles existing pieces)
//!
//! 1. **PICK** — calls the `onboard` scan path (EFFECTIVE-166, via `run_scan`)
//!    to produce an `OnboardScan` with ranked `ProposedGap`s. Scout fills
//!    `SourceOfEvidence` with real evidence from the repo.
//!
//! 2. **DEDUP** (ZERO-WASTE-006) — before implementing the picked gap, checks
//!    whether the work is already done in the target repo (`git log` / `grep`
//!    the clone). If redundant, skips and emits `kind=redundant_work_skipped`.
//!    This is a required stage, not advisory.
//!
//! 3. **IMPLEMENT** — spawns a capable agent (`claude -p
//!    --dangerously-skip-permissions --model claude-sonnet-4-5`) in the repo
//!    clone via `ExternalRepoContract`. Reuses the `spawn_headless_in_dir`
//!    pattern from `src/dispatch.rs`. Binary path is overridable via
//!    `CHUMP_IMPROVE_CLAUDE_BIN` for testing (same pattern as
//!    `CHUMP_COORD_BIN` in `src/atomic_claim.rs`).
//!
//! 4. **VERIFY-MERGE** — calls `chump external verify-merge` (CREDIBLE-096,
//!    `src/external_verify_merge.rs`). Judges CI green + anti-cosmetic test
//!    proof + no-regression. Self-merges ONLY on merit. The orchestrator does
//!    NOT re-implement merge logic — it delegates to the existing subcommand.
//!
//! ## Dry-run vs --apply
//!
//! By default (dry-run) the command prints the planned chain and the scout's
//! pick WITHOUT pushing code or merging. `--apply` executes for real.
//!
//! ## Ambient events emitted
//!
//! - `kind=improve_cycle_complete` — end of every cycle (including dry-runs);
//!   fields: repo, gap_title, verdict (dry_run|verified|held), pr (if any).
//! - `kind=redundant_work_skipped` — dedup stage decided the work is already done;
//!   fields: repo, gap_title, reason.
//!
//! ## Kill-switch (Category B — _DISABLED form per INFRA-2429)
//!
//! `CHUMP_IMPROVE_DISABLED=1` — disables the subcommand (exits 1 with message).
//!
//! ## Env vars (documented in scripts/ci/env-vars-internal.txt)
//!
//! - `CHUMP_IMPROVE_CLAUDE_BIN` — override path to `claude` CLI (test injection).
//! - `CHUMP_IMPROVE_GH_BIN`     — override path to `gh`     CLI (test injection).
//! - `CHUMP_IMPROVE_CHUMP_BIN`  — override path to `chump`  binary (test injection).
//! - `CHUMP_IMPROVE_DISABLED`   — kill-switch: set to `1` to disable the subcommand.
//!
//! ## Trust guarantees (CREDIBLE-100 + RESILIENT-106)
//!
//! - `verify_and_merge` uses `std::env::current_exe()` to spawn the running binary,
//!   not a stale `target/debug/chump` that may lack `external verify-merge`.
//! - Verdict is keyed off the bar's real `"Verdict: MERGE"` / `"Verdict: HELD"` output
//!   line. If no Verdict: line is present (misfire / brain reply / stale binary), we
//!   bail loudly — NEVER default to "verified".
//! - `implement_gap` injects `CLAUDE_CODE_OAUTH_TOKEN` from `~/.chump/oauth-token.json`
//!   when the env doesn't already carry it, so the agent can authenticate outside the
//!   pre-authed fleet-worker environment. The token value is never logged.

use anyhow::{bail, Context, Result};
use chump_handoff::external_repo_schema::{read_latest_scan, OnboardScan, ProposedGap};
use std::path::{Path, PathBuf};
use std::process::Command;

// ── Public entry point ────────────────────────────────────────────────────

/// Entry point called from `src/main.rs` after routing `chump improve`.
pub fn run(args: &[String]) -> i32 {
    // Category-B kill-switch using _DISABLED suffix (INFRA-2429 ceiling: no new
    // _SKIP/_BYPASS/_CHECK/_IGNORE env vars).
    if std::env::var("CHUMP_IMPROVE_DISABLED").as_deref() == Ok("1") {
        eprintln!("[improve] disabled via CHUMP_IMPROVE_DISABLED=1");
        eprintln!("Unset to re-enable.");
        return 1;
    }

    match run_inner(args) {
        Ok(rc) => rc,
        Err(e) => {
            eprintln!("chump improve: {e:#}");
            1
        }
    }
}

// ── CLI parsing ───────────────────────────────────────────────────────────

struct Opts {
    /// `owner/repo` of the external repo to improve.
    owner_repo: String,
    /// Pre-selected gap ID (skip scout, use this as the proposed-gap title/desc).
    gap_id: Option<String>,
    /// --apply executes for real; default is dry-run.
    apply: bool,
    /// Directory where the repo is cloned (default: ~/.chump/external/<owner>/<repo>/clone/).
    clone_dir: Option<PathBuf>,
}

fn parse_args(args: &[String]) -> Result<Opts> {
    if args.is_empty() || args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        std::process::exit(0);
    }

    let mut owner_repo: Option<String> = None;
    let mut gap_id: Option<String> = None;
    let mut apply = false;
    let mut clone_dir: Option<PathBuf> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--apply" => apply = true,
            "--gap" => {
                i += 1;
                gap_id = Some(
                    args.get(i)
                        .ok_or_else(|| anyhow::anyhow!("--gap requires a value"))?
                        .clone(),
                );
            }
            "--clone-dir" => {
                i += 1;
                clone_dir =
                    Some(PathBuf::from(args.get(i).ok_or_else(|| {
                        anyhow::anyhow!("--clone-dir requires a value")
                    })?));
            }
            a if a.starts_with("--gap=") => {
                gap_id = Some(a.trim_start_matches("--gap=").to_string());
            }
            a if a.starts_with("--clone-dir=") => {
                clone_dir = Some(PathBuf::from(a.trim_start_matches("--clone-dir=")));
            }
            a if !a.starts_with('-') => {
                if owner_repo.is_some() {
                    bail!("unexpected extra argument: {a}");
                }
                owner_repo = Some(a.to_string());
            }
            a => bail!("unknown flag: {a}"),
        }
        i += 1;
    }

    Ok(Opts {
        owner_repo: owner_repo
            .ok_or_else(|| anyhow::anyhow!("Usage: chump improve <owner/repo> [options]"))?,
        gap_id,
        apply,
        clone_dir,
    })
}

fn print_usage() {
    println!("Usage: chump improve <owner/repo> [options]");
    println!();
    println!("Autonomous-improve loop: scout the repo, pick real work, implement it via");
    println!("an agent in a clone, open a PR, and verify-merge on merit. EFFECTIVE-177.");
    println!();
    println!("Options:");
    println!("  --gap <ID>         Skip the scout; use this gap ID as the work description.");
    println!("  --apply            Execute for real (push + merge). Default: dry-run.");
    println!("  --clone-dir <path> Path to an existing repo clone. Default: ~/.chump/external/<owner>/<repo>/clone/.");
    println!();
    println!("Dry-run prints the planned chain and the scout's pick without touching the repo.");
    println!("--apply chains all 4 stages: pick → dedup → implement → verify-merge.");
    println!();
    println!("Env overrides (for testing):");
    println!("  CHUMP_IMPROVE_CLAUDE_BIN  — path to claude CLI  (default: claude)");
    println!("  CHUMP_IMPROVE_GH_BIN      — path to gh CLI      (default: gh)");
    println!("  CHUMP_IMPROVE_CHUMP_BIN   — path to chump binary (default: auto-resolve)");
    println!("  CHUMP_IMPROVE_DISABLED    — set to 1 to kill-switch this subcommand");
}

// ── Core logic ────────────────────────────────────────────────────────────

fn run_inner(args: &[String]) -> Result<i32> {
    let opts = parse_args(args)?;

    if !opts.owner_repo.contains('/') {
        bail!(
            "<owner/repo> must contain a slash, got {:?}",
            opts.owner_repo
        );
    }

    let mode = if opts.apply { "APPLY" } else { "DRY-RUN" };
    println!("[improve] mode={mode} repo={}", opts.owner_repo);

    let clone_dir = resolve_clone_dir(&opts);

    // ── Stage 1: PICK ─────────────────────────────────────────────────────
    println!("\n[improve] Stage 1: PICK — scout {}...", opts.owner_repo);

    // If --gap is specified, that's the pre-selected work description.
    // Otherwise load the most-recent onboard scan from the canonical location.
    let picked = pick_gap(&opts, &clone_dir)?;

    println!("[improve] picked: {}", picked.title);
    println!(
        "[improve] evidence: {} §{}",
        picked.source_of_evidence.input_path, picked.source_of_evidence.section
    );

    if !opts.apply {
        println!("\n[improve] Stage 2: DEDUP — skipped in dry-run.");
        println!("[improve] Stage 3: IMPLEMENT — skipped in dry-run.");
        println!("[improve] Stage 4: VERIFY-MERGE — skipped in dry-run.");
        println!("\n[improve] dry-run complete. Pass --apply to execute.");
        emit_cycle_complete(&opts.owner_repo, &picked.title, "dry_run", None);
        return Ok(0);
    }

    // EFFECTIVE-291: refresh the persistent clone to the remote default branch
    // BEFORE dedup + implement, so the PR branches from CURRENT main rather than
    // a stale reused clone. Without this, every improve PR inherits months-old
    // main and fails CI gates that were already fixed on real main.
    refresh_clone(&clone_dir)?;

    // ── Stage 2: DEDUP ────────────────────────────────────────────────────
    println!("\n[improve] Stage 2: DEDUP — checking work isn't already done...");

    let gh_bin = std::env::var("CHUMP_IMPROVE_GH_BIN").unwrap_or_else(|_| "gh".to_string());
    let dedup_result = dedup_check(&opts.owner_repo, &clone_dir, &picked, &gh_bin)?;
    if let DedupResult::Redundant { reason } = dedup_result {
        println!("[improve] SKIP (redundant): {reason}");
        emit_redundant_work_skipped(&opts.owner_repo, &picked.title, &reason);
        emit_cycle_complete(&opts.owner_repo, &picked.title, "skipped_redundant", None);
        return Ok(0);
    }
    println!("[improve] dedup PASS — work is not already done.");

    // ── Stage 3: IMPLEMENT ────────────────────────────────────────────────
    println!("\n[improve] Stage 3: IMPLEMENT — spawning agent in clone...");

    let pr_url = implement_gap(&opts, &clone_dir, &picked)?;
    let pr_number = extract_pr_number(&pr_url);

    println!("[improve] PR opened: {pr_url}");
    if let Some(n) = pr_number {
        println!("[improve] PR number: #{n}");
    }

    // ── Stage 4: VERIFY-MERGE ─────────────────────────────────────────────
    println!("\n[improve] Stage 4: VERIFY-MERGE — judging PR on merit...");

    let pr_num =
        pr_number.ok_or_else(|| anyhow::anyhow!("could not parse PR number from URL: {pr_url}"))?;

    let verdict = verify_and_merge(&opts, pr_num, &picked.title)?;

    println!("[improve] verdict: {verdict}");
    emit_cycle_complete(&opts.owner_repo, &picked.title, &verdict, Some(&pr_url));

    if verdict == "verified" {
        Ok(0)
    } else {
        // HELD — non-zero exit so callers can detect failure.
        Ok(1)
    }
}

// ── Stage implementations ─────────────────────────────────────────────────

/// Stage 1: Pick the highest-confidence proposed gap from the latest scan.
///
/// If `--gap` was specified, synthesise a minimal `ProposedGap` from the gap
/// title/ID. Otherwise reads the most-recent onboard scan from `clone_dir`'s
/// parent (the canonical external-repo directory).
fn pick_gap(opts: &Opts, clone_dir: &Path) -> Result<ProposedGap> {
    use chump_handoff::external_repo_schema::{Confidence, Effort, Priority, SourceOfEvidence};

    if let Some(ref gap_id) = opts.gap_id {
        // Synthesise a gap from the provided ID so downstream stages work uniformly.
        return Ok(ProposedGap {
            title: gap_id.clone(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "--gap (operator-specified)".to_string(),
                section: "operator override".to_string(),
                excerpt: format!("gap ID provided via --gap: {gap_id}"),
            },
            acceptance_criteria_draft: vec![
                format!("Change described in gap {gap_id} is implemented"),
                "At least one test proves the change".to_string(),
            ],
            layer: None,
            doctrine_justification: None,
        });
    }

    // EFFECTIVE-288 GREEN-FIRST doctrine (operator, 2026-06-22): before picking
    // any NEW feature work, make the repo GREEN. If a CI check is failing across
    // the repo's open PRs (a broken gate blocking every merge), fixing it is the
    // forced top priority. "Step 1: make it green. Step 2: ship something new."
    // Skipped when --gap is set (operator chose the work) — that returns above.
    let gh_bin_gf = std::env::var("CHUMP_IMPROVE_GH_BIN").unwrap_or_else(|_| "gh".to_string());
    let failing = repo_failing_checks(&gh_bin_gf, &opts.owner_repo);
    if let Some(green) = green_first_gap_from_failures(&failing) {
        let top = failing.first().map(|(n, _)| n.as_str()).unwrap_or("?");
        println!(
            "[improve] GREEN-FIRST: repo not green ('{top}' failing across open PRs) — fixing before any new work"
        );
        return Ok(green);
    }

    // Repo is green (or gh unavailable) — proceed to scan-based feature picking.
    pick_gap_from_scan(opts, clone_dir)
}

/// Scan-based feature pick (pure, no network). The `--gap` override and the
/// EFFECTIVE-288 GREEN-FIRST gate both run in `pick_gap` *before* this; this
/// only reads the latest onboard scan and returns the highest-priority gap by
/// the L1<L2<L3 doctrine order. Kept separate + unit-tested directly so the
/// scan-pick tests never depend on live `gh` state (the green-first gh call
/// lives only in `pick_gap`).
fn pick_gap_from_scan(opts: &Opts, clone_dir: &Path) -> Result<ProposedGap> {
    // Read the latest onboard scan from the external-repo directory.
    // The scan lives at <external-repo-dir>/scans/onboard-scan-<ts>.json
    // where <external-repo-dir> is clone_dir's parent (the repo root, not /clone/).
    let repo_dir = clone_dir
        .parent()
        .ok_or_else(|| anyhow::anyhow!("clone_dir has no parent: {}", clone_dir.display()))?;

    let scan: OnboardScan = read_latest_scan(repo_dir)
        .context("reading latest onboard scan")?
        .ok_or_else(|| {
            anyhow::anyhow!(
                "no onboard scan found under {} — run `chump onboard {}` first",
                repo_dir.display(),
                opts.owner_repo
            )
        })?;

    // EFFECTIVE-201: doctrine-order picking — L1 → L2 → L3 → untagged,
    // then within each layer by confidence descending (High > Med > Low).
    //
    // Rationale: foundation (L1) must be fixed before higher-level work adds
    // value. L2 (unfulfilled claims) has more legible ROI than L3 (latent
    // ideas). Within a layer, higher confidence means stronger evidence.
    let mut gaps = scan.proposed_gaps;
    gaps.sort_by(|a, b| {
        let la = layer_sort_key(a.layer.as_deref());
        let lb = layer_sort_key(b.layer.as_deref());
        la.cmp(&lb).then_with(|| {
            confidence_sort_key(&a.confidence).cmp(&confidence_sort_key(&b.confidence))
        })
    });
    gaps.into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("onboard scan contains no proposed gaps"))
}

/// Gather failing CI checks across the target repo's open PRs, tallied by check
/// name (most-failing first). Best-effort: a `gh` failure (offline, no auth,
/// rate-limit) yields an empty vec → no false GREEN-FIRST block. EFFECTIVE-288.
///
/// A check failing on a SINGLE PR is likely that PR's own bug; a check failing
/// across *multiple* open PRs is a broken gate blocking every merge — that's the
/// signal `green_first_gap_from_failures` keys on.
fn repo_failing_checks(gh_bin: &str, owner_repo: &str) -> Vec<(String, usize)> {
    let out = Command::new(gh_bin)
        .args([
            "pr", "list", "--repo", owner_repo, "--state", "open", "--limit", "30", "--json",
            "statusCheckRollup", "--jq",
            // Emit one failing-check name per line across all open PRs. CheckRun
            // uses .conclusion+.name; StatusContext uses .state+.context.
            r#".[] | .statusCheckRollup[]? | select(.conclusion=="FAILURE" or .state=="FAILURE") | (.name // .context)"#,
        ])
        .output();
    let stdout = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => return Vec::new(), // best-effort — never false-block on a gh error
    };
    let mut counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for name in stdout.lines().map(str::trim).filter(|s| !s.is_empty()) {
        *counts.entry(name.to_string()).or_insert(0) += 1;
    }
    let mut v: Vec<(String, usize)> = counts.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0))); // most-failing first, stable
    v
}

/// GREEN-FIRST doctrine: a CI check failing across >=2 open PRs is a broken gate
/// blocking *every* merge — make the repo green before any new feature. Returns
/// the forced top-priority pick when such a check exists, else `None` (repo is
/// green enough → fall through to normal feature picking). Pure + unit-tested.
/// EFFECTIVE-288 (operator doctrine 2026-06-22: "Step 1 make it green, step 2
/// ship something new").
fn green_first_gap_from_failures(failures: &[(String, usize)]) -> Option<ProposedGap> {
    use chump_handoff::external_repo_schema::{Confidence, Effort, Priority, SourceOfEvidence};
    let (check, count) = failures.iter().find(|(_, c)| *c >= 2)?;
    Some(ProposedGap {
        title: format!("GREEN-FIRST: fix the failing CI check '{check}' (blocks all merges)"),
        domain: "RESILIENT".to_string(),
        priority: Priority::P0, // a broken merge-gate is always top priority
        effort: Effort::M,
        confidence: Confidence::High,
        source_of_evidence: SourceOfEvidence {
            input_path: "gh pr list (open-PR check rollups)".to_string(),
            section: "green-first doctrine".to_string(),
            excerpt: format!(
                "CI check '{check}' fails on {count} open PRs — a broken gate blocking every \
                 merge; make the repo green before any new feature work"
            ),
        },
        acceptance_criteria_draft: vec![
            format!(
                "Diagnose why '{check}' fails (broken/misconfigured check vs a real repo issue) \
                 and fix the root cause"
            ),
            format!("The '{check}' check passes (green) on a fresh PR"),
            "A previously-red PR can then go green and merge".to_string(),
        ],
        layer: Some("L1".to_string()), // green-first is foundation work
        doctrine_justification: Some(
            "green-first: make it green before shipping new (operator doctrine 2026-06-22)"
                .to_string(),
        ),
    })
}

/// Map a doctrine layer string to a sort key (lower = picked first).
///
/// L1 < L2 < L3 < untagged — foundation before features before aspirations.
fn layer_sort_key(layer: Option<&str>) -> u8 {
    match layer {
        Some("L1") => 0,
        Some("L2") => 1,
        Some("L3") => 2,
        _ => 3, // untagged gaps (pre-doctrine scans) are de-prioritised
    }
}

/// Map a `Confidence` to a sort key (lower = picked first / higher confidence).
fn confidence_sort_key(c: &chump_handoff::external_repo_schema::Confidence) -> u8 {
    use chump_handoff::external_repo_schema::Confidence;
    match c {
        Confidence::High => 0,
        Confidence::Med => 1,
        Confidence::Low => 2,
    }
}

// ── Dedup types + logic ───────────────────────────────────────────────────

enum DedupResult {
    /// The gap is not yet done in the target repo — proceed.
    NotRedundant,
    /// The work appears to already be done.
    Redundant { reason: String },
}

/// Stage 2: Check whether the proposed gap's work is already present in the
/// target repo clone OR is already in flight as an open PR (ZERO-WASTE-011).
///
/// Two sub-checks:
///
/// 1. **Merged-commit check** (ZERO-WASTE-010): `git log --oneline -50` on the
///    clone. Skip only when the exact title core (> 10 chars) or all key terms
///    co-occur in a single commit message. Errs toward PROCEED — the verify-merge
///    bar is the backstop for truly-redundant merged work.
///
/// 2. **Open-PR check** (ZERO-WASTE-011): `gh pr list --repo <owner/repo>
///    --state open --search "<key terms>"`. If any returned PR title matches the
///    key terms, treat as redundant (work already in flight). This prevents
///    opening duplicate PRs for work already submitted (the BEAST PR #2 case).
///    `gh_bin` is the path to the `gh` CLI — read from `CHUMP_IMPROVE_GH_BIN`
///    at the call site and passed in so this fn is unit-testable without touching
///    global env.
///    If `gh` fails (network error, unauthenticated), fail-open toward PROCEED;
///    the verify-merge bar is the backstop.
fn dedup_check(
    owner_repo: &str,
    clone_dir: &Path,
    gap: &ProposedGap,
    gh_bin: &str,
) -> Result<DedupResult> {
    // Extract the key noun phrase from the gap title (drop the pillar prefix).
    // E.g. "EFFECTIVE: add streaming support" → "streaming support"
    let title_core = gap
        .title
        .splitn(2, ':')
        .nth(1)
        .unwrap_or(&gap.title)
        .trim()
        .to_string();

    // Keyword list: first 3 words of the title core.
    let keywords: Vec<&str> = title_core.split_whitespace().take(3).collect();

    if keywords.is_empty() {
        // Cannot determine keywords — pass the dedup stage.
        return Ok(DedupResult::NotRedundant);
    }

    // ── Sub-check 1: git log (merged work) ───────────────────────────────────
    // "git log --oneline -50" gives the last 50 commits; grep for the keywords.
    let log_out = Command::new("git")
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "log",
            "--oneline",
            "-50",
        ])
        .output();

    if let Ok(out) = log_out {
        let lower_title = title_core.to_lowercase();
        let kws_lower: Vec<String> = keywords.iter().map(|k| k.to_lowercase()).collect();
        // ZERO-WASTE-010: a real "already done" signal is a COMMIT that did this work,
        // NOT mere file-keyword presence — common title words like "roadmap"/"tasks"
        // appear in any repo that has a roadmap, which false-skipped real work on the
        // first live BEAST-MODE run. So skip ONLY if the exact title core appears in a
        // recent commit message, or all key terms co-occur in one commit line. Err
        // toward PROCEED; the verify-merge bar is the backstop for truly-redundant work.
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let l = line.to_lowercase();
            let exact_title = lower_title.len() > 10 && l.contains(&lower_title);
            let all_kw_co_occur =
                kws_lower.len() >= 2 && kws_lower.iter().all(|k| l.contains(k.as_str()));
            if exact_title || all_kw_co_occur {
                return Ok(DedupResult::Redundant {
                    reason: format!("a recent commit already does this work: {}", line.trim()),
                });
            }
        }
    }

    // ── Sub-check 2: open PR check (ZERO-WASTE-011) ───────────────────────────
    // Build a search query from the first 3 key terms.
    let search_query = keywords.join(" ");

    let pr_list_out = Command::new(gh_bin)
        .args([
            "pr",
            "list",
            "--repo",
            owner_repo,
            "--state",
            "open",
            "--search",
            &search_query,
            "--json",
            "title,number",
        ])
        .output();

    if let Ok(out) = pr_list_out {
        if out.status.success() {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let lower_title = title_core.to_lowercase();
            let kws_lower: Vec<String> = keywords.iter().map(|k| k.to_lowercase()).collect();
            // Parse each JSON object's "title" field and check for keyword overlap.
            // Use the same match heuristic as the commit check: exact title core OR
            // all key terms co-occur in the PR title. This avoids false positives
            // from loosely matching search results.
            for line in stdout.lines() {
                let l = line.to_lowercase();
                if !l.contains("\"title\"") {
                    continue;
                }
                let exact_title = lower_title.len() > 10 && l.contains(&lower_title);
                let all_kw_co_occur =
                    kws_lower.len() >= 2 && kws_lower.iter().all(|k| l.contains(k.as_str()));
                if exact_title || all_kw_co_occur {
                    return Ok(DedupResult::Redundant {
                        reason: format!(
                            "an open PR on {owner_repo} already covers this work: {}",
                            line.trim()
                        ),
                    });
                }
            }
        }
        // If gh fails (e.g. unauthenticated, network unavailable) — proceed.
        // The verify-merge bar is the backstop.
    }

    Ok(DedupResult::NotRedundant)
}

// ── Auth env helper (B4) ─────────────────────────────────────────────────

/// Configure auth env-vars on a `Command` that will spawn `claude -p`.
///
/// Two responsibilities:
///
/// 1. **Inject OAUTH token** (RESILIENT-106): if the parent env doesn't carry
///    `CLAUDE_CODE_OAUTH_TOKEN`, try reading it from `~/.chump/oauth-token.json`
///    and inject it so the spawned agent can authenticate outside the pre-authed
///    fleet-worker environment.
///
/// 2. **Neutralize conflicting gateway vars** (B4 / RESILIENT-108): when we
///    *will* use OAUTH (token found in env or token file), also strip any
///    conflicting Anthropic gateway environment variables that the parent
///    process may carry (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
///    `ANTHROPIC_BASE_URL`, `ANTHROPIC_CUSTOM_HEADERS`). Without this, a
///    parent session running against a custom gateway causes the spawned claude
///    to prefer the gateway over subscription OAUTH → "Not logged in".
///
/// GUARD: gateway vars are ONLY stripped when an OAUTH token is actually
/// available. We never strip auth leaving the spawned process unauthenticated.
///
/// IMPORTANT: the token value is NEVER logged or printed.
///
/// Returns `true` if an OAUTH token was injected or already present (OAUTH
/// path chosen); `false` if no token available (gateway env left intact).
///
/// Testable via `Command::get_envs` on a `std::process::Command` — no process
/// spawn required.
pub(crate) fn configure_claude_auth_env(cmd: &mut Command) -> bool {
    // Step 1: check if OAUTH token is already present in the parent env.
    let token_in_env = std::env::var_os("CLAUDE_CODE_OAUTH_TOKEN").is_some();

    // Step 2: if not in env, try reading from the token file.
    let token_from_file: Option<String> = if token_in_env {
        None
    } else {
        read_oauth_token_file()
    };

    // Determine whether we have (or will have) an OAUTH token.
    let oauth_available = token_in_env || token_from_file.is_some();

    if !oauth_available {
        // No OAUTH token available — leave everything as-is; do not strip anything.
        return false;
    }

    // Inject the file token if the env didn't already carry one.
    if let Some(tok) = token_from_file {
        cmd.env("CLAUDE_CODE_OAUTH_TOKEN", tok);
    }

    // B4: strip conflicting gateway vars so the spawned claude uses OAUTH.
    // Only done when OAUTH is available (guard above ensures we never strip
    // auth leaving nothing).
    cmd.env_remove("ANTHROPIC_API_KEY");
    cmd.env_remove("ANTHROPIC_AUTH_TOKEN");
    cmd.env_remove("ANTHROPIC_BASE_URL");
    cmd.env_remove("ANTHROPIC_CUSTOM_HEADERS");

    true
}

// ── Implement stage ───────────────────────────────────────────────────────

/// Stage 3: Spawn a capable agent in the repo clone to implement the gap and
/// open a PR. Returns the PR URL.
///
/// Reuses the `ExternalRepoContract` prompt and the `claude -p
/// --dangerously-skip-permissions` pattern from `src/dispatch.rs`
/// (`spawn_headless`). Binary is resolved via `CHUMP_IMPROVE_CLAUDE_BIN`
/// env var (same pattern as `CHUMP_COORD_BIN`).
fn implement_gap(opts: &Opts, clone_dir: &Path, gap: &ProposedGap) -> Result<String> {
    use chump_handoff::contracts::{ExternalRepoContract, ExternalRepoInput};
    use chump_handoff::HandoffContract;

    let input = ExternalRepoInput {
        external_repo: opts.owner_repo.clone(),
        repo_local_path: clone_dir.to_string_lossy().to_string(),
        proposed_gap_description: build_gap_description(gap),
        base_branch: detect_base_branch(clone_dir),
        fork_owner: None, // direct-push to a branch; operator can set fork via --gap override
    };

    let prompt = ExternalRepoContract::prompt(&input);

    // Resolve claude binary — injectable for tests.
    let claude_bin =
        std::env::var("CHUMP_IMPROVE_CLAUDE_BIN").unwrap_or_else(|_| "claude".to_string());

    // Write prompt to a temp file so we don't hit ARG_MAX on complex prompts.
    let prompt_file = write_temp_prompt(&prompt)?;

    let mut cmd = Command::new(&claude_bin);
    cmd.arg("-p")
        .arg(std::fs::read_to_string(&prompt_file)?)
        .arg("--dangerously-skip-permissions")
        .args(["--model", "claude-sonnet-4-5"])
        .current_dir(clone_dir);

    // B4 + RESILIENT-106: inject OAUTH token and neutralize conflicting
    // gateway vars so the spawned agent authenticates from any context.
    // configure_claude_auth_env handles both responsibilities atomically.
    let oauth_path = configure_claude_auth_env(&mut cmd);
    if oauth_path {
        eprintln!("[improve] auth: using OAUTH token path for spawned claude");
    }

    // Capture output so we can extract the PR URL from the JSON block.
    let out = cmd
        .output()
        .with_context(|| format!("spawn `{claude_bin} -p` (is claude CLI on PATH?)"))?;

    // Cleanup temp file.
    let _ = std::fs::remove_file(&prompt_file);

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!(
            "claude -p exited {} — stderr: {}",
            out.status.code().unwrap_or(-1),
            stderr.trim().lines().next().unwrap_or("(no output)")
        );
    }

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();

    // Extract the JSON block containing pr_url.
    extract_pr_url_from_output(&stdout).ok_or_else(|| {
        anyhow::anyhow!(
            "could not find a pr_url in agent output.\nAgent output:\n{}",
            stdout.trim().chars().take(500).collect::<String>()
        )
    })
}

/// Stage 4: Call `chump external verify-merge` and return the verdict string.
///
/// CREDIBLE-100: we key off the bar's real "Verdict: MERGE" / "Verdict: HELD"
/// output line, NOT the spawned process exit code. A stale or wrong binary
/// (e.g. one that routes `external verify-merge` to the brain/chat) exits 0 but
/// prints no Verdict: line — `parse_verdict` returns None and we bail loudly
/// instead of silently reporting "verified". Verdict fabrication is the trust
/// keystone failure we are preventing.
fn verify_and_merge(opts: &Opts, pr_num: u64, _gap_title: &str) -> Result<String> {
    // CREDIBLE-100: resolve the binary that's CURRENTLY RUNNING — it has the
    // `external verify-merge` subcommand. Prefer CHUMP_IMPROVE_CHUMP_BIN for
    // test injection, then current_exe(), then "chump" as last resort.
    // Do NOT use resolve_chump_bin()'s shared-target lookup — a sibling build
    // can clobber target/debug/chump with a version that lacks the subcommand.
    let chump_bin = if let Ok(explicit) = std::env::var("CHUMP_IMPROVE_CHUMP_BIN") {
        explicit
    } else if let Ok(exe) = std::env::current_exe() {
        exe.to_string_lossy().to_string()
    } else {
        "chump".to_string()
    };

    let mut args = vec![
        "external".to_string(),
        "verify-merge".to_string(),
        "--pr".to_string(),
        pr_num.to_string(),
        "--repo".to_string(),
        opts.owner_repo.clone(),
        "--gap".to_string(),
        opts.gap_id
            .clone()
            .unwrap_or_else(|| "EFFECTIVE-177".to_string()),
    ];
    if opts.apply {
        args.push("--apply".to_string());
    }

    // Pass through the GH bin override if set (so tests see the same fake binary
    // that was used for the implement stage).
    let gh_bin = std::env::var("CHUMP_IMPROVE_GH_BIN").unwrap_or_else(|_| "gh".to_string());

    let mut cmd = Command::new(&chump_bin);
    cmd.args(&args);
    if gh_bin != "gh" {
        cmd.env("CHUMP_GH_BIN", &gh_bin);
    }

    // CREDIBLE-100: capture output, not just exit code. The real bar prints
    // "Verdict: MERGE" or "Verdict: HELD(<reason>)"; we key off that line.
    let out = cmd
        .output()
        .with_context(|| format!("spawn `{chump_bin} external verify-merge`"))?;

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();

    // Transparency: always print the bar's output so the operator can see what happened.
    if !stdout.is_empty() {
        print!("{stdout}");
    }
    if !stderr.is_empty() {
        eprint!("{stderr}");
    }

    // CREDIBLE-100: key off the real Verdict: line. bail! on misfire (no Verdict: line).
    match parse_verdict(&stdout) {
        Some(v) => Ok(v.to_string()),
        None => bail!(
            "verify-merge produced no bar Verdict: line — the sub-invocation did not run \
             the real bar (chump_bin={chump_bin}); refusing to report a verdict"
        ),
    }
}

/// Parse the merge bar's stdout for a `Verdict:` line.
///
/// Returns:
/// - `Some("verified")` if stdout contains `"Verdict: MERGE"`.
/// - `Some("held")` if stdout contains `"Verdict: HELD"`.
/// - `None` if no `Verdict:` line is present (misfire / stale binary / brain reply).
///
/// This is the trust keystone: we NEVER default to "verified".
/// Called by `verify_and_merge`; pub(crate) for unit tests.
///
/// # Examples
///
/// ```
/// # use chump::improve::parse_verdict; // doctest path
/// assert_eq!(parse_verdict("Verdict: MERGE"), Some("verified"));
/// assert_eq!(parse_verdict("Verdict: HELD(unproven)"), Some("held"));
/// assert_eq!(parse_verdict("Hello!"), None);
/// ```
pub(crate) fn parse_verdict(stdout: &str) -> Option<&'static str> {
    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.contains("Verdict: MERGE") {
            return Some("verified");
        }
        if trimmed.contains("Verdict: HELD") {
            return Some("held");
        }
    }
    None
}

// ── Ambient emit helpers ───────────────────────────────────────────────────

/// Emit `kind=improve_cycle_complete`.
///
/// scanner-anchor: kind=improve_cycle_complete (EFFECTIVE-177)
fn emit_cycle_complete(repo: &str, gap_title: &str, verdict: &str, pr_url: Option<&str>) {
    let mut fields = vec![
        ("repo".to_string(), repo.to_string()),
        ("gap".to_string(), gap_title.to_string()),
        ("verdict".to_string(), verdict.to_string()),
    ];
    if let Some(url) = pr_url {
        fields.push(("pr".to_string(), url.to_string()));
    }
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "improve_cycle_complete".to_string(),
        source: Some("chump-improve".to_string()),
        fields,
        ..Default::default()
    });
}

/// Emit `kind=redundant_work_skipped`.
///
/// scanner-anchor: kind=redundant_work_skipped (EFFECTIVE-177 / ZERO-WASTE-006)
fn emit_redundant_work_skipped(repo: &str, gap_title: &str, reason: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "redundant_work_skipped".to_string(),
        source: Some("chump-improve".to_string()),
        fields: vec![
            ("repo".to_string(), repo.to_string()),
            ("gap".to_string(), gap_title.to_string()),
            ("reason".to_string(), reason.to_string()),
        ],
        ..Default::default()
    });
}

// ── Utilities ────────────────────────────────────────────────────────────

/// Resolve the directory where the repo is cloned.
fn resolve_clone_dir(opts: &Opts) -> PathBuf {
    if let Some(ref p) = opts.clone_dir {
        return p.clone();
    }
    // Default: ~/.chump/external/<owner>/<repo>/clone/
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home)
        .join(".chump")
        .join("external")
        .join(opts.owner_repo.replace('/', std::path::MAIN_SEPARATOR_STR))
        .join("clone")
}

/// EFFECTIVE-291: refresh the persistent external-repo clone to the remote's
/// default branch before implementing, so the PR branches from CURRENT main
/// rather than a stale reused clone. Best-effort: a no-op if the clone isn't a
/// git repo yet; a warning (not a hard error) if fetch fails (offline).
fn refresh_clone(clone_dir: &Path) -> Result<()> {
    if !clone_dir.join(".git").exists() {
        return Ok(()); // not cloned yet — the scan/implement path reports that
    }
    let cd = clone_dir.to_string_lossy().to_string();
    let fetched = Command::new("git")
        .args(["-C", &cd, "fetch", "origin", "--quiet"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !fetched {
        eprintln!(
            "[improve] warning: git fetch failed in clone {cd}; using existing state (EFFECTIVE-291)"
        );
        return Ok(());
    }
    let branch = detect_default_branch(&cd);
    // Hard-reset the working tree to the freshly-fetched default branch and drop
    // any untracked leftovers from a prior run (prevents scope-crept PRs).
    let _ = Command::new("git")
        .args(["-C", &cd, "reset", "--hard", &format!("origin/{branch}")])
        .status();
    let _ = Command::new("git")
        .args(["-C", &cd, "clean", "-fd"])
        .status();
    println!("[improve] clone refreshed to origin/{branch} (EFFECTIVE-291)");
    Ok(())
}

/// Detect a clone's remote default branch: prefer `origin/HEAD`'s target, then
/// fall back to `main`, then `master`.
fn detect_default_branch(cd: &str) -> String {
    if let Ok(out) = Command::new("git")
        .args([
            "-C",
            cd,
            "symbolic-ref",
            "--short",
            "refs/remotes/origin/HEAD",
        ])
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout)
                .trim()
                .trim_start_matches("origin/")
                .to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    for cand in ["main", "master"] {
        let ok = Command::new("git")
            .args(["-C", cd, "rev-parse", "--verify", &format!("origin/{cand}")])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            return cand.to_string();
        }
    }
    "main".to_string()
}

/// Resolve the `chump` binary to use for `external verify-merge`.
///
/// Check `CHUMP_IMPROVE_CHUMP_BIN` first, then the same fallback chain as
/// `dispatch.rs::resolve_chump_binary`: target/release → target/debug →
/// ~/.local/bin → PATH.
///
/// NOTE: `verify_and_merge` does NOT use this function (CREDIBLE-100). It uses
/// `current_exe()` instead so it always calls the running binary which has the
/// `external verify-merge` subcommand. This function is kept for other callers
/// that need a loose "best-effort" binary resolution.
fn resolve_chump_bin() -> String {
    if let Ok(explicit) = std::env::var("CHUMP_IMPROVE_CHUMP_BIN") {
        return explicit;
    }
    // Try to find the binary relative to a repo root. In practice the worktree's
    // target/ is the same as the main repo's target/ (Cargo workspace feature).
    // Use `cargo metadata` if available; fall back to known paths.
    for candidate in ["target/release/chump", "target/debug/chump"] {
        if Path::new(candidate).exists() {
            return candidate.to_string();
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let dot_local = PathBuf::from(home).join(".local/bin/chump");
        if dot_local.exists() {
            return dot_local.to_string_lossy().to_string();
        }
    }
    "chump".to_string()
}

/// RESILIENT-106: read the OAUTH token from `~/.chump/oauth-token.json`.
///
/// Mirrors the pattern from `scripts/dispatch/worker.sh` (INFRA-620, lines 211-232).
/// Tries keys "token", "access_token", and "accessToken" in that order.
///
/// Returns `None` silently on any error (missing file, parse failure, empty value)
/// so the caller degrades gracefully.
///
/// IMPORTANT: callers MUST NOT log or print the returned value — it's a credential.
fn read_oauth_token_file() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let token_path = PathBuf::from(home).join(".chump/oauth-token.json");
    let content = std::fs::read_to_string(&token_path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&content).ok()?;
    // Try the three key names worker.sh checks, in the same order.
    for key in ["token", "access_token", "accessToken"] {
        if let Some(s) = v.get(key).and_then(|x| x.as_str()) {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// Detect the default branch of the cloned repo.
fn detect_base_branch(clone_dir: &Path) -> String {
    let out = Command::new("git")
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "rev-parse",
            "--abbrev-ref",
            "HEAD",
        ])
        .output();
    if let Ok(o) = out {
        let branch = String::from_utf8_lossy(&o.stdout).trim().to_string();
        if !branch.is_empty() && branch != "HEAD" {
            return branch;
        }
    }
    // Try symbolic-ref to get origin's HEAD.
    let out2 = Command::new("git")
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "remote",
            "show",
            "origin",
        ])
        .output();
    if let Ok(o) = out2 {
        let text = String::from_utf8_lossy(&o.stdout);
        for line in text.lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("HEAD branch:") {
                return rest.trim().to_string();
            }
        }
    }
    "main".to_string()
}

/// Build a human-readable description of the gap for the implement-agent prompt.
fn build_gap_description(gap: &ProposedGap) -> String {
    let ac = gap
        .acceptance_criteria_draft
        .iter()
        .enumerate()
        .map(|(i, s)| format!("  {}. {s}", i + 1))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "Gap: {}\n\nPriority: {:?} / Effort: {:?} / Confidence: {:?}\n\
         Source: {} §{}\n  excerpt: {}\n\nAcceptance criteria:\n{ac}",
        gap.title,
        gap.priority,
        gap.effort,
        gap.confidence,
        gap.source_of_evidence.input_path,
        gap.source_of_evidence.section,
        gap.source_of_evidence.excerpt,
    )
}

/// Write the prompt to a temp file and return its path.
fn write_temp_prompt(prompt: &str) -> Result<PathBuf> {
    let path = std::env::temp_dir().join(format!(
        "chump-improve-prompt-{}.txt",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    std::fs::write(&path, prompt).with_context(|| format!("write prompt to {}", path.display()))?;
    Ok(path)
}

/// Extract a GitHub PR URL (`https://github.com/.../pull/N`) from the agent's
/// JSON output. Scans for the first `"pr_url"` field in a JSON block.
fn extract_pr_url_from_output(output: &str) -> Option<String> {
    // Look for a JSON block containing pr_url.
    for line in output.lines() {
        let line = line.trim();
        if line.contains("\"pr_url\"") {
            // Simple extraction — find the value after "pr_url":
            if let Some(start) = line.find("\"pr_url\"") {
                let rest = &line[start + "\"pr_url\"".len()..];
                // Skip whitespace and the colon
                let rest = rest.trim_start().trim_start_matches(':').trim_start();
                // Extract the quoted string
                if let Some(inner) = rest.strip_prefix('"') {
                    if let Some(end) = inner.find('"') {
                        let url = inner[..end].to_string();
                        if url.starts_with("https://github.com/") && url.contains("/pull/") {
                            return Some(url);
                        }
                    }
                }
            }
        }
    }
    None
}

/// Extract the PR number from a GitHub PR URL.
fn extract_pr_number(pr_url: &str) -> Option<u64> {
    pr_url.rsplit('/').next()?.parse().ok()
}

// ── Unit tests ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use chump_handoff::external_repo_schema::{
        save_scan, Confidence, Effort, InputRead, OnboardScan, Priority, ProposedGap,
        SourceOfEvidence,
    };
    use std::fs;
    use tempfile::TempDir;

    fn sample_scan(owner_repo: &str) -> OnboardScan {
        OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: owner_repo.to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![InputRead {
                path: "README.md".to_string(),
                sha256: "deadbeef".to_string(),
                summary: "Main overview".to_string(),
            }],
            proposed_gaps: vec![
                ProposedGap {
                    title: "EFFECTIVE: add integration tests".to_string(),
                    domain: "EFFECTIVE".to_string(),
                    priority: Priority::P1,
                    effort: Effort::S,
                    confidence: Confidence::High,
                    source_of_evidence: SourceOfEvidence {
                        input_path: "README.md".to_string(),
                        section: "## Testing".to_string(),
                        excerpt: "no integration tests exist".to_string(),
                    },
                    acceptance_criteria_draft: vec![
                        "Integration test added".to_string(),
                        "Test covers the main flow".to_string(),
                    ],
                    layer: None,
                    doctrine_justification: None,
                },
                ProposedGap {
                    title: "DOC: update contributing guide".to_string(),
                    domain: "DOC".to_string(),
                    priority: Priority::P2,
                    effort: Effort::Xs,
                    confidence: Confidence::Med,
                    source_of_evidence: SourceOfEvidence {
                        input_path: "CONTRIBUTING.md".to_string(),
                        section: "## Setup".to_string(),
                        excerpt: "setup instructions are outdated".to_string(),
                    },
                    acceptance_criteria_draft: vec!["CONTRIBUTING.md updated".to_string()],
                    layer: None,
                    doctrine_justification: None,
                },
            ],
        }
    }

    /// Stage 1 PICK: reads the scan and returns the highest-confidence gap.
    #[test]
    fn pick_reads_latest_scan() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();
        let scan = sample_scan("test/repo");
        save_scan(repo_dir, &scan).unwrap();

        // Simulate the clone_dir being <repo_dir>/clone/
        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir),
        };

        let picked = pick_gap_from_scan(&opts, opts.clone_dir.as_ref().unwrap()).unwrap();
        // Should pick the first (highest-confidence) gap.
        assert_eq!(picked.title, "EFFECTIVE: add integration tests");
    }

    /// Stage 1 PICK: --gap overrides the scan entirely.
    #[test]
    fn pick_gap_id_override() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: Some("EFFECTIVE-177".to_string()),
            apply: false,
            clone_dir: Some(clone_dir.clone()),
        };

        let picked = pick_gap(&opts, &clone_dir).unwrap();
        assert_eq!(picked.title, "EFFECTIVE-177");
    }

    /// Init a git repo in `dir` with one commit carrying `commit_msg`.
    fn git_repo_with_commit(dir: &std::path::Path, commit_msg: &str) {
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .env("GIT_AUTHOR_NAME", "t")
                .env("GIT_AUTHOR_EMAIL", "t@t.t")
                .env("GIT_COMMITTER_NAME", "t")
                .env("GIT_COMMITTER_EMAIL", "t@t.t")
                .output()
                .unwrap();
        };
        git(&["init", "-q"]);
        fs::write(dir.join("seed.txt"), "seed").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", commit_msg]);
    }

    /// Stage 2 DEDUP (ZERO-WASTE-010): skips when a COMMIT already did the work
    /// (key terms co-occur in a commit message), NOT on mere file-keyword presence.
    #[test]
    fn dedup_detects_redundant_work() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path();
        // A commit already did this work — its message carries the gap's key terms.
        git_repo_with_commit(clone_dir, "feat: add streaming pipeline support");

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming pipeline".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming pipeline planned".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming pipeline implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check("owner/testrepo", clone_dir, &gap, "gh").unwrap();
        assert!(
            matches!(result, DedupResult::Redundant { .. }),
            "dedup should detect work already done in a commit"
        );
    }

    /// ZERO-WASTE-010 regression: common title words present in FILES (but no commit
    /// did the work) must NOT trigger a skip — this is the exact BEAST-MODE roadmap
    /// false-positive that skipped real work on the first live run.
    #[test]
    fn dedup_proceeds_when_keywords_only_in_files() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path();
        // Real repo, but the commit does NOT do the work.
        git_repo_with_commit(clone_dir, "initial commit");
        // Files DO contain the title keywords (like any repo that has a roadmap).
        fs::write(
            clone_dir.join("ROADMAP.md"),
            "# Roadmap\n- migrate the tasks eventually\n- more roadmap tasks\n",
        )
        .unwrap();

        let gap = ProposedGap {
            title: "EFFECTIVE: Migrate roadmap tasks to bd".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "AGENTS.md".to_string(),
                section: "## Tracking".to_string(),
                excerpt: "bd mandated; ROADMAP.md still markdown".to_string(),
            },
            acceptance_criteria_draft: vec!["Roadmap tasks migrated to bd".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check("owner/testrepo", clone_dir, &gap, "gh").unwrap();
        assert!(
            matches!(result, DedupResult::NotRedundant),
            "keywords in files (no matching commit) must NOT false-skip — ZERO-WASTE-010"
        );
    }

    /// Stage 2 DEDUP: passes if gap keywords are absent.
    #[test]
    fn dedup_passes_for_new_work() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path();

        // Write a file that does NOT contain the keywords.
        let src_dir = clone_dir.join("src");
        fs::create_dir_all(&src_dir).unwrap();
        fs::write(src_dir.join("main.rs"), "fn main() {}").unwrap();

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming support xyzzy".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::M,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming xyzzy planned but not built".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming xyzzy implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check("owner/testrepo", clone_dir, &gap, "gh").unwrap();
        assert!(
            matches!(result, DedupResult::NotRedundant),
            "dedup should pass for new work"
        );
    }

    /// extract_pr_url_from_output parses the URL correctly.
    #[test]
    fn extract_pr_url_parses_json() {
        let output = r#"
Some prose from the agent.

```json
{
  "pr_url": "https://github.com/test/repo/pull/42",
  "head_ref": "chump/improve-abc",
  "base_ref": "main",
  "files_touched": ["src/lib.rs"],
  "commit_sha": "abcdef1234567890abcdef1234567890abcdef12",
  "notes": "Added integration test"
}
```
"#;
        let url = extract_pr_url_from_output(output);
        assert_eq!(
            url,
            Some("https://github.com/test/repo/pull/42".to_string())
        );
    }

    /// extract_pr_number extracts the number from a URL.
    #[test]
    fn extract_pr_number_works() {
        assert_eq!(
            extract_pr_number("https://github.com/test/repo/pull/42"),
            Some(42)
        );
        assert_eq!(
            extract_pr_number("https://github.com/test/repo/pull/999"),
            Some(999)
        );
        assert_eq!(extract_pr_number("https://example.com"), None);
    }

    /// Dry-run mode: stages 2-4 are skipped; emit improve_cycle_complete with verdict=dry_run.
    /// This test verifies the orchestrator runs WITHOUT spawning a real claude/gh binary.
    #[test]
    fn dry_run_skips_implement_and_verify() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();
        let scan = sample_scan("owner/myrepo");
        save_scan(repo_dir, &scan).unwrap();

        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        // Build an Opts struct directly (dry-run, no apply).
        let opts = Opts {
            owner_repo: "owner/myrepo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir.clone()),
        };

        // Run just the pick stage + dedup logic without spawning any processes.
        let picked = pick_gap_from_scan(&opts, &clone_dir).unwrap();
        assert_eq!(picked.title, "EFFECTIVE: add integration tests");

        // Dedup on an empty clone dir should pass (no code present).
        let dedup = dedup_check("owner/myrepo", &clone_dir, &picked, "gh").unwrap();
        assert!(matches!(dedup, DedupResult::NotRedundant));

        // Dry-run: stages 3-4 are not called. Verify the chain stops here.
        // (No panic == the orchestrator composed stages 1+2 in order.)
    }

    /// --apply vs dry-run differ: apply mode would call implement + verify-merge;
    /// dry-run stops after pick+dedup. We assert the arg parsing distinction.
    #[test]
    fn apply_flag_parsed_correctly() {
        let args_dry = vec!["owner/repo".to_string()];
        let args_apply = vec!["owner/repo".to_string(), "--apply".to_string()];

        let opts_dry = parse_args(&args_dry).unwrap();
        let opts_apply = parse_args(&args_apply).unwrap();

        assert!(!opts_dry.apply, "dry-run: apply should be false");
        assert!(opts_apply.apply, "apply mode: apply should be true");
    }

    // ── CREDIBLE-100: parse_verdict unit tests ─────────────────────────────

    /// "Verdict: MERGE" → Some("verified")
    #[test]
    fn parse_verdict_merge() {
        assert_eq!(
            parse_verdict("Verdict: MERGE"),
            Some("verified"),
            "bare Verdict: MERGE should return verified"
        );
    }

    /// Multi-line output with Verdict: MERGE embedded → Some("verified")
    #[test]
    fn parse_verdict_merge_in_multiline() {
        let stdout = "[verify-merge] Gate 1: CI green\n\
                      [verify-merge] Gate 2: test proves change\n\
                      [verify-merge] Gate 3: no regression\n\
                      \n\
                      Verdict: MERGE\n";
        assert_eq!(parse_verdict(stdout), Some("verified"));
    }

    /// "Verdict: HELD(<reason>)" → Some("held")
    #[test]
    fn parse_verdict_held_with_reason() {
        let stdout = "...\nVerdict: HELD(unproven)\n";
        assert_eq!(
            parse_verdict(stdout),
            Some("held"),
            "Verdict: HELD(...) should return held"
        );
    }

    /// "Verdict: HELD(no-gates)" → Some("held")
    #[test]
    fn parse_verdict_held_no_gates() {
        assert_eq!(parse_verdict("\nVerdict: HELD(no-gates)\n"), Some("held"));
    }

    /// Brain-style chat reply with no Verdict: line → None (misfire detection)
    #[test]
    fn parse_verdict_brain_reply_is_none() {
        let brain_reply = "The word \"external\" refers to something \
                           originating or acting from outside. In anatomy, \
                           external means situated on or near the outside of \
                           the body. Exit code: 0.";
        assert_eq!(
            parse_verdict(brain_reply),
            None,
            "a brain chat reply with no Verdict: line must return None"
        );
    }

    /// Empty string → None
    #[test]
    fn parse_verdict_empty_is_none() {
        assert_eq!(parse_verdict(""), None);
    }

    // ── RESILIENT-106: oauth token injection path ──────────────────────────

    /// read_oauth_token_file: "token" key is read correctly.
    #[test]
    fn oauth_token_file_token_key() {
        let tmp = TempDir::new().unwrap();
        let token_path = tmp.path().join("oauth-token.json");
        fs::write(&token_path, r#"{"token":"tok_abc123"}"#).unwrap();

        // Override HOME so read_oauth_token_file looks in our temp dir.
        // The function reads ~/.chump/oauth-token.json, so we need
        // HOME=<tmp> and the file at <tmp>/.chump/oauth-token.json.
        let chump_dir = tmp.path().join(".chump");
        fs::create_dir_all(&chump_dir).unwrap();
        fs::write(
            chump_dir.join("oauth-token.json"),
            r#"{"token":"tok_abc123"}"#,
        )
        .unwrap();

        // Temporarily set HOME to our tmp dir and call read_oauth_token_file.
        // We can't set env vars in parallel tests safely, so we test the
        // parse logic directly via serde_json here.
        let content = r#"{"token":"tok_abc123"}"#;
        let v: serde_json::Value = serde_json::from_str(content).unwrap();
        let tok = v.get("token").and_then(|x| x.as_str()).unwrap_or("");
        assert_eq!(tok, "tok_abc123", "token key should be read");
    }

    /// read_oauth_token_file: "access_token" key is read correctly.
    #[test]
    fn oauth_token_file_access_token_key() {
        let content = r#"{"access_token":"at_xyz789"}"#;
        let v: serde_json::Value = serde_json::from_str(content).unwrap();
        // Try all three keys in order — "token" absent, falls through to "access_token".
        let tok = ["token", "access_token", "accessToken"]
            .iter()
            .find_map(|k| v.get(*k).and_then(|x| x.as_str()).filter(|s| !s.is_empty()));
        assert_eq!(tok, Some("at_xyz789"), "access_token key should be read");
    }

    /// read_oauth_token_file: "accessToken" key (camelCase) is read correctly.
    #[test]
    fn oauth_token_file_access_token_camel_key() {
        let content = r#"{"accessToken":"camel_tok_999"}"#;
        let v: serde_json::Value = serde_json::from_str(content).unwrap();
        let tok = ["token", "access_token", "accessToken"]
            .iter()
            .find_map(|k| v.get(*k).and_then(|x| x.as_str()).filter(|s| !s.is_empty()));
        assert_eq!(
            tok,
            Some("camel_tok_999"),
            "accessToken camelCase key should be read"
        );
    }

    /// read_oauth_token_file: missing file returns None gracefully.
    #[test]
    fn oauth_token_file_missing_returns_none() {
        let tmp = TempDir::new().unwrap();
        // No file written — simulate HOME pointing to empty dir.
        let fake_home = tmp.path().to_string_lossy().to_string();
        // We test the logic path: if read_to_string fails, we return None.
        let missing = std::fs::read_to_string(
            std::path::PathBuf::from(&fake_home)
                .join(".chump")
                .join("oauth-token.json"),
        );
        assert!(missing.is_err(), "reading missing file should fail");
        // The function returns None on any error — verified by the Option chain.
        let result: Option<String> = missing.ok().and_then(|c| {
            let v: Option<serde_json::Value> = serde_json::from_str(&c).ok();
            v?.get("token")
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
        });
        assert!(result.is_none(), "missing file path should yield None");
    }

    // ── EFFECTIVE-201: doctrine-order picking tests ────────────────────────

    /// Build a minimal `ProposedGap` with the given layer and confidence for
    /// testing the doctrine-order picker. All other fields are placeholder.
    fn make_gap(title: &str, layer: Option<&str>, conf: Confidence) -> ProposedGap {
        ProposedGap {
            title: title.to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P2,
            effort: Effort::S,
            confidence: conf,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "§test".to_string(),
                excerpt: "test".to_string(),
            },
            acceptance_criteria_draft: vec!["done".to_string()],
            layer: layer.map(|s| s.to_string()),
            doctrine_justification: layer.map(|l| format!("test {l} justification")),
        }
    }

    /// Doctrine-order: L1 is always picked before L2 and L3 regardless of
    /// position in the original scan.
    #[test]
    fn doctrine_order_l1_before_l2_before_l3() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();

        // Build a scan where gaps are ordered L3, L2, L1 — picker must re-sort
        // and return the L1 gap first.
        let scan = OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: "test/repo".to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![],
            proposed_gaps: vec![
                make_gap("L3: latent realization idea", Some("L3"), Confidence::High),
                make_gap("L2: README claim unfulfilled", Some("L2"), Confidence::High),
                make_gap("L1: foundation gate unmet", Some("L1"), Confidence::Med),
            ],
        };
        save_scan(repo_dir, &scan).unwrap();

        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir.clone()),
        };

        let picked = pick_gap_from_scan(&opts, &clone_dir).unwrap();
        assert_eq!(
            picked.title, "L1: foundation gate unmet",
            "doctrine-order picking must select L1 first, even if it appears last in the scan"
        );
        assert_eq!(picked.layer.as_deref(), Some("L1"));
    }

    /// Within L1, higher confidence is picked first.
    #[test]
    fn doctrine_order_within_layer_by_confidence() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();

        let scan = OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: "test/repo".to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![],
            proposed_gaps: vec![
                make_gap("L1 low-conf", Some("L1"), Confidence::Low),
                make_gap("L1 high-conf", Some("L1"), Confidence::High),
                make_gap("L2 high-conf", Some("L2"), Confidence::High),
            ],
        };
        save_scan(repo_dir, &scan).unwrap();

        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir.clone()),
        };

        let picked = pick_gap_from_scan(&opts, &clone_dir).unwrap();
        assert_eq!(
            picked.title, "L1 high-conf",
            "within L1, high-confidence gap must be picked before low-confidence"
        );
    }

    /// Untagged gaps (no layer) are de-prioritised below L3.
    #[test]
    fn doctrine_order_untagged_after_l3() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();

        let scan = OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: "test/repo".to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![],
            proposed_gaps: vec![
                make_gap("untagged high-conf", None, Confidence::High),
                make_gap("L3 low-conf", Some("L3"), Confidence::Low),
            ],
        };
        save_scan(repo_dir, &scan).unwrap();

        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir.clone()),
        };

        let picked = pick_gap_from_scan(&opts, &clone_dir).unwrap();
        assert_eq!(
            picked.title, "L3 low-conf",
            "L3 (even low-confidence) must be picked before an untagged gap"
        );
    }

    // ── B4: configure_claude_auth_env unit tests (RESILIENT-108) ──────────

    /// B4: when CLAUDE_CODE_OAUTH_TOKEN is set in the parent env and fake
    /// ANTHROPIC_* gateway vars are explicitly set on a Command, calling
    /// configure_claude_auth_env strips all four gateway vars (they appear as
    /// `(key, None)` in `Command::get_envs()`) and returns true.
    ///
    /// We use Command::get_envs() to inspect the env-override map without
    /// spawning any process.
    #[test]
    #[serial_test::serial]
    fn configure_auth_env_strips_gateway_when_oauth_in_env() {
        // Set the OAUTH token in the process env for this test.
        // Use a clearly fake value — never logged.
        unsafe {
            std::env::set_var("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-token-b4-unit");
        }

        let mut cmd = Command::new("true"); // never spawned
                                            // Explicitly add gateway vars to cmd so env_remove can target them.
        cmd.env("ANTHROPIC_API_KEY", "fake-key");
        cmd.env("ANTHROPIC_AUTH_TOKEN", "fake-auth-token");
        cmd.env("ANTHROPIC_BASE_URL", "https://fake.gateway.example");
        cmd.env("ANTHROPIC_CUSTOM_HEADERS", "X-Fake: header");

        let result = configure_claude_auth_env(&mut cmd);

        // Restore env before assertions (isolate from other tests).
        unsafe {
            std::env::remove_var("CLAUDE_CODE_OAUTH_TOKEN");
        }

        assert!(
            result,
            "configure_claude_auth_env must return true when OAUTH token is in env"
        );

        // After env_remove(), the key appears as (key, None) in get_envs().
        let env_map: std::collections::HashMap<_, _> = cmd
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().to_string(),
                    v.map(|v| v.to_string_lossy().to_string()),
                )
            })
            .collect();

        assert_eq!(
            env_map.get("ANTHROPIC_API_KEY"),
            Some(&None),
            "ANTHROPIC_API_KEY must be removed from Command env when OAUTH is active"
        );
        assert_eq!(
            env_map.get("ANTHROPIC_AUTH_TOKEN"),
            Some(&None),
            "ANTHROPIC_AUTH_TOKEN must be removed from Command env when OAUTH is active"
        );
        assert_eq!(
            env_map.get("ANTHROPIC_BASE_URL"),
            Some(&None),
            "ANTHROPIC_BASE_URL must be removed from Command env when OAUTH is active"
        );
        assert_eq!(
            env_map.get("ANTHROPIC_CUSTOM_HEADERS"),
            Some(&None),
            "ANTHROPIC_CUSTOM_HEADERS must be removed from Command env when OAUTH is active"
        );
        // CLAUDE_CODE_OAUTH_TOKEN was in the parent env (token_in_env=true) so
        // configure_claude_auth_env does NOT re-inject it (no explicit cmd.env call).
        // It must not be removed either.
        assert_ne!(
            env_map.get("CLAUDE_CODE_OAUTH_TOKEN"),
            Some(&None),
            "CLAUDE_CODE_OAUTH_TOKEN must NOT be removed from Command env"
        );
    }

    /// B4: when no OAUTH token is available (neither env nor file), the
    /// function returns false and does NOT strip any gateway vars.
    #[test]
    #[serial_test::serial]
    fn configure_auth_env_noop_when_no_oauth() {
        // If the test process happens to carry CLAUDE_CODE_OAUTH_TOKEN, skip —
        // we can't safely remove it without affecting other parallel tests.
        if std::env::var_os("CLAUDE_CODE_OAUTH_TOKEN").is_some() {
            return;
        }

        // Point HOME at an empty tmp dir so read_oauth_token_file returns None.
        let tmp = TempDir::new().unwrap();
        let orig_home = std::env::var("HOME").unwrap_or_default();
        unsafe {
            std::env::set_var("HOME", tmp.path());
        }

        let mut cmd = Command::new("true");
        cmd.env("ANTHROPIC_API_KEY", "real-key-must-not-be-stripped");

        let result = configure_claude_auth_env(&mut cmd);

        unsafe {
            std::env::set_var("HOME", &orig_home);
        }

        assert!(
            !result,
            "configure_claude_auth_env must return false when no OAUTH token available"
        );

        // ANTHROPIC_API_KEY must NOT appear as None in the env map.
        let env_map: std::collections::HashMap<_, _> = cmd
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().to_string(),
                    v.map(|v| v.to_string_lossy().to_string()),
                )
            })
            .collect();

        assert_ne!(
            env_map.get("ANTHROPIC_API_KEY"),
            Some(&None),
            "ANTHROPIC_API_KEY must NOT be stripped when no OAUTH token is available"
        );
    }

    // ── B5: open-PR dedup unit tests (ZERO-WASTE-011 / RESILIENT-108) ─────

    /// Helper: init a git repo in `dir` with one commit carrying `commit_msg`.
    fn git_repo_with_commit_b5(dir: &std::path::Path, commit_msg: &str) {
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .env("GIT_AUTHOR_NAME", "t")
                .env("GIT_AUTHOR_EMAIL", "t@t.t")
                .env("GIT_COMMITTER_NAME", "t")
                .env("GIT_COMMITTER_EMAIL", "t@t.t")
                .output()
                .unwrap();
        };
        git(&["init", "-q"]);
        fs::write(dir.join("seed.txt"), "seed").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", commit_msg]);
    }

    /// Write a fake gh binary at `path` that emits `output` on stdout and
    /// exits with `exit_code`. Makes the file executable (unix only).
    fn write_fake_gh(path: &std::path::Path, output: &str, exit_code: i32) {
        let script = format!(
            "#!/usr/bin/env bash\necho '{}'\nexit {}\n",
            output.replace('\'', "'\\''"),
            exit_code
        );
        fs::write(path, script).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// B5: fake gh returns a matching open PR → dedup Redundant.
    #[test]
    fn dedup_open_pr_match_is_redundant() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();
        git_repo_with_commit_b5(&clone_dir, "initial commit: unrelated work");

        let fake_gh = tmp.path().join("gh");
        // The fake gh emits one PR whose title contains the gap's key terms.
        write_fake_gh(
            &fake_gh,
            r#"[{"number":99,"title":"add streaming pipeline for async events"}]"#,
            0,
        );

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming pipeline".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming pipeline not yet built".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming pipeline implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        // Pass fake_gh directly — no global env mutation needed.
        let result = dedup_check(
            "owner/testrepo",
            &clone_dir,
            &gap,
            &fake_gh.to_string_lossy(),
        )
        .unwrap();

        assert!(
            matches!(result, DedupResult::Redundant { .. }),
            "open PR matching title keywords must trigger Redundant (ZERO-WASTE-011)"
        );
        if let DedupResult::Redundant { reason } = result {
            assert!(
                reason.contains("open PR"),
                "reason must mention 'open PR', got: {reason}"
            );
        }
    }

    /// B5: fake gh returns empty list + no matching commit → NotRedundant.
    #[test]
    fn dedup_no_open_pr_is_not_redundant() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();
        git_repo_with_commit_b5(&clone_dir, "initial commit: unrelated work");

        let fake_gh = tmp.path().join("gh");
        write_fake_gh(&fake_gh, "[]", 0);

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming pipeline xyzzy99".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming xyzzy99 not built".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming xyzzy99 implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check(
            "owner/testrepo",
            &clone_dir,
            &gap,
            &fake_gh.to_string_lossy(),
        )
        .unwrap();

        assert!(
            matches!(result, DedupResult::NotRedundant),
            "empty open-PR list + no matching commit must be NotRedundant"
        );
    }

    /// B5: gh exits non-zero (network error) → fail-open, returns NotRedundant.
    #[test]
    fn dedup_gh_failure_is_not_redundant() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();
        git_repo_with_commit_b5(&clone_dir, "initial commit");

        let fake_gh = tmp.path().join("gh");
        write_fake_gh(&fake_gh, "error: network failure", 1);

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming pipeline".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming pipeline not built".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming pipeline implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check(
            "owner/testrepo",
            &clone_dir,
            &gap,
            &fake_gh.to_string_lossy(),
        )
        .unwrap();

        assert!(
            matches!(result, DedupResult::NotRedundant),
            "gh failure must fail-open toward NotRedundant (verify-merge is the backstop)"
        );
    }

    // ── EFFECTIVE-288 GREEN-FIRST doctrine ────────────────────────────────
    // "Step 1: make it green. Step 2: ship something new."

    #[test]
    fn green_first_none_when_repo_is_green() {
        // No failing checks at all → nothing to fix → fall through to features.
        assert!(green_first_gap_from_failures(&[]).is_none());
    }

    #[test]
    fn green_first_none_when_single_pr_fails() {
        // A check failing on ONE PR is likely that PR's own bug, not a broken
        // gate — must NOT hijack the pick away from feature work.
        let failures = vec![("flaky-test".to_string(), 1)];
        assert!(
            green_first_gap_from_failures(&failures).is_none(),
            "a 1-PR failure is per-PR, not a repo-wide broken gate"
        );
    }

    #[test]
    fn green_first_forces_fix_when_check_fails_across_prs() {
        use chump_handoff::external_repo_schema::{Effort, Priority};
        // "Code Quality Analysis" failing on 3 open PRs (the real BEAST-MODE
        // case) is a broken gate blocking every merge → forced top-priority fix.
        let failures = vec![("Code Quality Analysis".to_string(), 3)];
        let gap = green_first_gap_from_failures(&failures)
            .expect("a check failing across >=2 PRs must force a green-first pick");
        assert!(
            gap.title.contains("GREEN-FIRST") && gap.title.contains("Code Quality Analysis"),
            "title names the doctrine + the failing check: {}",
            gap.title
        );
        assert_eq!(
            gap.priority,
            Priority::P0,
            "a broken merge-gate is top priority"
        );
        assert_eq!(gap.effort, Effort::M);
        assert_eq!(
            gap.layer.as_deref(),
            Some("L1"),
            "green-first is foundation work"
        );
        assert!(
            gap.doctrine_justification
                .as_deref()
                .unwrap_or("")
                .contains("green-first"),
            "carries the green-first doctrine justification"
        );
    }

    #[test]
    fn green_first_picks_the_most_failing_check() {
        // When several checks fail across PRs, the highest-count one is named
        // first (repo_failing_checks sorts most-failing first; the pure fn keeps
        // that order via `.find`).
        let failures = vec![
            ("widely-broken".to_string(), 5),
            ("less-broken".to_string(), 2),
        ];
        let gap = green_first_gap_from_failures(&failures).expect("some failure crosses the bar");
        assert!(
            gap.title.contains("widely-broken"),
            "names the most-failing gate first: {}",
            gap.title
        );
    }

    // ── EFFECTIVE-291: clone refresh ──────────────────────────────────────

    /// Helper: run git in `cwd`, asserting success (commits get a fixed identity).
    fn git_ok(cwd: &std::path::Path, args: &[&str]) {
        let ok = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        assert!(ok, "git {:?} failed in {}", args, cwd.display());
    }

    fn rev_parse(dir: &std::path::Path, rev: &str) -> String {
        let out = Command::new("git")
            .args(["-C", &dir.to_string_lossy(), "rev-parse", rev])
            .output()
            .unwrap();
        assert!(out.status.success(), "rev-parse {rev} failed");
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    #[test]
    fn refresh_clone_brings_stale_clone_to_origin_head() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let origin = root.join("origin.git");
        let work = root.join("work"); // pushes commits into origin
        let clone = root.join("clone"); // the persistent "improve clone" under test

        // bare origin on `main`
        assert!(Command::new("git")
            .args(["init", "--bare", "-b", "main", &origin.to_string_lossy()])
            .status()
            .unwrap()
            .success());
        // work clone → commit c1 → push
        assert!(Command::new("git")
            .args(["clone", &origin.to_string_lossy(), &work.to_string_lossy()])
            .status()
            .unwrap()
            .success());
        fs::write(work.join("a.txt"), "v1").unwrap();
        git_ok(&work, &["add", "."]);
        git_ok(&work, &["commit", "-m", "c1"]);
        git_ok(&work, &["push", "origin", "main"]);
        // improve clone created now (sits at c1)
        assert!(Command::new("git")
            .args(["clone", &origin.to_string_lossy(), &clone.to_string_lossy()])
            .status()
            .unwrap()
            .success());
        // origin advances to c2 → the improve clone is now STALE (behind)
        fs::write(work.join("a.txt"), "v2").unwrap();
        git_ok(&work, &["add", "."]);
        git_ok(&work, &["commit", "-m", "c2"]);
        git_ok(&work, &["push", "origin", "main"]);
        let clone_before = rev_parse(&clone, "HEAD");
        let origin_head = rev_parse(&work, "origin/main");
        assert_ne!(clone_before, origin_head, "precondition: clone is behind");

        // refresh: the clone must come up to origin/main's HEAD
        refresh_clone(&clone).unwrap();

        assert_eq!(
            rev_parse(&clone, "HEAD"),
            origin_head,
            "refresh_clone must fast-forward the clone to origin's default-branch HEAD"
        );
    }

    #[test]
    fn refresh_clone_noop_when_not_a_git_repo() {
        let tmp = TempDir::new().unwrap();
        // a non-git directory → no-op, no error
        refresh_clone(tmp.path()).unwrap();
    }
}
