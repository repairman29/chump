//! `chump-plan` — standalone binary surface for chump-planner v0.1.
//!
//! The same logic is also reachable as `chump plan` via the main `chump`
//! binary subcommand (see src/main.rs in the workspace root). This standalone
//! binary exists so the crate is independently runnable and so future
//! consumers (Mabel, ChumpMenu, the heartbeat) can shell out without
//! pulling in the entire chump CLI.

use anyhow::{Context, Result};
use chump_planner::{
    build_plan, collect_reconcile, load_gaps_dir,
    output::{json as out_json, table, Format},
    score::TelemetryInputs,
    DependencyGraph, PlanRequest, Weights,
};
use clap::Parser;
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(
    name = "chump-plan",
    about = "Rank the gap backlog and recommend the next N to dispatch.",
    version
)]
struct Args {
    /// Path to the gaps directory (default: docs/gaps).
    #[arg(long, default_value = "docs/gaps")]
    gaps: PathBuf,

    /// Plan for N concurrent agents.
    #[arg(long, default_value_t = 5)]
    agents: usize,

    /// Restrict to a single domain (e.g. INFRA, CREDIBLE).
    #[arg(long)]
    pillar: Option<String>,

    /// Skip gaps larger than this effort (xs/s/m/l/xl).
    #[arg(long)]
    max_effort: Option<String>,

    /// Disable the pillar-share cap.
    #[arg(long)]
    no_pillar_cap: bool,

    /// Include gaps with open prerequisites in the rank (default: skip).
    #[arg(long)]
    include_blocked: bool,

    /// Output format. v0.1 supports: table.
    #[arg(long, default_value = "table")]
    format: String,

    /// Reconciliation gate threshold. Exits non-zero when
    /// status:open+closed_pr backlog exceeds this count.
    #[arg(long, default_value_t = 10)]
    reconcile_threshold: usize,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let format: Format = args.format.parse()?;

    let gaps = load_gaps_dir(&args.gaps)
        .with_context(|| format!("loading gaps from {}", args.gaps.display()))?;

    let graph = DependencyGraph::build(&gaps);

    if let Err(cycle) = graph.topo_order() {
        // Cycle is informational at v0.1 — surface to stderr, do not crash.
        eprintln!(
            "warning: dependency cycle detected ({} members, identity {}): {:?}",
            cycle.gaps.len(),
            &cycle.identity()[..16],
            cycle.gaps.iter().map(|g| g.0.as_str()).collect::<Vec<_>>(),
        );
    }

    let pillar_filter = match args.pillar.as_deref() {
        Some(s) => Some(
            <chump_planner::Domain as std::str::FromStr>::from_str(s)
                .with_context(|| format!("invalid --pillar {s}"))?,
        ),
        None => None,
    };
    let max_effort = match args.max_effort.as_deref() {
        Some(s) => Some(
            <chump_planner::Effort as std::str::FromStr>::from_str(s)
                .with_context(|| format!("invalid --max-effort {s}"))?,
        ),
        None => None,
    };

    let req = PlanRequest {
        agents: args.agents,
        pillar_filter,
        max_effort,
        respect_pillar_cap: !args.no_pillar_cap,
        include_blocked: args.include_blocked,
    };

    let weights = Weights::default();
    let telemetry = TelemetryInputs::default();
    let today = chrono::Utc::now().date_naive();

    let plan = build_plan(&gaps, &graph, &req, &telemetry, today, &weights);
    let reconcile = collect_reconcile(&gaps);

    match format {
        Format::Table => {
            let out = table::render(&plan, &reconcile);
            print!("{out}");
        }
        Format::Json => {
            // INFRA-1257: stable JSON for the fleet picker. Writes the same
            // ranking the table would render, plus generation metadata.
            let stdout = std::io::stdout();
            let mut handle = stdout.lock();
            out_json::render_json(&plan, &weights, &mut handle)
                .context("rendering --format json")?;
        }
    }

    if reconcile.breaches(args.reconcile_threshold) {
        eprintln!(
            "error: reconciliation backlog {} exceeds threshold {} — run scripts/coord/gap-doctor-reconcile.py",
            reconcile.count(),
            args.reconcile_threshold
        );
        std::process::exit(2);
    }

    Ok(())
}
