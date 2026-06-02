//! INFRA-2399: `chump install-daemon` — author-time helper to register a new
//! install script in the correct bootstrap manifest so CI install-manifest
//! gates don't fire on the next PR.
//!
//! Usage:
//!   chump install-daemon <stem> --kind required|optional|deprecated [--gap-id <ID>]
//!
//! Kinds:
//!   required   → appends to REQUIRED_DAEMONS array in
//!                scripts/setup/chump-fleet-bootstrap.sh
//!                Format: "com.chump.<stem>|scripts/setup/<stem>.sh"
//!   optional   → appends to scripts/setup/optional-installers-allowlist.txt
//!   deprecated → appends to scripts/setup/deprecated-installers-allowlist.txt
//!
//! <stem> is the basename of the install script WITHOUT the install- prefix or .sh suffix.
//! Example: `chump install-daemon my-watchdog --kind required`
//!   registers "com.chump.my-watchdog|scripts/setup/install-my-watchdog.sh"
//!
//! Idempotent: if the stem is already present, exits 0 with a skip message.

use std::io::Write;
use std::path::{Path, PathBuf};

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

/// Add entry to a one-filename-per-line allowlist file.
fn add_to_allowlist(path: &Path, filename: &str) -> anyhow::Result<bool> {
    let content = std::fs::read_to_string(path).unwrap_or_default();
    for line in content.lines() {
        let stripped = line.trim();
        if stripped == filename || stripped.split('#').next().map(str::trim) == Some(filename) {
            return Ok(false); // already present
        }
    }
    let mut f = std::fs::OpenOptions::new().append(true).open(path)?;
    writeln!(f, "{filename}")?;
    Ok(true)
}

/// Add entry to REQUIRED_DAEMONS array in chump-fleet-bootstrap.sh.
/// Finds the closing `)` of REQUIRED_DAEMONS and inserts before it.
fn add_to_required_daemons(root: &Path, stem: &str, gap_id: Option<&str>) -> anyhow::Result<bool> {
    let path = root.join("scripts/setup/chump-fleet-bootstrap.sh");
    let content = std::fs::read_to_string(&path)?;

    let label = format!("com.chump.{stem}");
    let install_path = format!("scripts/setup/install-{stem}.sh");
    let entry_val = format!("{label}|{install_path}");

    // Idempotency: check if label already in file.
    if content.contains(&label) {
        return Ok(false);
    }

    // Find REQUIRED_DAEMONS closing paren.
    let mut in_array = false;
    let mut close_line: Option<usize> = None;
    let lines: Vec<&str> = content.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        if line.contains("REQUIRED_DAEMONS=(") {
            in_array = true;
            continue;
        }
        if in_array && line.trim() == ")" {
            close_line = Some(i);
            break;
        }
    }

    let close_idx = match close_line {
        Some(idx) => idx,
        None => {
            anyhow::bail!(
                "could not find REQUIRED_DAEMONS closing ')' in chump-fleet-bootstrap.sh"
            );
        }
    };

    let mut new_lines: Vec<String> = lines[..close_idx].iter().map(|s| s.to_string()).collect();
    if let Some(id) = gap_id {
        new_lines.push(format!("    # {id}: registered by chump install-daemon"));
    }
    new_lines.push(format!("    \"{entry_val}\""));
    new_lines.extend(lines[close_idx..].iter().map(|s| s.to_string()));

    let out = new_lines.join("\n") + "\n";
    std::fs::write(&path, out)?;
    Ok(true)
}

pub fn run(args: &[String]) -> i32 {
    let mut stem = String::new();
    let mut kind = String::new();
    let mut gap_id: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--kind" => {
                i += 1;
                if i < args.len() {
                    kind = args[i].clone();
                }
            }
            "--gap-id" => {
                i += 1;
                if i < args.len() {
                    gap_id = Some(args[i].clone());
                }
            }
            "--help" | "-h" => {
                println!("Usage: chump install-daemon <stem> --kind required|optional|deprecated [--gap-id <ID>]");
                println!();
                println!("  required   → REQUIRED_DAEMONS in chump-fleet-bootstrap.sh");
                println!("               label: com.chump.<stem>");
                println!("               script: scripts/setup/install-<stem>.sh");
                println!("  optional   → scripts/setup/optional-installers-allowlist.txt");
                println!("  deprecated → scripts/setup/deprecated-installers-allowlist.txt");
                return 0;
            }
            arg if !arg.starts_with('-') && stem.is_empty() => {
                stem = arg.to_string();
            }
            _ => {}
        }
        i += 1;
    }

    if stem.is_empty() {
        eprintln!("error: <stem> is required");
        eprintln!("Usage: chump install-daemon <stem> --kind required|optional|deprecated [--gap-id <ID>]");
        return 2;
    }
    if !matches!(kind.as_str(), "required" | "optional" | "deprecated") {
        eprintln!("error: --kind must be required, optional, or deprecated");
        return 2;
    }

    let root = repo_root();

    let result: anyhow::Result<bool> = match kind.as_str() {
        "required" => add_to_required_daemons(&root, &stem, gap_id.as_deref()),
        "optional" => {
            let path = root.join("scripts/setup/optional-installers-allowlist.txt");
            let filename = format!("install-{stem}.sh");
            add_to_allowlist(&path, &filename)
        }
        "deprecated" => {
            let path = root.join("scripts/setup/deprecated-installers-allowlist.txt");
            let filename = format!("install-{stem}.sh");
            add_to_allowlist(&path, &filename)
        }
        _ => unreachable!(),
    };

    match result {
        Ok(true) => {
            println!("[install-daemon] registered install-{stem}.sh as kind={kind}");
            println!("[install-daemon] Run bash scripts/setup/chump-fleet-bootstrap.sh --check to verify.");
            0
        }
        Ok(false) => {
            println!(
                "[install-daemon] install-{stem}.sh already registered as kind={kind} — skipping"
            );
            0
        }
        Err(e) => {
            eprintln!("[install-daemon] error: {e}");
            1
        }
    }
}
