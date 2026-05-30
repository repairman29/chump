//! INFRA-2258: `chump voice` — file a Voice-of-Agent (VOA) report from an agent session.
//!
//! Flags:
//!   --wedge-class <id>               Wedge class identifier (e.g., fmt-drift-queue-wide)
//!   --minutes-lost <int>             Estimated minutes lost to this friction
//!   --workaround <text>              Description of the workaround used
//!   --fix-shape <doc|tooling|gate|new-subcommand|other>
//!                                    Shape of the proposed fix
//!   --fix <text>                     Description of the proposed fix
//!   --target-repo <slug|opt-in:slug|anonymous>
//!                                    Disclosure mode for target repo; default anonymous
//!   --evidence <gap-or-pr-id,...>    Comma-separated evidence references (gap IDs, PR #s)
//!   --ship                           After writing YAML, open a PR against repairman29/chump
//!   --dry-run                        With --ship: print the PR body without opening
//!
//! Writes:
//!   docs/gaps/VOA-NNNN.yaml           — lightweight gap registry entry
//!   docs/voice/VOA-NNNN-FULL.yaml     — full friction report
//!
//! Emits kind=voice_of_agent_filed to ambient.jsonl (anonymized fields only).
//!
//! Reads ~/.chump/voice-opt-in.toml for blanket-consent power-users.
//! Per-VOA disclosure override via --target-repo flag takes precedence.
//!
//! Acceptance criteria:
//!   AC1 — implements all required flags
//!   AC2 — writes docs/gaps/VOA-NNNN.yaml + docs/voice/VOA-NNNN-FULL.yaml with correct schema
//!   AC3 — reads ~/.chump/voice-opt-in.toml; honors per-VOA --target-repo override
//!   AC4 — --ship flag opens PR; --ship --dry-run prints PR body only
//!   AC5 — emits kind=voice_of_agent_filed (anonymized)
//!   AC6 — smoke test scripts/ci/test-voice-subcommand.sh passes

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Disclosure modes for VOA reporter identity + target repo.
#[derive(Debug, Clone, PartialEq)]
enum DisclosureMode {
    Anonymous,
    OptInSlug(String),
    OptInFull,
}

impl DisclosureMode {
    fn from_str(s: &str) -> Self {
        if s == "anonymous" || s.is_empty() {
            return Self::Anonymous;
        }
        if s == "opt-in:full" {
            return Self::OptInFull;
        }
        if let Some(slug) = s.strip_prefix("opt-in:") {
            return Self::OptInSlug(slug.to_string());
        }
        // Bare slug with no opt-in prefix → treat as anonymous (never leak without consent).
        Self::Anonymous
    }

    /// Returns the YAML representation of target_repo for the full report.
    /// Only reveals the repo slug if explicitly opted in.
    fn target_repo_yaml(&self) -> String {
        match self {
            Self::Anonymous => "anonymous".to_string(),
            Self::OptInSlug(slug) => slug.clone(),
            Self::OptInFull => "opt-in:full".to_string(),
        }
    }

    /// Returns the disclosure string for the YAML reporter block.
    fn disclosure_yaml(&self) -> String {
        match self {
            Self::Anonymous => "anonymous".to_string(),
            Self::OptInSlug(_) => "opt-in:slug".to_string(),
            Self::OptInFull => "opt-in:full".to_string(),
        }
    }

    /// Returns the ambient-safe (anonymized) target_repo value. Never leaks slug.
    fn ambient_safe_target(&self) -> &str {
        match self {
            Self::Anonymous => "anonymous",
            Self::OptInSlug(_) => "opt-in:slug",
            Self::OptInFull => "opt-in:full",
        }
    }
}

/// Opt-in configuration from ~/.chump/voice-opt-in.toml.
struct OptInConfig {
    mode: DisclosureMode,
    github_identity: Option<String>,
}

impl Default for OptInConfig {
    fn default() -> Self {
        Self {
            mode: DisclosureMode::Anonymous,
            github_identity: None,
        }
    }
}

