//! `chump-gap-enricher` — EFFECTIVE-446 standalone CLI for the proactive
//! gap-spec enricher (sibling of `chump-gap-architect`).
//!
//! Turns THIN open gaps (no file pointer, vague/TODO AC, thin description) into
//! CONCRETE, file-pointed specs the cheap DeepSeek-v4-flash floor can ship — by
//! querying Almanac for `file:line` and calling a capable model ONCE to rewrite
//! the EXISTING gap in place (never manufacturing new gaps).
//!
//! ## Usage
//!
//! ```text
//! chump-gap-enricher <GAP-ID> [--apply] [--preview] [--dry-run] [--json]
//!                             [--force] [--repo <name>] [--repo-root <path>]
//! chump-gap-enricher --scan [--limit N] [--apply] [--json]   # enrich the thinnest open gaps
//! ```
//!
//! Modes (default `--preview`):
//!   --dry-run   detect + Almanac + build prompt only (no LLM call, no write)
//!   --preview   detect + Almanac + LLM; parse spec but do NOT write it back
//!   --apply     full pipeline: also write the enriched spec back to the gap
//!
//! Boundaries (both mockable / host-agnostic):
//!   CHUMP_ALMANAC_BIN     almanac binary (default `almanac`)
//!   CHUMP_ENRICH_LLM_CMD  space-split argv for the capable model (default
//!                         `chump llm-complete --max-tokens 1200`); point at a
//!                         curl-to-OpenRouter wrapper to pin `deepseek-v4-pro`.

use chump_gap_store::maintenance::enricher::{
    classify_thinness, CliAlmanacClient, CommandLlmClient, EnrichMode, Enricher,
};
use chump_gap_store::maintenance::resolve_repo_root;
use chump_gap_store::GapStore;

fn usage() -> ! {
    eprintln!(
        "Usage: chump-gap-enricher <GAP-ID> [--apply|--preview|--dry-run] [--json] [--force]\n\
         \x20      [--repo <almanac-repo-name>] [--repo-root <path>]\n\
         \x20      chump-gap-enricher --scan [--limit N] [--apply] [--json]\n\
         \n\
         Enrich a THIN gap spec into a concrete, file-pointed one (EFFECTIVE-446).\n\
         Default mode is --preview (LLM call, no write). --apply writes back in place."
    );
    std::process::exit(2);
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 || args.iter().any(|a| a == "-h" || a == "--help") {
        usage();
    }

    let json = args.iter().any(|a| a == "--json");
    let force = args.iter().any(|a| a == "--force");
    let scan = args.iter().any(|a| a == "--scan");
    let mode = if args.iter().any(|a| a == "--apply") {
        EnrichMode::Apply
    } else if args.iter().any(|a| a == "--dry-run") {
        EnrichMode::DryRun
    } else {
        EnrichMode::Preview
    };

    let flag_val = |name: &str| -> Option<String> {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };

    let repo_root = match flag_val("--repo-root") {
        Some(p) => std::path::PathBuf::from(p),
        None => resolve_repo_root().unwrap_or_else(|_| std::path::PathBuf::from(".")),
    };
    // Almanac repo name defaults to the repo-root's directory basename.
    let repo_name = flag_val("--repo").unwrap_or_else(|| {
        repo_root
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "chump".to_string())
    });

    let almanac = CliAlmanacClient::new(repo_name.clone());
    let llm = CommandLlmClient::from_env();
    let mut enricher = Enricher::new(&repo_root, almanac, llm);
    enricher.force = force;

    // --scan: pick the thinnest open gaps and enrich each.
    if scan {
        let limit: usize = flag_val("--limit")
            .and_then(|s| s.parse().ok())
            .unwrap_or(5);
        let store = match GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump-gap-enricher: open store: {e}");
                std::process::exit(1);
            }
        };
        let open = store.list(Some("open")).unwrap_or_default();
        // Rank by thin-signal count (thinnest first) so the enrichment budget
        // hits the gaps the cheap floor is most likely to spin on.
        let mut thin: Vec<(usize, String)> = open
            .iter()
            .map(|g| (classify_thinness(g).reasons.len(), g.id.clone()))
            .filter(|(n, _)| *n > 0)
            .collect();
        thin.sort_by_key(|(n, _)| std::cmp::Reverse(*n));
        thin.truncate(limit);

        let mut results = Vec::new();
        for (_, id) in &thin {
            match enricher.enrich(id, mode).await {
                Ok(o) => {
                    eprintln!(
                        "[{}] thin={} hits={} applied={} {}",
                        o.gap_id,
                        o.thinness.tags(),
                        o.hits.len(),
                        o.applied,
                        o.skipped_reason.as_deref().unwrap_or("")
                    );
                    results.push(o);
                }
                Err(e) => eprintln!("[{id}] enrich error: {e}"),
            }
        }
        if json {
            print_json(&results);
        }
        return;
    }

    let gap_id = args
        .iter()
        .skip(1)
        .find(|a| !a.starts_with('-'))
        .cloned()
        .unwrap_or_else(|| usage());

    match enricher.enrich(&gap_id, mode).await {
        Ok(o) => {
            if mode == EnrichMode::DryRun {
                println!("{}", o.prompt);
                eprintln!(
                    "\n[{}] thin={} almanac_hits={} (dry-run: no LLM call)",
                    o.gap_id,
                    o.thinness.tags(),
                    o.hits.len()
                );
            } else if json {
                print_json(std::slice::from_ref(&o));
            } else {
                eprintln!(
                    "[{}] thin={} hits={} applied={} {}",
                    o.gap_id,
                    o.thinness.tags(),
                    o.hits.len(),
                    o.applied,
                    o.skipped_reason.as_deref().unwrap_or("")
                );
                if let Some(spec) = &o.spec {
                    eprintln!("  target_files: {:?}", spec.target_files);
                    eprintln!("  change_intent: {}", spec.change_intent);
                    for (i, ac) in spec.acceptance_criteria.iter().enumerate() {
                        eprintln!("  AC[{i}]: {ac}");
                    }
                }
            }
        }
        Err(e) => {
            eprintln!("chump-gap-enricher: {e}");
            std::process::exit(1);
        }
    }
}

fn print_json(outcomes: &[chump_gap_store::maintenance::enricher::EnrichOutcome]) {
    let arr: Vec<serde_json::Value> = outcomes
        .iter()
        .map(|o| {
            serde_json::json!({
                "gap_id": o.gap_id,
                "thin_reasons": o.thinness.reasons.iter().map(|r| r.tag()).collect::<Vec<_>>(),
                "almanac_hits": o.hits.iter().map(|h| h.citation.clone()).collect::<Vec<_>>(),
                "applied": o.applied,
                "skipped_reason": o.skipped_reason,
                "spec": o.spec.as_ref().map(|s| serde_json::json!({
                    "target_files": s.target_files,
                    "change_intent": s.change_intent,
                    "acceptance_criteria": s.acceptance_criteria,
                })),
            })
        })
        .collect();
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({ "enriched": arr }))
            .unwrap_or_else(|_| "{}".to_string())
    );
}
