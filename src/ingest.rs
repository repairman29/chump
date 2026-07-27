//! `chump ingest <repo-path>` — INFRA-1780 (INFRA-1746 phase 1a).
//!
//! Phase 1a scope, deliberately narrow: validate that the target is a
//! directory containing `.git`, and emit observability events. **No
//! filesystem mutation, git operation, or network call happens in this
//! phase** — that holds regardless of `--confirm-mutations`, which is
//! accepted here only so later phases can add it without a flag-parsing
//! migration. Later phases (1b+) do the actual scanning/writing and make
//! LLM/API calls, which is why the failure taxonomy already carries a
//! `transient` field even though every failure class in this phase is
//! permanent.

use std::path::Path;
use std::time::Instant;

const DEFAULT_BUDGET_USD: f64 = 10.0;

struct Opts {
    repo_path: String,
    budget_usd_raw: String,
    #[allow(dead_code)] // accepted for forward-compat; unused until later phases write.
    confirm_mutations: bool,
}

enum ParseOutcome {
    Ok(Opts),
    Help,
    UsageError(String),
}

/// `chump ingest` subcommand entry point. `args` is everything after `ingest`.
pub fn run(args: &[String]) -> i32 {
    match parse_args(args) {
        ParseOutcome::Help => {
            print_usage();
            0
        }
        ParseOutcome::UsageError(msg) => {
            eprintln!("chump ingest: {msg}");
            print_usage();
            2
        }
        ParseOutcome::Ok(opts) => run_validated(&opts),
    }
}

fn parse_args(args: &[String]) -> ParseOutcome {
    let mut repo_path: Option<String> = None;
    let mut budget_usd_raw = DEFAULT_BUDGET_USD.to_string();
    let mut confirm_mutations = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => return ParseOutcome::Help,
            "--confirm-mutations" => confirm_mutations = true,
            "--budget-usd" => {
                i += 1;
                match args.get(i) {
                    Some(v) => budget_usd_raw = v.clone(),
                    None => {
                        return ParseOutcome::UsageError("--budget-usd requires a value".into())
                    }
                }
            }
            a if a.starts_with("--budget-usd=") => {
                budget_usd_raw = a.trim_start_matches("--budget-usd=").to_string();
            }
            a if !a.starts_with('-') => {
                if repo_path.is_some() {
                    return ParseOutcome::UsageError(format!("unexpected extra argument: {a}"));
                }
                repo_path = Some(a.to_string());
            }
            a => return ParseOutcome::UsageError(format!("unknown flag: {a}")),
        }
        i += 1;
    }
    match repo_path {
        Some(p) => ParseOutcome::Ok(Opts {
            repo_path: p,
            budget_usd_raw,
            confirm_mutations,
        }),
        None => ParseOutcome::UsageError(
            "missing required argument <repo-path>\nUsage: chump ingest <repo-path> [--budget-usd N] [--confirm-mutations]".into(),
        ),
    }
}

fn print_usage() {
    println!("Usage: chump ingest <repo-path> [options]");
    println!();
    println!("Phase 1a (INFRA-1780): validates <repo-path> is a directory containing");
    println!("a .git subdirectory. Read-only — no filesystem mutation, git operation,");
    println!("or network call is performed, regardless of --confirm-mutations. Later");
    println!("phases of INFRA-1746 add the actual ingest work.");
    println!();
    println!("Options:");
    println!("  --budget-usd N       Cost ceiling for downstream phases (default: 10.0)");
    println!("  --confirm-mutations  Accepted for forward-compat; no-op in phase 1a");
}

fn run_validated(opts: &Opts) -> i32 {
    let start = Instant::now();
    emit_ingest_initiated(&opts.repo_path, &opts.budget_usd_raw);

    let budget_usd = match opts.budget_usd_raw.parse::<f64>() {
        Ok(v) if v.is_finite() && v > 0.0 => v,
        _ => {
            let elapsed_ms = start.elapsed().as_millis();
            let error = format!(
                "--budget-usd must be a positive number, got '{}'",
                opts.budget_usd_raw
            );
            emit_ingest_failed(&opts.repo_path, "invalid_budget", false, elapsed_ms, &error);
            eprintln!("chump ingest: {error}");
            return 1;
        }
    };

    let path = Path::new(&opts.repo_path);
    if !path.exists() {
        let elapsed_ms = start.elapsed().as_millis();
        let error = format!("path does not exist: {}", opts.repo_path);
        emit_ingest_failed(&opts.repo_path, "path_not_found", false, elapsed_ms, &error);
        eprintln!("chump ingest: {error}");
        return 1;
    }
    if !path.is_dir() || !path.join(".git").exists() {
        let elapsed_ms = start.elapsed().as_millis();
        let error = format!(
            "path is not a git repository (expected a directory containing .git): {}",
            opts.repo_path
        );
        emit_ingest_failed(&opts.repo_path, "not_a_git_repo", false, elapsed_ms, &error);
        eprintln!("chump ingest: {error}");
        return 1;
    }

    let elapsed_ms = start.elapsed().as_millis();
    emit_ingest_validated(&opts.repo_path, elapsed_ms);
    println!(
        "chump ingest: {} is a valid git repository (phase 1a — read-only, no mutation performed; budget=${budget_usd:.2})",
        opts.repo_path
    );
    0
}

fn emit_ingest_initiated(repo_path: &str, budget_usd_raw: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_initiated".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("repo_path".to_string(), repo_path.to_string()),
            ("budget_usd".to_string(), budget_usd_raw.to_string()),
        ],
        ..Default::default()
    });
}

fn emit_ingest_validated(repo_path: &str, elapsed_ms: u128) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_validated".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("repo_path".to_string(), repo_path.to_string()),
            ("cost_usd_cents".to_string(), "0".to_string()),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
        ],
        ..Default::default()
    });
}

fn emit_ingest_failed(
    repo_path: &str,
    failure_class: &str,
    transient: bool,
    elapsed_ms: u128,
    error: &str,
) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_failed".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("repo_path".to_string(), repo_path.to_string()),
            ("failure_class".to_string(), failure_class.to_string()),
            ("transient".to_string(), transient.to_string()),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
            ("error".to_string(), error.to_string()),
        ],
        ..Default::default()
    });
}