/// Parse ~/.chump/voice-opt-in.toml (simple TOML subset: key = "value" lines).
fn read_opt_in_config() -> OptInConfig {
    let home = match std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")) {
        Ok(h) => PathBuf::from(h),
        Err(_) => return OptInConfig::default(),
    };
    let path = home.join(".chump/voice-opt-in.toml");
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return OptInConfig::default(),
    };

    let mut mode = DisclosureMode::Anonymous;
    let mut github_identity: Option<String> = None;

    for line in content.lines() {
        let line = line.trim();
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        if let Some((key, val)) = line.split_once('=') {
            let key = key.trim();
            let val = val.trim().trim_matches('"');
            match key {
                "mode" => {
                    mode = DisclosureMode::from_str(val);
                }
                "github_identity" => {
                    github_identity = Some(val.to_string());
                }
                _ => {}
            }
        }
    }

    OptInConfig {
        mode,
        github_identity,
    }
}

/// Find the repo root (walk up from cwd looking for Cargo.toml with [workspace]).
fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(content) = std::fs::read_to_string(&cargo) {
                if content.contains("[workspace]") {
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

/// Auto-increment the next VOA number by scanning docs/gaps/VOA-*.yaml.
fn next_voa_id(repo_root: &Path) -> String {
    let gaps_dir = repo_root.join("docs/gaps");
    let mut max_num: u32 = 0;
    if let Ok(entries) = std::fs::read_dir(&gaps_dir) {
        for entry in entries.flatten() {
            let fname = entry.file_name();
            let s = fname.to_string_lossy();
            if let Some(rest) = s.strip_prefix("VOA-") {
                if let Some(num_str) = rest.strip_suffix(".yaml") {
                    if let Ok(n) = num_str.parse::<u32>() {
                        if n > max_num {
                            max_num = n;
                        }
                    }
                }
            }
        }
    }
    format!("VOA-{:03}", max_num + 1)
}

/// Escape a string for inline YAML flow (single-quoted) or double-quoted JSON.
fn yaml_escape(s: &str) -> String {
    // Use double-quoted YAML: escape backslash and double-quote.
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Escape for JSON string values.
fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

/// Write the lightweight gap entry at docs/gaps/VOA-NNNN.yaml.
fn write_gap_entry(
    repo_root: &Path,
    voa_id: &str,
    wedge_class: &str,
    minutes_lost: u32,
    fix_shape: &str,
    fix: &str,
    evidence: &[String],
) -> anyhow::Result<()> {
    let path = repo_root.join("docs/gaps").join(format!("{voa_id}.yaml"));
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);

    let evidence_yaml = if evidence.is_empty() {
        "    - (none provided)".to_string()
    } else {
        evidence
            .iter()
            .map(|e| format!("    - \"{}\"", yaml_escape(e)))
            .collect::<Vec<_>>()
            .join("\n")
    };

    let content = format!(
        r#"- id: {voa_id}
  domain: VOA
  title: "VOICE-OF-AGENT {voa_id}: {wedge_class} — {minutes_lost} min lost; fix-shape: {fix_shape}"
  status: open
  priority: P1
  effort: xs
  acceptance_criteria:
    - Full friction report at docs/voice/{voa_id}-FULL.yaml with wedge_class={wedge_class}, minutes_lost={minutes_lost}
    - Proposed fix ({fix_shape}): "{fix}"
    - Evidence references documented in FULL report
  notes: |
    [{ts}] Auto-filed by `chump voice` (INFRA-2258).
    Wedge class: {wedge_class}
    Minutes lost: {minutes_lost}
    Evidence:
{evidence_yaml}
    See docs/voice/{voa_id}-FULL.yaml for full report.
"#,
        voa_id = voa_id,
        wedge_class = wedge_class,
        minutes_lost = minutes_lost,
        fix_shape = fix_shape,
        fix = yaml_escape(fix),
        ts = ts,
        evidence_yaml = evidence_yaml,
    );

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, content)?;
    Ok(())
}

/// Write the full friction report at docs/voice/VOA-NNNN-FULL.yaml.
#[allow(clippy::too_many_arguments)]
fn write_full_report(
    repo_root: &Path,
    voa_id: &str,
    wedge_class: &str,
    minutes_lost: u32,
    workaround: &str,
    fix_shape: &str,
    fix: &str,
    disclosure: &DisclosureMode,
    evidence: &[String],
    agent_role: &str,
    chump_version: &str,
    session_id: &str,
) -> anyhow::Result<()> {
    let dir = repo_root.join("docs/voice");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{voa_id}-FULL.yaml"));
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);

    let target_repo_val = disclosure.target_repo_yaml();
    let disclosure_val = disclosure.disclosure_yaml();

    let evidence_yaml = if evidence.is_empty() {
        "      - (none provided)".to_string()
    } else {
        evidence
            .iter()
            .map(|e| format!("      - \"{}\"", yaml_escape(e)))
            .collect::<Vec<_>>()
            .join("\n")
    };

    // Session ID is always elided in the full report (even opt-in:full),
    // because session IDs may carry context about the target repo's work.
    let session_elided = if session_id.len() > 8 {
        format!("{}...(elided)", &session_id[..8])
    } else {
        "(elided)".to_string()
    };

    let content = format!(
        r#"# {voa_id} — Voice of the Agent, full report.
# Auto-filed by `chump voice` (INFRA-2258).
# See docs/process/VOICE_OF_AGENT.md for protocol.

id: {voa_id}
filed_at: "{ts}"

reporter:
  agent_role: {agent_role}
  chump_version: "{chump_version}"
  target_repo: "{target_repo_val}"
  target_repo_disclosure: {disclosure_val}
  session_id: "{session_elided}"

wedge_observations:

  - wedge_class: {wedge_class}
    minutes_lost: {minutes_lost}
    workaround_used:
      summary: "{workaround_escaped}"
    proposed_fix:
      shape: {fix_shape}
      fix: "{fix_escaped}"
    impact_estimate_minutes_per_session: {minutes_lost}
    evidence:
{evidence_yaml}
"#,
        voa_id = voa_id,
        ts = ts,
        agent_role = agent_role,
        chump_version = chump_version,
        target_repo_val = target_repo_val,
        disclosure_val = disclosure_val,
        session_elided = session_elided,
        wedge_class = wedge_class,
        minutes_lost = minutes_lost,
        workaround_escaped = yaml_escape(workaround),
        fix_shape = fix_shape,
        fix_escaped = yaml_escape(fix),
        evidence_yaml = evidence_yaml,
    );

    std::fs::write(&path, content)?;
    Ok(())
}

