use anyhow::Result;
use crate::{staleness, version, briefing, ambient_emit};

pub async fn run(args: &[String]) -> Result<()> {
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!(
            "chump {} ({} built {})",
            version::chump_version(),
            version::chump_build_sha(),
            version::chump_build_date(),
        );
        return Ok(());
    }

    if args.iter().any(|a| a == "--build-info") {
        let want_json = args.iter().any(|a| a == "--json");
        std::process::exit(staleness::run_build_info_cli(want_json));
    }

    if args.get(1).map(String::as_str) == Some("self-check-staleness") {
        let mut threshold_age_s: u64 = staleness::DEFAULT_THRESHOLD_AGE_S;
        let mut threshold_commits: u64 = staleness::DEFAULT_THRESHOLD_COMMITS;
        let mut want_json = false;
        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--threshold-age-s" => {
                    if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u64>().ok()) {
                        threshold_age_s = v;
                        i += 2;
                        continue;
                    }
                }
                "--threshold-commits" => {
                    if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u64>().ok()) {
                        threshold_commits = v;
                        i += 2;
                        continue;
                    }
                }
                "--json" => {
                    want_json = true;
                    i += 1;
                }
                "--help" | "-h" => {
                    println!("chump self-check-staleness — INFRA-2054 (META-114 cluster)");
                    return Ok(());
                }
                _ => { i += 1; }
            }
        }
        std::process::exit(staleness::run_self_check_staleness_cli(
            threshold_age_s,
            threshold_commits,
            want_json,
        ));
    }

    if let Some(pos) = args.iter().position(|a| a == "--briefing") {
        let gap_id = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if gap_id.is_empty() || gap_id.starts_with("--") {
            eprintln!("Usage: chump --briefing <GAP-ID> [--json]");
            std::process::exit(2);
        }
        let b = briefing::build_briefing(gap_id);
        if args.iter().any(|a| a == "--json") {
            println!("{}", briefing::render_json(&b));
        } else {
            print!("{}", briefing::render_markdown(&b));
        }
        return Ok(());
    }

    if args.get(1).map(String::as_str) == Some("ambient")
        && args.get(2).map(String::as_str) == Some("emit")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!("Usage: chump ambient emit <kind> [options]");
            return Ok(());
        }
        let parsed = ambient_emit::EmitArgs::from_argv(&args[1..])?;
        let path = ambient_emit::emit(&parsed)?;
        eprintln!("[ambient] wrote {} ({})", parsed.kind, path.display());
        return Ok(());
    }

    Ok(())
}
