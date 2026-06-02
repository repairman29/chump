//! INFRA-2399: `chump add-env-var` — author-time helper to register a new env var
//! in the correct tier registry so CI env-var-coverage gates don't fire on the
//! NEXT PR (innocent bystander pattern).
//!
//! Usage:
//!   chump add-env-var <NAME> --tier 1|2|3 [--gap-id <ID>]
//!
//! Tier semantics:
//!   1 → operator-tunable: adds to .env.example (commented-out template line)
//!   2 → debug/advanced: adds to scripts/ci/env-vars-internal.txt (Tier 2 section)
//!   3 → system/runtime: adds to scripts/ci/env-vars-internal.txt (Tier 3 section)
//!
//! CRITICAL: the env-var-coverage audit parses each line of env-vars-internal.txt
//! as a var name (whole line). Comments MUST appear on separate lines ABOVE the
//! var name. Never embed inline comments on the var line.
//!
//! If --gap-id is provided, a comment line `# gap: <ID>` is inserted immediately
//! above the var name in the registry file.

use std::io::Write;
use std::path::{Path, PathBuf};

/// Locate repo root by walking up to find workspace Cargo.toml.
fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(c) = std::fs::read_to_string(&cargo) {
                if c.contains("[workspace]") {
                    return dir;
                }
            }
        }
        if !dir.pop() {
            break;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Add var to .env.example (tier 1): appends a commented-out template line.
fn add_to_env_example(root: &Path, name: &str, gap_id: Option<&str>) -> anyhow::Result<()> {
    let path = root.join(".env.example");
    let existing = std::fs::read_to_string(&path).unwrap_or_default();

    // Idempotency: if var already present, skip.
    for line in existing.lines() {
        let stripped = line.trim_start_matches('#').trim();
        if stripped.starts_with(name) && stripped[name.len()..].trim_start().starts_with('=') {
            println!("[add-env-var] {name} already present in .env.example — skipping");
            return Ok(());
        }
    }

    let mut f = std::fs::OpenOptions::new().append(true).open(&path)?;

    writeln!(f)?;
    if let Some(id) = gap_id {
        writeln!(f, "# gap: {id}")?;
    }
    writeln!(f, "# {name}=")?;
    println!("[add-env-var] appended {name} to .env.example");
    Ok(())
}

/// Section marker strings in env-vars-internal.txt for tier 2 and tier 3.
const TIER2_HEADER: &str = "# ── Tier 2";
const TIER3_HEADER: &str = "# ── Tier 3";

/// Add var to scripts/ci/env-vars-internal.txt in the correct tier section.
/// CRITICAL: var name on its own line; gap comment (if any) on the line ABOVE.
fn add_to_internal(root: &Path, name: &str, tier: u8, gap_id: Option<&str>) -> anyhow::Result<()> {
    let path = root.join("scripts/ci/env-vars-internal.txt");
    let content = std::fs::read_to_string(&path)?;

    // Idempotency: if bare var name already exists on its own line, skip.
    for line in content.lines() {
        if line.trim() == name {
            println!("[add-env-var] {name} already in env-vars-internal.txt — skipping");
            return Ok(());
        }
    }

    // Find insertion point: end of the matching tier section.
    // Strategy: scan lines, find the tier header, then find the next blank
    // line or next section header after it — insert before that.
    let target_header = if tier == 2 {
        TIER2_HEADER
    } else {
        TIER3_HEADER
    };

    let lines: Vec<&str> = content.lines().collect();
    let mut insert_at: Option<usize> = None;

    let mut in_target = false;
    for (i, line) in lines.iter().enumerate() {
        if line.starts_with(target_header) {
            in_target = true;
            continue;
        }
        if in_target {
            // Next section header (starts with # ──) or end-of-file.
            if line.starts_with("# ──") || line.starts_with("# ──") {
                insert_at = Some(i);
                break;
            }
        }
    }

    let insert_idx = insert_at.unwrap_or(lines.len());

    let new_lines: Vec<String> = {
        let mut v: Vec<String> = lines[..insert_idx].iter().map(|s| s.to_string()).collect();
        if let Some(id) = gap_id {
            v.push(format!("# gap: {id}"));
        }
        v.push(name.to_string());
        v.extend(lines[insert_idx..].iter().map(|s| s.to_string()));
        v
    };

    let out = new_lines.join("\n") + "\n";
    std::fs::write(&path, out)?;
    println!("[add-env-var] added {name} to env-vars-internal.txt (tier {tier})");
    Ok(())
}

pub fn run(args: &[String]) -> i32 {
    let mut name = String::new();
    let mut tier: Option<u8> = None;
    let mut gap_id: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--tier" => {
                i += 1;
                if i < args.len() {
                    tier = args[i].parse::<u8>().ok();
                }
            }
            "--gap-id" => {
                i += 1;
                if i < args.len() {
                    gap_id = Some(args[i].clone());
                }
            }
            "--help" | "-h" => {
                println!("Usage: chump add-env-var <NAME> --tier 1|2|3 [--gap-id <ID>]");
                println!();
                println!("Tier 1: operator-tunable — adds to .env.example");
                println!("Tier 2: debug/advanced  — adds to scripts/ci/env-vars-internal.txt");
                println!("Tier 3: system/runtime  — adds to scripts/ci/env-vars-internal.txt");
                println!();
                println!(
                    "CRITICAL: never inline comments on the var line in env-vars-internal.txt."
                );
                println!("Use --gap-id to add a comment ABOVE the var name.");
                return 0;
            }
            arg if !arg.starts_with('-') && name.is_empty() => {
                name = arg.to_string();
            }
            _ => {}
        }
        i += 1;
    }

    if name.is_empty() {
        eprintln!("error: var NAME is required");
        eprintln!("Usage: chump add-env-var <NAME> --tier 1|2|3 [--gap-id <ID>]");
        return 2;
    }

    let tier = match tier {
        Some(t @ 1..=3) => t,
        Some(t) => {
            eprintln!("error: --tier must be 1, 2, or 3 (got {t})");
            return 2;
        }
        None => {
            eprintln!("error: --tier 1|2|3 is required");
            eprintln!("Usage: chump add-env-var <NAME> --tier 1|2|3 [--gap-id <ID>]");
            return 2;
        }
    };

    let root = repo_root();

    let result = if tier == 1 {
        add_to_env_example(&root, &name, gap_id.as_deref())
    } else {
        add_to_internal(&root, &name, tier, gap_id.as_deref())
    };

    match result {
        Ok(()) => {
            println!("[add-env-var] done. Run scripts/ci/test-env-var-coverage.sh to verify.");
            0
        }
        Err(e) => {
            eprintln!("[add-env-var] error: {e}");
            1
        }
    }
}