/// Emit kind=voice_of_agent_filed to ambient.jsonl.
/// NEVER leaks target_repo slug (uses ambient_safe_target).
fn emit_ambient_event(
    ambient_path: &Path,
    voa_id: &str,
    wedge_class: &str,
    minutes_lost: u32,
    fix_shape: &str,
    disclosure: &DisclosureMode,
    session_id: &str,
) -> anyhow::Result<()> {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let safe_target = disclosure.ambient_safe_target();
    let esc_voa = json_escape(voa_id);
    let esc_class = json_escape(wedge_class);
    let esc_fix = json_escape(fix_shape);
    let esc_session = json_escape(session_id);
    let line = format!(
        r#"{{"ts":"{ts}","kind":"voice_of_agent_filed","voa_id":"{esc_voa}","wedge_class":"{esc_class}","minutes_lost":{minutes_lost},"fix_shape":"{esc_fix}","target_repo":"{safe_target}","session":"{esc_session}"}}"#,
    );
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)?;
    writeln!(f, "{line}")?;
    Ok(())
}

/// Build the PR body text for --ship.
#[allow(clippy::too_many_arguments)]
fn build_pr_body(
    voa_id: &str,
    wedge_class: &str,
    minutes_lost: u32,
    workaround: &str,
    fix_shape: &str,
    fix: &str,
    evidence: &[String],
    disclosure: &DisclosureMode,
) -> String {
    let target_line = match disclosure {
        DisclosureMode::Anonymous => "**Target repo:** anonymous".to_string(),
        DisclosureMode::OptInSlug(slug) => format!("**Target repo:** {slug}"),
        DisclosureMode::OptInFull => "**Target repo:** opt-in:full (see FULL report)".to_string(),
    };

    let evidence_lines = if evidence.is_empty() {
        "- (none provided)".to_string()
    } else {
        evidence
            .iter()
            .map(|e| format!("- {e}"))
            .collect::<Vec<_>>()
            .join("\n")
    };

    format!(
        "## {voa_id} — Voice of the Agent\n\n\
        Auto-filed by `chump voice` ([INFRA-2258](https://github.com/repairman29/chump/issues/2258)).\n\n\
        **Wedge class:** `{wedge_class}`\n\
        **Minutes lost:** {minutes_lost}\n\
        {target_line}\n\n\
        **Workaround used:** {workaround}\n\n\
        **Proposed fix ({fix_shape}):** {fix}\n\n\
        **Evidence:**\n{evidence_lines}\n\n\
        Artifacts:\n\
        - `docs/gaps/{voa_id}.yaml` — lightweight gap entry\n\
        - `docs/voice/{voa_id}-FULL.yaml` — full friction report\n\n\
        See `docs/process/VOICE_OF_AGENT.md` for the VOA protocol.\n\n\
        🤖 Generated with [Claude Code](https://claude.com/claude-code)\n",
        voa_id = voa_id,
        wedge_class = wedge_class,
        minutes_lost = minutes_lost,
        target_line = target_line,
        workaround = workaround,
        fix_shape = fix_shape,
        fix = fix,
        evidence_lines = evidence_lines,
    )
}

