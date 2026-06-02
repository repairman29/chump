//! INFRA-2399: `chump add-path-filter` — author-time helper to add a new
//! directory glob to the `code:` paths-filter block in .github/workflows/ci.yml.
//!
//! Usage:
//!   chump add-path-filter <dir>
//!
//! Inserts `- '<dir>/**'` into the `code:` section of the dorny/paths-filter
//! block in ci.yml. Insertion is alphabetical among existing `- '...'` entries.
//!
//! Why this matters: if a PR's diff matches NONE of the `code:` patterns, CI
//! marks required checks as "skipped" and branch protection blocks the merge
//! forever. See INFRA-272 / INFRA-682.
//!
//! Idempotent: if the dir is already listed, exits 0 with a skip message.

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

/// Extract the glob prefix from a path-filter line like `- 'src/**'` → `src`.
fn glob_prefix(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    // Lines look like: `              - 'src/**'`
    let after_dash = trimmed.strip_prefix('-')?.trim();
    let inner = after_dash
        .strip_prefix('\'')
        .or_else(|| after_dash.strip_prefix('"'))?;
    let inner = inner
        .strip_suffix("/**'")
        .or_else(|| inner.strip_suffix("/**\""))
        .or_else(|| inner.strip_suffix("/**"))?;
    Some(inner)
}

/// Insert `- '<dir>/**'` alphabetically into the `code:` block.
fn insert_path_filter(ci_path: &Path, dir: &str) -> anyhow::Result<bool> {
    let content = std::fs::read_to_string(ci_path)?;
    let target_glob = format!("- '{dir}/**'");

    // Idempotency: check for existing entry.
    for line in content.lines() {
        if line.trim() == target_glob.as_str() {
            return Ok(false);
        }
        // Also match double-quote variant.
        let dq = format!("- \"{dir}/**\"");
        if line.trim() == dq.as_str() {
            return Ok(false);
        }
    }

    let lines: Vec<&str> = content.lines().collect();

    // Find the `code:` block: look for a line matching `            code:` or `      code:`
    // then collect the run of `- '...'` entries immediately following it.
    let mut code_block_start: Option<usize> = None;
    let mut code_entries_end: Option<usize> = None; // index of line AFTER last `- '...'` in code block

    let mut in_code = false;
    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if trimmed == "code:" {
            in_code = true;
            code_block_start = Some(i);
            continue;
        }
        if in_code {
            if trimmed.starts_with("- '") || trimmed.starts_with("- \"") {
                code_entries_end = Some(i + 1);
            } else if !trimmed.is_empty() && !trimmed.starts_with('#') && code_entries_end.is_some()
            {
                // We've left the entries list.
                break;
            }
        }
    }

    let block_start = match code_block_start {
        Some(s) => s,
        None => anyhow::bail!("could not find `code:` filter block in ci.yml"),
    };
    let entries_end = code_entries_end.unwrap_or(block_start + 1);

    // Collect the range of `- '...'` entry lines (entries_start..entries_end).
    // entries_start = first line after `code:` that is an entry.
    let mut entries_start = block_start + 1;
    while entries_start < entries_end {
        let t = lines[entries_start].trim();
        if t.starts_with("- '") || t.starts_with("- \"") || t.starts_with('#') {
            break;
        }
        entries_start += 1;
    }

    // Determine indentation from the first entry line.
    let indent = if entries_start < lines.len() {
        let first = lines[entries_start];
        let spaces: usize = first.chars().take_while(|c| *c == ' ').count();
        " ".repeat(spaces)
    } else {
        "              ".to_string() // default 14 spaces
    };

    let new_line = format!("{indent}{target_glob}");

    // Find alphabetical insertion point within entries_start..entries_end.
    let mut insert_at = entries_end; // default: append at end of block
    for (i, line) in lines
        .iter()
        .enumerate()
        .take(entries_end)
        .skip(entries_start)
    {
        let t = line.trim();
        if t.starts_with('#') {
            continue;
        }
        if let Some(prefix) = glob_prefix(line) {
            if prefix > dir {
                insert_at = i;
                break;
            }
        }
    }

    let mut new_lines: Vec<String> = lines[..insert_at].iter().map(|s| s.to_string()).collect();
    new_lines.push(new_line);
    new_lines.extend(lines[insert_at..].iter().map(|s| s.to_string()));

    let out = new_lines.join("\n") + "\n";
    std::fs::write(ci_path, out)?;
    Ok(true)
}

pub fn run(args: &[String]) -> i32 {
    let mut dir = String::new();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                println!("Usage: chump add-path-filter <dir>");
                println!();
                println!("Inserts - '<dir>/**' into the code: paths-filter block in");
                println!(".github/workflows/ci.yml (alphabetical insertion).");
                println!();
                println!("Required when a new top-level directory may be the SOLE diff in a PR.");
                println!("Without this, branch protection blocks the merge (INFRA-272/682).");
                return 0;
            }
            arg if !arg.starts_with('-') && dir.is_empty() => {
                dir = arg.to_string();
            }
            _ => {}
        }
        i += 1;
    }

    if dir.is_empty() {
        eprintln!("error: <dir> is required");
        eprintln!("Usage: chump add-path-filter <dir>");
        return 2;
    }

    let root = repo_root();
    let ci_path = root.join(".github/workflows/ci.yml");

    if !ci_path.exists() {
        eprintln!("error: .github/workflows/ci.yml not found");
        return 1;
    }

    match insert_path_filter(&ci_path, &dir) {
        Ok(true) => {
            println!("[add-path-filter] inserted - '{dir}/**' into code: block in ci.yml");
            println!("[add-path-filter] Verify: grep \"{dir}\" .github/workflows/ci.yml");
            0
        }
        Ok(false) => {
            println!("[add-path-filter] '{dir}/**' already in ci.yml code: block — skipping");
            0
        }
        Err(e) => {
            eprintln!("[add-path-filter] error: {e}");
            1
        }
    }
}
