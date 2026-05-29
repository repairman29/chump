//! `chump-policy` — auto-merge policy CLI (INFRA-1489).
//!
//! Subcommands:
//!   show     — print effective + per-scope policy as JSON
//!   set      — write per-scope policy fields to disk
//!   record-review — increment the operator's reviewed_pr_count by one
//!   check    — exit 0 if auto-merge allowed, exit 1 with reason otherwise
//!
//! Storage:
//!   ~/.chump/auto_merge_policy.toml          (operator scope)
//!   <repo>/.chump/auto_merge_policy.toml     (repo scope)
//!   <repo>/.chump/fleet-policy.toml          (fleet scope; rarely edited)
//!
//! Examples:
//!   chump-policy show
//!   chump-policy show --json
//!   chump-policy set --scope operator --require-human-review true
//!   chump-policy set --scope operator --trust-threshold 50
//!   chump-policy set --scope repo --enabled false
//!   chump-policy record-review
//!   chump-policy check
//!
//! Note: the bot-merge integration that calls `chump-policy check` lives
//! in scripts/coord/bot-merge.sh and is a follow-up gap so this PR can
//! land without colliding with the active INFRA-2119 lease on bot-merge.

use chump_policy::{Policy, PolicyChain, Scope};
use std::path::PathBuf;

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() < 2 {
        print_usage();
        std::process::exit(2);
    }
    let cmd = argv[1].as_str();
    let rest: Vec<&str> = argv[2..].iter().map(|s| s.as_str()).collect();
    let result = match cmd {
        "show" => cmd_show(&rest),
        "set" => cmd_set(&rest),
        "record-review" => cmd_record_review(&rest),
        "check" => cmd_check(&rest),
        "-h" | "--help" | "help" => {
            print_usage();
            Ok(())
        }
        other => {
            eprintln!("chump-policy: unknown subcommand: {other}");
            print_usage();
            std::process::exit(2);
        }
    };
    if let Err(e) = result {
        eprintln!("chump-policy: {e:#}");
        std::process::exit(1);
    }
}

fn print_usage() {
    eprintln!(
        "Usage: chump-policy <subcommand> [flags]\n\n\
         Subcommands:\n  \
           show [--json]                                        — print effective + per-scope policy\n  \
           set --scope <fleet|operator|repo> [policy fields]    — write policy fields to that scope\n  \
                --enabled <bool>\n  \
                --require-human-review <bool>\n  \
                --trust-threshold <N>\n  \
           record-review                                        — increment operator reviewed_pr_count by 1\n  \
           check                                                — exit 0 if auto-merge allowed, 1 otherwise\n\n\
         Storage paths (resolved via $CHUMP_REPO and $HOME):\n  \
           operator: $HOME/.chump/auto_merge_policy.toml\n  \
           repo:     $CHUMP_REPO/.chump/auto_merge_policy.toml\n  \
           fleet:    $CHUMP_REPO/.chump/fleet-policy.toml"
    );
}

fn repo_root() -> PathBuf {
    std::env::var("CHUMP_REPO")
        .map(PathBuf::from)
        .ok()
        .filter(|p| p.is_dir())
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."))
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

fn cmd_show(args: &[&str]) -> anyhow::Result<()> {
    let json = args.contains(&"--json");
    let chain = PolicyChain::load(&repo_root(), &home_dir())?;
    let (eff, contributing) = chain.effective();

    if json {
        // Minimal hand-rolled JSON to avoid pulling serde_json into this
        // CLI (kept dep-light: serde + toml + anyhow only).
        let scopes: Vec<String> = contributing
            .iter()
            .map(|s| format!("\"{}\"", s.as_str()))
            .collect();
        println!(
            "{{\
\"effective\":{{\"enabled\":{},\"require_human_review\":{},\
\"trust_threshold_pr_count\":{},\"reviewed_pr_count\":{},\
\"auto_merge_allowed\":{},\"block_reason\":{}}},\
\"contributing_scopes\":[{}],\
\"fleet\":{},\"operator\":{},\"repo\":{}\
}}",
            eff.enabled,
            eff.require_human_review,
            eff.trust_threshold_pr_count,
            eff.reviewed_pr_count,
            eff.is_auto_merge_allowed(),
            match eff.block_reason() {
                Some(r) => format!("\"{}\"", r.replace('"', "\\\"")),
                None => "null".into(),
            },
            scopes.join(","),
            policy_to_json(&chain.fleet),
            policy_to_json(&chain.operator),
            policy_to_json(&chain.repo),
        );
    } else {
        println!("Effective auto-merge policy:");
        println!("  enabled:                {}", eff.enabled);
        println!("  require_human_review:   {}", eff.require_human_review);
        println!(
            "  trust_threshold:        {} (reviewed: {})",
            eff.trust_threshold_pr_count, eff.reviewed_pr_count
        );
        if let Some(reason) = eff.block_reason() {
            println!("  status:                 BLOCKED — {}", reason);
            let scopes_str: Vec<&str> = contributing.iter().map(|s| s.as_str()).collect();
            println!("  blocked_by:             [{}]", scopes_str.join(", "));
        } else {
            println!("  status:                 ALLOWED");
        }
        println!();
        println!("Per-scope detail:");
        print_scope("fleet", &chain.fleet);
        print_scope("operator", &chain.operator);
        print_scope("repo", &chain.repo);
    }
    Ok(())
}

fn print_scope(label: &str, p: &Policy) {
    println!(
        "  {:9} enabled={} require_review={} threshold={} reviewed={}",
        format!("{}:", label),
        p.enabled,
        p.require_human_review,
        p.trust_threshold_pr_count,
        p.reviewed_pr_count,
    );
}

fn policy_to_json(p: &Policy) -> String {
    format!(
        "{{\"enabled\":{},\"require_human_review\":{},\
\"trust_threshold_pr_count\":{},\"reviewed_pr_count\":{}}}",
        p.enabled, p.require_human_review, p.trust_threshold_pr_count, p.reviewed_pr_count,
    )
}

fn cmd_set(args: &[&str]) -> anyhow::Result<()> {
    let mut scope: Option<Scope> = None;
    let mut enabled: Option<bool> = None;
    let mut require_review: Option<bool> = None;
    let mut threshold: Option<u32> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i] {
            "--scope" => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow::anyhow!("--scope needs a value"))?;
                scope = Some(match *v {
                    "fleet" => Scope::Fleet,
                    "operator" => Scope::Operator,
                    "repo" => Scope::Repo,
                    other => {
                        anyhow::bail!(
                            "invalid --scope value: {other}; expected fleet|operator|repo"
                        )
                    }
                });
                i += 2;
            }
            "--enabled" => {
                enabled = Some(parse_bool(args.get(i + 1))?);
                i += 2;
            }
            "--require-human-review" => {
                require_review = Some(parse_bool(args.get(i + 1))?);
                i += 2;
            }
            "--trust-threshold" => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow::anyhow!("--trust-threshold needs a value"))?;
                threshold = Some(v.parse::<u32>()?);
                i += 2;
            }
            other => anyhow::bail!("unknown flag: {other}"),
        }
    }
    let scope =
        scope.ok_or_else(|| anyhow::anyhow!("set: --scope <fleet|operator|repo> is required"))?;
    let path = scope_path(scope);

    // Load existing then overlay only the fields the operator changed.
    let mut p = Policy::from_file(&path)?;
    if let Some(v) = enabled {
        p.enabled = v;
    }
    if let Some(v) = require_review {
        p.require_human_review = v;
    }
    if let Some(v) = threshold {
        p.trust_threshold_pr_count = v;
    }
    p.save_to_file(&path)?;
    println!(
        "[chump-policy] wrote {} (scope={})",
        path.display(),
        scope.as_str()
    );
    Ok(())
}

