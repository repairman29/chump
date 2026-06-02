//! INFRA-2399: `chump emit-event` — author-time helper to register a new event
//! kind in docs/observability/EVENT_REGISTRY.yaml so CI event-registry-coverage
//! gates don't fire on the next PR.
//!
//! Usage:
//!   chump emit-event <kind> [--gap-id <ID>] [--description "..."]
//!
//! Appends a minimal YAML entry to EVENT_REGISTRY.yaml under an
//! "── INFRA-2399: author-time additions" section comment.
//! The entry is marked status: pending — operator should flesh it out.
//!
//! Idempotent: if the kind already exists in the registry, exits 0 with a
//! "already registered" message.

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

/// Check if a kind is already registered in the registry file.
/// Matches both bare `kind: <value>` and list-style `- kind: <value>` YAML lines.
fn already_registered(content: &str, kind: &str) -> bool {
    for line in content.lines() {
        // Strip leading whitespace and optional list marker "- " before looking for kind:.
        let trimmed = line.trim_start();
        let after_dash = trimmed.strip_prefix("- ").unwrap_or(trimmed);
        if let Some(rest) = after_dash.strip_prefix("kind:") {
            let val = rest.trim();
            if val == kind {
                return true;
            }
        }
    }
    false
}

/// Append a minimal YAML entry for the new kind.
fn append_entry(
    path: &Path,
    kind: &str,
    gap_id: Option<&str>,
    description: &str,
) -> anyhow::Result<()> {
    let gap_ref = gap_id.unwrap_or("INFRA-2399");
    let desc = if description.is_empty() {
        format!("Author-time registered kind (see {gap_ref}). Fill in trigger/consumers/fields.")
    } else {
        description.to_string()
    };

    let ts = chrono::Utc::now().format("%Y-%m-%d").to_string();

    let entry = format!(
        r#"
  # ── {gap_ref}: author-time addition {ts} ─────────────────────────────────────
  - kind: {kind}
    effect_metric: tbd
    emitter: "tbd — fill in after implementing the emitter"
    trigger: >
      {desc}
    consumers: [ops-audit]
    fields_required: [ts, kind]
    expected_volume: "tbd"
    status: pending
"#,
        gap_ref = gap_ref,
        ts = ts,
        kind = kind,
        desc = desc,
    );

    let mut f = std::fs::OpenOptions::new().append(true).open(path)?;
    write!(f, "{entry}")?;
    Ok(())
}

pub fn run(args: &[String]) -> i32 {
    let mut kind = String::new();
    let mut gap_id: Option<String> = None;
    let mut description = String::new();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--gap-id" => {
                i += 1;
                if i < args.len() {
                    gap_id = Some(args[i].clone());
                }
            }
            "--description" => {
                i += 1;
                if i < args.len() {
                    description = args[i].clone();
                }
            }
            "--help" | "-h" => {
                println!("Usage: chump emit-event <kind> [--gap-id <ID>] [--description \"...\"]");
                println!();
                println!("Registers a new event kind in docs/observability/EVENT_REGISTRY.yaml.");
                println!("Prevents CI event-registry-coverage gate failures on the next PR.");
                println!("The entry is marked status: pending — flesh it out before shipping.");
                return 0;
            }
            arg if !arg.starts_with('-') && kind.is_empty() => {
                kind = arg.to_string();
            }
            _ => {}
        }
        i += 1;
    }

    if kind.is_empty() {
        eprintln!("error: event kind is required");
        eprintln!("Usage: chump emit-event <kind> [--gap-id <ID>] [--description \"...\"]");
        return 2;
    }

    let root = repo_root();
    let registry_path = root.join("docs/observability/EVENT_REGISTRY.yaml");

    if !registry_path.exists() {
        eprintln!(
            "error: EVENT_REGISTRY.yaml not found at {}",
            registry_path.display()
        );
        eprintln!("Expected: docs/observability/EVENT_REGISTRY.yaml");
        return 1;
    }

    let content = match std::fs::read_to_string(&registry_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[emit-event] error reading registry: {e}");
            return 1;
        }
    };

    if already_registered(&content, &kind) {
        println!("[emit-event] kind={kind} already registered in EVENT_REGISTRY.yaml — skipping");
        return 0;
    }

    if let Err(e) = append_entry(&registry_path, &kind, gap_id.as_deref(), &description) {
        eprintln!("[emit-event] error appending entry: {e}");
        return 1;
    }

    println!("[emit-event] registered kind={kind} in EVENT_REGISTRY.yaml");
    println!("[emit-event] status=pending — fill in trigger/emitter/consumers before ship.");
    println!("[emit-event] Run scripts/ci/test-event-registry-coverage.sh to verify.");
    0
}