/// Open a PR against repairman29/chump with the VOA files attached.
fn ship_pr(
    repo_root: &Path,
    voa_id: &str,
    pr_body: &str,
    dry_run: bool,
    github_identity: Option<&str>,
) -> i32 {
    let branch = format!("voice/{}", voa_id.to_lowercase());

    if dry_run {
        println!("[voice --ship --dry-run] PR title: Voice of Agent: {voa_id}");
        println!("[voice --ship --dry-run] Branch: {branch}");
        println!("[voice --ship --dry-run] Target: repairman29/chump");
        if let Some(id) = github_identity {
            println!("[voice --ship --dry-run] Identity: {id}");
        }
        println!("\n--- PR BODY ---\n{pr_body}\n--- END PR BODY ---");
        return 0;
    }

    // Create branch and commit the VOA files.
    let git_result = Command::new("git")
        .args(["checkout", "-b", &branch])
        .current_dir(repo_root)
        .status();
    if let Err(e) = git_result {
        eprintln!("[voice --ship] failed to create branch: {e}");
        return 1;
    }

    let add_result = Command::new("git")
        .args([
            "add",
            &format!("docs/gaps/{voa_id}.yaml"),
            &format!("docs/voice/{voa_id}-FULL.yaml"),
        ])
        .current_dir(repo_root)
        .status();
    if let Err(e) = add_result {
        eprintln!("[voice --ship] git add failed: {e}");
        return 1;
    }

    let commit_msg = format!("docs(voa): file {voa_id} — Voice of the Agent report\n\nAuto-filed by `chump voice` (INFRA-2258).");
    let commit_result = Command::new("git")
        .args(["commit", "-m", &commit_msg])
        .current_dir(repo_root)
        .status();
    if let Err(e) = commit_result {
        eprintln!("[voice --ship] git commit failed: {e}");
        return 1;
    }

    let push_result = Command::new("git")
        .args(["push", "-u", "origin", &branch, "--force-with-lease"])
        .current_dir(repo_root)
        .status();
    if let Err(e) = push_result {
        eprintln!("[voice --ship] git push failed: {e}");
        return 1;
    }

    let title = format!("docs(voa): Voice of the Agent — {voa_id}");

    let gh_args = vec![
        "pr".to_string(),
        "create".to_string(),
        "--title".to_string(),
        title,
        "--body".to_string(),
        pr_body.to_string(),
        "--base".to_string(),
        "main".to_string(),
        "--repo".to_string(),
        "repairman29/chump".to_string(),
    ];

    if let Some(id) = github_identity {
        // Identity is for PR metadata context (already included in PR body).
        // gh CLI does not support impersonation; we just log it.
        eprintln!("[voice --ship] filing as identity: {id}");
    }

    let pr_result = Command::new("gh")
        .args(&gh_args)
        .current_dir(repo_root)
        .status();

    match pr_result {
        Ok(s) if s.success() => {
            println!("[voice --ship] PR opened against repairman29/chump");
            0
        }
        Ok(s) => {
            eprintln!("[voice --ship] gh pr create exited {:?}", s.code());
            1
        }
        Err(e) => {
            eprintln!("[voice --ship] failed to run gh: {e}");
            1
        }
    }
}