fn parse_bool(v: Option<&&str>) -> anyhow::Result<bool> {
    let s = v.ok_or_else(|| anyhow::anyhow!("bool flag needs a value"))?;
    Ok(match s.to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => true,
        "false" | "0" | "no" | "off" => false,
        other => anyhow::bail!("invalid bool: {other}; expected true|false"),
    })
}

fn cmd_record_review(_args: &[&str]) -> anyhow::Result<()> {
    let path = scope_path(Scope::Operator);
    let mut p = Policy::from_file(&path)?;
    let before = p.reviewed_pr_count;
    p.record_human_review();
    p.save_to_file(&path)?;
    println!(
        "[chump-policy] reviewed_pr_count: {} → {} ({})",
        before,
        p.reviewed_pr_count,
        path.display()
    );
    Ok(())
}

fn cmd_check(_args: &[&str]) -> anyhow::Result<()> {
    let chain = PolicyChain::load(&repo_root(), &home_dir())?;
    let ts = chrono_like_now();
    match chain.require_auto_merge_allowed() {
        Ok(()) => {
            println!(
                "{{\"ts\":\"{ts}\",\"kind\":\"auto_merge_policy_evaluated\",\
\"outcome\":\"allowed\"}}",
            );
            std::process::exit(0);
        }
        Err(blocked) => {
            let scopes: Vec<String> = blocked
                .contributing
                .iter()
                .map(|s| format!("\"{}\"", s.as_str()))
                .collect();
            println!(
                "{{\"ts\":\"{ts}\",\"kind\":\"auto_merge_policy_blocked\",\
\"reason\":\"{}\",\"contributing\":[{}]}}",
                blocked.reason.replace('"', "\\\""),
                scopes.join(",")
            );
            std::process::exit(1);
        }
    }
}

fn scope_path(scope: Scope) -> PathBuf {
    match scope {
        Scope::Fleet => repo_root().join(".chump").join("fleet-policy.toml"),
        Scope::Operator => home_dir().join(".chump").join("auto_merge_policy.toml"),
        Scope::Repo => repo_root().join(".chump").join("auto_merge_policy.toml"),
    }
}

fn chrono_like_now() -> String {
    // Avoid pulling chrono just for this single timestamp. SystemTime
    // since epoch + handcrafted ISO-8601 keeps the crate dep-light. The
    // bot-merge integration script can rebuild a richer timestamp if
    // needed; for the ambient-emit we just need monotonic + ISO-shape.
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Days since 1970-01-01 (Thu). Compute Y/M/D via the standard
    // 400-year-cycle algorithm.
    let days = (secs / 86_400) as i64;
    let (y, m, d) = days_to_ymd(days);
    let rem = secs % 86_400;
    let h = (rem / 3600) as u32;
    let mi = ((rem % 3600) / 60) as u32;
    let s = (rem % 60) as u32;
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, h, mi, s)
}

/// Days-from-epoch → (year, month, day). Standard Zeller-adjacent walk.
fn days_to_ymd(mut days: i64) -> (i32, u32, u32) {
    // Shift to start of 0000-03-01 (Howard Hinnant's algorithm makes the
    // year start in March so the leap day is at the end and indexing
    // is uniform).
    days += 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let doe = (days - era * 146_097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i32 + (era * 400) as i32;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}