pub fn run(args: &[String]) -> i32 {
    // Parse flags.
    let mut wedge_class = String::new();
    let mut minutes_lost: Option<u32> = None;
    let mut workaround = String::new();
    let mut fix_shape = String::new();
    let mut fix = String::new();
    let mut target_repo_flag: Option<String> = None;
    let mut evidence_raw = String::new();
    let mut ship = false;
    let mut dry_run = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--wedge-class" => {
                i += 1;
                if i < args.len() {
                    wedge_class = args[i].clone();
                }
            }
            "--minutes-lost" => {
                i += 1;
                if i < args.len() {
                    minutes_lost = args[i].parse::<u32>().ok();
                }
            }
            "--workaround" => {
                i += 1;
                if i < args.len() {
                    workaround = args[i].clone();
                }
            }
            "--fix-shape" => {
                i += 1;
                if i < args.len() {
                    fix_shape = args[i].clone();
                }
            }
            "--fix" => {
                i += 1;
                if i < args.len() {
                    fix = args[i].clone();
                }
            }
            "--target-repo" => {
                i += 1;
                if i < args.len() {
                    target_repo_flag = Some(args[i].clone());
                }
            }
            "--evidence" => {
                i += 1;
                if i < args.len() {
                    evidence_raw = args[i].clone();
                }
            }
            "--ship" => {
                ship = true;
            }
            "--dry-run" => {
                dry_run = true;
            }
            "--help" | "-h" => {
                println!("Usage: chump voice --wedge-class <id> --minutes-lost <int> [--workaround <text>] --fix-shape <doc|tooling|gate|new-subcommand|other> --fix <text> [--target-repo <anonymous|opt-in:slug|opt-in:full>] [--evidence <refs,...>] [--ship [--dry-run]]");
                println!();
                println!("Writes:");
                println!("  docs/gaps/VOA-NNNN.yaml       — lightweight gap registry entry");
                println!("  docs/voice/VOA-NNNN-FULL.yaml — full friction report");
                println!();
                println!("Emits kind=voice_of_agent_filed to ambient.jsonl (anonymized).");
                println!();
                println!("Power-user opt-in: create ~/.chump/voice-opt-in.toml with:");
                println!("  mode = \"opt-in:slug\"  # or opt-in:full");
                println!("  github_identity = \"your-gh-handle\"");
                return 0;
            }
            _ => {}
        }
        i += 1;
    }

    // Validate required fields.
    if wedge_class.is_empty() {
        eprintln!("error: --wedge-class <id> is required");
        eprintln!("Usage: chump voice --wedge-class <id> --minutes-lost <int> --fix-shape <shape> --fix <text>");
        return 2;
    }
    let minutes_lost = match minutes_lost {
        Some(m) => m,
        None => {
            eprintln!("error: --minutes-lost <int> is required");
            return 2;
        }
    };
    if fix_shape.is_empty() {
        eprintln!("error: --fix-shape <doc|tooling|gate|new-subcommand|other> is required");
        return 2;
    }
    let valid_shapes = ["doc", "tooling", "gate", "new-subcommand", "other"];
    if !valid_shapes.contains(&fix_shape.as_str()) {
        eprintln!(
            "error: --fix-shape must be one of: {}",
            valid_shapes.join(", ")
        );
        return 2;
    }
    if fix.is_empty() {
        eprintln!("error: --fix <text> is required");
        return 2;
    }

    // Evidence list.
    let evidence: Vec<String> = if evidence_raw.is_empty() {
        vec![]
    } else {
        evidence_raw
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    };

    // Resolve disclosure mode.
    // 1. Read blanket opt-in config from ~/.chump/voice-opt-in.toml.
    // 2. Per-VOA --target-repo flag overrides.
    let opt_in = read_opt_in_config();
    let disclosure = match target_repo_flag {
        Some(ref flag) => DisclosureMode::from_str(flag),
        None => opt_in.mode.clone(),
    };

    // Resolve agent role + version + session.
    let agent_role = std::env::var("CHUMP_SESSION_ROLE")
        .or_else(|_| std::env::var("CHUMP_AGENT_ROLE"))
        .unwrap_or_else(|_| "unknown-role".to_string());
    let chump_version =
        std::env::var("CHUMP_VERSION").unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    let session_id = std::env::var("CHUMP_SESSION_ID").unwrap_or_else(|_| "unknown".to_string());

    let root = repo_root();

    // Auto-increment VOA ID.
    let voa_id = std::env::var("CHUMP_VOICE_TEST_ID").unwrap_or_else(|_| next_voa_id(&root));

    // Write gap entry.
    if let Err(e) = write_gap_entry(
        &root,
        &voa_id,
        &wedge_class,
        minutes_lost,
        &fix_shape,
        &fix,
        &evidence,
    ) {
        eprintln!("error: failed to write docs/gaps/{voa_id}.yaml: {e}");
        return 1;
    }
    println!("[voice] wrote docs/gaps/{voa_id}.yaml");

    // Write full report.
    if let Err(e) = write_full_report(
        &root,
        &voa_id,
        &wedge_class,
        minutes_lost,
        &workaround,
        &fix_shape,
        &fix,
        &disclosure,
        &evidence,
        &agent_role,
        &chump_version,
        &session_id,
    ) {
        eprintln!("error: failed to write docs/voice/{voa_id}-FULL.yaml: {e}");
        return 1;
    }
    println!("[voice] wrote docs/voice/{voa_id}-FULL.yaml");

    // Emit ambient event (always anonymized).
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join(".chump-locks/ambient.jsonl"));

    if let Err(e) = emit_ambient_event(
        &ambient_path,
        &voa_id,
        &wedge_class,
        minutes_lost,
        &fix_shape,
        &disclosure,
        &session_id,
    ) {
        // Non-fatal: warn and continue.
        eprintln!("warn: failed to emit kind=voice_of_agent_filed: {e}");
    } else {
        println!("[voice] emitted kind=voice_of_agent_filed to ambient.jsonl");
    }

    // Handle --ship.
    if ship {
        let pr_body = build_pr_body(
            &voa_id,
            &wedge_class,
            minutes_lost,
            &workaround,
            &fix_shape,
            &fix,
            &evidence,
            &disclosure,
        );
        let code = ship_pr(
            &root,
            &voa_id,
            &pr_body,
            dry_run,
            opt_in.github_identity.as_deref(),
        );
        if code != 0 {
            return code;
        }
    }

    println!("[voice] {voa_id} filed successfully.");
    0
}
